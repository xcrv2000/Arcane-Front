# 锁步调度器（V0.4 P2 完整化）。
# 职责：
#   - 维护当前模拟 tick（TICK_RATE Hz）
#   - 维护命令队列（按 tick 索引，每 tick 双方各一条命令）
#   - 输入延迟：玩家/远端/Bot 的命令标注到 tick_now + INPUT_DELAY_TICKS 后执行
#   - 累积器：帧 delta → 整数 tick 推进
#   - P2：等待对端命令（strict_wait 模式）、checksum 比对、desync 检测与暂停
#
# 使用模式：
#   - 本地单机（strict_wait=false）：缺任一方命令自动填 NO_OP，不暂停，Bot 不需要预先送入
#   - 联机（strict_wait=true）：缺任一方命令则 consume 返回空数组，调用方不推进 tick，模拟暂停等待
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const Command = preload("res://scripts/networking/command.gd")

# 调度配置
var strict_wait: bool = false  # true=联机等待模式；false=本地Bot兼容模式
var sides: Array[String] = [Config.PLAYER, Config.BOT]  # 参与方列表，联机可改为 [player, remote_bot_placeholder]

# 运行时状态
var current_tick: int = 0  # 已执行到的 tick（下一次执行 current_tick + 1）
var accumulator: float = 0.0  # 累积的亚 tick 时间
var ticks_this_frame: int = 0  # 最近 1 帧推了多少 tick（供控制器参考）

# tick → {side → cmd}：已收到但尚未执行的命令（PLAY_CARD / NO_OP / CHECKSUM）
var pending_commands: Dictionary = {}

# tick → {side → checksum_value}：已收到的 checksum，用于 desync 比对
var received_checksums: Dictionary = {}

# 状态标志
var paused: bool = false           # 命令缺失导致的暂停
var paused_reason: String = ""     # 暂停原因（调试显示）
var desynced: bool = false         # desync 发生标志
var desync_info: Dictionary = {}   # desync 详情 {tick, side_a, cs_a, side_b, cs_b}
var waiting_for_tick: int = -1     # 正在等待哪个 tick 的命令


# 设置参与方列表（联机模式下调用）
func set_sides(side_list: Array[String]) -> void:
	sides = side_list.duplicate()


# 推入一条命令到对应 tick（自动处理输入延迟）。
func enqueue_command(cmd: Dictionary) -> void:
	var t: int = int(cmd.get("tick", 0))
	var side: String = String(cmd.get("side", ""))
	var cmd_type: String = String(cmd.get("type", ""))
	# CHECKSUM 命令只存入 received_checksums，不入队 pending_commands
	# （避免覆盖同 tick 的 PLAY_CARD / NO_OP 命令导致 desync）
	if cmd_type == "checksum":
		if not received_checksums.has(t):
			received_checksums[t] = {}
		received_checksums[t][side] = int(cmd.get("checksum", 0))
		return
	if not pending_commands.has(t):
		pending_commands[t] = {}
	pending_commands[t][side] = cmd


# 远端命令直接入队（网络层收到时已携带正确的 tick，无需再偏移）。
func enqueue_command_direct(cmd: Dictionary) -> void:
	enqueue_command(cmd)


# 计算某条命令应该落到的执行 tick（NOW + INPUT_DELAY）。
func target_execution_tick() -> int:
	return current_tick + Config.INPUT_DELAY_TICKS


# 累积 delta 时间，返回本帧可推进的 tick 数上限（调用方需配合 consume_tick_commands 的返回）
func accumulate(delta: float) -> int:
	accumulator += delta
	var count: int = 0
	while accumulator >= Config.TICK_DT:
		accumulator -= Config.TICK_DT
		count += 1
	ticks_this_frame = count
	return count


# 判断某 tick 的双方 PLAY_CARD/NO_OP 是否已齐（strict_wait 模式用）
func has_tick_commands(tick: int) -> bool:
	var tick_table: Dictionary = pending_commands.get(tick, {})
	for side in sides:
		# 只要该 side 存在任意命令（PLAY_CARD/NO_OP/CHECKSUM 任意一种即可，或者混合多命令以最后一条覆盖）
		if not tick_table.has(side):
			waiting_for_tick = tick
			return false
	waiting_for_tick = -1
	return true


# 判断某 tick 是否已有指定 side 的命令
func has_side_command_for_tick(tick: int, side: String) -> bool:
	var tick_table: Dictionary = pending_commands.get(tick, {})
	return tick_table.has(side)


# 取出下一个 tick 的双方命令。
# - strict_wait=true：如果缺任一方命令则返回空数组 []，调用方不得推进该 tick（模拟暂停等待）
# - strict_wait=false：缺命令填 NO_OP，永远返回有效列表
func consume_tick_commands(tick: int) -> Array[Dictionary]:
	if strict_wait and not has_tick_commands(tick):
		paused = true
		paused_reason = "等待 %s 的 T%d 命令" % [_missing_sides_for_tick(tick), tick]
		return []
	paused = false
	paused_reason = ""

	var result: Array[Dictionary] = []
	var tick_table: Dictionary = pending_commands.get(tick, {})
	for side in sides:
		if tick_table.has(side):
			result.append(tick_table[side])
		else:
			# 非严格模式：自动填 NO_OP
			result.append(Command.no_op_command(tick, side))
	if pending_commands.has(tick):
		pending_commands.erase(tick)
	return result


# 检查某 tick 的双方 CHECKSUM 是否一致。
# - 返回 {ok:bool, mismatch:Dictionary or null}
# - 双方均未发送 checksum 视为 ok（间隔未到）
func verify_checksum_for_tick(tick: int) -> Dictionary:
	if not (tick > 0 and tick % Config.DESYNC_CHECK_INTERVAL == 0):
		return {"ok": true, "mismatch": null}
	if not received_checksums.has(tick):
		return {"ok": true, "mismatch": null}
	var cs_tbl: Dictionary = received_checksums[tick]
	if cs_tbl.size() < sides.size():
		# 尚未收齐，等下轮
		return {"ok": true, "mismatch": null}
	var cs_values: Array = []
	for s in sides:
		cs_values.append({"side": s, "cs": int(cs_tbl.get(s, 0))})
	# 两两比较
	for i in range(cs_values.size() - 1):
		for j in range(i + 1, cs_values.size()):
			if int(cs_values[i]["cs"]) != int(cs_values[j]["cs"]):
				desynced = true
				desync_info = {
					"tick": tick,
					"side_a": cs_values[i]["side"],
					"cs_a": int(cs_values[i]["cs"]),
					"side_b": cs_values[j]["side"],
					"cs_b": int(cs_values[j]["cs"])
				}
				return {"ok": false, "mismatch": desync_info}
	# 校验通过：收齐且一致后清除本条 checksum 缓存，减少内存
	received_checksums.erase(tick)
	return {"ok": true, "mismatch": null}


# 工具：列出某 tick 缺命令的参与方列表字符串
func _missing_sides_for_tick(tick: int) -> String:
	var tick_table: Dictionary = pending_commands.get(tick, {})
	var missing: Array[String] = []
	for side in sides:
		if not tick_table.has(side):
			missing.append(side)
	return ", ".join(missing)


# 清除累积器与 tick（对局重开用）。
func reset() -> void:
	current_tick = 0
	accumulator = 0.0
	pending_commands.clear()
	received_checksums.clear()
	ticks_this_frame = 0
	paused = false
	paused_reason = ""
	desynced = false
	desync_info = {}
	waiting_for_tick = -1
