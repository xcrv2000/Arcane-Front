extends Control

const CardCatalog = preload("res://scripts/v01/card_catalog.gd")

const PLAYER: String = "player"
const BOT: String = "bot"
const CARD_PICK_COUNT: int = 6
const MAP_WIDTH: float = 56.0
const MAP_HEIGHT: float = 100.0
const MANA_MAX: float = 10.0
const STARTING_MANA: float = 5.0
const MANA_PER_SECOND: float = 0.5
const BASE_MAX_HP: float = 300.0
const BASE_RADIUS: float = 4.8
const UNIT_RADIUS_SCALE: float = 2.0
const UNIT_ART_ROOT: String = "res://assets/units/"
const UNIT_ART_FRONT: String = "front"
const UNIT_ART_BACK: String = "back"
const UNIT_ART_HEIGHT_SCALE: float = 3.0
const UNIT_ART_FOOT_OFFSET: float = 1.05
const RIVER_Y: float = 50.0
const PLAYER_DEPLOY_MIN_Y: float = 54.0
const BOT_DEPLOY_MAX_Y: float = 46.0
const BOT_THINK_MIN_DELAY: float = 1.45
const BOT_THINK_MAX_DELAY: float = 2.7
const BOT_DECK_IDS: Array[String] = [
	"spark_swarm",
	"shield_pair",
	"cleaver",
	"quick_archer",
	"ember_mage",
	"arcane_giant"
]

enum ScreenMode { DECK_SELECT, BATTLE, RESULT }

var screen_mode: int = ScreenMode.DECK_SELECT
var cards: Array[Dictionary] = []
var selected_card_ids: Array[String] = []
var selected_battle_card_id: String = ""
var card_pick_rects: Dictionary = {}
var battle_card_rects: Dictionary = {}
var start_rect: Rect2 = Rect2()
var restart_rect: Rect2 = Rect2()
var deck_rect: Rect2 = Rect2()
var board_rect: Rect2 = Rect2()
var battle_time: float = 0.0
var player_mana: float = STARTING_MANA
var bot_mana: float = STARTING_MANA
var bot_play_cursor: int = 0
var bot_think_timer: float = 0.0
var next_unit_id: int = 1
var units: Array[Dictionary] = []
var spell_effects: Array[Dictionary] = []
var bases: Dictionary = {}
var stats: Dictionary = {}
var task_states: Dictionary = {}
var event_log: Array[String] = []
var match_winner: String = ""
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var ui_font: Font
var unit_art_cache: Dictionary = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	ui_font = get_theme_default_font()
	rng.seed = 10101
	cards = CardCatalog.all_cards()
	for index in range(min(CARD_PICK_COUNT, cards.size())):
		selected_card_ids.append(cards[index]["id"])
	queue_redraw()

func _process(delta: float) -> void:
	if screen_mode != ScreenMode.BATTLE:
		return

	battle_time += delta
	player_mana = min(MANA_MAX, player_mana + MANA_PER_SECOND * delta)
	bot_mana = min(MANA_MAX, bot_mana + MANA_PER_SECOND * delta)
	_check_mana_tasks(PLAYER)
	_check_mana_tasks(BOT)
	_update_bot(delta)
	_update_units(delta)
	_update_spell_effects(delta)
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_press(event.position)
	elif event is InputEventScreenTouch and event.pressed:
		_handle_press(event.position)

func _handle_press(position: Vector2) -> void:
	_update_layout_cache()
	if screen_mode == ScreenMode.DECK_SELECT:
		_handle_deck_press(position)
	elif screen_mode == ScreenMode.BATTLE:
		_handle_battle_press(position)
	elif screen_mode == ScreenMode.RESULT:
		if restart_rect.has_point(position):
			_start_battle()
		elif deck_rect.has_point(position):
			screen_mode = ScreenMode.DECK_SELECT
			queue_redraw()

func _handle_deck_press(position: Vector2) -> void:
	for raw_card_id in card_pick_rects.keys():
		var card_id: String = String(raw_card_id)
		if card_pick_rects[card_id].has_point(position):
			_toggle_card_selection(card_id)
			queue_redraw()
			return

	if start_rect.has_point(position):
		if selected_card_ids.size() == CARD_PICK_COUNT:
			_start_battle()
		else:
			_push_event("需要选择 6 张卡。")
			queue_redraw()

func _handle_battle_press(position: Vector2) -> void:
	for raw_card_id in battle_card_rects.keys():
		var card_id: String = String(raw_card_id)
		if battle_card_rects[card_id].has_point(position):
			selected_battle_card_id = card_id
			var card: Dictionary = _active_card_by_id(PLAYER, card_id)
			if player_mana < float(card["cost"]):
				_push_event("%s 费用不足。" % card["name"])
			queue_redraw()
			return

	if board_rect.has_point(position) and selected_battle_card_id != "":
		var logic_position: Vector2 = _screen_to_map(position)
		var card: Dictionary = _active_card_by_id(PLAYER, selected_battle_card_id)
		_try_play_card(PLAYER, card, logic_position)
		queue_redraw()

func _toggle_card_selection(card_id: String) -> void:
	if selected_card_ids.has(card_id):
		selected_card_ids.erase(card_id)
	elif selected_card_ids.size() < CARD_PICK_COUNT:
		selected_card_ids.append(card_id)
	else:
		_push_event("V0.2 单局仍只能携带 6 张卡。")

