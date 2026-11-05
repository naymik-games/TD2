class_name Board
extends RefCounted
## Pure game logic: no drawing, no input, no scene tree.
## Coordinates are Vector2i(col, row); row 0 is the top.
##
## Grid values: 0..5 = colored dot, EMPTY = nothing, ANCHOR = anchor tile, ROCK = rock,
## BLANK = a permanent hole in the grid (no tile can ever sit there).
## Everything negative is not selectable or matchable.

const EMPTY := -1
const ANCHOR := -2
const ROCK := -3
const BLANK := -4

## How many cells make up the group of blanks a level places when its `blanks` flag is on.
const BLANK_GROUP_SIZE := 4

## What happened when a selection was committed. The view uses this to animate.
class Result:
	var color := -1
	var is_square := false
	var points := 0
	var won := false        # that move completed every goal
	var game_over := false  # that was the last move and the goals weren't met
	var reshuffled := false  # board had no moves left and was reshuffled
	var removed: Array[Vector2i] = []
	## Vector2i (final cell) -> number of rows that tile fell.
	## Includes freshly spawned tiles (they "fall" in from above the board).
	var fall := {}
	## Anchors that left the board this move: [{"cell": Vector2i, "fell": int}, ...]
	## "cell" is the bottom-row cell they exited from, "fell" how far they dropped
	## to get there (so the view can animate them landing and then dropping away).
	var exits: Array = []
	## Ice cells that lost health this move but survived / that broke this move.
	var ice_hit_cells: Array[Vector2i] = []
	var ice_broken_cells: Array[Vector2i] = []
	## Bomb dots cleared (defused) this move, and bombs whose fuse ran out.
	var bomb_defused_cells: Array[Vector2i] = []
	var bomb_exploded_cells: Array[Vector2i] = []
	## Rocks damaged but still standing: [{"cell": Vector2i, "health": int}, ...]
	## (cell = where the rock was when it was hit, before anything fell).
	var rock_hits: Array = []
	## Rocks destroyed this move, at the cell they were hit.
	var rock_broken_cells: Array[Vector2i] = []

var cols: int
var rows: int
var num_colors: int

## Number of moves (committed selections) allowed. 0 = unlimited.
var move_limit: int
var moves_left := 0
## Points per dot removed. A square multiplies the points for its dots.
var points_per_dot := 1
var square_multiplier := 2

## Anchors placed at the start. Also the cap on anchors on the board at any time.
var anchor_count: int
## Chance that a newly spawned tile is an anchor (only while under the cap).
var anchor_spawn_chance := 0.1
var anchors_collected := 0

## Ice: a fixed overlay on the board. It never moves; only the dot beneath it changes.
## ice_count cells get ice at the start (never replenished). Each time the dot on an
## ice cell is cleared by a match, the ice loses 1 health; at 0 it breaks.
var ice_count: int
var ice_health := 3  # starting health (the sprite sheet has frames for 1..3)
var ice_total := 0   # ice actually placed at the start
var ice_broken := 0  # ice destroyed so far

## Rocks: blockers that can't be selected or matched. They fall like anchors but never
## leave the board. Whenever dots next to a rock are cleared, the rock loses 1 health
## (once per move, however many neighbors were cleared); at 0 it breaks. Rocks are placed
## at the start (replacing dots) and are not replenished.
var rock_count: int
var rock_health := 2  # starting health
var rock_total := 0   # rocks actually placed at the start
var rocks_broken := 0

## Timed bombs: a colored dot with a countdown that travels with the dot as it falls.
## Every move (committed selection) ticks all bombs on the board down by 1; at 0 the
## level is lost. Clearing the dot defuses it. Bombs spawn randomly with refills, never
## more than bomb_count on the board at once. None are placed at the start.
var bomb_count: int
var bomb_fuse := 8              # moves a new bomb has before it explodes
var bomb_spawn_chance := 0.06   # per newly spawned colored dot, while under the cap
var bombs_defused := 0
var exploded := false           # the level was lost to a bomb

## The level this board was built from, and its goals (at most LevelData.MAX_GOALS).
## Beating the level = every goal met. No goals = score-attack until moves run out.
var level: LevelData
var goals: Array[GoalData] = []
var colors_cleared: Array[int] = []  # dots cleared this game, per color index
var won := false

var score := 0
var game_over := false

