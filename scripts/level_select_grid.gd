extends Control
## OPTION A: paginated grid of levels, with swipe or arrow buttons to change page.
## Each cell is a card showing the level number, best score and a summary of the goals.
## Attach to a Control root (Layout -> Full Rect) in res://scenes/level_select_grid.tscn.
## The whole UI is built in code, so the scene needs no other nodes.

const GRID_COLS := 2
const GRID_ROWS := 4
const PAGE_SIZE := GRID_COLS * GRID_ROWS
const SWIPE_DISTANCE := 80.0  # px of horizontal drag that counts as a page swipe

const BG_COLOR := Color("#1d1f2b")
const CARD_COLOR := Color("#2a2d3e")
const LOCKED_BORDER := Color("#454a63")
const DONE_COLOR := Color("#06d6a0")     # beaten
const BEST_COLOR := Color("cb796cff") 
const CURRENT_COLOR := Color("#ffd166")  # next level to play
const TEXT_COLOR := Color("#e8e9f0")
const DIM_TEXT_COLOR := Color("#9a9db3")

## Swatch colors for color goals, indexed by GoalData.color.
## PLACEHOLDER: replace with your board's dot palette (e.g. point this at the same array).
const GOAL_COLORS: Array[Color] = [
	Color("#ef476f"), Color("#ffd166"), Color("#06d6a0"),
	Color("#118ab2"), Color("#9b5de5"), Color("#f78c6b"),
]

var levels: Array[LevelData] = []
var page := 0
var page_count := 1
var swipe_start_x := 0.0

var grid: GridContainer
var page_label: Label
var prev_button: Button
var next_button: Button


func _ready() -> void:
	levels = LevelLibrary.load_all()  # res://levels/level_01.tres, level_02.tres, ...
	if levels.is_empty():
		levels = LevelData.sample_levels()
	page_count = maxi(ceili(levels.size() / float(PAGE_SIZE)), 1)
	_build_ui()
	# Open on the page that holds the level the player should play next.
	page = floori(Progress.current_index(levels) / float(PAGE_SIZE))
	_show_page()


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	var title := Label.new()
	title.text = "Select Level"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	column.add_child(title)

	# The grid takes all the space between the title and the page controls; its cards
	# stretch to fill, so the layout adapts to any screen size.
	grid = GridContainer.new()
	grid.columns = GRID_COLS
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	column.add_child(grid)

	var nav := HBoxContainer.new()
	nav.alignment = BoxContainer.ALIGNMENT_CENTER
	nav.add_theme_constant_override("separation", 24)
	column.add_child(nav)

	prev_button = Button.new()
	prev_button.text = "<"
	prev_button.custom_minimum_size = Vector2(80, 64)
	prev_button.pressed.connect(_change_page.bind(-1))
	nav.add_child(prev_button)

	page_label = Label.new()
	page_label.add_theme_font_size_override("font_size", 24)
	nav.add_child(page_label)

	next_button = Button.new()
	next_button.text = ">"
	next_button.custom_minimum_size = Vector2(80, 64)
	next_button.pressed.connect(_change_page.bind(1))
	nav.add_child(next_button)


func _show_page() -> void:
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	var current := Progress.current_index(levels)
	var first := page * PAGE_SIZE
	for slot in PAGE_SIZE:
		var i := first + slot
		# Pad the last page with empty cells so the cards keep the same size.
		grid.add_child(_make_cell(i, current) if i < levels.size() else _make_spacer())
	page_label.text = "%d / %d" % [page + 1, page_count]
	prev_button.disabled = page <= 0
	next_button.disabled = page >= page_count - 1