func _start_battle() -> void:
	screen_mode = ScreenMode.BATTLE
	battle_time = 0.0
	player_mana = STARTING_MANA
	bot_mana = STARTING_MANA
	bot_play_cursor = 0
	bot_think_timer = 1.2
	next_unit_id = 1
	units.clear()
	spell_effects.clear()
	event_log.clear()
	match_winner = ""
	selected_battle_card_id = selected_card_ids[0]
	bases = {
		PLAYER: {
			"hp": BASE_MAX_HP,
			"max_hp": BASE_MAX_HP,
			"next_clear_threshold": 200.0,
			"clear_count": 0
		},
		BOT: {
			"hp": BASE_MAX_HP,
			"max_hp": BASE_MAX_HP,
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
	_initialize_task_states()
	_push_event("V0.2 对局开始：任务完成后卡牌自动进化。")
	queue_redraw()

func _update_bot(delta: float) -> void:
	bot_think_timer -= delta
	if bot_think_timer > 0.0:
		return

	var attempts: int = 0
	while attempts < BOT_DECK_IDS.size():
		var card_id: String = BOT_DECK_IDS[bot_play_cursor % BOT_DECK_IDS.size()]
		bot_play_cursor += 1
		attempts += 1
		var card: Dictionary = _active_card_by_id(BOT, card_id)
		if card.size() > 0 and bot_mana >= float(card["cost"]):
			var target_position: Vector2 = _choose_bot_position(card)
			_try_play_card(BOT, card, target_position)
			bot_think_timer = rng.randf_range(BOT_THINK_MIN_DELAY, BOT_THINK_MAX_DELAY)
			return

	bot_think_timer = 0.45

func _choose_bot_position(card: Dictionary) -> Vector2:
	if card["kind"] == "spell":
		var cluster: Vector2 = _best_enemy_cluster(BOT, float(card["radius"]))
		if cluster.x >= 0.0:
			return cluster
		return _base_position(PLAYER) + Vector2(rng.randf_range(-2.5, 2.5), rng.randf_range(-2.0, 2.0))

	var lane_x: float = _bridge_x(bot_play_cursor)
	return Vector2(
		clamp(lane_x + rng.randf_range(-4.0, 4.0), 5.0, MAP_WIDTH - 5.0),
		rng.randf_range(11.0, BOT_DEPLOY_MAX_Y)
	)

func _best_enemy_cluster(side: String, radius: float) -> Vector2:
	var enemy_side: String = _opponent(side)
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

func _try_play_card(side: String, card: Dictionary, target_position: Vector2) -> bool:
	if card.size() == 0:
		return false

	var cost: float = float(card["cost"])
	if side == PLAYER:
		if player_mana < cost:
			_push_event("%s 费用不足。" % card["name"])
			return false
	else:
		if bot_mana < cost:
			return false

	if card["kind"] == "unit":
		if side == PLAYER and target_position.y < PLAYER_DEPLOY_MIN_Y:
			_push_event("单位只能部署在己方半场。")
			return false
		if side == BOT and target_position.y > BOT_DEPLOY_MAX_Y:
			return false

	if side == PLAYER:
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

func _spawn_units(side: String, card: Dictionary, target_position: Vector2) -> void:
	var count: int = int(card["count"])
	var center: Vector2 = _clamped_deploy_position(side, target_position)
	var spread: float = 1.9 * UNIT_RADIUS_SCALE
	for index in range(count):
		var angle: float = TAU * float(index) / max(1.0, float(count))
		var offset: Vector2 = Vector2(cos(angle), sin(angle)) * spread
		if count == 1:
			offset = Vector2.ZERO
		var unit_position: Vector2 = _clamped_deploy_position(side, center + offset)
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
			"radius": float(card["radius"]) * UNIT_RADIUS_SCALE,
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
	_push_event("%s 部署 %s。" % [_side_name(side), card["name"]])

func _cast_spell(side: String, card: Dictionary, target_position: Vector2) -> void:
	if card["spell_mode"] == "line":
		_cast_line_spell(side, card, target_position)
		return

	var enemy_side: String = _opponent(side)
	var radius: float = float(card["radius"])
	var damage: float = float(card["damage"])
	var base_damage: float = float(card["base_damage"])
	var hit_count: int = 0

	if card["spell_mode"] == "single":
		var target: Dictionary = _nearest_enemy_unit(enemy_side, target_position, radius)
		if target.size() > 0:
			_damage_unit(target, damage, side, String(card["id"]), 0)
			hit_count = 1
		elif target_position.distance_to(_base_position(enemy_side)) <= radius + BASE_RADIUS:
			_damage_base(enemy_side, base_damage, side, String(card["id"]))
			hit_count = 1
	else:
		for unit in units:
			if unit["side"] == enemy_side and unit["hp"] > 0.0 and unit["pos"].distance_to(target_position) <= radius:
				_damage_unit(unit, damage, side, String(card["id"]), 0)
				hit_count += 1
		if target_position.distance_to(_base_position(enemy_side)) <= radius + BASE_RADIUS:
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
	_push_event("%s 施放 %s，命中 %d。" % [_side_name(side), card["name"], hit_count])

func _update_units(delta: float) -> void:
	for unit in units:
		if unit["hp"] <= 0.0:
			continue
		unit["attack_timer"] = max(0.0, float(unit["attack_timer"]) - delta)
		_update_unit_aura(unit, delta)

	for unit in units:
		if unit["hp"] <= 0.0 or screen_mode != ScreenMode.BATTLE:
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

	var alive_units: Array[Dictionary] = []
	for unit in units:
		if unit["hp"] > 0.0:
			alive_units.append(unit)
		else:
			stats["units_lost"] += 1
	units = alive_units

func _find_target(unit: Dictionary) -> Dictionary:
	var enemy_side: String = _opponent(unit["side"])
	if bool(unit.get("target_base_only", false)):
		return {
			"kind": "base",
			"side": enemy_side,
			"pos": _base_position(enemy_side),
			"radius": BASE_RADIUS
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
		"pos": _base_position(enemy_side),
		"radius": BASE_RADIUS
	}

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

func _damage_attack_aoe(unit: Dictionary, center: Vector2, damage: float) -> Array[int]:
	var hit_unit_ids: Array[int] = []
	for enemy in units:
		if enemy["side"] != unit["side"] and enemy["hp"] > 0.0 and enemy["pos"].distance_to(center) <= float(unit["aoe_radius"]):
			hit_unit_ids.append(int(enemy["id"]))
			_damage_unit(enemy, damage, unit["side"], String(unit["card_id"]), int(unit["id"]))
	return hit_unit_ids

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

func _move_unit_toward(unit: Dictionary, target_position: Vector2, delta: float) -> void:
	var direction: Vector2 = target_position - unit["pos"]
	var distance: float = direction.length()
	if distance <= 0.02:
		return
	var step: float = min(distance, float(unit["speed"]) * delta)
	unit["pos"] = unit["pos"] + direction.normalized() * step

func _next_step_goal(unit: Dictionary, target_position: Vector2) -> Vector2:
	if _target_is_base_position(unit["side"], target_position):
		return _path_goal_toward_base(unit)
	return target_position

func _path_goal_toward_base(unit: Dictionary) -> Vector2:
	var position: Vector2 = unit["pos"]
	var bridge_x: float = _nearest_bridge_x(position.x)
	if unit["side"] == PLAYER:
		if position.y > RIVER_Y + 3.0:
			return Vector2(bridge_x, RIVER_Y + 2.0)
		if position.y > RIVER_Y - 3.0:
			return Vector2(bridge_x, RIVER_Y - 3.0)
		return _base_position(BOT)

	if position.y < RIVER_Y - 3.0:
		return Vector2(bridge_x, RIVER_Y - 2.0)
	if position.y < RIVER_Y + 3.0:
		return Vector2(bridge_x, RIVER_Y + 3.0)
	return _base_position(PLAYER)

func _target_is_base_position(side: String, target_position: Vector2) -> bool:
	return target_position.distance_to(_base_position(_opponent(side))) <= 0.1

func _damage_unit(unit: Dictionary, amount: float, source_side: String = "", source_card_id: String = "", source_unit_id: int = 0) -> void:
	var previous_hp: float = float(unit["hp"])
	if previous_hp <= 0.0:
		return
	unit["hp"] = max(0.0, previous_hp - amount)
	_track_unit_hp_change(unit)
	if float(unit["hp"]) <= 0.0 and source_side != "" and source_side != String(unit["side"]):
		_track_unit_kill(source_side, source_card_id, source_unit_id)

func _damage_base(base_side: String, amount: float, source_side: String, source_card_id: String = "") -> void:
	if screen_mode != ScreenMode.BATTLE:
		return

	var base: Dictionary = bases[base_side]
	var previous_hp: float = float(base["hp"])
	base["hp"] = max(0.0, float(base["hp"]) - amount)
	if previous_hp > float(base["hp"]) and source_side != "" and source_side != base_side:
		_track_base_hit(source_side, source_card_id)
	while float(base["next_clear_threshold"]) > 0.0 and float(base["hp"]) <= float(base["next_clear_threshold"]):
		_trigger_clear(base_side, float(base["next_clear_threshold"]))
		base["next_clear_threshold"] = float(base["next_clear_threshold"]) - 100.0

	if float(base["hp"]) <= 0.0:
		var winner_side: String = source_side if source_side != base_side else _opponent(base_side)
		_finish_match(winner_side)

func _trigger_clear(base_side: String, threshold: float) -> void:
	for unit in units:
		unit["hp"] = 0.0
	bases[base_side]["clear_count"] = int(bases[base_side]["clear_count"]) + 1
	_push_event("%s基地跌破 %d 血，清屏。" % [_side_name(base_side), int(threshold)])

func _finish_match(winner_side: String) -> void:
	match_winner = winner_side
	screen_mode = ScreenMode.RESULT
	_push_event("%s胜利，用时 %s。" % [_side_name(winner_side), _format_time(battle_time)])
	queue_redraw()

func _update_spell_effects(delta: float) -> void:
	var active: Array[Dictionary] = []
	for effect in spell_effects:
		effect["time"] = float(effect["time"]) - delta
		if float(effect["time"]) > 0.0:
			active.append(effect)
	spell_effects = active

func _record_card_use(side: String, card_id: String) -> void:
	var key: String = "player_cards" if side == PLAYER else "bot_cards"
	var usage: Dictionary = stats[key]
	usage[card_id] = int(usage.get(card_id, 0)) + 1
	_track_card_play(side, card_id)

func _initialize_task_states() -> void:
	task_states = {
		PLAYER: {},
		BOT: {}
	}
	for card_id in selected_card_ids:
		_add_task_state(PLAYER, card_id)
	for card_id in BOT_DECK_IDS:
		_add_task_state(BOT, card_id)

func _add_task_state(side: String, card_id: String) -> void:
	var card: Dictionary = _card_by_id(card_id)
	if card.size() == 0 or not card.has("task"):
		return
	var side_tasks: Dictionary = task_states[side]
	side_tasks[card_id] = {
		"progress": 0.0,
		"completed": false,
		"evolved": false,
		"recent_uses": [],
		"unit_kills": {}
	}

func _active_card_by_id(side: String, card_id: String) -> Dictionary:
	var base_card: Dictionary = _card_by_id(card_id)
	if base_card.size() == 0:
		return {}
	var active_card: Dictionary = base_card.duplicate(true)
	active_card["id"] = card_id
	active_card["base_name"] = base_card["name"]
	active_card["evolved"] = false
	if not _is_card_evolved(side, card_id):
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

func _is_card_evolved(side: String, card_id: String) -> bool:
	if not task_states.has(side):
		return false
	var side_tasks: Dictionary = task_states[side]
	if not side_tasks.has(card_id):
		return false
	return bool(side_tasks[card_id].get("evolved", false))

func _task_progress_text(side: String, card_id: String) -> String:
	if _is_card_evolved(side, card_id):
		return "已进化"
	var state: Dictionary = _task_state(side, card_id)
	var card: Dictionary = _card_by_id(card_id)
	if state.size() == 0 or card.size() == 0 or not card.has("task"):
		return "无任务"
	var task: Dictionary = card["task"]
	var target_text: String = String(task.get("target_text", str(int(task.get("target", 1)))))
	var progress: float = float(state.get("progress", 0.0))
	if String(task.get("type", "")) == "mana_reached":
		return "%s %.1f/%s" % [String(task.get("progress_label", "进度")), progress, target_text]
	return "%s %d/%s" % [String(task.get("progress_label", "进度")), int(floor(progress)), target_text]

func _task_state(side: String, card_id: String) -> Dictionary:
	if not task_states.has(side):
		return {}
	var side_tasks: Dictionary = task_states[side]
	if not side_tasks.has(card_id):
		return {}
	return side_tasks[card_id]

func _check_mana_tasks(side: String) -> void:
	if not task_states.has(side):
		return
	var current_mana: float = player_mana if side == PLAYER else bot_mana
	var side_tasks: Dictionary = task_states[side]
	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = _card_by_id(card_id).get("task", {})
		if String(task.get("type", "")) != "mana_reached":
			continue
		state["progress"] = current_mana
		side_tasks[card_id] = state
		if current_mana >= float(task.get("target", 1.0)):
			_complete_task(side, card_id)

func _track_card_play(side: String, played_card_id: String) -> void:
	if not task_states.has(side):
		return
	var side_tasks: Dictionary = task_states[side]
	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = _card_by_id(card_id).get("task", {})
		var task_type: String = String(task.get("type", ""))
		var watch_card_id: String = String(task.get("watch_card_id", card_id))
		if played_card_id != watch_card_id:
			continue
		if task_type == "card_play_count" or task_type == "linked_card_play_count":
			_increment_task_progress(side, card_id, 1.0)
		elif task_type == "card_play_burst":
			_track_burst_card_play(side, card_id, state, task)

func _track_burst_card_play(side: String, card_id: String, state: Dictionary, task: Dictionary) -> void:
	var recent_uses: Array = state.get("recent_uses", [])
	recent_uses.append(battle_time)
	var window: float = float(task.get("window", 3.0))
	var filtered_uses: Array = []
	for raw_time in recent_uses:
		var use_time: float = float(raw_time)
		if battle_time - use_time <= window:
			filtered_uses.append(use_time)
	state["recent_uses"] = filtered_uses
	state["progress"] = float(filtered_uses.size())
	var side_tasks: Dictionary = task_states[side]
	side_tasks[card_id] = state
	if filtered_uses.size() >= int(task.get("target", 1)):
		_complete_task(side, card_id)

func _track_unit_hp_change(unit: Dictionary) -> void:
	var side: String = String(unit["side"])
	var card_id: String = String(unit["card_id"])
	var state: Dictionary = _task_state(side, card_id)
	var card: Dictionary = _card_by_id(card_id)
	if state.size() == 0 or card.size() == 0 or bool(state.get("completed", false)):
		return
	var task: Dictionary = card.get("task", {})
	if String(task.get("type", "")) != "unit_hp_below_ratio":
		return
	if float(unit["hp"]) < float(unit["max_hp"]) * float(task.get("hp_ratio", 0.6667)):
		_set_task_progress(side, card_id, 1.0)

func _track_unit_kill(source_side: String, source_card_id: String, source_unit_id: int) -> void:
	if source_card_id == "" or not task_states.has(source_side):
		return
	var side_tasks: Dictionary = task_states[source_side]
	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = _card_by_id(card_id).get("task", {})
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

func _track_base_hit(source_side: String, source_card_id: String) -> void:
	if source_card_id == "" or not task_states.has(source_side):
		return
	var side_tasks: Dictionary = task_states[source_side]
	for raw_card_id in side_tasks.keys():
		var card_id: String = String(raw_card_id)
		var state: Dictionary = side_tasks[card_id]
		if bool(state.get("completed", false)):
			continue
		var task: Dictionary = _card_by_id(card_id).get("task", {})
		if String(task.get("type", "")) == "base_hit_count" and source_card_id == String(task.get("watch_card_id", card_id)):
			_increment_task_progress(source_side, card_id, 1.0)

func _increment_task_progress(side: String, card_id: String, amount: float) -> void:
	var state: Dictionary = _task_state(side, card_id)
	if state.size() == 0:
		return
	_set_task_progress(side, card_id, float(state.get("progress", 0.0)) + amount)

func _set_task_progress(side: String, card_id: String, value: float) -> void:
	var side_tasks: Dictionary = task_states[side]
	var state: Dictionary = side_tasks[card_id]
	if bool(state.get("completed", false)):
		return
	var task: Dictionary = _card_by_id(card_id).get("task", {})
	var target: float = float(task.get("target", 1.0))
	state["progress"] = min(value, target)
	side_tasks[card_id] = state
	if value >= target:
		_complete_task(side, card_id)

func _complete_task(side: String, card_id: String) -> void:
	var side_tasks: Dictionary = task_states[side]
	var state: Dictionary = side_tasks[card_id]
	if bool(state.get("completed", false)):
		return
	var card: Dictionary = _card_by_id(card_id)
	var task: Dictionary = card.get("task", {})
	var evolution: Dictionary = card.get("evolution", {})
	state["completed"] = true
	state["evolved"] = evolution.size() > 0
	state["progress"] = float(task.get("target", state.get("progress", 0.0)))
	side_tasks[card_id] = state
	var task_key: String = "player_tasks_completed" if side == PLAYER else "bot_tasks_completed"
	var evolution_key: String = "player_evolutions" if side == PLAYER else "bot_evolutions"
	stats[task_key] = int(stats.get(task_key, 0)) + 1
	if evolution.size() > 0:
		stats[evolution_key] = int(stats.get(evolution_key, 0)) + 1
		_push_event("%s完成%s任务，进化为%s。" % [_side_name(side), card["name"], evolution["name"]])
	else:
		_push_event("%s完成%s任务。" % [_side_name(side), card["name"]])

func _update_unit_aura(unit: Dictionary, delta: float) -> void:
	var interval: float = float(unit.get("aura_interval", 0.0))
	if interval <= 0.0 or screen_mode != ScreenMode.BATTLE:
		return
	var timer: float = float(unit.get("aura_timer", interval)) - delta
	while timer <= 0.0 and screen_mode == ScreenMode.BATTLE and float(unit["hp"]) > 0.0:
		_pulse_unit_aura(unit)
		timer += interval
	unit["aura_timer"] = timer

func _pulse_unit_aura(unit: Dictionary) -> void:
	var enemy_side: String = _opponent(unit["side"])
	var radius: float = float(unit["aura_radius"])
	var damage: float = float(unit["aura_damage"])
	var hit_count: int = 0
	for enemy in units:
		if enemy["side"] == enemy_side and enemy["hp"] > 0.0 and enemy["pos"].distance_to(unit["pos"]) <= radius:
			_damage_unit(enemy, damage, unit["side"], String(unit["card_id"]), int(unit["id"]))
			hit_count += 1
	if unit["pos"].distance_to(_base_position(enemy_side)) <= radius + BASE_RADIUS:
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

func _cast_line_spell(side: String, card: Dictionary, target_position: Vector2) -> void:
	var start_position: Vector2 = _base_position(side)
	var radius: float = float(card["radius"])
	var damage: float = float(card["damage"])
	var base_damage: float = float(card["base_damage"])
	var hit_count: int = 0
	for unit in units:
		if unit["hp"] > 0.0 and _distance_to_segment(unit["pos"], start_position, target_position) <= radius:
			_damage_unit(unit, damage, side, String(card["id"]), 0)
			hit_count += 1
	for raw_base_side in [PLAYER, BOT]:
		var base_side: String = String(raw_base_side)
		if _distance_to_segment(_base_position(base_side), start_position, target_position) <= radius + BASE_RADIUS:
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
	_push_event("%s 施放 %s，路径命中 %d。" % [_side_name(side), card["name"], hit_count])

func _push_event(message: String) -> void:
	event_log.append(message)
	while event_log.size() > 6:
		event_log.pop_front()

func _draw() -> void:
	_update_layout_cache()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.06, 0.07, 0.09))
	if screen_mode == ScreenMode.DECK_SELECT:
		_draw_deck_select()
	else:
		_draw_battle()
		if screen_mode == ScreenMode.RESULT:
			_draw_result_overlay()

