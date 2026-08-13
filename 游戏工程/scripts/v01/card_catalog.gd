extends RefCounted

const CARD_DATA_PATH: String = "res://data/cards.json"

static func all_cards() -> Array[Dictionary]:
<<<<<<< Updated upstream
	return [
		{
			"id": "spark_swarm",
			"name": "星屑群",
			"short_name": "群",
			"role": "数量杂兵",
			"kind": "unit",
			"cost": 2,
			"count": 4,
			"hp": 24.0,
			"damage": 6.0,
			"attack_cooldown": 0.85,
			"range": 1.4,
			"speed": 7.0,
			"radius": 0.55,
			"shape": "circle",
			"color": Color(0.45, 0.83, 0.86),
			"trial_note": "低费多数量，测试场面铺开速度。",
			"task": {
				"type": "card_play_count",
				"summary": "本局中打出过三次星屑群。",
				"progress_label": "星屑群",
				"watch_card_id": "spark_swarm",
				"target": 3
			},
			"evolution": {
				"id": "spark_drift",
				"name": "星屑漂流",
				"short_name": "漂",
				"summary": "数量变为 6，其余效果属性不变。",
				"overrides": {
					"count": 6
				}
			}
		},
		{
			"id": "shield_pair",
			"name": "盾卫",
			"short_name": "盾",
			"role": "肉盾杂兵",
			"kind": "unit",
			"cost": 3,
			"count": 2,
			"hp": 92.0,
			"damage": 10.0,
			"attack_cooldown": 1.25,
			"range": 1.5,
			"speed": 4.1,
			"radius": 1.05,
			"shape": "square",
			"color": Color(0.52, 0.70, 0.96),
			"trial_note": "中低费承伤单位，测试抗线价值。",
			"task": {
				"type": "unit_hp_below_ratio",
				"summary": "当前血量低于 2/3。",
				"progress_label": "低血",
				"watch_card_id": "shield_pair",
				"target": 1,
				"hp_ratio": 0.6667
			},
			"evolution": {
				"id": "steadfast_guard",
				"name": "坚盾护卫",
				"short_name": "坚",
				"summary": "生命值翻倍，其余效果属性不变。",
				"overrides": {
					"hp": 184.0
				}
			}
		},
		{
			"id": "cleaver",
			"name": "旋刃兵",
			"short_name": "旋",
			"role": "近战 AOE",
			"kind": "unit",
			"cost": 4,
			"count": 1,
			"hp": 128.0,
			"damage": 18.0,
			"attack_cooldown": 1.45,
			"range": 1.8,
			"speed": 4.4,
			"radius": 1.15,
			"aoe_radius": 3.4,
			"shape": "triangle",
			"color": Color(0.93, 0.70, 0.37),
			"trial_note": "近战范围伤害，测试反杂兵能力。",
			"task": {
				"type": "card_kill_count",
				"summary": "所有旋刃兵在本局中总共杀死超过 12 个敌人。",
				"progress_label": "击杀",
				"watch_card_id": "cleaver",
				"target": 13,
				"target_text": ">12"
			},
			"evolution": {
				"id": "wheel_blade",
				"name": "轮刃兵",
				"short_name": "轮",
				"summary": "攻击间隔减少到 1.2 秒，射程提升到 3。",
				"overrides": {
					"attack_cooldown": 1.2,
					"range": 3.0
				}
			}
		},
		{
			"id": "quick_archer",
			"name": "连弩手",
			"short_name": "频",
			"role": "频率远程",
			"kind": "unit",
			"cost": 3,
			"count": 1,
			"hp": 54.0,
			"damage": 7.0,
			"attack_cooldown": 0.5,
			"range": 12.0,
			"speed": 3.7,
			"radius": 0.9,
			"shape": "circle",
			"color": Color(0.57, 0.86, 0.54),
			"trial_note": "高频低伤远程，测试持续输出读秒。",
			"task": {
				"type": "card_play_burst",
				"summary": "3 秒钟内使用 3 个连弩手。",
				"progress_label": "连发",
				"watch_card_id": "quick_archer",
				"target": 3,
				"window": 3.0
			},
			"evolution": {
				"id": "roaming_archer",
				"name": "漫游弓手",
				"short_name": "游",
				"summary": "一次攻击同时攻击两个敌对目标。",
				"overrides": {
					"multi_target_count": 2
				}
			}
		},
		{
			"id": "ember_mage",
			"name": "秘火手",
			"short_name": "火",
			"role": "伤害远程",
			"kind": "unit",
			"cost": 4,
			"count": 1,
			"hp": 50.0,
			"damage": 24.0,
			"attack_cooldown": 1.45,
			"range": 14.0,
			"speed": 3.1,
			"radius": 0.95,
			"shape": "triangle",
			"color": Color(0.95, 0.43, 0.35),
			"trial_note": "慢频高伤远程，测试爆发换线。",
			"task": {
				"type": "single_unit_kill_count",
				"summary": "一名秘火手击杀 3 名敌人。",
				"progress_label": "单体击杀",
				"watch_card_id": "ember_mage",
				"target": 3
			},
			"evolution": {
				"id": "fire_thrower",
				"name": "投火手",
				"short_name": "投",
				"summary": "攻击落点附带半径为 2 的 AOE。",
				"overrides": {
					"aoe_radius": 2.0
				}
			}
		},
		{
			"id": "arcane_giant",
			"name": "奥术巨像",
			"short_name": "巨",
			"role": "巨型单位",
			"kind": "unit",
			"cost": 6,
			"count": 1,
			"hp": 270.0,
			"damage": 34.0,
			"attack_cooldown": 1.7,
			"range": 2.1,
			"speed": 2.6,
			"radius": 1.8,
			"shape": "square",
			"target_base_only": true,
			"color": Color(0.80, 0.66, 0.96),
			"trial_note": "慢速高血量，只盯基地，测试推进压力。",
			"task": {
				"type": "mana_reached",
				"summary": "拥有 10 点法力。",
				"progress_label": "法力",
				"target": 10
			},
			"evolution": {
				"id": "arcane_power_giant",
				"name": "奥能巨像",
				"short_name": "能",
				"summary": "基础半径变为 2；每 0.6 秒对 2.1 范围内造成 6 点 AOE 伤害。",
				"overrides": {
					"radius": 2.0,
					"aura_interval": 0.6,
					"aura_radius": 2.1,
					"aura_damage": 6.0
				}
			}
		},
		{
			"id": "soul_lance",
			"name": "裂魂矢",
			"short_name": "矢",
			"role": "对单法术",
			"kind": "spell",
			"cost": 3,
			"damage": 82.0,
			"base_damage": 33.0,
			"radius": 4.4,
			"spell_mode": "single",
			"color": Color(0.73, 0.55, 0.95),
			"trial_note": "指定区域内命中最近单体；贴近基地时造成较低基地伤害。",
			"task": {
				"type": "base_hit_count",
				"summary": "用裂魂矢攻击三次敌方基底。",
				"progress_label": "攻基",
				"watch_card_id": "soul_lance",
				"target": 3
			},
			"evolution": {
				"id": "sky_rift_arrow",
				"name": "裂天矢",
				"short_name": "天",
				"summary": "费用变为 5；对己方基地到目标点路径上所有单位和基地造成伤害，己方基地也会被路径命中。",
				"overrides": {
					"cost": 5,
					"spell_mode": "line"
				}
			}
		},
		{
			"id": "starfall",
			"name": "星陨",
			"short_name": "陨",
			"role": "对群法术",
			"kind": "spell",
			"cost": 4,
			"damage": 46.0,
			"base_damage": 24.0,
			"radius": 8.8,
			"spell_mode": "area",
			"color": Color(0.96, 0.82, 0.42),
			"trial_note": "范围伤害，测试清杂兵和压基地的取舍。",
			"task": {
				"type": "linked_card_play_count",
				"summary": "使用 3 次星屑群。",
				"progress_label": "星屑群",
				"watch_card_id": "spark_swarm",
				"target": 3
			},
			"evolution": {
				"id": "star_scatter",
				"name": "星散",
				"short_name": "散",
				"summary": "范围半径扩大到 12。",
				"overrides": {
					"radius": 12.0
				}
			}
		}
	]
