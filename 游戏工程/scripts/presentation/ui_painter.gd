# UI 绘制与布局层：负责所有屏幕绘制（选卡、战场、结算）与屏幕/逻辑坐标换算。
# 拥有布局矩形缓存（供控制器做点击命中测试），但不处理输入逻辑本身。
# 依赖：CanvasHelpers（低层绘制原语与单位美术）、BattleSimulator/TaskSystem（读取对局状态）。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const MapMath = preload("res://scripts/support/map_math.gd")

var helpers: RefCounted = null  # CanvasHelpers
var simulator: RefCounted = null  # BattleSimulator
var task_system: RefCounted = null  # TaskSystem
var cards: Array[Dictionary] = []

# 当前视口尺寸与布局缓存（由控制器在绘制/输入前刷新）。
var view_size: Vector2 = Vector2.ZERO
var board_rect: Rect2 = Rect2()
var card_pick_rects: Dictionary = {}
var battle_card_rects: Dictionary = {}
var start_rect: Rect2 = Rect2()
var restart_rect: Rect2 = Rect2()
var deck_rect: Rect2 = Rect2()

# 控制器在选卡/出牌时同步更新这两个字段，供绘制读取。
var selected_card_ids: Array[String] = []
var selected_battle_card_id: String = ""
var info_card_id: String = ""  # 当前显示详情的卡牌 id


# 注入依赖与卡牌数据。
func setup(helpers_ref: RefCounted, sim: RefCounted, task_sys: RefCounted, card_list: Array[Dictionary]) -> void:
	helpers = helpers_ref
	simulator = sim
	task_system = task_sys
	cards = card_list


# 依据视口尺寸计算战场板面矩形；选卡界面不使用板面，直接返回。
func update_layout(new_view_size: Vector2, is_deck_select: bool) -> void:
	view_size = new_view_size
	if is_deck_select:
		return

	var top: float = 70.0
	var bottom: float = 232.0
	var margin: float = 12.0
	var available: Rect2 = Rect2(margin, top, view_size.x - margin * 2.0, max(100.0, view_size.y - top - bottom))
	var map_aspect: float = Config.MAP_WIDTH / Config.MAP_HEIGHT
	var map_width: float = available.size.x
	var map_height: float = map_width / map_aspect
	if map_height > available.size.y:
		map_height = available.size.y
		map_width = map_height * map_aspect
	board_rect = Rect2(available.position + Vector2((available.size.x - map_width) * 0.5, 0.0), Vector2(map_width, map_height))


# 逻辑坐标 → 屏幕坐标。
func map_to_screen(logic_position: Vector2) -> Vector2:
	return board_rect.position + Vector2(
		logic_position.x / Config.MAP_WIDTH * board_rect.size.x,
		logic_position.y / Config.MAP_HEIGHT * board_rect.size.y
	)


# 屏幕坐标 → 逻辑坐标（限制在地图范围内）。
func screen_to_map(screen_position: Vector2) -> Vector2:
	return Vector2(
		clamp((screen_position.x - board_rect.position.x) / board_rect.size.x * Config.MAP_WIDTH, 0.0, Config.MAP_WIDTH),
		clamp((screen_position.y - board_rect.position.y) / board_rect.size.y * Config.MAP_HEIGHT, 0.0, Config.MAP_HEIGHT)
	)


# 逻辑长度 → 像素长度（按地图长边换算）。
func logic_to_pixels(value: float) -> float:
	return value / Config.MAP_HEIGHT * board_rect.size.y


# 屏幕点是否落在战场板面内。
func is_in_board(position: Vector2) -> bool:
	return board_rect.has_point(position)


# 绘制全屏背景底色。
func draw_background(canvas: CanvasItem) -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, view_size), Color(0.06, 0.07, 0.09))