## One level card: a Button (so tap, disabled state and signals come for free) holding a
## header row (number + best score) and the goal summary. Child controls ignore the mouse
## so every tap and swipe reaches the button.
func _make_cell(i: int, current: int) -> Button:
	var level := levels[i]
	var unlocked := Progress.is_unlocked(levels, i)
	var completed := unlocked and Progress.is_completed(level, i)

	var accent := LOCKED_BORDER
	if completed:
		accent = DONE_COLOR
	elif unlocked and i == current:
		accent = CURRENT_COLOR
	elif unlocked:
		accent = DIM_TEXT_COLOR

	var b := Button.new()
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b.clip_contents = true
	b.focus_mode = Control.FOCUS_NONE
	_apply_card_style(b, accent)
	if not unlocked:
		b.disabled = true
		b.modulate = Color(1, 1, 1, 0.5)
	b.pressed.connect(_on_level_pressed.bind(i))

	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 16)
	b.add_child(pad)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 6)
	pad.add_child(box)

	# Header: level number on the left, best score on the right.
	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(header)

	var number := _label(str(i + 1), 34, accent if unlocked else DIM_TEXT_COLOR)
	number.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(number)

	var best_text := "Locked"
	var best_color := DIM_TEXT_COLOR
	if completed:
		best_text = "Best %d" % Progress.best_score(level, i)
		best_color = BEST_COLOR
	elif unlocked:
		best_text = "Best -"
	var best := _label(best_text, 22, best_color)
	best.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	best.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(best)

	# Goals are hidden on locked levels, so there's still something to discover.
	if unlocked:
		box.add_child(_make_goal_summary(level))
	return b


## One row per goal (up to LevelData.MAX_GOALS), or a "score attack" line when there are none.
func _make_goal_summary(level: LevelData) -> VBoxContainer:
	var list := VBoxContainer.new()
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.add_theme_constant_override("separation", 2)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var goals := level.active_goals()
	if goals.is_empty():
		list.add_child(_label("Score attack", 20, TEXT_COLOR))
		return list

	for g in goals:
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 8)
		list.add_child(row)
		# Every row starts with a same-size slot (swatch for color goals, empty otherwise)
		# so the goal text lines up down the card.
		var swatch := ColorRect.new()
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		swatch.custom_minimum_size = Vector2(20, 20)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if g.type == GoalData.Type.COLOR:
			swatch.color = GOAL_COLORS[g.color % GOAL_COLORS.size()]
		else:
			swatch.color = Color(0, 0, 0, 0)
		row.add_child(swatch)
		var text := _label(_goal_text(g), 20, TEXT_COLOR)
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.clip_text = true  # never wraps; trims with "..." if a goal is too long
		text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(text)
	return list


func _goal_text(g: GoalData) -> String:
	match g.type:
		GoalData.Type.COLOR:
			return "Clear %d" % g.amount  # the swatch beside it shows which color
		GoalData.Type.ANCHOR:
			return "Drop %d ANCHOR%s" % [g.amount, "" if g.amount == 1 else "S"]
		GoalData.Type.ICE:
			return "Break %d ICE" % g.amount
		GoalData.Type.BOMB:
			return "Defuse %d BOMB%s" % [g.amount, "" if g.amount == 1 else "S"]
		GoalData.Type.ROCK:
			return "Smash %d ROCK%s" % [g.amount, "" if g.amount == 1 else "S"]
	return "Goal x%d" % g.amount


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


## Rounded card with a colored border; the same look for every button state so the
## border color alone tells beaten / next / open / locked apart.
func _apply_card_style(b: Button, border: Color) -> void:
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var s := StyleBoxFlat.new()
		s.bg_color = CARD_COLOR
		s.set_corner_radius_all(14)
		s.set_border_width_all(3)
		s.border_color = border
		if state == "hover":
			s.bg_color = CARD_COLOR.lightened(0.08)
		elif state == "pressed":
			s.bg_color = CARD_COLOR.lightened(0.16)
		b.add_theme_stylebox_override(state, s)


func _make_spacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return s


func _change_page(delta: int) -> void:
	page = clampi(page + delta, 0, page_count - 1)
	_show_page()


func _on_level_pressed(i: int) -> void:
	Global.selected_level = i
	get_tree().change_scene_to_file(Global.MAIN_SCENE)


## Swipe left/right to change page (touch is emulated as mouse). _input sees the press
## and release even when they land on a button; a plain tap travels < SWIPE_DISTANCE.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			swipe_start_x = event.position.x
		else:
			var dx: float = event.position.x - swipe_start_x
			if absf(dx) > SWIPE_DISTANCE:
				_change_page(-1 if dx > 0.0 else 1)
