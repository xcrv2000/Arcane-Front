# V0.4 (P3) 联机客户端网络层 + V0.5 弱网优化。
# 职责：
#   - 连接/断开 TCP 中继服务器（协议：JSON Lines，每包 \n 分隔）
#   - 发送房间请求（CREATE_ROOM / JOIN_ROOM / READY / COMMAND / RESULT）
#   - 解析服务器推送事件并通过 Signal 通知上层 UI 与控制器
#   - V0.5：命令历史缓存、冗余批量发送（COMMAND_BATCH）、主动请求缺失命令（REQUEST_COMMANDS/COMMANDS_REPLY）
#
# 用法：
#   var nc = NetworkClient.new()
#   nc.connected_to_server.connect(...)
#   nc.room_created.connect(...)
#   nc.start_match_received.connect(func(seed,my_side,my_deck,peer_deck): ...)
#   nc.command_received.connect(func(cmd_dict): scheduler.enqueue_command(cmd_dict))
#   nc.commands_batch_received.connect(func(cmd_arr): scheduler.enqueue_command_batch(cmd_arr))
#   nc.connect_to_server(host, port)
#   ...
#   nc.send_command_buffered(my_command_dict)  # V0.5：自动带冗余批量发送
#
# 注意：本类纯网络 IO，不持有对局逻辑状态；scheduler/simulator 由控制器协调。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const Command = preload("res://scripts/networking/command.gd")

signal connected_to_server()
signal connection_failed(reason: String)
signal disconnected()

signal room_created(room_code: String, my_side: String)
signal room_joined(room_code: String, my_side: String)
signal peer_joined()
signal peer_ready_changed(ready: bool, peer_side: String)
signal peer_disconnected(grace_seconds: float)
signal opponent_win_by_disconnect(winner: String, room_code: String)
signal start_match_received(seed: int, my_side: String, my_deck: Array[String], peer_deck: Array[String])
signal command_received(payload: Dictionary)
# —— V0.5：批量命令到达（内含冗余），上层应调用 scheduler.enqueue_command_batch 去重入队
signal commands_batch_received(cmd_list: Array)
# —— V0.5：对端/服务器对我方 REQUEST_COMMANDS 的应答到达，上层调用 scheduler.enqueue_command_batch 补全
signal commands_reply_received(from_tick: int, to_tick: int, matched_commands: Array)
# —— V0.5：服务器转发的对端命令请求（一般由服务器直接用 command_log 应答，客户端可忽略此信号）
signal request_commands_received(from_tick: int, to_tick: int, side_filter: String)

signal result_received(winner: String, room_code: String)
signal peer_rematch_received()
signal peer_left_received(who: String)
signal resume_battle_received(commands: Array, seed: int, my_side: String, my_deck: Array[String], peer_deck: Array[String])
signal server_error(message: String)

# 配置
var default_host: String = "64.90.30.36"
var default_port: int = 8765
# V0.5：冗余发送开关（默认开启）
var enable_redundancy: bool = true

# —— 断线重连：本端身份令牌（服务器在 ROOM_CREATED/ROOM_JOINED 时下发）——
var client_id: String = ""

# 运行时
var _tcp: StreamPeerTCP = StreamPeerTCP.new()
var _recv_buf: PackedByteArray = PackedByteArray()
var _running: bool = false
var _last_error: String = ""

# —— V0.5：命令发送历史（按发送时间正序，最新在尾；最多保留 Config.COMMAND_REDUNDANCY_COUNT * 4 条）——
var _send_history: Array = []
const HISTORY_MAX: int = 96  # 上限（冗余条数的 8 倍，足够覆盖网络抖动 + 请求补全窗口）


# —— V0.5：重置发送历史（新对局开始时调用，防止旧局命令污染下一局冗余）——
func reset_send_history() -> void:
	_send_history.clear()


