extends Control
## Level builder (editor only). Open level_builder.tscn and press F6 ("Run Current Scene").
##
## Left:   the level list (new / duplicate / delete / reorder / import)
## Middle: every exported field of LevelData, generated automatically, plus the goals
## Right:  a live preview built by the real Board class, and the validate() problems
## Bottom: Save All (writes res://levels/level_01.tres, level_02.tres, ...) and Test Play
##
## New @export fields added to LevelData show up in the middle column with no changes here.
## The UI is built in code, like main.gd.

## Scene to launch for Test Play.
@export var main_scene_path := "res://main.tscn"
## Window size used while building (the game's own window is usually a phone-sized portrait).
@export var builder_window_size := Vector2i(1400, 860)

## Keep in sync with main.gd's PALETTE.
const PALETTE: Array[Color] = [
	Color("#ef476f"), Color("#ffd166"), Color("#06d6a0"),
	Color("#118ab2"), Color("#9b5de5"), Color("#f78c3b"),
]
## Tooltips for the generated fields. Any field not listed just has no tooltip.
const FIELD_HINTS := {
	"title": "Optional. The HUD falls back to \"Level N\".",
	"moves": "0 = unlimited.",
	"anchor_count": "Anchors at the start, and the most on the board at once.",
	"ice_count": "Cells that start with ice over them.",
	"rock_count": "Rocks placed at the start.",
	"bomb_count": "Most timed bombs on the board at once. 0 = none. They spawn during play.",
	"bomb_fuse": "Moves a bomb has before it explodes.",
	"blanks": "One connected group of four holes, never on the bottom row.",
}

var levels: Array[LevelData] = []
var index := 0
var dirty := false
var preview_seed := 1

var _loading := false  # true while the form is being filled, so it doesn't count as an edit
var _field_controls := {}  # LevelData property name -> Control
var _color_icons: Array[Texture2D] = []
var _orig_scale_mode := Window.CONTENT_SCALE_MODE_DISABLED
var _orig_size := Vector2i.ZERO

var _list: ItemList
var _goal_box: VBoxContainer
var _add_goal_button: Button
var _preview: BoardPreview
var _stats_label: Label
var _problems_label: Label
var _status_label: Label
var _delete_dialog: ConfirmationDialog
var _quit_dialog: ConfirmationDialog
var _import_dialog: FileDialog
var _gen_count: SpinBox
var _gen_from: SpinBox
var _gen_to: SpinBox
var _gen_button: Button
var _generating := false


func _ready() -> void:
	_setup_window()
	get_tree().auto_accept_quit = false  # so closing the window can ask about unsaved changes
	_make_color_icons()
	_build_ui()

	Global.test_level = null
	if not Global.builder_levels.is_empty():
		# Coming back from Test Play: pick up exactly where we left off.
		levels = Global.builder_levels
		index = clampi(Global.builder_index, 0, levels.size() - 1)
		dirty = Global.builder_dirty
		Global.builder_levels = []
	else:
		levels = LevelLibrary.load_all(true)
		for l in levels:
			_inline_goals(l)
		if levels.is_empty():
			levels.append(_new_level())
			dirty = true
	preview_seed = randi_range(1, 2147483647)
	_refresh_list()
	_select(index)
	_set_status("Loaded %d level(s) from %s" % [levels.size(), LevelLibrary.DIR])


# ---------- Window ----------

func _setup_window() -> void:
	var win := get_window()
	_orig_scale_mode = win.content_scale_mode
	_orig_size = win.size
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	win.size = builder_window_size
	win.move_to_center()


func _restore_window() -> void:
	var win := get_window()
	win.content_scale_mode = _orig_scale_mode
	win.size = _orig_size
	win.move_to_center()
	get_tree().auto_accept_quit = true


func _update_title() -> void:
	get_window().title = "Level Builder  -  %d level(s)%s" % [levels.size(), "  *unsaved" if dirty else ""]


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if dirty:
			_quit_dialog.popup_centered()
		else:
			get_tree().quit()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_S \
			and (key.ctrl_pressed or key.meta_pressed):
		_save_all()
		get_viewport().set_input_as_handled()