var grid: Array = []  # grid[col][row] = color index, EMPTY or ANCHOR
var ice: Array = []   # ice[col][row] = remaining ice health (0 = no ice)
var bombs: Array = [] # bombs[col][row] = moves until the dot there explodes (0 = no bomb)
var rocks: Array = [] # rocks[col][row] = health of the rock there (0 = not a rock); falls with it

## Blanks: permanent holes. Placed once at the start as one connected group (never on the
## bottom row). Nothing is ever in them: tiles fall straight past, they can't be selected,
## cleared or counted toward goals, and a chain can't cross them.
var has_blanks := false
var blank_set := {}  # Vector2i -> true, for every blank cell

# Current selection
var chain: Array[Vector2i] = []
var chain_color := EMPTY
var close_len := 0  # chain length at the moment it closed on itself (0 = not closed)
var close_to := Vector2i(-1, -1)  # the earlier chain dot the loop connected back to

# Color excluded from the next refill (set when a square was made)
var square_color := EMPTY

var rng := RandomNumberGenerator.new()


func _init(p_level: LevelData = null, p_seed := 0) -> void:
	level = p_level if p_level != null else LevelData.new()
	cols = maxi(level.cols, 2)
	rows = maxi(level.rows, 2)
	num_colors = clampi(level.num_colors, 3, 6)
	move_limit = maxi(level.moves, 0)
	anchor_count = maxi(level.anchor_count, 0)
	ice_count = maxi(level.ice_count, 0)
	bomb_count = maxi(level.bomb_count, 0)
	bomb_fuse = maxi(level.bomb_fuse, 1)
	rock_count = maxi(level.rock_count, 0)
	rock_health = maxi(level.rock_health, 1)
	has_blanks = level.blanks
	goals = level.active_goals()
	if p_seed != 0:
		rng.seed = p_seed
	else:
		rng.randomize()
	fill()


## Start a fresh game: new random grid, anchors placed, score reset.
func fill() -> void:
	score = 0
	anchors_collected = 0
	moves_left = move_limit
	game_over = false
	won = false
	bombs_defused = 0
	exploded = false
	bombs.clear()
	for c in cols:
		var bomb_col := []
		bomb_col.resize(rows)
		bomb_col.fill(0)
		bombs.append(bomb_col)
	colors_cleared.clear()
	colors_cleared.resize(6)
	colors_cleared.fill(0)
	square_color = EMPTY
	cancel()

	# Rocks: health grid, then pick starting cells.
	rocks.clear()
	for c in cols:
		var rock_col := []
		rock_col.resize(rows)
		rock_col.fill(0)
		rocks.append(rock_col)
	rocks_broken = 0
	rock_total = 0

	# Cells that hold something other than a colored dot: Vector2i -> ANCHOR / ROCK.
	# Blanks go down first; everything else is placed around them.
	_place_blanks()
	var fixed := {}
	for p in blank_set:
		fixed[p] = BLANK
	for p in _pick_cells(anchor_count, rows - 1):  # anchors never on the bottom row
		fixed[p] = ANCHOR
	for p in _pick_cells(rock_count, rows, fixed):
		fixed[p] = ROCK
		rocks[p.x][p.y] = rock_health
		rock_total += 1
	_randomize_grid(fixed)
	_place_ice()


## Re-roll all colored dots (keeps score; anchors and rocks stay where they are).
## Guarantees at least one move.
func reshuffle() -> void:
	var fixed := {}
	for c in cols:
		for r in rows:
			if grid[c][r] == ANCHOR or grid[c][r] == ROCK or grid[c][r] == BLANK:
				fixed[Vector2i(c, r)] = grid[c][r]
	square_color = EMPTY
	cancel()
	_randomize_grid(fixed)


## `count` distinct random cells from the top `row_count` rows, skipping any cell
## that is a key in `exclude`.
## (Anchors pass rows - 1: one sitting on the bottom row would never "arrive".)
func _pick_cells(count: int, row_count: int, exclude := {}) -> Array[Vector2i]:
	var pool: Array[Vector2i] = []
	for c in cols:
		for r in row_count:
			var p := Vector2i(c, r)
			if not exclude.has(p) and not blank_set.has(p):
				pool.append(p)
	for i in range(pool.size() - 1, 0, -1):  # Fisher-Yates with our own rng
		var j := rng.randi_range(0, i)
		var tmp := pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	var picked: Array[Vector2i] = []
	for i in mini(count, pool.size()):
		picked.append(pool[i])
	return picked


