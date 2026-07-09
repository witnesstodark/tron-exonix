class_name QixEnemies
extends RefCounted
## Balls (soft/hard/evil) roaming the sea + mines patrolling claimed ground.
## Owns the data; main.gd owns the scene nodes (stored in each entry as "node").

var board: QixBoard
var balls: Array = []   # {type, pos, vel, base_speed, radius, crash_cd, node, [temp_t]}
var mines: Array = []   # {pos: Vector2, vel: Vector2, node}
var obstacles: Array = []   # SP bumpers {pos, radius, hp, cd, flash, node}
var saws: Array = []        # slow cutters {pos, dir, turn_t, carving, node}
var speed_scale := 1.0  # pickup effects: freeze 0.5 / enemyfast 1.5 / normal 1.0
var penetration := false  # meteor debuff: balls pass through and DESTROY claimed ground
var sound_events: Array = []   # {n: sfx name, pos: Vector2} — main drains every frame


## What blocks a ball right now? For a penetrating ball (meteor mode, hard/evil
## only) just the rim and the arena bounds — everything else gets carved through.
func _blocks(c: Vector2i, pen: bool) -> bool:
	if not board.in_bounds(c):
		return true
	if pen:
		return board.is_rim(c)
	return board.cell(c) == QixBoard.LAND


func _init(p_board: QixBoard) -> void:
	board = p_board


func spawn_balls(level_cfg: Dictionary) -> void:
	balls.clear()
	mines.clear()
	saws.clear()
	obstacles.clear()
	for type in level_cfg.balls:
		var spec: Dictionary = QixConfig.BALL_TYPES[type]
		var spd: float = float(level_cfg.speed) * float(spec.speed_mul)
		balls.append({
			"type": type,
			"pos": Vector2(randf_range(QixConfig.GRID_W * 0.25, QixConfig.GRID_W * 0.75),
					randf_range(QixConfig.GRID_H * 0.25, QixConfig.GRID_H * 0.75)),
			"vel": Vector2(spd * (1.0 if randf() < 0.5 else -1.0), spd * (1.0 if randf() < 0.5 else -1.0)).normalized() * spd,
			"base_speed": spd,
			"radius": QixConfig.BALL_DIAMETER * float(spec.size_mul) * 0.5,
			"crash_cd": 0.0,
			"node": null,
		})


## Capture flood-fill seeds: balls AND saws — territory holding ANY enemy
## cannot be claimed (the saw counts as a ball here).
func ball_cells() -> Array:
	var out: Array = []
	for b in balls:
		out.append(Vector2i(b.pos))
	for s in saws:
		out.append(Vector2i(s.pos))
	return out


