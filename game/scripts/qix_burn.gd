class_name QixBurn
extends RefCounted
## Trail burn: when a ball hits the line, two fronts eat the trail from the hit
## point at BURN_SPEED_MUL x player speed. Reach land first -> surviving line
## becomes platform; the burn reaching the player first -> death.

var board: QixBoard
var path: Array[Vector2i] = []   # ordered trail cells, oldest -> player end
var active := false
var _lo_f := 0.0
var _hi_f := 0.0
var _next_lo := -1
var _next_hi := -1


func _init(p_board: QixBoard) -> void:
	board = p_board


func reset() -> void:
	active = false
	path.clear()


## Path indices of the two burn fronts ((-999,-999) when inactive) — the wall
## recolor uses these to spread the red heat outward from the impact point.
func front_indices() -> Vector2i:
	return Vector2i(_next_lo, _next_hi) if active else Vector2i(-999, -999)


## Current burn-front cells (for the in-world fire markers).
func front_cells() -> Array:
	if not active:
		return []
	var out: Array = []
	if _next_lo >= 0 and _next_lo < path.size():
		out.append(path[_next_lo])
	if _next_hi >= 0 and _next_hi < path.size() and _next_hi != _next_lo:
		out.append(path[_next_hi])
	return out


func on_player_cut(c: Vector2i) -> void:
	path.append(c)


func start(c: Vector2i) -> void:
	var idx := path.find(c)
	if idx < 0:
		return
	active = true
	_lo_f = float(idx)
	_hi_f = float(idx)
	_next_lo = idx
	_next_hi = idx


## Returns true if the burn caught the player this tick.
func update(delta: float, player: Vector2i) -> bool:
	if not active:
		return false
	var adv := delta * QixConfig.BURN_SPEED_MUL / QixConfig.MOVE_INTERVAL
	_lo_f -= adv
	_hi_f += adv
	while _next_lo >= 0 and float(_next_lo) >= _lo_f:
		var c := path[_next_lo]
		if board.in_bounds(c) and board.cell(c) == QixBoard.TRAIL:
			board.set_cell(c, QixBoard.SEA)
			board.trail_dirty = true
		_next_lo -= 1
	while _next_hi < path.size() and float(_next_hi) <= _hi_f:
		var c := path[_next_hi]
		if c == player:
			return true
		if board.in_bounds(c) and board.cell(c) == QixBoard.TRAIL:
			board.set_cell(c, QixBoard.SEA)
			board.trail_dirty = true
		_next_hi += 1
	if _next_lo < 0 and _next_hi >= path.size():
		active = false
	return false