func _draw_deck_select() -> void:
	card_pick_rects.clear()
	var margin: float = max(18.0, size.x * 0.04)
	var title_y: float = 30.0
	_draw_text_line("奥术前线 V0.2", Rect2(margin, title_y, size.x - margin * 2.0, 34.0), 24, Color(0.95, 0.96, 0.98), HORIZONTAL_ALIGNMENT_CENTER)
	_draw_text_line("8 选 6；局内任务完成后自动进化。", Rect2(margin, title_y + 42.0, size.x - margin * 2.0, 24.0), 16, Color(0.68, 0.73, 0.80), HORIZONTAL_ALIGNMENT_CENTER)

	var grid_top: float = title_y + 82.0
	var gap: float = 10.0
	var grid_width: float = size.x - margin * 2.0
	var card_width: float = (grid_width - gap) * 0.5
	var bottom_space: float = 126.0
	var card_height: float = clamp((size.y - grid_top - bottom_space - gap * 3.0) / 4.0, 88.0, 128.0)

	for index in range(cards.size()):
		var col: int = index % 2
		var row: int = int(index / 2)
		var rect: Rect2 = Rect2(
			Vector2(margin + col * (card_width + gap), grid_top + row * (card_height + gap)),
			Vector2(card_width, card_height)
		)
		var card: Dictionary = cards[index]
		card_pick_rects[card["id"]] = rect
		_draw_pick_card(card, rect, selected_card_ids.has(card["id"]))

	var info_rect: Rect2 = Rect2(margin, size.y - 116.0, size.x - margin * 2.0, 22.0)
	_draw_text_line("已选 %d/%d" % [selected_card_ids.size(), CARD_PICK_COUNT], info_rect, 18, Color(0.86, 0.90, 0.95), HORIZONTAL_ALIGNMENT_CENTER)
	var hint: String = "点选卡牌切换配置；进化只影响后续使用。"
	if event_log.size() > 0:
		hint = event_log[event_log.size() - 1]
	_draw_text_line(hint, Rect2(margin, size.y - 94.0, size.x - margin * 2.0, 18.0), 13, Color(0.62, 0.68, 0.76), HORIZONTAL_ALIGNMENT_CENTER)
	start_rect = Rect2(margin, size.y - 78.0, size.x - margin * 2.0, 54.0)
	var start_enabled: bool = selected_card_ids.size() == CARD_PICK_COUNT
	var start_color: Color = Color(0.24, 0.56, 0.88) if start_enabled else Color(0.18, 0.20, 0.24)
	var start_text_color: Color = Color.WHITE if start_enabled else Color(0.50, 0.54, 0.60)
	_draw_panel(start_rect, start_color, 8.0, Color(0.58, 0.78, 0.98) if start_enabled else Color(0.26, 0.28, 0.32), 2.0)
	_draw_text_line("开始本地对局" if start_enabled else "请选择 6 张卡", start_rect, 20, start_text_color, HORIZONTAL_ALIGNMENT_CENTER)