## Choose the blank cells for this game: one connected group of BLANK_GROUP_SIZE cells,
## in a random shape, never touching the bottom row. Does nothing if the level has no blanks.
func _place_blanks() -> void:
	blank_set.clear()
	if not has_blanks:
		return
	for attempt in 20:
		var group := _random_group(BLANK_GROUP_SIZE)
		if group.size() == BLANK_GROUP_SIZE:
			for p in group:
				blank_set[p] = true
			return


## Grow a random connected group (orthogonal neighbors) of `size` cells in the grid
## excluding the bottom row. Empty if the area is too small to hold one.
func _random_group(size: int) -> Array[Vector2i]:
	var group: Array[Vector2i] = []
	var usable_rows := rows - 1  # the bottom row always stays solid
	if usable_rows < 1:
		return group
	group.append(Vector2i(rng.randi() % cols, rng.randi() % usable_rows))
	while group.size() < size:
		var frontier: Array[Vector2i] = []
		for g in group:
			for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var n: Vector2i = g + d
				if n.x < 0 or n.x >= cols or n.y < 0 or n.y >= usable_rows:
					continue
				if n in group or n in frontier:
					continue
				frontier.append(n)
		if frontier.is_empty():
			group.clear()
			return group
		group.append(frontier[rng.randi() % frontier.size()])
	return group


## Designate the starting ice cells. Ice sits on coordinates, independent of the dots.
func _place_ice() -> void:
	ice.clear()
	for c in cols:
		var column := []
		column.resize(rows)
		column.fill(0)
		ice.append(column)
	ice_broken = 0
	ice_total = 0
	for p in _pick_cells(ice_count, rows):
		ice[p.x][p.y] = ice_health
		ice_total += 1


## Random colors everywhere, except `fixed` cells (Vector2i -> ANCHOR / ROCK).
func _randomize_grid(fixed: Dictionary) -> void:
	for attempt in 100:
		grid.clear()
		for c in cols:
			var column := []
			for r in rows:
				column.append(rng.randi() % num_colors)
			grid.append(column)
		for p in fixed:
			grid[p.x][p.y] = fixed[p]
		if has_moves():
			return


# ---------- Queries ----------

func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < cols and p.y < rows


## Color index, or EMPTY / ANCHOR (both negative).
func get_color(p: Vector2i) -> int:
	return grid[p.x][p.y]


## The level has ended, either won or out of moves.
func is_finished() -> bool:
	return won or game_over


## How many are needed for goal i. An ice goal can't ask for more ice than was placed.
func goal_target(i: int) -> int:
	var g := goals[i]
	if g.type == GoalData.Type.ICE and ice_total > 0:
		return mini(g.amount, ice_total)
	if g.type == GoalData.Type.ROCK and rock_total > 0:
		return mini(g.amount, rock_total)  # rocks aren't replenished
	return g.amount


## Raw running total for goal i (can exceed the target).
func goal_current(i: int) -> int:
	var g := goals[i]
	match g.type:
		GoalData.Type.COLOR:
			return colors_cleared[g.color]
		GoalData.Type.ANCHOR:
			return anchors_collected
		GoalData.Type.ICE:
			return ice_broken
		GoalData.Type.BOMB:
			return bombs_defused
		GoalData.Type.ROCK:
			return rocks_broken
	return 0


## Progress for display: goal_current capped at the target.
func goal_progress(i: int) -> int:
	return mini(goal_current(i), goal_target(i))


func goal_met(i: int) -> bool:
	return goal_current(i) >= goal_target(i)


func all_goals_met() -> bool:
	if goals.is_empty():
		return false
	for i in goals.size():
		if not goal_met(i):
			return false
	return true


## Remaining ice health at p (0 = no ice).
func get_ice(p: Vector2i) -> int:
	return ice[p.x][p.y]


## Health of the rock at p (0 = no rock there).
func get_rock(p: Vector2i) -> int:
	return rocks[p.x][p.y]


## Moves left on the bomb at p (0 = no bomb there).
func get_bomb(p: Vector2i) -> int:
	return bombs[p.x][p.y]


