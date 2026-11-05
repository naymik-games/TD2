class_name LevelGenerator
extends RefCounted
## Builds random but playable LevelData for the level builder.
##
## 1. A level is *designed* from a difficulty (1-10): which mechanics appear, how many,
##    how they are shaped, and which goals use them.
## 2. It is then *calibrated* by letting a bot play the real Board many times. The bot
##    tells us how many moves a typical player needs, and the move limit is set so the
##    level lands on a target win rate for its difficulty.
## 3. Levels the bot can't beat, that are lucky/unfair, or that are trivially short are
##    thrown away and the generator tries again.
##
## Usage (see level_builder.gd):
##   var gen := LevelGenerator.new()
##   var result := gen.try_generate(5)
##   if result["level"] != null: ...

enum Mech { ANCHOR, ICE, ROCK, BOMB, BLANKS }

## Difficulty (1-10) at which each mechanic may first appear.
const UNLOCK := {
	Mech.ANCHOR: 2,
	Mech.ICE: 2,
	Mech.ROCK: 3,
	Mech.BLANKS: 3,
	Mech.BOMB: 4,
}

## Title for a level, by its headline mechanic (-1 = colors only).
const MECH_NAMES := {
	-1: "Color Rush",
	Mech.ANCHOR: "Anchors Away",
	Mech.ICE: "Break the Ice",
	Mech.ROCK: "Rock Solid",
	Mech.BOMB: "Ticking Clock",
	Mech.BLANKS: "Holes",
}

const DIRS: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]

# ---------- Tuning knobs ----------

## Attempts per level before the builder gives up on it.
const MAX_ATTEMPTS := 25
## Simulated games per candidate level.
const GAMES := 30
## If the bot hasn't won any of this many games, stop early.
const EARLY_CHECK_GAMES := 8
## A simulated game that takes longer than this counts as a loss.
const MAX_SIM_MOVES := 80
## Chance per move that the bot plays a random chain instead of its best one.
## Higher = the bot plays like a more casual player = more generous move limits.
const BOT_NOISE := 0.25
## Share of games a typical player should win with the generated move limit.
## Even the easiest level is not a gimme: it should be won about 4 times in 5.
const WIN_RATE_EASIEST := 0.80
const WIN_RATE_HARDEST := 0.35
## Moves the level may end up with.
const MIN_MOVES := 6
const MAX_MOVES := 45
## Reject a level when the moves needed to reach the target win rate are this many times
## the median moves needed: it means the outcome is mostly luck.
const MAX_SPREAD := 1.6
## Most games that may be lost to a bomb exploding.
const EXPLODE_EASIEST := 0.05
const EXPLODE_HARDEST := 0.20

var rng := RandomNumberGenerator.new()


func _init(p_seed := 0) -> void:
	if p_seed != 0:
		rng.seed = p_seed
	else:
		rng.randomize()


## Difficulty for level `i` of a batch of `n`, ramping from `lo` to `hi` with a short
## breather (two steps easier) on every fourth level. The last level is never a breather.
static func batch_difficulty(i: int, n: int, lo: int, hi: int) -> int:
	var t := 0.0 if n <= 1 else float(i) / float(n - 1)
	var d := roundi(lerpf(lo, hi, t))
	if i % 4 == 3 and i < n - 1:
		d -= 2
	return clampi(d, 1, 10)


## One attempt at a level. Returns:
##   {"level": LevelData or null, "headline": int, "win_rate": float, "reason": String}
## `reason` says why an attempt was rejected. `avoid_headline` is the Mech to avoid as the
## headline (so consecutive levels in a batch feel different); -2 = no preference.
func try_generate(difficulty: int, avoid_headline := -2) -> Dictionary:
	difficulty = clampi(difficulty, 1, 10)
	var plan := _plan(difficulty, avoid_headline)
	var level: LevelData = plan["level"]
	var problems := level.validate()
	if not problems.is_empty():
		return {"level": null, "reason": problems[0]}
	var cal := calibrate(level, difficulty)
	if not cal["ok"]:
		return {"level": null, "reason": cal["reason"]}
	level.moves = cal["moves"]
	return {
		"level": level,
		"headline": plan["headline"],
		"win_rate": cal["win_rate"],
		"reason": "",
	}


# ---------- Design ----------