func _draw_pick_card(card: Dictionary, rect: Rect2, selected: bool) -> void:
	var base_color: Color = Color(0.13, 0.15, 0.19)
	if selected:
		base_color = Color(0.14, 0.23, 0.31)
	_draw_panel(rect, base_color, 7.0, Color(0.34, 0.62, 0.84) if selected else Color(0.24, 0.27, 0.32), 2.0 if selected else 1.0)

	var icon_rect: Rect2 = Rect2(rect.position + Vector2(10.0, 12.0), Vector2(42.0, 42.0))
	if not _draw_card_art_icon(card, icon_rect.get_center(), 40.0, Color.WHITE):
		_draw_unit_shape(card, icon_rect.get_center(), 13.0, card["color"], Color(0.04, 0.05, 0.07), String(card["short_name"]), 18)
	_draw_text_line("%s  %d费" % [card["name"], int(card["cost"])], Rect2(rect.position + Vector2(60.0, 12.0), Vector2(rect.size.x - 70.0, 24.0)), 17, Color(0.95, 0.96, 0.98), HORIZONTAL_ALIGNMENT_LEFT)
	_draw_text_line(card["role"], Rect2(rect.position + Vector2(60.0, 38.0), Vector2(rect.size.x - 70.0, 20.0)), 14, Color(0.64, 0.71, 0.78), HORIZONTAL_ALIGNMENT_LEFT)

	var note: String = "trial：" + String(card["trial_note"])
	_draw_two_line_text(note, Rect2(rect.position + Vector2(10.0, 62.0), Vector2(rect.size.x - 20.0, 38.0)), 13, Color(0.70, 0.76, 0.82))
	var evolution: Dictionary = card.get("evolution", {})
	_draw_text_line("进化：%s" % String(evolution.get("name", "未设置")), Rect2(rect.position + Vector2(10.0, rect.size.y - 24.0), Vector2(rect.size.x - 20.0, 18.0)), 12, Color(0.86, 0.72, 0.42), HORIZONTAL_ALIGNMENT_RIGHT)

	if selected:
		draw_circle(rect.position + Vector2(rect.size.x - 18.0, 18.0), 10.0, Color(0.35, 0.78, 0.95))
		_draw_text_line("✓", Rect2(rect.position + Vector2(rect.size.x - 28.0, 7.0), Vector2(20.0, 20.0)), 16, Color(0.04, 0.06, 0.08), HORIZONTAL_ALIGNMENT_CENTER)