func count_bombs() -> int:
	var n := 0
	for c in cols:
		for r in rows:
			if bombs[c][r] > 0:
				n += 1
	return n


## True if p is a hole in the grid.
func is_blank(p: Vector2i) -> bool:
	return grid[p.x][p.y] == BLANK


## True for a normal colored dot (selectable / matchable).
func is_dot(p: Vector2i) -> bool:
	return get_color(p) >= 0


func is_selecting() -> bool:
	return not chain.is_empty()


func is_closed() -> bool:
	return close_len > 0


func can_commit() -> bool:
	return is_closed() or chain.size() >= 2


func has_move_limit() -> bool:
	return move_limit > 0


func count_anchors() -> int:
	var n := 0
	for c in cols:
		for r in rows:
			if grid[c][r] == ANCHOR:
				n += 1
	return n


## True if at least one pair of adjacent colored dots shares a color.
## (Any square contains such a pair, so this covers squares too. Anchors never match.)
func has_moves() -> bool:
	for c in cols:
		for r in rows:
			var v: int = grid[c][r]
			if v < 0:
				continue
			if c + 1 < cols and grid[c + 1][r] == v:
				return true
			if r + 1 < rows and grid[c][r + 1] == v:
				return true
	return false


# ---------- Selection ----------

func begin(p: Vector2i) -> bool:
	if is_finished() or not in_bounds(p) or not is_dot(p):
		return false
	chain = [p]
	chain_color = get_color(p)
	close_len = 0
	close_to = Vector2i(-1, -1)
	return true


## Try to extend the chain to p. Returns true if the chain changed.
func extend(p: Vector2i) -> bool:
	if chain.is_empty() or not in_bounds(p):
		return false
	var last: Vector2i = chain.back()
	if p == last:
		return false
	if absi(p.x - last.x) + absi(p.y - last.y) != 1:
		return false
	if get_color(p) != chain_color:  # also rejects anchors/empty (negative values)
		return false

	if chain.size() >= 2 and p == chain[chain.size() - 2]:
		# Dragged back over the previous dot: undo the last step.
		chain.pop_back()
		if chain.size() < close_len:
			close_len = 0
			close_to = Vector2i(-1, -1)
	elif p in chain:
		# Touched a dot already in the chain: the chain loops (a "square").
		if close_len == 0:
			close_len = chain.size()
			close_to = p
		else:
			return false
	else:
		chain.append(p)
	return true


func cancel() -> void:
	chain.clear()
	chain_color = EMPTY
	close_len = 0
	close_to = Vector2i(-1, -1)


# ---------- Commit ----------

## Applies the current selection. Returns null if it wasn't a valid selection.
func commit() -> Result:
	if is_finished() or not can_commit():
		cancel()
		return null

	var res := Result.new()
	res.color = chain_color
	res.is_square = is_closed()

	if res.is_square:
		# Square: remove every dot of this color on the board.
		for c in cols:
			for r in rows:
				if grid[c][r] == chain_color:
					res.removed.append(Vector2i(c, r))
		square_color = chain_color
	else:
		res.removed.assign(chain)
		square_color = EMPTY

	for p in res.removed:
		grid[p.x][p.y] = EMPTY
		_damage_ice(p, res)
		_defuse_bomb(p, res)
	_damage_rocks(res)

	# Scoring
	res.points = res.removed.size() * points_per_dot
	if res.is_square:
		res.points *= square_multiplier
	score += res.points
	colors_cleared[chain_color] += res.removed.size()  # for color goals

	cancel()
	# Remaining bombs tick down now, before the refill, so a bomb spawned by this
	# move keeps its full fuse. (Bombs cleared above were already defused.)
	_tick_bombs(res)
	_settle(res)

	# Each valid selection (chain or square) costs one move.
	if has_move_limit():
		moves_left -= 1

	# Goals are checked first, so completing them on the very last move still wins,
	# even if a bomb ran out on that same move.
	if all_goals_met():
		won = true
		res.won = true
	elif not res.bomb_exploded_cells.is_empty():
		exploded = true
		game_over = true
		res.game_over = true
	elif has_move_limit() and moves_left <= 0:
		game_over = true
		res.game_over = true
	elif not has_moves():
		# Dead board: re-roll the colored dots and drop everything in again.
		reshuffle()
		res.reshuffled = true
		res.fall.clear()
		for c in cols:
			for r in rows:
				if grid[c][r] != BLANK:
					res.fall[Vector2i(c, r)] = rows

	return res