# —— 选卡界面 ——
func draw_deck_select(canvas: CanvasItem) -> void:
	card_pick_rects.clear()
	var margin: float = max(18.0, view_size.x * 0.04)
	var title_y: float = 30.0
	helpers.draw_text_line(canvas, "奥术前线 V0.2", Rect2(margin, title_y, view_size.x - margin * 2.0, 34.0), 24, Color(0.95, 0.96, 0.98), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "8 选 6；局内任务完成后自动进化。", Rect2(margin, title_y + 42.0, view_size.x - margin * 2.0, 24.0), 16, Color(0.68, 0.73, 0.80), HORIZONTAL_ALIGNMENT_CENTER)

	var grid_top: float = title_y + 82.0
	var gap: float = 10.0
	var grid_width: float = view_size.x - margin * 2.0
	var card_width: float = (grid_width - gap) * 0.5
	var bottom_space: float = 126.0
	var card_height: float = clamp((view_size.y - grid_top - bottom_space - gap * 3.0) / 4.0, 88.0, 128.0)

	for index in range(cards.size()):
		var col: int = index % 2
		var row: int = int(index / 2)
		var rect: Rect2 = Rect2(
			Vector2(margin + col * (card_width + gap), grid_top + row * (card_height + gap)),
			Vector2(card_width, card_height)
		)
		var card: Dictionary = cards[index]
		card_pick_rects[card["id"]] = rect
		_draw_pick_card(canvas, card, rect, selected_card_ids.has(card["id"]))

	var info_rect: Rect2 = Rect2(margin, view_size.y - 116.0, view_size.x - margin * 2.0, 22.0)
	helpers.draw_text_line(canvas, "已选 %d/%d" % [selected_card_ids.size(), Config.CARD_PICK_COUNT], info_rect, 18, Color(0.86, 0.90, 0.95), HORIZONTAL_ALIGNMENT_CENTER)
	var hint: String = "点选卡牌切换配置；进化只影响后续使用。"
	if simulator.event_log.size() > 0:
		hint = simulator.event_log[simulator.event_log.size() - 1]
	helpers.draw_text_line(canvas, hint, Rect2(margin, view_size.y - 94.0, view_size.x - margin * 2.0, 18.0), 13, Color(0.62, 0.68, 0.76), HORIZONTAL_ALIGNMENT_CENTER)
	start_rect = Rect2(margin, view_size.y - 78.0, view_size.x - margin * 2.0, 54.0)
	var start_enabled: bool = selected_card_ids.size() == Config.CARD_PICK_COUNT
	var start_color: Color = Color(0.24, 0.56, 0.88) if start_enabled else Color(0.18, 0.20, 0.24)
	var start_text_color: Color = Color.WHITE if start_enabled else Color(0.50, 0.54, 0.60)
	helpers.draw_panel(canvas, start_rect, start_color, 8.0, Color(0.58, 0.78, 0.98) if start_enabled else Color(0.26, 0.28, 0.32), 2.0)
	helpers.draw_text_line(canvas, "开始本地对局" if start_enabled else "请选择 6 张卡", start_rect, 20, start_text_color, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_pick_card(canvas: CanvasItem, card: Dictionary, rect: Rect2, selected: bool) -> void:
	var base_color: Color = Color(0.13, 0.15, 0.19)
	if selected:
		base_color = Color(0.14, 0.23, 0.31)
	helpers.draw_panel(canvas, rect, base_color, 7.0, Color(0.34, 0.62, 0.84) if selected else Color(0.24, 0.27, 0.32), 2.0 if selected else 1.0)

	var icon_rect: Rect2 = Rect2(rect.position + Vector2(10.0, 12.0), Vector2(42.0, 42.0))
	if not helpers.draw_card_art_icon(canvas, card, icon_rect.get_center(), 40.0, Color.WHITE):
		helpers.draw_unit_shape(canvas, card, icon_rect.get_center(), 13.0, card["color"], Color(0.04, 0.05, 0.07), String(card["short_name"]), 18)
	helpers.draw_text_line(canvas, "%s  %d费" % [card["name"], int(card["cost"])], Rect2(rect.position + Vector2(60.0, 12.0), Vector2(rect.size.x - 70.0, 24.0)), 17, Color(0.95, 0.96, 0.98), HORIZONTAL_ALIGNMENT_LEFT)
	helpers.draw_text_line(canvas, card["role"], Rect2(rect.position + Vector2(60.0, 38.0), Vector2(rect.size.x - 70.0, 20.0)), 14, Color(0.64, 0.71, 0.78), HORIZONTAL_ALIGNMENT_LEFT)

	var note: String = "trial：" + String(card["trial_note"])
	helpers.draw_two_line_text(canvas, note, Rect2(rect.position + Vector2(10.0, 62.0), Vector2(rect.size.x - 20.0, 38.0)), 13, Color(0.70, 0.76, 0.82))
	var evolution: Dictionary = card.get("evolution", {})
	helpers.draw_text_line(canvas, "进化：%s" % String(evolution.get("name", "未设置")), Rect2(rect.position + Vector2(10.0, rect.size.y - 24.0), Vector2(rect.size.x - 20.0, 18.0)), 12, Color(0.86, 0.72, 0.42), HORIZONTAL_ALIGNMENT_RIGHT)

	if selected:
		canvas.draw_circle(rect.position + Vector2(rect.size.x - 18.0, 18.0), 10.0, Color(0.35, 0.78, 0.95))
		helpers.draw_text_line(canvas, "✓", Rect2(rect.position + Vector2(rect.size.x - 28.0, 7.0), Vector2(20.0, 20.0)), 16, Color(0.04, 0.06, 0.08), HORIZONTAL_ALIGNMENT_CENTER)


# —— 战场界面 ——
func draw_battle(canvas: CanvasItem) -> void:
	battle_card_rects.clear()
	_draw_battle_header(canvas)
	_draw_map(canvas)
	_draw_card_info_panel(canvas)
	_draw_battle_card_bar(canvas)
	_draw_event_log(canvas)


func _draw_battle_header(canvas: CanvasItem) -> void:
	var margin: float = 14.0
	var header: Rect2 = Rect2(margin, 12.0, view_size.x - margin * 2.0, 48.0)
	helpers.draw_panel(canvas, header, Color(0.10, 0.12, 0.15), 7.0, Color(0.20, 0.23, 0.28), 1.0)
	var player_base: Dictionary = simulator.bases[Config.PLAYER]
	var bot_base: Dictionary = simulator.bases[Config.BOT]
	var left: String = "我方基地 %d/300  费 %.1f/10" % [int(ceil(float(player_base["hp"]))), simulator.player_mana]
	var right: String = "Bot基地 %d/300  费 %.1f/10" % [int(ceil(float(bot_base["hp"]))), simulator.bot_mana]
	helpers.draw_text_line(canvas, left, Rect2(header.position + Vector2(12.0, 6.0), Vector2(header.size.x - 24.0, 18.0)), 15, Color(0.72, 0.88, 1.0), HORIZONTAL_ALIGNMENT_LEFT)
	helpers.draw_text_line(canvas, right, Rect2(header.position + Vector2(12.0, 25.0), Vector2(header.size.x - 24.0, 18.0)), 15, Color(1.0, 0.72, 0.70), HORIZONTAL_ALIGNMENT_LEFT)
	helpers.draw_text_line(canvas, "清屏 %d:%d" % [int(player_base["clear_count"]), int(bot_base["clear_count"])], Rect2(header.position + Vector2(0.0, 15.0), header.size), 15, Color(0.78, 0.82, 0.88), HORIZONTAL_ALIGNMENT_RIGHT)


func _draw_map(canvas: CanvasItem) -> void:
	helpers.draw_panel(canvas, board_rect, Color(0.08, 0.09, 0.10), 8.0, Color(0.24, 0.27, 0.32), 1.0)
	var bot_half: Rect2 = Rect2(board_rect.position, Vector2(board_rect.size.x, board_rect.size.y * 0.5))
	var player_half: Rect2 = Rect2(board_rect.position + Vector2(0.0, board_rect.size.y * 0.5), Vector2(board_rect.size.x, board_rect.size.y * 0.5))
	canvas.draw_rect(bot_half.grow(-2.0), Color(0.24, 0.10, 0.10))
	canvas.draw_rect(player_half.grow(-2.0), Color(0.08, 0.16, 0.25))

	var river_top: float = map_to_screen(Vector2(0.0, Config.RIVER_Y - 2.1)).y
	var river_bottom: float = map_to_screen(Vector2(0.0, Config.RIVER_Y + 2.1)).y
	var river_rect: Rect2 = Rect2(Vector2(board_rect.position.x + 2.0, river_top), Vector2(board_rect.size.x - 4.0, river_bottom - river_top))
	canvas.draw_rect(river_rect, Color(0.07, 0.25, 0.34))

	for bridge_x in [16.0, 40.0]:
		var bridge_center: Vector2 = map_to_screen(Vector2(float(bridge_x), Config.RIVER_Y))
		var bridge_size: Vector2 = Vector2(logic_to_pixels(7.2), logic_to_pixels(8.0))
		var bridge_rect: Rect2 = Rect2(bridge_center - bridge_size * 0.5, bridge_size)
		canvas.draw_rect(bridge_rect, Color(0.48, 0.38, 0.28))
		canvas.draw_rect(bridge_rect, Color(0.78, 0.66, 0.46), false, max(1.0, logic_to_pixels(0.25)))

	var deploy_line: float = map_to_screen(Vector2(0.0, Config.PLAYER_DEPLOY_MIN_Y)).y
	canvas.draw_line(Vector2(board_rect.position.x + 6.0, deploy_line), Vector2(board_rect.end.x - 6.0, deploy_line), Color(0.47, 0.73, 0.96, 0.55), 1.0)
	helpers.draw_text_line(canvas, "我方单位部署区", Rect2(board_rect.position.x + 8.0, deploy_line + 4.0, board_rect.size.x - 16.0, 18.0), 12, Color(0.60, 0.80, 0.98, 0.80), HORIZONTAL_ALIGNMENT_CENTER)

	_draw_base(canvas, Config.BOT)
	_draw_base(canvas, Config.PLAYER)
	_draw_clock(canvas)
	for effect in simulator.spell_effects:
		_draw_spell_effect(canvas, effect)
	for unit in simulator.units:
		_draw_unit(canvas, unit)


func _draw_base(canvas: CanvasItem, side: String) -> void:
	var base: Dictionary = simulator.bases[side]
	var center: Vector2 = map_to_screen(MapMath.base_position(side))
	var radius: float = logic_to_pixels(Config.BASE_RADIUS)
	var fill: Color = Color(0.58, 0.14, 0.13) if side == Config.BOT else Color(0.10, 0.34, 0.58)
	canvas.draw_circle(center, radius, fill)
	canvas.draw_circle(center, radius, Color(0.90, 0.92, 0.95), false, 2.0)
	helpers.draw_text_line(canvas, "基", Rect2(center - Vector2(radius, radius * 0.65), Vector2(radius * 2.0, radius * 1.3)), 19, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)

	var bar_width: float = radius * 2.2
	var bar_rect: Rect2 = Rect2(center + Vector2(-bar_width * 0.5, radius + 5.0), Vector2(bar_width, 5.0))
	canvas.draw_rect(bar_rect, Color(0.08, 0.08, 0.09))
	canvas.draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * float(base["hp"]) / Config.BASE_MAX_HP, bar_rect.size.y)), Color(0.86, 0.20, 0.18))