=======
	var cards: Array[Dictionary] = _load_cards_from_json()
	if cards.is_empty():
		push_error("CardCatalog did not load any cards from %s." % CARD_DATA_PATH)
	return cards

static func _load_cards_from_json() -> Array[Dictionary]:
	if not FileAccess.file_exists(CARD_DATA_PATH):
		push_error("Card data file is missing: %s." % CARD_DATA_PATH)
		return []

	var file: FileAccess = FileAccess.open(CARD_DATA_PATH, FileAccess.READ)
	if file == null:
		push_error("Card data file could not be opened: %s." % CARD_DATA_PATH)
		return []

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		push_error("Card data JSON could not be parsed: %s." % CARD_DATA_PATH)
		return []

	var raw_cards: Variant = []
	if typeof(parsed) == TYPE_DICTIONARY:
		raw_cards = parsed.get("cards", [])
	elif typeof(parsed) == TYPE_ARRAY:
		raw_cards = parsed

	if typeof(raw_cards) != TYPE_ARRAY:
		push_error("Card data JSON must contain a cards array: %s." % CARD_DATA_PATH)
		return []

	var cards: Array[Dictionary] = []
	for raw_card in raw_cards:
		if typeof(raw_card) != TYPE_DICTIONARY:
			continue
		var card: Dictionary = raw_card.duplicate(true)
		_normalize_card(card)
		cards.append(card)
	return cards

static func _normalize_card(card: Dictionary) -> void:
	card["color"] = _color_from_value(card.get("color", "#ffffff"))

	var evolution: Dictionary = card.get("evolution", {})
	if evolution.is_empty():
		return

	var overrides: Dictionary = evolution.get("overrides", {})
	if overrides.has("color"):
		overrides["color"] = _color_from_value(overrides["color"])

static func _color_from_value(value: Variant) -> Color:
	if value is Color:
		return value

	if typeof(value) == TYPE_STRING:
		var text: String = String(value).strip_edges()
		if Color.html_is_valid(text):
			return Color.html(text)
		if Color.html_is_valid("#" + text):
			return Color.html("#" + text)

	if typeof(value) == TYPE_ARRAY:
		var components: Array = value
		if components.size() >= 3:
			var alpha: float = 1.0
			if components.size() >= 4:
				alpha = float(components[3])
			return Color(float(components[0]), float(components[1]), float(components[2]), alpha)

	return Color.WHITE
>>>>>>> Stashed changes
