# 任务与进化系统：追踪局内任务进度，任务完成后自动且不可避地进化卡牌。
# 职责边界（V0.2 已确认）：
#   - 每张初版卡默认 1 个任务，暂不做局外配置；
#   - 先做 1 层进化，任务进度仅在局内生效；
#   - 任务完成后，卡牌后续使用读取进化后的临时定义，场上已打出单位不受影响。
#
# 依赖：卡牌数据（card_catalog）、模拟器引用（用于读取 battle_time、写入事件与统计）。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const MapMath = preload("res://scripts/support/map_math.gd")

var cards: Array[Dictionary] = []
var task_states: Dictionary = {}
var simulator: RefCounted = null  # BattleSimulator 引用，运行时由控制器注入


# 注入卡牌数据与模拟器引用。在控制器 _ready 中调用一次。
func setup(card_list: Array[Dictionary], sim: RefCounted) -> void:
	cards = card_list
	simulator = sim


# 对局开始时初始化双方任务状态。
func initialize(player_deck_ids: Array, bot_deck_ids: Array) -> void:
	task_states = {
		Config.PLAYER: {},
		Config.BOT: {}
	}
	for card_id in player_deck_ids:
		_add_task_state(Config.PLAYER, String(card_id))
	for card_id in bot_deck_ids:
		_add_task_state(Config.BOT, String(card_id))


# 按 id 查找卡牌定义。
func card_by_id(card_id: String) -> Dictionary:
	for card in cards:
		if card["id"] == card_id:
			return card
	return {}


# 为某阵营的某张卡建立任务状态（若无 task 字段则跳过）。
func _add_task_state(side: String, card_id: String) -> void:
	var card: Dictionary = card_by_id(card_id)
	if card.size() == 0 or not card.has("task"):
		return
	var side_tasks: Dictionary = task_states[side]
	side_tasks[card_id] = {
		"progress": 0.0,
		"completed": false,
		"evolved": false,
		"recent_uses": [],
		"unit_kills": {},
		"play_count": 0,
		"completed_at_time": -1.0
	}


# 解析当前生效的卡牌定义：未进化返回基础卡副本，已进化返回应用 overrides 后的副本。
# 注意：返回的是深拷贝，调用方可安全修改；id 保持为传入的 card_id。
func active_card_by_id(side: String, card_id: String) -> Dictionary:
	var base_card: Dictionary = card_by_id(card_id)
	if base_card.size() == 0:
		return {}
	var active_card: Dictionary = base_card.duplicate(true)
	active_card["id"] = card_id
	active_card["base_name"] = base_card["name"]
	active_card["evolved"] = false
	if not is_evolved(side, card_id):
		return active_card

	var evolution: Dictionary = base_card.get("evolution", {})
	active_card["evolved"] = true
	active_card["evolved_id"] = String(evolution.get("id", card_id))
	active_card["name"] = String(evolution.get("name", base_card["name"]))
	active_card["short_name"] = String(evolution.get("short_name", base_card["short_name"]))
	var overrides: Dictionary = evolution.get("overrides", {})
	for raw_key in overrides.keys():
		active_card[raw_key] = overrides[raw_key]
	return active_card


# 该阵营的该卡是否已完成进化。
func is_evolved(side: String, card_id: String) -> bool:
	if not task_states.has(side):
		return false
	var side_tasks: Dictionary = task_states[side]
	if not side_tasks.has(card_id):
		return false
	return bool(side_tasks[card_id].get("evolved", false))


# 返回某张卡当前任务进度的可读文本，供 UI 显示。
func task_progress_text(side: String, card_id: String) -> String:
	if is_evolved(side, card_id):
		return "已进化"
	var state: Dictionary = task_state(side, card_id)
	var card: Dictionary = card_by_id(card_id)
	if state.size() == 0 or card.size() == 0 or not card.has("task"):
		return "无任务"
	var task: Dictionary = card["task"]
	var target_text: String = String(task.get("target_text", str(int(task.get("target", 1)))))
	var progress: float = float(state.get("progress", 0.0))
	if String(task.get("type", "")) == "mana_reached":
		return "%s %.1f/%s" % [String(task.get("progress_label", "进度")), progress, target_text]
	return "%s %d/%s" % [String(task.get("progress_label", "进度")), int(floor(progress)), target_text]


# 取某阵营某卡的任务状态（不存在返回空字典）。
func task_state(side: String, card_id: String) -> Dictionary:
	if not task_states.has(side):
		return {}
	var side_tasks: Dictionary = task_states[side]
	if not side_tasks.has(card_id):
		return {}
	return side_tasks[card_id]


# 每帧检查 mana_reached 类任务：以当前费用作为进度。
func check_mana(side: String, current_mana: float) -> void:
	if not task_states.has(side):
		return
	var side_tasks: Dictionary = task_states[side]
	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = card_by_id(card_id).get("task", {})
		if String(task.get("type", "")) != "mana_reached":
			continue
		state["progress"] = current_mana
		side_tasks[card_id] = state
		if current_mana >= float(task.get("target", 1.0)):
			_complete_task(side, card_id)


