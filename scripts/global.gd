extends Node

const MAIN_SCENE := "res://scenes/main.tscn"  # adjust to your real path
const LEVEL_SELECT_SCENE := "res://scenes/level_select_grid.tscn"  # or the list
var selected_level := -1  # -1 = not chosen from the menu

## --- Level builder (editor only) ---
const BUILDER_SCENE := "res://scenes/level_builder.tscn"
var test_level: LevelData  # set by the builder's Test Play; Main plays only this level
var builder_levels: Array[LevelData] = []  # the builder's working list, survives Test Play
var builder_index := 0
var builder_dirty := false

## Persistent player state. Registered as an autoload named "Global".

enum PowerUp { NONE, REMOVE_DOT, REMOVE_COLOR, SHUFFLE }

const START_POWER_UPS := 3

## Emitted whenever any count changes, so the UI can refresh.
signal power_ups_changed

## PowerUp -> uses left. Never reset by gameplay.
var power_ups := {
	PowerUp.REMOVE_DOT: START_POWER_UPS,
	PowerUp.REMOVE_COLOR: START_POWER_UPS,
	PowerUp.SHUFFLE: START_POWER_UPS,
}


func get_count(kind: PowerUp) -> int:
	return power_ups.get(kind, 0)


func has_power_up(kind: PowerUp) -> bool:
	return get_count(kind) > 0


## Spend one. Returns false (and changes nothing) if none are left.
func use_power_up(kind: PowerUp) -> bool:
	if not has_power_up(kind):
		return false
	power_ups[kind] -= 1
	power_ups_changed.emit()
	return true


## For rewards, purchases or loading a save.
func add_power_up(kind: PowerUp, amount := 1) -> void:
	power_ups[kind] = get_count(kind) + amount
	power_ups_changed.emit()