# —— 连接控制 ——
func connect_to_server(host: String = "", port: int = 0) -> void:
	disconnect_from_server()
	_was_connected = false
	var h: String = host if host != "" else default_host
	var p: int = port if port > 0 else default_port
	var ok: Error = _tcp.connect_to_host(h, p)
	if ok != OK:
		_last_error = "connect call failed: %d" % int(ok)
		emit_signal("connection_failed", _last_error)
		return
	_recv_buf.clear()
	_running = true
	_last_error = ""
	reset_send_history()
	# 轮询由 attach_to_node 的 Timer 驱动


func disconnect_from_server() -> void:
	_running = false
	_was_connected = false
	# 轮询由 attach_to_node 的 Timer 驱动，无需手动停止
	if _tcp != null:
		_tcp.disconnect_from_host()
	_recv_buf.clear()
	reset_send_history()


func is_tcp_connected() -> bool:
	if _tcp == null:
		return false
	return _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED


# —— 房间与对局请求（客户端 → 服务器）——
func send_create_room() -> void:
	var payload: Dictionary = {"type": "CREATE_ROOM"}
	if client_id != "":
		payload["client_id"] = client_id
	_send_json(payload)


func send_join_room(room_code: String) -> void:
	var payload: Dictionary = {"type": "JOIN_ROOM", "room_code": room_code.strip_edges().to_upper()}
	if client_id != "":
		payload["client_id"] = client_id
	_send_json(payload)


func send_heartbeat() -> void:
	_send_json({"type": "HEARTBEAT"})


func send_ready(ready_flag: bool, my_deck: Array[String]) -> void:
	var deck_strs: Array[String] = []
	for c in my_deck:
		deck_strs.append(String(c))
	_send_json({"type": "READY", "ready": ready_flag, "deck": deck_strs})


# 兼容旧接口：发送单条命令（不带冗余）。
# V0.5 建议优先使用 send_command_buffered。
func send_command(cmd_dict: Dictionary) -> void:
	_send_json({"type": "COMMAND", "payload": cmd_dict})


# —— V0.5：发送命令 + 自动加入发送历史 + 可选冗余批量包装 ——
# 新的主发送入口。联机模式下调用此函数可获得抗抖动冗余。
func send_command_buffered(cmd_dict: Dictionary) -> void:
	# 先加入历史缓存
	_history_append(cmd_dict)
	if enable_redundancy:
		# 包装为 COMMAND_BATCH：主命令 + 最近 COMMAND_REDUNDANCY_COUNT 条历史
		var batch: Dictionary = Command.wrap_command_batch(cmd_dict, _send_history, Config.COMMAND_REDUNDANCY_COUNT)
		_send_json({"type": "COMMAND", "payload": batch})
	else:
		# 冗余关闭：走旧的单条发送
		_send_json({"type": "COMMAND", "payload": cmd_dict})


# —— V0.5：主动请求 [from_tick, to_tick] 范围内的命令（触发服务器查 command_log 回发 COMMANDS_REPLY）——
func send_request_commands(from_tick: int, to_tick: int, side_filter: String = "") -> void:
	var req: Dictionary = Command.request_commands(from_tick, to_tick, side_filter)
	_send_json({"type": "COMMAND", "payload": req})


func send_result(winner: String, room_code: String) -> void:
	_send_json({"type": "RESULT", "winner": winner, "room_code": room_code})


func send_rematch(my_deck: Array[String]) -> void:
	var deck_strs: Array[String] = []
	for c in my_deck:
		deck_strs.append(String(c))
	_send_json({"type": "REMATCH", "deck": deck_strs})


func send_leave_room() -> void:
	_send_json({"type": "LEAVE_ROOM"})


# —— V0.5 内部：把一条命令追加到历史环形缓冲 ——
func _history_append(cmd_dict: Dictionary) -> void:
	_send_history.append(cmd_dict.duplicate(true))
	while _send_history.size() > HISTORY_MAX:
		_send_history.pop_front()


# —— 内部发送/轮询 ——
func _send_json(obj: Dictionary) -> void:
	if not _running:
		return
	var json_str: String = JSON.stringify(obj)
	var payload: PackedByteArray = (json_str + "\n").to_utf8_buffer()
	var err: Error = _tcp.put_data(payload)
	if err != OK:
		_last_error = "put_data failed: %d" % int(err)
		_running = false
		emit_signal("disconnected")