# ---------- Power-ups ----------
## Power-ups cost no move and don't tick bombs. Each returns a Result for the view to
## animate, or null if the target was invalid (nothing changed, so nothing gets spent).
## Cleared dots still count toward color goals and still hit ice, bombs and rocks.

## Remove the single colored dot at p.
func power_remove_dot(p: Vector2i) -> Result:
	if is_finished() or not in_bounds(p) or not is_dot(p):
		return null
	var cells: Array[Vector2i] = [p]
	return _power_clear(cells, get_color(p), false)


## Remove every colored dot that shares the color of the dot at p.
func power_remove_color(p: Vector2i) -> Result:
	if is_finished() or not in_bounds(p) or not is_dot(p):
		return null
	var color := get_color(p)
	var cells: Array[Vector2i] = []
	for c in cols:
		for r in rows:
			if grid[c][r] == color:
				cells.append(Vector2i(c, r))
	# Like a square, the removed color is left out of the next refill.
	return _power_clear(cells, color, true)


## Shuffle the colored dots among their cells. Anchors, rocks, blanks, ice and bomb
## timers stay where they are. Returns null if there's nothing to shuffle.
func power_shuffle() -> Result:
	if is_finished():
		return null
	var cells: Array[Vector2i] = []
	var colors: Array[int] = []
	var distinct := {}
	for c in cols:
		for r in rows:
			var v: int = grid[c][r]
			if v >= 0:
				cells.append(Vector2i(c, r))
				colors.append(v)
				distinct[v] = true
	if distinct.size() < 2:  # shuffling one color (or nothing) changes nothing
		return null

	cancel()
	square_color = EMPTY
	for attempt in 50:  # retry until the shuffle leaves at least one move
		for i in range(colors.size() - 1, 0, -1):  # Fisher-Yates with our own rng
			var j := rng.randi_range(0, i)
			var tmp := colors[i]
			colors[i] = colors[j]
			colors[j] = tmp
		for i in cells.size():
			grid[cells[i].x][cells[i].y] = colors[i]
		if has_moves():
			break

	var res := Result.new()
	for p in cells:
		res.fall[p] = rows  # every dot drops in again, like a reshuffle
	_after_power_up(res)  # falls back to a full reshuffle if the board is somehow dead
	return res


func _power_clear(cells: Array[Vector2i], color: int, exclude_color: bool) -> Result:
	cancel()
	var res := Result.new()
	res.color = color
	res.removed.assign(cells)
	for p in cells:
		grid[p.x][p.y] = EMPTY
		_damage_ice(p, res)
		_defuse_bomb(p, res)
	_damage_rocks(res)
	colors_cleared[color] += cells.size()
	square_color = color if exclude_color else EMPTY
	_settle(res)
	_after_power_up(res)
	return res


## Win check and dead-board handling, same as the tail of commit().
func _after_power_up(res: Result) -> void:
	if all_goals_met():
		won = true
		res.won = true
	elif not has_moves():
		reshuffle()
		res.reshuffled = true
		res.fall.clear()
		for c in cols:
			for r in rows:
				if grid[c][r] != BLANK:
					res.fall[Vector2i(c, r)] = rows



## A dot on p was just cleared: the ice over it (if any) loses 1 health.
func _damage_ice(p: Vector2i, res: Result) -> void:
	var health: int = ice[p.x][p.y]
	if health <= 0:
		return
	health -= 1
	ice[p.x][p.y] = health
	if health == 0:
		ice_broken += 1
		res.ice_broken_cells.append(p)
	else:
		res.ice_hit_cells.append(p)


## Dots were just cleared: every rock next to a cleared dot loses 1 health.
## A rock is hit at most once per move, however many neighbors were cleared.
## Runs before gravity, so positions are still where the dots were removed.
func _damage_rocks(res: Result) -> void:
	var touched := {}  # Vector2i -> true
	for p in res.removed:
		for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n: Vector2i = p + d
			if in_bounds(n) and grid[n.x][n.y] == ROCK:
				touched[n] = true
	for n in touched:
		var health: int = rocks[n.x][n.y] - 1
		if health <= 0:
			rocks[n.x][n.y] = 0
			grid[n.x][n.y] = EMPTY  # leaves a gap that gravity/refill fills
			rocks_broken += 1
			res.rock_broken_cells.append(n)
		else:
			rocks[n.x][n.y] = health
			res.rock_hits.append({"cell": n, "health": health})


