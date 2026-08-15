# Bot AI：脚本对手的出牌决策。
# V0.3：支持随机从卡池选 6 张、法术/单位混合出牌、可切换固定牌组。
# V0.4 (P0)：不再直接调用 simulator.try_play_card，改为输出一条 Command。
#   调用方（控制器 / 未来的联机层）负责将命令送入 lockstep_scheduler。
#   update() 返回 Array[Dictionary]（此 tick 产生的命令列表，通常 0 或 1 条）。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const MapMath = preload("res://scripts/support/map_math.gd")
const CardCatalog = preload("res://scripts/v01/card_catalog.gd")
const Command = preload("res://scripts/networking/command.gd")

var bot_deck_ids: Array[String] = []  # 当前 Bot 使用的 6 张卡 id
var bot_play_cursor: int = 0
var bot_think_timer: float = 0.0
var use_random_deck: bool = true  # true=随机选 6 张；false=使用固定牌组
var selected_random_ids: Array[String] = []  # 随机选中的卡牌
var deck_rng: RandomNumberGenerator = RandomNumberGenerator.new()


# 对局开始时重置 Bot 状态。
func reset() -> void:
	bot_play_cursor = 0
	bot_think_timer = 1.2
	if use_random_deck:
		_select_random_deck()
	else:
		bot_deck_ids = _filter_ai_deck_ids(Config.BOT_DECK_IDS)
	selected_random_ids = bot_deck_ids.duplicate()


# 从全卡池中随机选 6 张不同的卡。
func _select_random_deck() -> void:
	var all_ids: Array[String] = []
	for card in CardCatalog.deckable_cards():
		if bool(card.get("ai_deckable", true)):
			all_ids.append(String(card["id"]))
	bot_deck_ids.clear()
	var pool: Array[String] = all_ids.duplicate()
	deck_rng.seed = Time.get_ticks_msec()
	while bot_deck_ids.size() < min(6, pool.size()):
		var index: int = deck_rng.randi() % pool.size()
		bot_deck_ids.append(pool[index])
		pool.remove_at(index)


func _filter_ai_deck_ids(source_ids: Array) -> Array[String]:
	var eligible_by_id: Dictionary = {}
	for card in CardCatalog.deckable_cards():
		eligible_by_id[String(card["id"])] = bool(card.get("ai_deckable", true))
	var filtered: Array[String] = []
	for raw_card_id in source_ids:
		var card_id: String = String(raw_card_id)
		if bool(eligible_by_id.get(card_id, false)):
			filtered.append(card_id)
	return filtered


# 每 tick（固定步长）推进 Bot 思考计时器，到点返回一条出牌命令。
# P0 本地实现：delta 使用 TICK_DT。controller 每 tick 调一次，返回命令列表。
func update(delta: float, simulator: RefCounted, task_sys: RefCounted, execution_tick: int) -> Array[Dictionary]:
	var cmds: Array[Dictionary] = []
	bot_think_timer -= delta
	if bot_think_timer > 0.0:
		return cmds

	var attempts: int = 0
	while attempts < bot_deck_ids.size():
		var card_id: String = bot_deck_ids[bot_play_cursor % bot_deck_ids.size()]
		bot_play_cursor += 1
		attempts += 1
		var card: Dictionary = task_sys.active_card_by_id(Config.BOT, card_id)
		if card.size() > 0 and simulator.bot_mana() >= float(card["cost"]) and simulator.card_cooldown_ticks(Config.BOT, card_id) <= 0:
			var target_position: Vector2 = _choose_bot_position(card, simulator)
			cmds.append(Command.play_card_command(
				execution_tick,
				Config.BOT,
				card_id,
				target_position.x,
				target_position.y
			))
			bot_think_timer = simulator.rng.randf_range(Config.BOT_THINK_MIN_DELAY, Config.BOT_THINK_MAX_DELAY)
			return cmds

	bot_think_timer = 0.45
	return cmds


# 为 Bot 即将打出的卡选择落点：法术瞄向敌群/基地，单位走桥分路。
func _choose_bot_position(card: Dictionary, simulator: RefCounted) -> Vector2:
	if card["kind"] == "spell":
		if bool(card.get("cast_own_half_only", false)) or String(card.get("spell_mode", "")) == "death_mana_zone":
			return Vector2(MapMath.bridge_x(bot_play_cursor), Config.RIVER_Y - 8.0)
		var cluster: Vector2 = simulator.best_enemy_cluster(Config.BOT, float(card["radius"]))
		if cluster.x >= 0.0:
			return cluster
		return MapMath.base_position(Config.PLAYER) + Vector2(simulator.rng.randf_range(-2.5, 2.5), simulator.rng.randf_range(-2.0, 2.0))

	var lane_x: float = MapMath.bridge_x(bot_play_cursor)
	return Vector2(
		clamp(lane_x + simulator.rng.randf_range(-4.0, 4.0), 5.0, Config.MAP_WIDTH - 5.0),
		simulator.rng.randf_range(11.0, Config.BOT_DEPLOY_MAX_Y)
	)


# 切换 Bot 牌组模式（供控制器/调试工具调用）。
func set_use_random_deck(enabled: bool) -> void:
	use_random_deck = enabled


# 获取当前 Bot 牌组（供调试显示）。
func current_deck() -> Array[String]:
	return bot_deck_ids
