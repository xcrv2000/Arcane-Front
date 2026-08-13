# 玩家意图命令层：定义对局中所有可同步的输入命令。
# 本地玩家、远端玩家（联机）、脚本 Bot 都经此统一入口驱动 try_play_card。
# V0.4：坐标统一为 Q*1000 定点整数；CHECKSUM 用于 desync 检测。
#
# 命令类型：
#   - PLAY_CARD：出牌（side + card_id + target_fp 坐标）
#   - NO_OP：空命令（某 tick 无操作时填充，保证双方每 tick 都有一条命令）
#   - CHECKSUM：状态校验和（每 DESYNC_CHECK_INTERVAL tick 双方各一条，用于比对）
#
# 序列化：用 Dictionary → JSON String（本地走 Dictionary，P3 网络层做 JSON 序列化）
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const Fp = preload("res://scripts/support/fp_math.gd")

# 命令类型常量
const CMD_PLAY_CARD: String = "play_card"
const CMD_NO_OP: String = "no_op"
const CMD_CHECKSUM: String = "checksum"


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
