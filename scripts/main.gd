extends Node2D
## View + input for the dots game. All rules live in Board (board.gd).
## Attach to a Node2D root in main.tscn.
##
## Node layout (built in code):
##   Main (this node)  -> draws the background
##   |- DotsRoot       -> one Sprite2D per grid cell, tinted via modulate
##   |- IceRoot        -> ice sprites over their cells
##   |- Overlay        -> HUD (hides dots spawning above the grid), chain line, end screen
##
## Grid size, colors, moves, anchors, ice and goals all come from a LevelData resource.

## Levels, played in order. Create them in the FileSystem dock (New Resource -> LevelData)
## and assign them here. Leave empty to use the built-in sample levels.
@export var levels: Array[LevelData] = []
## Index of the level to start on (handy for testing a specific level).
@export var first_level := 0
@export var margin := 24.0
@export var hud_height := 140.0
## A WHITE dot texture; it gets tinted per color. Leave empty to use a generated placeholder.
@export var dot_texture: Texture2D
## Anchor sprite (drawn untinted). Leave empty to load res://assets/anchor.png.
@export var anchor_texture: Texture2D
## Ice sprite sheet: a horizontal strip where frame N shows ice with N health left
## (frame 0 = blank/unused, then health 1, 2, 3). Leave empty to load res://assets/ice.png.
@export var ice_texture: Texture2D
@export var ice_hframes := 4
## Rock sprite. Leave empty to load res://assets/rock.png, or fall back to a grey square.
## Either a single static image (set rock_hframes to 1; it darkens as health drops), or a
## horizontal sheet where frame N shows N health left (frame 0 unused), like the ice sheet.
@export var rock_texture: Texture2D
@export var rock_hframes := 4

## The three power-up buttons (assign in the inspector).
@onready var remove_dot_button: TextureButton = $HBoxContainer/remove_dot_button
@onready var remove_color_button: TextureButton = $HBoxContainer/remove_color_button
@onready var shuffle_button: TextureButton = $HBoxContainer/shuffle_board_button

#enum PowerUp { NONE, REMOVE_DOT, REMOVE_COLOR, SHUFFLE }
#const START_POWER_UPS := 3
const ACTIVE_TINT := Color("#ffd166")
#
#var power_ups := {}  # PowerUp -> uses left. Not reset by new_game(), so it carries across levels/retries.
#var active_power_up := PowerUp.NONE
var active_power_up := Global.PowerUp.NONE

const PALETTE: Array[Color] = [
	Color("#ef476f"), Color("#ffd166"), Color("#06d6a0"),
	Color("#118ab2"), Color("#9b5de5"), Color("#f78c3b"),
]
const DOT_SCALE := 0.75   # dot diameter as a fraction of the cell size
const FALL_SPEED := 8.0  # cells per second
const POP_UP_TIME := 0.06    # removed dots swell slightly...
const POP_DOWN_TIME := 0.14  # ...then shrink and fade out
const POP_SWELL := 1.3
const SELECT_SCALE := 1.15  # dots in the current chain are drawn this much larger
const ANCHOR_PATH := "res://assets/anchor.png"
const ANCHOR_SCALE := 0.8  # anchor's longest side as a fraction of the cell size
const ROCK_PATH := "res://assets/rock.png"
const ROCK_SCALE := 0.88   # rock frame's longest side as a fraction of the cell size
const ICE_PATH := "res://assets/ice.png"
const ICE_SCALE := 0.95   # ice frame's longest side as a fraction of the cell size
const ICE_BREAK_TIME := 0.22
const NO_CELL := Vector2i(-1, -1)

@onready var game_menu: PopupMenu = $game_menu


var level_list: Array[LevelData] = []
var level_index := 0
var level: LevelData
var cols := 8  # taken from the current level
var rows := 8
var board: Board
var tex: Texture2D
var anchor_tex: Texture2D
var rock_tex: Texture2D
var ice_tex: Texture2D
var ice_root: Node2D
var ice_sprites := {}  # Vector2i -> Sprite2D, only for cells that started with ice
var dots_root: Node2D
var overlay: Node2D
var sprites: Array = []  # sprites[col][row] = Sprite2D
var offset: Array = []   # offset[col][row] = visual y offset in px (negative = above)
var cell := 64.0
var origin := Vector2.ZERO
var dragging := false
var animating := false
var result_recorded := false  # true once this attempt's win has been saved


