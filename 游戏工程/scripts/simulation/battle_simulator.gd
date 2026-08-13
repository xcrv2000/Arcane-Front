# 战斗模拟核心：纯逻辑，不依赖 UI。
# 持有对局运行时状态（时间、费用、单位、基地、法术特效、统计、事件日志），
# 并驱动单位移动/索敌/攻击、法术命中、光环脉冲、基地清屏与胜负结算。
#
# 与外界的接口约定：
#   - 控制器每帧调用 advance_time / update_units / update_spell_effects；
#   - 出牌通过 try_play_card 注入（玩家输入与 Bot 输入共用同一入口）；
#   - 任务/进化追踪委托给 TaskSystem（通过 task_system 引用回调）；
#   - running 标记对局是否进行中，finish_match 后置 false，控制器据此切换结算界面。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const MapMath = preload("res://scripts/support/map_math.gd")

var battle_time: float = 0.0
var player_mana: float = Config.STARTING_MANA
var bot_mana: float = Config.STARTING_MANA
var units: Array[Dictionary] = []
var spell_effects: Array[Dictionary] = []
var bases: Dictionary = {}
var stats: Dictionary = {}
var event_log: Array[String] = []
var next_unit_id: int = 1
var match_winner: String = ""
var running: bool = false
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var task_system: RefCounted = null  # TaskSystem 引用，运行时由控制器注入
var evolution_flashes: Dictionary = {}  # side → {card_id → remaining_flash_time}


func _init() -> void:
	rng.seed = 10101


# 注入任务系统引用。
func setup(task_sys: RefCounted) -> void:
	task_system = task_sys


# 对局开始：重置全部模拟状态。任务状态与 Bot 状态由控制器分别初始化。
func start_battle() -> void:
	battle_time = 0.0
	player_mana = Config.STARTING_MANA
	bot_mana = Config.STARTING_MANA
	next_unit_id = 1
	units.clear()
	spell_effects.clear()
	event_log.clear()
	match_winner = ""
	running = true
	evolution_flashes = {}
	bases = {
		Config.PLAYER: {
			"hp": Config.BASE_MAX_HP,
			"max_hp": Config.BASE_MAX_HP,
			"next_clear_threshold": 200.0,
			"clear_count": 0
		},
		Config.BOT: {
			"hp": Config.BASE_MAX_HP,
			"max_hp": Config.BASE_MAX_HP,
			"next_clear_threshold": 200.0,
			"clear_count": 0
		}
	}
	stats = {
		"player_cards": {},
		"bot_cards": {},
		"player_spent": 0.0,
		"bot_spent": 0.0,
		"units_lost": 0,
		"spell_casts": 0,
		"player_tasks_completed": 0,
		"bot_tasks_completed": 0,
		"player_evolutions": 0,
		"bot_evolutions": 0
	}


# 推进时间与费用回复（任务检查由控制器在此时调用 task_system.check_mana）。
func advance_time(delta: float) -> void:
	battle_time += delta
	player_mana = min(Config.MANA_MAX, player_mana + Config.MANA_PER_SECOND * delta)
	bot_mana = min(Config.MANA_MAX, bot_mana + Config.MANA_PER_SECOND * delta)


# 尝试打出一张卡（玩家或 Bot 共用）。card 应为 active_card_by_id 解析后的生效卡牌。
func try_play_card(side: String, card: Dictionary, target_position: Vector2) -> bool:
	if card.size() == 0:
		return false

	var cost: float = float(card["cost"])
	if side == Config.PLAYER:
		if player_mana < cost:
			push_event("%s 费用不足。" % card["name"])
			return false
	else:
		if bot_mana < cost:
			return false

	if card["kind"] == "unit":
		if side == Config.PLAYER and target_position.y < Config.PLAYER_DEPLOY_MIN_Y:
			push_event("单位只能部署在己方半场。")
			return false
		if side == Config.BOT and target_position.y > Config.BOT_DEPLOY_MAX_Y:
			return false

	if side == Config.PLAYER:
		player_mana -= cost
		stats["player_spent"] += cost
	else:
		bot_mana -= cost
		stats["bot_spent"] += cost

	if card["kind"] == "unit":
		_spawn_units(side, card, target_position)
	else:
		_cast_spell(side, card, target_position)

	_record_card_use(side, String(card["id"]))
	return true


