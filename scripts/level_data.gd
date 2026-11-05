class_name LevelData
extends Resource
## Configuration for one level. Create these as .tres files (FileSystem dock ->
## right-click -> New Resource -> LevelData) and assign them to Main's `levels` array.

const MAX_GOALS := 4

@export var title := ""  # optional; the HUD falls back to "Level N"
## Moves allowed. 0 = unlimited.
@export var moves := 20
@export_range(3, 6) var num_colors := 5
## Grid width (columns) and height (rows).
@export_range(3, 12) var cols := 8
@export_range(3, 14) var rows := 8
## Anchors at the start; also the most that can be on the board at once.
@export var anchor_count := 0
## Cells that start with ice over them.
@export var ice_count := 0
## Rocks placed at the start (replacing dots). They can't be selected, fall like anchors,
## and break after dots next to them have been cleared `rock_health` times.
@export var rock_count := 0
@export_range(1, 3) var rock_health := 2
## Most timed bombs allowed on the board at once. 0 = no bombs. They spawn randomly
## as the board refills (none at the start).
@export var bomb_count := 0
## Moves a bomb has before it explodes and you lose the level.
@export_range(1, 30) var bomb_fuse := 8
## Place a connected group of four blank cells ("holes") at the start, in a random shape
## and never on the bottom row. Dots fall through them; they can't be selected, dragged
## across, cleared, or counted toward goals.
@export var blanks := false
## Up to MAX_GOALS; extras are ignored. Reach all of them to win.
## With no goals the level is score-attack: play until the moves run out.
@export var goals: Array[GoalData] = []


## The goals that count: non-null, capped at MAX_GOALS.
func active_goals() -> Array[GoalData]:
	var out: Array[GoalData] = []
	for g in goals:
		if g != null and out.size() < MAX_GOALS:
			out.append(g)
	return out


## Human-readable problems that would make the level unwinnable or confusing.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if goals.size() > MAX_GOALS:
		problems.append("%d goals set; only the first %d are used." % [goals.size(), MAX_GOALS])
	for g in active_goals():
		match g.type:
			GoalData.Type.COLOR:
				if g.color >= num_colors:
					problems.append("Color goal uses color %d but the level only has %d colors." % [g.color, num_colors])
			GoalData.Type.ANCHOR:
				if anchor_count <= 0:
					problems.append("Anchor goal, but the level has no anchors.")
			GoalData.Type.ICE:
				if ice_count <= 0:
					problems.append("Ice goal, but the level has no ice.")
				elif g.amount > ice_count:
					problems.append("Ice goal of %d but only %d ice; it will be capped." % [g.amount, ice_count])
			GoalData.Type.BOMB:
				if bomb_count <= 0:
					problems.append("Bomb goal, but the level has no bombs.")
			GoalData.Type.ROCK:
				if rock_count <= 0:
					problems.append("Rock goal, but the level has no rocks.")
				elif g.amount > rock_count:
					problems.append("Rock goal of %d but only %d rocks; it will be capped." % [g.amount, rock_count])
	if blanks and cols * (rows - 1) < Board.BLANK_GROUP_SIZE:
		problems.append("Blanks are on, but there isn't room for %d of them above the bottom row." % Board.BLANK_GROUP_SIZE)
	return problems


static func create(p_title: String, p_moves: int, p_colors: int, p_cols: int, p_rows: int,
		p_anchors: int, p_ice: int, p_goals: Array[GoalData],
		p_bombs := 0, p_fuse := 8, p_rocks := 0, p_rock_health := 3, p_blanks := false) -> LevelData:
	var l := LevelData.new()
	l.blanks = p_blanks
	l.bomb_count = p_bombs
	l.bomb_fuse = p_fuse
	l.rock_count = p_rocks
	l.rock_health = p_rock_health
	l.title = p_title
	l.moves = p_moves
	l.num_colors = p_colors
	l.cols = p_cols
	l.rows = p_rows
	l.anchor_count = p_anchors
	l.ice_count = p_ice
	l.goals = p_goals
	return l


## Built-in levels, used when Main's `levels` array is empty.
static func sample_levels() -> Array[LevelData]:
	var C := GoalData.Type.COLOR
	var A := GoalData.Type.ANCHOR
	var I := GoalData.Type.ICE
	var B := GoalData.Type.BOMB
	var R := GoalData.Type.ROCK
	var list: Array[LevelData] = []
	list.append(create("Warm-up", 15, 4, 6, 6, 0, 0, [
		GoalData.make(C, 10, 0), GoalData.make(C, 10, 1)]))
	list.append(create("Anchors Away", 20, 5, 7, 8, 2, 0, [
		GoalData.make(A, 3), GoalData.make(C, 15, 2)]))
	list.append(create("Break the Ice", 25, 5, 8, 8, 0, 8, [
		GoalData.make(I, 8), GoalData.make(C, 20, 3)]))
	list.append(create("Ticking Clock", 25, 5, 7, 8, 0, 0, [
		GoalData.make(B, 4), GoalData.make(C, 15, 1)], 2, 7))
	list.append(create("Rock Solid", 25, 5, 7, 8, 0, 0, [
		GoalData.make(R, 6), GoalData.make(C, 15, 0)], 0, 8, 6, 3))
	list.append(create("Holes", 25, 5, 7, 8, 0, 0, [
		GoalData.make(C, 15, 0), GoalData.make(C, 15, 3)], 0, 8, 0, 2, true))
	list.append(create("Everything", 30, 6, 8, 8, 3, 6, [
		GoalData.make(C, 15, 0), GoalData.make(A, 4),
		GoalData.make(I, 6), GoalData.make(C, 15, 4)], 2, 9, 3, 2))
	return list