# Godot 4.5 无内建帧回调（RefCounted 非 Node）。我们用一个假的 Timer 思路：
# 让控制器（Control/Node）每帧调用 _poll()，或我们每 0.033s 触发一次自定义 poll。
# 此处提供 _poll() 公开入口，由控制器 _process 每帧调用。
func poll() -> void:
	if not _running:
		return
	# 必须先 poll 才能推动 TCP 状态机（STATUS_CONNECTING → STATUS_CONNECTED）
	_tcp.poll()
	var st: int = int(_tcp.get_status())
	if st == StreamPeerTCP.STATUS_NONE:
		# 还没连上或连接失败
		return
	if st == StreamPeerTCP.STATUS_ERROR:
		_last_error = "socket error"
		_running = false
		if not _was_connected:
			emit_signal("connection_failed", _last_error)
		else:
			emit_signal("disconnected")
		_was_connected = false
		return
	if st == StreamPeerTCP.STATUS_CONNECTING:
		return
	if st == StreamPeerTCP.STATUS_CONNECTED:
		if not _was_connected:
			_was_connected = true
			emit_signal("connected_to_server")
		_drain_incoming()


var _was_connected: bool = false


func _drain_incoming() -> void:
	while true:
		var avail: int = int(_tcp.get_available_bytes())
		if avail <= 0:
			break
		var read_r = _tcp.get_partial_data(avail)
		var err: int = int(read_r[0])
		var chunk: PackedByteArray = read_r[1]
		if err != OK or chunk.size() == 0:
			break
		_recv_buf.append_array(chunk)
	# 按 \n 切包
	while true:
		var nl_idx: int = -1
		for i in range(_recv_buf.size()):
			if _recv_buf[i] == 10:  # '\n'
				nl_idx = i
				break
		if nl_idx < 0:
			break
		var line_bytes: PackedByteArray = _recv_buf.slice(0, nl_idx)
		if nl_idx + 1 < _recv_buf.size():
			_recv_buf = _recv_buf.slice(nl_idx + 1, _recv_buf.size())
		else:
			_recv_buf.clear()
		var text: String = line_bytes.get_string_from_utf8()
		if text.strip_edges() == "":
			continue
		_handle_line(text)