# 按卡牌数量在目标点周围环形铺开生成单位。
func _spawn_units(side: String, card: Dictionary, target_position: Vector2) -> void:
	var count: int = int(card["count"])
	var center: Vector2 = MapMath.clamped_deploy_position(side, target_position)
	var spread: float = 1.9 * Config.UNIT_RADIUS_SCALE
	for index in range(count):
		var angle: float = TAU * float(index) / max(1.0, float(count))
		var offset: Vector2 = Vector2(cos(angle), sin(angle)) * spread
		if count == 1:
			offset = Vector2.ZERO
		var unit_position: Vector2 = MapMath.clamped_deploy_position(side, center + offset)
		var unit: Dictionary = {
			"id": next_unit_id,
			"side": side,
			"card_id": card["id"],
			"art_id": String(card.get("evolved_id", card["id"])),
			"name": card["name"],
			"short_name": card["short_name"],
			"hp": float(card["hp"]),
			"max_hp": float(card["hp"]),
			"damage": float(card["damage"]),
			"attack_cooldown": float(card["attack_cooldown"]),
			"attack_timer": rng.randf_range(0.0, 0.35),
			"range": float(card["range"]),
			"speed": float(card["speed"]),
			"radius": float(card["radius"]) * Config.UNIT_RADIUS_SCALE,
			"aoe_radius": float(card.get("aoe_radius", 0.0)),
			"multi_target_count": int(card.get("multi_target_count", 1)),
			"aura_interval": float(card.get("aura_interval", 0.0)),
			"aura_timer": float(card.get("aura_interval", 0.0)),
			"aura_radius": float(card.get("aura_radius", 0.0)),
			"aura_damage": float(card.get("aura_damage", 0.0)),
			"shape": card["shape"],
			"color": card["color"],
			"target_base_only": bool(card.get("target_base_only", false)),
			"pos": unit_position
		}
		next_unit_id += 1
		units.append(unit)
	push_event("%s 部署 %s。" % [MapMath.side_name(side), card["name"]])


# 施放法术：按 spell_mode 分发到 single / area / line。
func _cast_spell(side: String, card: Dictionary, target_position: Vector2) -> void:
	if card["spell_mode"] == "line":
		_cast_line_spell(side, card, target_position)
		return

	var enemy_side: String = MapMath.opponent(side)
	var radius: float = float(card["radius"])
	var damage: float = float(card["damage"])
	var base_damage: float = float(card["base_damage"])
	var hit_count: int = 0

	if card["spell_mode"] == "single":
		var target: Dictionary = _nearest_enemy_unit(enemy_side, target_position, radius)
		if target.size() > 0:
			_damage_unit(target, damage, side, String(card["id"]), 0)
			hit_count = 1
		elif target_position.distance_to(MapMath.base_position(enemy_side)) <= radius + Config.BASE_RADIUS:
			_damage_base(enemy_side, base_damage, side, String(card["id"]))
			hit_count = 1
	else:
		for unit in units:
			if unit["side"] == enemy_side and unit["hp"] > 0.0 and unit["pos"].distance_to(target_position) <= radius:
				_damage_unit(unit, damage, side, String(card["id"]), 0)
				hit_count += 1
		if target_position.distance_to(MapMath.base_position(enemy_side)) <= radius + Config.BASE_RADIUS:
			_damage_base(enemy_side, base_damage, side, String(card["id"]))
			hit_count += 1

	stats["spell_casts"] += 1
	spell_effects.append({
		"pos": target_position,
		"radius": radius,
		"time": 0.36,
		"max_time": 0.36,
		"color": card["color"],
		"label": card["short_name"]
	})
	push_event("%s 施放 %s，命中 %d。" % [MapMath.side_name(side), card["name"], hit_count])


