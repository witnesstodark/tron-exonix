extends Node2D

# QIX: Territory Reveal — playable prototype (Xonix / AirXonix mechanics).
# One script, no assets: grid state + _draw(). Tron palette per concept art.

const CELL := 20
const GRID_W := 48
const GRID_H := 30
const HUD_H := 40
const BORDER := 2
const WIN_PERCENT := 75.0
const MOVE_INTERVAL := 0.06   # player: one cell per tick
const BALL_SPEED := 11.0      # cells per second
const BALL_COUNT := 2
const START_LIVES := 3

enum { SEA, LAND, TRAIL }

const COL_BG := Color("050a14")
const COL_LAND := Color("11314f")
const COL_LAND_EDGE := Color(0.0, 0.9, 1.0, 0.13)
const COL_TRAIL := Color("ff2d78")
const COL_PLAYER := Color("00e5ff")
const COL_BALL := Color("ffb020")
const COL_TEXT := Color("9adcff")

var grid := PackedInt32Array()
var player := Vector2i.ZERO
var dir := Vector2i.ZERO
var move_timer := 0.0
var balls: Array = []          # { pos: Vector2 (cells), vel: Vector2 (cells/s) }
var lives := START_LIVES
var initial_land := 0
var percent := 0.0
var state := "play"            # play | over | win


func _ready() -> void:
	randomize()
	grid.resize(GRID_W * GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			var is_border := x < BORDER or y < BORDER or x >= GRID_W - BORDER or y >= GRID_H - BORDER
			grid[y * GRID_W + x] = LAND if is_border else SEA
	initial_land = count_land()
	player = Vector2i(int(GRID_W / 2.0), BORDER - 1)
	for i in BALL_COUNT:
		balls.append({
			"pos": Vector2(randf_range(GRID_W * 0.3, GRID_W * 0.7), randf_range(GRID_H * 0.3, GRID_H * 0.7)),
			"vel": Vector2(BALL_SPEED * (1.0 if randf() < 0.5 else -1.0), BALL_SPEED * (1.0 if randf() < 0.5 else -1.0)),
		})
	update_percent()


func cell(c: Vector2i) -> int:
	return grid[c.y * GRID_W + c.x]


func set_cell(c: Vector2i, v: int) -> void:
	grid[c.y * GRID_W + c.x] = v


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < GRID_W and c.y < GRID_H


func count_land() -> int:
	var n := 0
	for v in grid:
		if v == LAND:
			n += 1
	return n


func update_percent() -> void:
	var total_sea := GRID_W * GRID_H - initial_land
	percent = 100.0 * float(count_land() - initial_land) / float(total_sea)


func _process(delta: float) -> void:
	if Input.is_physical_key_pressed(KEY_ESCAPE):
		get_tree().quit()
	if state != "play":
		if Input.is_physical_key_pressed(KEY_R):
			get_tree().reload_current_scene()
		return
	read_input()
	move_timer += delta
	while move_timer >= MOVE_INTERVAL:
		move_timer -= MOVE_INTERVAL
		step_player()
		if state != "play":
			return
	move_balls(delta)
	check_ball_hits()
	queue_redraw()


func read_input() -> void:
	var d := Vector2i.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT) or Input.is_physical_key_pressed(KEY_A):
		d = Vector2i.LEFT
	elif Input.is_physical_key_pressed(KEY_RIGHT) or Input.is_physical_key_pressed(KEY_D):
		d = Vector2i.RIGHT
	elif Input.is_physical_key_pressed(KEY_UP) or Input.is_physical_key_pressed(KEY_W):
		d = Vector2i.UP
	elif Input.is_physical_key_pressed(KEY_DOWN) or Input.is_physical_key_pressed(KEY_S):
		d = Vector2i.DOWN
	if d != Vector2i.ZERO:
		dir = d
	elif cell(player) == LAND:
		dir = Vector2i.ZERO   # on land you may stand still; in the sea you can't stop


func step_player() -> void:
	if dir == Vector2i.ZERO:
		return
	var next := player + dir
	if not in_bounds(next):
		return
	if cell(next) == TRAIL:
		die()   # crossing your own trail is fatal, as the classics demand
		return
	var was_on_land := cell(player) == LAND
	player = next
	if cell(player) == SEA:
		set_cell(player, TRAIL)
	elif cell(player) == LAND and not was_on_land:
		capture()


