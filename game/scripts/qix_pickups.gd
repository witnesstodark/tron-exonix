class_name QixPickups
extends RefCounted
## Pickup system data/logic (see the Mechanics tab): weighted spawns on claimed
## ground, fall-from-sky -> float, ~10s lifetime with a 3s expiry blink.
## main.gd owns the nodes and applies the effects.

const LIFETIME := 10.0
const BLINK_AT := 7.0            # last 3s blink
const FALL_SPEED := 42.0
const FLOAT_H := 1.35            # float height above the platform top
const SPAWN_EVERY_MIN := 1.0     # keep ~MAX_ON_BOARD pickups out there at all times
const SPAWN_EVERY_MAX := 2.2
const MAX_ON_BOARD := 4          # baseline; big maps (L5+) raise max_cap to 6
var max_cap := MAX_ON_BOARD      # set per level by main
var time_left := 99.0            # main feeds the clock — low time = generosity

# spawn weights — SURPRISE dominates (it is the debuff delivery vehicle:
# 65% bad / 35% good on open); raw red pickups are rare, nobody collects
# them voluntarily — they mostly exist as ball-bait that pops
const WEIGHTS := {
	"bonus_speed": 0.09, "bonus_freeze": 0.09, "bonus_time": 0.12,
	"bonus_score": 0.12, "bonus_life": 0.04,
	"debuff_blackout": 0.05, "debuff_meteor": 0.05, "debuff_enemyfast": 0.05,
	"debuff_selfslow": 0.05, "debuff_addball": 0.05, "surprise": 0.35,
	# ULTIMATES: ZA WARUDO may drop standalone at 1/3 of a regular bonus
	# (Stefan); BALLMAGEDDON stays surprise-only. The surprise jackpot gate
	# excludes both from its normal pools regardless of weight.
	"bonus_zawarudo": 0.03, "debuff_ballmageddon": 0.0,
}

var items: Array = []            # {kind, cell: Vector2i, y, state: fall|float, age, node}
var spawn_timer := 1.5
var time_spawned := false
var elapsed := 0.0
var started := false             # set on first deploy — the ramp counts from there


func pick_kind() -> String:
	# guarantee the clock shows up once per level after 25s
	if not time_spawned and elapsed > 20.0:
		time_spawned = true
		return "bonus_time"
	var eff := {}
	for kind in WEIGHTS:
		var w: float = WEIGHTS[kind]
		if kind == "bonus_time" and time_left < 15.0:
			w *= 4.0   # the clock is dying — time drops get likely
		eff[kind] = w
	var total := 0.0
	for w in eff.values():
		total += w
	var r := randf() * total
	for kind in eff:
		r -= eff[kind]
		if r <= 0.0:
			if kind == "bonus_time":
				time_spawned = true
			return kind
	return "bonus_score"


## Returns a spawn request {kind, cell} or {} — main creates the node.
## Ramp-up: nothing before ~5s of play, then the on-board cap climbs one
## pickup per 5s until the full MAX_ON_BOARD (~20s) — slow start, then boom.
func update_spawn(delta: float, board: QixBoard, player: Vector2i) -> Dictionary:
	if not started:
		return {}
	elapsed += delta
	spawn_timer -= delta
	var cap := int(clamp(1.0 + (elapsed - 5.0) / 5.0, 0.0, float(max_cap)))
	if time_left < 20.0:
		cap += 1   # endgame generosity: one extra pickup slot
	if spawn_timer > 0.0 or items.size() >= cap:
		return {}
	spawn_timer = randf_range(SPAWN_EVERY_MIN, SPAWN_EVERY_MAX) * (0.55 if time_left < 20.0 else 1.0)
	# drops land on claimed ground OR the open sea (~40%) — sea ones are
	# ball-bait: a ball hit blows them up (main handles the burst VFX)
	var want_sea := randf() < 0.4
	for attempt in 140:
		var c := Vector2i(randi_range(0, QixConfig.GRID_W - 1), randi_range(0, QixConfig.GRID_H - 1))
		var v := board.cell(c)
		if v != QixBoard.LAND and v != QixBoard.SEA:
			continue
		if attempt < 70 and want_sea != (v == QixBoard.SEA):
			continue   # soft preference; falls back to anything after 70 tries
		if Vector2(c - player).length() < 6.0:
			continue
		var taken := false
		for it in items:
			if it.cell == c:
				taken = true
				break
		if taken:
			continue
		var it := {"kind": pick_kind(), "cell": c, "y": 20.0, "state": "fall", "age": 0.0, "node": null}
		items.append(it)
		return it
	return {}


## Fall/float/lifetime; returns {collected: [items], expired: [items]}.
## Ground height is dynamic: sea-level for open water, platform top for claimed
## cells (re-checked each frame — captured ground can rise under a floater).
func update_items(delta: float, player: Vector2i, top_y: float, board: QixBoard) -> Dictionary:
	var collected: Array = []
	var expired: Array = []
	for it in items:
		var g: float = top_y if board.cell(it.cell) == QixBoard.LAND else 0.0
		it["ground"] = g
		if it.state == "fall":
			it.y -= FALL_SPEED * delta
			if it.y <= g + FLOAT_H:
				it.y = g + FLOAT_H
				it.state = "float"
		else:
			it.y = move_toward(float(it.y), g + FLOAT_H, delta * 4.0)
			it.age += delta
			if it.age >= LIFETIME:
				expired.append(it)
				continue
			if player == it.cell or Vector2(player - Vector2i(it.cell)).length() < 2.2:
				collected.append(it)   # generous scoop — no pixel-perfect pickup runs
	for it in collected + expired:
		items.erase(it)
	return {"collected": collected, "expired": expired}