# ---------- UI construction ----------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 12)
	root.add_child(columns)
	columns.add_child(_build_list_column())
	columns.add_child(VSeparator.new())
	columns.add_child(_build_form_column())
	columns.add_child(VSeparator.new())
	columns.add_child(_build_preview_column())

	root.add_child(HSeparator.new())
	root.add_child(_build_toolbar())

	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.confirmed.connect(_delete_current)
	add_child(_delete_dialog)

	_quit_dialog = ConfirmationDialog.new()
	_quit_dialog.title = "Unsaved changes"
	_quit_dialog.dialog_text = "You have unsaved changes."
	_quit_dialog.ok_button_text = "Save and quit"
	_quit_dialog.add_button("Quit without saving", false, "discard")
	_quit_dialog.confirmed.connect(_on_quit_save)
	_quit_dialog.custom_action.connect(_on_quit_action)
	add_child(_quit_dialog)

	_import_dialog = FileDialog.new()
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_import_dialog.access = FileDialog.ACCESS_RESOURCES
	_import_dialog.filters = PackedStringArray(["*.tres, *.res ; LevelData resources"])
	_import_dialog.title = "Import level resources"
	_import_dialog.files_selected.connect(_on_files_imported)
	add_child(_import_dialog)


func _build_list_column() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 240
	box.add_child(_header("Levels"))

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_list_selected)
	box.add_child(_list)

	var row1 := HBoxContainer.new()
	row1.add_child(_button("New", _on_new))
	row1.add_child(_button("Duplicate", _on_duplicate))
	row1.add_child(_button("Delete", _on_delete))
	box.add_child(row1)

	var row2 := HBoxContainer.new()
	row2.add_child(_button("Move Up", _on_move.bind(-1)))
	row2.add_child(_button("Move Down", _on_move.bind(1)))
	box.add_child(row2)

	var row3 := HBoxContainer.new()
	row3.add_child(_button("Import...", _on_import))
	row3.add_child(_button("Add Samples", _on_add_samples))
	box.add_child(row3)

	box.add_child(HSeparator.new())
	box.add_child(_header("Generate"))
	var gen_row1 := HBoxContainer.new()
	gen_row1.add_child(_small_label("Levels"))
	_gen_count = _spin(1, 30, 10)
	gen_row1.add_child(_gen_count)
	box.add_child(gen_row1)
	var gen_row2 := HBoxContainer.new()
	gen_row2.add_child(_small_label("Difficulty"))
	_gen_from = _spin(1, 10, 1)
	gen_row2.add_child(_gen_from)
	gen_row2.add_child(_small_label("to"))
	_gen_to = _spin(1, 10, 10)
	gen_row2.add_child(_gen_to)
	box.add_child(gen_row2)
	_gen_button = _button("Generate Levels", _on_generate)
	_gen_button.tooltip_text = "Adds playable random levels after the selected one. The move limit of each is tuned by simulated play."
	box.add_child(_gen_button)
	return box


func _build_form_column() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 400
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

	box.add_child(_header("Level settings"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	box.add_child(grid)
	_build_fields(grid)

	box.add_child(HSeparator.new())
	box.add_child(_header("Goals (up to %d)" % LevelData.MAX_GOALS))
	_goal_box = VBoxContainer.new()
	box.add_child(_goal_box)
	_add_goal_button = _button("+ Add goal", _on_add_goal)
	box.add_child(_add_goal_button)
	return scroll


func _build_preview_column() -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var head := HBoxContainer.new()
	head.add_child(_header("Preview (one random example)"))
	head.add_child(_button("Reroll", _on_reroll, false))
	box.add_child(head)

	_preview = BoardPreview.new()
	_preview.palette = PALETTE
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.custom_minimum_size = Vector2(320, 320)
	box.add_child(_preview)

	_stats_label = Label.new()
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_stats_label)

	_problems_label = Label.new()
	_problems_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_problems_label)
	return box


func _build_toolbar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	bar.add_child(_button("Save All  (Ctrl+S)", _save_all, false))
	bar.add_child(_button("Test Play", _test_play, false))
	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_status_label)
	return bar


func _header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 18)
	return l


func _button(text: String, callback: Callable, expand := true) -> Button:
	var b := Button.new()
	b.text = text
	if expand:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(callback)
	return b