func _ready() -> void:
	tex = dot_texture if dot_texture != null else _make_dot_texture()
	if anchor_texture != null:
		anchor_tex = anchor_texture
	elif ResourceLoader.exists(ANCHOR_PATH):
		anchor_tex = load(ANCHOR_PATH)
	else:
		anchor_tex = _make_anchor_texture()  # placeholder until the art exists
	if rock_texture != null:
		rock_tex = rock_texture
	elif ResourceLoader.exists(ROCK_PATH):
		rock_tex = load(ROCK_PATH)
	else:
		rock_tex = _make_rock_texture()  # grey-square placeholder until the art exists
		rock_hframes = 4  # the placeholder is a 4-frame sheet
	if ice_texture != null:
		ice_tex = ice_texture
	elif ResourceLoader.exists(ICE_PATH):
		ice_tex = load(ICE_PATH)
	else:
		ice_tex = _make_ice_texture()  # placeholder until the art exists

	dots_root = Node2D.new()
	dots_root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(dots_root)

	ice_root = Node2D.new()  # above the dots, below the chain line
	ice_root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR  # no mipmaps: they'd bleed between sheet frames
	add_child(ice_root)

	overlay = Node2D.new()
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)  # added last, so it draws above the dots

	#if Global.test_level == null:  # Test Play returns to the builder instead
		#var levels_button := Button.new()
		#levels_button.text = "Levels"
		#levels_button.position = Vector2(margin, margin)
		#levels_button.pressed.connect(_open_level_select)
		#add_child(levels_button)  # a Control, so it eats its own clicks

	get_viewport().size_changed.connect(_layout)

	if Global.test_level != null:
		level_list.append(Global.test_level)  # launched from the builder's Test Play
		level_index = 0
	else:
		for l in levels:  # the export array still works as an override
			if l != null:
				level_list.append(l)
		if level_list.is_empty():
			level_list = LevelLibrary.load_all()  # res://levels/level_01.tres, level_02.tres, ...
		if level_list.is_empty():
			level_list = LevelData.sample_levels()
		# Chosen from the level-select screen, else the inspector's first_level.
		var start := Global.selected_level if Global.selected_level >= 0 else first_level
		level_index = clampi(start, 0, level_list.size() - 1)

	#for l in levels:
		#if l != null:
			#level_list.append(l)
	#if level_list.is_empty():
		#level_list = LevelData.sample_levels()
	#level_index = clampi(first_level, 0, level_list.size() - 1)
	Global.power_ups_changed.connect(_update_power_up_buttons)
	game_menu.id_pressed.connect(_on_game_menu_pressed)
	new_game()


## (Re)start the current level.
func new_game() -> void:
	level = level_list[level_index]
	for problem in level.validate():
		push_warning("Level %d (%s): %s" % [level_index + 1, level.title, problem])
	cols = maxi(level.cols, 2)
	rows = maxi(level.rows, 2)
	board = Board.new(level)
	dragging = false
	animating = false
	result_recorded = false
	
	active_power_up = Global.PowerUp.NONE
	_update_power_up_buttons()
	
	# One sprite per starting ice cell. Ice never moves, so these are static.
	for child in ice_root.get_children():
		child.queue_free()
	ice_sprites.clear()
	for c in cols:
		for r in rows:
			var p := Vector2i(c, r)
			if board.get_ice(p) > 0:
				var ice_spr := Sprite2D.new()
				ice_spr.texture = ice_tex
				ice_spr.hframes = ice_hframes
				ice_root.add_child(ice_spr)
				ice_sprites[p] = ice_spr

	for child in dots_root.get_children():
		child.queue_free()
	sprites.clear()
	offset.clear()
	for c in cols:
		var sprite_col := []
		var offset_col := []
		offset_col.resize(rows)
		offset_col.fill(0.0)
		for r in rows:
			var spr := Sprite2D.new()
			spr.texture = tex
			dots_root.add_child(spr)
			sprite_col.append(spr)
		sprites.append(sprite_col)
		offset.append(offset_col)
	_layout()


