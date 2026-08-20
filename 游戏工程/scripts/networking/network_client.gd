# V0.45 (P2) 联机客户端网络层：ENet raw packet。
# 替换 V0.4 的 StreamPeerTCP + JSON Lines 实现。
# 职责：
#   - 用 Godot ENetMultiplayerPeer 创建客户端连接（UDP 8765）。
#   - 以 raw packet 承载自定义协议：0x00+JSON 控制包、0x01 PLAY_CARD、0x02 CHECKSUM、0x03 PING。
#   - 保持 V0.4 的上层信号接口，使 v01_game.gd 的房间/对局流程改动最小。
#
# 用法与旧版一致：
#   var nc = NetworkClient.new()
#   nc.start_match_received.connect(...)
#   nc.connect_to_server(host, port)
#   ...
#   nc.send_command_buffered(my_command_dict)
#
# 注意：本类纯网络 IO，不持有对局逻辑状态；scheduler/simulator 由控制器协调。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const Command = preload("res://scripts/networking/command.gd")
const EnetProtocol = preload("res://scripts/networking/enet_protocol.gd")

signal connected_to_server()
signal connection_failed(reason: String)
signal disconnected()

signal room_created(room_code: String, my_side: String)
signal room_joined(room_code: String, my_side: String)
signal peer_joined()
signal peer_ready_changed(ready: bool, peer_side: String)
signal start_countdown_received(seconds: float)
signal peer_disconnected(grace_seconds: float)
signal opponent_win_by_disconnect(winner: String, room_code: String)
signal start_match_received(seed: int, my_side: String, my_deck: Array[String], peer_deck: Array[String])
signal command_received(payload: Dictionary)
# —— V0.5 兼容：批量命令到达（ENet 下每次收到一条真实命令也广播长度 1 的数组）——
signal commands_batch_received(cmd_list: Array)
# —— V0.5 兼容：服务器命令日志应答——
signal commands_reply_received(from_tick: int, to_tick: int, matched_commands: Array)
# —— V0.5 兼容：服务器转发的对端命令请求——
signal request_commands_received(from_tick: int, to_tick: int, side_filter: String)
# —— V0.45：RTT 采样（PING/PONG，可选）——
signal ping_received(time_ms: int)

signal result_received(winner: String, room_code: String)
signal peer_rematch_received()
signal peer_left_received(who: String)
signal resume_battle_received(commands: Array, seed: int, my_side: String, my_deck: Array[String], peer_deck: Array[String])
signal resync_data_received(commands: Array, target_tick: int, base_tick: int, seed: int, my_side: String, my_deck: Array[String], peer_deck: Array[String])
signal server_error(message: String)

# 配置
var default_host: String = "64.90.30.36"
var default_port: int = Config.ENET_PORT
# V0.45 冗余发送开关保留为兼容项；新主线不再逐 tick 发 NO_OP，也不使用 COMMAND_BATCH。
var enable_redundancy: bool = false

# —— 断线重连：本端身份令牌（服务器在 ROOM_CREATED/ROOM_JOINED 时下发）——
var client_id: String = ""

# 运行时
var _enet: ENetMultiplayerPeer = null
var _running: bool = false
var _was_connected: bool = false
var _last_error: String = ""

# —— 兼容 V0.5：命令发送历史（保留接口，ENet 主线不使用冗余批量）——
var _send_history: Array = []
const HISTORY_MAX: int = 96


func reset_send_history() -> void:
	_send_history.clear()


# —— 连接控制 ——
func connect_to_server(host: String = "", port: int = 0) -> void:
	disconnect_from_server()
	var h: String = host if host != "" else default_host
	var p: int = port if port > 0 else default_port
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(h, p, Config.ENET_CHANNEL_COUNT)
	if err != OK:
		_last_error = "enet create_client failed: %d" % int(err)
		emit_signal("connection_failed", _last_error)
		return
	_enet = peer
	_running = true
	_was_connected = false
	_last_error = ""
	reset_send_history()
	# 轮询由 attach_to_node 的 Timer 或控制器 _process 驱动


