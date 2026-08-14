# 战斗模拟核心：V0.4 (P1) 定点整数版。
# 纯逻辑，不依赖 UI。持有对局运行时状态并驱动战斗。
#
# 定点约定：
#   - HP / Damage / Base Damage / Aura Damage → 纯整数 int（整数量纲，不乘 FP）
#   - 费用 Mana → Q*1000 int（1 费 = 1000，允许 0.5 增长）
#   - 位置 / 半径 / 速度 / 射程 / AOE 半径 → Q*1000 int（Dictionary pos_fp）
#   - 攻击计时 attack_timer / attack_cooldown / aura_timer / aura_interval → Q*1000 int（秒）
#   - 时间 / battle_time → 直接用 tick_count int（每 tick +1，显示时 tick/TICK_RATE）
#
# 距离比较统一用平方距离（Fp.dist_sq），绝不调用 sqrt。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const MapMath = preload("res://scripts/support/map_math.gd")
const Command = preload("res://scripts/networking/command.gd")
const Fp = preload("res://scripts/support/fp_math.gd")

# 运行时状态
var tick_count: int = 0
var player_mana_fp: int = 0
var bot_mana_fp: int = 0
var units: Array[Dictionary] = []
var spell_effects: Array[Dictionary] = []
var persistent_effects: Array[Dictionary] = []
var bases: Dictionary = {}
var stats: Dictionary = {}
var event_log: Array[String] = []
var next_unit_id: int = 1
var match_winner: String = ""
var running: bool = false
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var task_system: RefCounted = null
var evolution_flashes: Dictionary = {}
var rng_seed: int = 10101
var card_cooldowns: Dictionary = {Config.PLAYER: {}, Config.BOT: {}}


func _init() -> void:
	rng.seed = rng_seed


func set_shared_seed(seed: int) -> void:
	rng_seed = seed
	rng.seed = seed


func setup(task_sys: RefCounted) -> void:
	task_system = task_sys


# —— 定点辅助 ——
func _FP() -> int:
	return Config.FP_SCALE


func _F() -> float:
	return Config.FP_SCALE_F


func _to_fp(v: float) -> int:
	return Fp.to_fp(v)


func _tick_dt_fp() -> int:
	# 从 Config 取当前固定步长；60Hz 时约为 17 (Q*1000)。
	return _to_fp(Config.TICK_DT)


func _mana_max_fp() -> int:
	return int(Config.MANA_MAX * _F() + 0.5)


func _starting_mana_fp() -> int:
	return int(Config.STARTING_MANA * _F() + 0.5)


func _mana_per_tick_fp() -> int:
	# MANA_PER_SECOND * TICK_DT，Q*1000
	var per_sec_fp: int = _to_fp(Config.MANA_PER_SECOND)
	var dt_fp: int = _tick_dt_fp()
	# (per_sec_fp * dt_fp) / FP_SCALE
	return int((int(per_sec_fp) * int(dt_fp)) / int(_FP()))


func _base_radius_fp() -> int:
	return _to_fp(Config.BASE_RADIUS)


func _base_max_hp_int() -> int:
	return int(Config.BASE_MAX_HP)  # 300，纯 int HP


func _map_width_fp() -> int:
	return int(Config.MAP_WIDTH * _F() + 0.5)


func _map_height_fp() -> int:
	return int(Config.MAP_HEIGHT * _F() + 0.5)


# 把 float Vector2 转为定点向量。部署/命令入口调用。
func _logical_vec_to_fp(v: Vector2) -> Dictionary:
	return {"x": _to_fp(v.x), "y": _to_fp(v.y)}


# —— 对局开始 ——
func start_battle() -> void:
	tick_count = 0
	player_mana_fp = _starting_mana_fp()
	bot_mana_fp = _starting_mana_fp()
	next_unit_id = 1
	units.clear()
	spell_effects.clear()
	persistent_effects.clear()
	event_log.clear()
	match_winner = ""
	running = true
	evolution_flashes = {}
	card_cooldowns = {Config.PLAYER: {}, Config.BOT: {}}
	rng.seed = rng_seed
	bases = {
		Config.PLAYER: {
			"hp": _base_max_hp_int(),
			"max_hp": _base_max_hp_int(),
			"next_clear_threshold_fp": _to_fp(200.0),
			"clear_count": 0
		},
		Config.BOT: {
			"hp": _base_max_hp_int(),
			"max_hp": _base_max_hp_int(),
			"next_clear_threshold_fp": _to_fp(200.0),
			"clear_count": 0
		}
	}
	stats = {
		"player_cards": {},
		"bot_cards": {},
		"player_spent_fp": 0,
		"bot_spent_fp": 0,
		"units_lost": 0,
		"spell_casts": 0,
		"player_tasks_completed": 0,
		"bot_tasks_completed": 0,
		"player_evolutions": 0,
		"bot_evolutions": 0
	}


# 对外读取的 float 兼容层（供 UI / task_system / Bot 读取费用、时间）
func battle_time() -> float:
	return float(tick_count) * Config.TICK_DT


func player_mana() -> float:
	return float(player_mana_fp) / _F()


func bot_mana() -> float:
	return float(bot_mana_fp) / _F()


# 保留老接口别名（保持 task_system / painter 调用）。
var battle_time_f: float = 0.0  # 暂时保留，兼容 task_system.read（P1-4 同步改 task_system 后移除）


# 推进 1 tick：时间 + 费用回复。
func advance_time(_unused_delta: float) -> void:
	tick_count += 1
	_update_card_cooldowns()
	var mpt: int = _mana_per_tick_fp()
	player_mana_fp = min(_mana_max_fp(), player_mana_fp + mpt)
	bot_mana_fp = min(_mana_max_fp(), bot_mana_fp + mpt)


# —— 命令执行 ——
func execute_command(cmd: Dictionary, task_sys: RefCounted) -> void:
	var t: String = String(cmd.get("type", ""))
	if t == Command.CMD_NO_OP:
		return
	if t == Command.CMD_CHECKSUM:
		# CHECKSUM 命令不改变模拟状态，由锁步调度层比对
		return
	if t != Command.CMD_PLAY_CARD:
		return
	var side: String = String(cmd.get("side", ""))
	var card_id: String = String(cmd.get("card_id", ""))
	if side == "" or card_id == "":
		return
	var card: Dictionary = task_sys.active_card_by_id(side, card_id)
	var target_fp: Dictionary = Command.command_target_fp(cmd)
	try_play_card_fp(side, card, target_fp)


# —— 出牌统一入口（定点版）——
func try_play_card_fp(side: String, card: Dictionary, target_fp: Dictionary) -> bool:
	if card.size() == 0:
		return false
	var card_id: String = String(card["id"])
	var cooldown_ticks: int = card_cooldown_ticks(side, card_id)
	if cooldown_ticks > 0:
		push_event("%s仍在冷却（%.1f 秒）。" % [card["name"], max(0.1, float(cooldown_ticks) / float(Config.TICK_RATE))])
		return false

	var cost_fp: int = int(float(card["cost"]) * _F() + 0.5)
	if side == Config.PLAYER:
		if player_mana_fp < cost_fp:
			push_event("%s 费用不足。" % card["name"])
			return false
	else:
		if bot_mana_fp < cost_fp:
			return false

	if card["kind"] == "unit":
		var deploy_min_y_fp: int = _to_fp(Config.PLAYER_DEPLOY_MIN_Y)
		var deploy_max_y_fp: int = _to_fp(Config.BOT_DEPLOY_MAX_Y)
		var tgt_y_fp: int = int(target_fp.get("y", 0))
		if side == Config.PLAYER and tgt_y_fp < deploy_min_y_fp:
			push_event("单位只能部署在己方半场。")
			return false
		if side == Config.BOT and tgt_y_fp > deploy_max_y_fp:
			return false
	elif bool(card.get("cast_own_half_only", false)):
		var river_y_fp: int = _to_fp(Config.RIVER_Y)
		var spell_y_fp: int = int(target_fp.get("y", 0))
		if side == Config.PLAYER and spell_y_fp < river_y_fp:
			push_event("该法术只能施放在己方半场。")
			return false
		if side == Config.BOT and spell_y_fp > river_y_fp:
			return false

	if side == Config.PLAYER:
		player_mana_fp -= cost_fp
		stats["player_spent_fp"] = int(stats["player_spent_fp"]) + cost_fp
	else:
		bot_mana_fp -= cost_fp
		stats["bot_spent_fp"] = int(stats["bot_spent_fp"]) + cost_fp
	var cooldown_seconds: float = float(card.get("play_cooldown", 0.0))
	if cooldown_seconds > 0.0:
		var side_cooldowns: Dictionary = card_cooldowns.get(side, {})
		side_cooldowns[card_id] = max(1, int(round(cooldown_seconds * float(Config.TICK_RATE))))
		card_cooldowns[side] = side_cooldowns

	if card["kind"] == "unit":
		_spawn_units(side, card, target_fp)
	else:
		_cast_spell(side, card, target_fp)

	_record_card_use(side, card_id)
	return true


