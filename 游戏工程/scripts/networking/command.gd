# 玩家意图命令层：定义对局中所有可同步的输入命令。
# 本地玩家、远端玩家（联机）、脚本 Bot 都经此统一入口驱动 try_play_card。
# V0.4：坐标统一为 Q*1000 定点整数；CHECKSUM 用于 desync 检测。
# V0.5（弱网优化）：新增命令批量包装、冗余发送和命令请求/应答类型。
#
# 命令类型：
#   - PLAY_CARD：出牌（side + card_id + target_fp 坐标）
#   - NO_OP：空命令（某 tick 无操作时填充，保证双方每 tick 都有一条命令）
#   - CHECKSUM：状态校验和（每 DESYNC_CHECK_INTERVAL tick 双方各一条，用于比对）
#
# 弱网新增网络层包类型（只在 Client↔Server 之间使用，不入 scheduler）：
#   - COMMAND_BATCH：单次携带多条命令（含冗余历史），接收方去重后逐条入队
#   - REQUEST_COMMANDS：主动请求 [from_tick, to_tick] 范围的缺失命令
#   - COMMANDS_REPLY：对 REQUEST_COMMANDS 的应答，携带范围内命中的命令
#
# 序列化：用 Dictionary → JSON String（本地走 Dictionary，P3 网络层做 JSON 序列化）
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const Fp = preload("res://scripts/support/fp_math.gd")

# 命令类型常量（入 scheduler 的战斗命令）
const CMD_PLAY_CARD: String = "play_card"
const CMD_NO_OP: String = "no_op"
const CMD_CHECKSUM: String = "checksum"

# 网络层弱信封包类型（只在 Client↔Server 之间使用，不入 scheduler）
const NET_COMMAND_BATCH: String = "COMMAND_BATCH"
const NET_REQUEST_COMMANDS: String = "REQUEST_COMMANDS"
const NET_COMMANDS_REPLY: String = "COMMANDS_REPLY"


# 创建一条出牌命令。坐标为 Q*1000 定点整数。
static func play_card_command_fp(tick: int, side: String, card_id: String, target_x_fp: int, target_y_fp: int) -> Dictionary:
	return {
		"type": CMD_PLAY_CARD,
		"tick": tick,
		"side": side,
		"card_id": card_id,
		"target_x_fp": target_x_fp,
		"target_y_fp": target_y_fp
	}


# 兼容旧接口（float 坐标 → 自动转定点），供过渡期调用。
static func play_card_command(tick: int, side: String, card_id: String, target_x: float, target_y: float) -> Dictionary:
	return play_card_command_fp(tick, side, card_id, Fp.to_fp(target_x), Fp.to_fp(target_y))


# 创建一条空命令（占位，保证每 tick 双方各一条）。
static func no_op_command(tick: int, side: String) -> Dictionary:
	return {
		"type": CMD_NO_OP,
		"tick": tick,
		"side": side
	}


# 创建一条校验和命令（P2 desync 检测用）。
static func checksum_command(tick: int, side: String, checksum_value: int) -> Dictionary:
	return {
		"type": CMD_CHECKSUM,
		"tick": tick,
		"side": side,
		"checksum": checksum_value
	}


# —— V0.5 弱网：命令批量包装（每次发送附带最近 N 条冗余历史）——
# 入参：
#   primary_cmd: 本次要发送的主命令（Dictionary）
#   history_cmds: 最近发送的命令历史数组（Array[Dictionary]，按时间正序，最新在尾部）
#   redundancy: 需要附带的冗余条数（取 history_cmds 的最后 redundancy 条）
# 返回：可直接交给 network_client 发送的 COMMAND_BATCH Dictionary
# 说明：接收方收到 batch 后应遍历 batch["commands"]，逐条去重入队 scheduler，
#       真实命令（PLAY_CARD）会覆盖同 tick 同 side 的 NO_OP 占位，不影响确定性。
static func wrap_command_batch(primary_cmd: Dictionary, history_cmds: Array, redundancy: int) -> Dictionary:
	var batch: Array = []
	# 先加冗余历史（去重：同一 tick 同 side 只留最后一条；因为 primary_cmd 是最新，最后再加它）
	var seen: Dictionary = {}  # key = "<tick>|<side>"，value = true
	var start_idx: int = max(0, history_cmds.size() - redundancy)
	for i in range(start_idx, history_cmds.size()):
		var h: Dictionary = history_cmds[i]
		var t: int = int(h.get("tick", 0))
		var s: String = String(h.get("side", ""))
		var key: String = "%d|%s" % [t, s]
		if seen.has(key):
			continue
		seen[key] = true
		batch.append(h)
	# 最后加主命令（保证覆盖同 tick 同 side 的历史冗余）
	var pt: int = int(primary_cmd.get("tick", 0))
	var ps: String = String(primary_cmd.get("side", ""))
	var pkey: String = "%d|%s" % [pt, ps]
	if not seen.has(pkey):
		batch.append(primary_cmd)
	else:
		# 已经加过同 tick/side 的历史 → 用最新的 primary_cmd 替换末尾那条
		# （简单起见直接 append；scheduler.enqueue_command 同 key 后写覆盖前写，最终效果一致）
		batch.append(primary_cmd)
	return {
		"_net_type": NET_COMMAND_BATCH,
		"commands": batch
	}