func _layout() -> void:
	if board == null:
		return
	var size := get_viewport_rect().size
	var avail := Vector2(size.x - margin * 2.0, size.y - margin * 2.0 - hud_height)
	cell = minf(avail.x / cols, avail.y / rows)
	origin = Vector2(margin, margin + hud_height) + (avail - Vector2(cols, rows) * cell) * 0.5
	for p in ice_sprites:  # ice is static, so position/scale only change on layout
		var spr: Sprite2D = ice_sprites[p]
		spr.position = _center(p)
		spr.scale = Vector2.ONE * _ice_scale()
	_redraw()


func _center(p: Vector2i) -> Vector2:
	return origin + (Vector2(p) + Vector2(0.5, 0.5)) * cell


func _redraw() -> void:
	_sync_sprites()
	_sync_ice()
	queue_redraw()
	overlay.queue_redraw()


## Scale that fits one ice frame's longest side to ICE_SCALE of a cell.
func _ice_scale() -> float:
	var frame := Vector2(float(ice_tex.get_width()) / ice_hframes, ice_tex.get_height())
	return cell * ICE_SCALE / maxf(frame.x, frame.y)


## Show the frame matching each ice cell's remaining health; hide broken ice.
## (Only frame/visibility here, so hit/break tweens on scale/modulate aren't overridden.)
func _sync_ice() -> void:
	for p in ice_sprites:
		var health := board.get_ice(p)
		var spr: Sprite2D = ice_sprites[p]
		spr.visible = health > 0
		spr.frame = mini(health, ice_hframes - 1)


## Push board state + animation offsets onto the sprites.
func _sync_sprites() -> void:
	var s := cell * DOT_SCALE / tex.get_width()
	var square := board.is_closed()
	for c in cols:
		for r in rows:
			var p := Vector2i(c, r)
			var v := board.get_color(p)
			var spr: Sprite2D = sprites[c][r]
			spr.visible = v != Board.EMPTY and v != Board.BLANK  # blanks are holes: draw nothing
			if not spr.visible:
				continue
			spr.position = _center(p) + Vector2(0.0, offset[c][r])
			if v == Board.ROCK:
				var health := board.get_rock(p)
				spr.texture = rock_tex
				spr.hframes = rock_hframes
				spr.frame = mini(health, rock_hframes - 1)
				# A single static sprite darkens as it takes damage.
				spr.modulate = Color.WHITE if rock_hframes > 1 \
						else Color.WHITE.darkened(0.2 * (board.rock_health - health))
				spr.scale = Vector2.ONE * _rock_scale()
				continue
			if spr.hframes != 1:  # this sprite may have been a rock earlier
				spr.hframes = 1
				spr.frame = 0
			if v == Board.ANCHOR:
				spr.texture = anchor_tex
				spr.modulate = Color.WHITE
				spr.scale = Vector2.ONE * _anchor_scale()
				continue
			spr.texture = tex
			var col := PALETTE[v]
			# A square lights up every dot of its color (no outline needed).
			if square and v == board.chain_color:
				col = col.lightened(0.5)
			spr.modulate = col
			# Dots in the current chain are slightly enlarged.
			var in_chain := board.is_selecting() and p in board.chain
			spr.scale = Vector2(s, s) * (SELECT_SCALE if in_chain else 1.0)


## Scale that fits the anchor sprite's longest side to ANCHOR_SCALE of a cell.
func _anchor_scale() -> float:
	var size := anchor_tex.get_size()
	return cell * ANCHOR_SCALE / maxf(size.x, size.y)


## Scale that fits one rock frame's longest side to ROCK_SCALE of a cell.
func _rock_scale() -> float:
	var frame := Vector2(float(rock_tex.get_width()) / rock_hframes, rock_tex.get_height())
	return cell * ROCK_SCALE / maxf(frame.x, frame.y)


## A throwaway copy of a rock frame at cell p, used for the hit/break effects.
func _rock_ghost(p: Vector2i, health: int) -> Sprite2D:
	var ghost := Sprite2D.new()
	ghost.texture = rock_tex
	ghost.hframes = rock_hframes
	ghost.frame = mini(health, rock_hframes - 1)
	ghost.position = _center(p)
	ghost.scale = Vector2.ONE * _rock_scale()
	ice_root.add_child(ghost)  # above the dots
	return ghost