func _draw_clock(canvas: CanvasItem) -> void:
	var center: Vector2 = map_to_screen(Vector2(Config.MAP_WIDTH * 0.5, Config.RIVER_Y))
	var clock_rect: Rect2 = Rect2(center - Vector2(42.0, 17.0), Vector2(84.0, 34.0))
	helpers.draw_panel(canvas, clock_rect, Color(0.04, 0.06, 0.08, 0.88), 6.0, Color(0.52, 0.67, 0.78), 1.0)
	helpers.draw_text_line(canvas, _format_time(simulator.battle_time), clock_rect, 19, Color(0.90, 0.96, 1.0), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_spell_effect(canvas: CanvasItem, effect: Dictionary) -> void:
	var alpha: float = clamp(float(effect["time"]) / float(effect["max_time"]), 0.0, 1.0)
	var color: Color = effect["color"]
	if String(effect.get("mode", "circle")) == "line":
		var start: Vector2 = map_to_screen(effect["from"])
		var end: Vector2 = map_to_screen(effect["pos"])
		var width: float = max(2.0, logic_to_pixels(float(effect["radius"]) * 2.0))
		color.a = 0.16 * alpha
		canvas.draw_line(start, end, color, width, true)
		color.a = 0.82 * alpha
		canvas.draw_line(start, end, color, max(2.0, width * 0.18), true)
		canvas.draw_circle(end, max(5.0, width * 0.16), color)
		helpers.draw_text_line(canvas, effect["label"], Rect2(end - Vector2(24.0, 12.0), Vector2(48.0, 24.0)), 16, Color(1.0, 0.96, 0.78, alpha), HORIZONTAL_ALIGNMENT_CENTER)
		return
	color.a = 0.22 * alpha
	var center: Vector2 = map_to_screen(effect["pos"])
	var radius: float = logic_to_pixels(float(effect["radius"]))
	canvas.draw_circle(center, radius, color)
	color.a = 0.75 * alpha
	canvas.draw_circle(center, radius, color, false, 2.0)
	helpers.draw_text_line(canvas, effect["label"], Rect2(center - Vector2(24.0, 12.0), Vector2(48.0, 24.0)), 16, Color(1.0, 0.96, 0.78, alpha), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_unit(canvas: CanvasItem, unit: Dictionary) -> void:
	var center: Vector2 = map_to_screen(unit["pos"])
	var radius: float = logic_to_pixels(float(unit["radius"]))
	var side: String = String(unit["side"])
	var fill: Color = unit["color"]
	if side == Config.BOT:
		fill = fill.darkened(0.25)
	var stroke: Color = Color(0.06, 0.07, 0.08)
	helpers.draw_unit_team_ring(canvas, center, radius, side)
	var texture: Texture2D = helpers.unit_art_texture(String(unit.get("art_id", unit.get("card_id", ""))), helpers.unit_art_view_for_side(side))
	if texture != null:
		helpers.draw_unit_art(canvas, texture, center, radius)
	else:
		helpers.draw_unit_shape(canvas, unit, center, radius, fill, stroke, String(unit["short_name"]), clamp(int(radius * 1.2), 12, 19))

	var hp_ratio: float = clamp(float(unit["hp"]) / float(unit["max_hp"]), 0.0, 1.0)
	var bar_rect: Rect2 = Rect2(center + Vector2(-radius, radius + 6.0), Vector2(radius * 2.0, 4.0))
	canvas.draw_rect(bar_rect, Color(0.04, 0.04, 0.05))
	canvas.draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * hp_ratio, bar_rect.size.y)), Color(0.28, 0.86, 0.42) if side == Config.PLAYER else Color(0.95, 0.36, 0.32))


