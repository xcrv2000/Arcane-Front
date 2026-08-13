# Bot AI：脚本对手的出牌决策。
# 当前为 V0.1 trial 固定节奏策略：按固定牌组顺序循环出牌，费用不足则跳过。
# 出牌与玩家共用 BattleSimulator.try_play_card 入口，便于未来替换为联机输入源。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const MapMath = preload("res://scripts/support/map_math.gd")

var bot_play_cursor: int = 0
var bot_think_timer: float = 0.0


# 对局开始时重置 Bot 状态。
func reset() -> void:
	bot_play_cursor = 0
	bot_think_timer = 1.2


# 每帧推进 Bot 思考计时器，到点尝试出一张可负担的卡。
func update(delta: float, simulator: RefCounted, task_system: RefCounted) -> void:
	bot_think_timer -= delta
	if bot_think_timer > 0.0:
		return

	var attempts: int = 0
	while attempts < Config.BOT_DECK_IDS.size():
		var card_id: String = Config.BOT_DECK_IDS[bot_play_cursor % Config.BOT_DECK_IDS.size()]
		bot_play_cursor += 1
		attempts += 1
		var card: Dictionary = task_system.active_card_by_id(Config.BOT, card_id)
		if card.size() > 0 and simulator.bot_mana >= float(card["cost"]):
			var target_position: Vector2 = _choose_bot_position(card, simulator)
			simulator.try_play_card(Config.BOT, card, target_position)
			bot_think_timer = simulator.rng.randf_range(Config.BOT_THINK_MIN_DELAY, Config.BOT_THINK_MAX_DELAY)
			return

	bot_think_timer = 0.45


# 为 Bot 即将打出的卡选择落点：法术瞄向敌群/基地，单位走桥分路。
func _choose_bot_position(card: Dictionary, simulator: RefCounted) -> Vector2:
	if card["kind"] == "spell":
		var cluster: Vector2 = simulator.best_enemy_cluster(Config.BOT, float(card["radius"]))
		if cluster.x >= 0.0:
			return cluster
		return MapMath.base_position(Config.PLAYER) + Vector2(simulator.rng.randf_range(-2.5, 2.5), simulator.rng.randf_range(-2.0, 2.0))

	var lane_x: float = MapMath.bridge_x(bot_play_cursor)
	return Vector2(
		clamp(lane_x + simulator.rng.randf_range(-4.0, 4.0), 5.0, Config.MAP_WIDTH - 5.0),
		simulator.rng.randf_range(11.0, Config.BOT_DEPLOY_MAX_Y)
	)