# —— 出牌统一入口（float 兼容版，供调试/旧调用方使用）——
func try_play_card(side: String, card: Dictionary, target_position: Vector2) -> bool:
	return try_play_card_fp(side, card, _logical_vec_to_fp(target_position))


func card_cooldown_ticks(side: String, card_id: String) -> int:
	var side_cooldowns: Dictionary = card_cooldowns.get(side, {})
	return max(0, int(side_cooldowns.get(card_id, 0)))


func card_cooldown_seconds(side: String, card_id: String) -> float:
	return float(card_cooldown_ticks(side, card_id)) / float(Config.TICK_RATE)


func _update_card_cooldowns() -> void:
	for raw_side in [Config.PLAYER, Config.BOT]:
		var side: String = String(raw_side)
		var current: Dictionary = card_cooldowns.get(side, {})
		var remaining: Dictionary = {}
		for raw_card_id in current.keys():
			var ticks: int = int(current[raw_card_id]) - 1
			if ticks > 0:
				remaining[String(raw_card_id)] = ticks
		card_cooldowns[side] = remaining


# —— 单位生成（定点）——
func _spawn_units(side: String, card: Dictionary, target_fp: Dictionary) -> void:
	var count: int = int(card["count"])
	var center_fp: Dictionary = MapMath.clamped_deploy_position_fp(side, target_fp)
	var positions: Array[Dictionary] = _formation_positions(side, center_fp, count, "circle")
	for spawn_fp in positions:
		var unit: Dictionary = _spawn_unit_definition(side, card, spawn_fp, true)
		_apply_entry_summons(unit, card)
	push_event("%s 部署 %s。" % [MapMath.side_name(side), card["name"]])


func _spawn_unit_definition(side: String, definition: Dictionary, position_fp: Dictionary, clamp_to_deploy: bool = false) -> Dictionary:
	var spawn_fp: Dictionary = MapMath.clamped_deploy_position_fp(side, position_fp) if clamp_to_deploy else _clamp_map_position_fp(position_fp)
	var hp_int: int = int(float(definition.get("hp", 1.0)) + 0.5)
	var damage_int: int = int(float(definition.get("damage", 0.0)) + 0.5)
	var attack_cd_fp: int = _to_fp(float(definition.get("attack_cooldown", 1.0)))
	var range_fp: int = _to_fp(float(definition.get("range", 1.0)))
	var speed_fp: int = _to_fp(float(definition.get("speed", 1.0)))
	var periodic: Dictionary = definition.get("periodic_summon", {})
	var unit: Dictionary = {
		"id": next_unit_id,
		"side": side,
		"card_id": String(definition.get("id", "")),
		"art_id": String(definition.get("evolved_id", definition.get("id", ""))),
		"name": String(definition.get("name", "")),
		"short_name": String(definition.get("short_name", "")),
		"hp": hp_int,
		"max_hp": hp_int,
		"base_damage": damage_int,
		"damage": damage_int,
		"base_attack_cooldown_fp": attack_cd_fp,
		"attack_cooldown_fp": attack_cd_fp,
		"attack_timer_fp": _to_fp(rng.randf_range(0.0, 0.35)),
		"base_range_fp": range_fp,
		"range_fp": range_fp,
		"base_speed_fp": speed_fp,
		"speed_fp": speed_fp,
		"radius_fp": int(float(definition.get("radius", 0.75)) * Config.UNIT_RADIUS_SCALE * _F() + 0.5),
		"aoe_radius_fp": _to_fp(float(definition.get("aoe_radius", 0.0))),
		"multi_target_count": int(definition.get("multi_target_count", 1)),
		"aura_interval_fp": _to_fp(float(definition.get("aura_interval", 0.0))),
		"aura_timer_fp": _to_fp(float(definition.get("aura_interval", 0.0))),
		"aura_radius_fp": _to_fp(float(definition.get("aura_radius", 0.0))),
		"aura_damage": int(float(definition.get("aura_damage", 0.0)) + 0.5),
		"shape": String(definition.get("shape", "circle")),
		"color": definition.get("color", Color.WHITE),
		"target_base_only": bool(definition.get("target_base_only", false)),
		"tags": definition.get("tags", []).duplicate(),
		"on_death": definition.get("on_death", {}).duplicate(true),
		"bridge_summons": definition.get("bridge_summons", []).duplicate(true),
		"bridge_triggered": false,
		"squire_death_buff": definition.get("squire_death_buff", {}).duplicate(true),
		"squire_buff_stacks": 0,
		"squire_aura": definition.get("squire_aura", {}).duplicate(true),
		"protect_squires": bool(definition.get("protect_squires", false)),
		"protection_radius_fp": _to_fp(float(definition.get("protection_radius", 0.0))),
		"sync_squire_speed": bool(definition.get("sync_squire_speed", false)),
		"damage_reduction_percent": 0,
		"periodic_summon": periodic.duplicate(true),
		"periodic_summon_timer_fp": _to_fp(float(periodic.get("interval", 0.0))),
		"dead_processed": false,
		"pos_fp": spawn_fp
	}
	next_unit_id += 1
	units.append(unit)
	if task_system != null:
		task_system.track_unit_spawn(side, unit)
	return unit


func _apply_entry_summons(parent: Dictionary, definition: Dictionary) -> void:
	for raw_request in definition.get("entry_summons", []):
		var request: Dictionary = raw_request
		_summon_derivatives(String(parent["side"]), String(request.get("unit_id", "")), int(request.get("count", 1)), parent["pos_fp"], String(request.get("formation", "circle")))


func _summon_derivatives(side: String, unit_id: String, count: int, center_fp: Dictionary, formation: String) -> void:
	var definition: Dictionary = task_system.card_by_id(unit_id)
	if definition.is_empty() or String(definition.get("kind", "")) != "unit":
		return
	for spawn_fp in _formation_positions(side, center_fp, count, formation):
		_spawn_unit_definition(side, definition, spawn_fp, false)