## Move balls; returns an Array of smashed cells (for effects, if wanted).
func move_balls(delta: float, player: Vector2i) -> void:
	for o in obstacles:
		o.cd = maxf(0.0, float(o.cd) - delta)
	for b in balls:
		var spec: Dictionary = QixConfig.BALL_TYPES[b.type]
		# meteor mode only turns HARD/EVIL balls into drills; softs just speed up
		var pen := penetration and not String(b.type).begins_with("soft")
		var p: Vector2 = b.pos
		var v: Vector2 = b.vel
		b.crash_cd = max(0.0, float(b.crash_cd) - delta)
		if bool(spec.homing):
			var to_player := Vector2(player.x + 0.5, player.y + 0.5) - p
			if to_player.length() > 0.01:
				var cur := v.angle()
				var diff := wrapf(to_player.angle() - cur, -PI, PI)
				var max_turn := QixConfig.EVIL_TURN_RATE * delta
				v = Vector2.from_angle(cur + clamp(diff, -max_turn, max_turn)) * v.length()
		var r: float = float(b.get("radius", QixConfig.BALL_DIAMETER * 0.5))
		var hit_cell := Vector2i.ZERO
		var bounced := false
		# --- axis-separated moves, EDGE-SAMPLED (rewrite 2026-07-09, the notch
		# trap): each leading edge is probed at its center AND both shoulders
		# (±0.7r), so a gap NARROWER than the ball rejects the whole ball in one
		# frame — it simply bounces (a wedge flips both axes: in-and-out, one
		# frame, never stuck). A blocked axis does not move that frame; the
		# other axis stays free, so glancing hits keep sliding naturally.
		if absf(v.x) > 0.0:
			var nx := p.x + v.x * delta
			var lead_x := nx + signf(v.x) * r
			var blocked_x := false
			for oy in [-0.7 * r, 0.0, 0.7 * r]:
				var pr := Vector2(lead_x, p.y + oy)
				if _blocks(Vector2i(pr), pen):
					blocked_x = true
					hit_cell = Vector2i(pr)
					break
			if blocked_x:
				v.x = -v.x
				bounced = true
			else:
				p.x = nx
		if absf(v.y) > 0.0:
			var ny := p.y + v.y * delta
			var lead_y := ny + signf(v.y) * r
			var blocked_y := false
			for ox in [-0.7 * r, 0.0, 0.7 * r]:
				var pr2 := Vector2(p.x + ox, lead_y)
				if _blocks(Vector2i(pr2), pen):
					blocked_y = true
					hit_cell = Vector2i(pr2)
					break
			if blocked_y:
				v.y = -v.y
				bounced = true
			else:
				p.y = ny
		var np := p
		if bounced:
			sound_events.append({"n": "bounce_hard" if bool(spec.crash) else "bounce_soft", "pos": p})
		if bounced and bool(spec.crash) and float(b.crash_cd) <= 0.0 and not pen:
			# crashers chip the cell they slammed into — a 1-wide hole gets
			# WIDENED on the next hits until the ball genuinely fits through
			board.smash(hit_cell, player)
			b.crash_cd = QixConfig.CRASH_COOLDOWN
			sound_events.append({"n": "smash", "pos": Vector2(hit_cell)})
		# hard rescue: center buried in land (capture/smash under the ball)
		if _blocks(Vector2i(np), pen) and not pen:
			var esc := _nearest_open(Vector2i(np))
			if esc.x >= 0:
				var dirv := (Vector2(esc.x + 0.5, esc.y + 0.5) - np).normalized()
				np += dirv * v.length() * delta * 2.0
				v = dirv * v.length()
		# penetration: carve the ground the ball passes over (hard/evil only)
		if pen:
			var cc := Vector2i(np)
			if board.in_bounds(cc) and not board.is_rim(cc) and board.cell(cc) == QixBoard.LAND:
				for d in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
					var n: Vector2i = cc + d
					if board.in_bounds(n) and not board.is_rim(n) and n != player and board.cell(n) == QixBoard.LAND:
						board.set_cell(n, QixBoard.SEA)
						board.last_smashed.append(n)
				board.land_dirty = true
				board.update_percent()
		# SP obstacles: circular bumpers; each solid hit chips one HP
		for o in obstacles:
			var od := np - Vector2(o.pos)
			var odl := od.length()
			var orr: float = float(o.radius) + r
			if odl < orr and odl > 0.0001:
				var onrm := od / odl
				np = Vector2(o.pos) + onrm * orr
				var ovn := v.dot(onrm)
				if ovn < 0.0:
					v -= 2.0 * ovn * onrm
				if float(o.cd) <= 0.0:
					o.cd = 0.3
					o.hp = int(o.hp) - 1
					o.flash = true
		# the SAW is an immovable bumper: balls bounce, the saw never reacts
		for sw in saws:
			var sd := np - Vector2(sw.pos)
			var sdl := sd.length()
			var srr: float = QixConfig.SAW_RADIUS + r
			if sdl < srr and sdl > 0.0001:
				var snrm := sd / sdl
				np = Vector2(sw.pos) + snrm * srr
				var svn := v.dot(snrm)
				if svn < 0.0:
					v -= 2.0 * svn * snrm
		b.pos = np
		b.vel = v
	_collide_balls()
	_regulate_speeds(delta)


## Nearest non-blocking cell (spiral search); (-1,-1) if none close.
func _nearest_open(c: Vector2i) -> Vector2i:
	for radius in range(1, 7):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if max(abs(dx), abs(dy)) != radius:
					continue
				var n := c + Vector2i(dx, dy)
				if board.in_bounds(n) and board.cell(n) == QixBoard.SEA:
					return n
	return Vector2i(-1, -1)