func _plan(d: int, avoid: int) -> Dictionary:
	var t := (d - 1) / 9.0
	var level := LevelData.new()
	level.cols = rng.randi_range(6, 6 + roundi(t * 2.0))
	level.rows = mini(level.cols + rng.randi_range(0, 1), 9)
	level.num_colors = clampi(4 + roundi(t * 2.0 + rng.randf_range(-0.6, 0.6)), 4, 6)
	var area := level.cols * level.rows

	# Which mechanics are in play. One "headline" mechanic carries the level; the rest are
	# seasoning. Difficulty 1 is colors only; later levels may layer more on.
	var unlocked: Array[int] = []
	for m in UNLOCK:
		if d >= UNLOCK[m]:
			unlocked.append(m)
	unlocked.shuffle()

	var budget := 0
	if d >= 2:
		budget = 1
	if d >= 4:
		budget = 2
	if d >= 8:
		budget = 3

	var headline := -1
	var active: Array[int] = []
	if budget > 0 and not unlocked.is_empty():
		var pool: Array = unlocked.filter(func(m): return m != avoid)
		if pool.is_empty():
			pool = unlocked
		headline = int(pool[rng.randi() % pool.size()])
		active.append(headline)
		for m in unlocked:
			if active.size() >= budget:
				break
			if m != headline and rng.randf() < 0.7:
				active.append(m)

	# Set each mechanic up. The headline gets goals; seasoning gets one half the time.
	var mech_goals: Array[GoalData] = []
	for m in active:
		var is_head: bool = (m == headline)
		var intensity := lerpf(0.2, 0.5, t)
		if is_head:
			intensity = clampf(lerpf(0.35, 1.0, t) * rng.randf_range(0.85, 1.15), 0.2, 1.0)
		var goal := _setup(level, m, intensity, t, area, is_head)
		if goal != null and (is_head or rng.randf() < 0.5):
			mech_goals.append(goal)

	# Color goals fill out the rest. Colors only, or a mechanic with no goal of its own
	# (blanks), gets two; otherwise one or two depending on how many goals are already there.
	var colors: Array[int] = []
	for i in level.num_colors:
		colors.append(i)
	colors.shuffle()
	var color_goals := 2 if mech_goals.size() <= 1 else 1
	color_goals = mini(color_goals, LevelData.MAX_GOALS - mech_goals.size())
	var share := float(area) / float(level.num_colors)
	var amount_scale := lerpf(1.1, 1.7, t) * (1.0 if mech_goals.is_empty() else 0.7)

	for g in mech_goals:
		level.goals.append(g)
	for i in color_goals:
		var amount := maxi(6, roundi(share * amount_scale * rng.randf_range(0.85, 1.15)))
		level.goals.append(GoalData.make(GoalData.Type.COLOR, amount, colors[i]))

	level.title = "%s [d%d]" % [MECH_NAMES[headline], d]
	return {"level": level, "headline": headline}


## Configure one mechanic on `level`. Returns the goal it suggests (or null).
func _setup(level: LevelData, m: int, intensity: float, t: float, area: int, is_head: bool) -> GoalData:
	match m:
		Mech.ANCHOR:
			var anchors := clampi(roundi(lerpf(1.0, level.cols * 0.6, intensity)), 1, 5)
			level.anchor_count = anchors
			# More anchors can spawn as the board refills, so the goal may exceed the count.
			var extra := rng.randi_range(0, 1) if is_head else 0
			return GoalData.make(GoalData.Type.ANCHOR, anchors + extra)
		Mech.ICE:
			var ice := clampi(roundi(area * lerpf(0.08, 0.24, intensity)), 3, 18)
			level.ice_count = ice
			var ice_goal := maxi(2, roundi(ice * rng.randf_range(0.6, 1.0)))
			return GoalData.make(GoalData.Type.ICE, mini(ice_goal, ice))
		Mech.ROCK:
			var rocks := clampi(roundi(area * lerpf(0.05, 0.14, intensity)), 2, 10)
			level.rock_count = rocks
			level.rock_health = clampi(1 + roundi(intensity * 2.0 + rng.randf_range(-0.5, 0.5)), 1, 3)
			var rock_goal := clampi(roundi(rocks * rng.randf_range(0.6, 1.0)), 1, rocks)
			return GoalData.make(GoalData.Type.ROCK, rock_goal)
		Mech.BOMB:
			level.bomb_count = clampi(roundi(lerpf(1.0, 3.0, intensity)), 1, 3)
			# Short fuses are for late levels; early bombs give plenty of time.
			level.bomb_fuse = clampi(roundi(lerpf(11.0, 6.0, t) + rng.randf_range(-1.0, 1.0)), 5, 14)
			return GoalData.make(GoalData.Type.BOMB, clampi(roundi(lerpf(2.0, 6.0, intensity)), 2, 8))
		Mech.BLANKS:
			level.blanks = true
	return null


