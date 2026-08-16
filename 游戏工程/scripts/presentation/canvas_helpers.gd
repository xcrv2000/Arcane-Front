# 画布绘制原语与单位美术层：低层、无状态的公共绘制组件。
# 所有方法接收一个 CanvasItem（通常是控制器节点）作为第一参数，在其 _draw() 期间调用。
# 单位美术为版本线外表现层实验：按 art_id 加载正/背面 PNG，缺图回退到几何占位。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")

var font: Font = null
var unit_art_cache: Dictionary = {}


# 注入主题字体（控制器在 _ready 中通过 get_theme_default_font() 取得）。
func setup(ui_font: Font) -> void:
	font = ui_font


# 绘制带描边的填充矩形面板（radius 参数保留以兼容调用，当前未做圆角）。
func draw_panel(canvas: CanvasItem, rect: Rect2, fill: Color, radius: float, stroke: Color, stroke_width: float) -> void:
	canvas.draw_rect(rect, fill)
	canvas.draw_rect(rect, stroke, false, stroke_width)


# 在矩形内垂直居中绘制一行文本。
func draw_text_line(canvas: CanvasItem, text: String, rect: Rect2, font_size: int, color: Color, alignment: HorizontalAlignment) -> void:
	if font == null:
		return
	var y: float = rect.position.y + rect.size.y * 0.5 + font_size * 0.36
	canvas.draw_string(font, Vector2(rect.position.x, y), text, alignment, rect.size.x, font_size, color)


# 将较长文本拆成两行绘制（按宽度估算截断点）。
func draw_two_line_text(canvas: CanvasItem, text: String, rect: Rect2, font_size: int, color: Color) -> void:
	# 中文字符通常接近一个字号宽，以字号估算可避免长句溢出详情面板。
	var limit: int = max(8, int(rect.size.x / max(8.0, font_size * 0.96)))
	var first: String = text
	var second: String = ""
	if text.length() > limit:
		first = text.substr(0, limit)
		second = text.substr(limit, limit)
	draw_text_line(canvas, first, Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.5)), font_size, color, HORIZONTAL_ALIGNMENT_LEFT)
	if second != "":
		draw_text_line(canvas, second, Rect2(rect.position + Vector2(0.0, rect.size.y * 0.5), Vector2(rect.size.x, rect.size.y * 0.5)), font_size, color, HORIZONTAL_ALIGNMENT_LEFT)


# 我方显示背面，敌方显示正面。
# own_side 用于联机客机控制 BOT 阵营时反转视角：本机控制的阵营显示背面，对手显示正面。
func unit_art_view_for_side(side: String, own_side: String = Config.PLAYER) -> String:
	return Config.UNIT_ART_BACK if side == own_side else Config.UNIT_ART_FRONT


# 卡牌的表现层 art_id：进化卡用 evolved_id，否则用 id。
func card_art_id(card: Dictionary) -> String:
	return String(card.get("evolved_id", card.get("id", "")))


# 按 art_id+view 加载并缓存单位纹理；缺图返回 null。
func unit_art_texture(art_id: String, view: String) -> Texture2D:
	if art_id == "":
		return null
	var key: String = "%s:%s" % [art_id, view]
	if unit_art_cache.has(key):
		return unit_art_cache[key]

	var path: String = "%s%s_%s.png" % [Config.UNIT_ART_ROOT, art_id, view]
	var texture: Texture2D = null
	if FileAccess.file_exists(path):
		var image: Image = Image.load_from_file(path)
		if image != null and not image.is_empty():
			texture = ImageTexture.create_from_image(image)
	unit_art_cache[key] = texture
	return texture


# 绘制单位美术贴图：以单位脚部为锚点、按高度缩放。
func draw_unit_art(canvas: CanvasItem, texture: Texture2D, center: Vector2, radius: float) -> void:
	var height: float = max(18.0, radius * Config.UNIT_ART_HEIGHT_SCALE)
	var aspect: float = float(texture.get_width()) / max(1.0, float(texture.get_height()))
	var art_size: Vector2 = Vector2(height * aspect, height)
	var bottom_center: Vector2 = center + Vector2(0.0, radius * Config.UNIT_ART_FOOT_OFFSET)
	var rect: Rect2 = Rect2(Vector2(bottom_center.x - art_size.x * 0.5, bottom_center.y - art_size.y), art_size)
	canvas.draw_texture_rect(texture, rect, false)