## Speed law: default speed is the FLOOR; collision boosts decay back to
## default within ~1.5s. (Debuffs/bonuses will scale base_speed itself.)
func _regulate_speeds(delta: float) -> void:
	for b in balls:
		var base: float = float(b.base_speed) * speed_scale
		if penetration and String(b.type).begins_with("soft"):
			base *= 2.0   # meteor: softs can't carve — they rage at double speed
		var v: Vector2 = b.vel
		var sp := v.length()
		if sp < 0.001:
			b.vel = Vector2(base, 0).rotated(randf() * TAU)
			continue
		if sp < base:
			sp = base
		elif sp > base:
			# exponential decay: excess is ~95% gone in 1.5s (tau = 0.5)
			sp = base + (sp - base) * exp(-delta / 0.5)
			if sp - base < 0.05:
				sp = base
		b.vel = v / v.length() * sp


## Billiard-style ball-vs-ball: equal-mass elastic collision — exchange the
## velocity components along the contact normal, keep the tangential ones.
func _collide_balls() -> void:
	for i in balls.size():
		for j in range(i + 1, balls.size()):
			var a: Dictionary = balls[i]
			var b: Dictionary = balls[j]
			var d: Vector2 = Vector2(b.pos) - Vector2(a.pos)
			var dist := d.length()
			# REAL radii: hard balls are 1.3x — they used to overlap before bouncing
			var rr: float = float(a.get("radius", QixConfig.BALL_DIAMETER * 0.5)) 					+ float(b.get("radius", QixConfig.BALL_DIAMETER * 0.5))
			if dist <= 0.0001 or dist >= rr:
				continue
			var n := d / dist
			# push apart so they don't stick
			var overlap := rr - dist
			a.pos = Vector2(a.pos) - n * overlap * 0.5
			b.pos = Vector2(b.pos) + n * overlap * 0.5
			# exchange normal components only when approaching
			var v1n: float = Vector2(a.vel).dot(n)
			var v2n: float = Vector2(b.vel).dot(n)
			if v1n - v2n > 0.0:
				a.vel = (Vector2(a.vel) + n * (v2n - v1n)) * 1.12   # small kick, decays via _regulate_speeds
				b.vel = (Vector2(b.vel) + n * (v1n - v2n)) * 1.12
				sound_events.append({"n": "bounce_soft", "pos": Vector2(a.pos)})


func update_mines(delta: float, player: Vector2i) -> void:
	for m in mines:
		var p: Vector2 = m.pos
		var v: Vector2 = m.vel
		var np := p + v * delta
		# HUNTER mine (Stefan L5): drifts straight at the player, the surface
		# means nothing to it. Obstacles are the only thing that stops it —
		# and the crash is mutual: obstacle destroyed, mine gone (main sweeps
		# entries flagged "dead": explosion FX + node cleanup).
		if String(m.get("kind", "")) == "hunter":
			var target := Vector2(player.x + 0.5, player.y + 0.5)
			var dirv := target - p
			if dirv.length() > 0.01:
				v = dirv.normalized() * QixConfig.HUNTER_SPEED
			np = p + v * delta
			for o in obstacles:
				if (np - Vector2(o.pos)).length() < float(o.radius) + 1.2:
					o.hp = 0
					o.flash = true
					m["dead"] = true
					break
			m.pos = np
			m.vel = v
			continue
		# GHOST mode: a stranded mine (ground destroyed under it / boxed in)
		# flies STRAIGHT over anything until it reaches stable claimed ground —
		# mines never stand still (Stefan's rule)
		if bool(m.get("ghost", false)) or not board.land_at(Vector2i(p)):
			m["ghost"] = true
			if np.x < 0.5 or np.x > QixConfig.GRID_W - 0.5:
				v.x = -v.x
			if np.y < 0.5 or np.y > QixConfig.GRID_H - 0.5:
				v.y = -v.y
			np = p + v * delta
			if board.land_at(Vector2i(np)):
				m["ghost"] = false
			m.pos = np
			m.vel = v
			continue
		if not board.land_at(Vector2i(Vector2(np.x, p.y))):
			v.x = -v.x
		if not board.land_at(Vector2i(Vector2(p.x, np.y))):
			v.y = -v.y
		np = p + v * delta
		if not board.land_at(Vector2i(np)):
			# no legal land step at all -> go ghost and keep moving
			m["ghost"] = true
			np = p + v * delta
		# mines chip SP obstacles exactly like balls do
		for o in obstacles:
			var od := np - Vector2(o.pos)
			var odl := od.length()
			var orr: float = float(o.radius) + 1.4
			if odl < orr and odl > 0.0001:
				var onrm := od / odl
				np = Vector2(o.pos) + onrm * orr
				var ovn := v.dot(onrm)
				if ovn < 0.0:
					v -= 2.0 * ovn * onrm
				if float(o.cd) <= 0.0:
					o.cd = 0.3
					o.hp = int(o.hp) - 1
					o.flash = true
		m.pos = np
		m.vel = v


