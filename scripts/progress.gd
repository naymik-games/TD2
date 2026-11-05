extends Node
## Player progress: which levels are beaten, best score per level, and power-up counts.
## Register as an autoload named "Progress", listed AFTER "Global"
## (Project Settings -> Globals -> Autoload).
##
## Saved to user://progress.json, e.g.
##   {"version": 1,
##    "results": {"level_01.tres": {"best": 1240}, "level_02.tres": {"best": 980}},
##    "power_ups": {"1": 3, "2": 2, "3": 3}}
## A level is "completed" when it has an entry in `results`. Level N+1 is unlocked when
## level N is completed; level 1 is always unlocked.

signal changed

const SAVE_PATH := "user://td-2-progress.json"
const VERSION := 1

## level file name -> {"best": int}
var results := {}
## Flip on while testing to open every level.
var debug_unlock_all := false


func _ready() -> void:
	load_save()
	# Power-up counts live in Global and are never reset by gameplay, so persist them too.
	Global.power_ups_changed.connect(save)


## Stable id for a level: its file name (level_03.tres). Built-in sample levels have no
## file, so they fall back to their position.
func key_for(level: LevelData, index: int) -> String:
	var file := level.resource_path.get_file()
	return file if file != "" else "sample_%d" % index


func is_completed(level: LevelData, index: int) -> bool:
	return results.has(key_for(level, index))


func best_score(level: LevelData, index: int) -> int:
	var entry: Dictionary = results.get(key_for(level, index), {})
	return int(entry.get("best", 0))


func is_unlocked(levels: Array[LevelData], index: int) -> bool:
	if debug_unlock_all or index == 0:
		return true
	return is_completed(levels[index - 1], index - 1)


## The level the player should play next: the first one not yet beaten
## (or the last level once everything is beaten).
func current_index(levels: Array[LevelData]) -> int:
	for i in levels.size():
		if not is_completed(levels[i], i):
			return i
	return maxi(levels.size() - 1, 0)


## Call when a level is won. Keeps the best score.
func record_win(level: LevelData, index: int, score: int) -> void:
	results[key_for(level, index)] = {"best": maxi(best_score(level, index), score)}
	save()
	changed.emit()


func save() -> void:
	var power_ups := {}
	for kind in Global.power_ups:
		power_ups[str(kind)] = Global.power_ups[kind]
	var data := {"version": VERSION, "results": results, "power_ups": power_ups}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Progress: couldn't write %s (error %d)" % [SAVE_PATH, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(data))


func load_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Progress: save file is unreadable, starting fresh.")
		return
	results = parsed.get("results", {})
	var saved_power_ups: Dictionary = parsed.get("power_ups", {})
	for kind in saved_power_ups:
		Global.power_ups[int(kind)] = int(saved_power_ups[kind])  # JSON keys come back as strings


## Wipe everything (a "reset progress" button, or testing).
func reset() -> void:
	results.clear()
	for kind in Global.power_ups:
		Global.power_ups[kind] = Global.START_POWER_UPS
	save()
	changed.emit()
	Global.power_ups_changed.emit()