# 任意阵营打出一张卡时，推进受该事件影响的任务。
func track_card_play(side: String, played_card_id: String) -> void:
	if not task_states.has(side):
		return
	var side_tasks: Dictionary = task_states[side]
	# 记录该卡使用次数（供结算读取）。
	if side_tasks.has(played_card_id):
		var state: Dictionary = side_tasks[played_card_id]
		state["play_count"] = int(state.get("play_count", 0)) + 1
		side_tasks[played_card_id] = state

	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = card_by_id(card_id).get("task", {})
		var task_type: String = String(task.get("type", ""))
		var watch_card_id: String = String(task.get("watch_card_id", card_id))
		if played_card_id != watch_card_id:
			continue
		if task_type == "card_play_count" or task_type == "linked_card_play_count":
			_increment_task_progress(side, card_id, 1.0)
		elif task_type == "card_play_burst":
			_track_burst_card_play(side, card_id, state, task)


# card_play_burst 任务：在时间窗口内累计使用次数。
func _track_burst_card_play(side: String, card_id: String, state: Dictionary, task: Dictionary) -> void:
	var recent_uses: Array = state.get("recent_uses", [])
	recent_uses.append(simulator.battle_time())
	var window: float = float(task.get("window", 3.0))
	var filtered_uses: Array = []
	for raw_time in recent_uses:
		var use_time: float = float(raw_time)
		if simulator.battle_time() - use_time <= window:
			filtered_uses.append(use_time)
	state["recent_uses"] = filtered_uses
	state["progress"] = float(filtered_uses.size())
	var side_tasks: Dictionary = task_states[side]
	side_tasks[card_id] = state
	if filtered_uses.size() >= int(task.get("target", 1)):
		_complete_task(side, card_id)


# 单位血量变化时，推进 unit_hp_below_ratio 类任务。
func track_unit_hp_change(unit: Dictionary) -> void:
	var side: String = String(unit["side"])
	var card_id: String = String(unit["card_id"])
	var state: Dictionary = task_state(side, card_id)
	var card: Dictionary = card_by_id(card_id)
	if state.size() == 0 or card.size() == 0 or bool(state.get("completed", false)):
		return
	var task: Dictionary = card.get("task", {})
	if String(task.get("type", "")) != "unit_hp_below_ratio":
		return
	if float(unit["hp"]) < float(unit["max_hp"]) * float(task.get("hp_ratio", 0.6667)):
		_set_task_progress(side, card_id, 1.0)


# 衍生侍童入场时，推进“全局召唤数”类任务。
func track_unit_spawn(side: String, unit: Dictionary) -> void:
	if not _is_squire(unit) or not task_states.has(side):
		return
	var side_tasks: Dictionary = task_states[side]
	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = card_by_id(card_id).get("task", {})
		if String(task.get("type", "")) == "squire_summon_count":
			_increment_task_progress(side, card_id, 1.0)


# 单位阵亡时，同时处理己方侍童任务与双方全局阵亡任务。
func track_unit_death(dead_side: String, unit: Dictionary) -> void:
	if task_states.has(dead_side) and _is_squire(unit):
		var own_tasks: Dictionary = task_states[dead_side]
		for raw_card_id in own_tasks.keys():
			var card_id: String = String(raw_card_id)
			var state: Dictionary = own_tasks[card_id]
			if bool(state.get("completed", false)):
				continue
			var task: Dictionary = card_by_id(card_id).get("task", {})
			if String(task.get("type", "")) != "squire_death_count":
				continue
			var watch_unit_id: String = String(task.get("watch_unit_id", ""))
			if watch_unit_id == "" or watch_unit_id == String(unit.get("card_id", "")):
				_increment_task_progress(dead_side, card_id, 1.0)

	for raw_side in task_states.keys():
		var observer_side: String = String(raw_side)
		var observer_tasks: Dictionary = task_states[observer_side]
		for raw_card_id in observer_tasks.keys():
			var card_id: String = String(raw_card_id)
			var state: Dictionary = observer_tasks[card_id]
			if bool(state.get("completed", false)):
				continue
			var task: Dictionary = card_by_id(card_id).get("task", {})
			if String(task.get("type", "")) == "all_unit_death_count":
				_increment_task_progress(observer_side, card_id, 1.0)


# 每 tick 同步当前在场侍童数，供“同时存在”任务使用。
func track_squire_state(side: String, alive_count: int) -> void:
	if not task_states.has(side):
		return
	var side_tasks: Dictionary = task_states[side]
	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = card_by_id(card_id).get("task", {})
		if String(task.get("type", "")) == "squire_simultaneous":
			_set_task_progress(side, card_id, float(alive_count))


func _is_squire(unit: Dictionary) -> bool:
	var tags: Array = unit.get("tags", [])
	return tags.has("squire")