# 线性法术：从己方基地到目标点路径上命中所有单位与基地。
func _cast_line_spell(side: String, card: Dictionary, target_position: Vector2) -> void:
	var start_position: Vector2 = MapMath.base_position(side)
	var radius: float = float(card["radius"])
	var damage: float = float(card["damage"])
	var base_damage: float = float(card["base_damage"])
	var hit_count: int = 0
	for unit in units:
		if unit["hp"] > 0.0 and MapMath.distance_to_segment(unit["pos"], start_position, target_position) <= radius:
			_damage_unit(unit, damage, side, String(card["id"]), 0)
			hit_count += 1
	for raw_base_side in [Config.PLAYER, Config.BOT]:
		var base_side: String = String(raw_base_side)
		if MapMath.distance_to_segment(MapMath.base_position(base_side), start_position, target_position) <= radius + Config.BASE_RADIUS:
			_damage_base(base_side, base_damage, side, String(card["id"]))
			hit_count += 1
	stats["spell_casts"] += 1
	spell_effects.append({
		"mode": "line",
		"from": start_position,
		"pos": target_position,
		"radius": radius,
		"time": 0.36,
		"max_time": 0.36,
		"color": card["color"],
		"label": card["short_name"]
	})
	push_event("%s 施放 %s，路径命中 %d。" % [MapMath.side_name(side), card["name"], hit_count])


# 每帧更新所有单位：光环、索敌、攻击或移动、碰撞分离、清理阵亡单位。
func update_units(delta: float) -> void:
	for unit in units:
		if unit["hp"] <= 0.0:
			continue
		unit["attack_timer"] = max(0.0, float(unit["attack_timer"]) - delta)
		_update_unit_aura(unit, delta)

	for unit in units:
		if unit["hp"] <= 0.0 or not running:
			continue
		var target: Dictionary = _find_target(unit)
		var target_position: Vector2 = target["pos"]
		var unit_position: Vector2 = unit["pos"]
		var distance: float = unit_position.distance_to(target_position)
		var attack_distance: float = float(unit["range"]) + float(target["radius"])

		if distance <= attack_distance:
			if float(unit["attack_timer"]) <= 0.0:
				_perform_attack(unit, target)
				unit["attack_timer"] = float(unit["attack_cooldown"])
		else:
			_move_unit_toward(unit, _next_step_goal(unit, target_position), delta)

	_separate_units()

	var alive_units: Array[Dictionary] = []
	for unit in units:
		if unit["hp"] > 0.0:
			alive_units.append(unit)
		else:
			stats["units_lost"] += 1
	units = alive_units


# 碰撞分离：推开所有互相重叠的单位（同阵营与敌方都分离，避免重叠）。
func _separate_units() -> void:
	var alive_count: int = 0
	for unit in units:
		if float(unit["hp"]) > 0.0:
			alive_count += 1

	for i in range(alive_count):
		var unit_a: Dictionary = units[i]
		if float(unit_a["hp"]) <= 0.0:
			continue
		var pos_a: Vector2 = unit_a["pos"]
		var radius_a: float = float(unit_a["radius"])

		for j in range(i + 1, alive_count):
			var unit_b: Dictionary = units[j]
			if float(unit_b["hp"]) <= 0.0:
				continue
			var pos_b: Vector2 = unit_b["pos"]
			var radius_b: float = float(unit_b["radius"])

			var delta_pos: Vector2 = pos_a - pos_b
			var dist: float = delta_pos.length()
			var min_dist: float = radius_a + radius_b
			if dist >= min_dist or dist <= 0.001:
				continue

			var overlap: float = min_dist - dist
			var direction: Vector2 = delta_pos.normalized()
			# 双方各推一半，向相反方向分离。
			var push: Vector2 = direction * overlap * 0.5
			unit_a["pos"] = pos_a + push
			unit_b["pos"] = pos_b - push


# 为单位寻找攻击目标：优先仇敌范围内的敌方单位，否则目标为基地。
func _find_target(unit: Dictionary) -> Dictionary:
	var enemy_side: String = MapMath.opponent(unit["side"])
	if bool(unit.get("target_base_only", false)):
		return {
			"kind": "base",
			"side": enemy_side,
			"pos": MapMath.base_position(enemy_side),
			"radius": Config.BASE_RADIUS
		}

	var aggro_range: float = max(9.0, float(unit["range"]) + 4.0)
	var best_unit: Dictionary = {}
	var best_distance: float = INF
	for enemy in units:
		if enemy["side"] == enemy_side and enemy["hp"] > 0.0:
			var distance: float = unit["pos"].distance_to(enemy["pos"])
			if distance < best_distance and distance <= aggro_range + float(enemy["radius"]):
				best_distance = distance
				best_unit = enemy

	if best_unit.size() > 0:
		return {
			"kind": "unit",
			"unit": best_unit,
			"side": enemy_side,
			"pos": best_unit["pos"],
			"radius": best_unit["radius"]
		}

	return {
		"kind": "base",
		"side": enemy_side,
		"pos": MapMath.base_position(enemy_side),
		"radius": Config.BASE_RADIUS
	}