func disconnect_from_server() -> void:
	_running = false
	_was_connected = false
	if _enet != null:
		_enet.close()
		_enet = null
	_last_error = ""
	reset_send_history()


func is_tcp_connected() -> bool:
	# 保留旧方法名以兼容 v01_game.gd；实现已是 ENet 连接状态。
	return is_enet_connected()


func is_enet_connected() -> bool:
	if _enet == null or not _running:
		return false
	return _enet.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


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
	# 心跳/在线探测走不可靠通道，减少可靠通道负载。
	_send_json({"type": "HEARTBEAT"}, Config.ENET_CHANNEL_UNRELIABLE, false)


func send_ready(ready_flag: bool, my_deck: Array[String]) -> void:
	var deck_strs: Array[String] = []
	for c in my_deck:
		deck_strs.append(String(c))
	_send_json({"type": "READY", "ready": ready_flag, "deck": deck_strs})


func send_command(cmd_dict: Dictionary) -> void:
	var cmd_type: String = String(cmd_dict.get("type", ""))
	if cmd_type == Command.CMD_PLAY_CARD:
		_send_packet(EnetProtocol.encode_play_card(cmd_dict), Config.ENET_CHANNEL_RELIABLE, true)
	elif cmd_type == Command.CMD_CHECKSUM:
		_send_packet(EnetProtocol.encode_checksum(cmd_dict), Config.ENET_CHANNEL_RELIABLE, true)
	elif cmd_type == Command.CMD_NO_OP:
		# V0.45 不再线上发送 NO_OP：缺省即 NO_OP。
		return
	else:
		# 兼容旧网络包装/其它控制类 payload，走 JSON。
		_send_json({"type": "COMMAND", "payload": cmd_dict})


func send_command_buffered(cmd_dict: Dictionary) -> void:
	_history_append(cmd_dict)
	send_command(cmd_dict)


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


func send_resync(target_tick: int, base_tick: int = 0) -> void:
	_send_json({"type": "RESYNC", "tick": target_tick, "base_tick": base_tick})


# —— V0.5 内部：把一条命令追加到历史环形缓冲（兼容接口）——
func _history_append(cmd_dict: Dictionary) -> void:
	_send_history.append(cmd_dict.duplicate(true))
	while _send_history.size() > HISTORY_MAX:
		_send_history.pop_front()


# —— 内部发送/轮询 ——
func _send_json(obj: Dictionary, channel: int = Config.ENET_CHANNEL_RELIABLE, reliable: bool = true) -> void:
	if not _running:
		return
	_send_packet(EnetProtocol.encode_json(obj), channel, reliable)


func _send_packet(data: PackedByteArray, channel: int, reliable: bool) -> void:
	if _enet == null or not is_enet_connected():
		return
	_enet.set_transfer_channel(channel)
	_enet.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	var err: Error = _enet.put_packet(data)
	if err != OK:
		_last_error = "enet put_packet failed: %d" % int(err)
		_handle_disconnected()


func poll() -> void:
	if not _running or _enet == null:
		return
	_enet.poll()
	var st: int = int(_enet.get_connection_status())
	if st == MultiplayerPeer.CONNECTION_CONNECTED:
		if not _was_connected:
			_was_connected = true
			emit_signal("connected_to_server")
		_drain_incoming()
	elif st == MultiplayerPeer.CONNECTION_DISCONNECTED:
		_handle_disconnected()


func _handle_disconnected() -> void:
	var had_connection: bool = _was_connected
	_running = false
	_was_connected = false
	if _enet != null:
		_enet.close()
		_enet = null
	reset_send_history()
	if had_connection:
		emit_signal("disconnected")
	else:
		emit_signal("connection_failed", _last_error if _last_error != "" else "connection closed")


func _drain_incoming() -> void:
	while _enet != null and _enet.get_available_packet_count() > 0:
		var channel: int = _enet.get_packet_channel()
		var data: PackedByteArray = _enet.get_packet()
		_handle_packet(data, channel)


