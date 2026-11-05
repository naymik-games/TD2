class_name GoalData
extends Resource
## One goal in a level. A level can have up to LevelData.MAX_GOALS of these.

## BOMB = defuse this many bombs, ROCK = break this many rocks.
enum Type { COLOR, ANCHOR, ICE, BOMB, ROCK }

@export var type: Type = Type.COLOR
## Which dot color to clear (index into the palette, 0-5). Only used when type is COLOR.
@export_range(0, 5) var color := 0
## How many to clear / collect / break.
@export_range(1, 999) var amount := 10


## Convenience for building goals in code (the sample levels use this).
static func make(p_type: Type, p_amount: int, p_color := 0) -> GoalData:
	var g := GoalData.new()
	g.type = p_type
	g.amount = p_amount
	g.color = p_color
	return g