# ---------- Calibration ----------

## Play the level with the bot (no move limit) and pick the move limit that gives the
## target win rate. Returns {"ok": bool, "reason": String, "moves": int, "win_rate": float}.
func calibrate(level: LevelData, d: int) -> Dictionary:
	var t := (d - 1) / 9.0
	var target := lerpf(WIN_RATE_EASIEST, WIN_RATE_HARDEST, t)
	var max_explode := lerpf(EXPLODE_EASIEST, EXPLODE_HARDEST, t)

	var saved_moves := level.moves
	level.moves = 0  # unlimited: we record how many moves each win took
	var needed: Array[int] = []
	var exploded := 0
	var played := 0
	for i in GAMES:
		var r := _play(level, rng.randi_range(1, 2147483647))
		played += 1
		if r["won"]:
			needed.append(r["moves"])
		elif r["exploded"]:
			exploded += 1
		if played == EARLY_CHECK_GAMES and needed.is_empty():
			break
	level.moves = saved_moves

	if needed.is_empty():
		return {"ok": false, "reason": "the bot never wins"}
	if float(exploded) / float(played) > max_explode:
		return {"ok": false, "reason": "bombs explode too often"}
	var need_count := ceili(target * played)
	if needed.size() < need_count:
		return {"ok": false, "reason": "too hard: bot wins only %d%%" % roundi(100.0 * needed.size() / played)}

	needed.sort()
	var moves: int = needed[need_count - 1]
	var median: int = needed[needed.size() / 2]
	if moves < MIN_MOVES:
		return {"ok": false, "reason": "too short (%d moves)" % moves}
	if moves > MAX_MOVES:
		return {"ok": false, "reason": "too long (%d moves)" % moves}
	if float(moves) > MAX_SPREAD * float(median):
		return {"ok": false, "reason": "outcome mostly luck"}

	var wins := 0
	for n in needed:
		if n <= moves:
			wins += 1
	return {"ok": true, "reason": "", "moves": moves, "win_rate": float(wins) / float(played)}


## One simulated game on the real Board. Returns {"won", "moves", "exploded"}.
func _play(level: LevelData, board_seed: int) -> Dictionary:
	var board := Board.new(level, board_seed)
	var moves := 0
	while moves < MAX_SIM_MOVES:
		var cands := _candidates(board)
		if cands.is_empty():
			break
		var pick: Dictionary = cands[rng.randi() % cands.size()]
		if rng.randf() >= BOT_NOISE:
			var best := -INF
			for c in cands:
				var s: float = c["score"] + rng.randf() * 0.01
				if s > best:
					best = s
					pick = c
		board.chain.assign(pick["path"])
		board.chain_color = pick["color"]
		board.close_len = pick["close_len"]
		var res := board.commit()
		if res == null:
			break
		moves += 1
		if res.won:
			return {"won": true, "moves": moves, "exploded": false}
		if res.game_over:
			return {"won": false, "moves": moves, "exploded": board.exploded}
	return {"won": false, "moves": moves, "exploded": false}


## Every move the bot considers, each scored by how much it helps the unmet goals:
## [{"path", "color", "close_len", "score"}, ...]
func _candidates(b: Board) -> Array:
	var out: Array = []
	var vals := _cell_values(b)
	var seen := {}
	var square_score := {}  # color -> score of clearing the whole color
	for c in b.cols:
		for r in b.rows:
			var p := Vector2i(c, r)
			if seen.has(p) or not b.is_dot(p):
				continue
			var comp := _component(b, p, seen)
			if comp.size() < 2:
				continue
			var color := b.get_color(p)
			var in_comp := {}
			for q in comp:
				in_comp[q] = true

			# A long walk through the group, and one that heads for its best cell.
			var start := comp[0]
			var fewest := 99
			var best_cell := comp[0]
			for q in comp:
				var n := _open_neighbors(q, in_comp, {}).size()
				if n < fewest:
					fewest = n
					start = q
				if vals[q.x][q.y] > vals[best_cell.x][best_cell.y]:
					best_cell = q
			for variant in 2:
				var path := _walk(in_comp, start if variant == 0 else best_cell, vals, variant == 1)
				var score := 0.0
				for q in path:
					score += vals[q.x][q.y]
				out.append({"path": path, "color": color, "close_len": 0, "score": score})

			# A 2x2 block of one color makes a square: clears every dot of that color.
			var sq := _find_square(comp, in_comp)
			if not sq.is_empty():
				if not square_score.has(color):
					var total := 0.0
					for cc in b.cols:
						for rr in b.rows:
							if b.grid[cc][rr] == color:
								total += vals[cc][rr]
					square_score[color] = total
				out.append({"path": sq, "color": color, "close_len": 4, "score": square_score[color]})
	return out