# 尝试用卡牌美术图标绘制；非单位卡或无图返回 false。
func draw_card_art_icon(canvas: CanvasItem, card: Dictionary, center: Vector2, height: float, modulate: Color) -> bool:
	if String(card.get("kind", "")) != "unit":
		return false
	var texture: Texture2D = unit_art_texture(card_art_id(card), Config.UNIT_ART_FRONT)
	if texture == null:
		return false
	draw_texture_centered_height(canvas, texture, center, height, modulate)
	return true


# 以高度为基准、按宽高比居中绘制贴图。
func draw_texture_centered_height(canvas: CanvasItem, texture: Texture2D, center: Vector2, height: float, modulate: Color) -> void:
	var aspect: float = float(texture.get_width()) / max(1.0, float(texture.get_height()))
	var draw_size: Vector2 = Vector2(height * aspect, height)
	var rect: Rect2 = Rect2(center - draw_size * 0.5, draw_size)
	canvas.draw_texture_rect(texture, rect, false, modulate)


# 绘制单位阵营识别环（蓝/红），不烘焙进美术图片。
# own_side 用于联机客机控制 BOT 阵营时反转视角：本机控制的阵营显示蓝环，对手显示红环。
func draw_unit_team_ring(canvas: CanvasItem, center: Vector2, radius: float, side: String, own_side: String = Config.PLAYER) -> void:
	var color: Color = Color(0.32, 0.68, 1.0) if side == own_side else Color(1.0, 0.30, 0.24)
	var fill: Color = color
	fill.a = 0.13
	var ring_radius: float = max(4.0, radius * 1.08)
	canvas.draw_circle(center, ring_radius, fill)
	canvas.draw_circle(center, ring_radius, color, false, max(2.0, radius * 0.12))


# 按 shape 绘制单位几何占位（圆/方/三角）并叠加单字标签。美术缺图时回退使用。
func draw_unit_shape(canvas: CanvasItem, source: Dictionary, center: Vector2, radius: float, fill: Color, stroke: Color, label: String, label_size: int) -> void:
	var shape: String = String(source.get("shape", "circle"))
	if shape == "square":
		var rect: Rect2 = Rect2(center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
		canvas.draw_rect(rect, fill)
		canvas.draw_rect(rect, stroke, false, max(1.0, radius * 0.14))
	elif shape == "triangle":
		var points: PackedVector2Array = PackedVector2Array([
			center + Vector2(0.0, -radius),
			center + Vector2(radius * 0.92, radius * 0.72),
			center + Vector2(-radius * 0.92, radius * 0.72)
		])
		var outline: PackedVector2Array = PackedVector2Array(points)
		outline.append(points[0])
		canvas.draw_colored_polygon(points, fill)
		canvas.draw_polyline(outline, stroke, max(1.0, radius * 0.14))
	elif shape == "diamond":
		var points: PackedVector2Array = PackedVector2Array([
			center + Vector2(0.0, -radius),
			center + Vector2(radius * 0.82, 0.0),
			center + Vector2(0.0, radius),
			center + Vector2(-radius * 0.82, 0.0)
		])
		var outline: PackedVector2Array = PackedVector2Array(points)
		outline.append(points[0])
		canvas.draw_colored_polygon(points, fill)
		canvas.draw_polyline(outline, stroke, max(1.0, radius * 0.14))
	elif shape == "hexagon":
		var points: PackedVector2Array = PackedVector2Array()
		for index in range(6):
			var angle: float = -PI * 0.5 + TAU * float(index) / 6.0
			points.append(center + Vector2(cos(angle), sin(angle)) * radius)
		var outline: PackedVector2Array = PackedVector2Array(points)
		outline.append(points[0])
		canvas.draw_colored_polygon(points, fill)
		canvas.draw_polyline(outline, stroke, max(1.0, radius * 0.14))
	else:
		canvas.draw_circle(center, radius, fill)
		canvas.draw_circle(center, radius, stroke, false, max(1.0, radius * 0.14))
	draw_text_line(canvas, label, Rect2(center - Vector2(radius, radius * 0.72), Vector2(radius * 2.0, radius * 1.44)), label_size, Color(0.04, 0.05, 0.06), HORIZONTAL_ALIGNMENT_CENTER)
