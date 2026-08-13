# 地图与几何工具层：纯函数，不持有任何运行时对局状态。
# 提供阵营换算、基地/桥位置、部署区裁剪、点到线段距离等计算。
# 仅依赖 GameConfig 中的常量，可被模拟器、Bot、UI 任意调用。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")


# 返回对立阵营标识。
static func opponent(side: String) -> String:
	return Config.BOT if side == Config.PLAYER else Config.PLAYER


# 返回阵营的中文显示名。
static func side_name(side: String) -> String:
	return "我方" if side == Config.PLAYER else "Bot"


# 返回阵营基地的逻辑坐标（玩家在下方，Bot 在上方）。
static func base_position(side: String) -> Vector2:
	if side == Config.PLAYER:
		return Vector2(Config.MAP_WIDTH * 0.5, 94.0)
	return Vector2(Config.MAP_WIDTH * 0.5, 6.0)


# 依据游标选择左桥(16)或右桥(40)。
static func bridge_x(seed_value: int) -> float:
	return 16.0 if seed_value % 2 == 0 else 40.0


# 返回距离给定 x 最近的那座桥的 x 坐标。
static func nearest_bridge_x(x: float) -> float:
	return 16.0 if abs(x - 16.0) <= abs(x - 40.0) else 40.0


# 将部署点裁剪到阵营合法部署区内。
static func clamped_deploy_position(side: String, position: Vector2) -> Vector2:
	var min_y: float = Config.PLAYER_DEPLOY_MIN_Y if side == Config.PLAYER else 6.0
	var max_y: float = 94.0 if side == Config.PLAYER else Config.BOT_DEPLOY_MAX_Y
	return Vector2(
		clamp(position.x, 4.5, Config.MAP_WIDTH - 4.5),
		clamp(position.y, min_y, max_y)
	)


# 计算点到线段的最近距离（用于线性法术命中判定）。
static func distance_to_segment(point: Vector2, segment_start: Vector2, segment_end: Vector2) -> float:
	var segment: Vector2 = segment_end - segment_start
	var length_squared: float = segment.length_squared()
	if length_squared <= 0.0001:
		return point.distance_to(segment_start)
	var t: float = clamp((point - segment_start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(segment_start + segment * t)
