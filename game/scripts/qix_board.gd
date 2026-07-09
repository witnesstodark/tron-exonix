class_name QixBoard
extends RefCounted
## Pure grid state: SEA / LAND / TRAIL cells, flood-fill capture, smash bites.
## No scene nodes here — visuals read this state and render it.

enum { SEA, LAND, TRAIL }

var grid := PackedInt32Array()
var initial_land := 0
var percent := 0.0
var land_dirty := true
var trail_dirty := true
var last_claimed: Array[Vector2i] = []   # cells that became LAND in the last capture()
var last_smashed: Array[Vector2i] = []   # cells destroyed in the last smash()


func reset() -> void:
	grid.resize(QixConfig.GRID_W * QixConfig.GRID_H)
	for y in QixConfig.GRID_H:
		for x in QixConfig.GRID_W:
			grid[y * QixConfig.GRID_W + x] = LAND if is_rim(Vector2i(x, y)) else SEA
	initial_land = count_land()
	percent = 0.0
	land_dirty = true
	trail_dirty = true


func is_rim(c: Vector2i) -> bool:
	return c.x < QixConfig.BORDER or c.y < QixConfig.BORDER \
		or c.x >= QixConfig.GRID_W - QixConfig.BORDER or c.y >= QixConfig.GRID_H - QixConfig.BORDER


func cell(c: Vector2i) -> int:
	return grid[c.y * QixConfig.GRID_W + c.x]


func set_cell(c: Vector2i, v: int) -> void:
	grid[c.y * QixConfig.GRID_W + c.x] = v


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < QixConfig.GRID_W and c.y < QixConfig.GRID_H


func solid(c: Vector2i) -> bool:
	if not in_bounds(c):
		return true
	return cell(c) == LAND


func land_at(c: Vector2i) -> bool:
	return in_bounds(c) and cell(c) == LAND


func count_land() -> int:
	var n := 0
	for v in grid:
		if v == LAND:
			n += 1
	return n


func update_percent() -> void:
	var total_sea := QixConfig.GRID_W * QixConfig.GRID_H - initial_land
	percent = 100.0 * float(count_land() - initial_land) / float(total_sea)


func clear_trail() -> void:
	for i in grid.size():
		if grid[i] == TRAIL:
			grid[i] = SEA
	trail_dirty = true


## Close the cut: trail becomes land; sea regions unreachable from any ball
## get claimed. Returns true when the win threshold is passed.
func capture(ball_cells: Array) -> bool:
	last_claimed.clear()
	for i in grid.size():
		if grid[i] == TRAIL:
			grid[i] = LAND
			@warning_ignore("integer_division")
			last_claimed.append(Vector2i(i % QixConfig.GRID_W, i / QixConfig.GRID_W))
	var reached := {}
	var queue: Array[Vector2i] = []
	for c in ball_cells:
		if in_bounds(c) and cell(c) == SEA and not reached.has(c):
			reached[c] = true
			queue.append(c)
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n: Vector2i = c + d
			if in_bounds(n) and cell(n) == SEA and not reached.has(n):
				reached[n] = true
				queue.append(n)
	for y in QixConfig.GRID_H:
		for x in QixConfig.GRID_W:
			var c := Vector2i(x, y)
			if cell(c) == SEA and not reached.has(c):
				set_cell(c, LAND)
				last_claimed.append(c)
	land_dirty = true
	trail_dirty = true
	update_percent()
	return percent >= QixConfig.WIN_PERCENT


## Hard/evil ball bite: destroy the hit cell + orthogonal land neighbours.
## The rim and the protected cell (player) are indestructible.
func smash(c: Vector2i, protect: Vector2i) -> void:
	# NOTE: last_smashed ACCUMULATES; main consumes and clears it each frame
	var changed := false
	for d in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var n: Vector2i = c + d
		if not in_bounds(n) or n == protect or is_rim(n):
			continue
		if cell(n) == LAND:
			set_cell(n, SEA)
			last_smashed.append(n)
			changed = true
	if changed:
		land_dirty = true
		update_percent()
