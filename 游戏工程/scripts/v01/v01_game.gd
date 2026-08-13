# V0.1/V0.2 对局控制器：Godot Control 节点入口。
# 职责仅限于生命周期、输入分发、每帧驱动模拟器与绘制器、屏幕状态切换。
# 不再直接包含战斗逻辑或绘制实现，相关职责已拆分到：
#   - simulation/battle_simulator.gd   战斗模拟核心
#   - simulation/task_system.gd         任务与进化系统
#   - simulation/bot_brain.gd           Bot AI
#   - presentation/ui_painter.gd        屏幕绘制与布局
#   - presentation/canvas_helpers.gd    绘制原语与单位美术
#   - support/map_math.gd               地图与几何工具
#   - config/game_config.gd             常量配置
extends Control

const Config = preload("res://scripts/config/game_config.gd")
const CardCatalog = preload("res://scripts/v01/card_catalog.gd")
const BattleSimulator = preload("res://scripts/simulation/battle_simulator.gd")
const TaskSystem = preload("res://scripts/simulation/task_system.gd")
const BotBrain = preload("res://scripts/simulation/bot_brain.gd")
const CanvasHelpers = preload("res://scripts/presentation/canvas_helpers.gd")
const UIPainter = preload("res://scripts/presentation/ui_painter.gd")

enum ScreenMode { DECK_SELECT, BATTLE, RESULT }

var screen_mode: int = ScreenMode.DECK_SELECT
var cards: Array[Dictionary] = []
var selected_card_ids: Array[String] = []
var selected_battle_card_id: String = ""

var helpers: CanvasHelpers
var simulator: BattleSimulator
var task_system: TaskSystem
var bot_brain: BotBrain
var painter: UIPainter


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	cards = CardCatalog.all_cards()
	helpers = CanvasHelpers.new()
	helpers.setup(get_theme_default_font())
	simulator = BattleSimulator.new()
	task_system = TaskSystem.new()
	task_system.setup(cards, simulator)
	simulator.setup(task_system)
	bot_brain = BotBrain.new()
	painter = UIPainter.new()
	painter.setup(helpers, simulator, task_system, cards)
	for index in range(min(Config.CARD_PICK_COUNT, cards.size())):
		selected_card_ids.append(cards[index]["id"])
	queue_redraw()


func _process(delta: float) -> void:
	if screen_mode != ScreenMode.BATTLE:
		return
	# 顺序与原实现一致：时间/费用 → 费用任务 → Bot → 单位 → 法术特效 → 胜负检测。
	simulator.advance_time(delta)
	task_system.check_mana(Config.PLAYER, simulator.player_mana)
	task_system.check_mana(Config.BOT, simulator.bot_mana)
	bot_brain.update(delta, simulator, task_system)
	simulator.update_units(delta)
	simulator.update_spell_effects(delta)
	simulator.update_evolution_flashes(delta)
	if screen_mode == ScreenMode.BATTLE and not simulator.running:
		screen_mode = ScreenMode.RESULT
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_press(event.position)
	elif event is InputEventScreenTouch and event.pressed:
		_handle_press(event.position)


func _input(event: InputEvent) -> void:
	if screen_mode != ScreenMode.BATTLE:
		return
	if not (event is InputEventKey and event.pressed):
		return

	var keycode: Key = event.keycode
	match keycode:
		KEY_EQUAL, KEY_PLUS:
			simulator.player_mana = min(Config.MANA_MAX, simulator.player_mana + 2.0)
			simulator.push_event("调试：费用 +2")
		KEY_MINUS:
			simulator.player_mana = max(0.0, simulator.player_mana - 2.0)
			simulator.push_event("调试：费用 -2")
		KEY_T:
			if selected_battle_card_id != "":
				task_system.force_complete_task(Config.PLAYER, selected_battle_card_id)
				simulator.push_event("调试：强制完成 %s 任务" % selected_battle_card_id)
		KEY_R:
			_start_battle()
		KEY_D:
			bot_brain.set_use_random_deck(not bot_brain.use_random_deck)
			simulator.push_event("调试：Bot 牌组模式 → %s" % ("随机" if bot_brain.use_random_deck else "固定"))
		KEY_S:
			simulator.rng.seed = simulator.rng.randi()
			simulator.push_event("调试：随机种子已重置")
		KEY_F:
			_toggle_debug_overlay()


