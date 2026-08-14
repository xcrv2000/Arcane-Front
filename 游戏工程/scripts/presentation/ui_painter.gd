# UI 绘制与布局层：负责所有屏幕绘制（主界面、图鉴、牌组、战场、结算）与屏幕/逻辑坐标换算。
# 拥有布局矩形缓存（供控制器做点击命中测试），但不处理输入逻辑本身。
# 依赖：CanvasHelpers（低层绘制原语与单位美术）、BattleSimulator/TaskSystem（读取对局状态）。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const MapMath = preload("res://scripts/support/map_math.gd")
const CARD_HOTKEY_LABELS: Array[String] = ["Q", "W", "E", "A", "S", "D"]
const REPOSITORY_PAGE_SIZE: int = 8
const FRIENDLY_ATTACK_COLOR: Color = Color(0.28, 0.78, 1.0)
const ENEMY_ATTACK_COLOR: Color = Color(1.0, 0.32, 0.20)

var helpers: RefCounted = null  # CanvasHelpers
var simulator: RefCounted = null  # BattleSimulator
var task_system: RefCounted = null  # TaskSystem
var cards: Array[Dictionary] = []
var catalog_cards: Array[Dictionary] = []

# 当前视口尺寸与布局缓存（由控制器在绘制/输入前刷新）。
var view_size: Vector2 = Vector2.ZERO
var board_rect: Rect2 = Rect2()
var battle_card_rects: Dictionary = {}
var main_menu_rects: Dictionary = {}
var repository_card_rects: Dictionary = {}
var deck_slot_rects: Dictionary = {}
var back_rect: Rect2 = Rect2()
var save_deck_rect: Rect2 = Rect2()
var page_prev_rect: Rect2 = Rect2()
var page_next_rect: Rect2 = Rect2()
var restart_rect: Rect2 = Rect2()
var deck_rect: Rect2 = Rect2()

# 控制器在选卡/出牌时同步更新这两个字段，供绘制读取。
var selected_card_ids: Array[String] = []
var selected_battle_card_id: String = ""
var info_card_id: String = ""  # 当前显示详情的卡牌 id
var controlled_side: String = Config.PLAYER  # 当前本机玩家在模拟器中的阵营

# V0.4 联机：断线判负时覆盖胜者显示（""=不覆盖，用 simulator.match_winner）
var override_winner: String = ""


# 注入依赖与卡牌数据。
func setup(helpers_ref: RefCounted, sim: RefCounted, task_sys: RefCounted, card_list: Array[Dictionary], catalog_card_list: Array[Dictionary] = []) -> void:
	helpers = helpers_ref
	simulator = sim
	task_system = task_sys
	cards = card_list
	catalog_cards = catalog_card_list if not catalog_card_list.is_empty() else card_list


# 依据视口尺寸计算战场板面矩形；前置界面不使用板面，直接返回。
func update_layout(new_view_size: Vector2, is_frontend: bool) -> void:
	view_size = new_view_size
	if is_frontend:
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