# 判断一个网络 payload 是否是 COMMAND_BATCH 包装。
static func is_command_batch(payload: Dictionary) -> bool:
	return String(payload.get("_net_type", "")) == NET_COMMAND_BATCH


# 从 COMMAND_BATCH 中取出所有命令（返回 Array[Dictionary]）。
# 若 payload 不是 batch，则返回 [payload]（兼容旧协议：单条命令即长度为 1 的 batch）。
static func unwrap_commands(payload: Dictionary) -> Array:
	if is_command_batch(payload):
		var arr: Array = payload.get("commands", [])
		if typeof(arr) == TYPE_ARRAY:
			return arr
		return []
	return [payload]


# —— V0.5 弱网：主动请求缺失命令 / 应答 ——
# 请求 [from_tick, to_tick] 范围内，指定 side 的所有命令（side 留空表示请求双方）。
static func request_commands(from_tick: int, to_tick: int, side_filter: String = "") -> Dictionary:
	return {
		"_net_type": NET_REQUEST_COMMANDS,
		"from_tick": from_tick,
		"to_tick": to_tick,
		"side": side_filter
	}


# 对 REQUEST_COMMANDS 的应答：携带命中的命令数组。
static func commands_reply(request_ref: Dictionary, matched_cmds: Array) -> Dictionary:
	return {
		"_net_type": NET_COMMANDS_REPLY,
		"from_tick": int(request_ref.get("from_tick", 0)),
		"to_tick": int(request_ref.get("to_tick", 0)),
		"side": String(request_ref.get("side", "")),
		"commands": matched_cmds
	}


# 判断是否是网络层弱信封包（不入 scheduler，需要单独处理）。
static func is_network_wrapper(payload: Dictionary) -> bool:
	return payload.has("_net_type")


# 从命令中提取定点坐标（返回 Dictionary {x:int, y:int}）。
static func command_target_fp(cmd: Dictionary) -> Dictionary:
	return {
		"x": int(cmd.get("target_x_fp", 0)),
		"y": int(cmd.get("target_y_fp", 0))
	}


# 兼容旧接口：提取 float Vector2（仅 Bot / 非战斗判定层使用）。
static func command_target(cmd: Dictionary) -> Vector2:
	var fp: Dictionary = command_target_fp(cmd)
	return Vector2(Fp.from_fp(int(fp.get("x", 0))), Fp.from_fp(int(fp.get("y", 0))))


# 打印命令摘要（调试/日志用）。
static func describe(cmd: Dictionary) -> String:
	var t: String = String(cmd.get("type", "?"))
	var tk: int = int(cmd.get("tick", -1))
	var side: String = String(cmd.get("side", "?"))
	if t == CMD_PLAY_CARD:
		var fx: float = Fp.from_fp(int(cmd.get("target_x_fp", 0)))
		var fy: float = Fp.from_fp(int(cmd.get("target_y_fp", 0)))
		return "T%d %s PLAY %s (%.1f,%.1f)" % [tk, side, String(cmd.get("card_id", "?")), fx, fy]
	if t == CMD_CHECKSUM:
		return "T%d %s CHECKSUM=%d" % [tk, side, int(cmd.get("checksum", 0))]
	return "T%d %s NOOP" % [tk, side]