func _draw_battle_card_bar(canvas: CanvasItem) -> void:
	var margin: float = 12.0
	var bar_top: float = view_size.y - 162.0
	var bar_rect: Rect2 = Rect2(margin, bar_top, view_size.x - margin * 2.0, 148.0)
	helpers.draw_panel(canvas, bar_rect, Color(0.10, 0.12, 0.15), 8.0, Color(0.22, 0.25, 0.29), 1.0)
	helpers.draw_text_line(canvas, "常驻卡组  任务 %d/%d  进化 %d" % [int(simulator.stats.get("player_tasks_completed", 0)), selected_card_ids.size(), int(simulator.stats.get("player_evolutions", 0))], Rect2(bar_rect.position + Vector2(10.0, 8.0), Vector2(bar_rect.size.x - 20.0, 18.0)), 14, Color(0.75, 0.80, 0.86), HORIZONTAL_ALIGNMENT_LEFT)
	_draw_mana_bar(canvas, Rect2(bar_rect.position + Vector2(10.0, 32.0), Vector2(bar_rect.size.x - 20.0, 10.0)))

	var gap: float = 6.0
	var card_width: float = (bar_rect.size.x - 20.0 - gap * 5.0) / 6.0
	var card_height: float = 88.0
	var y: float = bar_rect.position.y + 50.0
	for index in range(selected_card_ids.size()):
		var card_id: String = selected_card_ids[index]
		var base_card: Dictionary = task_system.card_by_id(card_id)
		var card: Dictionary = task_system.active_card_by_id(Config.PLAYER, card_id)
		var rect: Rect2 = Rect2(bar_rect.position.x + 10.0 + index * (card_width + gap), y, card_width, card_height)
		battle_card_rects[card_id] = rect
		_draw_battle_card(canvas, base_card, card, rect, selected_battle_card_id == card_id)