# 执行一次攻击：处理 AOE、多目标与基地命中。
func _perform_attack(unit: Dictionary, target: Dictionary) -> void:
	var damage: float = float(unit["damage"])
	var source_card_id: String = String(unit["card_id"])
	var source_unit_id: int = int(unit["id"])
	if target["kind"] == "base":
		_damage_base(target["side"], damage, unit["side"], source_card_id)
		var excluded_unit_ids: Array[int] = []
		_damage_extra_attack_targets(unit, excluded_unit_ids, max(0, int(unit.get("multi_target_count", 1)) - 1), damage)
		return

	var hit_unit_ids: Array[int] = []
	if float(unit.get("aoe_radius", 0.0)) > 0.0:
		hit_unit_ids = _damage_attack_aoe(unit, target["unit"]["pos"], damage)
	else:
		hit_unit_ids.append(int(target["unit"]["id"]))
		_damage_unit(target["unit"], damage, unit["side"], source_card_id, source_unit_id)

	_damage_extra_attack_targets(unit, hit_unit_ids, max(0, int(unit.get("multi_target_count", 1)) - 1), damage)


# 攻击落点 AOE：对范围内所有敌方单位造成伤害。
func _damage_attack_aoe(unit: Dictionary, center: Vector2, damage: float) -> Array[int]:
	var hit_unit_ids: Array[int] = []
	for enemy in units:
		if enemy["side"] != unit["side"] and enemy["hp"] > 0.0 and enemy["pos"].distance_to(center) <= float(unit["aoe_radius"]):
			hit_unit_ids.append(int(enemy["id"]))
			_damage_unit(enemy, damage, unit["side"], String(unit["card_id"]), int(unit["id"]))
	return hit_unit_ids


# 多目标攻击：在射程内挑选额外目标依次命中。
func _damage_extra_attack_targets(unit: Dictionary, excluded_unit_ids: Array[int], count: int, damage: float) -> void:
	var remaining: int = count
	while remaining > 0:
		var best_unit: Dictionary = {}
		var best_distance: float = INF
		for enemy in units:
			if enemy["side"] == unit["side"] or enemy["hp"] <= 0.0 or excluded_unit_ids.has(int(enemy["id"])):
				continue
			var distance: float = unit["pos"].distance_to(enemy["pos"])
			if distance <= float(unit["range"]) + float(enemy["radius"]) and distance < best_distance:
				best_distance = distance
				best_unit = enemy
		if best_unit.size() == 0:
			return
		excluded_unit_ids.append(int(best_unit["id"]))
		_damage_unit(best_unit, damage, unit["side"], String(unit["card_id"]), int(unit["id"]))
		remaining -= 1


# 单位朝目标移动一步。
func _move_unit_toward(unit: Dictionary, target_position: Vector2, delta: float) -> void:
	var direction: Vector2 = target_position - unit["pos"]
	var distance: float = direction.length()
	if distance <= 0.02:
		return
	var step: float = min(distance, float(unit["speed"]) * delta)
	unit["pos"] = unit["pos"] + direction.normalized() * step


# 计算单位下一步的移动目标点（向基地推进时走桥）。
func _next_step_goal(unit: Dictionary, target_position: Vector2) -> Vector2:
	if _target_is_base_position(unit["side"], target_position):
		return _path_goal_toward_base(unit)
	return target_position