func _small_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _spin(min_value: int, max_value: int, value: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_value
	s.max_value = max_value
	s.step = 1
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


func _make_color_icons() -> void:
	for col in PALETTE:
		var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
		img.fill(col)
		_color_icons.append(ImageTexture.create_from_image(img))


# ---------- Generated fields (one control per exported LevelData property) ----------

func _build_fields(grid: GridContainer) -> void:
	var proto := LevelData.new()
	for p in proto.get_property_list():
		if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) or not (p.usage & PROPERTY_USAGE_EDITOR):
			continue
		var pname: String = p.name
		if pname == "goals":  # has its own panel
			continue
		var control := _make_field(p)
		if control == null:
			continue
		var label := Label.new()
		label.text = pname.capitalize()
		label.tooltip_text = FIELD_HINTS.get(pname, "")
		control.tooltip_text = label.tooltip_text
		grid.add_child(label)
		grid.add_child(control)
		_field_controls[pname] = control


func _make_field(p: Dictionary) -> Control:
	var pname: String = p.name
	match p.type:
		TYPE_BOOL:
			var cb := CheckBox.new()
			cb.toggled.connect(_on_bool_field.bind(pname))
			return cb
		TYPE_INT, TYPE_FLOAT:
			var is_int: bool = p.type == TYPE_INT
			var sb := SpinBox.new()
			var lo := 0.0
			var hi := 9999.0
			var step := 1.0 if is_int else 0.01
			if p.hint == PROPERTY_HINT_RANGE:
				var parts: PackedStringArray = String(p.hint_string).split(",")
				if parts.size() >= 2 and parts[0].is_valid_float() and parts[1].is_valid_float():
					lo = float(parts[0])
					hi = float(parts[1])
				if parts.size() >= 3 and parts[2].is_valid_float() and not is_int:
					step = float(parts[2])
			sb.min_value = lo
			sb.max_value = hi
			sb.step = step
			sb.rounded = is_int
			sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sb.value_changed.connect(_on_number_field.bind(pname, is_int))
			return sb
		TYPE_STRING:
			var le := LineEdit.new()
			le.placeholder_text = "(optional)"
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_changed.connect(_on_text_field.bind(pname))
			return le
	return null


func _on_bool_field(value: bool, pname: String) -> void:
	_set_field(pname, value)


func _on_number_field(value: float, pname: String, is_int: bool) -> void:
	_set_field(pname, int(value) if is_int else value)


func _on_text_field(value: String, pname: String) -> void:
	_set_field(pname, value)


func _set_field(pname: String, value: Variant) -> void:
	if _loading or _level() == null:
		return
	_level().set(pname, value)
	_changed()


func _refresh_form() -> void:
	_loading = true
	var l := _level()
	for pname in _field_controls:
		var c: Control = _field_controls[pname]
		var v: Variant = l.get(pname)
		if c is CheckBox:
			(c as CheckBox).set_pressed_no_signal(bool(v))
		elif c is SpinBox:
			(c as SpinBox).set_value_no_signal(float(v))
		elif c is LineEdit:
			(c as LineEdit).text = str(v)
	_loading = false
	_rebuild_goal_rows()


# ---------- Goals ----------

func _rebuild_goal_rows() -> void:
	for child in _goal_box.get_children():
		_goal_box.remove_child(child)
		child.queue_free()
	var l := _level()
	for i in l.goals.size():
		_goal_box.add_child(_make_goal_row(l.goals[i], i))
	_add_goal_button.disabled = l.goals.size() >= LevelData.MAX_GOALS


func _make_goal_row(g: GoalData, i: int) -> Control:
	var row := HBoxContainer.new()

	var type_btn := OptionButton.new()
	for type_name in GoalData.Type.keys():
		type_btn.add_item(String(type_name).capitalize())
	type_btn.selected = g.type
	row.add_child(type_btn)

	var color_btn := OptionButton.new()
	for c in PALETTE.size():
		color_btn.add_icon_item(_color_icons[c], "Color %d" % c)
	color_btn.selected = clampi(g.color, 0, PALETTE.size() - 1)
	color_btn.visible = g.type == GoalData.Type.COLOR
	color_btn.item_selected.connect(_on_goal_color.bind(g))
	row.add_child(color_btn)

	type_btn.item_selected.connect(_on_goal_type.bind(g, color_btn))

	var amount := SpinBox.new()
	amount.min_value = 1
	amount.max_value = 999
	amount.rounded = true
	amount.value = g.amount
	amount.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	amount.value_changed.connect(_on_goal_amount.bind(g))
	row.add_child(amount)

	var remove := Button.new()
	remove.text = "x"
	remove.tooltip_text = "Remove this goal"
	remove.pressed.connect(_on_remove_goal.bind(i))
	row.add_child(remove)
	return row