func spawn_saw_data(player: Vector2i) -> Dictionary:
	var dirs := [Vector2.RIGHT, Vector2.LEFT, Vector2(0.0, 1.0), Vector2(0.0, -1.0)]
	for attempt in 200:
		var c := Vector2i(randi_range(QixConfig.BORDER + 2, QixConfig.GRID_W - QixConfig.BORDER - 3),
				randi_range(QixConfig.BORDER + 2, QixConfig.GRID_H - QixConfig.BORDER - 3))
		if Vector2(c - player).length() < 18.0:
			continue
		var s := {"pos": Vector2(c.x + 0.5, c.y + 0.5), "dir": dirs[randi_range(0, 3)],
				"turn_t": randf_range(QixConfig.SAW_TURN_MIN, QixConfig.SAW_TURN_MAX),
				"carving": false, "carve_t": 0.0, "node": null}
		saws.append(s)
		return s
	return {}


## Slow axis-aligned wanderer: straight lines, occasional random 90° turns,
## carves EVERYTHING beneath the blade (rim and the player's cell excepted).
func update_saws(delta: float, player: Vector2i) -> void:
	for s in saws:
		s.turn_t = float(s.turn_t) - delta
		if float(s.turn_t) <= 0.0:
			s.turn_t = randf_range(QixConfig.SAW_TURN_MIN, QixConfig.SAW_TURN_MAX)
			var d: Vector2 = s.dir
			var pick := randi_range(0, 2)   # straight / left / right — never reverse
			if pick == 1:
				d = Vector2(d.y, -d.x)
			elif pick == 2:
				d = Vector2(-d.y, d.x)
			s.dir = d
		var np: Vector2 = Vector2(s.pos) + Vector2(s.dir) * QixConfig.SAW_SPEED * delta
		var lo := float(QixConfig.BORDER) + 1.5
		var hix := float(QixConfig.GRID_W - QixConfig.BORDER) - 1.5
		var hiy := float(QixConfig.GRID_H - QixConfig.BORDER) - 1.5
		if np.x < lo or np.x > hix or np.y < lo or np.y > hiy:
			np = s.pos
			var d2: Vector2 = s.dir
			s.dir = Vector2(d2.y, -d2.x) if randf() < 0.5 else Vector2(-d2.y, d2.x)
		s.pos = np
		# carve the ground under the blade
		s.carving = false
		var cc := Vector2i(np)
		for doff in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n: Vector2i = cc + doff
			if board.in_bounds(n) and not board.is_rim(n) and n != player and board.cell(n) == QixBoard.LAND:
				board.set_cell(n, QixBoard.SEA)
				board.last_smashed.append(n)
				s.carving = true
		if s.carving:
			board.land_dirty = true
			board.update_percent()
			s.carve_t = 0.3   # latch: sparks stay lit between carve frames
		else:
			s.carve_t = maxf(0.0, float(s.carve_t) - delta)


