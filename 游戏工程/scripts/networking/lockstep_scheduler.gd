# 锁步调度器（V0.4 P2 完整化 + V0.5 弱网优化）。
# 职责：
#   - 维护当前模拟 tick（TICK_RATE Hz）
#   - 维护命令队列（按 tick 索引，每 tick 双方各一条命令）
#   - 输入延迟：玩家/远端/Bot 的命令标注到 tick_now + INPUT_DELAY_TICKS 后执行
#   - 累积器：帧 delta → 整数 tick 推进
#   - P2：等待对端命令（strict_wait 模式）、checksum 比对、desync 检测与暂停
#   - V0.5 弱网：批量命令入队、命令缺失统计、抖动测量、自适应输入延迟
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

# —— V0.5 自适应输入延迟（可运行时动态调整，默认=Config.INPUT_DELAY_TICKS）——
var current_input_delay_ticks: int = Config.INPUT_DELAY_TICKS

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

# —— V0.5 弱网：命令缺失统计 ——
# 连续多少个 tick 因为缺命令而未推进（用于触发主动请求补全）
var consecutive_wait_ticks: int = 0
# 上次发送命令请求的 tick（用于冷却控制）
var last_request_tick: int = -1

# —— V0.5 弱网：抖动测量（命令到达延迟统计）——
# 记录命令到达时，该命令的 tick 与 current_tick 的差值（"提前量"，越大表示命令到得越早越从容）
# 单位：tick。负值表示命令"迟到"（本该 T+0 执行的命令到 T+X 才收到）
var arrival_ahead_history: Array = []  # 环形/滑动窗口，存 int
# 统计指标（由 _update_jitter_stats 每 tick 更新）
var jitter_avg_ahead_ticks: float = 0.0  # 平均提前量 tick（越大越好，>0=从容，<0=迟到）
var jitter_worst_ahead_ticks: int = 999  # 窗口内最小提前量（最差情况）
var jitter_p95_ahead_ticks: float = 0.0  # 95 分位提前量

# —— V0.5 回滚重放：状态快照环形缓冲 + 命令执行日志 ——
# tick → {"sim": Dictionary, "task": Dictionary}：每 tick 执行后保存的状态快照
var _state_snapshots: Dictionary = {}
# tick → Array[Dictionary]：该 tick 实际执行的命令列表（用于回滚后重放）
var _consumed_commands: Dictionary = {}
const SNAPSHOT_BUFFER_SIZE: int = 120  # 保留最近 2 秒的快照（60Hz × 2s）
# 回滚信号：当 enqueue_command_batch 发现迟到的真实命令时设置
var rollback_pending: bool = false
var rollback_tick: int = -1
var rollback_cmd: Dictionary = {}
# 迟到命令计数（用于自适应延迟：有迟到→增大 input_delay）
var late_arrival_count: int = 0


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
	# —— V0.5：记录命令到达提前量（用于抖动统计）——
	# 仅统计对端命令（本方命令在 enqueue 时总是"刚好"，不代表网络状况）
	# 这里我们无法判断 side 归属，统一记录，由上层在 consume 时更精确统计。
	_record_arrival_ahead(t, side)


# —— V0.5：批量入队一组命令（COMMAND_BATCH 解包后使用）——
# 返回值：实际新入队的命令条数（去重后）。
# V0.5 回滚增强：跳过已过期的 NO_OP/CHECKSUM；对迟到的 play_card 触发回滚信号。
func enqueue_command_batch(cmd_list: Array) -> int:
	var added: int = 0
	for raw in cmd_list:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var cmd: Dictionary = raw
		var t: int = int(cmd.get("tick", 0))
		var side: String = String(cmd.get("side", ""))
		var cmd_type: String = String(cmd.get("type", ""))
		if cmd_type == "":
			continue

		# —— V0.5 回滚：跳过已过期的 NO_OP（tick 已过，不会被消费，不记录抖动）——
		if t <= current_tick and cmd_type == Command.CMD_NO_OP:
			continue

		# —— V0.5 回滚：跳过已过期的 CHECKSUM（校验点已过）——
		if t <= current_tick and cmd_type == Command.CMD_CHECKSUM:
			continue

		# —— V0.5 回滚：迟到的真实命令（play_card）——
		# 该 tick 已被消费（用了 NO_OP 占位），真实命令现在才到。
		# 检查 consumed_commands 中该 tick/side 是否为 NO_OP → 是则触发回滚。
		if t <= current_tick and cmd_type == Command.CMD_PLAY_CARD:
			late_arrival_count += 1
			if _consumed_commands.has(t):
				var cmds_at_t: Array = _consumed_commands[t]
				for c in cmds_at_t:
					if String(c.get("side", "")) == side and String(c.get("type", "")) == Command.CMD_NO_OP:
						# 发现该 tick 的 NO_OP 被消费了 → 触发回滚
						rollback_pending = true
						rollback_tick = t
						rollback_cmd = cmd
						break
			continue  # 不入队（由控制器回滚处理）

		# —— 正常去重逻辑 ——
		if cmd_type == "checksum":
			var val_new: int = int(cmd.get("checksum", 0))
			if received_checksums.has(t) and received_checksums[t].has(side):
				if int(received_checksums[t][side]) == val_new:
					continue  # 完全相同，跳过
		else:
			if pending_commands.has(t) and pending_commands[t].has(side):
				var existing: Dictionary = pending_commands[t][side]
				var existing_type: String = String(existing.get("type", ""))
				if existing_type == Command.CMD_PLAY_CARD and cmd_type == Command.CMD_NO_OP:
					continue  # 已有 PLAY_CARD，忽略冗余到达的 NO_OP
				if existing_type == cmd_type and cmd_type == Command.CMD_NO_OP:
					continue  # 都是 NO_OP，跳过
		enqueue_command(cmd)
		added += 1
	return added