## Per-cell worth of clearing it, given the goals still unmet.
func _cell_values(b: Board) -> Array:
	var want_color := {}
	var want_ice := false
	var want_anchor := false
	var want_rock := false
	var want_bomb := false
	for i in b.goals.size():
		if b.goal_met(i):
			continue
		var g := b.goals[i]
		match g.type:
			GoalData.Type.COLOR:
				want_color[g.color] = true
			GoalData.Type.ICE:
				want_ice = true
			GoalData.Type.ANCHOR:
				want_anchor = true
			GoalData.Type.ROCK:
				want_rock = true
			GoalData.Type.BOMB:
				want_bomb = true

	var vals: Array = []
	for c in b.cols:
		var col: Array = []
		for r in b.rows:
			var v := 1.0
			var color: int = b.grid[c][r]
			if color >= 0:
				if want_color.has(color):
					v += 3.0
				if want_ice and b.ice[c][r] > 0:
					v += 3.0
				var fuse: int = b.bombs[c][r]
				if fuse > 0:
					# Defusing is about survival first, so urgent bombs dominate everything.
					v += 6.0 + (4.0 if want_bomb else 0.0) + (20.0 if fuse <= 2 else 0.0)
			col.append(v)
		vals.append(col)

	for c in b.cols:
		for r in b.rows:
			match b.grid[c][r]:
				Board.ANCHOR:
					if want_anchor:
						for rr in range(r + 1, b.rows):  # clearing below an anchor lowers it
							vals[c][rr] += 2.0
				Board.ROCK:
					if want_rock:
						for d in DIRS:
							var n: Vector2i = Vector2i(c, r) + d
							if b.in_bounds(n):
								vals[n.x][n.y] += 2.5
	return vals


func _component(b: Board, start: Vector2i, seen: Dictionary) -> Array[Vector2i]:
	var color := b.get_color(start)
	var comp: Array[Vector2i] = [start]
	seen[start] = true
	var i := 0
	while i < comp.size():
		var p := comp[i]
		i += 1
		for d in DIRS:
			var n: Vector2i = p + d
			if b.in_bounds(n) and not seen.has(n) and b.grid[n.x][n.y] == color:
				seen[n] = true
				comp.append(n)
	return comp