func _handle_line(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	var t: String = String(msg.get("type", ""))
	match t:
		"ROOM_CREATED":
			client_id = String(msg.get("client_id", client_id))
			emit_signal("room_created", String(msg.get("room_code", "")), String(msg.get("my_side", "host")))
		"ROOM_JOINED":
			client_id = String(msg.get("client_id", client_id))
			emit_signal("room_joined", String(msg.get("room_code", "")), String(msg.get("my_side", "guest")))
		"PEER_JOINED":
			emit_signal("peer_joined")
		"PEER_READY":
			emit_signal("peer_ready_changed", bool(msg.get("ready", false)), String(msg.get("side", "guest")))
		"PEER_DISCONNECT":
			emit_signal("peer_disconnected", float(msg.get("grace_seconds", 30.0)))
		"OPPONENT_DISCONNECTED_WIN":
			emit_signal("opponent_win_by_disconnect", String(msg.get("winner", "")), String(msg.get("room_code", "")))
		"START":
			var deck_a: Array[String] = []
			for raw in msg.get("my_deck", []):
				deck_a.append(String(raw))
			var deck_b: Array[String] = []
			for raw in msg.get("peer_deck", []):
				deck_b.append(String(raw))
			# 新对局开始：清空发送历史（避免上一局冗余污染）
			reset_send_history()
			emit_signal("start_match_received", int(msg.get("seed", 0)), String(msg.get("my_side", "host")), deck_a, deck_b)
		"COMMAND":
			var payload: Variant = msg.get("payload", {})
			if typeof(payload) == TYPE_DICTIONARY:
				_dispatch_incoming_command(Dictionary(payload))
		"RESULT":
			emit_signal("result_received", String(msg.get("winner", "")), String(msg.get("room_code", "")))
		"PEER_REMATCH":
			emit_signal("peer_rematch_received")
		"PEER_LEFT":
			emit_signal("peer_left_received", String(msg.get("who", "")))
		"RESUME_BATTLE":
			# 主机端收到的是无数据的 RESUME_BATTLE（只需恢复倒计时）
			# 客机端收到的是带 commands/seed/decks 的 RESUME_BATTLE（需要回放恢复战场）
			var cmds: Array = []
			for raw in msg.get("commands", []):
				if typeof(raw) == TYPE_DICTIONARY:
					cmds.append(Dictionary(raw))
			var deck_a: Array[String] = []
			for raw in msg.get("my_deck", []):
				deck_a.append(String(raw))
			var deck_b: Array[String] = []
			for raw in msg.get("peer_deck", []):
				deck_b.append(String(raw))
			emit_signal("resume_battle_received", cmds, int(msg.get("seed", 0)), String(msg.get("my_side", "")), deck_a, deck_b)
		"ERROR":
			emit_signal("server_error", String(msg.get("message", "")))


# —— V0.5：分发来自服务器的 COMMAND payload ——
# 可能是：
#   1) 单条战斗命令（旧格式 / 未包装）→ 走 command_received 兼容 + commands_batch_received([cmd])
#   2) COMMAND_BATCH（带冗余的新格式）→ 走 commands_batch_received(批量)
#   3) REQUEST_COMMANDS（服务器转发的对端请求，通常服务器自己答，此为兜底）→ 信号上报
#   4) COMMANDS_REPLY（服务器对我方 REQUEST_COMMANDS 的应答）→ commands_reply_received 信号
func _dispatch_incoming_command(payload: Dictionary) -> void:
	if Command.is_network_wrapper(payload):
		var net_type: String = String(payload.get("_net_type", ""))
		match net_type:
			Command.NET_COMMAND_BATCH:
				var cmds: Array = Command.unwrap_commands(payload)
				# V0.5 新信号：批量到达，由上层去重入队
				emit_signal("commands_batch_received", cmds)
				# 兼容：也把第一条（最新的主命令）走旧信号，避免上层未改时功能退化
				if cmds.size() > 0 and typeof(cmds[cmds.size() - 1]) == TYPE_DICTIONARY:
					emit_signal("command_received", Dictionary(cmds[cmds.size() - 1]))
			Command.NET_REQUEST_COMMANDS:
				var ft: int = int(payload.get("from_tick", 0))
				var tt: int = int(payload.get("to_tick", 0))
				var sf: String = String(payload.get("side", ""))
				emit_signal("request_commands_received", ft, tt, sf)
			Command.NET_COMMANDS_REPLY:
				var ft: int = int(payload.get("from_tick", 0))
				var tt: int = int(payload.get("to_tick", 0))
				var matched: Array = []
				for raw in payload.get("commands", []):
					if typeof(raw) == TYPE_DICTIONARY:
						matched.append(Dictionary(raw))
				emit_signal("commands_reply_received", ft, tt, matched)
			_:
				# 未知网络包装：忽略（安全兜底）
				pass
	else:
		# 旧格式：单条命令
		emit_signal("command_received", payload)
		emit_signal("commands_batch_received", [payload])


# —— 可选：由持有方用 Node 挂 _process 每帧调用 poll；此处提供便利方法
#    在 Node 中：nc.attach_to_node(self)，自动每帧 _process 调用 poll()
var _attached_node: Node = null
var _timer: Timer = null

func attach_to_node(node: Node) -> void:
	detach_from_node()
	_attached_node = node
	_timer = Timer.new()
	_timer.wait_time = 0.033
	_timer.autostart = true
	_timer.one_shot = false
	_timer.timeout.connect(_on_attached_tick)
	node.add_child(_timer)


func is_attached() -> bool:
	return _timer != null and is_instance_valid(_timer)


func detach_from_node() -> void:
	if _timer != null and _attached_node != null:
		if _timer.get_parent() == _attached_node:
			_attached_node.remove_child(_timer)
		_timer.queue_free()
	_timer = null
	_attached_node = null


func _on_attached_tick() -> void:
	poll()