func capture() -> void:
	for i in grid.size():
		if grid[i] == TRAIL:
			grid[i] = LAND
	# Flood-fill the sea from every ball; unreachable sea becomes yours.
	var reached := {}
	var queue: Array[Vector2i] = []
	for b in balls:
		var c := Vector2i(b.pos)
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
	for y in GRID_H:
		for x in GRID_W:
			var c := Vector2i(x, y)
			if cell(c) == SEA and not reached.has(c):
				set_cell(c, LAND)
	update_percent()
	if percent >= WIN_PERCENT:
		state = "win"


func solid(c: Vector2i) -> bool:
	if not in_bounds(c):
		return true
	return cell(c) == LAND


func move_balls(delta: float) -> void:
	for b in balls:
		var p: Vector2 = b.pos
		var v: Vector2 = b.vel
		var np := p + v * delta
		if solid(Vector2i(Vector2(np.x, p.y))):
			v.x = -v.x
		if solid(Vector2i(Vector2(p.x, np.y))):
			v.y = -v.y
		np = p + v * delta
		if solid(Vector2i(np)):
			np = p
		b.pos = np
		b.vel = v


func check_ball_hits() -> void:
	for b in balls:
		var c := Vector2i(b.pos)
		if not in_bounds(c):
			continue
		if cell(c) == TRAIL or (c == player and cell(player) != LAND):
			die()
			return


func die() -> void:
	lives -= 1
	for i in grid.size():
		if grid[i] == TRAIL:
			grid[i] = SEA
	player = Vector2i(int(GRID_W / 2.0), BORDER - 1)
	dir = Vector2i.ZERO
	move_timer = 0.0
	if lives <= 0:
		state = "over"
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(0, 0, GRID_W * CELL, HUD_H + GRID_H * CELL), COL_BG)
	for y in GRID_H:
		for x in GRID_W:
			var s := grid[y * GRID_W + x]
			if s == SEA:
				continue
			var r := Rect2(x * CELL + 1, HUD_H + y * CELL + 1, CELL - 2, CELL - 2)
			if s == LAND:
				draw_rect(r, COL_LAND)
				draw_rect(r, COL_LAND_EDGE, false, 1.0)
			else:
				draw_rect(Rect2(x * CELL, HUD_H + y * CELL, CELL, CELL), COL_TRAIL)
	# player
	var pr := Rect2(player.x * CELL + 2, HUD_H + player.y * CELL + 2, CELL - 4, CELL - 4)
	draw_rect(pr, COL_PLAYER)
	draw_rect(pr.grow(2.0), Color(1, 1, 1, 0.8), false, 2.0)
	# balls
	for b in balls:
		var pos: Vector2 = b.pos
		var center := Vector2(pos.x * CELL, HUD_H + pos.y * CELL)
		draw_circle(center, CELL * 0.42, COL_BALL)
		draw_circle(center, CELL * 0.16, Color.WHITE)
	# HUD
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(14, 27), "CAPTURED %d%%  /  TARGET %d%%" % [int(percent), int(WIN_PERCENT)], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, COL_TEXT)
	draw_string(font, Vector2(400, 27), "LIVES: %d" % lives, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, COL_TRAIL if lives == 1 else COL_TEXT)
	draw_string(font, Vector2(0, 27), "ARROWS / WASD — MOVE      R — RESTART", HORIZONTAL_ALIGNMENT_RIGHT, GRID_W * CELL - 14, 16, Color(0.6, 0.86, 1.0, 0.55))
	# overlays
	if state != "play":
		draw_rect(Rect2(0, 0, GRID_W * CELL, HUD_H + GRID_H * CELL), Color(0.02, 0.04, 0.08, 0.82))
		var msg := "TERRITORY SECURED" if state == "win" else "GAME OVER"
		var col := COL_PLAYER if state == "win" else COL_TRAIL
		draw_string(font, Vector2(0, 300), msg, HORIZONTAL_ALIGNMENT_CENTER, GRID_W * CELL, 46, col)
		draw_string(font, Vector2(0, 350), "PRESS R TO RESTART", HORIZONTAL_ALIGNMENT_CENTER, GRID_W * CELL, 20, COL_TEXT)
