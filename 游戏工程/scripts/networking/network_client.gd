# V0.4 (P3) 联机客户端网络层。
# 职责：
#   - 连接/断开 TCP 中继服务器（协议：JSON Lines，每包 \n 分隔）
#   - 发送房间请求（CREATE_ROOM / JOIN_ROOM / READY / COMMAND / RESULT）
#   - 解析服务器推送事件并通过 Signal 通知上层 UI 与控制器
#
# 用法：
#   var nc = NetworkClient.new()
#   nc.connected_to_server.connect(...)
#   nc.room_created.connect(...)
#   nc.start_match_received.connect(func(seed,my_side,my_deck,peer_deck): ...)
#   nc.command_received.connect(func(cmd_dict): scheduler.enqueue_command(cmd_dict))
#   nc.connect_to_server(host, port)
#   ...
#   nc.send_command(my_command_dict)
#
# 注意：本类纯网络 IO，不持有对局逻辑状态；scheduler/simulator 由控制器协调。
extends RefCounted

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
signal result_received(winner: String, room_code: String)
signal server_error(message: String)

# 配置
var default_host: String = "127.0.0.1"
var default_port: int = 8765

# 运行时
var _tcp: StreamPeerTCP = StreamPeerTCP.new()
var _recv_buf: PackedByteArray = PackedByteArray()
var _running: bool = false
var _last_error: String = ""


# —— 连接控制 ——
func connect_to_server(host: String = "", port: int = 0) -> void:
	disconnect_from_server()
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
	# 轮询由 attach_to_node 的 Timer 驱动


func disconnect_from_server() -> void:
	_running = false
	# 轮询由 attach_to_node 的 Timer 驱动，无需手动停止
	if _tcp != null:
		_tcp.disconnect_from_host()
	_recv_buf.clear()


func is_tcp_connected() -> bool:
	if _tcp == null:
		return false
	return _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED


# —— 房间与对局请求（客户端 → 服务器）——
func send_create_room() -> void:
	_send_json({"type": "CREATE_ROOM"})


func send_join_room(room_code: String) -> void:
	_send_json({"type": "JOIN_ROOM", "room_code": room_code.strip_edges().to_upper()})


func send_ready(ready_flag: bool, my_deck: Array[String]) -> void:
	var deck_strs: Array[String] = []
	for c in my_deck:
		deck_strs.append(String(c))
	_send_json({"type": "READY", "ready": ready_flag, "deck": deck_strs})


# 把战斗命令（Lockstep 层的 Dictionary，含 PLAY_CARD/NO_OP/CHECKSUM）转发给服务器
func send_command(cmd_dict: Dictionary) -> void:
	_send_json({"type": "COMMAND", "payload": cmd_dict})


func send_result(winner: String, room_code: String) -> void:
	_send_json({"type": "RESULT", "winner": winner, "room_code": room_code})


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
			emit_signal("room_created", String(msg.get("room_code", "")), String(msg.get("my_side", "host")))
		"ROOM_JOINED":
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
			emit_signal("start_match_received", int(msg.get("seed", 0)), String(msg.get("my_side", "host")), deck_a, deck_b)
		"COMMAND":
			var payload: Variant = msg.get("payload", {})
			if typeof(payload) == TYPE_DICTIONARY:
				emit_signal("command_received", Dictionary(payload))
		"RESULT":
			emit_signal("result_received", String(msg.get("winner", "")), String(msg.get("room_code", "")))
		"ERROR":
			emit_signal("server_error", String(msg.get("message", "")))


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