## Rock hit but still standing: a quick white flash.
func _flash_rock(p: Vector2i, health: int) -> void:
	var ghost := _rock_ghost(p, health)
	ghost.modulate = Color(2, 2, 2, 0.8)
	var t := ghost.create_tween()
	t.tween_property(ghost, "modulate:a", 0.0, 0.15)
	t.tween_callback(ghost.queue_free)


## Rock destroyed: its last frame swells and fades out.
func _spawn_rock_break(p: Vector2i) -> void:
	var ghost := _rock_ghost(p, 1)
	var t := ghost.create_tween()
	t.tween_property(ghost, "scale", ghost.scale * 1.3, 0.2) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(ghost, "modulate:a", 0.0, 0.2)
	t.tween_callback(ghost.queue_free)


## Once per attempt, when the end screen is about to show: save a win and its score.
## Test Play from the builder never touches the save.
func _check_finished() -> void:
	if result_recorded or not board.is_finished():
		return
	result_recorded = true
	if board.won and Global.test_level == null:
		Progress.record_win(level, level_index, board.score)


func _on_menu_button_pressed() -> void:
	game_menu.visible = true

func _open_level_select() -> void:
	game_menu.visible = true

func _on_game_menu_pressed(id: int):
	if id == 0:
		_go_to_levels()
	else:
		get_tree().reload_current_scene()
func _go_to_levels() -> void:
	get_tree().change_scene_to_file(Global.LEVEL_SELECT_SCENE)
	

# ---------- Input (touch is emulated as mouse by default) ----------

func _unhandled_input(event: InputEvent) -> void:
	if Global.test_level != null and event.is_action_pressed("ui_cancel"):
		get_tree().change_scene_to_file(Global.BUILDER_SCENE)
		return
	if animating:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if board.is_finished():
				if board.won:  # win -> next level; after the last, back to level select
					if Global.test_level == null and level_index + 1 >= level_list.size():
						_open_level_select()
						return
					level_index = (level_index + 1) % level_list.size()
				new_game()     # loss -> retry the same level
				return
			
			var p := _cell_at(event.position)
			if active_power_up != Global.PowerUp.NONE:
				if p != NO_CELL:
					_use_power_up(p)
				return  # while a power-up is armed, a click never starts a chain
			if p != NO_CELL and board.begin(p):
				dragging = true
				_redraw()
		elif dragging:
			dragging = false
			_commit()
	elif event is InputEventMouseMotion and dragging:
		var p := _cell_at(event.position)
		if p != NO_CELL and board.extend(p):
			_redraw()


## Screen position -> cell. Circular hit area so diagonal drags don't grab neighbors.
func _cell_at(pos: Vector2) -> Vector2i:
	var rel := (pos - origin) / cell
	var p := Vector2i(floori(rel.x), floori(rel.y))
	if not board.in_bounds(p):
		return NO_CELL
	if pos.distance_to(_center(p)) > cell * 0.45:
		return NO_CELL
	return p



func _commit() -> void:
	var res := board.commit()
	if res == null:
		_redraw()
		return
	_play_result(res)


## Spawn all the pop/fall/ice/rock/bomb effects for a Result, then start animating.
func _play_result(res: Board.Result) -> void:
	# (everything that was after the null check in _commit, unchanged,
	#  from "# Removed dots pop out where they were..." down to _redraw())

	for p in res.removed:
		# A defused bomb pops white so you can see it went off safely.
		_spawn_pop(p, Color.WHITE if p in res.bomb_defused_cells else PALETTE[res.color])
	for p in res.bomb_exploded_cells:
		_spawn_explosion(p)
	# ...while the remaining/new dots start above their final position and fall.
	for p in res.fall:
		offset[p.x][p.y] = -res.fall[p] * cell
	# Anchors that reached the bottom fall in, then drop off the board.
	for e in res.exits:
		_spawn_exit(e["cell"], e["fell"])
	# Ice over cleared dots: cracks (brief flash) or breaks (shatter ghost).
	for p in res.ice_hit_cells:
		_flash_ice(p)
	for p in res.ice_broken_cells:
		_spawn_ice_break(p)
	# Rocks next to cleared dots: flash if still standing, shatter if destroyed.
	for h in res.rock_hits:
		_flash_rock(h["cell"], h["health"])
	for p in res.rock_broken_cells:
		_spawn_rock_break(p)
	animating = true
	_redraw()


