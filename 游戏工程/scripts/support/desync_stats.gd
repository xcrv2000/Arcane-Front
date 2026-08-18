# 调试用：记录联机 desync 从“暂停等待重同步”到“恢复/失败”的耗时。
# 每次重同步开始会记下开始时间，结束时计算耗时并追加到 user://desync_stats.json。
# 文件里同时保存全部事件和汇总（总次数、平均耗时、已恢复平均耗时），便于直接查看。
extends RefCounted

const STATS_PATH: String = "user://desync_stats.json"
const MAX_EVENTS: int = 0  # 0=不裁剪，保留每一次记录；调试期如文件过大可改成 500 等

var _active: bool = false
var _start_ms: int = 0
var _start_tick: int = 0
var _room_code: String = ""
var _info: Dictionary = {}


func is_active() -> bool:
	return _active


# 在检测到 desync 并进入“正在重新同步”时调用。
func start_desync(tick: int, room_code: String, info: Dictionary) -> void:
	if _active:
		# 理论上不会重叠；若发生则保留第一次开始时间，避免重复计时。
		return
	_active = true
	_start_ms = Time.get_ticks_msec()
	_start_tick = tick
	_room_code = room_code
	_info = info.duplicate(true)


# 在重同步结束（恢复或失败/超时）时调用。
# outcome: "recovered" 表示成功恢复；"failed" 表示最终进入同步错误结果页。
func end_desync(outcome: String) -> Dictionary:
	if not _active:
		return {}
	var end_ms: int = Time.get_ticks_msec()
	var duration_ms: int = maxi(0, end_ms - _start_ms)
	var record: Dictionary = {
		"timestamp": Time.get_datetime_string_from_system(),
		"start_tick": _start_tick,
		"room_code": _room_code,
		"duration_ms": duration_ms,
		"duration_seconds": float(duration_ms) / 1000.0,
		"outcome": outcome,
		"desync_info": _info,
	}
	_active = false
	_start_ms = 0
	_start_tick = 0
	_room_code = ""
	_info = {}
	_append_record(record)
	print("[DesyncStats] %s：耗时 %.3f 秒（T%d，房间 %s）" % [
		outcome, record["duration_seconds"], record["start_tick"], record["room_code"]
	])
	var summary: Dictionary = get_summary()
	var recovered_count: int = int(summary.get("recovered_count", 0))
	if recovered_count > 0:
		print("[DesyncStats] 已恢复 %d 次，平均 %.3f 秒；全部 %d 次平均 %.3f 秒" % [
			recovered_count,
			float(summary.get("recovered_average_seconds", 0.0)),
			int(summary.get("total_count", 0)),
			float(summary.get("average_duration_ms", 0.0)) / 1000.0,
		])
	return record


# 读取保存的汇总（total_count / recovered_count / recovered_average_seconds 等）。
func get_summary() -> Dictionary:
	return _load_stats()


# 放弃当前未结束的计时（例如玩家中途离开房间/开始新对局）。
func cancel_active() -> void:
	_active = false
	_start_ms = 0
	_start_tick = 0
	_room_code = ""
	_info = {}


func _load_stats() -> Dictionary:
	var result: Dictionary = {
		"schema_version": 1,
		"events": [],
	}
	if not FileAccess.file_exists(STATS_PATH):
		return result
	var file: FileAccess = FileAccess.open(STATS_PATH, FileAccess.READ)
	if file == null:
		return result
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		var events: Variant = parsed.get("events", [])
		if events is Array:
			result["events"] = events
	return result


func _append_record(record: Dictionary) -> void:
	var stats: Dictionary = _load_stats()
	var events: Array = stats.get("events", [])
	events.append(record)
	if MAX_EVENTS > 0 and events.size() > MAX_EVENTS:
		events = events.slice(events.size() - MAX_EVENTS, events.size())
	stats["events"] = events

	var total_count: int = 0
	var total_duration_ms: int = 0
	var recovered_count: int = 0
	var recovered_duration_ms: int = 0
	for raw_event in events:
		if typeof(raw_event) != TYPE_DICTIONARY:
			continue
		var event: Dictionary = raw_event
		var duration_ms: int = int(event.get("duration_ms", 0))
		total_count += 1
		total_duration_ms += duration_ms
		if String(event.get("outcome", "")) == "recovered":
			recovered_count += 1
			recovered_duration_ms += duration_ms

	stats["total_count"] = total_count
	stats["total_duration_ms"] = total_duration_ms
	stats["average_duration_ms"] = float(total_duration_ms) / float(total_count) if total_count > 0 else 0.0
	stats["recovered_count"] = recovered_count
	stats["recovered_total_duration_ms"] = recovered_duration_ms
	stats["recovered_average_duration_ms"] = float(recovered_duration_ms) / float(recovered_count) if recovered_count > 0 else 0.0
	stats["recovered_average_seconds"] = float(recovered_duration_ms) / 1000.0 / float(recovered_count) if recovered_count > 0 else 0.0

	var file: FileAccess = FileAccess.open(STATS_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[DesyncStats] 无法写入 %s（错误码 %d）" % [STATS_PATH, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(stats, "\t"))
	file.close()
