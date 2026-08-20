# 玩家本地多牌组存档模型。
# 只处理可用卡牌过滤、旧存档迁移、预设切换与序列化；文件 IO 由控制器负责。
extends RefCounted

const SCHEMA_VERSION: int = 2
const MAX_DECKS: int = 6

var decks: Array[Dictionary] = []
var active_index: int = 0
var migrated_from_schema: int = 0

var _known_ids: Dictionary = {}
var _default_ids: Array[String] = []


func setup(known_ids: Array[String], default_ids: Array[String]) -> void:
	_known_ids.clear()
	for card_id in known_ids:
		_known_ids[card_id] = true
	_default_ids = _sanitize_deck(default_ids)
	_reset_to_default()


# 返回空字符串表示正常读取；非空字符串可直接作为前端提示。
func load_payload(payload: Variant) -> String:
	migrated_from_schema = 0
	if not (payload is Dictionary):
		_reset_to_default()
		return "牌组存档无法读取，已使用默认牌组。"

	var data: Dictionary = payload
	var schema_version: int = int(data.get("schema_version", 1))
	if schema_version >= SCHEMA_VERSION and data.get("decks", null) is Array:
		var loaded: Array[Dictionary] = []
		var raw_decks: Array = data.get("decks", [])
		for raw_deck in raw_decks:
			if not (raw_deck is Dictionary):
				continue
			var deck_data: Dictionary = raw_deck
			var ids: Array[String] = _sanitize_deck(deck_data.get("card_ids", []))
			if ids.size() != _default_ids.size():
				continue
			loaded.append({
				"name": _clean_name(String(deck_data.get("name", "")), loaded.size() + 1),
				"card_ids": ids
			})
			if loaded.size() >= MAX_DECKS:
				break
		if loaded.is_empty():
			_reset_to_default()
			return "牌组存档中没有完整的可用牌组，已使用默认牌组。"
		decks = loaded
		active_index = clampi(int(data.get("active_deck_index", 0)), 0, decks.size() - 1)
		return ""

	# schema v1：{selected_card_ids:[...]}，在内存中迁移成第一个预设。
	var legacy_ids: Array[String] = _sanitize_deck(data.get("selected_card_ids", []))
	if legacy_ids.size() == _default_ids.size():
		decks = [{"name": "牌组 1", "card_ids": legacy_ids}]
		active_index = 0
		migrated_from_schema = schema_version
		return "旧牌组存档已升级为多牌组格式。"

	_reset_to_default()
	return "牌组存档不完整，已使用默认牌组。"


func to_payload() -> Dictionary:
	var serialized_decks: Array[Dictionary] = []
	for deck in decks:
		serialized_decks.append({
			"name": String(deck.get("name", "")),
			"card_ids": _deck_ids_from(deck)
		})
	return {
		"schema_version": SCHEMA_VERSION,
		"active_deck_index": active_index,
		"decks": serialized_decks
	}


func active_deck_ids() -> Array[String]:
	if decks.is_empty():
		return _default_ids.duplicate()
	return _deck_ids_from(decks[active_index])


func active_deck_name() -> String:
	if decks.is_empty():
		return "牌组 1"
	return String(decks[active_index].get("name", "牌组 %d" % (active_index + 1)))


func deck_count() -> int:
	return decks.size()


func switch_relative(offset: int) -> bool:
	if decks.size() <= 1 or offset == 0:
		return false
	active_index = posmod(active_index + offset, decks.size())
	return true


func save_active(deck_ids: Array[String]) -> bool:
	var sanitized: Array[String] = _sanitize_deck(deck_ids)
	if sanitized.size() != _default_ids.size() or decks.is_empty():
		return false
	decks[active_index]["card_ids"] = sanitized
	return true


func create_deck(copy_ids: Array[String]) -> bool:
	if decks.size() >= MAX_DECKS:
		return false
	var sanitized: Array[String] = _sanitize_deck(copy_ids)
	if sanitized.size() != _default_ids.size():
		sanitized = active_deck_ids()
	decks.append({
		"name": _next_deck_name(),
		"card_ids": sanitized
	})
	active_index = decks.size() - 1
	return true


func delete_active() -> bool:
	if decks.size() <= 1:
		return false
	decks.remove_at(active_index)
	active_index = mini(active_index, decks.size() - 1)
	return true


static func resolve_preferred_card(deck_ids: Array[String], preferred_card_id: String) -> String:
	if preferred_card_id != "" and deck_ids.has(preferred_card_id):
		return preferred_card_id
	return deck_ids[0] if not deck_ids.is_empty() else ""


func _reset_to_default() -> void:
	decks = [{"name": "牌组 1", "card_ids": _default_ids.duplicate()}]
	active_index = 0


func _sanitize_deck(raw_ids: Variant) -> Array[String]:
	var result: Array[String] = []
	if not (raw_ids is Array):
		return result
	var seen: Dictionary = {}
	for raw_id in raw_ids:
		var card_id: String = String(raw_id)
		if _known_ids.has(card_id) and not seen.has(card_id):
			result.append(card_id)
			seen[card_id] = true
	return result


func _deck_ids_from(deck: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for raw_id in deck.get("card_ids", []):
		result.append(String(raw_id))
	return result


func _clean_name(raw_name: String, fallback_index: int) -> String:
	var cleaned: String = raw_name.strip_edges()
	if cleaned == "":
		return "牌组 %d" % fallback_index
	return cleaned.left(24)


func _next_deck_name() -> String:
	var used: Dictionary = {}
	for deck in decks:
		used[String(deck.get("name", ""))] = true
	for number in range(1, MAX_DECKS + 1):
		var candidate: String = "牌组 %d" % number
		if not used.has(candidate):
			return candidate
	return "牌组 %d" % (decks.size() + 1)