func _draw_battle() -> void:
	battle_card_rects.clear()
	_draw_battle_header()
	_draw_map()
	_draw_battle_card_bar()
	_draw_event_log()

func _draw_battle_header() -> void:
	var margin: float = 14.0
	var header: Rect2 = Rect2(margin, 12.0, size.x - margin * 2.0, 48.0)
	_draw_panel(header, Color(0.10, 0.12, 0.15), 7.0, Color(0.20, 0.23, 0.28), 1.0)
	var player_base: Dictionary = bases[PLAYER]
	var bot_base: Dictionary = bases[BOT]
	var left: String = "我方基地 %d/300  费 %.1f/10" % [int(ceil(float(player_base["hp"]))), player_mana]
	var right: String = "Bot基地 %d/300  费 %.1f/10" % [int(ceil(float(bot_base["hp"]))), bot_mana]
	_draw_text_line(left, Rect2(header.position + Vector2(12.0, 6.0), Vector2(header.size.x - 24.0, 18.0)), 15, Color(0.72, 0.88, 1.0), HORIZONTAL_ALIGNMENT_LEFT)
	_draw_text_line(right, Rect2(header.position + Vector2(12.0, 25.0), Vector2(header.size.x - 24.0, 18.0)), 15, Color(1.0, 0.72, 0.70), HORIZONTAL_ALIGNMENT_LEFT)
	_draw_text_line("清屏 %d:%d" % [int(player_base["clear_count"]), int(bot_base["clear_count"])], Rect2(header.position + Vector2(0.0, 15.0), header.size), 15, Color(0.78, 0.82, 0.88), HORIZONTAL_ALIGNMENT_RIGHT)

func _draw_map() -> void:
	_draw_panel(board_rect, Color(0.08, 0.09, 0.10), 8.0, Color(0.24, 0.27, 0.32), 1.0)
	var bot_half: Rect2 = Rect2(board_rect.position, Vector2(board_rect.size.x, board_rect.size.y * 0.5))
	var player_half: Rect2 = Rect2(board_rect.position + Vector2(0.0, board_rect.size.y * 0.5), Vector2(board_rect.size.x, board_rect.size.y * 0.5))
	draw_rect(bot_half.grow(-2.0), Color(0.24, 0.10, 0.10))
	draw_rect(player_half.grow(-2.0), Color(0.08, 0.16, 0.25))

	var river_top: float = _map_to_screen(Vector2(0.0, RIVER_Y - 2.1)).y
	var river_bottom: float = _map_to_screen(Vector2(0.0, RIVER_Y + 2.1)).y
	var river_rect: Rect2 = Rect2(Vector2(board_rect.position.x + 2.0, river_top), Vector2(board_rect.size.x - 4.0, river_bottom - river_top))
	draw_rect(river_rect, Color(0.07, 0.25, 0.34))

	for bridge_x in [16.0, 40.0]:
		var bridge_center: Vector2 = _map_to_screen(Vector2(float(bridge_x), RIVER_Y))
		var bridge_size: Vector2 = Vector2(_logic_to_pixels(7.2), _logic_to_pixels(8.0))
		var bridge_rect: Rect2 = Rect2(bridge_center - bridge_size * 0.5, bridge_size)
		draw_rect(bridge_rect, Color(0.48, 0.38, 0.28))
		draw_rect(bridge_rect, Color(0.78, 0.66, 0.46), false, max(1.0, _logic_to_pixels(0.25)))

	var deploy_line: float = _map_to_screen(Vector2(0.0, PLAYER_DEPLOY_MIN_Y)).y
	draw_line(Vector2(board_rect.position.x + 6.0, deploy_line), Vector2(board_rect.end.x - 6.0, deploy_line), Color(0.47, 0.73, 0.96, 0.55), 1.0)
	_draw_text_line("我方单位部署区", Rect2(board_rect.position.x + 8.0, deploy_line + 4.0, board_rect.size.x - 16.0, 18.0), 12, Color(0.60, 0.80, 0.98, 0.80), HORIZONTAL_ALIGNMENT_CENTER)

	_draw_base(BOT)
	_draw_base(PLAYER)
	_draw_clock()
	for effect in spell_effects:
		_draw_spell_effect(effect)
	for unit in units:
		_draw_unit(unit)