func _on_goal_type(idx: int, g: GoalData, color_btn: OptionButton) -> void:
	g.type = idx as GoalData.Type
	color_btn.visible = g.type == GoalData.Type.COLOR
	_changed()


func _on_goal_color(idx: int, g: GoalData) -> void:
	g.color = idx
	_changed()


func _on_goal_amount(value: float, g: GoalData) -> void:
	g.amount = int(value)
	_changed()


func _on_remove_goal(i: int) -> void:
	_level().goals.remove_at(i)
	_rebuild_goal_rows()
	_changed()


func _on_add_goal() -> void:
	var l := _level()
	if l.goals.size() >= LevelData.MAX_GOALS:
		return
	l.goals.append(GoalData.make(GoalData.Type.COLOR, 10, 0))
	_rebuild_goal_rows()
	_changed()


# ---------- Level list ----------

func _level() -> LevelData:
	return levels[index] if index >= 0 and index < levels.size() else null


func _new_level() -> LevelData:
	var l := LevelData.new()
	l.goals.append(GoalData.make(GoalData.Type.COLOR, 10, 0))
	return l


## Make every goal a private inline copy, so saving embeds it in the level's own file
## instead of referencing a separate GoalData .tres.
func _inline_goals(l: LevelData) -> void:
	var inline_goals: Array[GoalData] = []
	for g in l.goals:
		if g != null:
			inline_goals.append(g.duplicate())
	l.goals = inline_goals


func _copy_level(l: LevelData, mark_as_copy := false) -> LevelData:
	var c := l.duplicate() as LevelData
	c.goals = []
	_inline_goals_from(c, l)
	if mark_as_copy and c.title != "":
		c.title += " copy"
	return c


func _inline_goals_from(target: LevelData, source: LevelData) -> void:
	var copies: Array[GoalData] = []
	for g in source.goals:
		if g != null:
			copies.append(g.duplicate())
	target.goals = copies


func _list_text(i: int) -> String:
	var l := levels[i]
	var t := l.title if l.title != "" else "(untitled)"
	var flag := "   [!]" if not l.validate().is_empty() else ""
	return "%02d  %s%s" % [i + 1, t, flag]


func _refresh_list() -> void:
	_list.clear()
	for i in levels.size():
		_list.add_item(_list_text(i))


func _select(i: int) -> void:
	index = clampi(i, 0, levels.size() - 1)
	_list.select(index)
	_list.ensure_current_is_visible()
	_refresh_form()
	_rebuild_preview()
	_update_title()


func _on_list_selected(i: int) -> void:
	_select(i)


func _on_new() -> void:
	levels.insert(index + 1, _new_level())
	dirty = true
	_refresh_list()
	_select(index + 1)


func _on_duplicate() -> void:
	levels.insert(index + 1, _copy_level(_level(), true))
	dirty = true
	_refresh_list()
	_select(index + 1)


func _on_delete() -> void:
	var l := _level()
	var t := l.title if l.title != "" else "(untitled)"
	_delete_dialog.title = "Delete level"
	_delete_dialog.dialog_text = "Delete level %d \"%s\"?\nIts file is removed the next time you Save All." % [index + 1, t]
	_delete_dialog.popup_centered()


func _delete_current() -> void:
	levels.remove_at(index)
	if levels.is_empty():
		levels.append(_new_level())
	dirty = true
	_refresh_list()
	_select(index)


func _on_move(direction: int) -> void:
	var j := index + direction
	if j < 0 or j >= levels.size():
		return
	var tmp := levels[index]
	levels[index] = levels[j]
	levels[j] = tmp
	dirty = true
	_refresh_list()
	_select(j)


func _on_import() -> void:
	_import_dialog.current_dir = "res://"
	_import_dialog.popup_centered_ratio(0.6)