## A bomb ran out of fuse: an orange burst grows over its cell and fades.
func _spawn_explosion(p: Vector2i) -> void:
	var blast := Sprite2D.new()
	blast.texture = tex
	blast.modulate = Color(1.0, 0.45, 0.15, 0.9)
	blast.position = _center(p)
	var base := Vector2.ONE * (cell * DOT_SCALE / tex.get_width())
	blast.scale = base
	ice_root.add_child(blast)  # above the dots

	var t := blast.create_tween()
	t.tween_property(blast, "scale", base * 3.5, 0.4) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(blast, "modulate:a", 0.0, 0.4)
	t.tween_callback(blast.queue_free)


## Brief brightening when ice is hit. The frame itself changes in _sync_ice().
func _flash_ice(p: Vector2i) -> void:
	var spr: Sprite2D = ice_sprites.get(p)
	if spr == null:
		return
	spr.modulate = Color(1.8, 1.8, 1.8)
	spr.create_tween().tween_property(spr, "modulate", Color.WHITE, 0.2)


## The real ice sprite is hidden once health hits 0, so a ghost of its last
## frame (health 1) swells and fades out in its place.
func _spawn_ice_break(p: Vector2i) -> void:
	var ghost := Sprite2D.new()
	ghost.texture = ice_tex
	ghost.hframes = ice_hframes
	ghost.frame = mini(1, ice_hframes - 1)
	ghost.position = _center(p)
	ghost.scale = Vector2.ONE * _ice_scale()
	ice_root.add_child(ghost)

	var t := ghost.create_tween()
	t.tween_property(ghost, "scale", ghost.scale * 1.35, ICE_BREAK_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(ghost, "modulate:a", 0.0, ICE_BREAK_TIME)
	t.tween_callback(ghost.queue_free)


## Ghost anchor: falls from where it was to the bottom row at the same speed as the
## dots, keeps going one more cell, and fades out. The grid no longer holds it.
func _spawn_exit(p: Vector2i, fell: int) -> void:
	var ghost := Sprite2D.new()
	ghost.texture = anchor_tex
	ghost.scale = Vector2.ONE * _anchor_scale()
	var landing := _center(p)
	ghost.position = landing - Vector2(0.0, fell * cell)
	dots_root.add_child(ghost)

	var fall_time := fell / FALL_SPEED
	var exit_time := 1.0 / FALL_SPEED
	var t := ghost.create_tween()
	t.tween_property(ghost, "position:y", landing.y + cell, fall_time + exit_time)
	t.parallel().tween_property(ghost, "modulate:a", 0.0, exit_time).set_delay(fall_time)
	t.tween_callback(ghost.queue_free)


## A throwaway sprite that swells, then shrinks and fades, then frees itself.
## The real sprite at this cell already shows the new dot, so this is a ghost.
func _spawn_pop(p: Vector2i, color: Color) -> void:
	var ghost := Sprite2D.new()
	ghost.texture = tex
	ghost.modulate = color
	ghost.position = _center(p)
	var base := Vector2.ONE * (cell * DOT_SCALE / tex.get_width())
	ghost.scale = base
	dots_root.add_child(ghost)  # added after the cell sprites, so it draws above them

	var t := ghost.create_tween()  # tied to the ghost, so it dies with it
	t.tween_property(ghost, "scale", base * POP_SWELL, POP_UP_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(ghost, "scale", Vector2.ZERO, POP_DOWN_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t.parallel().tween_property(ghost, "modulate:a", 0.0, POP_DOWN_TIME)
	t.tween_callback(ghost.queue_free)


func _process(delta: float) -> void:
	if not animating:
		return
	var moving := false
	for c in cols:
		for r in rows:
			var o: float = offset[c][r]
			if o < 0.0:
				offset[c][r] = minf(o + cell * FALL_SPEED * delta, 0.0)
				moving = true
	animating = moving
	_sync_sprites()
	overlay.queue_redraw()  # bomb counters are drawn there and must follow the falling dots
	if not animating:
		_redraw()  # shows the game-over screen if the last move just finished
		_check_finished()


# ---------- Drawing ----------

const BG_COLOR := Color("#1d1f2b")


## Background only. The HUD is drawn in the overlay instead, so it can cover dots
## that spawn above the grid (otherwise they'd be seen sliding over the HUD).
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), BG_COLOR)


## HUD, chain line and end screen (drawn above the dot sprites).
## Note: draw calls must go through `overlay`, not `self`.
func _draw_overlay() -> void:
	_draw_bomb_counters()  # before the HUD strip, which covers anything above the grid
	_draw_hud()

	if board.is_selecting() and board.chain.size() >= 2:
		var pts := PackedVector2Array()
		for p in board.chain:
			pts.append(_center(p))
		var col := PALETTE[board.chain_color]
		var width := cell * 0.12
		overlay.draw_polyline(pts, col, width, true)
		# Closing link: from the dot that completed the loop back to the dot it touched.
		# (Not necessarily the last chain dot if the player kept dragging.)
		if board.is_closed():
			overlay.draw_line(_center(board.chain[board.close_len - 1]),
					_center(board.close_to), col, width, true)

	if board.is_finished() and not animating:
		_draw_end_screen()


## Countdown badge on every bomb dot. It uses the same fall offset as the dot sprite,
## so it travels with the dot; red when 2 or fewer moves remain.
func _draw_bomb_counters() -> void:
	var font := ThemeDB.fallback_font
	var font_size := int(cell * 0.3)
	for c in cols:
		for r in rows:
			var p := Vector2i(c, r)
			var fuse := board.get_bomb(p)
			if fuse <= 0:
				continue
			var pos := _center(p) + Vector2(0.0, offset[c][r])
			overlay.draw_circle(pos, cell * 0.2, Color(0.08, 0.08, 0.12, 0.85))
			overlay.draw_string(font, pos + Vector2(-cell * 0.5, font_size * 0.35), str(fuse),
					HORIZONTAL_ALIGNMENT_CENTER, cell, font_size,
					Color("#ff4d4d") if fuse <= 2 else Color.WHITE)


## Title, score/moves and one chip per goal: icon + progress ("3/10", green once met).
func _draw_hud() -> void:
	var size := get_viewport_rect().size
	var font := ThemeDB.fallback_font
	# Opaque strip above the grid: hides dots that spawn above the board.
	overlay.draw_rect(Rect2(0.0, 0.0, size.x, origin.y), BG_COLOR)

	var title := level.title if level.title != "" else "Level %d" % (level_index + 1)
	overlay.draw_string(font, Vector2(0, margin + 22), title,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 24, Color(1, 1, 1, 0.6))
	var info := "Score %d" % board.score
	if board.has_move_limit():
		info += "      Moves %d" % board.moves_left
	overlay.draw_string(font, Vector2(0, margin + 56), info,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 30, Color.WHITE)

	var n := board.goals.size()
	if n == 0:
		return
	var chip_w := minf(140.0, (size.x - margin * 2.0) / n)
	var left := (size.x - chip_w * n) * 0.5
	for i in n:
		var rect := Rect2(left + chip_w * i + 8.0, margin + 72.0, 40.0, 40.0)
		_draw_goal_icon(board.goals[i], rect)
		var color := Color("#06d6a0") if board.goal_met(i) else Color.WHITE
		overlay.draw_string(font, Vector2(rect.end.x + 8.0, rect.position.y + 29.0),
				"%d/%d" % [board.goal_progress(i), board.goal_target(i)],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 24, color)


func _draw_goal_icon(g: GoalData, rect: Rect2) -> void:
	match g.type:
		GoalData.Type.COLOR:
			overlay.draw_texture_rect(tex, rect, false, PALETTE[g.color])
		GoalData.Type.ANCHOR:
			overlay.draw_texture_rect(anchor_tex, _fit(anchor_tex.get_size(), rect), false)
		GoalData.Type.ICE:
			# Show the full-health frame (the last one) on a faint backing so it's visible.
			var frame_w := float(ice_tex.get_width()) / ice_hframes
			var src := Rect2(frame_w * (ice_hframes - 1), 0.0, frame_w, ice_tex.get_height())
			overlay.draw_rect(rect, Color(1, 1, 1, 0.12))
			overlay.draw_texture_rect_region(ice_tex, _fit(src.size, rect), src)
		GoalData.Type.ROCK:
			# Full-health frame (the last one) of the rock sprite.
			var frame_w := float(rock_tex.get_width()) / rock_hframes
			var src := Rect2(frame_w * (rock_hframes - 1), 0.0, frame_w, rock_tex.get_height())
			overlay.draw_texture_rect_region(rock_tex, _fit(src.size, rect), src)
		GoalData.Type.BOMB:
			# A gray dot with the same dark badge + fuse number the bombs use on the board.
			overlay.draw_texture_rect(tex, rect, false, Color("#8d99ae"))
			overlay.draw_circle(rect.get_center(), rect.size.x * 0.28, Color(0.08, 0.08, 0.12, 0.85))
			overlay.draw_string(ThemeDB.fallback_font,
					Vector2(rect.position.x, rect.get_center().y + 7.0), str(level.bomb_fuse),
					HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 20, Color.WHITE)


## `src` scaled to fit inside `rect`, keeping its aspect ratio, centered.
func _fit(src: Vector2, rect: Rect2) -> Rect2:
	var k := minf(rect.size.x / src.x, rect.size.y / src.y)
	var fitted := src * k
	return Rect2(rect.position + (rect.size - fitted) * 0.5, fitted)


func _draw_end_screen() -> void:
	var size := get_viewport_rect().size
	var font := ThemeDB.fallback_font
	var headline := "Level complete!"
	if not board.won:
		headline = "Bomb exploded!" if board.exploded else "Out of moves!"
	var prompt := "Tap to retry"
	if board.won:
		var last := Global.test_level == null and level_index == level_list.size() - 1
		prompt = "Tap for level select" if last else "Tap for next level"
	overlay.draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.6))
	overlay.draw_string(font, Vector2(0, size.y * 0.45), headline,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 56, Color.WHITE)
	overlay.draw_string(font, Vector2(0, size.y * 0.45 + 56), "Score %d" % board.score,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 32, Color.WHITE)
	overlay.draw_string(font, Vector2(0, size.y * 0.45 + 110), prompt,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 24, Color(1, 1, 1, 0.7))