func _draw_mana_bar(canvas: CanvasItem, rect: Rect2) -> void:
	canvas.draw_rect(rect, Color(0.05, 0.06, 0.08))
	canvas.draw_rect(Rect2(rect.position, Vector2(rect.size.x * simulator.player_mana / Config.MANA_MAX, rect.size.y)), Color(0.22, 0.56, 0.92))
	for tick in range(int(Config.MANA_MAX) + 1):
		var x: float = rect.position.x + rect.size.x * float(tick) / Config.MANA_MAX
		canvas.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), Color(0.95, 0.96, 1.0, 0.18), 1.0)


func _draw_battle_card(canvas: CanvasItem, base_card: Dictionary, card: Dictionary, rect: Rect2, selected: bool) -> void:
	var affordable: bool = simulator.player_mana >= float(card["cost"])
	var bg: Color = Color(0.14, 0.17, 0.21) if affordable else Color(0.09, 0.10, 0.12)
	if selected:
		bg = Color(0.18, 0.30, 0.38)
	var flashing: bool = simulator.is_evolution_flashing(Config.PLAYER, String(base_card["id"]))
	var border_color: Color = Color(0.48, 0.78, 0.94) if selected else Color(0.24, 0.27, 0.32)
	var border_width: float = 2.0 if selected else 1.0
	if flashing:
		bg = Color(0.22, 0.34, 0.22)
		border_color = Color(0.47, 0.92, 0.72)
		border_width = 3.0
	helpers.draw_panel(canvas, rect, bg, 7.0, border_color, border_width)
	var icon_center: Vector2 = rect.position + Vector2(rect.size.x * 0.5, 22.0)
	if not helpers.draw_card_art_icon(canvas, card, icon_center, 34.0, Color.WHITE if affordable else Color(0.42, 0.44, 0.46)):
		helpers.draw_unit_shape(canvas, card, icon_center, 12.0, card["color"] if affordable else Color(0.30, 0.32, 0.34), Color(0.04, 0.05, 0.07), String(card["short_name"]), 16)
	helpers.draw_text_line(canvas, card["name"], Rect2(rect.position + Vector2(3.0, 38.0), Vector2(rect.size.x - 6.0, 16.0)), 11, Color(0.92, 0.94, 0.96) if affordable else Color(0.46, 0.49, 0.54), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "%d费" % int(card["cost"]), Rect2(rect.position + Vector2(3.0, 54.0), Vector2(rect.size.x - 6.0, 13.0)), 11, Color(0.70, 0.84, 1.0) if affordable else Color(0.42, 0.46, 0.52), HORIZONTAL_ALIGNMENT_CENTER)

	# 任务进度条：底部显示，已进化变绿。
	var progress_ratio: float = task_system.task_progress_ratio(Config.PLAYER, String(base_card["id"]))
	var bar_x: float = rect.position.x + 4.0
	var bar_y: float = rect.position.y + rect.size.y - 12.0
	var bar_w: float = rect.size.x - 8.0
	var bar_h: float = 6.0
	canvas.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.04, 0.05, 0.06))
	if bool(card.get("evolved", false)):
		canvas.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.28, 0.76, 0.42))
	else:
		canvas.draw_rect(Rect2(bar_x, bar_y, bar_w * progress_ratio, bar_h), Color(0.86, 0.66, 0.30) if affordable else Color(0.40, 0.36, 0.22))
	helpers.draw_text_line(canvas, task_system.task_progress_text(Config.PLAYER, String(base_card["id"])), Rect2(rect.position + Vector2(3.0, 68.0), Vector2(rect.size.x - 6.0, 12.0)), 9, Color(0.90, 0.76, 0.46) if not bool(card.get("evolved", false)) else Color(0.47, 0.92, 0.72), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_event_log(canvas: CanvasItem) -> void:
	var log_rect: Rect2 = Rect2(14.0, board_rect.end.y + 8.0, view_size.x - 28.0, max(0.0, view_size.y - board_rect.end.y - 260.0))
	if log_rect.size.y < 20.0:
		return
	helpers.draw_panel(canvas, log_rect, Color(0.06, 0.07, 0.09, 0.72), 7.0, Color(0.20, 0.23, 0.27), 1.0)
	var line_y: float = log_rect.position.y + 4.0
	for index in range(simulator.event_log.size()):
		helpers.draw_text_line(canvas, simulator.event_log[index], Rect2(log_rect.position.x + 8.0, line_y, log_rect.size.x - 16.0, 16.0), 11, Color(0.72, 0.77, 0.84), HORIZONTAL_ALIGNMENT_LEFT)
		line_y += 16.0


# 选中卡牌详情面板：显示任务条件与进化效果。
func _draw_card_info_panel(canvas: CanvasItem) -> void:
	if selected_battle_card_id == "":
		return

	var card_id: String = selected_battle_card_id
	var base_card: Dictionary = task_system.card_by_id(card_id)
	var card: Dictionary = task_system.active_card_by_id(Config.PLAYER, card_id)
	if base_card.size() == 0 or card.size() == 0:
		return

	var panel_top: float = board_rect.end.y + 8.0
	var panel_height: float = 92.0
	var panel: Rect2 = Rect2(14.0, panel_top, view_size.x - 28.0, panel_height)
	helpers.draw_panel(canvas, panel, Color(0.10, 0.12, 0.15, 0.92), 7.0, Color(0.30, 0.34, 0.40), 1.0)

	# 左：卡牌名、费用、角色
	var left_rect: Rect2 = Rect2(panel.position + Vector2(10.0, 6.0), Vector2(160.0, panel.size.y - 12.0))
	helpers.draw_text_line(canvas, card["name"], Rect2(left_rect.position, Vector2(left_rect.size.x, 20.0)), 15, Color(0.95, 0.96, 0.98), HORIZONTAL_ALIGNMENT_LEFT)
	helpers.draw_text_line(canvas, "%s  ·  %d费  ·  %s" % [card["role"], int(card["cost"]), "已进化" if bool(card.get("evolved", false)) else "未进化"], Rect2(left_rect.position + Vector2(0.0, 22.0), Vector2(left_rect.size.x, 16.0)), 12, Color(0.68, 0.74, 0.80), HORIZONTAL_ALIGNMENT_LEFT)

	# 中：任务描述
	var task: Dictionary = base_card.get("task", {})
	var task_rect: Rect2 = Rect2(panel.position + Vector2(175.0, 6.0), Vector2(panel.size.x - 350.0, panel.size.y * 0.5 - 4.0))
	if task.size() > 0:
		var task_summary: String = String(task.get("summary", ""))
		helpers.draw_text_line(canvas, "任务：%s" % task_summary, task_rect, 12, Color(0.86, 0.72, 0.42), HORIZONTAL_ALIGNMENT_LEFT)
		var state: Dictionary = task_system.task_state(Config.PLAYER, card_id)
		var progress_text: String = task_system.task_progress_text(Config.PLAYER, card_id)
		helpers.draw_text_line(canvas, "进度：%s" % progress_text, Rect2(task_rect.position + Vector2(0.0, 18.0), Vector2(task_rect.size.x, 16.0)), 12, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_LEFT)

	# 右：进化效果
	var evolution: Dictionary = base_card.get("evolution", {})
	var evo_rect: Rect2 = Rect2(panel.position + Vector2(panel.size.x - 175.0, 6.0), Vector2(165.0, panel.size.y - 12.0))
	if evolution.size() > 0:
		var evo_name: String = String(evolution.get("name", ""))
		var evo_summary: String = String(evolution.get("summary", ""))
		helpers.draw_text_line(canvas, "进化 → %s" % evo_name, Rect2(evo_rect.position, Vector2(evo_rect.size.x, 20.0)), 13, Color(0.47, 0.92, 0.72), HORIZONTAL_ALIGNMENT_LEFT)
		helpers.draw_two_line_text(canvas, evo_summary, Rect2(evo_rect.position + Vector2(0.0, 22.0), Vector2(evo_rect.size.x, panel.size.y - 30.0)), 11, Color(0.66, 0.72, 0.78))
	else:
		helpers.draw_text_line(canvas, "无进化", evo_rect, 13, Color(0.45, 0.48, 0.52), HORIZONTAL_ALIGNMENT_LEFT)


# 调试覆盖层：显示快捷键提示与 Bot 卡组信息。
func draw_debug_overlay(canvas: CanvasItem, bot_deck: Array[String], rng_seed: int) -> void:
	var help_lines: Array[String] = [
		"[+/-] 费用增减  [T] 强制完成任务  [R] 重开",
		"[D] Bot随机/固定  [S] 重置种子  [F] 隐藏面板",
		"Bot: %s" % ", ".join(bot_deck),
		"种子: %d" % rng_seed
	]
	var line_h: float = 14.0
	var panel_h: float = help_lines.size() * line_h + 10.0
	var panel: Rect2 = Rect2(12.0, board_rect.position.y + 70.0, 200.0, panel_h)
	helpers.draw_panel(canvas, panel, Color(0.04, 0.05, 0.06, 0.80), 5.0, Color(0.30, 0.34, 0.40), 1.0)
	for index in range(help_lines.size()):
		helpers.draw_text_line(canvas, help_lines[index], Rect2(panel.position + Vector2(8.0, 4.0 + index * line_h), Vector2(panel.size.x - 16.0, line_h)), 10, Color(0.68, 0.74, 0.82), HORIZONTAL_ALIGNMENT_LEFT)


# —— 结算覆盖层 ——
func draw_result_overlay(canvas: CanvasItem) -> void:
	var overlay: Rect2 = Rect2(Vector2.ZERO, view_size)
	canvas.draw_rect(overlay, Color(0.02, 0.025, 0.035, 0.74))
	var panel_width: float = min(view_size.x - 36.0, 440.0)
	var panel_height: float = 360.0
	var panel: Rect2 = Rect2(Vector2((view_size.x - panel_width) * 0.5, (view_size.y - panel_height) * 0.5), Vector2(panel_width, panel_height))
	helpers.draw_panel(canvas, panel, Color(0.11, 0.13, 0.16), 8.0, Color(0.38, 0.46, 0.55), 2.0)
	helpers.draw_text_line(canvas, "%s胜利" % MapMath.side_name(simulator.match_winner), Rect2(panel.position + Vector2(18.0, 16.0), Vector2(panel.size.x - 36.0, 28.0)), 25, Color(0.94, 0.96, 1.0), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "用时 %s；单位阵亡 %d；法术施放 %d" % [_format_time(simulator.battle_time), int(simulator.stats["units_lost"]), int(simulator.stats["spell_casts"])], Rect2(panel.position + Vector2(18.0, 48.0), Vector2(panel.size.x - 36.0, 20.0)), 14, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "清屏次数 我方 %d / Bot %d" % [int(simulator.bases[Config.PLAYER]["clear_count"]), int(simulator.bases[Config.BOT]["clear_count"])], Rect2(panel.position + Vector2(18.0, 72.0), Vector2(panel.size.x - 36.0, 18.0)), 13, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "耗费 我方 %.0f / Bot %.0f" % [float(simulator.stats["player_spent"]), float(simulator.stats["bot_spent"])], Rect2(panel.position + Vector2(18.0, 94.0), Vector2(panel.size.x - 36.0, 18.0)), 13, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "任务 我方 %d / Bot %d；进化 我方 %d / Bot %d" % [int(simulator.stats.get("player_tasks_completed", 0)), int(simulator.stats.get("bot_tasks_completed", 0)), int(simulator.stats.get("player_evolutions", 0)), int(simulator.stats.get("bot_evolutions", 0))], Rect2(panel.position + Vector2(18.0, 116.0), Vector2(panel.size.x - 36.0, 18.0)), 13, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)

	# 卡牌详情列表
	var list_top: float = panel.position.y + 142.0
	var list_height: float = panel.size.y - 206.0
	var card_lines: Array[String] = []
	for card_id in selected_card_ids:
		var base_card: Dictionary = task_system.card_by_id(card_id)
		var state: Dictionary = task_system.task_state(Config.PLAYER, card_id)
		var play_count: int = int(state.get("play_count", 0))
		var evolved: bool = bool(state.get("evolved", false))
		var completed_time: float = float(state.get("completed_at_time", -1.0))
		var line: String = "%s" % String(base_card["name"])
		if play_count > 0:
			line += " · 使用%d次" % play_count
		if evolved:
			line += " · 进化于%s" % _format_time(completed_time)
		elif bool(state.get("completed", false)):
			line += " · 完成于%s(无进化)" % _format_time(completed_time)
		else:
			line += " · 未完成"
		card_lines.append(line)

	var line_y: float = list_top
	for text in card_lines:
		helpers.draw_text_line(canvas, text, Rect2(panel.position + Vector2(18.0, line_y), Vector2(panel.size.x - 36.0, 16.0)), 11, Color(0.78, 0.84, 0.90) if not text.find("进化") >= 0 else Color(0.47, 0.92, 0.72), HORIZONTAL_ALIGNMENT_LEFT)
		line_y += 16.0

	restart_rect = Rect2(panel.position + Vector2(24.0, panel.size.y - 78.0), Vector2((panel.size.x - 58.0) * 0.5, 48.0))
	deck_rect = Rect2(Vector2(restart_rect.end.x + 10.0, restart_rect.position.y), restart_rect.size)
	helpers.draw_panel(canvas, restart_rect, Color(0.24, 0.56, 0.88), 7.0, Color(0.58, 0.78, 0.98), 1.5)
	helpers.draw_text_line(canvas, "再战", restart_rect, 18, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_panel(canvas, deck_rect, Color(0.18, 0.21, 0.25), 7.0, Color(0.36, 0.42, 0.50), 1.5)
	helpers.draw_text_line(canvas, "换卡", deck_rect, 18, Color(0.90, 0.93, 0.96), HORIZONTAL_ALIGNMENT_CENTER)


# 格式化秒为 mm:ss。
func _format_time(seconds: float) -> String:
	var total_seconds: int = int(floor(seconds))
	return "%02d:%02d" % [int(total_seconds / 60), total_seconds % 60]