func _on_files_imported(paths: PackedStringArray) -> void:
	var count := 0
	for path in paths:
		var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if res is LevelData:
			levels.insert(index + 1 + count, _copy_level(res))
			count += 1
		else:
			push_warning("Import skipped (not a LevelData): %s" % path)
	if count > 0:
		dirty = true
		_refresh_list()
		_select(index + 1)
	_set_status("Imported %d level(s)." % count)


func _on_add_samples() -> void:
	var samples := LevelData.sample_levels()
	for s in samples:
		levels.append(s)
	dirty = true
	_refresh_list()
	_select(levels.size() - samples.size())
	_set_status("Added %d built-in sample level(s)." % samples.size())


## Generate a batch of levels and insert them after the selected one. Each level is
## designed, then calibrated by simulated play (see level_generator.gd), which takes a
## moment, so this yields to the UI between attempts.
func _on_generate() -> void:
	if _generating:
		return
	_generating = true
	_gen_button.disabled = true

	var n := int(_gen_count.value)
	var lo := int(minf(_gen_from.value, _gen_to.value))
	var hi := int(maxf(_gen_from.value, _gen_to.value))
	var gen := LevelGenerator.new()
	var made: Array[LevelData] = []
	var failed := 0
	var avoid := -2

	for i in n:
		var d := LevelGenerator.batch_difficulty(i, n, lo, hi)
		var result := {}
		for attempt in LevelGenerator.MAX_ATTEMPTS:
			_set_status("Generating level %d of %d (difficulty %d), attempt %d..." % [i + 1, n, d, attempt + 1])
			await get_tree().process_frame
			result = gen.try_generate(d, avoid)
			if result["level"] != null:
				break
		if result["level"] == null:
			failed += 1
			continue
		var level: LevelData = result["level"]
		made.append(level)
		avoid = result["headline"]
		print("Generated %s: %d moves, bot win rate %d%%" % [level.title, level.moves, roundi(100.0 * result["win_rate"])])

	_generating = false
	_gen_button.disabled = false
	if made.is_empty():
		_set_status("Couldn't generate any levels (%d failed)." % failed)
		return
	var at := clampi(index + 1, 0, levels.size())
	for k in made.size():
		levels.insert(at + k, made[k])
	dirty = true
	_refresh_list()
	_select(at)
	var msg := "Generated %d level(s). Play-test them before saving." % made.size()
	if failed > 0:
		msg += " %d couldn't be generated." % failed
	_set_status(msg)


# ---------- Editing, preview, validation ----------

## Call after any edit to the current level.
func _changed() -> void:
	dirty = true
	_list.set_item_text(index, _list_text(index))
	_rebuild_preview()
	_update_title()


func _on_reroll() -> void:
	preview_seed = randi_range(1, 2147483647)
	_rebuild_preview()


func _rebuild_preview() -> void:
	var l := _level()
	if l == null:
		return
	var board := Board.new(l, preview_seed)
	_preview.board = board
	_preview.queue_redraw()
	_update_stats(board, l)
	_update_problems(l)


func _update_stats(board: Board, l: LevelData) -> void:
	var anchors := 0
	for col in board.grid:
		for v in col:
			if v == Board.ANCHOR:
				anchors += 1
	var lines: Array[String] = []
	lines.append("%d x %d grid, %s" % [board.cols, board.rows,
			"unlimited moves" if l.moves <= 0 else "%d moves" % l.moves])
	if l.anchor_count > 0:
		lines.append(_placed("Anchors", anchors, l.anchor_count))
	if l.ice_count > 0:
		lines.append(_placed("Ice", board.ice_total, l.ice_count))
	if l.rock_count > 0:
		lines.append(_placed("Rocks", board.rock_total, l.rock_count))
	if l.blanks:
		lines.append(_placed("Blank cells", board.blank_set.size(), Board.BLANK_GROUP_SIZE))
	if l.bomb_count > 0:
		lines.append("Bombs: up to %d at once, %d-move fuse (they spawn during play, so none are shown)" % [l.bomb_count, l.bomb_fuse])
	if l.active_goals().is_empty():
		lines.append("No goals: score attack until the moves run out.")
	_stats_label.text = "\n".join(lines)


func _placed(label: String, placed: int, wanted: int) -> String:
	if placed < wanted:
		return "%s: %d placed (%d requested, not enough room)" % [label, placed, wanted]
	return "%s: %d placed" % [label, placed]