## A dot on p was just cleared: if it carried a bomb, the bomb is defused.
func _defuse_bomb(p: Vector2i, res: Result) -> void:
	if bombs[p.x][p.y] > 0:
		bombs[p.x][p.y] = 0
		bombs_defused += 1
		res.bomb_defused_cells.append(p)


## One move has passed: every bomb still on the board loses 1 fuse.
## A bomb that hits 0 explodes (it's reported in res and ends the level).
func _tick_bombs(res: Result) -> void:
	for c in cols:
		for r in rows:
			if bombs[c][r] > 0:
				bombs[c][r] -= 1
				if bombs[c][r] == 0:
					res.bomb_exploded_cells.append(Vector2i(c, r))


## Gravity, anchor exits, then refill.
func _settle(res: Result) -> void:
	# Anchors that land on the bottom row leave the board. That opens a gap, so
	# gravity runs again (and may carry another anchor down to the bottom).
	while true:
		_apply_gravity(res)
		var exited := false
		for c in cols:
			if grid[c][rows - 1] == ANCHOR:
				var p := Vector2i(c, rows - 1)
				res.exits.append({"cell": p, "fell": res.fall.get(p, 0)})
				res.fall.erase(p)
				grid[c][rows - 1] = EMPTY
				anchors_collected += 1
				exited = true
		if not exited:
			break
	_refill(res)


## Drop every tile (dots, anchors, rocks) toward the bottom of its column. Blank cells
## are skipped: they never hold a tile, so a falling tile passes straight over them and
## lands in the next real cell below.
## res.fall accumulates across repeated calls, so a tile that falls twice
## is animated as one longer fall (the distance counts every row crossed, blanks included).
func _apply_gravity(res: Result) -> void:
	for c in cols:
		var write := rows - 1
		for r in range(rows - 1, -1, -1):
			if grid[c][r] == BLANK or grid[c][r] == EMPTY:
				continue
			while grid[c][write] == BLANK:  # the landing slot can't be a hole
				write -= 1
			if write != r:
				var src := Vector2i(c, r)
				var dst := Vector2i(c, write)
				var prior: int = res.fall.get(src, 0)
				res.fall.erase(src)
				res.fall[dst] = prior + (write - r)
				grid[c][write] = grid[c][r]
				grid[c][r] = EMPTY
				bombs[c][write] = bombs[c][r]  # a bomb travels with its dot
				bombs[c][r] = 0
				rocks[c][write] = rocks[c][r]  # and a rock keeps its health
				rocks[c][r] = 0
			write -= 1


## Fill the empty slots at the top of each column with new tiles. Blank cells aren't slots.
func _refill(res: Result) -> void:
	var allowed: Array[int] = []
	for i in num_colors:
		if i != square_color:
			allowed.append(i)

	# Anchors may only spawn while the board holds fewer than anchor_count.
	var budget := anchor_count - count_anchors()
	# Same idea for bombs: never more than bomb_count on the board at once.
	var bomb_budget := bomb_count - count_bombs()

	for c in cols:
		# After gravity the open slots are stacked at the top of the column, with any
		# blanks mixed in. Collect the real slots, top to bottom.
		var slots: Array[int] = []
		for r in rows:
			if grid[c][r] == BLANK:
				continue
			if grid[c][r] != EMPTY:
				break
			slots.append(r)
		for i in slots.size():
			var r := slots[i]
			# New tiles enter in a stack just above the board (the lowest one starts one
			# row above row 0), so a tile's fall = its row + 1 + the slots below it.
			res.fall[Vector2i(c, r)] = r + 1 + (slots.size() - 1 - i)
			# Never spawn an anchor on the bottom row (it would never "arrive").
			if budget > 0 and r < rows - 1 and rng.randf() < anchor_spawn_chance:
				grid[c][r] = ANCHOR
				budget -= 1
			else:
				grid[c][r] = allowed[rng.randi() % allowed.size()]
				if bomb_budget > 0 and rng.randf() < bomb_spawn_chance:
					bombs[c][r] = bomb_fuse
					bomb_budget -= 1