# 单位击杀时，推进 card_kill_count / single_unit_kill_count 类任务。
func track_unit_kill(source_side: String, source_card_id: String, source_unit_id: int) -> void:
	if source_card_id == "" or not task_states.has(source_side):
		return
	var side_tasks: Dictionary = task_states[source_side]
	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = card_by_id(card_id).get("task", {})
		var task_type: String = String(task.get("type", ""))
		if source_card_id != String(task.get("watch_card_id", card_id)):
			continue
		if task_type == "card_kill_count":
			_increment_task_progress(source_side, card_id, 1.0)
		elif task_type == "single_unit_kill_count" and source_unit_id > 0:
			var unit_kills: Dictionary = state.get("unit_kills", {})
			unit_kills[source_unit_id] = int(unit_kills.get(source_unit_id, 0)) + 1
			state["unit_kills"] = unit_kills
			state["progress"] = max(float(state.get("progress", 0.0)), float(unit_kills[source_unit_id]))
			side_tasks[card_id] = state
			if int(unit_kills[source_unit_id]) >= int(task.get("target", 1)):
				_complete_task(source_side, card_id)


# 命中基地时，推进 base_hit_count 类任务。
func track_base_hit(source_side: String, source_card_id: String) -> void:
	if source_card_id == "" or not task_states.has(source_side):
		return
	var side_tasks: Dictionary = task_states[source_side]
	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = card_by_id(card_id).get("task", {})
		if String(task.get("type", "")) == "base_hit_count" and source_card_id == String(task.get("watch_card_id", card_id)):
			_increment_task_progress(source_side, card_id, 1.0)


# 增量推进任务进度。
func _increment_task_progress(side: String, card_id: String, amount: float) -> void:
	var state: Dictionary = task_state(side, card_id)
	if state.size() == 0:
		return
	_set_task_progress(side, card_id, float(state.get("progress", 0.0)) + amount)


# 直接设置任务进度，并检查是否达成。
func _set_task_progress(side: String, card_id: String, value: float) -> void:
	var side_tasks: Dictionary = task_states[side]
	var state: Dictionary = side_tasks[card_id]
	if bool(state.get("completed", false)):
		return
	var task: Dictionary = card_by_id(card_id).get("task", {})
	var target: float = float(task.get("target", 1.0))
	state["progress"] = min(value, target)
	side_tasks[card_id] = state
	if value >= target:
		_complete_task(side, card_id)


# 完成任务：标记完成、触发进化、回报统计与事件。
func _complete_task(side: String, card_id: String) -> void:
	var side_tasks: Dictionary = task_states[side]
	var state: Dictionary = side_tasks[card_id]
	if bool(state.get("completed", false)):
		return
	var card: Dictionary = card_by_id(card_id)
	var task: Dictionary = card.get("task", {})
	var evolution: Dictionary = card.get("evolution", {})
	state["completed"] = true
	state["evolved"] = evolution.size() > 0
	state["progress"] = float(task.get("target", state.get("progress", 0.0)))
	state["completed_at_time"] = simulator.battle_time()
	side_tasks[card_id] = state
	simulator.record_task_completed(side, evolution.size() > 0, card_id)
	if evolution.size() > 0:
		simulator.push_event("%s完成%s任务，进化为%s。" % [MapMath.side_name(side), card["name"], evolution["name"]])
	else:
		simulator.push_event("%s完成%s任务。" % [MapMath.side_name(side), card["name"]])


# 强制完成某张卡的任务（供调试工具使用）。
func force_complete_task(side: String, card_id: String) -> void:
	if not task_states.has(side):
		return
	var side_tasks: Dictionary = task_states[side]
	if not side_tasks.has(card_id):
		return
	var state: Dictionary = side_tasks[card_id]
	if bool(state.get("completed", false)):
		return
	var card: Dictionary = card_by_id(card_id)
	var task: Dictionary = card.get("task", {})
	_set_task_progress(side, card_id, float(task.get("target", 1.0)))


# 返回某张卡当前任务进度比例（0.0~1.0），供进度条显示。
func task_progress_ratio(side: String, card_id: String) -> float:
	var state: Dictionary = task_state(side, card_id)
	var card: Dictionary = card_by_id(card_id)
	if state.size() == 0 or card.size() == 0 or not card.has("task"):
		return 0.0
	var task: Dictionary = card["task"]
	var target: float = float(task.get("target", 1.0))
	if target <= 0.0:
		return 0.0
	if bool(state.get("completed", false)):
		return 1.0
	return clamp(float(state.get("progress", 0.0)) / target, 0.0, 1.0)


# —— V0.5 回滚重放：任务状态快照与恢复 ——
# cards 是静态卡牌定义（不变），simulator 是外部引用（由控制器重新注入）
# 只需快照 task_states（局内任务进度，会随对局变化）
func snapshot() -> Dictionary:
	return {
		"task_states": task_states.duplicate(true),
	}


func restore(snap: Dictionary) -> void:
	task_states = snap["task_states"].duplicate(true)