func _update_problems(l: LevelData) -> void:
	var problems := l.validate()
	if problems.is_empty():
		_problems_label.text = "No problems found."
		_problems_label.modulate = Color("#06d6a0")
	else:
		var lines: Array[String] = []
		for p in problems:
			lines.append("- " + p)
		_problems_label.text = "\n".join(lines)
		_problems_label.modulate = Color("#ffb347")


# ---------- Saving and testing ----------

func _save_all() -> bool:
	var err := LevelLibrary.save_all(levels)
	if err != OK:
		_set_status("Save failed: %s" % error_string(err))
		return false
	dirty = false
	var flagged := 0
	for l in levels:
		if not l.validate().is_empty():
			flagged += 1
	var msg := "Saved %d level(s) to %s." % [levels.size(), LevelLibrary.DIR]
	if flagged > 0:
		msg += "  %d with warnings [!]" % flagged
	_set_status(msg)
	_update_title()
	return true


func _test_play() -> void:
	Global.builder_levels = levels
	Global.builder_index = index
	Global.builder_dirty = dirty
	Global.test_level = _level()
	_restore_window()
	get_tree().change_scene_to_file(main_scene_path)


func _on_quit_save() -> void:
	if _save_all():
		get_tree().quit()


func _on_quit_action(action: StringName) -> void:
	if action == &"discard":
		get_tree().quit()


func _set_status(text: String) -> void:
	_status_label.text = text


# ---------- Preview drawing ----------

## Draws a Board's starting grid. Colored dots, anchors, rocks, ice overlays and blanks.
class BoardPreview extends Control:
	var board: Board
	var palette: Array[Color] = []

	func _draw() -> void:
		if board == null:
			return
		var cols := board.cols
		var rows := board.rows
		var cell := minf(size.x / cols, size.y / rows)
		var origin := (size - Vector2(cols, rows) * cell) * 0.5
		draw_rect(Rect2(origin, Vector2(cols, rows) * cell), Color(0.13, 0.14, 0.19))

		var font := ThemeDB.fallback_font
		var font_size := int(clampf(cell * 0.3, 8.0, 28.0))
		for c in cols:
			for r in rows:
				var p := Vector2i(c, r)
				var rect := Rect2(origin + Vector2(c, r) * cell, Vector2(cell, cell))
				var mid := rect.get_center()
				var v: int = board.grid[c][r]
				if v == Board.BLANK:
					draw_rect(rect, Color(0.03, 0.03, 0.05))
					var a := rect.position + Vector2(cell, cell) * 0.25
					var b := rect.end - Vector2(cell, cell) * 0.25
					draw_line(a, b, Color(0.3, 0.3, 0.36), 2.0)
					draw_line(Vector2(a.x, b.y), Vector2(b.x, a.y), Color(0.3, 0.3, 0.36), 2.0)
				elif v >= 0 and v < palette.size():
					draw_circle(mid, cell * 0.3, palette[v])
				elif v == Board.ANCHOR:
					var radius := cell * 0.3
					draw_colored_polygon(PackedVector2Array([
						mid + Vector2(0, -radius), mid + Vector2(radius, 0),
						mid + Vector2(0, radius), mid + Vector2(-radius, 0)]),
						Color(0.92, 0.92, 0.92))
					_center_text(font, rect, "A", font_size, Color.BLACK)
				elif v == Board.ROCK:
					draw_rect(rect.grow(-cell * 0.1), Color(0.5, 0.5, 0.53))
					_center_text(font, rect, str(board.get_rock(p)), font_size, Color.WHITE)

				var ice_health := board.get_ice(p)
				if ice_health > 0:
					draw_rect(rect.grow(-2.0), Color(0.55, 0.85, 1.0, 0.35))
					draw_rect(rect.grow(-2.0), Color(0.7, 0.92, 1.0, 0.95), false, 2.0)
					draw_string(font, Vector2(rect.position.x + cell * 0.05, rect.end.y - cell * 0.1),
							str(ice_health), HORIZONTAL_ALIGNMENT_RIGHT, cell * 0.9,
							int(font_size * 0.8), Color(0.85, 0.96, 1.0))

	func _center_text(font: Font, rect: Rect2, text: String, font_size: int, color: Color) -> void:
		draw_string(font, Vector2(rect.position.x, rect.get_center().y + font_size * 0.35),
				text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, font_size, color)
