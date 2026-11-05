class_name LevelLibrary
extends RefCounted
## Finds, loads and saves the level files in res://levels/.
## Levels play in filename order (level_01.tres, level_02.tres, ...), compared "naturally"
## so level_100 comes after level_99. The level builder writes the files in list order,
## so you never have to name them yourself.

const DIR := "res://levels"
const FILE_PREFIX := "level_"


## Full paths of every level file, in play order. Works in exported builds too, where
## Godot renames resources to "name.tres.remap".
static func list_paths() -> PackedStringArray:
	var names: Array[String] = []
	for f in DirAccess.get_files_at(DIR):
		var name := f.trim_suffix(".remap")
		if (name.ends_with(".tres") or name.ends_with(".res")) and not names.has(name):
			names.append(name)
	names.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	var paths := PackedStringArray()
	for n in names:
		paths.append(DIR.path_join(n))
	return paths


## Every level in play order. `fresh` skips Godot's resource cache (the builder uses it so
## edits never leak into a cached copy).
static func load_all(fresh := false) -> Array[LevelData]:
	var out: Array[LevelData] = []
	for path in list_paths():
		var res: Resource
		if fresh:
			res = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		else:
			res = load(path)
		if res is LevelData:
			out.append(res)
		else:
			push_warning("LevelLibrary: %s is not a LevelData, skipped." % path)
	return out


## Write the levels as level_01.tres, level_02.tres, ... and delete any
## other LevelData files in the folder (the folder is managed by the builder). Editor only.
static func save_all(levels: Array[LevelData]) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	if err != OK:
		return err
	var written := {}
	for i in levels.size():
		var file_name := "%s%02d.tres" % [FILE_PREFIX, i + 1]
		err = ResourceSaver.save(levels[i], DIR.path_join(file_name))
		if err != OK:
			return err
		written[file_name] = true
	# Remove level files that are no longer in the list: leftovers from when the list was
	# longer, and hand-named level files the builder loaded and has now rewritten as
	# level_NN. Only files that really are LevelData are touched.
	for f in DirAccess.get_files_at(DIR):
		if written.has(f) or not (f.ends_with(".tres") or f.ends_with(".res")):
			continue
		var path := DIR.path_join(f)
		if ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) is LevelData:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return OK