func _open_neighbors(p: Vector2i, in_comp: Dictionary, used: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in DIRS:
		var n: Vector2i = p + d
		if in_comp.has(n) and not used.has(n):
			out.append(n)
	return out


## A simple (non-crossing) path through a group of same-colored dots. Normally it prefers
## the neighbor with the fewest onward options, which tends to cover most of the group;
## with value_first it chases the most valuable cells instead.
func _walk(in_comp: Dictionary, start: Vector2i, vals: Array, value_first: bool) -> Array[Vector2i]:
	var path: Array[Vector2i] = [start]
	var used := {start: true}
	var cur := start
	while true:
		var opts := _open_neighbors(cur, in_comp, used)
		if opts.is_empty():
			break
		var nxt := opts[0]
		var best := INF
		for o in opts:
			var onward := float(_open_neighbors(o, in_comp, used).size())
			var v: float = vals[o.x][o.y]
			var key := onward - v * (10.0 if value_first else 0.05)
			if key < best:
				best = key
				nxt = o
		path.append(nxt)
		used[nxt] = true
		cur = nxt
	return path


## Four cells forming a 2x2 block, in loop order, or empty if the group has none.
func _find_square(comp: Array[Vector2i], in_comp: Dictionary) -> Array[Vector2i]:
	for q in comp:
		var right := q + Vector2i.RIGHT
		var down := q + Vector2i.DOWN
		var diag := q + Vector2i(1, 1)
		if in_comp.has(right) and in_comp.has(down) and in_comp.has(diag):
			var sq: Array[Vector2i] = [q, right, diag, down]
			return sq
	var none: Array[Vector2i] = []
	return none
"""
How it works

Design. Each level gets a difficulty from 1 to 10, which decides the board and the mix of mechanics:

Board: difficulty sets the grid size (6x6 up to 8x9) and the number of colors (4 to 6).
Mechanics: difficulty 1 is colors only. Ice and anchors unlock at 2, rocks and blanks at 3, bombs at 4.
One headline mechanic per level: the level is built around it, with other mechanics as light seasoning. The number of mechanics at once is 1 at difficulties 2–3, 2 at 4–7 and 3 at 8–10.
Variety: consecutive levels in a batch avoid repeating the same headline.
Goals: the headline mechanic gets a goal. Color goals fill the rest, and the total never exceeds 4.
Blanks: they’re an obstacle with no goal, so those levels get two color goals.

Calibration. The move limit comes from simulated play instead of a formula, which is what keeps goals and moves reasonable:

A bot plays 30 games on the real Board with no move limit and records how many moves each win took. The bot is goal-aware: it goes for unmet color, ice, rock, anchor and bomb targets, urgently defuses short fuses, and plays 2x2 squares.
The move limit is the number of moves that gives the target win rate. That rate is about 80% at difficulty 1 and falls to about 35% at 10. So even the easiest level should lose about one game in five.
A level is rejected and rerolled if the bot never wins, bombs end too many games, it needs fewer than 6 or more than 45 moves, or the result looks mostly luck.

Batch. The builder asks for a count and a difficulty range, default 10 levels from 1 to 10. It adds a short breather (two steps easier) on every fourth level, and the last level is never one. Generated levels are inserted after the selected level and are titled like Break the Ice [d5]. Generation yields to the UI between attempts, and results are printed to the output panel.

Things to know
Bombs: you described bombs as non-selectable tiles cleared by an adjacent clear. board.gd instead makes a bomb a countdown on a normal colored dot, defused when that dot is cleared. I followed the code, so tell me if the code is out of date.
Bot skill: the bot has a noise setting (BOT_NOISE, 25%) so it plays like a casual player. If generated levels feel too easy or too hard when you play them, tune WIN_RATE_EASIEST and WIN_RATE_HARDEST first. Both are constants at the top of level_generator.gd, along with the other knobs.
Playtesting: the bot has no foresight and no sense of risk, so a human still has to play each generated level before you save it.
Run time: a level needs 30 simulated games per attempt, and a hard level can take several attempts. I’d expect a few seconds per level, but I haven’t timed it. If it feels slow, lower GAMES.

Next I’d try one batch and note which levels feel wrong, such as too many ice cells or bombs that feel unfair. Those complaints map directly to the intensity numbers in _setup, so they’re quick to adjust.

#################################################
Adding a mechanic touches a handful of places, and the bot is the one that’s easy to forget.

1. Game side (your existing work)

Add the field(s) to LevelData, the logic to Board, and a GoalData.Type if it can be a goal.
Update LevelData.validate() so it flags impossible setups, such as a goal for a mechanic the level doesn’t have. The generator runs validate() on every candidate and rejects any that fail.

2. Generator side (level_generator.gd)

Register it. Add it to the Mech enum, UNLOCK (the difficulty where it first appears) and MECH_NAMES.
Configure it. Add a branch to _setup() that sets the level fields from intensity, t and area, and returns a goal or null. The existing branches are templates. Scale counts to the board area, keep goal amounts at or below what exists, and make dangerous parameters (like short bomb fuses) late-game only.
Pairing rules. If it interacts badly with another mechanic, filter that combination in _plan(). Otherwise the existing budget already limits how many mechanics stack.

3. Teach the bot (the step that matters most)
Calibration is only as good as the bot’s understanding of the mechanic. If the bot ignores it, the move limit gets set as if the mechanic weren’t there. The level will look fine in the builder and play wrong.

Goal or pressure value: add a case to _cell_values() giving cells a bonus when clearing them advances the goal or relieves pressure. This is where the “want_*” flags and bonuses live.
New move types: if the mechanic adds a new kind of move, such as a different selection shape or a special tile you tap, _candidates() has to generate it. Squares are the existing example, with close_len and a custom path.
New ways to lose: if it can end the level the way a bomb does, extend _play() and calibrate(). Right now only bomb explosions are counted as non-move-limit losses, with the max_explode check.

4. Builder side (level_builder.gd)

Add the new LevelData fields to _copy_level so duplicating and importing keep them. It’s easy to forget because nothing breaks until you duplicate a level.
Add a form control for the new field(s).
Update the BoardPreview drawing if the mechanic has a visual.

5. Tune with a test batch
Generate a batch with the new mechanic at the difficulties where it’s unlocked and read the printed moves and bot win rates. Watch for:

levels that are always rejected, which means the intensity range is unreachable
very low or very high move counts, which means the amounts are off
a bot win rate that doesn’t match your experience when you play it, which means the bot’s valuation is wrong

Then play a few by hand. A good first test is to compare the bot’s results on a level with the mechanic against the same level without it. If they barely differ, the bot isn’t engaging with it.

If you tell me the next mechanic, I can draft the exact _setup, _cell_values and builder changes for it.


"""
