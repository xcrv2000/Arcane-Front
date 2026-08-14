# 地图与几何工具层：纯函数，不持有任何运行时对局状态。
# 提供阵营换算、基地/桥位置、部署区裁剪、点到线段距离等计算。
# V0.4 (P1)：新增 *_fp 版本，位置/半径统一使用 Q*1000 定点整数（int），
# 距离比较统一用平方距离，避免 float 与 sqrt。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const Fp = preload("res://scripts/support/fp_math.gd")


# 返回对立阵营标识。
static func opponent(side: String) -> String:
	return Config.BOT if side == Config.PLAYER else Config.PLAYER


# 返回阵营的中文显示名。空字符串表示平局。
static func side_name(side: String) -> String:
	if side == "":
		return "平局"
	return "我方" if side == Config.PLAYER else "Bot"


# —— 以下为 float 兼容层（表现层/非战斗判定继续使用）——

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


# —— 以下为 V0.4 (P1) 定点整数版本（战斗判定层专用）——
# 所有返回位置的函数用 Dictionary {x:int, y:int}（Q*1000）。

static func _FP() -> int:
	return Config.FP_SCALE


static func base_position_fp(side: String) -> Dictionary:
	var s: int = _FP()
	# MAP_WIDTH 是 float，但在 Config 中固定；用整数避免 float 参与
	# MAP_WIDTH * 0.5 = 28.0, 94.0, 6.0
	var center_x: int = 28 * s  # 28.0
	if side == Config.PLAYER:
		return {"x": center_x, "y": 94 * s}
	return {"x": center_x, "y": 6 * s}


static func bridge_x_fp(seed_value: int) -> int:
	var s: int = _FP()
	return (16 * s) if seed_value % 2 == 0 else (40 * s)


# 距离给定 x（定点）最近的桥 x（定点）。
static func nearest_bridge_x_fp(x_fp: int) -> int:
	var s: int = _FP()
	var left: int = 16 * s
	var right: int = 40 * s
	var d_left: int = abs(x_fp - left)
	var d_right: int = abs(x_fp - right)
	return left if d_left <= d_right else right


# 将部署点裁剪到合法部署区（定点版）。
static func clamped_deploy_position_fp(side: String, pos_fp: Dictionary) -> Dictionary:
	var s: int = _FP()
	var min_y: int
	var max_y: int
	var clamp_min_y_deploy: int = int(Config.PLAYER_DEPLOY_MIN_Y * float(s) + 0.5)
	var clamp_max_y_deploy: int = int(Config.BOT_DEPLOY_MAX_Y * float(s) + 0.5)
	if side == Config.PLAYER:
		min_y = clamp_min_y_deploy
		max_y = 94 * s
	else:
		min_y = 6 * s
		max_y = clamp_max_y_deploy
	var margin: int = int(4.5 * float(s) + 0.5)
	var map_w: int = int(Config.MAP_WIDTH * float(s) + 0.5)
	return {
		"x": Fp.clamp_int(int(pos_fp.get("x", 0)), margin, map_w - margin),
		"y": Fp.clamp_int(int(pos_fp.get("y", 0)), min_y, max_y)
	}


# 点到线段的平方距离（定点版，用于 <= R^2 比较，无需开根）。
static func distance_to_segment_sq_fp(p: Dictionary, a: Dictionary, b: Dictionary) -> int:
	var px: int = int(p.get("x", 0))
	var py: int = int(p.get("y", 0))
	var ax: int = int(a.get("x", 0))
	var ay: int = int(a.get("y", 0))
	var bx: int = int(b.get("x", 0))
	var by: int = int(b.get("y", 0))
	var sx: int = bx - ax
	var sy: int = by - ay
	var len_sq: int = sx * sx + sy * sy
	if len_sq == 0:
		return Fp.dist_sq(px, py, ax, ay)
	# t = clamp((p - a) · s / len_sq, 0, 1)
	# 点积
	var dot_v: int = (px - ax) * sx + (py - ay) * sy
	var t_num: int = Fp.clamp_int(dot_v, 0, len_sq)
	# 投影点：a + s * (t_num / len_sq)
	var qx: int = ax + int((int(sx) * int(t_num)) / int(len_sq))
	var qy: int = ay + int((int(sy) * int(t_num)) / int(len_sq))
	return Fp.dist_sq(px, py, qx, qy)