## The +1-ball debuff, reworked (Stefan 2026-07-09): SPLIT a random existing
## soft-family or hard ball — the clone launches the opposite way and expires
## after `life` seconds. Evil balls never split. Empty dict if no candidate.
func split_ball(life: float) -> Dictionary:
	var pool: Array = []
	for b in balls:
		var t := String(b.type)
		if t.begins_with("soft") or t == "hard":
			pool.append(b)
	if pool.is_empty():
		return {}
	var src: Dictionary = pool[randi_range(0, pool.size() - 1)]
	var b := {
		"type": src.type,
		"pos": Vector2(src.pos),
		"vel": -Vector2(src.vel),   # the two halves fly apart
		"base_speed": src.base_speed,
		"radius": src.radius,
		"crash_cd": 0.0,
		"node": null,
		"temp_t": life,
	}
	balls.append(b)
	return b


## Tick temp-ball lifetimes; returns expired entries (main frees their nodes).
func expire_temp_balls(delta: float) -> Array:
	var dead: Array = []
	for b in balls:
		if b.has("temp_t"):
			b.temp_t -= delta
			if float(b.temp_t) <= 0.0:
				dead.append(b)
	for b in dead:
		balls.erase(b)
	return dead


## Wants a new mine? (call each frame; main creates the node)
func want_mine(level_cfg: Dictionary) -> bool:
	return board.percent >= QixConfig.MINE_UNLOCK_PERCENT and mines.size() < int(level_cfg.mines)


func spawn_mine_data(player: Vector2i) -> Dictionary:
	# mines always deploy from the TOP border — never on the player's (bottom) side
	for attempt in 200:
		var c := Vector2i(randi_range(QixConfig.BORDER, QixConfig.GRID_W - QixConfig.BORDER - 1),
				randi_range(0, QixConfig.BORDER - 1))
		if board.cell(c) != QixBoard.LAND:
			continue
		if Vector2(c - player).length() < 10.0:
			continue
		var m := {
			"pos": Vector2(c.x + 0.5, c.y + 0.5),
			"vel": Vector2(QixConfig.MINE_SPEED * (1.0 if randf() < 0.5 else -1.0),
					QixConfig.MINE_SPEED * (1.0 if randf() < 0.5 else -1.0)),
			"node": null,
		}
		mines.append(m)
		return m
	return {}


## BALLMAGEDDON (ultimate debuff): EVERY ball splits at once — the clones fly
## the opposite way and all expire together after `life` seconds.
func ballmageddon(life: float) -> Array:
	var clones: Array = []
	for src in balls.duplicate():
		var b := {
			"type": src.type,
			"pos": Vector2(src.pos),
			"vel": -Vector2(src.vel),
			"base_speed": src.base_speed,
			"radius": src.radius,
			"crash_cd": 0.0,
			"node": null,
			"temp_t": life,
		}
		balls.append(b)
		clones.append(b)
	return clones


## Auto-target mine: deploys like a normal one, then free-flight hunts.
func spawn_hunter_data(player: Vector2i) -> Dictionary:
	var m := spawn_mine_data(player)
	if not m.is_empty():
		m["kind"] = "hunter"
	return m


## Returns: "player" (ball hit the player), "mine" (mine got him),
## a Vector2i (trail cell that was hit -> start the burn), or null.
func check_hits(player: Vector2i, cutting: bool, burn_active: bool) -> Variant:
	var ppos := Vector2(player.x + 0.5, player.y + 0.5)
	for b in balls:
		if cutting and Vector2(b.pos).distance_to(ppos) < float(b.get("radius", 1.0)) + 0.45:
			return "player"
		var c := Vector2i(b.pos)
		if board.in_bounds(c) and board.cell(c) == QixBoard.TRAIL and not burn_active:
			return c
	for m in mines:
		if Vector2(m.pos).distance_to(ppos) < QixConfig.KILL_RADIUS + 0.4:
			return "mine"
	for o in obstacles:
		if Vector2(o.pos).distance_to(ppos) < float(o.radius) + 0.2:
			return "obstacle"
	for sw in saws:
		if Vector2(sw.pos).distance_to(ppos) < QixConfig.SAW_RADIUS + 0.2:
			return "saw"
		var sc := Vector2i(sw.pos)
		if board.in_bounds(sc) and board.cell(sc) == QixBoard.TRAIL and not burn_active:
			return sc
	return null