# ---------- Placeholder art ----------

## White circle with light grayscale shading, so it can be tinted via modulate.
## Replace by assigning `dot_texture` in the inspector.
func _make_dot_texture() -> ImageTexture:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var center := Vector2(n, n) * 0.5
	var radius := n * 0.5 - 2.0
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(center)
			var a := clampf(radius - d + 0.5, 0.0, 1.0)  # ~1px antialiased edge
			var shade := 1.0 - 0.15 * clampf((y - n * 0.5) / (n * 0.5), 0.0, 1.0)
			img.set_pixel(x, y, Color(shade, shade, shade, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Placeholder 4-frame ice sheet (frame N = N health left; frame 0 blank).
## Translucent blue squares; lower health shows more diagonal cracks.
func _make_ice_texture() -> ImageTexture:
	var n := 64
	var img := Image.create(n * 4, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var body := Color(0.65, 0.88, 1.0, 0.5)
	var edge_color := Color(1, 1, 1, 0.8)
	for f in range(1, 4):
		var x0 := f * n
		for y in n:
			for x in n:
				var is_edge := x < 3 or y < 3 or x >= n - 3 or y >= n - 3
				img.set_pixel(x0 + x, y, edge_color if is_edge else body)
		for k in 3 - f:  # health 3 = no cracks, 2 = one, 1 = two
			var start := 14 + k * 18
			for i in n:
				if start + i < n:
					img.set_pixel(x0 + start + i, i, Color(1, 1, 1, 0.9))
	return ImageTexture.create_from_image(img)


## Placeholder rock sheet: grey squares, 4 frames (frame N = N health left, frame 0 unused).
## Lower health shows more dark cracks. Replace by assigning `rock_texture`.
func _make_rock_texture() -> ImageTexture:
	var n := 64
	var img := Image.create(n * 4, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var body := Color("#8d8d99")
	var edge := Color("#5c5c66")
	for f in range(1, 4):
		var x0 := f * n
		for y in n:
			for x in n:
				var is_edge := x < 4 or y < 4 or x >= n - 4 or y >= n - 4
				img.set_pixel(x0 + x, y, edge if is_edge else body)
		for k in 3 - f:  # health 3 = no cracks, 2 = one, 1 = two
			var start := 14 + k * 18
			for i in n:
				if start + i < n:
					img.set_pixel(x0 + start + i, i, Color("#2b2b33"))
	return ImageTexture.create_from_image(img)


## Plain gray square with a light border, used only if no anchor sprite is found.
func _make_anchor_texture() -> ImageTexture:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color("#8d99ae"))
	for i in n:
		for edge in 4:
			img.set_pixel(i, edge, Color.WHITE)
			img.set_pixel(i, n - 1 - edge, Color.WHITE)
			img.set_pixel(edge, i, Color.WHITE)
			img.set_pixel(n - 1 - edge, i, Color.WHITE)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

#power up buttons
# ---------- Power-ups ----------

#func reset_power_ups() -> void:
	#power_ups = {
		#PowerUp.REMOVE_DOT: START_POWER_UPS,
		#PowerUp.REMOVE_COLOR: START_POWER_UPS,
		#PowerUp.SHUFFLE: START_POWER_UPS,
	#}
	#active_power_up = PowerUp.NONE
	#_update_power_up_buttons()


# ---------- Power-ups (counts live in the Global autoload) ----------

func _on_remove_dot_button_pressed() -> void:
	_toggle_power_up(Global.PowerUp.REMOVE_DOT)


func _on_remove_color_button_pressed() -> void:
	_toggle_power_up(Global.PowerUp.REMOVE_COLOR)


func _on_shuffle_board_button_pressed() -> void:
	_toggle_power_up(Global.PowerUp.SHUFFLE)


## Press once to arm, press the same button again to disarm.
## Pressing a different button switches to that power-up.
func _toggle_power_up(kind: Global.PowerUp) -> void:
	if not animating and not dragging and not board.is_finished():
		if active_power_up == kind:
			active_power_up = Global.PowerUp.NONE
		elif Global.has_power_up(kind):
			active_power_up = kind
	_update_power_up_buttons()


## The player clicked cell p with a power-up armed.
func _use_power_up(p: Vector2i) -> void:
	var res: Board.Result = null
	match active_power_up:
		Global.PowerUp.REMOVE_DOT:
			res = board.power_remove_dot(p)
		Global.PowerUp.REMOVE_COLOR:
			res = board.power_remove_color(p)
		Global.PowerUp.SHUFFLE:
			if board.is_dot(p):
				res = board.power_shuffle()
	if res == null:
		return  # invalid target (anchor, rock, blank): stay armed, nothing spent
	var kind := active_power_up
	active_power_up = Global.PowerUp.NONE
	Global.use_power_up(kind)  # emits power_ups_changed, which refreshes the buttons
	_play_result(res)


func _update_power_up_buttons() -> void:
	var pairs := [
		[remove_dot_button, Global.PowerUp.REMOVE_DOT],
		[remove_color_button, Global.PowerUp.REMOVE_COLOR],
		[shuffle_button, Global.PowerUp.SHUFFLE],
	]
	for pair in pairs:
		var btn: TextureButton = pair[0]
		if btn == null:
			continue
		var kind: Global.PowerUp = pair[1]
		var left := Global.get_count(kind)
		var active := active_power_up == kind

		var badge: Label = btn.get_node_or_null("CountBadge")
		if badge == null:
			badge = _make_count_badge(btn)
		badge.text = str(left)

		btn.disabled = left <= 0
		btn.set_pressed_no_signal(active)
		if left <= 0:
			btn.modulate = Color(1, 1, 1, 0.4)
		elif active:
			btn.modulate = ACTIVE_TINT
		else:
			btn.modulate = Color.WHITE


## A count label pinned to the bottom-right of a button. It ignores the mouse,
## so clicks still reach the button underneath.
func _make_count_badge(btn: TextureButton) -> Label:
	var lbl := Label.new()
	lbl.name = "CountBadge"
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 8)
	btn.add_child(lbl)
	return lbl
