# V0.4 (P1) 定点数工具层：Q*1000 整数定点，纯函数。
# 目标：消除 float 与 sqrt 导致的跨端 desync。
#
# 约定：
#   - Q*1000：1.0 → 1000，0.5 → 500，56.0 → 56000
#   - 坐标/半径/速度/距离一律使用 int（定点）表示，内部绝不使用 float 运算
#   - 距离比较统一用"平方距离"fp_dist_sq()，避免 sqrt
#   - 移动方向用整数向量归一化近似：dx/dy 各取 sign 后按比例放大
#
# 注意：纯工具，不持有任何运行时状态。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")

const FP: int = 1000  # 与 Config.FP_SCALE 保持一致


# float → 定点（round，避免 truncate 偏差）。
static func to_fp(value: float) -> int:
	var s: int = Config.FP_SCALE
	if value >= 0.0:
		return int(value * float(s) + 0.5)
	return -int(-value * float(s) + 0.5)


# 定点 → float（仅表现层/日志/调试使用，不参与战斗判定）。
static func from_fp(value_fp: int) -> float:
	return float(value_fp) / Config.FP_SCALE_F


# Vector2 → 定点向量（返回 Dictionary {x:int, y:int}）。
static func vec_to_fp(v: Vector2) -> Dictionary:
	return {"x": to_fp(v.x), "y": to_fp(v.y)}


# 定点向量 → Vector2（仅表现层）。
static func vec_from_fp(v_fp: Dictionary) -> Vector2:
	return Vector2(from_fp(int(v_fp.get("x", 0))), from_fp(int(v_fp.get("y", 0))))


# 平方距离（定点）：(x1 - x2)^2 + (y1 - y2)^2。用 64 位 int 避免溢出。
static func dist_sq(x1: int, y1: int, x2: int, y2: int) -> int:
	var dx: int = x1 - x2
	var dy: int = y1 - y2
	return dx * dx + dy * dy


# 平方距离（Dictionary 版本，参数：两定点向量）。
static func vec_dist_sq(a: Dictionary, b: Dictionary) -> int:
	return dist_sq(int(a.get("x", 0)), int(a.get("y", 0)), int(b.get("x", 0)), int(b.get("y", 0)))


# 比较距离是否小于等于阈值：无需 sqrt，直接比较平方。
static func dist_le(x1: int, y1: int, x2: int, y2: int, radius_fp: int) -> bool:
	return dist_sq(x1, y1, x2, y2) <= radius_fp * radius_fp


# 定点 clamp：返回 clamp(v, min_v, max_v)。
static func clamp_int(v: int, min_v: int, max_v: int) -> int:
	if v < min_v:
		return min_v
	if v > max_v:
		return max_v
	return v


# 定点向目标移动一步（Q*1000）：
#   输入：当前 (cx, cy)，目标 (tx, ty)，步长 step_fp（速度*tick_dt，已转定点）
#   输出：新 (nx, ny)；若已到达目标半径内则原地
# 实现：整数方向近似（无 sqrt），按比例放缩。
static func move_toward(cx: int, cy: int, tx: int, ty: int, step_fp: int) -> Dictionary:
	var dx: int = tx - cx
	var dy: int = ty - cy
	var adx: int = abs(dx)
	var ady: int = abs(dy)
	# 到达条件：dx 与 dy 都 <= 20 (0.02 * FP)
	if adx <= 20 and ady <= 20:
		return {"x": cx, "y": cy}
	# 使用切比雪夫范数（max(|dx|, |dy|)）近似归一化长度，避免 sqrt：
	#   方向分量 = dx * step / max(|dx|, |dy|)
	# 这是保守估计，移动方向略微偏向长轴；相比 sqrt 误差可接受且完全确定。
	var length: int = max(adx, ady)
	if length == 0:
		return {"x": cx, "y": cy}
	# 64 位乘法防溢出：
	var sx: int = int((int(dx) * int(step_fp)) / int(length))
	var sy: int = int((int(dy) * int(step_fp)) / int(length))
	# 避免越过目标：当 |step| > |remaining|，截断到目标
	if abs(sx) > adx:
		sx = dx
	if abs(sy) > ady:
		sy = dy
	return {"x": cx + sx, "y": cy + sy}


# 两定点向量相加：a + b。
static func vec_add(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"x": int(a.get("x", 0)) + int(b.get("x", 0)), "y": int(a.get("y", 0)) + int(b.get("y", 0))}


# 两定点向量相减：a - b。
static func vec_sub(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"x": int(a.get("x", 0)) - int(b.get("x", 0)), "y": int(a.get("y", 0)) - int(b.get("y", 0))}


# 向量标量乘法（scalar 是整数，直接乘；scalar 是定点数则随后按 FP 缩放）。
static func vec_mul(v: Dictionary, scalar_int: int) -> Dictionary:
	return {"x": int(v.get("x", 0)) * scalar_int, "y": int(v.get("y", 0)) * scalar_int}


# 向量整数归一化方向（返回 {dx, dy}，量级为 max(|dx|,|dy|)=1 或 (0,0)）。
static func vec_dir(from_fp: Dictionary, to_fp: Dictionary) -> Dictionary:
	var dx: int = int(to_fp.get("x", 0)) - int(from_fp.get("x", 0))
	var dy: int = int(to_fp.get("y", 0)) - int(from_fp.get("y", 0))
	var adx: int = abs(dx)
	var ady: int = abs(dy)
	if adx == 0 and ady == 0:
		return {"x": 0, "y": 0}
	if adx >= ady:
		return {"x": 1 if dx > 0 else -1, "y": int((int(dy) * int(FP)) / int(max(adx, 1))) / FP}
	else:
		return {"x": int((int(dx) * int(FP)) / int(ady)) / FP, "y": 1 if dy > 0 else -1}