func _formation_positions(side: String, center_fp: Dictionary, count: int, formation: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var spread_fp: int = _to_fp(1.9 * Config.UNIT_RADIUS_SCALE)
	var behind_sign: int = 1 if side == Config.PLAYER else -1
	for index in range(count):
		var offset_x_fp: int = 0
		var offset_y_fp: int = 0
		if formation == "random_near":
			offset_x_fp = _to_fp(rng.randf_range(-2.2, 2.2))
			offset_y_fp = _to_fp(rng.randf_range(-2.2, 2.2))
		elif formation == "behind":
			offset_x_fp = _to_fp((float(index) - float(count - 1) * 0.5) * 2.0)
			offset_y_fp = _to_fp(3.0 * behind_sign)
		elif formation == "flanks":
			offset_x_fp = _to_fp(-2.5 if index % 2 == 0 else 2.5)
		elif formation == "triangle":
			var triangle: Array[Vector2] = [Vector2(0.0, -1.8), Vector2(-1.8, 1.5), Vector2(1.8, 1.5)]
			var p: Vector2 = triangle[index % triangle.size()]
			offset_x_fp = _to_fp(p.x)
			offset_y_fp = _to_fp(p.y * behind_sign)
		elif count > 1:
			var angle: float = TAU * float(index) / float(count)
			offset_x_fp = int(cos(angle) * float(spread_fp))
			offset_y_fp = int(sin(angle) * float(spread_fp))
		result.append(_clamp_map_position_fp({"x": int(center_fp.get("x", 0)) + offset_x_fp, "y": int(center_fp.get("y", 0)) + offset_y_fp}))
	return result


func _clamp_map_position_fp(position_fp: Dictionary) -> Dictionary:
	var margin_fp: int = _to_fp(3.5)
	return {
		"x": Fp.clamp_int(int(position_fp.get("x", 0)), margin_fp, _map_width_fp() - margin_fp),
		"y": Fp.clamp_int(int(position_fp.get("y", 0)), margin_fp, _map_height_fp() - margin_fp)
	}


# —— 法术施放（定点）——
func _cast_spell(side: String, card: Dictionary, target_fp: Dictionary) -> void:
	var travel_time: float = float(card.get("projectile_travel_time", 0.0))
	if travel_time > 0.0:
		_launch_spell_projectile(side, card, target_fp, travel_time)
		return
	_resolve_spell(side, card, target_fp)


func _launch_spell_projectile(side: String, card: Dictionary, target_fp: Dictionary, travel_time: float) -> void:
	var duration_ticks: int = max(1, int(round(travel_time * float(Config.TICK_RATE))))
	persistent_effects.append({
		"mode": "spell_projectile",
		"side": side,
		"card_id": String(card["id"]),
		"evolved_id": String(card.get("evolved_id", "")),
		"spell_mode": String(card.get("spell_mode", "")),
		"card": card.duplicate(true),
		"from_fp": MapMath.base_position_fp(side),
		"pos_fp": target_fp.duplicate(),
		"duration_ticks": duration_ticks,
		"remaining_ticks": duration_ticks,
		"radius_fp": _to_fp(float(card.get("radius", 0.0))),
		"damage": int(float(card.get("damage", 0.0)) + 0.5),
		"base_damage": int(float(card.get("base_damage", 0.0)) + 0.5),
		"color": card["color"],
		"label": String(card["short_name"])
	})
	stats["spell_casts"] = int(stats["spell_casts"]) + 1
	push_event("%s 发射 %s，%.1f 秒后抵达。" % [MapMath.side_name(side), card["name"], travel_time])


func _resolve_spell(side: String, card: Dictionary, target_fp: Dictionary, count_cast: bool = true) -> void:
	if card["spell_mode"] == "summon":
		_cast_summon_spell(side, card, target_fp)
		return
	if card["spell_mode"] == "death_mana_zone":
		_cast_death_mana_zone(side, card, target_fp)
		return
	if card["spell_mode"] == "line":
		_cast_line_spell(side, card, target_fp, count_cast)
		return

	var enemy_side: String = MapMath.opponent(side)
	var radius_fp: int = _to_fp(float(card["radius"]))
	var radius_sq: int = radius_fp * radius_fp
	var damage_int: int = int(float(card["damage"]) + 0.5)
	var base_damage_int: int = int(float(card["base_damage"]) + 0.5)
	var hit_count: int = 0

	if card["spell_mode"] == "single":
		var target: Dictionary = _nearest_enemy_unit(enemy_side, target_fp, radius_fp, radius_sq)
		if target.size() > 0:
			_damage_unit(target, damage_int, side, String(card["id"]), 0)
			hit_count = 1
		else:
			var enemy_base_fp: Dictionary = MapMath.base_position_fp(enemy_side)
			var r_total_fp: int = radius_fp + _base_radius_fp()
			if Fp.vec_dist_sq(target_fp, enemy_base_fp) <= r_total_fp * r_total_fp:
				_damage_base(enemy_side, base_damage_int, side, String(card["id"]))
				hit_count = 1
	else:
		var tx: int = int(target_fp.get("x", 0))
		var ty: int = int(target_fp.get("y", 0))
		for unit in units:
			if unit["side"] == enemy_side and int(unit["hp"]) > 0:
				var upos: Dictionary = unit["pos_fp"]
				if Fp.dist_sq(tx, ty, int(upos.get("x", 0)), int(upos.get("y", 0))) <= radius_sq:
					_damage_unit(unit, damage_int, side, String(card["id"]), 0)
					hit_count += 1
		var enemy_base_fp: Dictionary = MapMath.base_position_fp(enemy_side)
		var r_total_fp: int = radius_fp + _base_radius_fp()
		if Fp.vec_dist_sq(target_fp, enemy_base_fp) <= r_total_fp * r_total_fp:
			_damage_base(enemy_side, base_damage_int, side, String(card["id"]))
			hit_count += 1

	if count_cast:
		stats["spell_casts"] = int(stats["spell_casts"]) + 1
	spell_effects.append({
		"pos_fp": target_fp.duplicate(),
		"radius_fp": radius_fp,
		"time": 0.36,
		"max_time": 0.36,
		"color": card["color"],
		"label": card["short_name"]
	})
	push_event("%s 施放 %s，命中 %d。" % [MapMath.side_name(side), card["name"], hit_count])


func _cast_summon_spell(side: String, card: Dictionary, target_fp: Dictionary) -> void:
	var count: int = int(card.get("summon_count", 1))
	var river_fp: int = _to_fp(Config.RIVER_Y)
	var on_own_half: bool = (side == Config.PLAYER and int(target_fp.get("y", 0)) >= river_fp) or (side == Config.BOT and int(target_fp.get("y", 0)) <= river_fp)
	if on_own_half:
		count = int(card.get("own_half_summon_count", count))
	_summon_derivatives(side, String(card.get("summon_unit_id", "")), count, target_fp, String(card.get("summon_formation", "circle")))
	var delayed_count: int = int(card.get("delayed_summon_count", 0))
	if delayed_count > 0:
		persistent_effects.append({
			"mode": "delayed_summon",
			"side": side,
			"unit_id": String(card.get("summon_unit_id", "")),
			"count": delayed_count,
			"formation": String(card.get("summon_formation", "circle")),
			"pos_fp": _clamp_map_position_fp(target_fp),
			"timer_fp": _to_fp(float(card.get("delayed_summon_delay", 0.0)))
		})
	stats["spell_casts"] = int(stats["spell_casts"]) + 1
	_append_spell_visual(target_fp, _to_fp(float(card.get("radius", 2.0))), card["color"], String(card["short_name"]), 0.45)
	push_event("%s 施放 %s，召唤 %d 名侍童。" % [MapMath.side_name(side), card["name"], count])


func _cast_death_mana_zone(side: String, card: Dictionary, target_fp: Dictionary) -> void:
	var radius_fp: int = _to_fp(float(card.get("radius", 0.0)))
	var max_mana_refund_fp: int = _to_fp(float(card.get("max_mana_refund", 0.0)))
	persistent_effects.append({
		"mode": "death_mana_zone",
		"side": side,
		"pos_fp": _clamp_map_position_fp(target_fp),
		"radius_fp": radius_fp,
		"timer_fp": _to_fp(float(card.get("duration", 0.0))),
		"include_enemy_deaths": bool(card.get("include_enemy_deaths", false)),
		"max_mana_refund_fp": max_mana_refund_fp,
		"mana_refunded_fp": 0,
		"color": card["color"],
		"label": String(card["short_name"])
	})
	stats["spell_casts"] = int(stats["spell_casts"]) + 1
	_append_spell_visual(target_fp, radius_fp, card["color"], String(card["short_name"]), float(card.get("duration", 0.0)))
	push_event("%s 施放 %s，阵亡回费区域持续 %.0f 秒。" % [MapMath.side_name(side), card["name"], float(card.get("duration", 0.0))])


func _append_spell_visual(position_fp: Dictionary, radius_fp: int, color: Color, label: String, duration: float) -> void:
	spell_effects.append({
		"pos_fp": position_fp.duplicate(),
		"radius_fp": radius_fp,
		"time": duration,
		"max_time": duration,
		"color": color,
		"label": label
	})


# —— 线性法术（定点）——
func _cast_line_spell(side: String, card: Dictionary, target_fp: Dictionary, count_cast: bool = true) -> void:
	var start_fp: Dictionary = MapMath.base_position_fp(side)
	var radius_fp: int = _to_fp(float(card["radius"]))
	var radius_sq: int = radius_fp * radius_fp
	var damage_int: int = int(float(card["damage"]) + 0.5)
	var base_damage_int: int = int(float(card["base_damage"]) + 0.5)
	var hit_count: int = 0
	for unit in units:
		if int(unit["hp"]) > 0:
			var upos: Dictionary = unit["pos_fp"]
			var d_sq: int = MapMath.distance_to_segment_sq_fp(upos, start_fp, target_fp)
			if d_sq <= radius_sq:
				_damage_unit(unit, damage_int, side, String(card["id"]), 0)
				hit_count += 1
	var base_r_sq: int = (radius_fp + _base_radius_fp()) * (radius_fp + _base_radius_fp())
	for raw_base_side in [Config.PLAYER, Config.BOT]:
		var base_side: String = String(raw_base_side)
		var bpos: Dictionary = MapMath.base_position_fp(base_side)
		if MapMath.distance_to_segment_sq_fp(bpos, start_fp, target_fp) <= base_r_sq:
			_damage_base(base_side, base_damage_int, side, String(card["id"]))
			hit_count += 1
	if count_cast:
		stats["spell_casts"] = int(stats["spell_casts"]) + 1
	spell_effects.append({
		"mode": "line",
		"from_fp": start_fp.duplicate(),
		"pos_fp": target_fp.duplicate(),
		"radius_fp": radius_fp,
		"time": 0.36,
		"max_time": 0.36,
		"color": card["color"],
		"label": card["short_name"]
	})
	push_event("%s 施放 %s，路径命中 %d。" % [MapMath.side_name(side), card["name"], hit_count])


# —— 每 tick 更新单位：光环 → 索敌/攻击/移动 → 分离 → 边界 → 清尸体 ——
func update_units(_unused_delta: float) -> void:
	var dt_fp: int = _tick_dt_fp()
	var summon_requests: Array[Dictionary] = []

	# A: 推进攻击计时器 + 光环
	for unit in units:
		if int(unit["hp"]) <= 0:
			continue
		_update_squire_aura_stats(unit)
		unit["attack_timer_fp"] = max(0, int(unit["attack_timer_fp"]) - dt_fp)
		_update_unit_aura(unit, dt_fp)
		var periodic: Dictionary = unit.get("periodic_summon", {})
		var interval_fp: int = _to_fp(float(periodic.get("interval", 0.0)))
		if interval_fp > 0:
			var timer_fp: int = int(unit.get("periodic_summon_timer_fp", interval_fp)) - dt_fp
			while timer_fp <= 0:
				summon_requests.append({"side": unit["side"], "unit_id": periodic.get("unit_id", ""), "count": periodic.get("count", 1), "formation": periodic.get("formation", "random_near"), "pos_fp": unit["pos_fp"].duplicate()})
				timer_fp += interval_fp
			unit["periodic_summon_timer_fp"] = timer_fp

	for request in summon_requests:
		_summon_derivatives(String(request["side"]), String(request["unit_id"]), int(request["count"]), request["pos_fp"], String(request["formation"]))

	# B: 单位行为
	for unit in units:
		if int(unit["hp"]) <= 0 or not running:
			continue
		var target: Dictionary = _find_target(unit)
		var target_is_base: bool = String(target.get("kind", "")) == "base"
		var target_pos_fp: Dictionary = target["pos_fp"]
		var unit_pos_fp: Dictionary = unit["pos_fp"]
		var d_sq: int = Fp.vec_dist_sq(unit_pos_fp, target_pos_fp)
		var range_total_fp: int = int(unit["range_fp"]) + int(unit["radius_fp"]) + int(target.get("radius_fp", 0))
		var attack_dist_sq: int = range_total_fp * range_total_fp

		if d_sq <= attack_dist_sq:
			if int(unit["attack_timer_fp"]) <= 0:
				_perform_attack(unit, target)
				unit["attack_timer_fp"] = int(unit["attack_cooldown_fp"])
		else:
			var goal_fp: Dictionary = _next_step_goal(unit, target_pos_fp, target_is_base)
			var speed_step_fp: int = int((int(_effective_speed_fp(unit)) * int(dt_fp)) / int(_FP()))
			var ux: int = int(unit_pos_fp.get("x", 0))
			var uy: int = int(unit_pos_fp.get("y", 0))
			var gx: int = int(goal_fp.get("x", 0))
			var gy: int = int(goal_fp.get("y", 0))
			var new_pos: Dictionary = Fp.move_toward(ux, uy, gx, gy, speed_step_fp)
			unit["pos_fp"] = new_pos
			_check_bridge_summons(unit)

	_separate_units()
	_clamp_positions_to_map_border()

	var alive_units: Array[Dictionary] = []
	for unit in units:
		if int(unit["hp"]) > 0:
			alive_units.append(unit)
		else:
			stats["units_lost"] = int(stats["units_lost"]) + 1
	units = alive_units
	if task_system != null:
		task_system.track_squire_state(Config.PLAYER, _alive_squire_count(Config.PLAYER))
		task_system.track_squire_state(Config.BOT, _alive_squire_count(Config.BOT))


func _update_squire_aura_stats(unit: Dictionary) -> void:
	var aura: Dictionary = unit.get("squire_aura", {})
	if aura.is_empty():
		return
	var counts: Dictionary = {"book_squire": 0, "sword_squire": 0, "dawn_squire": 0}
	var radius_fp: int = _to_fp(float(aura.get("radius", 0.0)))
	var radius_sq: int = radius_fp * radius_fp
	for other in units:
		if other == unit or other["side"] != unit["side"] or int(other["hp"]) <= 0 or not _is_squire(other):
			continue
		if Fp.vec_dist_sq(unit["pos_fp"], other["pos_fp"]) <= radius_sq:
			var squire_id: String = String(other["card_id"])
			if counts.has(squire_id):
				counts[squire_id] = int(counts[squire_id]) + 1
	unit["damage"] = max(1, int(float(int(unit["base_damage"])) * (1.0 + float(int(counts["dawn_squire"]) * int(aura.get("dawn_damage_percent", 0))) / 100.0) + 0.5))
	unit["attack_cooldown_fp"] = max(_to_fp(0.1), int(float(int(unit["base_attack_cooldown_fp"])) * max(0.1, 1.0 - float(int(counts["book_squire"]) * int(aura.get("book_cooldown_percent", 0))) / 100.0) + 0.5))
	unit["speed_fp"] = max(1, int(float(int(unit["base_speed_fp"])) * (1.0 + float(int(counts["sword_squire"]) * int(aura.get("sword_speed_percent", 0))) / 100.0) + 0.5))


func _effective_speed_fp(unit: Dictionary) -> int:
	if not _is_squire(unit):
		return int(unit["speed_fp"])
	var protector: Dictionary = _find_squire_protector(unit)
	if not protector.is_empty() and bool(protector.get("sync_squire_speed", false)):
		return int(protector["speed_fp"])
	return int(unit["speed_fp"])


func _check_bridge_summons(unit: Dictionary) -> void:
	if bool(unit.get("bridge_triggered", false)) or unit.get("bridge_summons", []).is_empty():
		return
	var river_fp: int = _to_fp(Config.RIVER_Y)
	var y_fp: int = int(unit["pos_fp"].get("y", 0))
	var crossed: bool = (unit["side"] == Config.PLAYER and y_fp <= river_fp) or (unit["side"] == Config.BOT and y_fp >= river_fp)
	if not crossed:
		return
	unit["bridge_triggered"] = true
	for raw_request in unit["bridge_summons"]:
		var request: Dictionary = raw_request
		_summon_derivatives(String(unit["side"]), String(request.get("unit_id", "")), int(request.get("count", 1)), unit["pos_fp"], String(request.get("formation", "behind")))


func _alive_squire_count(side: String) -> int:
	var count: int = 0
	for unit in units:
		if unit["side"] == side and int(unit["hp"]) > 0 and _is_squire(unit):
			count += 1
	return count


func _is_squire(unit: Dictionary) -> bool:
	var tags: Array = unit.get("tags", [])
	return tags.has("squire")


# —— 碰撞分离（定点）：推开重叠单位。攻击CD中位置锁定。——
func _separate_units() -> void:
	var alive_count: int = 0
	for unit in units:
		if int(unit["hp"]) > 0:
			alive_count += 1

	for i in range(alive_count):
		var unit_a: Dictionary = units[i]
		if int(unit_a["hp"]) <= 0:
			continue
		var a_r: int = int(unit_a["radius_fp"])
		var a_locked: bool = int(unit_a["attack_timer_fp"]) > 0

		for j in range(i + 1, alive_count):
			var unit_b: Dictionary = units[j]
			if int(unit_b["hp"]) <= 0:
				continue
			var b_r: int = int(unit_b["radius_fp"])
			var b_locked: bool = int(unit_b["attack_timer_fp"]) > 0

			if a_locked and b_locked:
				continue

			var apos: Dictionary = unit_a["pos_fp"]
			var bpos: Dictionary = unit_b["pos_fp"]
			var ax: int = int(apos.get("x", 0))
			var ay: int = int(apos.get("y", 0))
			var bx: int = int(bpos.get("x", 0))
			var by: int = int(bpos.get("y", 0))
			var dx: int = ax - bx
			var dy: int = int(ay - by)
			var dist_sq: int = dx * dx + dy * dy
			var min_r: int = a_r + b_r
			var min_r_sq: int = min_r * min_r
			# dist == 0 情况：沿 x 轴推
			if dist_sq == 0:
				dx = 1
				dy = 0
				dist_sq = 1
			if dist_sq >= min_r_sq:
				continue
			# 近似距离（避免 sqrt）：用 max(|dx|,|dy|) 估算 overlap 量级的 1/sqrt(2) 倍；
			# 直接用精确 sqrt 会有浮点，改为迭代一次近似：
			#   overlap ≈ (min_r - dist) ≈ (min_r^2 - dist^2) / (2 * min_r) （一阶牛顿）
			var numer: int = min_r_sq - dist_sq
			var denom_twice: int = 2 * max(1, min_r)
			var overlap_fp: int = numer / max(1, denom_twice)
			if overlap_fp <= 0:
				overlap_fp = 1
			# 方向用 (dx,dy) 近似归一化长度用 max(|dx|,|dy|)
			var adx: int = abs(dx)
			var ady: int = abs(dy)
			var len: int = max(1, max(adx, ady))
			var dir_x: int = int((int(dx) * int(_FP())) / int(len))
			var dir_y: int = int((int(dy) * int(_FP())) / int(len))

			var push_x: int
			var push_y: int
			if a_locked:
				# B 推开全部
				push_x = -int((int(dir_x) * int(overlap_fp)) / int(_FP()))
				push_y = -int((int(dir_y) * int(overlap_fp)) / int(_FP()))
				unit_b["pos_fp"] = {"x": bx + push_x, "y": by + push_y}
			elif b_locked:
				# A 推开全部
				push_x = int((int(dir_x) * int(overlap_fp)) / int(_FP()))
				push_y = int((int(dir_y) * int(overlap_fp)) / int(_FP()))
				unit_a["pos_fp"] = {"x": ax + push_x, "y": ay + push_y}
			else:
				# 各推一半
				var half: int = overlap_fp / 2
				push_x = int((int(dir_x) * int(half)) / int(_FP()))
				push_y = int((int(dir_y) * int(half)) / int(_FP()))
				unit_a["pos_fp"] = {"x": ax + push_x, "y": ay + push_y}
				unit_b["pos_fp"] = {"x": bx - push_x, "y": by - push_y}


# —— 硬边界（定点）——
func _clamp_positions_to_map_border() -> void:
	var margin_fp: int = int(3.5 * _F() + 0.5)
	var mw: int = _map_width_fp()
	var mh: int = _map_height_fp()
	for unit in units:
		if int(unit["hp"]) <= 0:
			continue
		var r: int = int(unit["radius_fp"])
		var p: Dictionary = unit["pos_fp"]
		var x: int = Fp.clamp_int(int(p.get("x", 0)), margin_fp + r, mw - margin_fp - r)
		var y: int = Fp.clamp_int(int(p.get("y", 0)), margin_fp + r, mh - margin_fp - r)
		unit["pos_fp"] = {"x": x, "y": y}


# —— 索敌（定点）：最近敌人，tie-break id。目标字典包含 pos_fp、radius_fp、kind、unit 引用 ——
func _find_target(unit: Dictionary) -> Dictionary:
	var enemy_side: String = MapMath.opponent(unit["side"])
	if bool(unit.get("target_base_only", false)):
		return {
			"kind": "base",
			"side": enemy_side,
			"pos_fp": MapMath.base_position_fp(enemy_side),
			"radius_fp": _base_radius_fp()
		}

	var aggro_range_fp: int = max(_to_fp(9.0), int(unit["range_fp"]) + int(unit["radius_fp"]) + _to_fp(4.0))
	var aggro_sq: int = aggro_range_fp * aggro_range_fp
	var best_unit: Dictionary = {}
	var best_dist_sq: int = 1000000000  # 极大值
	var best_id: int = 1000000000
	var up: Dictionary = unit["pos_fp"]
	var ux: int = int(up.get("x", 0))
	var uy: int = int(up.get("y", 0))

	for enemy in units:
		if enemy["side"] != enemy_side or int(enemy["hp"]) <= 0:
			continue
		var ep: Dictionary = enemy["pos_fp"]
		var d_sq: int = Fp.dist_sq(ux, uy, int(ep.get("x", 0)), int(ep.get("y", 0)))
		var eid: int = int(enemy["id"])
		var r_sum: int = aggro_range_fp + int(enemy["radius_fp"])
		var in_aggro: bool = d_sq <= r_sum * r_sum
		var better: bool = (d_sq < best_dist_sq) or (d_sq == best_dist_sq and eid < best_id)
		if in_aggro and better:
			best_dist_sq = d_sq
			best_unit = enemy
			best_id = eid

	if best_unit.size() > 0:
		return {
			"kind": "unit",
			"unit": best_unit,
			"side": enemy_side,
			"pos_fp": best_unit["pos_fp"],
			"radius_fp": best_unit["radius_fp"]
		}

	return {
		"kind": "base",
		"side": enemy_side,
		"pos_fp": MapMath.base_position_fp(enemy_side),
		"radius_fp": _base_radius_fp()
	}


# —— 攻击执行 ——
func _perform_attack(unit: Dictionary, target: Dictionary) -> void:
	var damage_int: int = int(unit["damage"])
	var source_card_id: String = String(unit["card_id"])
	var source_unit_id: int = int(unit["id"])
	if String(target.get("kind", "")) == "base":
		_damage_base(target["side"], damage_int, unit["side"], source_card_id)
		var excluded: Array[int] = []
		_damage_extra_attack_targets(unit, excluded, max(0, int(unit.get("multi_target_count", 1)) - 1), damage_int)
		return

	var hit_ids: Array[int] = []
	if int(unit.get("aoe_radius_fp", 0)) > 0:
		hit_ids = _damage_attack_aoe(unit, target["unit"]["pos_fp"], damage_int)
	else:
		hit_ids.append(int(target["unit"]["id"]))
		_damage_unit(target["unit"], damage_int, unit["side"], source_card_id, source_unit_id)

	_damage_extra_attack_targets(unit, hit_ids, max(0, int(unit.get("multi_target_count", 1)) - 1), damage_int)


# AOE 落点
func _damage_attack_aoe(unit: Dictionary, center_fp: Dictionary, damage_int: int) -> Array[int]:
	var hit_ids: Array[int] = []
	var r_fp: int = int(unit["aoe_radius_fp"])
	var r_sq: int = r_fp * r_fp
	var cx: int = int(center_fp.get("x", 0))
	var cy: int = int(center_fp.get("y", 0))
	for enemy in units:
		if enemy["side"] == unit["side"] or int(enemy["hp"]) <= 0:
			continue
		var ep: Dictionary = enemy["pos_fp"]
		if Fp.dist_sq(cx, cy, int(ep.get("x", 0)), int(ep.get("y", 0))) <= r_sq:
			hit_ids.append(int(enemy["id"]))
			_damage_unit(enemy, damage_int, unit["side"], String(unit["card_id"]), int(unit["id"]))
	return hit_ids


# 多目标
func _damage_extra_attack_targets(unit: Dictionary, excluded_unit_ids: Array[int], count: int, damage_int: int) -> void:
	var remaining: int = count
	while remaining > 0:
		var best: Dictionary = {}
		var best_dist_sq: int = 1000000000
		var best_id: int = 1000000000
		var up: Dictionary = unit["pos_fp"]
		var ux: int = int(up.get("x", 0))
		var uy: int = int(up.get("y", 0))
		var r_total_fp: int = int(unit["range_fp"]) + int(unit["radius_fp"])
		for enemy in units:
			if enemy["side"] == unit["side"] or int(enemy["hp"]) <= 0 or excluded_unit_ids.has(int(enemy["id"])):
				continue
			var r_full: int = r_total_fp + int(enemy["radius_fp"])
			var ep: Dictionary = enemy["pos_fp"]
			var d_sq: int = Fp.dist_sq(ux, uy, int(ep.get("x", 0)), int(ep.get("y", 0)))
			var eid: int = int(enemy["id"])
			var better: bool = (d_sq < best_dist_sq) or (d_sq == best_dist_sq and eid < best_id)
			if d_sq <= r_full * r_full and better:
				best_dist_sq = d_sq
				best = enemy
				best_id = eid
		if best.size() == 0:
			return
		excluded_unit_ids.append(int(best["id"]))
		_damage_unit(best, damage_int, unit["side"], String(unit["card_id"]), int(unit["id"]))
		remaining -= 1


# —— 路径点（定点）：向基地推进走桥，越过边界避免卡死 ——
func _next_step_goal(unit: Dictionary, target_pos_fp: Dictionary, target_is_base: bool) -> Dictionary:
	if target_is_base and _target_is_base_fp(unit["side"], target_pos_fp):
		return _path_goal_toward_base_fp(unit)
	return target_pos_fp


func _target_is_base_fp(side: String, pos_fp: Dictionary) -> bool:
	var enemy_base_fp: Dictionary = MapMath.base_position_fp(MapMath.opponent(side))
	var tol_fp: int = _to_fp(0.1)
	var tol_sq: int = tol_fp * tol_fp
	return Fp.vec_dist_sq(pos_fp, enemy_base_fp) <= tol_sq


func _path_goal_toward_base_fp(unit: Dictionary) -> Dictionary:
	var p: Dictionary = unit["pos_fp"]
	var px: int = int(p.get("x", 0))
	var py: int = int(p.get("y", 0))
	var s: int = _FP()
	var bridge_x_fp: int = MapMath.nearest_bridge_x_fp(px)
	var river_fp: int = int(Config.RIVER_Y * _F() + 0.5)

	if unit["side"] == Config.PLAYER:
		if py >= river_fp + 3 * s:
			return {"x": bridge_x_fp, "y": river_fp + 1 * s + 500}  # 500 = 0.5 s
		if py >= river_fp - 3 * s:
			return {"x": bridge_x_fp, "y": river_fp - 4 * s - 500}
		return MapMath.base_position_fp(Config.BOT)
	else:
		if py <= river_fp - 3 * s:
			return {"x": bridge_x_fp, "y": river_fp - 1 * s - 500}
		if py <= river_fp + 3 * s:
			return {"x": bridge_x_fp, "y": river_fp + 4 * s + 500}
		return MapMath.base_position_fp(Config.PLAYER)


# —— 伤害：单位 / 基地 ——
func _damage_unit(unit: Dictionary, amount_int: int, source_side: String = "", source_card_id: String = "", source_unit_id: int = 0, allow_transfer: bool = true) -> void:
	var prev: int = int(unit["hp"])
	if prev <= 0:
		return
	if allow_transfer and _is_squire(unit):
		var protector: Dictionary = _find_squire_protector(unit)
		if not protector.is_empty():
			_damage_unit(protector, amount_int, source_side, source_card_id, source_unit_id, false)
			return
	var reduction_percent: int = clamp(int(unit.get("damage_reduction_percent", 0)), 0, 90)
	var final_amount: int = max(0, int(float(amount_int) * (1.0 - float(reduction_percent) / 100.0) + 0.5))
	unit["hp"] = max(0, prev - final_amount)
	task_system.track_unit_hp_change(unit)
	if int(unit["hp"]) <= 0:
		if source_side != "" and source_side != String(unit["side"]):
			task_system.track_unit_kill(source_side, source_card_id, source_unit_id)
		_process_unit_death(unit)


func _find_squire_protector(squire: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_dist_sq: int = 1000000000
	var best_id: int = 1000000000
	for candidate in units:
		if candidate["side"] != squire["side"] or int(candidate["hp"]) <= 0 or not bool(candidate.get("protect_squires", false)):
			continue
		var radius_fp: int = int(candidate.get("protection_radius_fp", 0))
		var d_sq: int = Fp.vec_dist_sq(candidate["pos_fp"], squire["pos_fp"])
		var cid: int = int(candidate["id"])
		if d_sq <= radius_fp * radius_fp and (d_sq < best_dist_sq or (d_sq == best_dist_sq and cid < best_id)):
			best = candidate
			best_dist_sq = d_sq
			best_id = cid
	return best


func _process_unit_death(unit: Dictionary) -> void:
	if bool(unit.get("dead_processed", false)):
		return
	unit["dead_processed"] = true
	var side: String = String(unit["side"])
	if task_system != null:
		task_system.track_unit_death(side, unit)
	var death_effect: Dictionary = unit.get("on_death", {})
	var mana_gain: int = int(death_effect.get("mana_gain", 0))
	if mana_gain > 0:
		_gain_mana(side, mana_gain)
	_apply_death_mana_zones(unit)
	if _is_squire(unit):
		_apply_nearby_squire_death_buffs(unit)
	if int(death_effect.get("explosion_damage", 0)) > 0 or int(death_effect.get("explosion_base_damage", 0)) > 0:
		_trigger_death_explosion(unit, death_effect)


func _gain_mana(side: String, amount: int) -> int:
	return _gain_mana_fp(side, amount * _FP())


func _gain_mana_fp(side: String, requested_gain_fp: int) -> int:
	var before_fp: int = player_mana_fp if side == Config.PLAYER else bot_mana_fp
	var after_fp: int = min(_mana_max_fp(), before_fp + max(0, requested_gain_fp))
	if side == Config.PLAYER:
		player_mana_fp = after_fp
	else:
		bot_mana_fp = after_fp
	return after_fp - before_fp


func _apply_death_mana_zones(dead_unit: Dictionary) -> void:
	var rewarded_sides: Dictionary = {}
	for effect in persistent_effects:
		if String(effect.get("mode", "")) != "death_mana_zone" or int(effect.get("timer_fp", 0)) <= 0:
			continue
		var owner_side: String = String(effect.get("side", ""))
		if rewarded_sides.has(owner_side):
			continue
		var max_mana_refund_fp: int = int(effect.get("max_mana_refund_fp", 0))
		var mana_refunded_fp: int = int(effect.get("mana_refunded_fp", 0))
		if max_mana_refund_fp > 0 and mana_refunded_fp >= max_mana_refund_fp:
			continue
		if dead_unit["side"] != owner_side and not bool(effect.get("include_enemy_deaths", false)):
			continue
		var radius_fp: int = int(effect.get("radius_fp", 0))
		if Fp.vec_dist_sq(dead_unit["pos_fp"], effect["pos_fp"]) <= radius_fp * radius_fp:
			var requested_gain_fp: int = _FP()
			if max_mana_refund_fp > 0:
				requested_gain_fp = min(requested_gain_fp, max_mana_refund_fp - mana_refunded_fp)
			var actual_gain_fp: int = _gain_mana_fp(owner_side, requested_gain_fp)
			effect["mana_refunded_fp"] = mana_refunded_fp + actual_gain_fp
			rewarded_sides[owner_side] = true


func _apply_nearby_squire_death_buffs(dead_squire: Dictionary) -> void:
	for listener in units:
		if listener["side"] != dead_squire["side"] or int(listener["hp"]) <= 0:
			continue
		var buff: Dictionary = listener.get("squire_death_buff", {})
		if buff.is_empty():
			continue
		var radius_fp: int = _to_fp(float(buff.get("radius", 0.0)))
		if Fp.vec_dist_sq(listener["pos_fp"], dead_squire["pos_fp"]) > radius_fp * radius_fp:
			continue
		var stacks: int = min(int(buff.get("max_stacks", 0)), int(listener.get("squire_buff_stacks", 0)) + 1)
		listener["squire_buff_stacks"] = stacks
		listener["damage"] = max(1, int(float(int(listener["base_damage"])) * (1.0 + float(stacks * int(buff.get("damage_percent", 0))) / 100.0) + 0.5))
		listener["attack_cooldown_fp"] = max(_to_fp(0.1), int(float(int(listener["base_attack_cooldown_fp"])) * max(0.1, 1.0 - float(stacks * int(buff.get("cooldown_percent", 0))) / 100.0) + 0.5))
		listener["range_fp"] = max(1, int(float(int(listener["base_range_fp"])) * (1.0 + float(stacks * int(buff.get("range_percent", 0))) / 100.0) + 0.5))
		listener["damage_reduction_percent"] = stacks * int(buff.get("damage_reduction_percent", 0))


func _trigger_death_explosion(unit: Dictionary, effect: Dictionary) -> void:
	var enemy_side: String = MapMath.opponent(String(unit["side"]))
	var radius_fp: int = _to_fp(float(effect.get("explosion_radius", 0.0)))
	var radius_sq: int = radius_fp * radius_fp
	for target in units:
		if target["side"] == enemy_side and int(target["hp"]) > 0 and Fp.vec_dist_sq(unit["pos_fp"], target["pos_fp"]) <= radius_sq:
			_damage_unit(target, int(effect.get("explosion_damage", 0)), unit["side"], unit["card_id"], int(unit["id"]))
	var enemy_base_fp: Dictionary = MapMath.base_position_fp(enemy_side)
	var base_range_fp: int = radius_fp + _base_radius_fp()
	if Fp.vec_dist_sq(unit["pos_fp"], enemy_base_fp) <= base_range_fp * base_range_fp:
		_damage_base(enemy_side, int(effect.get("explosion_base_damage", 0)), unit["side"], unit["card_id"])
	var fire_duration_fp: int = _to_fp(float(effect.get("fire_duration", 0.0)))
	if fire_duration_fp > 0:
		persistent_effects.append({
			"mode": "fire_zone",
			"side": unit["side"],
			"pos_fp": unit["pos_fp"].duplicate(),
			"radius_fp": radius_fp,
			"timer_fp": fire_duration_fp,
			"tick_interval_fp": _to_fp(float(effect.get("fire_tick_interval", 0.5))),
			"tick_timer_fp": _to_fp(float(effect.get("fire_tick_interval", 0.5))),
			"damage": int(effect.get("fire_damage", 0)),
			"base_damage": int(effect.get("fire_base_damage", 0))
		})
	_append_spell_visual(unit["pos_fp"], radius_fp, unit["color"], "爆", max(0.4, float(effect.get("fire_duration", 0.0))))


func _damage_base(base_side: String, amount_int: int, source_side: String, source_card_id: String = "") -> void:
	if not running:
		return
	var base: Dictionary = bases[base_side]
	var prev: int = int(base["hp"])
	base["hp"] = max(0, prev - amount_int)
	if prev > int(base["hp"]) and source_side != "" and source_side != base_side:
		task_system.track_base_hit(source_side, source_card_id)
	# 阈值：200、100 （定点 Q*1000，hp 是 int 1~300，所以需要把 fp 阈值转为 int hp 比较）
	var threshold_hp_int: int = int(float(int(base["next_clear_threshold_fp"])) / _F() + 0.5)
	while threshold_hp_int > 0 and int(base["hp"]) <= threshold_hp_int:
		var next_fp: int = int(base["next_clear_threshold_fp"]) - _to_fp(100.0)
		base["next_clear_threshold_fp"] = next_fp
		_trigger_clear(base_side, threshold_hp_int)
		threshold_hp_int = int(float(next_fp) / _F() + 0.5)

	if int(base["hp"]) <= 0:
		var winner: String = source_side if source_side != base_side else MapMath.opponent(base_side)
		_finish_match(winner)


func _trigger_clear(base_side: String, threshold_int: int) -> void:
	for unit in units:
		if int(unit["hp"]) > 0:
			_damage_unit(unit, int(unit["hp"]), "", "", 0, false)
	bases[base_side]["clear_count"] = int(bases[base_side]["clear_count"]) + 1
	push_event("%s基地跌破 %d 血，清屏。" % [MapMath.side_name(base_side), threshold_int])


func _finish_match(winner_side: String) -> void:
	match_winner = winner_side
	running = false
	push_event("%s胜利，用时 %s。" % [MapMath.side_name(winner_side), _format_time(tick_count)])


# 返回当前对局胜方阵营（""=未结束）。V0.4 联机结果上报用。
func winner_side() -> String:
	return match_winner


# —— 法术特效时间（float，纯客户端表现，保留 float）——
func update_spell_effects(delta: float) -> void:
	_update_persistent_effects()
	var active: Array[Dictionary] = []
	for effect in spell_effects:
		effect["time"] = float(effect["time"]) - delta
		if float(effect["time"]) > 0.0:
			active.append(effect)
	spell_effects = active


func _update_persistent_effects() -> void:
	var dt_fp: int = _tick_dt_fp()
	var effects_to_process: Array[Dictionary] = persistent_effects
	persistent_effects = []
	for effect in effects_to_process:
		var mode: String = String(effect.get("mode", ""))
		if mode == "spell_projectile":
			effect["remaining_ticks"] = int(effect.get("remaining_ticks", 0)) - 1
			if int(effect["remaining_ticks"]) <= 0:
				_resolve_spell(String(effect["side"]), effect["card"], effect["pos_fp"], false)
			else:
				persistent_effects.append(effect)
			continue
		if mode == "delayed_summon":
			effect["timer_fp"] = int(effect.get("timer_fp", 0)) - dt_fp
			if int(effect["timer_fp"]) <= 0:
				_summon_derivatives(String(effect["side"]), String(effect["unit_id"]), int(effect["count"]), effect["pos_fp"], String(effect["formation"]))
			else:
				persistent_effects.append(effect)
			continue
		if mode == "fire_zone":
			effect["timer_fp"] = int(effect.get("timer_fp", 0)) - dt_fp
			effect["tick_timer_fp"] = int(effect.get("tick_timer_fp", 0)) - dt_fp
			var interval_fp: int = max(1, int(effect.get("tick_interval_fp", 1)))
			while int(effect["tick_timer_fp"]) <= 0:
				_pulse_fire_zone(effect)
				effect["tick_timer_fp"] = int(effect["tick_timer_fp"]) + interval_fp
		else:
			effect["timer_fp"] = int(effect.get("timer_fp", 0)) - dt_fp
		if int(effect.get("timer_fp", 0)) > 0:
			persistent_effects.append(effect)


func _pulse_fire_zone(effect: Dictionary) -> void:
	var side: String = String(effect["side"])
	var enemy_side: String = MapMath.opponent(side)
	var radius_fp: int = int(effect["radius_fp"])
	var radius_sq: int = radius_fp * radius_fp
	for unit in units:
		if unit["side"] == enemy_side and int(unit["hp"]) > 0 and Fp.vec_dist_sq(effect["pos_fp"], unit["pos_fp"]) <= radius_sq:
			_damage_unit(unit, int(effect.get("damage", 0)), side, "dawn_squire", 0)
	var enemy_base_fp: Dictionary = MapMath.base_position_fp(enemy_side)
	var base_range_fp: int = radius_fp + _base_radius_fp()
	if Fp.vec_dist_sq(effect["pos_fp"], enemy_base_fp) <= base_range_fp * base_range_fp:
		_damage_base(enemy_side, int(effect.get("base_damage", 0)), side, "dawn_squire")


# —— 光环脉冲（定点）——
func _update_unit_aura(unit: Dictionary, dt_fp: int) -> void:
	var interval_fp: int = int(unit.get("aura_interval_fp", 0))
	if interval_fp <= 0 or not running:
		return
	var timer_fp: int = int(unit.get("aura_timer_fp", interval_fp)) - dt_fp
	while timer_fp <= 0 and running and int(unit["hp"]) > 0:
		_pulse_unit_aura(unit)
		timer_fp += interval_fp
	unit["aura_timer_fp"] = timer_fp


func _pulse_unit_aura(unit: Dictionary) -> void:
	var enemy_side: String = MapMath.opponent(unit["side"])
	var r_fp: int = int(unit["aura_radius_fp"])
	var r_sq: int = r_fp * r_fp
	var dmg_int: int = int(unit["aura_damage"])
	var hit_count: int = 0
	var up: Dictionary = unit["pos_fp"]
	var ux: int = int(up.get("x", 0))
	var uy: int = int(up.get("y", 0))
	for enemy in units:
		if enemy["side"] == enemy_side and int(enemy["hp"]) > 0:
			var ep: Dictionary = enemy["pos_fp"]
			if Fp.dist_sq(ux, uy, int(ep.get("x", 0)), int(ep.get("y", 0))) <= r_sq:
				_damage_unit(enemy, dmg_int, unit["side"], String(unit["card_id"]), int(unit["id"]))
				hit_count += 1
	var enemy_base_fp: Dictionary = MapMath.base_position_fp(enemy_side)
	var r_total_fp: int = r_fp + _base_radius_fp()
	if Fp.vec_dist_sq(up, enemy_base_fp) <= r_total_fp * r_total_fp:
		_damage_base(enemy_side, dmg_int, unit["side"], String(unit["card_id"]))
		hit_count += 1
	if hit_count > 0:
		spell_effects.append({
			"pos_fp": up.duplicate(),
			"radius_fp": r_fp,
			"time": 0.22,
			"max_time": 0.22,
			"color": unit["color"],
			"label": unit["short_name"]
		})


# —— single 法术最近敌人（定点）——
func _nearest_enemy_unit(enemy_side: String, position_fp: Dictionary, radius_fp: int, radius_sq: int) -> Dictionary:
	var best: Dictionary = {}
	var best_d_sq: int = 1000000000
	var best_id: int = 1000000000
	var px: int = int(position_fp.get("x", 0))
	var py: int = int(position_fp.get("y", 0))
	for unit in units:
		if unit["side"] != enemy_side or int(unit["hp"]) <= 0:
			continue
		var up: Dictionary = unit["pos_fp"]
		var d_sq: int = Fp.dist_sq(px, py, int(up.get("x", 0)), int(up.get("y", 0)))
		var uid: int = int(unit["id"])
		var better: bool = (d_sq < best_d_sq) or (d_sq == best_d_sq and uid < best_id)
		if d_sq <= radius_sq and better:
			best_d_sq = d_sq
			best = unit
			best_id = uid
	return best


# —— Bot 选簇（定点）——
func best_enemy_cluster(side: String, radius: float) -> Vector2:
	var enemy_side: String = MapMath.opponent(side)
	var radius_fp: int = _to_fp(radius)
	var r_sq: int = radius_fp * radius_fp
	var best_score: int = 0
	var best_pos_fp: Dictionary = {"x": -_to_fp(1.0), "y": -_to_fp(1.0)}
	var best_id: int = 1000000000
	for unit in units:
		if unit["side"] != enemy_side or int(unit["hp"]) <= 0:
			continue
		var score: int = 0
		var up: Dictionary = unit["pos_fp"]
		var ux: int = int(up.get("x", 0))
		var uy: int = int(up.get("y", 0))
		for other in units:
			if other["side"] == enemy_side and int(other["hp"]) > 0:
				var op: Dictionary = other["pos_fp"]
				if Fp.dist_sq(ux, uy, int(op.get("x", 0)), int(op.get("y", 0))) <= r_sq:
					score += 1
		var uid: int = int(unit["id"])
		var better: bool = (score > best_score) or (score == best_score and uid < best_id)
		if better:
			best_score = score
			best_pos_fp = up
			best_id = uid
	# 返回 float Vector2（Bot 仍用 float 接口选择，后续定点化 Bot）
	return Vector2(float(int(best_pos_fp.get("x", 0))) / _F(), float(int(best_pos_fp.get("y", 0))) / _F())


# —— 卡牌使用记录 / 任务完成 / 事件日志 ——
func _record_card_use(side: String, card_id: String) -> void:
	var key: String = "player_cards" if side == Config.PLAYER else "bot_cards"
	var usage: Dictionary = stats[key]
	usage[card_id] = int(usage.get(card_id, 0)) + 1
	task_system.track_card_play(side, card_id)


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


func push_event(message: String) -> void:
	event_log.append(message)
	while event_log.size() > 6:
		event_log.pop_front()


# 进化闪光（纯客户端 float 计时器）
func update_evolution_flashes(delta: float) -> void:
	for side in evolution_flashes.keys():
		var side_flashes: Dictionary = evolution_flashes[side]
		var remaining: Dictionary = {}
		for card_id in side_flashes.keys():
			var t: float = float(side_flashes[card_id]) - delta
			if t > 0.0:
				remaining[card_id] = t
		evolution_flashes[side] = remaining


func is_evolution_flashing(side: String, card_id: String) -> bool:
	if not evolution_flashes.has(side):
		return false
	return evolution_flashes[side].has(card_id)


# 用 tick_count 格式化 mm:ss
func _format_time(ticks: int) -> String:
	var total_sec: int = int(float(ticks) * Config.TICK_DT)
	return "%02d:%02d" % [int(total_sec / 60), total_sec % 60]


# —— P2：状态校验和辅助函数（FNV-1a 内联实现）——
# 每步都截断到 32 位，确保跨客户端哈希结果严格一致（否则 64 位中间溢出会导致 desync）
func _fnv_mix(h_in: int, value: int, prime: int) -> int:
	var mixed: int = int((int(h_in) ^ int(value)) * int(prime))
	return mixed & 0xFFFFFFFF


# —— 单位字典按 id 升序比较（供 sort_custom 使用）——
func _unit_compare_id(a: Dictionary, b: Dictionary) -> bool:
	return int(a["id"]) < int(b["id"])


# —— P2：状态校验和（用于 desync 检测）——
# 使用 FNV-1a 风格的整数哈希组合，确保：
#   - 仅依赖参与同步的战斗状态（不含纯客户端表现：evolution_flashes / spell_effects time）
#   - 单位按 id 升序排序后参与哈希，保证迭代顺序确定
#   - 所有整数乘法用 64 位避免中间溢出，最后截断到 int 返回
func state_checksum() -> int:
	var FNV_OFFSET: int = 2166136261
	var FNV_PRIME: int = 16777619
	var h: int = FNV_OFFSET

	h = _fnv_mix(h, tick_count, FNV_PRIME)
	h = _fnv_mix(h, player_mana_fp, FNV_PRIME)
	h = _fnv_mix(h, bot_mana_fp, FNV_PRIME)
	h = _fnv_mix(h, int(bases[Config.PLAYER]["hp"]), FNV_PRIME)
	h = _fnv_mix(h, int(bases[Config.BOT]["hp"]), FNV_PRIME)
	h = _fnv_mix(h, int(bases[Config.PLAYER].get("clear_count", 0)), FNV_PRIME)
	h = _fnv_mix(h, int(bases[Config.BOT].get("clear_count", 0)), FNV_PRIME)
	h = _fnv_mix(h, rng_seed, FNV_PRIME)
	h = _fnv_mix(h, int(rng.state), FNV_PRIME)
	h = _fnv_mix(h, next_unit_id, FNV_PRIME)
	h = _fnv_mix(h, match_winner.hash(), FNV_PRIME)
	h = _fnv_mix(h, units.size(), FNV_PRIME)
	for raw_side in [Config.PLAYER, Config.BOT]:
		var cooldown_side: String = String(raw_side)
		var side_cooldowns: Dictionary = card_cooldowns.get(cooldown_side, {})
		var cooldown_card_ids: Array = side_cooldowns.keys()
		cooldown_card_ids.sort()
		h = _fnv_mix(h, cooldown_side.hash(), FNV_PRIME)
		h = _fnv_mix(h, cooldown_card_ids.size(), FNV_PRIME)
		for raw_card_id in cooldown_card_ids:
			var cooldown_card_id: String = String(raw_card_id)
			h = _fnv_mix(h, cooldown_card_id.hash(), FNV_PRIME)
			h = _fnv_mix(h, int(side_cooldowns[cooldown_card_id]), FNV_PRIME)

	# 单位按 id 升序确保双端遍历一致
	var sorted_units: Array[Dictionary] = []
	for u in units:
		sorted_units.append(u)
	sorted_units.sort_custom(_unit_compare_id)

	for unit in sorted_units:
		h = _fnv_mix(h, int(unit["id"]), FNV_PRIME)
		h = _fnv_mix(h, String(unit["side"]).hash(), FNV_PRIME)
		h = _fnv_mix(h, String(unit["card_id"]).hash(), FNV_PRIME)
		h = _fnv_mix(h, String(unit.get("art_id", "")).hash(), FNV_PRIME)
		h = _fnv_mix(h, int(unit["hp"]), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("pos_fp", {}).get("x", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("pos_fp", {}).get("y", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("attack_timer_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("aura_timer_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("damage", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("attack_cooldown_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("range_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("speed_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("damage_reduction_percent", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("squire_buff_stacks", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(unit.get("periodic_summon_timer_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, 1 if bool(unit.get("bridge_triggered", false)) else 0, FNV_PRIME)
		h = _fnv_mix(h, 1 if bool(unit.get("target_base_only", false)) else 0, FNV_PRIME)
		h = _fnv_mix(h, 1 if bool(unit.get("protect_squires", false)) else 0, FNV_PRIME)
		h = _fnv_mix(h, 1 if bool(unit.get("sync_squire_speed", false)) else 0, FNV_PRIME)

	h = _fnv_mix(h, persistent_effects.size(), FNV_PRIME)
	for effect in persistent_effects:
		h = _fnv_mix(h, String(effect.get("mode", "")).hash(), FNV_PRIME)
		h = _fnv_mix(h, String(effect.get("side", "")).hash(), FNV_PRIME)
		h = _fnv_mix(h, String(effect.get("unit_id", "")).hash(), FNV_PRIME)
		h = _fnv_mix(h, String(effect.get("card_id", "")).hash(), FNV_PRIME)
		h = _fnv_mix(h, String(effect.get("evolved_id", "")).hash(), FNV_PRIME)
		h = _fnv_mix(h, String(effect.get("spell_mode", "")).hash(), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("timer_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("tick_timer_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("duration_ticks", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("remaining_ticks", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("from_fp", {}).get("x", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("from_fp", {}).get("y", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("pos_fp", {}).get("x", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("pos_fp", {}).get("y", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("radius_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("count", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("damage", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("base_damage", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("max_mana_refund_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, int(effect.get("mana_refunded_fp", 0)), FNV_PRIME)
		h = _fnv_mix(h, 1 if bool(effect.get("include_enemy_deaths", false)) else 0, FNV_PRIME)

	# 任务进度会改变后续卡牌定义，因此也必须参与锁步校验。
	if task_system != null:
		for side in [Config.PLAYER, Config.BOT]:
			var side_tasks: Dictionary = task_system.task_states.get(side, {})
			var card_ids: Array = side_tasks.keys()
			card_ids.sort()
			for raw_card_id in card_ids:
				var card_id: String = String(raw_card_id)
				var state: Dictionary = side_tasks[card_id]
				h = _fnv_mix(h, String(side).hash(), FNV_PRIME)
				h = _fnv_mix(h, card_id.hash(), FNV_PRIME)
				h = _fnv_mix(h, int(float(state.get("progress", 0.0)) * _F() + 0.5), FNV_PRIME)
				h = _fnv_mix(h, 1 if bool(state.get("completed", false)) else 0, FNV_PRIME)
				h = _fnv_mix(h, 1 if bool(state.get("evolved", false)) else 0, FNV_PRIME)

	h = _fnv_mix(h, int(stats.get("player_spent_fp", 0)), FNV_PRIME)
	h = _fnv_mix(h, int(stats.get("bot_spent_fp", 0)), FNV_PRIME)
	h = _fnv_mix(h, int(stats.get("units_lost", 0)), FNV_PRIME)
	h = _fnv_mix(h, int(stats.get("spell_casts", 0)), FNV_PRIME)
	# 最终再截一次，严格限定 32 位（FNV-1a 32bit 规范）
	return h & 0xFFFFFFFF