# 远端命令直接入队（网络层收到时已携带正确的 tick，无需再偏移）。
func enqueue_command_direct(cmd: Dictionary) -> void:
	enqueue_command(cmd)


# 计算某条命令应该落到的执行 tick（NOW + 自适应 INPUT_DELAY）。
func target_execution_tick() -> int:
	return current_tick + current_input_delay_ticks


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


# —— V0.5：列出指定范围内对端还缺哪些 tick 的命令（用于 REQUEST_COMMANDS）——
# peer_side: 对端阵营（如 Config.BOT）
# from_tick, to_tick: 闭区间
# 返回：Array[int]，缺命令的 tick 列表（按升序）
func missing_ticks_for_side(peer_side: String, from_tick: int, to_tick: int) -> Array:
	var result: Array = []
	var t_start: int = max(1, from_tick)
	var t_end: int = to_tick
	for t in range(t_start, t_end + 1):
		if not has_side_command_for_tick(t, peer_side):
			result.append(t)
	return result


# 取出下一个 tick 的双方命令。
# - strict_wait=true：如果缺任一方命令则返回空数组 []，调用方不得推进该 tick（模拟暂停等待）
# - strict_wait=false：缺命令填 NO_OP，永远返回有效列表
func consume_tick_commands(tick: int) -> Array[Dictionary]:
	if strict_wait and not has_tick_commands(tick):
		paused = true
		consecutive_wait_ticks += 1  # V0.5：累计等待
		paused_reason = "等待 %s 的 T%d 命令（已等 %d tick）" % [_missing_sides_for_tick(tick), tick, consecutive_wait_ticks]
		return []
	paused = false
	paused_reason = ""
	consecutive_wait_ticks = 0  # V0.5：推进成功，清零等待计数

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
	# V0.5 回滚：保存已消费命令（用于迟到真实命令时回滚重放）
	_consumed_commands[tick] = result.duplicate(true)
	# V0.5：每成功推进一个 tick，更新抖动统计
	_update_jitter_stats()
	# V0.5：根据抖动状况尝试调整输入延迟
	_adapt_input_delay()
	return result


# —— V0.5：是否该触发主动命令请求？——
# 满足：连续等待 >= MAX_WAIT_TICKS_BEFORE_REQUEST，且距上次请求已过 COOLDOWN
func should_request_missing_commands() -> bool:
	if consecutive_wait_ticks < Config.MAX_WAIT_TICKS_BEFORE_REQUEST:
		return false
	if last_request_tick > 0 and (current_tick - last_request_tick) < Config.COMMAND_REQUEST_COOLDOWN_TICKS:
		return false
	return true


# —— V0.5：标记"已发送一次命令请求"（更新冷却计时器）——
func mark_command_request_sent() -> void:
	last_request_tick = current_tick


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
	# V0.5 回滚：校验通过时清除 desync 标志（回滚修正后状态已一致）
	received_checksums.erase(tick)
	desynced = false
	desync_info = {}
	return {"ok": true, "mismatch": null}


# 工具：列出某 tick 缺命令的参与方列表字符串
func _missing_sides_for_tick(tick: int) -> String:
	var tick_table: Dictionary = pending_commands.get(tick, {})
	var missing: Array[String] = []
	for side in sides:
		if not tick_table.has(side):
			missing.append(side)
	return ", ".join(missing)


# —— V0.5：记录命令到达提前量 ——
# V0.5 回滚修复：跳过 ahead < 0 的过期命令，避免冗余历史污染抖动统计
func _record_arrival_ahead(cmd_tick: int, _side: String) -> void:
	if cmd_tick <= 0:
		return
	var ahead: int = cmd_tick - current_tick
	if ahead < 0:
		return  # 过期命令不计入抖动统计
	arrival_ahead_history.append(ahead)
	while arrival_ahead_history.size() > Config.JITTER_WINDOW_SIZE:
		arrival_ahead_history.pop_front()