func _draw_base(side: String) -> void:
	var base: Dictionary = bases[side]
	var center: Vector2 = _map_to_screen(_base_position(side))
	var radius: float = _logic_to_pixels(BASE_RADIUS)
	var fill: Color = Color(0.58, 0.14, 0.13) if side == BOT else Color(0.10, 0.34, 0.58)
	draw_circle(center, radius, fill)
	draw_circle(center, radius, Color(0.90, 0.92, 0.95), false, 2.0)
	_draw_text_line("基", Rect2(center - Vector2(radius, radius * 0.65), Vector2(radius * 2.0, radius * 1.3)), 19, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)

	var bar_width: float = radius * 2.2
	var bar_rect: Rect2 = Rect2(center + Vector2(-bar_width * 0.5, radius + 5.0), Vector2(bar_width, 5.0))
	draw_rect(bar_rect, Color(0.08, 0.08, 0.09))
	draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * float(base["hp"]) / BASE_MAX_HP, bar_rect.size.y)), Color(0.86, 0.20, 0.18))

func _draw_clock() -> void:
	var center: Vector2 = _map_to_screen(Vector2(MAP_WIDTH * 0.5, RIVER_Y))
	var clock_rect: Rect2 = Rect2(center - Vector2(42.0, 17.0), Vector2(84.0, 34.0))
	_draw_panel(clock_rect, Color(0.04, 0.06, 0.08, 0.88), 6.0, Color(0.52, 0.67, 0.78), 1.0)
	_draw_text_line(_format_time(battle_time), clock_rect, 19, Color(0.90, 0.96, 1.0), HORIZONTAL_ALIGNMENT_CENTER)

func _draw_spell_effect(effect: Dictionary) -> void:
	var alpha: float = clamp(float(effect["time"]) / float(effect["max_time"]), 0.0, 1.0)
	var color: Color = effect["color"]
	if String(effect.get("mode", "circle")) == "line":
		var start: Vector2 = _map_to_screen(effect["from"])
		var end: Vector2 = _map_to_screen(effect["pos"])
		var width: float = max(2.0, _logic_to_pixels(float(effect["radius"]) * 2.0))
		color.a = 0.16 * alpha
		draw_line(start, end, color, width, true)
		color.a = 0.82 * alpha
		draw_line(start, end, color, max(2.0, width * 0.18), true)
		draw_circle(end, max(5.0, width * 0.16), color)
		_draw_text_line(effect["label"], Rect2(end - Vector2(24.0, 12.0), Vector2(48.0, 24.0)), 16, Color(1.0, 0.96, 0.78, alpha), HORIZONTAL_ALIGNMENT_CENTER)
		return
	color.a = 0.22 * alpha
	var center: Vector2 = _map_to_screen(effect["pos"])
	var radius: float = _logic_to_pixels(float(effect["radius"]))
	draw_circle(center, radius, color)
	color.a = 0.75 * alpha
	draw_circle(center, radius, color, false, 2.0)
	_draw_text_line(effect["label"], Rect2(center - Vector2(24.0, 12.0), Vector2(48.0, 24.0)), 16, Color(1.0, 0.96, 0.78, alpha), HORIZONTAL_ALIGNMENT_CENTER)

func _draw_unit(unit: Dictionary) -> void:
	var center: Vector2 = _map_to_screen(unit["pos"])
	var radius: float = _logic_to_pixels(float(unit["radius"]))
	var side: String = String(unit["side"])
	var fill: Color = unit["color"]
	if side == BOT:
		fill = fill.darkened(0.25)
	var stroke: Color = Color(0.06, 0.07, 0.08)
	_draw_unit_team_ring(center, radius, side)
	var texture: Texture2D = _unit_art_texture(String(unit.get("art_id", unit.get("card_id", ""))), _unit_art_view_for_side(side))
	if texture != null:
		_draw_unit_art(texture, center, radius)
	else:
		_draw_unit_shape(unit, center, radius, fill, stroke, String(unit["short_name"]), clamp(int(radius * 1.2), 12, 19))

	var hp_ratio: float = clamp(float(unit["hp"]) / float(unit["max_hp"]), 0.0, 1.0)
	var bar_rect: Rect2 = Rect2(center + Vector2(-radius, radius + 6.0), Vector2(radius * 2.0, 4.0))
	draw_rect(bar_rect, Color(0.04, 0.04, 0.05))
	draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * hp_ratio, bar_rect.size.y)), Color(0.28, 0.86, 0.42) if side == PLAYER else Color(0.95, 0.36, 0.32))

func _unit_art_view_for_side(side: String) -> String:
	return UNIT_ART_BACK if side == PLAYER else UNIT_ART_FRONT

func _card_art_id(card: Dictionary) -> String:
	return String(card.get("evolved_id", card.get("id", "")))

func _unit_art_texture(art_id: String, view: String) -> Texture2D:
	if art_id == "":
		return null
	var key: String = "%s:%s" % [art_id, view]
	if unit_art_cache.has(key):
		return unit_art_cache[key]

	var path: String = "%s%s_%s.png" % [UNIT_ART_ROOT, art_id, view]
	var texture: Texture2D = null
	if FileAccess.file_exists(path):
		var image: Image = Image.load_from_file(path)
		if image != null and not image.is_empty():
			texture = ImageTexture.create_from_image(image)
	unit_art_cache[key] = texture
	return texture

func _draw_unit_team_ring(center: Vector2, radius: float, side: String) -> void:
	var color: Color = Color(0.32, 0.68, 1.0) if side == PLAYER else Color(1.0, 0.30, 0.24)
	var fill: Color = color
	fill.a = 0.13
	var ring_radius: float = max(4.0, radius * 1.08)
	draw_circle(center, ring_radius, fill)
	draw_circle(center, ring_radius, color, false, max(2.0, radius * 0.12))

func _draw_unit_art(texture: Texture2D, center: Vector2, radius: float) -> void:
	var height: float = max(18.0, radius * UNIT_ART_HEIGHT_SCALE)
	var aspect: float = float(texture.get_width()) / max(1.0, float(texture.get_height()))
	var art_size: Vector2 = Vector2(height * aspect, height)
	var bottom_center: Vector2 = center + Vector2(0.0, radius * UNIT_ART_FOOT_OFFSET)
	var rect: Rect2 = Rect2(Vector2(bottom_center.x - art_size.x * 0.5, bottom_center.y - art_size.y), art_size)
	draw_texture_rect(texture, rect, false)

func _draw_card_art_icon(card: Dictionary, center: Vector2, height: float, modulate: Color) -> bool:
	if String(card.get("kind", "")) != "unit":
		return false
	var texture: Texture2D = _unit_art_texture(_card_art_id(card), UNIT_ART_FRONT)
	if texture == null:
		return false
	_draw_texture_centered_height(texture, center, height, modulate)
	return true