# 向基地推进时的分段路径目标（先到桥、过河、再到基地）。
# 路径点始终越过边界，避免浮点精度导致的"卡在路径点"问题。
func _path_goal_toward_base(unit: Dictionary) -> Vector2:
	var position: Vector2 = unit["pos"]
	var bridge_x: float = MapMath.nearest_bridge_x(position.x)
	if unit["side"] == Config.PLAYER:
		# 向北推进：先到桥南入口，再到桥北出口（越过 y=47 边界），最后到基地。
		if position.y >= Config.RIVER_Y + 3.0:
			return Vector2(bridge_x, Config.RIVER_Y + 1.5)
		if position.y >= Config.RIVER_Y - 3.0:
			return Vector2(bridge_x, Config.RIVER_Y - 4.5)
		return MapMath.base_position(Config.BOT)

	# 向南推进：先到桥北入口，再到桥南出口（越过 y=53 边界），最后到基地。
	if position.y <= Config.RIVER_Y - 3.0:
		return Vector2(bridge_x, Config.RIVER_Y - 1.5)
	if position.y <= Config.RIVER_Y + 3.0:
		return Vector2(bridge_x, Config.RIVER_Y + 4.5)
	return MapMath.base_position(Config.PLAYER)


# 判断目标点是否就是敌方基地位置。
func _target_is_base_position(side: String, target_position: Vector2) -> bool:
	return target_position.distance_to(MapMath.base_position(MapMath.opponent(side))) <= 0.1


# 对单位造成伤害，并回报血量变化与击杀事件。
func _damage_unit(unit: Dictionary, amount: float, source_side: String = "", source_card_id: String = "", source_unit_id: int = 0) -> void:
	var previous_hp: float = float(unit["hp"])
	if previous_hp <= 0.0:
		return
	unit["hp"] = max(0.0, previous_hp - amount)
	task_system.track_unit_hp_change(unit)
	if float(unit["hp"]) <= 0.0 and source_side != "" and source_side != String(unit["side"]):
		task_system.track_unit_kill(source_side, source_card_id, source_unit_id)


# 对基地造成伤害，处理清屏阈值与胜负结算。
func _damage_base(base_side: String, amount: float, source_side: String, source_card_id: String = "") -> void:
	if not running:
		return

	var base: Dictionary = bases[base_side]
	var previous_hp: float = float(base["hp"])
	base["hp"] = max(0.0, float(base["hp"]) - amount)
	if previous_hp > float(base["hp"]) and source_side != "" and source_side != base_side:
		task_system.track_base_hit(source_side, source_card_id)
	while float(base["next_clear_threshold"]) > 0.0 and float(base["hp"]) <= float(base["next_clear_threshold"]):
		_trigger_clear(base_side, float(base["next_clear_threshold"]))
		base["next_clear_threshold"] = float(base["next_clear_threshold"]) - 100.0

	if float(base["hp"]) <= 0.0:
		var winner_side: String = source_side if source_side != base_side else MapMath.opponent(base_side)
		_finish_match(winner_side)


# 基地跌破阈值时清屏：场上所有单位阵亡。
func _trigger_clear(base_side: String, threshold: float) -> void:
	for unit in units:
		unit["hp"] = 0.0
	bases[base_side]["clear_count"] = int(bases[base_side]["clear_count"]) + 1
	push_event("%s基地跌破 %d 血，清屏。" % [MapMath.side_name(base_side), int(threshold)])


# 结束对局，记录胜方。控制器据此切换到结算界面。
func _finish_match(winner_side: String) -> void:
	match_winner = winner_side
	running = false
	push_event("%s胜利，用时 %s。" % [MapMath.side_name(winner_side), _format_time(battle_time)])


# 每帧衰减法术特效剩余时间，移除已结束的特效。
func update_spell_effects(delta: float) -> void:
	var active: Array[Dictionary] = []
	for effect in spell_effects:
		effect["time"] = float(effect["time"]) - delta
		if float(effect["time"]) > 0.0:
			active.append(effect)
	spell_effects = active


# 推进单位光环计时器，到点触发脉冲。
func _update_unit_aura(unit: Dictionary, delta: float) -> void:
	var interval: float = float(unit.get("aura_interval", 0.0))
	if interval <= 0.0 or not running:
		return
	var timer: float = float(unit.get("aura_timer", interval)) - delta
	while timer <= 0.0 and running and float(unit["hp"]) > 0.0:
		_pulse_unit_aura(unit)
		timer += interval
	unit["aura_timer"] = timer