# —— V0.5：更新抖动统计指标（平均/最差/95分位提前量）——
func _update_jitter_stats() -> void:
	var n: int = arrival_ahead_history.size()
	if n == 0:
		jitter_avg_ahead_ticks = 0.0
		jitter_worst_ahead_ticks = 999
		jitter_p95_ahead_ticks = 0.0
		return
	var sum: int = 0
	var worst: int = 999999
	var sorted: Array = []
	for v in arrival_ahead_history:
		var iv: int = int(v)
		sum += iv
		if iv < worst:
			worst = iv
		sorted.append(iv)
	sorted.sort()
	jitter_avg_ahead_ticks = float(sum) / float(n)
	jitter_worst_ahead_ticks = worst
	# 95 分位：取排序后第 ceil(n*0.05) 个位置（因为提前量越小越差，取低分位的下限）
	var p95_idx: int = max(0, int(ceil(float(n) * 0.05)) - 1)
	if p95_idx >= 0 and p95_idx < sorted.size():
		jitter_p95_ahead_ticks = float(int(sorted[p95_idx]))
	else:
		jitter_p95_ahead_ticks = float(worst)


# —— V0.5：根据抖动状况自适应调整输入延迟 ——
# 逻辑：
#   1) 若 p95_ahead < 0（命令开始迟到）或 worst < -1（最差情况已经晚 1 tick 以上）：
#      提高输入延迟 2 tick（扩大窗口，给网络更多缓冲）
#   2) 若 avg_ahead 持续高于 2 * current_input_delay（命令总是到得太早，浪费手感）：
#      降低输入延迟 1 tick
#   3) 限制在 [INPUT_DELAY_MIN_TICKS, INPUT_DELAY_MAX_TICKS] 范围内
func _adapt_input_delay() -> void:
	# 规则 0（最高优先级）：有迟到真实命令 → 立即加延迟（不管样本量）
	if late_arrival_count > 0:
		current_input_delay_ticks = min(Config.INPUT_DELAY_MAX_TICKS, current_input_delay_ticks + 2)
		late_arrival_count = 0
		return
	# 样本太少不调（至少半窗口）
	if arrival_ahead_history.size() < (Config.JITTER_WINDOW_SIZE / 2):
		return
	var clamped_p95: float = jitter_p95_ahead_ticks
	var clamped_worst: int = jitter_worst_ahead_ticks
	# 规则 1：出现迟到 → 加延迟
	if clamped_p95 < 0.0 or clamped_worst < -1:
		current_input_delay_ticks = min(Config.INPUT_DELAY_MAX_TICKS, current_input_delay_ticks + 2)
		return
	# 规则 2：总是过早 → 减延迟（手感优先）
	var ideal_avg: float = float(current_input_delay_ticks)
	if jitter_avg_ahead_ticks > ideal_avg * 2.0 and current_input_delay_ticks > Config.INPUT_DELAY_MIN_TICKS:
		current_input_delay_ticks -= 1


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
	# V0.5 弱网状态重置
	consecutive_wait_ticks = 0
	last_request_tick = -1
	arrival_ahead_history.clear()
	jitter_avg_ahead_ticks = 0.0
	jitter_worst_ahead_ticks = 999
	jitter_p95_ahead_ticks = 0.0
	current_input_delay_ticks = Config.INPUT_DELAY_TICKS
	# V0.5 回滚状态重置
	_state_snapshots.clear()
	_consumed_commands.clear()
	rollback_pending = false
	rollback_tick = -1
	rollback_cmd = {}
	late_arrival_count = 0


# —— V0.5 回滚：快照管理接口 ——

# 保存某 tick 执行后的状态快照（由控制器在每 tick 推进后调用）
func save_state_snapshot(tick: int, sim_snap: Dictionary, task_snap: Dictionary) -> void:
	_state_snapshots[tick] = {"sim": sim_snap, "task": task_snap}
	# 修剪旧快照（只保留最近 SNAPSHOT_BUFFER_SIZE 个 tick）
	while _state_snapshots.size() > SNAPSHOT_BUFFER_SIZE:
		var oldest: int = _state_snapshots.keys().min()
		_state_snapshots.erase(oldest)
		_consumed_commands.erase(oldest)


# 获取某 tick 的状态快照（用于回滚恢复）
func get_state_snapshot(tick: int) -> Variant:
	return _state_snapshots.get(tick, null)


# 替换已消费命令记录中某 tick/side 的命令（NO_OP → 迟到的 play_card）
func replace_consumed_command(tick: int, new_cmd: Dictionary) -> void:
	if not _consumed_commands.has(tick):
		return
	var cmds: Array = _consumed_commands[tick]
	var side: String = String(new_cmd.get("side", ""))
	for i in range(cmds.size()):
		if String(cmds[i].get("side", "")) == side:
			cmds[i] = new_cmd.duplicate(true)
			break


# 获取某 tick 已消费的命令列表（用于回滚重放）
func get_consumed_commands(tick: int) -> Array:
	return _consumed_commands.get(tick, [])


# 清除回滚信号（控制器处理完毕后调用）
func clear_rollback_state() -> void:
	rollback_pending = false
	rollback_tick = -1
	rollback_cmd = {}