func _draw_texture_centered_height(texture: Texture2D, center: Vector2, height: float, modulate: Color) -> void:
	var aspect: float = float(texture.get_width()) / max(1.0, float(texture.get_height()))
	var draw_size: Vector2 = Vector2(height * aspect, height)
	var rect: Rect2 = Rect2(center - draw_size * 0.5, draw_size)
	draw_texture_rect(texture, rect, false, modulate)

func _draw_unit_shape(source: Dictionary, center: Vector2, radius: float, fill: Color, stroke: Color, label: String, label_size: int) -> void:
	var shape: String = String(source.get("shape", "circle"))
	if shape == "square":
		var rect: Rect2 = Rect2(center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
		draw_rect(rect, fill)
		draw_rect(rect, stroke, false, max(1.0, radius * 0.14))
	elif shape == "triangle":
		var points: PackedVector2Array = PackedVector2Array([
			center + Vector2(0.0, -radius),
			center + Vector2(radius * 0.92, radius * 0.72),
			center + Vector2(-radius * 0.92, radius * 0.72)
		])
		var outline: PackedVector2Array = PackedVector2Array(points)
		outline.append(points[0])
		draw_colored_polygon(points, fill)
		draw_polyline(outline, stroke, max(1.0, radius * 0.14))
	else:
		draw_circle(center, radius, fill)
		draw_circle(center, radius, stroke, false, max(1.0, radius * 0.14))
	_draw_text_line(label, Rect2(center - Vector2(radius, radius * 0.72), Vector2(radius * 2.0, radius * 1.44)), label_size, Color(0.04, 0.05, 0.06), HORIZONTAL_ALIGNMENT_CENTER)

func _draw_battle_card_bar() -> void:
	var margin: float = 12.0
	var bar_top: float = size.y - 162.0
	var bar_rect: Rect2 = Rect2(margin, bar_top, size.x - margin * 2.0, 148.0)
	_draw_panel(bar_rect, Color(0.10, 0.12, 0.15), 8.0, Color(0.22, 0.25, 0.29), 1.0)
	_draw_text_line("常驻卡组  任务 %d/%d  进化 %d" % [int(stats.get("player_tasks_completed", 0)), selected_card_ids.size(), int(stats.get("player_evolutions", 0))], Rect2(bar_rect.position + Vector2(10.0, 8.0), Vector2(bar_rect.size.x - 20.0, 18.0)), 14, Color(0.75, 0.80, 0.86), HORIZONTAL_ALIGNMENT_LEFT)
	_draw_mana_bar(Rect2(bar_rect.position + Vector2(10.0, 32.0), Vector2(bar_rect.size.x - 20.0, 10.0)))

	var gap: float = 6.0
	var card_width: float = (bar_rect.size.x - 20.0 - gap * 5.0) / 6.0
	var card_height: float = 88.0
	var y: float = bar_rect.position.y + 50.0
	for index in range(selected_card_ids.size()):
		var card_id: String = selected_card_ids[index]
		var base_card: Dictionary = _card_by_id(card_id)
		var card: Dictionary = _active_card_by_id(PLAYER, card_id)
		var rect: Rect2 = Rect2(bar_rect.position.x + 10.0 + index * (card_width + gap), y, card_width, card_height)
		battle_card_rects[card_id] = rect
		_draw_battle_card(base_card, card, rect, selected_battle_card_id == card_id)

func _draw_mana_bar(rect: Rect2) -> void:
	draw_rect(rect, Color(0.05, 0.06, 0.08))
	draw_rect(Rect2(rect.position, Vector2(rect.size.x * player_mana / MANA_MAX, rect.size.y)), Color(0.22, 0.56, 0.92))
	for tick in range(int(MANA_MAX) + 1):
		var x: float = rect.position.x + rect.size.x * float(tick) / MANA_MAX
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), Color(0.95, 0.96, 1.0, 0.18), 1.0)

func _draw_battle_card(base_card: Dictionary, card: Dictionary, rect: Rect2, selected: bool) -> void:
	var affordable: bool = player_mana >= float(card["cost"])
	var bg: Color = Color(0.14, 0.17, 0.21) if affordable else Color(0.09, 0.10, 0.12)
	if selected:
		bg = Color(0.18, 0.30, 0.38)
	_draw_panel(rect, bg, 7.0, Color(0.48, 0.78, 0.94) if selected else Color(0.24, 0.27, 0.32), 2.0 if selected else 1.0)
	var icon_center: Vector2 = rect.position + Vector2(rect.size.x * 0.5, 24.0)
	if not _draw_card_art_icon(card, icon_center, 34.0, Color.WHITE if affordable else Color(0.42, 0.44, 0.46)):
		_draw_unit_shape(card, icon_center, 12.0, card["color"] if affordable else Color(0.30, 0.32, 0.34), Color(0.04, 0.05, 0.07), String(card["short_name"]), 16)
	_draw_text_line(card["name"], Rect2(rect.position + Vector2(3.0, 42.0), Vector2(rect.size.x - 6.0, 18.0)), 12, Color(0.92, 0.94, 0.96) if affordable else Color(0.46, 0.49, 0.54), HORIZONTAL_ALIGNMENT_CENTER)
	_draw_text_line("%d费" % int(card["cost"]), Rect2(rect.position + Vector2(3.0, 60.0), Vector2(rect.size.x - 6.0, 15.0)), 12, Color(0.70, 0.84, 1.0) if affordable else Color(0.42, 0.46, 0.52), HORIZONTAL_ALIGNMENT_CENTER)
	_draw_text_line(_task_progress_text(PLAYER, String(base_card["id"])), Rect2(rect.position + Vector2(3.0, 74.0), Vector2(rect.size.x - 6.0, 13.0)), 10, Color(0.90, 0.76, 0.46) if not bool(card.get("evolved", false)) else Color(0.47, 0.92, 0.72), HORIZONTAL_ALIGNMENT_CENTER)

func _draw_event_log() -> void:
	var log_rect: Rect2 = Rect2(14.0, board_rect.end.y + 8.0, size.x - 28.0, max(0.0, size.y - board_rect.end.y - 180.0))
	if log_rect.size.y < 22.0:
		return
	_draw_panel(log_rect, Color(0.06, 0.07, 0.09, 0.72), 7.0, Color(0.20, 0.23, 0.27), 1.0)
	var line_y: float = log_rect.position.y + 6.0
	for index in range(event_log.size()):
		_draw_text_line(event_log[index], Rect2(log_rect.position.x + 8.0, line_y, log_rect.size.x - 16.0, 17.0), 12, Color(0.72, 0.77, 0.84), HORIZONTAL_ALIGNMENT_LEFT)
		line_y += 17.0