# 光环脉冲：对范围内敌方单位与基地造成伤害，并生成短暂特效。
func _pulse_unit_aura(unit: Dictionary) -> void:
	var enemy_side: String = MapMath.opponent(unit["side"])
	var radius: float = float(unit["aura_radius"])
	var damage: float = float(unit["aura_damage"])
	var hit_count: int = 0
	for enemy in units:
		if enemy["side"] == enemy_side and enemy["hp"] > 0.0 and enemy["pos"].distance_to(unit["pos"]) <= radius:
			_damage_unit(enemy, damage, unit["side"], String(unit["card_id"]), int(unit["id"]))
			hit_count += 1
	if unit["pos"].distance_to(MapMath.base_position(enemy_side)) <= radius + Config.BASE_RADIUS:
		_damage_base(enemy_side, damage, unit["side"], String(unit["card_id"]))
		hit_count += 1
	if hit_count > 0:
		spell_effects.append({
			"pos": unit["pos"],
			"radius": radius,
			"time": 0.22,
			"max_time": 0.22,
			"color": unit["color"],
			"label": unit["short_name"]
		})


# 在指定范围内寻找最近的敌方单位（single 法术命中判定）。
func _nearest_enemy_unit(enemy_side: String, position: Vector2, radius: float) -> Dictionary:
	var best_unit: Dictionary = {}
	var best_distance: float = INF
	for unit in units:
		if unit["side"] == enemy_side and unit["hp"] > 0.0:
			var unit_position: Vector2 = unit["pos"]
			var distance: float = position.distance_to(unit_position)
			if distance <= radius and distance < best_distance:
				best_distance = distance
				best_unit = unit
	return best_unit


# 寻找敌方单位最密集的簇中心（Bot 选择法术落点用）。
func best_enemy_cluster(side: String, radius: float) -> Vector2:
	var enemy_side: String = MapMath.opponent(side)
	var best_position: Vector2 = Vector2(-1.0, -1.0)
	var best_score: int = 0
	for unit in units:
		if unit["side"] != enemy_side or unit["hp"] <= 0.0:
			continue
		var score: int = 0
		for other in units:
			if other["side"] == enemy_side and other["hp"] > 0.0 and unit["pos"].distance_to(other["pos"]) <= radius:
				score += 1
		if score > best_score:
			best_score = score
			best_position = unit["pos"]
	return best_position


# 记录卡牌使用次数统计，并推进相关任务。
func _record_card_use(side: String, card_id: String) -> void:
	var key: String = "player_cards" if side == Config.PLAYER else "bot_cards"
	var usage: Dictionary = stats[key]
	usage[card_id] = int(usage.get(card_id, 0)) + 1
	task_system.track_card_play(side, card_id)


# 任务完成时由 TaskSystem 回调：累计任务/进化统计，触发进化闪光。
func record_task_completed(side: String, evolved: bool, card_id: String = "") -> void:
	var task_key: String = "player_tasks_completed" if side == Config.PLAYER else "bot_tasks_completed"
	stats[task_key] = int(stats.get(task_key, 0)) + 1
	if evolved:
		var evolution_key: String = "player_evolutions" if side == Config.PLAYER else "bot_evolutions"
		stats[evolution_key] = int(stats.get(evolution_key, 0)) + 1
		if card_id != "":
			if not evolution_flashes.has(side):
				evolution_flashes[side] = {}
			evolution_flashes[side][card_id] = 2.0


# 追加一条事件日志，保留最近 6 条。
func push_event(message: String) -> void:
	event_log.append(message)
	while event_log.size() > 6:
		event_log.pop_front()


# 每帧衰减进化闪光计时器。
func update_evolution_flashes(delta: float) -> void:
	for side in evolution_flashes.keys():
		var side_flashes: Dictionary = evolution_flashes[side]
		var remaining: Dictionary = {}
		for card_id in side_flashes.keys():
			var time_left: float = float(side_flashes[card_id]) - delta
			if time_left > 0.0:
				remaining[card_id] = time_left
		evolution_flashes[side] = remaining


# 查询某张卡是否处于进化闪光状态。
func is_evolution_flashing(side: String, card_id: String) -> bool:
	if not evolution_flashes.has(side):
		return false
	return evolution_flashes[side].has(card_id)


# 格式化秒为 mm:ss。
func _format_time(seconds: float) -> String:
	var total_seconds: int = int(floor(seconds))
	return "%02d:%02d" % [int(total_seconds / 60), total_seconds % 60]