func _handle_packet(data: PackedByteArray, channel: int) -> void:
	var parsed: Dictionary = EnetProtocol.parse_packet(data, channel)
	var kind: String = String(parsed.get("kind", "invalid"))
	match kind:
		"json":
			var payload: Variant = parsed.get("payload", {})
			if typeof(payload) == TYPE_DICTIONARY:
				_handle_json(Dictionary(payload))
		"command":
			var cmd: Variant = parsed.get("payload", {})
			if typeof(cmd) == TYPE_DICTIONARY:
				# 单条真实命令：兼容旧 command_received，也广播 batch 供 enqueue_command_batch 处理。
				emit_signal("command_received", Dictionary(cmd))
				emit_signal("commands_batch_received", [Dictionary(cmd)])
		"ping":
			emit_signal("ping_received", int(parsed.get("time_ms", 0)))
		_:
			pass


func _handle_json(msg: Dictionary) -> void:
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
		"START_COUNTDOWN":
			emit_signal("start_countdown_received", float(msg.get("seconds", 0.0)))
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
			var cmds: Array = []
			var resume_raw: Variant = msg.get("commands", [])
			if typeof(resume_raw) != TYPE_ARRAY:
				resume_raw = []
			for raw in resume_raw:
				if typeof(raw) == TYPE_DICTIONARY:
					cmds.append(Dictionary(raw))
			var deck_a: Array[String] = []
			for raw in msg.get("my_deck", []):
				deck_a.append(String(raw))
			var deck_b: Array[String] = []
			for raw in msg.get("peer_deck", []):
				deck_b.append(String(raw))
			emit_signal("resume_battle_received", cmds, int(msg.get("seed", 0)), String(msg.get("my_side", "")), deck_a, deck_b)
		"RESYNC_DATA":
			var rcmds: Array = []
			var resync_raw: Variant = msg.get("commands", [])
			if typeof(resync_raw) != TYPE_ARRAY:
				resync_raw = []
			for raw in resync_raw:
				if typeof(raw) == TYPE_DICTIONARY:
					rcmds.append(Dictionary(raw))
			var rdeck_a: Array[String] = []
			for raw in msg.get("my_deck", []):
				rdeck_a.append(String(raw))
			var rdeck_b: Array[String] = []
			for raw in msg.get("peer_deck", []):
				rdeck_b.append(String(raw))
			emit_signal("resync_data_received", rcmds, int(msg.get("target_tick", 0)), int(msg.get("base_tick", 0)), int(msg.get("seed", 0)), String(msg.get("my_side", "")), rdeck_a, rdeck_b)
		"ERROR":
			emit_signal("server_error", String(msg.get("message", "")))


func _dispatch_incoming_command(payload: Dictionary) -> void:
	if Command.is_network_wrapper(payload):
		var net_type: String = String(payload.get("_net_type", ""))
		match net_type:
			Command.NET_COMMAND_BATCH:
				var cmds: Array = Command.unwrap_commands(payload)
				emit_signal("commands_batch_received", cmds)
				if cmds.size() > 0 and typeof(cmds[cmds.size() - 1]) == TYPE_DICTIONARY:
					emit_signal("command_received", Dictionary(cmds[cmds.size() - 1]))
			Command.NET_REQUEST_COMMANDS:
				emit_signal("request_commands_received", int(payload.get("from_tick", 0)), int(payload.get("to_tick", 0)), String(payload.get("side", "")))
			Command.NET_COMMANDS_REPLY:
				var ft: int = int(payload.get("from_tick", 0))
				var tt: int = int(payload.get("to_tick", 0))
				var matched: Array = []
				var raw_commands: Variant = payload.get("commands", [])
				if typeof(raw_commands) != TYPE_ARRAY:
					raw_commands = []
				for raw in raw_commands:
					if typeof(raw) == TYPE_DICTIONARY:
						matched.append(Dictionary(raw))
				emit_signal("commands_reply_received", ft, tt, matched)
			_:
				pass
	else:
		emit_signal("command_received", payload)
		emit_signal("commands_batch_received", [payload])


# —— 可选：由持有方用 Node 挂 _process 每帧调用 poll；此处提供便利方法 ——
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