# —— 对局前界面 ——
func draw_main_menu(canvas: CanvasItem, saved_deck_ids: Array[String], status_text: String = "") -> void:
	main_menu_rects.clear()
	var margin: float = max(20.0, view_size.x * 0.055)
	helpers.draw_text_line(canvas, "奥术前线", Rect2(margin, 38.0, view_size.x - margin * 2.0, 46.0), 34, Color(0.95, 0.96, 0.98), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "选择行动", Rect2(margin, 86.0, view_size.x - margin * 2.0, 24.0), 15, Color(0.58, 0.66, 0.75), HORIZONTAL_ALIGNMENT_CENTER)

	var gap: float = 14.0
	var button_top: float = 140.0
	var button_width: float = (view_size.x - margin * 2.0 - gap) * 0.5
	var button_height: float = 112.0
	var entries: Array[Dictionary] = [
		{"id": "single", "title": "单机", "hint": "使用当前牌组对战 Bot", "accent": Color(0.32, 0.67, 0.94)},
		{"id": "online", "title": "联机", "hint": "创建或加入房间", "accent": Color(0.35, 0.78, 0.57)},
		{"id": "compendium", "title": "图鉴", "hint": "查看单位与进化说明", "accent": Color(0.83, 0.62, 0.31)},
		{"id": "deck", "title": "牌组", "hint": "编辑并保存出战配置", "accent": Color(0.68, 0.54, 0.92)}
	]
	for index in range(entries.size()):
		var entry: Dictionary = entries[index]
		var col: int = index % 2
		var row: int = int(index / 2)
		var rect: Rect2 = Rect2(Vector2(margin + col * (button_width + gap), button_top + row * (button_height + gap)), Vector2(button_width, button_height))
		main_menu_rects[String(entry["id"])] = rect
		_draw_menu_button(canvas, rect, String(entry["title"]), String(entry["hint"]), entry["accent"])

	var deck_top: float = max(button_top + button_height * 2.0 + gap + 54.0, view_size.y * 0.46)
	helpers.draw_text_line(canvas, "当前牌组  %d/%d" % [saved_deck_ids.size(), Config.CARD_PICK_COUNT], Rect2(margin, deck_top - 38.0, view_size.x - margin * 2.0, 28.0), 19, Color(0.86, 0.90, 0.95), HORIZONTAL_ALIGNMENT_LEFT)
	_draw_deck_preview(canvas, saved_deck_ids, Rect2(margin, deck_top, view_size.x - margin * 2.0, min(360.0, view_size.y - deck_top - 62.0)))
	var footer: String = status_text if status_text != "" else "单机与联机共用已保存的当前牌组"
	helpers.draw_text_line(canvas, footer, Rect2(margin, view_size.y - 42.0, view_size.x - margin * 2.0, 20.0), 13, Color(0.60, 0.68, 0.76), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_menu_button(canvas: CanvasItem, rect: Rect2, title: String, hint: String, accent: Color) -> void:
	helpers.draw_panel(canvas, rect, Color(0.105, 0.125, 0.16), 8.0, accent.darkened(0.18), 2.0)
	helpers.draw_text_line(canvas, title, Rect2(rect.position + Vector2(16.0, 19.0), Vector2(rect.size.x - 32.0, 34.0)), 25, Color(0.95, 0.96, 0.98), HORIZONTAL_ALIGNMENT_LEFT)
	helpers.draw_text_line(canvas, hint, Rect2(rect.position + Vector2(16.0, 63.0), Vector2(rect.size.x - 32.0, 22.0)), 13, Color(0.65, 0.71, 0.78), HORIZONTAL_ALIGNMENT_LEFT)
	canvas.draw_rect(Rect2(rect.position + Vector2(16.0, rect.size.y - 12.0), Vector2(42.0, 3.0)), accent)


func _draw_deck_preview(canvas: CanvasItem, deck_ids: Array[String], area: Rect2) -> void:
	var cols: int = 3 if area.size.x >= 520.0 else 2
	var gap: float = 10.0
	var rows: int = int(ceil(float(Config.CARD_PICK_COUNT) / float(cols)))
	var slot_width: float = (area.size.x - gap * float(cols - 1)) / float(cols)
	var slot_height: float = min(160.0, (area.size.y - gap * float(rows - 1)) / float(rows))
	for index in range(Config.CARD_PICK_COUNT):
		var col: int = index % cols
		var row: int = int(index / cols)
		var rect: Rect2 = Rect2(area.position + Vector2(col * (slot_width + gap), row * (slot_height + gap)), Vector2(slot_width, slot_height))
		if index < deck_ids.size():
			_draw_deck_slot(canvas, _card_by_id(deck_ids[index]), rect, index)
		else:
			helpers.draw_panel(canvas, rect, Color(0.09, 0.10, 0.12), 6.0, Color(0.24, 0.27, 0.32), 1.0)
			helpers.draw_text_line(canvas, "空位 %d" % (index + 1), rect, 14, Color(0.42, 0.46, 0.52), HORIZONTAL_ALIGNMENT_CENTER)


func draw_compendium(canvas: CanvasItem, focused_card_id: String, page: int) -> void:
	repository_card_rects.clear()
	_draw_frontend_header(canvas, "图鉴", "选择下方单位，查看完整说明")
	var margin: float = max(18.0, view_size.x * 0.04)
	var detail_rect: Rect2 = Rect2(margin, 96.0, view_size.x - margin * 2.0, 360.0)
	_draw_catalog_detail(canvas, _card_by_id(focused_card_id), detail_rect)
	helpers.draw_text_line(canvas, "单位仓库", Rect2(margin, 478.0, view_size.x - margin * 2.0, 28.0), 19, Color(0.86, 0.90, 0.95), HORIZONTAL_ALIGNMENT_LEFT)
	_draw_pagination(canvas, page, _page_count(catalog_cards), 474.0, margin)
	_draw_repository(canvas, Rect2(margin, 516.0, view_size.x - margin * 2.0, view_size.y - 538.0), focused_card_id, [], catalog_cards, page)


func draw_deck_builder(canvas: CanvasItem, draft_ids: Array[String], status_text: String, page: int) -> void:
	repository_card_rects.clear()
	deck_slot_rects.clear()
	_draw_frontend_header(canvas, "牌组", "选择 6 张卡，保存后供单机与联机使用")
	var margin: float = max(18.0, view_size.x * 0.04)
	save_deck_rect = Rect2(view_size.x - margin - 140.0, 22.0, 140.0, 44.0)
	var save_enabled: bool = draft_ids.size() == Config.CARD_PICK_COUNT
	helpers.draw_panel(canvas, save_deck_rect, Color(0.18, 0.42, 0.62) if save_enabled else Color(0.13, 0.15, 0.18), 6.0, Color(0.48, 0.78, 0.96) if save_enabled else Color(0.26, 0.29, 0.33), 1.5)
	helpers.draw_text_line(canvas, "保存牌组" if save_enabled else "%d/%d" % [draft_ids.size(), Config.CARD_PICK_COUNT], save_deck_rect, 16, Color(0.96, 0.97, 0.98) if save_enabled else Color(0.48, 0.52, 0.58), HORIZONTAL_ALIGNMENT_CENTER)

	helpers.draw_text_line(canvas, "当前编辑", Rect2(margin, 92.0, view_size.x - margin * 2.0, 26.0), 18, Color(0.86, 0.90, 0.95), HORIZONTAL_ALIGNMENT_LEFT)
	var deck_area: Rect2 = Rect2(margin, 126.0, view_size.x - margin * 2.0, 220.0)
	_draw_editable_deck(canvas, draft_ids, deck_area)
	var message: String = status_text if status_text != "" else "点击已选卡可移出牌组；未保存的改动不会用于对局。"
	helpers.draw_text_line(canvas, message, Rect2(margin, 360.0, view_size.x - margin * 2.0, 22.0), 13, Color(0.72, 0.76, 0.82), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "单位仓库", Rect2(margin, 402.0, view_size.x - margin * 2.0, 28.0), 19, Color(0.86, 0.90, 0.95), HORIZONTAL_ALIGNMENT_LEFT)
	_draw_pagination(canvas, page, _page_count(cards), 398.0, margin)
	_draw_repository(canvas, Rect2(margin, 440.0, view_size.x - margin * 2.0, view_size.y - 462.0), "", draft_ids, cards, page)


func _draw_frontend_header(canvas: CanvasItem, title: String, subtitle: String) -> void:
	var margin: float = max(18.0, view_size.x * 0.04)
	back_rect = Rect2(margin, 22.0, 112.0, 44.0)
	helpers.draw_panel(canvas, back_rect, Color(0.12, 0.14, 0.17), 6.0, Color(0.30, 0.34, 0.40), 1.0)
	helpers.draw_text_line(canvas, "返回", back_rect, 15, Color(0.86, 0.89, 0.93), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, title, Rect2(margin + 128.0, 18.0, view_size.x - margin * 2.0 - 256.0, 30.0), 25, Color(0.95, 0.96, 0.98), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, subtitle, Rect2(margin + 128.0, 50.0, view_size.x - margin * 2.0 - 256.0, 20.0), 12, Color(0.58, 0.66, 0.75), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_editable_deck(canvas: CanvasItem, deck_ids: Array[String], area: Rect2) -> void:
	var cols: int = 3
	var gap: float = 9.0
	var slot_width: float = (area.size.x - gap * 2.0) / 3.0
	var slot_height: float = (area.size.y - gap) * 0.5
	for index in range(Config.CARD_PICK_COUNT):
		var col: int = index % cols
		var row: int = int(index / cols)
		var rect: Rect2 = Rect2(area.position + Vector2(col * (slot_width + gap), row * (slot_height + gap)), Vector2(slot_width, slot_height))
		if index < deck_ids.size():
			var card_id: String = deck_ids[index]
			deck_slot_rects[card_id] = rect
			_draw_deck_slot(canvas, _card_by_id(card_id), rect, index)
		else:
			helpers.draw_panel(canvas, rect, Color(0.085, 0.095, 0.115), 6.0, Color(0.24, 0.27, 0.32), 1.0)
			helpers.draw_text_line(canvas, "空位 %d" % (index + 1), rect, 13, Color(0.40, 0.44, 0.50), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_deck_slot(canvas: CanvasItem, card: Dictionary, rect: Rect2, index: int) -> void:
	if card.is_empty():
		return
	helpers.draw_panel(canvas, rect, Color(0.13, 0.18, 0.23), 6.0, Color(0.34, 0.60, 0.82), 1.5)
	var icon_center: Vector2 = rect.position + Vector2(35.0, rect.size.y * 0.5)
	if not helpers.draw_card_art_icon(canvas, card, icon_center, min(58.0, rect.size.y - 18.0), Color.WHITE):
		helpers.draw_unit_shape(canvas, card, icon_center, 15.0, card["color"], Color(0.04, 0.05, 0.07), String(card["short_name"]), 16)
	helpers.draw_text_line(canvas, "%d  %s" % [index + 1, String(card["name"])], Rect2(rect.position + Vector2(64.0, 20.0), Vector2(rect.size.x - 72.0, 22.0)), 15, Color(0.94, 0.96, 0.98), HORIZONTAL_ALIGNMENT_LEFT)
	helpers.draw_text_line(canvas, "%d费 · %s" % [int(card["cost"]), String(card["role"])], Rect2(rect.position + Vector2(64.0, 50.0), Vector2(rect.size.x - 72.0, 18.0)), 12, Color(0.64, 0.72, 0.80), HORIZONTAL_ALIGNMENT_LEFT)


func _page_count(source_cards: Array[Dictionary]) -> int:
	return max(1, int(ceil(float(source_cards.size()) / float(REPOSITORY_PAGE_SIZE))))


func _draw_pagination(canvas: CanvasItem, page: int, page_count: int, y: float, margin: float) -> void:
	var button_size: Vector2 = Vector2(78.0, 32.0)
	page_next_rect = Rect2(view_size.x - margin - button_size.x, y, button_size.x, button_size.y)
	page_prev_rect = Rect2(page_next_rect.position.x - button_size.x - 88.0, y, button_size.x, button_size.y)
	var prev_enabled: bool = page > 0
	var next_enabled: bool = page + 1 < page_count
	helpers.draw_panel(canvas, page_prev_rect, Color(0.14, 0.18, 0.22) if prev_enabled else Color(0.09, 0.10, 0.12), 5.0, Color(0.34, 0.48, 0.60) if prev_enabled else Color(0.20, 0.22, 0.25), 1.0)
	helpers.draw_text_line(canvas, "上一页", page_prev_rect, 13, Color(0.86, 0.90, 0.94) if prev_enabled else Color(0.36, 0.39, 0.43), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "%d/%d" % [page + 1, page_count], Rect2(page_prev_rect.end.x, y, 88.0, button_size.y), 13, Color(0.66, 0.72, 0.79), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_panel(canvas, page_next_rect, Color(0.14, 0.18, 0.22) if next_enabled else Color(0.09, 0.10, 0.12), 5.0, Color(0.34, 0.48, 0.60) if next_enabled else Color(0.20, 0.22, 0.25), 1.0)
	helpers.draw_text_line(canvas, "下一页", page_next_rect, 13, Color(0.86, 0.90, 0.94) if next_enabled else Color(0.36, 0.39, 0.43), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_repository(canvas: CanvasItem, area: Rect2, focused_id: String, selected_ids: Array[String], source_cards: Array[Dictionary], page: int) -> void:
	var cols: int = 2
	var gap: float = 9.0
	var start_index: int = clamp(page, 0, _page_count(source_cards) - 1) * REPOSITORY_PAGE_SIZE
	var end_index: int = min(start_index + REPOSITORY_PAGE_SIZE, source_cards.size())
	var visible_count: int = end_index - start_index
	var rows: int = max(1, int(ceil(float(visible_count) / float(cols))))
	var card_width: float = (area.size.x - gap * float(cols - 1)) / float(cols)
	var card_height: float = min(184.0, (area.size.y - gap * float(rows - 1)) / float(rows))
	for source_index in range(start_index, end_index):
		var index: int = source_index - start_index
		var col: int = index % cols
		var row: int = int(index / cols)
		var rect: Rect2 = Rect2(area.position + Vector2(col * (card_width + gap), row * (card_height + gap)), Vector2(card_width, card_height))
		var card: Dictionary = source_cards[source_index]
		var card_id: String = String(card["id"])
		repository_card_rects[card_id] = rect
		_draw_repository_card(canvas, card, rect, card_id == focused_id, selected_ids.has(card_id))


func _draw_repository_card(canvas: CanvasItem, card: Dictionary, rect: Rect2, focused: bool, selected: bool) -> void:
	var active: bool = focused or selected
	var fill: Color = Color(0.14, 0.20, 0.25) if active else Color(0.11, 0.13, 0.16)
	var stroke: Color = Color(0.40, 0.70, 0.92) if active else Color(0.24, 0.27, 0.32)
	helpers.draw_panel(canvas, rect, fill, 6.0, stroke, 2.0 if active else 1.0)
	var icon_center: Vector2 = rect.position + Vector2(rect.size.x * 0.5, 46.0)
	if not helpers.draw_card_art_icon(canvas, card, icon_center, 68.0, Color.WHITE):
		helpers.draw_unit_shape(canvas, card, icon_center, 19.0, card["color"], Color(0.04, 0.05, 0.07), String(card["short_name"]), 18)
	helpers.draw_text_line(canvas, String(card["name"]), Rect2(rect.position + Vector2(6.0, 84.0), Vector2(rect.size.x - 12.0, 22.0)), 15, Color(0.94, 0.96, 0.98), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "%d费 · %s" % [int(card["cost"]), String(card["role"])], Rect2(rect.position + Vector2(6.0, 108.0), Vector2(rect.size.x - 12.0, 18.0)), 11, Color(0.63, 0.70, 0.78), HORIZONTAL_ALIGNMENT_CENTER)
	var evolution: Dictionary = card.get("evolution", {})
	var footer: String = "衍生单位 · 不可携带" if not bool(card.get("deckable", true)) else "→ %s" % String(evolution.get("name", "未设置"))
	helpers.draw_text_line(canvas, footer, Rect2(rect.position + Vector2(6.0, rect.size.y - 30.0), Vector2(rect.size.x - 12.0, 18.0)), 11, Color(0.64, 0.76, 0.84) if not bool(card.get("deckable", true)) else Color(0.84, 0.70, 0.40), HORIZONTAL_ALIGNMENT_CENTER)
	if selected:
		canvas.draw_circle(rect.position + Vector2(rect.size.x - 17.0, 17.0), 9.0, Color(0.35, 0.78, 0.95))
		helpers.draw_text_line(canvas, "✓", Rect2(rect.position + Vector2(rect.size.x - 26.0, 7.0), Vector2(18.0, 18.0)), 14, Color(0.04, 0.06, 0.08), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_catalog_detail(canvas: CanvasItem, card: Dictionary, rect: Rect2) -> void:
	helpers.draw_panel(canvas, rect, Color(0.10, 0.12, 0.15), 8.0, Color(0.28, 0.33, 0.39), 1.0)
	if card.is_empty():
		helpers.draw_text_line(canvas, "选择一个单位查看说明", rect, 16, Color(0.58, 0.64, 0.72), HORIZONTAL_ALIGNMENT_CENTER)
		return
	var art_rect: Rect2 = Rect2(rect.position + Vector2(18.0, 18.0), Vector2(150.0, 150.0))
	helpers.draw_panel(canvas, art_rect, Color(0.07, 0.085, 0.11), 6.0, Color(0.22, 0.27, 0.34), 1.0)
	if not helpers.draw_card_art_icon(canvas, card, art_rect.get_center(), 126.0, Color.WHITE):
		helpers.draw_unit_shape(canvas, card, art_rect.get_center(), 34.0, card["color"], Color(0.04, 0.05, 0.07), String(card["short_name"]), 28)
	var text_x: float = art_rect.end.x + 22.0
	var text_width: float = rect.end.x - text_x - 18.0
	helpers.draw_text_line(canvas, String(card["name"]), Rect2(text_x, rect.position.y + 20.0, text_width, 34.0), 27, Color(0.95, 0.96, 0.98), HORIZONTAL_ALIGNMENT_LEFT)
	helpers.draw_text_line(canvas, "%d费 · %s · %s" % [int(card["cost"]), String(card["role"]), "单位" if String(card["kind"]) == "unit" else "法术"], Rect2(text_x, rect.position.y + 60.0, text_width, 22.0), 14, Color(0.67, 0.75, 0.84), HORIZONTAL_ALIGNMENT_LEFT)
	helpers.draw_two_line_text(canvas, _card_stats_text(card), Rect2(text_x, rect.position.y + 92.0, text_width, 48.0), 13, Color(0.80, 0.84, 0.88))
	helpers.draw_two_line_text(canvas, String(card.get("trial_note", "")), Rect2(text_x, rect.position.y + 142.0, text_width, 44.0), 12, Color(0.60, 0.67, 0.74))

	var task: Dictionary = card.get("task", {})
	var evolution: Dictionary = card.get("evolution", {})
	if not bool(card.get("deckable", true)):
		helpers.draw_text_line(canvas, "携带", Rect2(rect.position + Vector2(18.0, 190.0), Vector2(74.0, 22.0)), 15, Color(0.86, 0.70, 0.36), HORIZONTAL_ALIGNMENT_LEFT)
		helpers.draw_two_line_text(canvas, "衍生单位，不可编入牌组；由其他百骸公国卡牌召唤。", Rect2(rect.position + Vector2(92.0, 188.0), Vector2(rect.size.x - 110.0, 50.0)), 13, Color(0.78, 0.81, 0.85))
		helpers.draw_text_line(canvas, "进化", Rect2(rect.position + Vector2(18.0, 254.0), Vector2(74.0, 22.0)), 15, Color(0.44, 0.88, 0.66), HORIZONTAL_ALIGNMENT_LEFT)
		helpers.draw_text_line(canvas, "无（衍生单位）", Rect2(rect.position + Vector2(92.0, 252.0), Vector2(rect.size.x - 110.0, 22.0)), 15, Color(0.82, 0.90, 0.86), HORIZONTAL_ALIGNMENT_LEFT)
	else:
		helpers.draw_text_line(canvas, "任务", Rect2(rect.position + Vector2(18.0, 190.0), Vector2(74.0, 22.0)), 15, Color(0.86, 0.70, 0.36), HORIZONTAL_ALIGNMENT_LEFT)
		helpers.draw_two_line_text(canvas, String(task.get("summary", "未设置")), Rect2(rect.position + Vector2(92.0, 188.0), Vector2(rect.size.x - 110.0, 50.0)), 13, Color(0.78, 0.81, 0.85))
		helpers.draw_text_line(canvas, "进化", Rect2(rect.position + Vector2(18.0, 254.0), Vector2(74.0, 22.0)), 15, Color(0.44, 0.88, 0.66), HORIZONTAL_ALIGNMENT_LEFT)
		helpers.draw_text_line(canvas, String(evolution.get("name", "未设置")), Rect2(rect.position + Vector2(92.0, 252.0), Vector2(rect.size.x - 110.0, 22.0)), 15, Color(0.82, 0.90, 0.86), HORIZONTAL_ALIGNMENT_LEFT)
		helpers.draw_two_line_text(canvas, String(evolution.get("summary", "")), Rect2(rect.position + Vector2(92.0, 278.0), Vector2(rect.size.x - 110.0, 54.0)), 13, Color(0.67, 0.74, 0.78))


func _card_stats_text(card: Dictionary) -> String:
	if String(card.get("kind", "")) == "spell":
		return "伤害 %.0f · 基地伤害 %.0f · 范围 %.1f · 模式 %s" % [float(card.get("damage", 0.0)), float(card.get("base_damage", 0.0)), float(card.get("radius", 0.0)), String(card.get("spell_mode", ""))]
	return "数量 %d · 生命 %.0f · 攻击 %.0f · 间隔 %.2fs · 射程 %.1f · 移速 %.1f" % [int(card.get("count", 1)), float(card.get("hp", 0.0)), float(card.get("damage", 0.0)), float(card.get("attack_cooldown", 0.0)), float(card.get("range", 0.0)), float(card.get("speed", 0.0))]


func _card_by_id(card_id: String) -> Dictionary:
	for card in catalog_cards:
		if String(card.get("id", "")) == card_id:
			return card
	return {}


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
	var left: String = "我方基地 %d/300  费 %.1f/10" % [int(ceil(float(player_base["hp"]))), simulator.player_mana()]
	var right: String = "Bot基地 %d/300  费 %.1f/10" % [int(ceil(float(bot_base["hp"]))), simulator.bot_mana()]
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

	for unit in simulator.units:
		_draw_unit_death_trigger_range(canvas, unit)
	_draw_base(canvas, Config.BOT)
	_draw_base(canvas, Config.PLAYER)
	_draw_clock(canvas)
	for effect in simulator.persistent_effects:
		if String(effect.get("mode", "")) == "spell_projectile":
			_draw_spell_projectile(canvas, effect)
	for effect in simulator.spell_effects:
		if String(effect.get("mode", "")) != "attack":
			_draw_spell_effect(canvas, effect)
	for unit in simulator.units:
		_draw_unit(canvas, unit)
	for effect in simulator.spell_effects:
		if String(effect.get("mode", "")) == "attack":
			_draw_spell_effect(canvas, effect)


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
	helpers.draw_text_line(canvas, _format_time(simulator.battle_time()), clock_rect, 19, Color(0.90, 0.96, 1.0), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_spell_effect(canvas: CanvasItem, effect: Dictionary) -> void:
	var alpha: float = clamp(float(effect["time"]) / float(effect["max_time"]), 0.0, 1.0)
	var color: Color = effect["color"]
	var F = preload("res://scripts/config/game_config.gd").FP_SCALE_F
	var fp_from: Dictionary = effect.get("from_fp", {})
	var fp_pos: Dictionary = effect.get("pos_fp", {})
	var radius_fp: int = int(effect.get("radius_fp", int(float(effect.get("radius", 0.0)) * F + 0.5)))
	var radius_logic: float = float(radius_fp) / F
	var pos_logic: Vector2 = Vector2(
		float(fp_pos.get("x", int(float(effect.get("pos", Vector2.ZERO).x) * F + 0.5))) / F,
		float(fp_pos.get("y", int(float(effect.get("pos", Vector2.ZERO).y) * F + 0.5))) / F
	)

	if String(effect.get("mode", "circle")) == "attack":
		var attacker_side: String = String(effect.get("side", ""))
		if attacker_side != "":
			color = FRIENDLY_ATTACK_COLOR if attacker_side == controlled_side else ENEMY_ATTACK_COLOR
		var from_logic: Vector2 = Vector2(
			float(fp_from.get("x", 0)) / F,
			float(fp_from.get("y", 0)) / F
		)
		var start: Vector2 = map_to_screen(from_logic)
		var end: Vector2 = map_to_screen(pos_logic)
		var trace_color: Color = color.lightened(0.45)
		trace_color.a = 0.18 * alpha
		canvas.draw_line(start, end, trace_color, 5.0, true)
		trace_color.a = 0.92 * alpha
		canvas.draw_line(start, end, trace_color, 2.0, true)
		var flash_radius: float = 4.0 + (1.0 - alpha) * 9.0
		var flash_color: Color = color.lightened(0.65)
		flash_color.a = 0.28 * alpha
		canvas.draw_circle(end, flash_radius, flash_color)
		flash_color.a = 0.92 * alpha
		canvas.draw_circle(end, flash_radius, flash_color, false, 2.0)
		if radius_fp > 0:
			var area_radius: float = logic_to_pixels(radius_logic)
			var area_color: Color = color.lightened(0.50)
			area_color.a = 0.10 * alpha
			canvas.draw_circle(end, area_radius, area_color)
			area_color.a = 0.55 * alpha
			canvas.draw_circle(end, area_radius, area_color, false, 1.5)
		return

	if String(effect.get("mode", "circle")) == "line":
		var from_logic: Vector2 = Vector2(
			float(fp_from.get("x", int(float(effect.get("from", Vector2.ZERO).x) * F + 0.5))) / F,
			float(fp_from.get("y", int(float(effect.get("from", Vector2.ZERO).y) * F + 0.5))) / F
		)
		var start: Vector2 = map_to_screen(from_logic)
		var end: Vector2 = map_to_screen(pos_logic)
		var width: float = max(2.0, logic_to_pixels(radius_logic * 2.0))
		color.a = 0.16 * alpha
		canvas.draw_line(start, end, color, width, true)
		color.a = 0.82 * alpha
		canvas.draw_line(start, end, color, max(2.0, width * 0.18), true)
		canvas.draw_circle(end, max(5.0, width * 0.16), color)
		helpers.draw_text_line(canvas, effect["label"], Rect2(end - Vector2(24.0, 12.0), Vector2(48.0, 24.0)), 16, Color(1.0, 0.96, 0.78, alpha), HORIZONTAL_ALIGNMENT_CENTER)
		return
	color.a = 0.22 * alpha
	var center: Vector2 = map_to_screen(pos_logic)
	var radius: float = logic_to_pixels(radius_logic)
	canvas.draw_circle(center, radius, color)
	color.a = 0.75 * alpha
	canvas.draw_circle(center, radius, color, false, 2.0)
	helpers.draw_text_line(canvas, effect["label"], Rect2(center - Vector2(24.0, 12.0), Vector2(48.0, 24.0)), 16, Color(1.0, 0.96, 0.78, alpha), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_spell_projectile(canvas: CanvasItem, effect: Dictionary) -> void:
	var F: float = preload("res://scripts/config/game_config.gd").FP_SCALE_F
	var from_fp: Dictionary = effect.get("from_fp", {})
	var target_fp: Dictionary = effect.get("pos_fp", {})
	var start: Vector2 = map_to_screen(Vector2(float(int(from_fp.get("x", 0))) / F, float(int(from_fp.get("y", 0))) / F))
	var target: Vector2 = map_to_screen(Vector2(float(int(target_fp.get("x", 0))) / F, float(int(target_fp.get("y", 0))) / F))
	var duration_ticks: int = max(1, int(effect.get("duration_ticks", 1)))
	var remaining_ticks: int = clamp(int(effect.get("remaining_ticks", duration_ticks)), 0, duration_ticks)
	var progress: float = 1.0 - float(remaining_ticks) / float(duration_ticks)
	var head: Vector2 = start.lerp(target, progress)
	var tail: Vector2 = start.lerp(target, max(0.0, progress - 0.16))
	var color: Color = effect.get("color", Color.WHITE)
	var trail_color: Color = color
	trail_color.a = 0.38
	canvas.draw_line(start, head, trail_color, 2.0, true)
	trail_color.a = 0.85
	canvas.draw_line(tail, head, trail_color, 4.0, true)
	var glow_color: Color = color
	glow_color.a = 0.24
	canvas.draw_circle(head, 10.0, glow_color)
	canvas.draw_circle(head, 5.0, color)
	canvas.draw_circle(head, 5.0, Color(1.0, 0.97, 0.82), false, 1.5)
	helpers.draw_text_line(canvas, String(effect.get("label", "")), Rect2(head - Vector2(18.0, 22.0), Vector2(36.0, 16.0)), 12, Color(1.0, 0.97, 0.86), HORIZONTAL_ALIGNMENT_CENTER)


func _draw_unit_death_trigger_range(canvas: CanvasItem, unit: Dictionary) -> void:
	var death_buff: Dictionary = unit.get("squire_death_buff", {})
	var radius_logic: float = float(death_buff.get("radius", 0.0))
	if radius_logic <= 0.0:
		return
	var F: float = preload("res://scripts/config/game_config.gd").FP_SCALE_F
	var pos_fp: Dictionary = unit.get("pos_fp", {"x": 0, "y": 0})
	var center: Vector2 = map_to_screen(Vector2(float(int(pos_fp.get("x", 0))) / F, float(int(pos_fp.get("y", 0))) / F))
	var radius: float = logic_to_pixels(radius_logic)
	var range_color: Color = unit.get("color", Color.WHITE)
	range_color = range_color.lightened(0.45)
	range_color.a = 0.055
	canvas.draw_circle(center, radius, range_color)
	range_color.a = 0.30
	canvas.draw_circle(center, radius, range_color, false, 1.25)


func _draw_unit(canvas: CanvasItem, unit: Dictionary) -> void:
	var F: float = preload("res://scripts/config/game_config.gd").FP_SCALE_F
	var pos_fp: Dictionary = unit.get("pos_fp", {"x": 0, "y": 0})
	var pos_logic: Vector2 = Vector2(float(int(pos_fp.get("x", 0))) / F, float(int(pos_fp.get("y", 0))) / F)
	var radius_fp: int = int(unit.get("radius_fp", int(float(unit.get("radius", 0.0)) * F + 0.5)))
	var radius_logic: float = float(radius_fp) / F
	var center: Vector2 = map_to_screen(pos_logic)
	var radius: float = logic_to_pixels(radius_logic)
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
	var task_stat_key: String = "player_tasks_completed" if controlled_side == Config.PLAYER else "bot_tasks_completed"
	var evolution_stat_key: String = "player_evolutions" if controlled_side == Config.PLAYER else "bot_evolutions"
	helpers.draw_text_line(canvas, "常驻卡组  任务 %d/%d  进化 %d" % [int(simulator.stats.get(task_stat_key, 0)), selected_card_ids.size(), int(simulator.stats.get(evolution_stat_key, 0))], Rect2(bar_rect.position + Vector2(10.0, 8.0), Vector2(bar_rect.size.x - 20.0, 18.0)), 14, Color(0.75, 0.80, 0.86), HORIZONTAL_ALIGNMENT_LEFT)
	_draw_mana_bar(canvas, Rect2(bar_rect.position + Vector2(10.0, 32.0), Vector2(bar_rect.size.x - 20.0, 10.0)))

	var gap: float = 6.0
	var card_width: float = (bar_rect.size.x - 20.0 - gap * 5.0) / 6.0
	var card_height: float = 88.0
	var y: float = bar_rect.position.y + 50.0
	for index in range(selected_card_ids.size()):
		var card_id: String = selected_card_ids[index]
		var base_card: Dictionary = task_system.card_by_id(card_id)
		var card: Dictionary = task_system.active_card_by_id(controlled_side, card_id)
		var rect: Rect2 = Rect2(bar_rect.position.x + 10.0 + index * (card_width + gap), y, card_width, card_height)
		battle_card_rects[card_id] = rect
		_draw_battle_card(canvas, base_card, card, rect, selected_battle_card_id == card_id, index)


func _draw_mana_bar(canvas: CanvasItem, rect: Rect2) -> void:
	var mana: float = simulator.player_mana() if controlled_side == Config.PLAYER else simulator.bot_mana()
	canvas.draw_rect(rect, Color(0.05, 0.06, 0.08))
	canvas.draw_rect(Rect2(rect.position, Vector2(rect.size.x * mana / Config.MANA_MAX, rect.size.y)), Color(0.22, 0.56, 0.92))
	for tick in range(int(Config.MANA_MAX) + 1):
		var x: float = rect.position.x + rect.size.x * float(tick) / Config.MANA_MAX
		canvas.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), Color(0.95, 0.96, 1.0, 0.18), 1.0)


func _draw_battle_card(canvas: CanvasItem, base_card: Dictionary, card: Dictionary, rect: Rect2, selected: bool, hotkey_index: int) -> void:
	var mana: float = simulator.player_mana() if controlled_side == Config.PLAYER else simulator.bot_mana()
	var affordable: bool = mana >= float(card["cost"])
	var cooldown_seconds: float = simulator.card_cooldown_seconds(controlled_side, String(base_card["id"]))
	var cooling_down: bool = cooldown_seconds > 0.0
	var usable: bool = affordable and not cooling_down
	var bg: Color = Color(0.14, 0.17, 0.21) if usable else Color(0.09, 0.10, 0.12)
	if selected:
		bg = Color(0.18, 0.30, 0.38) if usable else Color(0.11, 0.16, 0.20)
	var flashing: bool = simulator.is_evolution_flashing(controlled_side, String(base_card["id"]))
	var border_color: Color = Color(0.48, 0.78, 0.94) if selected else Color(0.24, 0.27, 0.32)
	var border_width: float = 2.0 if selected else 1.0
	if flashing:
		bg = Color(0.22, 0.34, 0.22)
		border_color = Color(0.47, 0.92, 0.72)
		border_width = 3.0
	helpers.draw_panel(canvas, rect, bg, 7.0, border_color, border_width)
	if hotkey_index >= 0 and hotkey_index < CARD_HOTKEY_LABELS.size():
		var key_rect: Rect2 = Rect2(rect.position + Vector2(4.0, 4.0), Vector2(20.0, 17.0))
		helpers.draw_panel(canvas, key_rect, Color(0.05, 0.07, 0.09, 0.92), 3.0, Color(0.42, 0.50, 0.60), 1.0)
		helpers.draw_text_line(canvas, CARD_HOTKEY_LABELS[hotkey_index], key_rect, 10, Color(0.88, 0.92, 0.96), HORIZONTAL_ALIGNMENT_CENTER)
	var icon_center: Vector2 = rect.position + Vector2(rect.size.x * 0.5, 22.0)
	if not helpers.draw_card_art_icon(canvas, card, icon_center, 34.0, Color.WHITE if usable else Color(0.42, 0.44, 0.46)):
		helpers.draw_unit_shape(canvas, card, icon_center, 12.0, card["color"] if usable else Color(0.30, 0.32, 0.34), Color(0.04, 0.05, 0.07), String(card["short_name"]), 16)
	helpers.draw_text_line(canvas, card["name"], Rect2(rect.position + Vector2(3.0, 38.0), Vector2(rect.size.x - 6.0, 16.0)), 11, Color(0.92, 0.94, 0.96) if usable else Color(0.46, 0.49, 0.54), HORIZONTAL_ALIGNMENT_CENTER)
	var cost_or_cooldown: String = "冷却 %.1fs" % max(0.1, cooldown_seconds) if cooling_down else "%d费" % int(card["cost"])
	helpers.draw_text_line(canvas, cost_or_cooldown, Rect2(rect.position + Vector2(3.0, 54.0), Vector2(rect.size.x - 6.0, 13.0)), 11, Color(0.94, 0.58, 0.42) if cooling_down else (Color(0.70, 0.84, 1.0) if affordable else Color(0.42, 0.46, 0.52)), HORIZONTAL_ALIGNMENT_CENTER)

	# 任务进度条：底部显示，已进化变绿。
	var progress_ratio: float = task_system.task_progress_ratio(controlled_side, String(base_card["id"]))
	var bar_x: float = rect.position.x + 4.0
	var bar_y: float = rect.position.y + rect.size.y - 12.0
	var bar_w: float = rect.size.x - 8.0
	var bar_h: float = 6.0
	canvas.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.04, 0.05, 0.06))
	if bool(card.get("evolved", false)):
		canvas.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.28, 0.76, 0.42))
	else:
		canvas.draw_rect(Rect2(bar_x, bar_y, bar_w * progress_ratio, bar_h), Color(0.86, 0.66, 0.30) if usable else Color(0.40, 0.36, 0.22))
	helpers.draw_text_line(canvas, task_system.task_progress_text(controlled_side, String(base_card["id"])), Rect2(rect.position + Vector2(3.0, 68.0), Vector2(rect.size.x - 6.0, 12.0)), 9, Color(0.90, 0.76, 0.46) if not bool(card.get("evolved", false)) else Color(0.47, 0.92, 0.72), HORIZONTAL_ALIGNMENT_CENTER)


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
	var card: Dictionary = task_system.active_card_by_id(controlled_side, card_id)
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
		var state: Dictionary = task_system.task_state(controlled_side, card_id)
		var progress_text: String = task_system.task_progress_text(controlled_side, card_id)
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
		"[Q/W/E/A/S/D] 快速选卡",
		"[+/-] 费用增减  [T] 强制任务  [R] 重开",
		"[B] Bot随机/固定  [Y] 重置种子  [F] 隐藏",
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
	var winner: String = override_winner if override_winner != "" else simulator.match_winner
	helpers.draw_text_line(canvas, "%s胜利" % MapMath.side_name(winner), Rect2(panel.position + Vector2(18.0, 16.0), Vector2(panel.size.x - 36.0, 28.0)), 25, Color(0.94, 0.96, 1.0), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "用时 %s；单位阵亡 %d；法术施放 %d" % [_format_time(simulator.battle_time()), int(simulator.stats["units_lost"]), int(simulator.stats["spell_casts"])], Rect2(panel.position + Vector2(18.0, 48.0), Vector2(panel.size.x - 36.0, 20.0)), 14, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "清屏次数 我方 %d / Bot %d" % [int(simulator.bases[Config.PLAYER]["clear_count"]), int(simulator.bases[Config.BOT]["clear_count"])], Rect2(panel.position + Vector2(18.0, 72.0), Vector2(panel.size.x - 36.0, 18.0)), 13, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	var spent_fp_f: float = preload("res://scripts/config/game_config.gd").FP_SCALE_F
	var p_spent: float = float(int(simulator.stats.get("player_spent_fp", simulator.stats.get("player_spent", 0)))) / spent_fp_f
	var b_spent: float = float(int(simulator.stats.get("bot_spent_fp", simulator.stats.get("bot_spent", 0)))) / spent_fp_f
	helpers.draw_text_line(canvas, "耗费 我方 %.0f / Bot %.0f" % [p_spent, b_spent], Rect2(panel.position + Vector2(18.0, 94.0), Vector2(panel.size.x - 36.0, 18.0)), 13, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(canvas, "任务 我方 %d / Bot %d；进化 我方 %d / Bot %d" % [int(simulator.stats.get("player_tasks_completed", 0)), int(simulator.stats.get("bot_tasks_completed", 0)), int(simulator.stats.get("player_evolutions", 0)), int(simulator.stats.get("bot_evolutions", 0))], Rect2(panel.position + Vector2(18.0, 116.0), Vector2(panel.size.x - 36.0, 18.0)), 13, Color(0.72, 0.78, 0.84), HORIZONTAL_ALIGNMENT_CENTER)

	# 卡牌详情列表
	var list_top: float = panel.position.y + 142.0
	var list_height: float = panel.size.y - 206.0
	var card_lines: Array[String] = []
	for card_id in selected_card_ids:
		var base_card: Dictionary = task_system.card_by_id(card_id)
		var state: Dictionary = task_system.task_state(controlled_side, card_id)
		var play_count: int = int(state.get("play_count", 0))
		var evolved: bool = bool(state.get("evolved", false))
		var completed_time: float = state.get("completed_at_time", -1.0)
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
	helpers.draw_text_line(canvas, "主界面", deck_rect, 18, Color(0.90, 0.93, 0.96), HORIZONTAL_ALIGNMENT_CENTER)


# 格式化秒为 mm:ss。
func _format_time(seconds: float) -> String:
	var total_seconds: int = int(floor(seconds))
	return "%02d:%02d" % [int(total_seconds / 60), total_seconds % 60]