var show_debug_overlay: bool = true


func _toggle_debug_overlay() -> void:
	show_debug_overlay = not show_debug_overlay
	simulator.push_event("调试：调试面板 %s" % ("显示" if show_debug_overlay else "隐藏"))


func _handle_press(position: Vector2) -> void:
	painter.update_layout(size, screen_mode == ScreenMode.DECK_SELECT)
	if screen_mode == ScreenMode.DECK_SELECT:
		_handle_deck_press(position)
	elif screen_mode == ScreenMode.BATTLE:
		_handle_battle_press(position)
	elif screen_mode == ScreenMode.RESULT:
		if painter.restart_rect.has_point(position):
			_start_battle()
		elif painter.deck_rect.has_point(position):
			screen_mode = ScreenMode.DECK_SELECT
			queue_redraw()


func _handle_deck_press(position: Vector2) -> void:
	for raw_card_id in painter.card_pick_rects.keys():
		var card_id: String = String(raw_card_id)
		if painter.card_pick_rects[card_id].has_point(position):
			_toggle_card_selection(card_id)
			queue_redraw()
			return

	if painter.start_rect.has_point(position):
		if selected_card_ids.size() == Config.CARD_PICK_COUNT:
			_start_battle()
		else:
			simulator.push_event("需要选择 6 张卡。")
			queue_redraw()


func _handle_battle_press(position: Vector2) -> void:
	for raw_card_id in painter.battle_card_rects.keys():
		var card_id: String = String(raw_card_id)
		if painter.battle_card_rects[card_id].has_point(position):
			selected_battle_card_id = card_id
			painter.info_card_id = card_id
			var card: Dictionary = task_system.active_card_by_id(Config.PLAYER, card_id)
			if simulator.player_mana < float(card["cost"]):
				simulator.push_event("%s 费用不足。" % card["name"])
			queue_redraw()
			return

	if painter.is_in_board(position) and selected_battle_card_id != "":
		var logic_position: Vector2 = painter.screen_to_map(position)
		var card: Dictionary = task_system.active_card_by_id(Config.PLAYER, selected_battle_card_id)
		simulator.try_play_card(Config.PLAYER, card, logic_position)
		queue_redraw()


func _toggle_card_selection(card_id: String) -> void:
	if selected_card_ids.has(card_id):
		selected_card_ids.erase(card_id)
	elif selected_card_ids.size() < Config.CARD_PICK_COUNT:
		selected_card_ids.append(card_id)
	else:
		simulator.push_event("V0.2 单局仍只能携带 6 张卡。")


func _start_battle() -> void:
	screen_mode = ScreenMode.BATTLE
	selected_battle_card_id = selected_card_ids[0]
	painter.info_card_id = selected_card_ids[0]
	bot_brain.reset()
	task_system.initialize(selected_card_ids, bot_brain.current_deck())
	simulator.start_battle()
	simulator.push_event("V0.3 对局开始：任务完成后卡牌自动进化。Bot 卡组：%s" % ", ".join(bot_brain.current_deck()))
	queue_redraw()


func _draw() -> void:
	painter.update_layout(size, screen_mode == ScreenMode.DECK_SELECT)
	painter.selected_card_ids = selected_card_ids
	painter.selected_battle_card_id = selected_battle_card_id
	painter.draw_background(self)
	if screen_mode == ScreenMode.DECK_SELECT:
		painter.draw_deck_select(self)
	else:
		painter.draw_battle(self)
		if show_debug_overlay and screen_mode == ScreenMode.BATTLE:
			painter.draw_debug_overlay(self, bot_brain.current_deck(), simulator.rng.seed)
		if screen_mode == ScreenMode.RESULT:
			painter.draw_result_overlay(self)
