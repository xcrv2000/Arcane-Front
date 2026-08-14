extends RefCounted

const CARD_DATA_PATH: String = "res://data/cards.json"

static func all_cards() -> Array[Dictionary]:
	var cards: Array[Dictionary] = _load_card_group("cards")
	if cards.is_empty():
		push_error("CardCatalog did not load any cards from %s." % CARD_DATA_PATH)
	return cards


# 衍生单位可在图鉴与对局中使用，但不进入可编辑牌组的卡池。
static func derivative_units() -> Array[Dictionary]:
	return _load_card_group("derivative_units")


static func all_runtime_cards() -> Array[Dictionary]:
	var result: Array[Dictionary] = all_cards()
	result.append_array(derivative_units())
	return result


static func _load_card_group(group_name: String) -> Array[Dictionary]:
	if not FileAccess.file_exists(CARD_DATA_PATH):
		push_error("Card data file is missing: %s." % CARD_DATA_PATH)
		return []

	var file: FileAccess = FileAccess.open(CARD_DATA_PATH, FileAccess.READ)
	if file == null:
		push_error("Card data file could not be opened: %s." % CARD_DATA_PATH)
		return []

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		push_error("Card data JSON could not be parsed: %s." % CARD_DATA_PATH)
		return []

	var raw_cards: Variant = []
	if typeof(parsed) == TYPE_DICTIONARY:
		raw_cards = parsed.get(group_name, [])
	elif typeof(parsed) == TYPE_ARRAY and group_name == "cards":
		raw_cards = parsed

	if typeof(raw_cards) != TYPE_ARRAY:
		push_error("Card data JSON must contain a %s array: %s." % [group_name, CARD_DATA_PATH])
		return []

	var cards: Array[Dictionary] = []
	for raw_card in raw_cards:
		if typeof(raw_card) != TYPE_DICTIONARY:
			continue
		var card: Dictionary = raw_card.duplicate(true)
		_normalize_card(card)
		cards.append(card)
	return cards

static func _normalize_card(card: Dictionary) -> void:
	card["color"] = _color_from_value(card.get("color", "#ffffff"))

	var evolution: Dictionary = card.get("evolution", {})
	if evolution.is_empty():
		return

	var overrides: Dictionary = evolution.get("overrides", {})
	if overrides.has("color"):
		overrides["color"] = _color_from_value(overrides["color"])

static func _color_from_value(value: Variant) -> Color:
	if value is Color:
		return value

	if typeof(value) == TYPE_STRING:
		var text: String = String(value).strip_edges()
		if Color.html_is_valid(text):
			return Color.html(text)
		if Color.html_is_valid("#" + text):
			return Color.html("#" + text)

	if typeof(value) == TYPE_ARRAY:
		var components: Array = value
		if components.size() >= 3:
			var alpha: float = 1.0
			if components.size() >= 4:
				alpha = float(components[3])
			return Color(float(components[0]), float(components[1]), float(components[2]), alpha)

	return Color.WHITE