func _draw_result_overlay() -> void:
	var overlay: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(overlay, Color(0.02, 0.025, 0.035, 0.74))
	var panel_width: float = min(size.x - 36.0, 440.0)
	var panel_height: float = 286.0
	var panel: Rect2 = Rect2(Vector2((size.x - panel_width) * 0.5, (size.y - panel_height) * 0.5), Vector2(panel_width, panel_height))
	_draw_panel(panel, Color(0.11, 0.13, 0.16), 8.0, Color(0.38, 0.46, 0.55), 2.0)
	_draw_text_line("%s胜利" % _side_name(match_winner), Rect2(panel.position + Vector2(18.0, 20.0), Vector2(panel.size.x - 36.0, 30.0)), 25, Color(0.94, 0.96, 1.0), HORIZONTAL_ALIGNMENT_CENTER)
	_draw_text_line("用时 %s；单位阵亡 %d；法术施放 %d" % [_format_time(battle_time), int(stats["units_lost"]), int(stats["spell_casts"])], Rect2(panel.position + Vector2(18.0, 62.0), Vector2(panel.size.x - 36.0, 22.0)), 15, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	_draw_text_line("清屏次数 我方 %d / Bot %d" % [int(bases[PLAYER]["clear_count"]), int(bases[BOT]["clear_count"])], Rect2(panel.position + Vector2(18.0, 92.0), Vector2(panel.size.x - 36.0, 22.0)), 15, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	_draw_text_line("耗费 我方 %.0f / Bot %.0f" % [float(stats["player_spent"]), float(stats["bot_spent"])], Rect2(panel.position + Vector2(18.0, 120.0), Vector2(panel.size.x - 36.0, 22.0)), 15, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	_draw_text_line("任务 我方 %d / Bot %d；进化 我方 %d / Bot %d" % [int(stats.get("player_tasks_completed", 0)), int(stats.get("bot_tasks_completed", 0)), int(stats.get("player_evolutions", 0)), int(stats.get("bot_evolutions", 0))], Rect2(panel.position + Vector2(18.0, 148.0), Vector2(panel.size.x - 36.0, 22.0)), 15, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)

	restart_rect = Rect2(panel.position + Vector2(24.0, panel.size.y - 78.0), Vector2((panel.size.x - 58.0) * 0.5, 48.0))
	deck_rect = Rect2(Vector2(restart_rect.end.x + 10.0, restart_rect.position.y), restart_rect.size)
	_draw_panel(restart_rect, Color(0.24, 0.56, 0.88), 7.0, Color(0.58, 0.78, 0.98), 1.5)
	_draw_text_line("再战", restart_rect, 18, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	_draw_panel(deck_rect, Color(0.18, 0.21, 0.25), 7.0, Color(0.36, 0.42, 0.50), 1.5)
	_draw_text_line("换卡", deck_rect, 18, Color(0.90, 0.93, 0.96), HORIZONTAL_ALIGNMENT_CENTER)

func _update_layout_cache() -> void:
	if screen_mode == ScreenMode.DECK_SELECT:
		return

	var top: float = 70.0
	var bottom: float = 232.0
	var margin: float = 12.0
	var available: Rect2 = Rect2(margin, top, size.x - margin * 2.0, max(100.0, size.y - top - bottom))
	var map_aspect: float = MAP_WIDTH / MAP_HEIGHT
	var map_width: float = available.size.x
	var map_height: float = map_width / map_aspect
	if map_height > available.size.y:
		map_height = available.size.y
		map_width = map_height * map_aspect
	board_rect = Rect2(available.position + Vector2((available.size.x - map_width) * 0.5, 0.0), Vector2(map_width, map_height))

func _map_to_screen(logic_position: Vector2) -> Vector2:
	return board_rect.position + Vector2(
		logic_position.x / MAP_WIDTH * board_rect.size.x,
		logic_position.y / MAP_HEIGHT * board_rect.size.y
	)

func _screen_to_map(screen_position: Vector2) -> Vector2:
	return Vector2(
		clamp((screen_position.x - board_rect.position.x) / board_rect.size.x * MAP_WIDTH, 0.0, MAP_WIDTH),
		clamp((screen_position.y - board_rect.position.y) / board_rect.size.y * MAP_HEIGHT, 0.0, MAP_HEIGHT)
	)

func _logic_to_pixels(value: float) -> float:
	return value / MAP_HEIGHT * board_rect.size.y

func _clamped_deploy_position(side: String, position: Vector2) -> Vector2:
	var min_y: float = PLAYER_DEPLOY_MIN_Y if side == PLAYER else 6.0
	var max_y: float = 94.0 if side == PLAYER else BOT_DEPLOY_MAX_Y
	return Vector2(
		clamp(position.x, 4.5, MAP_WIDTH - 4.5),
		clamp(position.y, min_y, max_y)
	)

func _base_position(side: String) -> Vector2:
	if side == PLAYER:
		return Vector2(MAP_WIDTH * 0.5, 94.0)
	return Vector2(MAP_WIDTH * 0.5, 6.0)

func _opponent(side: String) -> String:
	return BOT if side == PLAYER else PLAYER

func _side_name(side: String) -> String:
	return "我方" if side == PLAYER else "Bot"

func _bridge_x(seed_value: int) -> float:
	return 16.0 if seed_value % 2 == 0 else 40.0

func _nearest_bridge_x(x: float) -> float:
	return 16.0 if abs(x - 16.0) <= abs(x - 40.0) else 40.0

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

func _distance_to_segment(point: Vector2, segment_start: Vector2, segment_end: Vector2) -> float:
	var segment: Vector2 = segment_end - segment_start
	var length_squared: float = segment.length_squared()
	if length_squared <= 0.0001:
		return point.distance_to(segment_start)
	var t: float = clamp((point - segment_start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(segment_start + segment * t)

func _card_by_id(card_id: String) -> Dictionary:
	for card in cards:
		if card["id"] == card_id:
			return card
	return {}

func _format_time(seconds: float) -> String:
	var total_seconds: int = int(floor(seconds))
	return "%02d:%02d" % [int(total_seconds / 60), total_seconds % 60]

func _draw_panel(rect: Rect2, fill: Color, radius: float, stroke: Color, stroke_width: float) -> void:
	draw_rect(rect, fill)
	draw_rect(rect, stroke, false, stroke_width)

func _draw_text_line(text: String, rect: Rect2, font_size: int, color: Color, alignment: HorizontalAlignment) -> void:
	if ui_font == null:
		return
	var y: float = rect.position.y + rect.size.y * 0.5 + font_size * 0.36
	draw_string(ui_font, Vector2(rect.position.x, y), text, alignment, rect.size.x, font_size, color)

func _draw_two_line_text(text: String, rect: Rect2, font_size: int, color: Color) -> void:
	var limit: int = max(8, int(rect.size.x / max(8.0, font_size * 0.72)))
	var first: String = text
	var second: String = ""
	if text.length() > limit:
		first = text.substr(0, limit)
		second = text.substr(limit, limit)
	_draw_text_line(first, Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.5)), font_size, color, HORIZONTAL_ALIGNMENT_LEFT)
	if second != "":
		_draw_text_line(second, Rect2(rect.position + Vector2(0.0, rect.size.y * 0.5), Vector2(rect.size.x, rect.size.y * 0.5)), font_size, color, HORIZONTAL_ALIGNMENT_LEFT)
