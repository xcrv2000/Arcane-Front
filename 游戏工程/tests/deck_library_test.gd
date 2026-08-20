extends SceneTree

const DeckLibrary = preload("res://scripts/support/deck_library.gd")
const NetworkClient = preload("res://scripts/networking/network_client.gd")
const UIPainter = preload("res://scripts/presentation/ui_painter.gd")
const V01Game = preload("res://scripts/v01/v01_game.gd")

var failures: Array[String] = []


func _init() -> void:
	_test_legacy_migration()
	_test_multiple_decks_and_switching()
	_test_invalid_cards_are_rejected()
	_test_preferred_battle_card_is_preserved()
	_test_countdown_protocol_reaches_room_state()
	if failures.is_empty():
		print("deck_library_test: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _new_library():
	var library = DeckLibrary.new()
	var known: Array[String] = ["a", "b", "c", "d", "e", "f", "g", "h"]
	var defaults: Array[String] = ["a", "b", "c", "d", "e", "f"]
	library.setup(known, defaults)
	return library


func _test_legacy_migration() -> void:
	var library = _new_library()
	var notice: String = library.load_payload({
		"schema_version": 1,
		"selected_card_ids": ["b", "c", "d", "e", "f", "g"]
	})
	_check(notice.find("升级") >= 0, "legacy schema did not report migration")
	_check(library.deck_count() == 1, "legacy schema did not create exactly one preset")
	_check(library.active_deck_ids() == ["b", "c", "d", "e", "f", "g"], "legacy deck order changed during migration")
	_check(int(library.to_payload().get("schema_version", 0)) == 2, "migrated payload was not schema v2")


func _test_multiple_decks_and_switching() -> void:
	var library = _new_library()
	var second: Array[String] = ["b", "c", "d", "e", "f", "g"]
	_check(library.create_deck(second), "could not create a second deck")
	_check(library.deck_count() == 2 and library.active_index == 1, "new deck was not activated")
	_check(library.active_deck_ids() == second, "new deck did not copy the requested cards")
	_check(library.switch_relative(-1), "could not switch to previous deck")
	_check(library.active_index == 0, "previous deck switch selected the wrong preset")
	_check(library.switch_relative(1), "could not switch to next deck")
	var adjusted: Array[String] = ["c", "d", "e", "f", "g", "h"]
	_check(library.save_active(adjusted), "could not adjust the active deck")
	_check(library.active_deck_ids() == adjusted, "active deck adjustment was not retained")
	_check(library.delete_active(), "could not delete one of multiple presets")
	_check(library.deck_count() == 1, "deck delete did not leave one preset")


func _test_invalid_cards_are_rejected() -> void:
	var library = _new_library()
	var notice: String = library.load_payload({
		"schema_version": 2,
		"active_deck_index": 0,
		"decks": [{"name": "bad", "card_ids": ["a", "a", "missing"]}]
	})
	_check(notice.find("默认") >= 0, "invalid deck did not fall back to defaults")
	_check(library.active_deck_ids() == ["a", "b", "c", "d", "e", "f"], "invalid deck fallback was incorrect")


func _test_preferred_battle_card_is_preserved() -> void:
	var deck: Array[String] = ["a", "b", "c", "d", "e", "f"]
	_check(DeckLibrary.resolve_preferred_card(deck, "d") == "d", "reconnect did not preserve the selected card")
	_check(DeckLibrary.resolve_preferred_card(deck, "missing") == "a", "invalid selected card did not fall back to the first card")
	var game = V01Game.new()
	game.painter = UIPainter.new()
	game._apply_battle_deck_selection(deck, "d")
	_check(game.selected_battle_card_id == "d", "controller integration reset the selected card during restore")
	game.free()


func _test_countdown_protocol_reaches_room_state() -> void:
	var game = V01Game.new()
	var client = NetworkClient.new()
	client.start_countdown_received.connect(game._on_start_countdown)
	client._handle_json({"type": "START_COUNTDOWN", "seconds": 3.0})
	_check(is_equal_approx(game.match_start_countdown, 3.0), "three-second server countdown did not reach the room state")
	client._handle_json({"type": "START_COUNTDOWN", "seconds": 0.0})
	_check(game.match_start_countdown < 0.0, "cancelled server countdown remained active in the room state")
	game.free()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
