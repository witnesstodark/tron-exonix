extends Node3D
## QIX: Territory Reveal — main orchestrator.
## Owns the scene, input, level flow and rendering; game rules live in the
## qix_* modules (see ARCHITECTURE.md). Tuning knobs: scripts/qix_config.gd.

static var level := 0              # persists across scene reloads
static var score := 0              # persists across levels; resets on full restart
static var fly_in := false         # next scene load is a mid-run level transition

var board := QixBoard.new()
var enemies := QixEnemies.new(board)
var burn := QixBurn.new(board)
var pickups := QixPickups.new()

var player := Vector2i.ZERO
var dir := Vector2i.ZERO
var move_timer := 0.0
var lives := QixConfig.START_LIVES
var time_left := QixConfig.LEVEL_TIME
var state := "play"                # play | over | win | final

var land_mm: MultiMesh
var rim_mm: MultiMesh
var trail_mm: MultiMesh
# incremental land multimesh bookkeeping (full 3600-cell rebuilds caused hitches)
var land_list: Array[Vector2i] = []   # instance index -> cell
var land_index := {}                  # cell -> instance index
var rim_index := {}                   # rim cell -> rim instance index
var trail_count := 0
var player_node: Node3D
var hud_level: Label
var hud_percent: Label
var hud_toast: Label                 # pickup-name pop-up under LEVEL/percent
var toast_tw: Tween
var hearts_box: HBoxContainer        # lives as Tron hearts (max 5)
var hearts: Array = []
var timebar_mat: ShaderMaterial      # bottom full-width time bar
var hud_score: Label
var overlay: Label
var menu_box: VBoxContainer
var menu_items: Array = []
var menu_sel := 0
var menu_resume := false
var dim_rect: ColorRect
var board_box: VBoxContainer         # per-level leaderboard panel
var last_entry := {}                 # the run just recorded (for highlight)
var hud_font: SystemFont
var backdrop_mat_ref: ShaderMaterial
var burn_markers: Array = []         # two fire dots riding the burn fronts
var bg_progress := 0.0               # animated web progress (eases UP, snaps DOWN)
var trail_segs: Array = []           # ordered wall segments {a, b}; index == burn path index
const TRAIL_CYAN := Color(0.15, 0.9, 1.0)
const TRAIL_RED := Color(1.0, 0.1, 0.04)
var bg_clock := 0.0                  # clock shared with the backdrop shader
var land_mat: ShaderMaterial
var sea_mat: ShaderMaterial
var land_emission_base := 1.0
var cam: Camera3D
var cam_base_pos: Vector3
var cam_follow_pos := 0.4            # per-level: big grids follow harder
var cam_follow_look := 0.5
var cam_base_look: Vector3
var pvis := Vector2.ZERO           # smoothed visual player position (grid stays discrete)
var pyaw := 0.0
var invuln := 2.0                  # spawn grace: mines patrol the rim you start on
var moved_since_spawn := false     # grace only starts ticking on the first move

# --- debug layer toggles (F1..F5) for isolating render artifacts
var rim_mat: ShaderMaterial
var env_ref: Environment
var backdrop_node: MeshInstance3D
var dbg := {"gloss": true, "emis": true, "glow": true, "edge": true, "bg": true}

# --- content: SP obstacles & pickups & effects
var obstacle_timer := 7.0            # SP obstacles rise from the ground
var world_nodes: Array = []          # hidden during the blackout debuff
var blackout_on := false
var frozen_on := false               # freeze VFX state (frost on the balls)
var pickup_templates := {}           # kind -> Node3D
var scan_mat: ShaderMaterial         # hologram wave over the player on collect
var cam_punch := 0.0                 # 0..1 — camera lunges toward the death spot
var cam_punch_spot := Vector3.ZERO
var cam_wide := 0.0                  # 0..1 — camera pulls back (game over / level out)
var fade_rect: ColorRect
var hud_layer: CanvasLayer
var fx := {}                         # effect -> time left
var audio: QixAudio
var _burn_snd_on := false
var _last_warn_sec := -1
var menu_mode := "main"              # main | options
var pause_orbit := 0.0               # pause: slow cinematic orbit angle
var fullscreen_on := false
var rising: Array = []
var derez: Array = []                # craft de-rez shards {node, vel, ax, spin, t, life, s0}
var death_fly := {}                  # ballistic knockback of the dying craft
var death_away := Vector2.RIGHT      # direction away from whatever killed us               # captured cells growing out of the ground {c, t}
var player_speed_mul := 1.0
var sun_ref: DirectionalLight3D
const SUN_BASE := 2.2
const AMBIENT_BASE := 1.4
const PLATFORM_TOP := 1.08
const OB_TYPES := ["sp_crystal", "sp_rock", "sp_peak"]   # legacy fallback pool
const MENU_NAMES := ["START", "OPTIONS", "QUIT"]
const HUD_COL := Color(0.6, 0.86, 1.0)


func _ready() -> void:
	randomize()
	audio = QixAudio.new()
	add_child(audio)
	_load_settings()
	if fullscreen_on:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	QixConfig.GRID_W = int(QixConfig.LEVELS[level].get("grid", 60))
	QixConfig.GRID_H = int(QixConfig.LEVELS[level].get("grid", 60))
	QixConfig.WIN_PERCENT = QixConfig.calc_win_percent(QixConfig.LEVELS[level])
	board.reset()
	player = Vector2i(QixConfig.GRID_W >> 1, QixConfig.GRID_H - QixConfig.BORDER)
	pvis = Vector2(player.x + 0.5, player.y + 0.5)
	_seed_islands(float(QixConfig.LEVELS[level].get("islands", 0.0)))
	enemies.spawn_balls(QixConfig.LEVELS[level])
	_build_world()
	_build_hud()
	_refresh(0.016)
	# obstacles stand on the field from second zero (no spawn wait)
	for i in int(QixConfig.LEVELS[level].get("obstacles", 1)):
		_spawn_obstacle()
	if fly_in:
		fly_in = false
		fade_rect.color.a = 1.0
		var tw := create_tween()
		tw.tween_property(fade_rect, "color:a", 0.0, 0.9)
		_respawn_start(false)
		audio.music(_gameplay_track())
	else:
		menu_resume = false
		player_node.visible = false
		_menu_open()
		audio.music("music_menu")


# ---------- construction ----------

func _build_world() -> void:
	var cfg: Dictionary = QixConfig.LEVELS[level]
	land_emission_base = float(cfg.emission)

	# sea set is level-designed now (default unclaimed_B): near-black floor,
	# sparse red veins that FLAME UP around rolling balls — quiet glow otherwise
	# per-level sea character: base emission + ball flare are level-designable
	# (L9/L10 run unclaimed_A quiet, then it IGNITES under rolling balls)
	sea_mat = QixAssets.floor_mat(String(cfg.get("sea", "unclaimed_B")), float(cfg.get("sea_emission", QixConfig.SEA_EMISSION)))
	sea_mat.set_shader_parameter("albedo_mul", 1.0)
	# per-level sea tiling (smaller = finer texture features on the water)
	sea_mat.set_shader_parameter("tile", float(cfg.get("sea_tile", QixConfig.TILE_REPEAT)))
	# the regenerated maps already carry the wet-glass roughness band — no extra pull-down
	sea_mat.set_shader_parameter("rough_mul", 1.0)
	sea_mat.set_shader_parameter("normal_depth", QixConfig.SEA_NORMAL_DEPTH)
	sea_mat.set_shader_parameter("ball_glow_energy", float(cfg.get("sea_ball_glow", QixConfig.SEA_BALL_GLOW)))
	sea_mat.set_shader_parameter("ball_glow_radius", QixConfig.SEA_BALL_RADIUS)
	sea_mat.set_shader_parameter("wave_len", 46.0)
	sea_mat.set_shader_parameter("wave_speed", 0.35)
	sea_mat.set_shader_parameter("wave_unevenness", 6.5)
	var sea := MeshInstance3D.new()
	sea.name = "SeaPlane"
	var sea_mesh := PlaneMesh.new()
	sea_mesh.size = Vector2(QixConfig.GRID_W, QixConfig.GRID_H)
	sea.mesh = sea_mesh
	sea.material_override = sea_mat
	sea.position = Vector3(QixConfig.GRID_W / 2.0, -0.12, QixConfig.GRID_H / 2.0)
	add_child(sea)
	world_nodes.append(sea)

	land_mat = QixAssets.floor_mat(String(cfg.tex), land_emission_base)
	land_mat.set_shader_parameter("albedo_mul", 1.6)   # near-black obsidian needs the lift
	land_mat.set_shader_parameter("edge_glow", 1.7)    # frontier light (calmer)
	land_mat.set_shader_parameter("arena", Vector2(QixConfig.GRID_W, QixConfig.GRID_H))
	land_mat.set_shader_parameter("wall_top", QixConfig.PLATFORM_Y + QixConfig.PLATFORM_HEIGHT * 0.5)
	# Stefan's Blender settings: flat roughness/metallic (maps unlinked).
	# Levels WITHOUT rough_flat/metal_flat run on the maps (catalog-WYSIWYG).
	land_mat.set_shader_parameter("rough_override", float(cfg.get("rough_flat", -1.0)))
	land_mat.set_shader_parameter("metal_override", float(cfg.get("metal_flat", -1.0)))
	land_mat.set_shader_parameter("rough_mul", 1.0)
	land_mat.set_shader_parameter("ball_count", 1)
	land_mat.set_shader_parameter("ball_glow_radius", QixConfig.LAND_PLAYER_RADIUS)
	land_mat.set_shader_parameter("ball_glow_energy", QixConfig.LAND_PLAYER_GLOW)
	var land_inst := MultiMeshInstance3D.new()
	land_inst.name = "LandCells"
	land_mm = MultiMesh.new()
	land_mm.transform_format = MultiMesh.TRANSFORM_3D
	land_mm.use_custom_data = true   # per-cell exposed-walls mask
	var land_box := BoxMesh.new()
	land_box.size = Vector3(1.0, QixConfig.PLATFORM_HEIGHT, 1.0)
	land_box.material = land_mat
	land_mm.mesh = land_box
	land_mm.instance_count = QixConfig.GRID_W * QixConfig.GRID_H
	land_mm.visible_instance_count = 0
	land_inst.multimesh = land_mm
	add_child(land_inst)
	world_nodes.append(land_inst)

	# THE RIM: separate static geometry with its OWN material — texture pattern
	# but ZERO top emission, so nothing from the horizontal surface can ever
	# paint the vertical frame. Its only lights: solid outer band + slash inner.
	# rim wears the SAME face as captured ground (Stefan: the tint mismatch) —
	# same albedo lift, same emission; walls stay light-only via the top gate
	rim_mat = QixAssets.floor_mat(String(cfg.tex), land_emission_base)
	rim_mat.set_shader_parameter("albedo_mul", 1.6)
	rim_mat.set_shader_parameter("edge_glow", 1.7)
	rim_mat.set_shader_parameter("arena", Vector2(QixConfig.GRID_W, QixConfig.GRID_H))
	rim_mat.set_shader_parameter("wall_top", QixConfig.PLATFORM_Y + QixConfig.PLATFORM_HEIGHT * 0.5)
	rim_mat.set_shader_parameter("rough_override", float(cfg.get("rough_flat", -1.0)))
	rim_mat.set_shader_parameter("metal_override", float(cfg.get("metal_flat", -1.0)))
	rim_mat.set_shader_parameter("rough_mul", 1.0)
	rim_mat.set_shader_parameter("ball_count", 1)
	rim_mat.set_shader_parameter("ball_glow_radius", QixConfig.LAND_PLAYER_RADIUS)
	rim_mat.set_shader_parameter("ball_glow_energy", QixConfig.LAND_PLAYER_GLOW)
	var rim_inst := MultiMeshInstance3D.new()
	rim_inst.name = "RimCells"
	rim_mm = MultiMesh.new()
	rim_mm.transform_format = MultiMesh.TRANSFORM_3D
	rim_mm.use_custom_data = true
	var rim_box := BoxMesh.new()
	rim_box.size = Vector3(1.0, QixConfig.PLATFORM_HEIGHT, 1.0)
	rim_box.material = rim_mat
	rim_mm.mesh = rim_box
	var rim_cells: Array[Vector2i] = []
	for y in QixConfig.GRID_H:
		for x in QixConfig.GRID_W:
			if board.is_rim(Vector2i(x, y)):
				rim_cells.append(Vector2i(x, y))
	rim_mm.instance_count = rim_cells.size()
	rim_index.clear()
	for i in rim_cells.size():
		var c := rim_cells[i]
		rim_mm.set_instance_transform(i, _land_cell_xform(c))
		rim_index[c] = i
		rim_mm.set_instance_custom_data(i, _cell_side_mask(c))
	rim_inst.multimesh = rim_mm
	add_child(rim_inst)
	world_nodes.append(rim_inst)

	var trail_inst := MultiMeshInstance3D.new()
	trail_inst.name = "TrailCells"
	trail_mm = MultiMesh.new()
	trail_mm.transform_format = MultiMesh.TRANSFORM_3D
	var trail_box := BoxMesh.new()
	trail_box.size = Vector3(1.12, 1.35, 0.14)   # Tron light-cycle ribbon wall
	trail_box.material = QixAssets.trail_wall_mat()
	trail_mm.mesh = trail_box
	trail_mm.use_colors = true
	trail_mm.instance_count = QixConfig.GRID_W * QixConfig.GRID_H
	trail_mm.visible_instance_count = 0
	trail_inst.multimesh = trail_mm
	add_child(trail_inst)
	world_nodes.append(trail_inst)

	# burn fronts: bright fire dots so the trail burn is a VISIBLE killer
	burn_markers.clear()
	for i in 2:
		var mk := MeshInstance3D.new()
		mk.name = "BurnFront%d" % i
		var ms := SphereMesh.new()
		ms.radius = 0.34
		ms.height = 0.68
		ms.material = QixAssets.flat_mat(Color(0.6, 0.03, 0.01), Color(1.0, 0.12, 0.05), 5.0)
		mk.mesh = ms
		var fp := QixAssets.make_fire_particles(0.4, Color(1.0, 0.15, 0.06))
		mk.add_child(fp)
		mk.visible = false
		add_child(mk)
		burn_markers.append(mk)

	# hero: generated Speeder Pod GLB (falls back to a hover block)
	player_node = QixAssets.make_enemy_node("hero_a_pod", QixConfig.HERO_SIZE, Color(0.2, 0.95, 1.0), QixConfig.HERO_YAW_DEG)
	QixAssets.dim_materials(player_node, 0.72)   # "darker a bit" — Stefan
	QixAssets.add_mesh_outline(player_node, Color(0.2, 0.95, 1.0), 0.07)   # Tron contour
	var shell := QixAssets.make_scan_shell(QixConfig.HERO_SIZE)
	scan_mat = shell.material_override as ShaderMaterial
	player_node.add_child(shell)
	# status VFX on the craft: frost while SLOWED, flames while SPEED-boosted
	player_node.add_child(QixAssets.make_frost_particles(QixConfig.HERO_SIZE * 0.4))
	player_node.add_child(QixAssets.make_fire_particles(QixConfig.HERO_SIZE * 0.35))
	player_node.name = "Player"
	add_child(player_node)

	# infinite animated Tron grid the arena floats on
	var backdrop := MeshInstance3D.new()
	backdrop.name = "Backdrop"
	backdrop_node = backdrop
	var bp := PlaneMesh.new()
	bp.size = Vector2(900.0, 900.0)
	backdrop.mesh = bp
	backdrop.material_override = QixAssets.backdrop_mat()
	backdrop_mat_ref = backdrop.material_override as ShaderMaterial
	backdrop.position = Vector3(QixConfig.GRID_W / 2.0, -0.3, QixConfig.GRID_H / 2.0)
	add_child(backdrop)
	world_nodes.append(backdrop)

	for i in enemies.balls.size():
		var b: Dictionary = enemies.balls[i]
		var spec: Dictionary = QixConfig.BALL_TYPES[b.type]
		var bsize: float = QixConfig.BALL_DIAMETER * float(spec.size_mul)
		var bn := QixAssets.make_enemy_node(String(spec.get("glb", "ball_" + String(b.type))), bsize, _ball_fallback(String(b.type)))
		QixAssets.add_outline(bn, bsize, spec.outline)
		bn.add_child(QixAssets.make_fire_particles(bsize * 0.5))
		bn.add_child(QixAssets.make_frost_particles(bsize * 0.5))
		bn.name = "Ball%d" % i
		add_child(bn)
		b.node = bn
		b.size = bsize

	# mines patrol the border rim from the very start; nodes built NOW so
	# there is no mid-game GLB-load hitch
	for i in int(cfg.mines):
		var m := enemies.spawn_mine_data(player)
		if m.is_empty():
			continue
		var node := QixAssets.make_enemy_node("mine", QixConfig.MINE_SIZE, Color(1.0, 0.12, 0.1))
		node.name = "Mine%d" % i
		# police-style beacon on top
		var beacon := MeshInstance3D.new()
		beacon.name = "Beacon"
		var bs := SphereMesh.new()
		bs.radius = 0.28
		bs.height = 0.56
		bs.material = QixAssets.flat_mat(Color(0.4, 0.02, 0.02), Color(1.0, 0.1, 0.1), 5.0)
		beacon.mesh = bs
		beacon.position = Vector3(0.0, QixConfig.MINE_SIZE * 0.32, 0.0)
		node.add_child(beacon)
		node.add_child(QixAssets.make_electric_particles(QixConfig.MINE_SIZE * 0.5))
		node.add_child(QixAssets.make_frost_particles(QixConfig.MINE_SIZE * 0.5))
		add_child(node)
		m.node = node

	# HUNTER mine(s): redder, slow, surface-blind — flies straight at the
	# player; only an obstacle stops it (kamikaze: both go down)
	for i in int(cfg.get("hunters", 0)):
		var hm := enemies.spawn_hunter_data(player)
		if hm.is_empty():
			continue
		var hnode := QixAssets.make_enemy_node("mine", QixConfig.MINE_SIZE, Color(1.0, 0.08, 0.06))
		hnode.name = "Hunter%d" % i
		QixAssets.tint_materials(hnode, Color(1.35, 0.5, 0.5))
		QixAssets.add_mesh_outline(hnode, Color(1.0, 0.16, 0.1), 0.07)
		hnode.add_child(QixAssets.make_electric_particles(QixConfig.MINE_SIZE * 0.5))
		hnode.add_child(QixAssets.make_frost_particles(QixConfig.MINE_SIZE * 0.5))
		add_child(hnode)
		hm.node = hnode

	# the SAW(s): slow spinning cutters wandering in straight lines
	for i in int(cfg.get("saws", 0)):
		var sdata := enemies.spawn_saw_data(player)
		if sdata.is_empty():
			continue
		var snode := QixAssets.make_enemy_node("saw_a", QixConfig.SAW_SIZE, Color(1.0, 0.5, 0.1))
		snode.name = "Saw%d" % i
		snode.add_child(QixAssets.make_saw_sparks(QixConfig.SAW_RADIUS))
		snode.add_child(QixAssets.make_frost_particles(QixConfig.SAW_RADIUS))
		add_child(snode)
		sdata.node = snode
		audio.attach_loop("saw_loop", snode)

	_load_templates(cfg)
	_build_camera_env()
	_prewarm_shaders()


func _prewarm_shaders() -> void:
	var rig := Node3D.new()
	rig.name = "ShaderPrewarm"
	var fwd := (cam_base_look - cam_base_pos).normalized()
	rig.position = cam_base_pos + fwd * 4.0
	var ghost_quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.01, 0.01)
	qm.material = StandardMaterial3D.new()
	ghost_quad.mesh = qm
	QixAssets.make_ghost(ghost_quad, 0.0)   # converts to ghost shader, alpha 0 = invisible
	rig.add_child(ghost_quad)
	var ring := QixAssets.make_ground_ring(Color.BLACK, 0.01)   # additive black = invisible
	rig.add_child(ring)
	var burst := QixAssets.make_burst(Color.BLACK, 0.05)        # additive black = invisible
	rig.add_child(burst)
	add_child(rig)
	get_tree().create_timer(1.2).timeout.connect(rig.queue_free)


func _load_templates(_cfg: Dictionary) -> void:
	# SP obstacles: warm the GLB cache NOW — parsing 2MB at first spawn lagged
	for kind in OB_TYPES:
		QixAssets.load_glb_scene(kind)
	# shader warm-up: fire a de-rez behind the boot fade (screen still black)
	# so the glass-shard pipeline compiles now — the FIRST death used to hitch
	_derez_burst(Vector3(QixConfig.GRID_W * 0.5, 1.2, QixConfig.GRID_H * 0.7), Vector2.RIGHT, -999.0)
	var warm := create_tween()
	warm.tween_interval(0.35)
	warm.tween_callback(func() -> void:
		for d in derez:
			if is_instance_valid(d.node):
				d.node.queue_free()
		derez.clear())

	# pickups: all kinds preloaded once; category outline like the balls have
	# (blue = bonus, red = debuff, violet = surprise)
	if pickup_templates.is_empty():
		for kind in QixPickups.WEIGHTS:
			var glb_name: String = "surprise" if kind == "surprise" else kind
			var t := QixAssets.make_enemy_node(glb_name, 3.0, Color(0.7, 0.9, 1.0))
			QixAssets.add_mesh_outline(t, _pickup_outline(kind))
			t.add_child(QixAssets.make_ground_ring(_pickup_outline(kind), 5.0))
			pickup_templates[kind] = t


func _pickup_outline(kind: String) -> Color:
	if kind == "surprise":
		return Color(0.72, 0.25, 1.0)
	if kind.begins_with("debuff"):
		return Color(1.0, 0.15, 0.12)
	return Color(0.15, 0.55, 1.0)


## Visuals for a ball spawned mid-game (split / ballmageddon clones).
func _spawn_ball_node(b: Dictionary) -> void:
	var bspec: Dictionary = QixConfig.BALL_TYPES[b.type]
	var bsize := QixConfig.BALL_DIAMETER * float(bspec.size_mul)
	var bn := QixAssets.make_enemy_node(String(bspec.get("glb", "ball_" + String(b.type))), bsize, _ball_fallback(String(b.type)))
	QixAssets.add_outline(bn, bsize, bspec.outline)
	bn.add_child(QixAssets.make_fire_particles(bsize * 0.5))
	var frost := QixAssets.make_frost_particles(bsize * 0.5)
	frost.emitting = frozen_on   # born mid-chill -> chills too
	bn.add_child(frost)
	add_child(bn)
	b.node = bn
	b.size = bsize


func _ball_fallback(type: String) -> Color:
	if type.begins_with("soft"):
		return Color(0.35, 0.8, 1.0)
	if type.begins_with("hard"):
		return Color(1.0, 0.45, 0.08)
	return Color(1.0, 0.1, 0.15)


func _build_camera_env() -> void:
	cam = Camera3D.new()
	cam.name = "GameCamera"
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = QixConfig.CAM_FOV
	# big arenas: the camera grows SUB-linearly with the grid (a 90-grid uses
	# an effective 76.5) and follows the player harder — we sacrifice a little
	# overview so the craft never feels a mile away (Stefan, L7-L8 feedback)
	var cam_h := 60.0 + (QixConfig.GRID_H - 60.0) * QixConfig.CAM_GROWTH
	cam_follow_pos = QixConfig.CAM_FOLLOW_POS + (QixConfig.GRID_H - 60.0) / 30.0 * 0.28
	cam_follow_look = QixConfig.CAM_FOLLOW_LOOK + (QixConfig.GRID_H - 60.0) / 30.0 * 0.25
	cam_base_pos = Vector3(QixConfig.GRID_W / 2.0, cam_h * QixConfig.CAM_HEIGHT_K, cam_h * QixConfig.CAM_DIST_K)
	cam_base_look = Vector3(QixConfig.GRID_W / 2.0, 0.0, QixConfig.GRID_H * QixConfig.CAM_LOOK_K)
	cam.look_at_from_position(cam_base_pos, cam_base_look, Vector3.UP)
	add_child(cam)
	cam.make_current()

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	sun.light_energy = 2.2
	sun.shadow_enabled = true                   # simple shadows from balls/hero
	sun.shadow_blur = 0.5                       # harder shadow edges per Stefan
	sun.directional_shadow_max_distance = 110.0 # tighter = denser shadow texels
	sun.shadow_normal_bias = 3.0                # kills GL shadow acne (dot moire)
	sun_ref = sun
	add_child(sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	var sky := Sky.new()
	# REAL environment reflections (Stefan: 'this is what we were missing'):
	# an HDRI night panorama feeds the sky — used ONLY for reflections/ambient
	# (background stays the black void below). Swap the map by dropping any
	# 2:1 panorama into assets/sky/ and naming it in QixConfig.SKY_PANORAMA.
	var pano := QixAssets.load_sky_panorama(QixConfig.SKY_PANORAMA)
	if pano:
		var pano_mat := PanoramaSkyMaterial.new()
		pano_mat.panorama = pano
		pano_mat.energy_multiplier = QixConfig.SKY_ENERGY
		sky.sky_material = pano_mat
	else:
		var sky_mat := ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = Color(0.05, 0.1, 0.2)
		sky_mat.sky_horizon_color = Color(0.14, 0.24, 0.38)
		sky_mat.ground_horizon_color = Color(0.1, 0.18, 0.3)
		sky_mat.ground_bottom_color = Color(0.03, 0.05, 0.09)
		sky.sky_material = sky_mat
	env.sky = sky
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.01, 0.015, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.4
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ssr_enabled = true
	env.ssr_max_steps = 56
	env.glow_enabled = true
	env.glow_intensity = 0.5                   # halved per Stefan
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.0
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		# Compatibility renders 3D into an LDR buffer: nothing ever crosses a
		# 1.0 HDR threshold, so glow silently dies. Pull it into LDR range and
		# blend additively — the edge lines bloom again.
		env.glow_hdr_threshold = 0.55
		env.glow_intensity = 0.45   # halved per Stefan (0.9 was too hot)
		env.glow_bloom = 0.08
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.3                 # readable darks, emissives still pop
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.02
	env.adjustment_saturation = 1.08
	env_node.environment = env
	env_ref = env
	add_child(env_node)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	hud_layer = layer
	hud_font = SystemFont.new()
	hud_font.font_names = PackedStringArray(["Bahnschrift", "Bahnschrift SemiBold", "Arial"])

	# top: LIVES | LEVEL + percent (center) | SCORE — nothing else
	var top := HBoxContainer.new()
	top.anchor_right = 1.0
	top.offset_left = 24.0
	top.offset_top = 12.0
	top.offset_right = -24.0
	layer.add_child(top)
	# lives: a row of Tron hearts (max 5) — filled bright, lost ones ghosted
	hearts_box = HBoxContainer.new()
	hearts_box.add_theme_constant_override("separation", 5)
	for i in 5:
		var h := TextureRect.new()
		h.texture = QixAssets.heart_tex()
		h.custom_minimum_size = Vector2(26, 26)
		h.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hearts_box.add_child(h)
		hearts.append(h)
	top.add_child(hearts_box)
	var sp1 := Control.new()
	sp1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp1)
	var mid := VBoxContainer.new()
	top.add_child(mid)
	hud_level = _hud_label(mid, "SECTOR 1 / 10")
	hud_level.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_percent = _hud_label(mid, "0%  /  75%")
	hud_percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_percent.add_theme_font_size_override("font_size", 15)
	hud_percent.modulate = Color(1, 1, 1, 0.7)
	# pickup toast: big, mid-screen, bounces in and de-rezzes into pixels
	hud_toast = Label.new()
	hud_toast.add_theme_font_override("font", hud_font)
	hud_toast.add_theme_font_size_override("font_size", 46)
	hud_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	hud_toast.add_theme_constant_override("outline_size", 12)
	var toast_sh := Shader.new()
	toast_sh.code = TOAST_DISSOLVE_SHADER
	var toast_mat := ShaderMaterial.new()
	toast_mat.shader = toast_sh
	hud_toast.material = toast_mat
	hud_toast.modulate.a = 0.0
	hud_layer.add_child(hud_toast)
	var sp2 := Control.new()
	sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp2)
	hud_score = _hud_label(top, "SCORE 0")

	# TIME: a full-width slash-tick bar hugging the bottom edge — drains with
	# the clock, goes red and pulses when low, flashes when time is added
	var tbar := ColorRect.new()
	tbar.anchor_top = 1.0
	tbar.anchor_right = 1.0
	tbar.anchor_bottom = 1.0
	tbar.offset_top = -22.0
	tbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tsh := Shader.new()
	tsh.code = TIMEBAR_SHADER
	timebar_mat = ShaderMaterial.new()
	timebar_mat.shader = tsh
	tbar.material = timebar_mat
	layer.add_child(tbar)

	# dim panel under overlays/menu so text reads over the living game
	dim_rect = ColorRect.new()
	dim_rect.color = Color(0.0, 0.01, 0.03, 0.0)
	dim_rect.anchor_right = 1.0
	dim_rect.anchor_bottom = 1.0
	dim_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(dim_rect)

	overlay = Label.new()
	overlay.anchor_right = 1.0
	overlay.anchor_bottom = 1.0
	overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	overlay.add_theme_font_override("font", hud_font)
	overlay.add_theme_font_size_override("font_size", 54)
	overlay.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	overlay.add_theme_constant_override("outline_size", 10)
	overlay.visible = false
	layer.add_child(overlay)

	# main menu: title + START / OPTIONS / QUIT
	menu_box = VBoxContainer.new()
	menu_box.anchor_right = 1.0
	menu_box.anchor_bottom = 1.0
	menu_box.alignment = BoxContainer.ALIGNMENT_CENTER
	menu_box.add_theme_constant_override("separation", 14)
	menu_box.visible = false
	layer.add_child(menu_box)
	var title := Label.new()
	title.text = "TRON: EXONIX"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", hud_font)
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(0.2, 0.95, 1.0))
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("outline_size", 10)
	menu_box.add_child(title)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 26)
	menu_box.add_child(gap)
	menu_items = []
	for n in MENU_NAMES.size() + 4:   # extra slots: options/controls pages
		var l := Label.new()
		l.text = ""
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_override("font", hud_font)
		l.add_theme_font_size_override("font_size", 30)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		l.add_theme_constant_override("outline_size", 8)
		menu_box.add_child(l)
		menu_items.append(l)

	board_box = VBoxContainer.new()
	board_box.anchor_right = 1.0
	board_box.anchor_top = 0.60
	board_box.anchor_bottom = 0.97
	board_box.add_theme_constant_override("separation", 6)
	board_box.visible = false
	layer.add_child(board_box)

	fade_rect = ColorRect.new()
	fade_rect.color = Color(0, 0, 0, 0)
	fade_rect.anchor_right = 1.0
	fade_rect.anchor_bottom = 1.0
	fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(fade_rect)


func _pause_resume() -> void:
	audio.set_paused(false)
	pause_orbit = wrapf(pause_orbit, -PI, PI)   # come home the short way round
	var tw := create_tween()
	tw.tween_property(self, "pause_orbit", 0.0, 0.9).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _menu_open() -> void:
	state = "menu"
	menu_sel = 0
	overlay.visible = false
	menu_box.visible = true
	dim_rect.color.a = 0.55
	_menu_paint()


func _menu_rows() -> Array:
	if menu_mode == "options":
		return ["MUSIC   <  %d%%  >" % int(round(QixConfig.MUSIC_VOL * 100.0)),
				"SOUND   <  %d%%  >" % int(round(QixConfig.SFX_VOL * 100.0)),
				"FULLSCREEN   <  %s  >" % ("ON" if fullscreen_on else "OFF"),
				"CONTROLS",
				"BACK"]
	if menu_mode == "controls":
		return ["MOVE — ARROWS / WASD",
				"DEPLOY / NEXT — SPACE",
				"PAUSE / BACK — ESC",
				"CONFIRM — ENTER",
				"BACK"]
	if menu_resume:
		return ["RESUME", "OPTIONS", "MAIN MENU", "QUIT"]
	return MENU_NAMES.duplicate()


func _menu_paint() -> void:
	var rows := _menu_rows()
	for i in menu_items.size():
		var l: Label = menu_items[i]
		l.visible = i < rows.size()
		if i >= rows.size():
			continue
		l.text = ("*  " + String(rows[i]) + "  *") if i == menu_sel else String(rows[i])
		l.add_theme_color_override("font_color", Color(0.25, 0.95, 1.0) if i == menu_sel else Color(0.42, 0.58, 0.72))


func _menu_key(code: int) -> void:
	var rows := _menu_rows()
	if code == KEY_UP or code == KEY_W:
		menu_sel = (menu_sel + rows.size() - 1) % rows.size()
		_menu_paint()
		audio.play("ui_move")
	elif code == KEY_DOWN or code == KEY_S:
		menu_sel = (menu_sel + 1) % rows.size()
		_menu_paint()
		audio.play("ui_move")
	elif menu_mode == "options" and (code == KEY_LEFT or code == KEY_A):
		_option_adjust(-1)
	elif menu_mode == "options" and (code == KEY_RIGHT or code == KEY_D):
		_option_adjust(1)
	elif code == KEY_ENTER or code == KEY_KP_ENTER or code == KEY_SPACE:
		_menu_confirm()


func _option_adjust(dv: int) -> void:
	match menu_sel:
		0:
			QixConfig.MUSIC_VOL = clampf(snappedf(QixConfig.MUSIC_VOL + 0.1 * dv, 0.1), 0.0, 1.0)
			audio.music_volume_changed()
		1:
			QixConfig.SFX_VOL = clampf(snappedf(QixConfig.SFX_VOL + 0.1 * dv, 0.1), 0.0, 1.0)
			audio.play("pickup_good")   # audible sample of the new level
		2:
			fullscreen_on = not fullscreen_on
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN \
					if fullscreen_on else DisplayServer.WINDOW_MODE_WINDOWED)
		_:
			return
	_save_settings()
	_menu_paint()
	audio.play("ui_move")


func _load_settings() -> void:
	var f := FileAccess.open("user://exonix_settings.json", FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		QixConfig.MUSIC_VOL = clampf(float(d.get("music", 0.5)), 0.0, 1.0)
		QixConfig.SFX_VOL = clampf(float(d.get("sfx", 0.5)), 0.0, 1.0)
		fullscreen_on = bool(d.get("fullscreen", false))


func _save_settings() -> void:
	var f := FileAccess.open("user://exonix_settings.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"music": QixConfig.MUSIC_VOL,
				"sfx": QixConfig.SFX_VOL, "fullscreen": fullscreen_on}))


func _menu_confirm() -> void:
	audio.play("ui_select")
	if menu_mode == "options":
		var row := String(_menu_rows()[menu_sel])
		if row == "BACK":
			menu_mode = "main"
			menu_sel = 1
			_menu_paint()
		elif row == "CONTROLS":
			menu_mode = "controls"
			menu_sel = 4   # selection sits on BACK; the rest is reference
			_menu_paint()
		else:
			_option_adjust(1)   # ENTER on a row cycles it forward
		return
	if menu_mode == "controls":
		menu_mode = "options"
		menu_sel = 3
		_menu_paint()
		return
	match String(_menu_rows()[menu_sel]):
		"RESUME":
			menu_box.visible = false
			dim_rect.color.a = 0.0
			state = "play"
			_pause_resume()
		"START":
			menu_box.visible = false
			state = "title"
			dim_rect.color.a = 0.3
			overlay.text = "PRESS SPACE TO DEPLOY"
			overlay.add_theme_color_override("font_color", Color(0.2, 0.95, 1.0))
			overlay.visible = true
		"OPTIONS":
			menu_mode = "options"
			menu_sel = 0
			_menu_paint()
		"MAIN MENU":
			_to_main_menu()
		"QUIT":
			get_tree().quit()


func _esc_pressed() -> void:
	match state:
		"play":
			menu_resume = true
			_menu_open()
			audio.set_paused(true)
		"menu":
			if menu_mode == "controls":
				menu_mode = "options"
				menu_sel = 3
				_menu_paint()
			elif menu_mode == "options":
				menu_mode = "main"
				menu_sel = 1
				_menu_paint()
			elif menu_resume:
				menu_box.visible = false
				dim_rect.color.a = 0.0
				state = "play"
				_pause_resume()
		"title":
			menu_resume = false
			overlay.visible = false
			_menu_open()
		"board", "over", "final":
			_to_main_menu()


func _hud_label(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", hud_font)
	l.add_theme_font_size_override("font_size", 22)
	l.add_theme_color_override("font_color", Color(0.6, 0.86, 1.0))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 6)
	parent.add_child(l)
	return l


func _unhandled_key_input(event: InputEvent) -> void:
	# Debug isolation: F1 gloss/spec, F2 texture emission, F3 glow, F4 edge lights, F5 backdrop
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.physical_keycode == KEY_ESCAPE:
		_esc_pressed()
		return
	if state == "menu":
		_menu_key(event.physical_keycode)
		return
	if state == "title" and event.physical_keycode == KEY_SPACE:
		overlay.visible = false
		dim_rect.color.a = 0.0
		audio.music(_gameplay_track())
		_respawn_start(false)
		return
	if state == "board" and event.physical_keycode == KEY_SPACE:
		_fly_out()
		return
	if state in ["over", "final"] and event.physical_keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
		_to_main_menu()
		return
	match event.physical_keycode:
		KEY_F1:
			dbg.gloss = not dbg.gloss
			var ro: float = float(QixConfig.LEVELS[level].get("rough_flat", -1.0))
			for m in [land_mat, sea_mat, rim_mat]:
				m.set_shader_parameter("rough_mul", 0.45 if dbg.gloss else 1.0)
				m.set_shader_parameter("spec", 0.7 if dbg.gloss else 0.0)
			for m in [land_mat, rim_mat]:
				m.set_shader_parameter("rough_override", ro if dbg.gloss else -1.0)
		KEY_F2:
			dbg.emis = not dbg.emis
			land_mat.set_shader_parameter("emission_energy", land_emission_base if dbg.emis else 0.0)
			sea_mat.set_shader_parameter("emission_energy", QixConfig.SEA_EMISSION if dbg.emis else 0.0)
			sea_mat.set_shader_parameter("ball_glow_energy", QixConfig.SEA_BALL_GLOW if dbg.emis else 0.0)
		KEY_F3:
			dbg.glow = not dbg.glow
			env_ref.glow_enabled = dbg.glow
		KEY_F4:
			dbg.edge = not dbg.edge
			for m in [land_mat, rim_mat]:
				m.set_shader_parameter("edge_glow", 1.7 if dbg.edge else 0.0)
		KEY_F5:
			dbg.bg = not dbg.bg
			backdrop_node.visible = dbg.bg
		KEY_F6:
			# shimmer forensics: toggle the sun's shadows entirely
			sun_ref.shadow_enabled = not sun_ref.shadow_enabled
			print("DBG shadows=", sun_ref.shadow_enabled)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
			# debug: jump straight to a level (fresh board, score kept)
			level = event.physical_keycode - KEY_1
			get_tree().reload_current_scene()
		KEY_0:
			level = 9   # sector 10
			get_tree().reload_current_scene()
		KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4, KEY_KP_5, KEY_KP_6, KEY_KP_7, KEY_KP_8, KEY_KP_9:
			level = event.physical_keycode - KEY_KP_1
			get_tree().reload_current_scene()
		KEY_KP_0:
			level = 9
			get_tree().reload_current_scene()
		_:
			return
	print("DBG  gloss=%s  emis=%s  glow=%s  edge=%s  bg=%s" % [dbg.gloss, dbg.emis, dbg.glow, dbg.edge, dbg.bg])


# ---------- game loop ----------

func _process(delta: float) -> void:
	# living reflections: the sky cubemap drifts and gently tilts, so glints
	# crawl across the polished floors even with a still camera (cheap: the
	# rotation is a shader-side lookup, the radiance map is not re-rendered)
	var skt := Time.get_ticks_msec() * 0.001
	env_ref.sky_rotation = Vector3(sin(skt * QixConfig.SKY_TILT_SPEED) * QixConfig.SKY_TILT,
			wrapf(skt * QixConfig.SKY_DRIFT_YAW, -TAU, TAU), 0.0)
	var paused := state == "menu" and menu_resume
	if not paused and not derez.is_empty():
		_update_derez(delta)
	if state == "dying" and not death_fly.is_empty():
		# the thrown craft: gravity arc + tumble; shatter on touchdown
		var dv: Vector3 = death_fly.vel
		death_fly.t += delta
		dv.y -= 26.0 * delta
		death_fly.vel = dv
		player_node.position += dv * delta
		player_node.rotate(death_fly.ax, 9.0 * delta)
		if player_node.position.y <= 0.8 or float(death_fly.t) > 0.9:
			death_fly = {}
			_death_boom()
			var twd := create_tween()
			twd.tween_interval(0.55)
			twd.tween_callback(_after_death)
	if paused or state == "board" or state == "final":
		# pause AND victory: the camera drifts around the arena we just won
		pause_orbit = wrapf(pause_orbit + delta * 0.16, -TAU, TAU)
	if state == "play":
		time_left -= delta
		if time_left <= 0.0:
			time_left = 0.0
			_game_over("TIME OUT")
		else:
			_read_input()
			move_timer += delta
			var eff_interval := QixConfig.MOVE_INTERVAL / player_speed_mul
			while move_timer >= eff_interval:
				move_timer -= eff_interval
				_step_player()
				if state != "play":
					break
	# the world never stops — EXCEPT the pause menu (Stefan: pause = full freeze)
	if not paused:
		enemies.move_balls(delta, player)
		# mines/saws/hunters obey speed_scale too (freeze / enemyfast /
		# ZA WARUDO slow EVERYTHING, not just balls) — scaled time, same logic
		enemies.update_mines(delta * enemies.speed_scale, player)
		# hunter kamikaze aftermath: explosion + cleanup for flagged mines
		for hm in enemies.mines.duplicate():
			if bool(hm.get("dead", false)):
				if hm.node:
					var boom := QixAssets.make_burst(Color(1.0, 0.3, 0.12), 3.0)
					boom.position = hm.node.position
					add_child(boom)
					audio.play_at("obstacle_break", hm.node.position)
					hm.node.queue_free()
				enemies.mines.erase(hm)
		enemies.update_saws(delta * enemies.speed_scale, player)
		for ev in enemies.sound_events:
			audio.play_at(String(ev.n), Vector3(ev.pos.x, 1.0, ev.pos.y))
		enemies.sound_events.clear()
		if moved_since_spawn:   # forensics: mines were camping the respawn cell
			invuln = max(0.0, invuln - delta)
		_update_fx(delta)
		_update_pickups(delta)
		for dead in enemies.expire_temp_balls(delta):
			if dead.node:
				dead.node.queue_free()
		if not board.last_smashed.is_empty():
			_land_remove(board.last_smashed)
			board.land_dirty = false   # handled incrementally
			board.last_smashed.clear()
	if state == "play":
		_update_obstacles(delta)
		_handle_hits()
	if state == "play":
		if burn.update(delta, player):
			_die("THE BURN CAUGHT YOU")
	if burn.active != _burn_snd_on:
		_burn_snd_on = burn.active
		if _burn_snd_on:
			audio.play("burn_start")
			audio.loop_start("burn_loop")
		else:
			audio.loop_stop("burn_loop")
	if state == "play" and time_left < 15.0:
		var warn_sec := int(ceil(time_left))
		if warn_sec != _last_warn_sec:
			_last_warn_sec = warn_sec
			audio.play("time_warn")
	_refresh(delta)


func _handle_hits() -> void:
	var cutting := board.cell(player) != QixBoard.LAND
	var hit = enemies.check_hits(player, cutting, burn.active)
	if hit is String:
		if invuln <= 0.0:
			var cause := "RAMMED BY A BALL"
			if hit == "mine":
				cause = "STRUCK BY A MINE"
			elif hit == "obstacle":
				cause = "CRASHED INTO AN OBSTACLE"
			elif hit == "saw":
				cause = "SHREDDED BY THE SAW"
			_die(cause)
	elif hit is Vector2i:
		burn.start(hit)


func _read_input() -> void:
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
		# while cutting, a direct reversal would step onto our own fresh trail —
		# the classic "killed by nothing" — so it is simply ignored
		if d == -dir and board.cell(player) != QixBoard.LAND:
			return
		dir = d
	elif board.cell(player) == QixBoard.LAND:
		dir = Vector2i.ZERO


func _step_player() -> void:
	if dir == Vector2i.ZERO:
		return
	moved_since_spawn = true
	var next := player + dir
	if not board.in_bounds(next):
		return
	if board.cell(next) == QixBoard.TRAIL:
		_die("SLICED BY OWN TRAIL")
		return
	var was_on_land := board.cell(player) == QixBoard.LAND
	var prev := player
	player = next
	if board.cell(player) == QixBoard.SEA:
		if was_on_land:
			audio.loop_start("cut_loop")
		board.set_cell(player, QixBoard.TRAIL)
		burn.on_player_cut(player)
		_trail_add(prev, player)
	elif board.cell(player) == QixBoard.LAND and not was_on_land:
		audio.loop_stop("cut_loop")
		burn.reset()
		var won := board.capture(enemies.ball_cells())
		var claimed := board.last_claimed.size()
		_land_add(board.last_claimed)
		board.land_dirty = false   # handled incrementally
		if claimed > 0:
			for rc in board.last_claimed:
				rising.append({"c": rc, "t": 0.0})
			backdrop_mat_ref.set_shader_parameter("pulse_t", bg_clock)   # big reveal pulse
			var total_sea := QixConfig.GRID_W * QixConfig.GRID_H - board.initial_land
			var cut_pct := 100.0 * float(claimed) / float(total_sea)
			var mult := 1
			if cut_pct >= QixConfig.SCORE_BIG_CUT_2:
				mult = 4
			elif cut_pct >= QixConfig.SCORE_BIG_CUT_1:
				mult = 2
			score += claimed * mult
			audio.play("platform_rise")
			audio.play("pulse")
		if won:
			_level_clear()


func _level_clear() -> void:
	# remaining time IS the score: every second left banks 1000 points
	var time_bonus := int(ceil(time_left)) * 1000
	if time_bonus > 0:
		score += time_bonus
		_hud_pulse(hud_score, "+%d" % time_bonus, Color(0.3, 0.85, 1.0))
	_record_run()
	if level < QixConfig.LEVELS.size() - 1:
		state = "board"
		audio.music("music_victory")
		overlay.text = "TERRITORY SECURED — %d%%" % int(board.percent)
		overlay.add_theme_color_override("font_color", Color(0.2, 0.95, 1.0))
		overlay.visible = true
		var td := create_tween()
		td.tween_property(dim_rect, "color:a", 0.45, 0.5)
		# victory lap: slow pull-back while the camera orbits the won arena
		var tc := create_tween()
		tc.tween_property(self, "cam_wide", 1.0, 5.0).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
		_show_board(level, true, "SPACE — NEXT SECTOR      ESC — MAIN MENU")
	else:
		state = "final"
		audio.music("music_victory")
		overlay.text = "ALL TERRITORY SECURED
SCORE %d" % score
		overlay.add_theme_color_override("font_color", Color(0.2, 0.95, 1.0))
		overlay.visible = true
		var td := create_tween()
		td.tween_property(dim_rect, "color:a", 0.45, 0.8)
		var tw := create_tween()
		tw.tween_property(self, "cam_wide", 1.0, 1.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_show_board(level, true, "ESC — MAIN MENU")


## Leave the leaderboard: camera pulls back, fade to black, next sector.
func _fly_out() -> void:
	audio.play("ui_select")
	board_box.visible = false
	state = "levelout"
	var td := create_tween()
	td.tween_property(dim_rect, "color:a", 0.0, 0.4)
	var tw := create_tween()
	tw.tween_property(self, "cam_wide", 1.0, 1.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	var tf := create_tween()
	tf.tween_interval(0.8)
	tf.tween_property(fade_rect, "color:a", 1.0, 0.9)
	tf.tween_callback(_next_level)


# ---------- local leaderboards (user://exonix_scores.json, no names) ----------

func _load_scores() -> Dictionary:
	var f := FileAccess.open("user://exonix_scores.json", FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	if not (d is Dictionary):
		return {}
	# migrate pre-name entries: fold their leftover time into the score
	for key in d:
		for e in d[key]:
			if e is Dictionary and not e.has("name"):
				e["score"] = int(e.get("score", 0)) + int(float(e.get("t", 0))) * 1000
				e["name"] = "PLAYER"
	return d


func _player_name() -> String:
	var n := OS.get_environment("USERNAME")
	if n.is_empty():
		n = OS.get_environment("USER")
	return (n if not n.is_empty() else "PLAYER").to_upper().left(12)


func _save_scores(d: Dictionary) -> void:
	var f := FileAccess.open("user://exonix_scores.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))


func _record_run() -> void:
	var d := _load_scores()
	var key := "level_%d" % (level + 1)
	var arr: Array = d.get(key, [])
	last_entry = {"t": snappedf(time_left, 0.1), "score": score, "name": _player_name(),
			"pct": int(board.percent), "date": Time.get_date_string_from_system()}
	arr.append(last_entry)
	arr.sort_custom(func(a, b): return int(a.get("score", 0)) > int(b.get("score", 0)))
	if arr.size() > 10:
		arr.resize(10)
	d[key] = arr
	_save_scores(d)


func _board_row(text: String, col: Color, fsize: int) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", hud_font)
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 6)
	board_box.add_child(l)


func _show_board(lv: int, highlight_last: bool, hint: String) -> void:
	audio.play("board_show")
	for c in board_box.get_children():
		c.queue_free()
	var data := _load_scores()
	var arr: Array = data.get("level_%d" % (lv + 1), [])
	_board_row("SECTOR %d — BEST RUNS" % (lv + 1), Color(0.2, 0.95, 1.0), 24)
	if arr.is_empty():
		_board_row("NO COMPLETED RUNS YET", Color(0.5, 0.65, 0.8), 18)
	var marked := false
	for i in mini(arr.size(), 6):
		var e: Dictionary = arr[i]
		var dparts := String(e.get("date", "")).split("-")
		var short_date := "%s.%s" % [dparts[2], dparts[1]] if dparts.size() == 3 else ""
		var txt := "%d.    %s    SCORE %d    %d%%    %s" % [i + 1,
				String(e.get("name", "PLAYER")), int(e.get("score", 0)), int(e.get("pct", 0)), short_date]
		var is_cur: bool = highlight_last and not marked and not last_entry.is_empty() 				and float(e.get("t", -1)) == float(last_entry.get("t", -2)) 				and int(e.get("score", -1)) == int(last_entry.get("score", -2))
		if is_cur:
			marked = true
		_board_row(txt, Color(0.35, 1.0, 0.9) if is_cur else Color(0.55, 0.7, 0.85), 18)
	if hint != "":
		_board_row(" ", Color.WHITE, 8)
		_board_row(hint, Color(0.8, 0.9, 1.0), 16)
	board_box.visible = true


## Danger arc across the (future 10-sector) campaign: 1-2 easy welcome,
## 3-5 driving, 6-8 dark chase, 9-10 ferocious (The Fall energy).
func _gameplay_track() -> String:
	if level < 2:
		return "music_play_easy"
	if level < 5:
		return "music_play_a"
	if level < 8:
		return "music_play_b"
	return "music_play_intense"


func _next_level() -> void:
	level += 1
	# decode the next level's floor maps NOW, behind the black screen — this
	# was the visible freeze between levels
	var nxt: Dictionary = QixConfig.LEVELS[level]
	for map in ["basecolor", "normal", "roughness", "metalness", "emission", "height"]:
		QixAssets.load_tex(String(nxt.tex), map)
	fly_in = true
	get_tree().reload_current_scene()


func _die(cause := "DESTROYED") -> void:
	if state != "play":
		return
	# forensics: every death prints WHAT got us and where everything was
	var pp := Vector2(player.x + 0.5, player.y + 0.5)
	var nb := "-"
	var nbd := 9999.0
	for b in enemies.balls:
		var bd: float = Vector2(b.pos).distance_to(pp)
		if bd < nbd:
			nbd = bd
			nb = String(b.type)
	var nmd := 9999.0
	for m in enemies.mines:
		nmd = minf(nmd, Vector2(m.pos).distance_to(pp))
	print("DEATH: %s | cell=%s cutting=%s | nearest ball=%s %.2f | nearest mine %.2f | burn=%s" \
			% [cause, player, board.cell(player) != QixBoard.LAND, nb, nbd, nmd, burn.active])
	_death_toast(cause)
	audio.loop_stop("cut_loop")
	audio.play("death")
	state = "dying"
	burn.reset()
	board.clear_trail()
	dir = Vector2i.ZERO
	cam_punch_spot = player_node.position
	var twc := create_tween()
	twc.tween_property(self, "cam_punch", 1.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# PHYSICS knockback (Stefan: no mid-air hover): the craft is THROWN away
	# from the killer in a ballistic arc, tumbling, and shatters on touchdown
	var threat := pp + Vector2(randf() - 0.5, randf() - 0.5)
	var tdist := 9999.0
	for tb in enemies.balls:
		var d1: float = Vector2(tb.pos).distance_to(pp)
		if d1 < tdist:
			tdist = d1
			threat = Vector2(tb.pos)
	for tm in enemies.mines:
		var d2: float = Vector2(tm.pos).distance_to(pp)
		if d2 < tdist:
			tdist = d2
			threat = Vector2(tm.pos)
	for tsw in enemies.saws:
		var d3: float = Vector2(tsw.pos).distance_to(pp)
		if d3 < tdist:
			tdist = d3
			threat = Vector2(tsw.pos)
	death_away = (pp - threat).normalized()
	death_fly = {"vel": Vector3(death_away.x, 0.0, death_away.y) * 9.0 + Vector3(0.0, 8.5, 0.0),
			"ax": Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized(), "t": 0.0}


func _death_boom() -> void:
	var boom := QixAssets.make_burst(Color(0.35, 0.9, 1.0), 2.6)
	boom.position = player_node.position
	add_child(boom)
	player_node.visible = false
	# TRON de-rez: the craft shatters into glassy voxel cubes that keep flying
	# AWAY from the killer, tumble, bounce off the floor and glitch out
	_derez_burst(player_node.position, death_away)


func _derez_burst(origin: Vector3, away: Vector2, floor_y := 0.65) -> void:
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE
	var m_dark := StandardMaterial3D.new()
	m_dark.albedo_color = Color(0.05, 0.09, 0.13, 0.92)
	m_dark.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m_dark.metallic = 0.8
	m_dark.roughness = 0.12
	m_dark.emission_enabled = true
	m_dark.emission = Color(0.2, 0.85, 1.0)
	m_dark.emission_energy_multiplier = 0.6
	var m_lit := m_dark.duplicate()
	m_lit.emission_energy_multiplier = 2.6
	var away3 := Vector3(away.x, 0.0, away.y)
	for i in 54:
		var mi := MeshInstance3D.new()
		mi.mesh = cube
		mi.material_override = m_lit if i % 3 == 0 else m_dark
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var s0 := randf_range(0.12, 0.38)
		mi.scale = Vector3.ONE * s0
		mi.position = origin + Vector3(randf_range(-1.4, 1.4), randf_range(-0.7, 0.9), randf_range(-1.4, 1.4))
		add_child(mi)
		var vel := away3 * randf_range(9.0, 19.0) 				+ Vector3(randf_range(-3.5, 3.5), randf_range(4.0, 11.0), randf_range(-3.5, 3.5))
		derez.append({"node": mi, "vel": vel, "floor": floor_y,
				"ax": Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized(),
				"spin": randf_range(4.0, 12.0), "t": 0.0, "life": randf_range(1.0, 1.6), "s0": s0})


func _update_derez(delta: float) -> void:
	for d in derez.duplicate():
		var n: MeshInstance3D = d.node
		if not is_instance_valid(n):
			derez.erase(d)
			continue
		d.t += delta
		if d.t >= float(d.life):
			n.queue_free()
			derez.erase(d)
			continue
		var v: Vector3 = d.vel
		v.y -= 24.0 * delta
		var np := n.position + v * delta
		if np.y < float(d.floor) and v.y < 0.0:
			v.y = -v.y * 0.45   # bounce off the floor
			v.x *= 0.7
			v.z *= 0.7
			np.y = float(d.floor)
		d.vel = v
		n.position = np
		n.rotate(d.ax, float(d.spin) * delta)
		var k := float(d.t) / float(d.life)
		if k > 0.62:
			# the de-rez glitch: flicker + shrink to nothing
			n.visible = fmod(d.t * 26.0, 1.0) < 0.72
			n.scale = Vector3.ONE * float(d.s0) * clampf(1.0 - (k - 0.62) / 0.38, 0.0, 1.0)


func _after_death() -> void:
	lives -= 1
	_hud_pulse(hearts_box, "-1", Color(1.0, 0.3, 0.3))
	if lives <= 0:
		_game_over("GAME OVER")
	else:
		_respawn_start(true)


## The craft is delivered from the sky onto the start cell (~1.5s), then play
## resumes with the usual invulnerability blink.
func _respawn_start(punch_back: bool) -> void:
	state = "respawn"
	audio.play("respawn")
	player = Vector2i(QixConfig.GRID_W >> 1, QixConfig.GRID_H - QixConfig.BORDER)
	pvis = Vector2(player.x + 0.5, player.y + 0.5)
	dir = Vector2i.ZERO
	move_timer = 0.0
	pyaw = 0.0
	if punch_back:
		var twc := create_tween()
		twc.tween_property(self, "cam_punch", 0.0, 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	var target := Vector3(pvis.x, QixConfig.PLAYER_HOVER, pvis.y)
	player_node.position = target + Vector3(0, 17.0, 0)
	player_node.rotation = Vector3.ZERO   # clear the death tumble
	player_node.visible = true
	var tw := create_tween()
	tw.tween_property(player_node, "position", target, 1.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_delivery_done)


func _delivery_done() -> void:
	state = "play"
	invuln = 2.0
	moved_since_spawn = false
	pickups.started = true   # pickup ramp counts from the first deploy


## Standard way out of any end screen: fresh sector-1 world under the menu.
func _to_main_menu() -> void:
	level = 0
	score = 0
	fly_in = false
	get_tree().reload_current_scene()


func _game_over(msg: String) -> void:
	state = "over"
	audio.loop_stop("cut_loop")
	audio.play("game_over")
	audio.music_duck(-12.0)
	overlay.text = msg + "
SCORE %d" % score
	overlay.add_theme_color_override("font_color", Color(1.0, 0.25, 0.35))
	overlay.visible = true
	var td := create_tween()
	td.tween_property(dim_rect, "color:a", 0.45, 0.8)
	player_node.visible = false
	_show_board(level, false, "ESC — MAIN MENU")
	var tw := create_tween()
	tw.tween_property(self, "cam_wide", 1.0, 1.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## Center-screen death cause, fades out over the death animation.
func _death_toast(cause: String) -> void:
	var l := Label.new()
	l.text = cause
	l.anchor_right = 1.0
	l.anchor_bottom = 1.0
	l.offset_top = -150.0
	l.offset_bottom = -150.0
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", hud_font)
	l.add_theme_font_size_override("font_size", 34)
	l.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 8)
	hud_layer.add_child(l)
	var tw := create_tween()
	tw.tween_interval(1.1)
	tw.tween_property(l, "modulate:a", 0.0, 0.7)
	tw.tween_callback(l.queue_free)


## HUD juice: pulse the affected label and float a "+X" next to it.
func _hud_pulse(label: Control, txt: String, col: Color) -> void:
	label.pivot_offset = label.size / 2.0
	var tw := create_tween()
	tw.tween_property(label, "scale", Vector2(1.45, 1.45), 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "scale", Vector2.ONE, 0.25)
	var fl := Label.new()
	fl.text = txt
	fl.add_theme_font_size_override("font_size", 24)
	fl.add_theme_color_override("font_color", col)
	fl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	fl.add_theme_constant_override("outline_size", 6)
	hud_layer.add_child(fl)
	fl.global_position = label.global_position + Vector2(label.size.x * 0.5 - 18.0, 30.0)
	var t2 := create_tween()
	t2.tween_property(fl, "position:y", fl.position.y - 46.0, 0.9).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t2.parallel().tween_property(fl, "modulate:a", 0.0, 0.9)
	t2.tween_callback(fl.queue_free)


## Head-start islands (L3+): pre-claimed circles and rim-anchored half-circles
## scattered around, totalling <= the level's `islands` fraction (~12-15%).
func _seed_islands(frac: float) -> void:
	if frac <= 0.0:
		return
	var total_sea := QixConfig.GRID_W * QixConfig.GRID_H - board.initial_land
	var target := int(total_sea * frac)
	var claimed := 0
	var guard := 0
	while claimed < target and guard < 60:
		guard += 1
		var r := randi_range(3, 6)
		var cx: int
		var cy: int
		if randf() < 0.5:
			# half-circle bulging from one of the four rims
			match randi_range(0, 3):
				0:
					cx = randi_range(8, QixConfig.GRID_W - 9)
					cy = QixConfig.BORDER
				1:
					cx = randi_range(8, QixConfig.GRID_W - 9)
					cy = QixConfig.GRID_H - QixConfig.BORDER - 1
				2:
					cx = QixConfig.BORDER
					cy = randi_range(8, QixConfig.GRID_H - 9)
				_:
					cx = QixConfig.GRID_W - QixConfig.BORDER - 1
					cy = randi_range(8, QixConfig.GRID_H - 9)
		else:
			cx = randi_range(9, QixConfig.GRID_W - 10)
			cy = randi_range(9, QixConfig.GRID_H - 10)
		# keep the player's landing zone open
		if Vector2(float(cx) - QixConfig.GRID_W / 2.0, float(cy) - float(QixConfig.GRID_H - QixConfig.BORDER)).length() < 13.0:
			continue
		for y in range(cy - r, cy + r + 1):
			for x in range(cx - r, cx + r + 1):
				var c := Vector2i(x, y)
				if not board.in_bounds(c) or board.is_rim(c):
					continue
				if Vector2(float(x - cx), float(y - cy)).length() <= float(r) and board.cell(c) == QixBoard.SEA:
					board.set_cell(c, QixBoard.LAND)
					claimed += 1
	board.update_percent()
	board.land_dirty = true


# ---------- SP obstacles (rise from the ground; 3 ball hits destroy) ----------

func _update_obstacles(delta: float) -> void:
	obstacle_timer -= delta
	var cap := int(QixConfig.LEVELS[level].get("obstacles", 1))
	if obstacle_timer <= 0.0 and enemies.obstacles.size() < cap:
		obstacle_timer = randf_range(9.0, 15.0)
		_spawn_obstacle()
	var dead: Array = []
	for o in enemies.obstacles:
		if o.get("flash", false):
			o.flash = false
			_obstacle_hit_fx(o)
		if int(o.hp) <= 0:
			dead.append(o)
	for o in dead:
		enemies.obstacles.erase(o)
		var node: Node3D = o.node
		world_nodes.erase(node)
		var boom := QixAssets.make_burst(Color(0.5, 0.85, 1.0), 2.4)
		boom.position = node.position + Vector3(0, 1.2, 0)
		add_child(boom)
		audio.play_at("obstacle_break", boom.position)
		var tw := create_tween()
		tw.tween_property(node, "scale", Vector3.ONE * 0.05, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_callback(node.queue_free)


func _spawn_obstacle() -> void:
	for attempt in 80:
		var c := Vector2i(randi_range(QixConfig.BORDER + 1, QixConfig.GRID_W - QixConfig.BORDER - 2),
				randi_range(QixConfig.BORDER + 1, QixConfig.GRID_H - QixConfig.BORDER - 2))
		if Vector2(c - player).length() < 13.0:
			continue
		var clash := false
		for o in enemies.obstacles:
			if Vector2(o.pos).distance_to(Vector2(c.x + 0.5, c.y + 0.5)) < 13.0:
				clash = true
				break
		if clash:
			continue
		# per-level obstacle pool (Stefan's cataclysm assignment); legacy trio
		# only if a level forgets to declare one
		var pool: Array = QixConfig.LEVELS[level].get("ob_pool", OB_TYPES)
		var kind: String = pool[randi_range(0, pool.size() - 1)]
		var node := QixAssets.make_obstacle_node(kind, QixConfig.OB_SIZE)
		QixAssets.add_mesh_outline(node, Color(0.2, 0.95, 1.0), 0.06)
		var g: float = PLATFORM_TOP if board.cell(c) == QixBoard.LAND else 0.0
		node.position = Vector3(c.x + 0.5, g - QixConfig.OB_SIZE, c.y + 0.5)
		add_child(node)
		world_nodes.append(node)
		audio.play_at("board_show", Vector3(c.x + 0.5, 1.2, c.y + 0.5), -3.0)
		if blackout_on:
			node.visible = false
		var tw := create_tween()
		tw.tween_property(node, "position:y", g, 1.1).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		enemies.obstacles.append({"pos": Vector2(c.x + 0.5, c.y + 0.5), "radius": QixConfig.OB_RADIUS,
				"hp": QixConfig.OB_HP, "cd": 0.0, "flash": false, "node": node, "phase": randf() * TAU})
		return


func _obstacle_hit_fx(o: Dictionary) -> void:
	var node: Node3D = o.node
	audio.play_at("obstacle_hit", node.position + Vector3(0, 2.0, 0))
	var boom := QixAssets.make_burst(Color(1.0, 0.8, 0.3), 1.4)
	boom.position = node.position + Vector3(0, 2.5, 0)
	add_child(boom)
	var base_y := node.position.y
	var tw := create_tween()
	tw.tween_property(node, "position:y", base_y - 0.4, 0.07)
	tw.tween_property(node, "position:y", base_y, 0.22)


# ---------- pickups & effects ----------

func _update_pickups(delta: float) -> void:
	pickups.max_cap = 6 if level >= 4 else QixPickups.MAX_ON_BOARD   # L5+: hold 5-6 on screen
	pickups.time_left = time_left
	var req := pickups.update_spawn(delta, board, player)
	if not req.is_empty():
		var node: Node3D = pickup_templates[req.kind].duplicate()
		node.position = Vector3(req.cell.x + 0.5, req.y, req.cell.y + 0.5)
		add_child(node)
		req.node = node
		audio.play_at("pickup_spawn", node.position)
	var pcell := player if state == "play" else Vector2i(-99, -99)
	var res := pickups.update_items(delta, pcell, PLATFORM_TOP, board)
	for it in res.collected:
		_collect_fx(it)
		_apply_pickup(String(it.kind))
	for it in res.expired:
		if it.node:
			it.node.queue_free()
	# a ball smashing into a pickup blows it up — burst colored by category
	var boomed: Array = []
	for it in pickups.items:
		if float(it.y) > float(it.get("ground", PLATFORM_TOP)) + 3.5:
			continue   # still high in the air
		var ipos := Vector2(it.cell.x + 0.5, it.cell.y + 0.5)
		for b in enemies.balls:
			if Vector2(b.pos).distance_to(ipos) < float(b.get("radius", 1.0)) + 1.0:
				boomed.append(it)
				break
	for it in boomed:
		pickups.items.erase(it)
		var boom := QixAssets.make_burst(_pickup_outline(String(it.kind)), 1.7)
		boom.position = Vector3(it.cell.x + 0.5, float(it.y), it.cell.y + 0.5)
		add_child(boom)
		audio.play_at("pickup_boom", boom.position)
		if it.node:
			it.node.queue_free()
	# animate: fall / float + slow rotate + expiry blink
	var t := Time.get_ticks_msec() * 0.001
	for it in pickups.items:
		var node: Node3D = it.node
		if node == null:
			continue
		# bob is BOUNCE-shaped (always upward from the float height) — a signed
		# sine dipped the item through the platform top (Stefan)
		var bob := 0.0 if it.state == "fall" else absf(sin(t * 1.8 + it.cell.x)) * 0.55
		node.position.y = float(it.y) + bob
		node.rotation.y += 0.9 * delta
		var ring: Node3D = node.get_node_or_null("GroundRing")
		if ring:
			# pinned to the ground under the item (platform top or sea level)
			ring.position.y = float(it.get("ground", PLATFORM_TOP)) + 0.06 - node.position.y
		node.visible = (not blackout_on) and (it.age < QixPickups.BLINK_AT or fmod(t * 5.0, 1.0) < 0.6)


## Eat animation: the item pops bigger, then dives into the player while a
## hologram wave (category-colored) sweeps down through the car.
func _collect_fx(it: Dictionary) -> void:
	var node: Node3D = it.node
	if node:
		var tw := create_tween()
		tw.tween_property(node, "scale", node.scale * 1.45, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(node, "position", player_node.position + Vector3(0, 0.6, 0), 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(node, "scale", Vector3.ONE * 0.02, 0.22)
		tw.tween_callback(node.queue_free)
	var col := _pickup_outline(String(it.kind))
	scan_mat.set_shader_parameter("col", Vector3(col.r, col.g, col.b))
	var ts := create_tween()
	ts.tween_method(_set_scan, 0.0, 0.999, 0.5)
	ts.tween_callback(func() -> void: scan_mat.set_shader_parameter("prog", -1.0))


func _set_scan(v: float) -> void:
	scan_mat.set_shader_parameter("prog", v)


const TOAST_NAMES := {
	"bonus_speed": "SPEED BOOST", "bonus_freeze": "ENEMY FREEZE", "bonus_time": "+10 SECONDS",
	"bonus_score": "+1000 SCORE", "bonus_life": "EXTRA LIFE",
	"debuff_blackout": "BLACKOUT", "debuff_enemyfast": "ENEMIES FASTER",
	"debuff_selfslow": "ENGINE SLOWED", "debuff_addball": "BALL SPLIT",
	"debuff_meteor": "METEOR BALLS",
	"bonus_zawarudo": "ZA WARUDO", "debuff_ballmageddon": "BALLMAGEDDON",
}

## Bottom time bar: Tron slash-ticks drifting left, cyan draining to red,
## bright frontier edge, white flash when time is added.
const TIMEBAR_SHADER := "
shader_type canvas_item;
uniform float fill : hint_range(0.0, 1.0) = 1.0;
uniform float low = 0.0;
uniform float flash = 0.0;
void fragment() {
	float sl = fract((FRAGCOORD.x + FRAGCOORD.y * 0.9) * 0.055 - TIME * 0.5);
	float tick = smoothstep(0.06, 0.18, sl) * (1.0 - smoothstep(0.60, 0.72, sl));
	vec3 base = mix(vec3(0.16, 0.85, 1.05), vec3(1.05, 0.26, 0.18), low);
	// a bright PULSE sweeps the filled bar left-to-right every ~2.4s; when the
	// clock is low it doubles down with the breathing dim
	float pw = fract(TIME * 0.42);
	float sweep = exp(-pow((UV.x - pw * fill) * 26.0, 2.0)) * step(UV.x, fill);
	float pulse = 1.0 - low * 0.35 * (0.5 + 0.5 * sin(TIME * 7.0));
	float inside = step(UV.x, fill);
	float edge = smoothstep(0.010, 0.0, abs(UV.x - fill));
	vec3 col = base * (0.30 + 0.90 * tick) * pulse + base * sweep * 1.4 + base * edge * 2.2 + vec3(0.9, 1.0, 1.0) * flash;
	float a = inside * (0.42 + 0.53 * tick) + sweep * 0.5 + edge;
	COLOR = vec4(col, clamp(a, 0.0, 1.0) * 0.95);
}
"


## De-rez: the glyphs break into screen-space pixel blocks that flare and drop out.
const TOAST_DISSOLVE_SHADER := "
shader_type canvas_item;
uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
uniform float px = 7.0;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
	vec4 c = COLOR;
	float h = hash(floor(FRAGCOORD.xy / px));
	if (h < dissolve) { discard; }
	if (h < dissolve + 0.15) { c.rgb *= 1.8; }   // blocks flare just before they go
	COLOR = c;
}
"


## Big mid-screen pop: bounce in, hold, then de-rez into pixels (Tron style).
## Ultimates (surprise-only rolls) land BIGGER and hold much longer.
func _pickup_toast(txt: String, col: Color, ultimate := false) -> void:
	hud_toast.text = txt
	hud_toast.add_theme_color_override("font_color", col)
	if toast_tw and toast_tw.is_valid():
		toast_tw.kill()
	hud_toast.reset_size()
	var vs := get_viewport().get_visible_rect().size
	# label CENTER sits at 20% screen height (Stefan: 25% still a touch low)
	var target := Vector2((vs.x - hud_toast.size.x) * 0.5, vs.y * 0.20 - hud_toast.size.y * 0.5)
	var rest_scale := Vector2(1.35, 1.35) if ultimate else Vector2.ONE
	hud_toast.pivot_offset = hud_toast.size * 0.5
	hud_toast.material.set_shader_parameter("dissolve", 0.0)
	hud_toast.position = target + Vector2(0, -110.0)
	hud_toast.scale = Vector2(1.8, 1.8) if ultimate else Vector2(1.3, 1.3)
	hud_toast.modulate = Color(1, 1, 1, 1)
	toast_tw = create_tween()
	toast_tw.tween_property(hud_toast, "position", target, 0.6) \
			.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	toast_tw.parallel().tween_property(hud_toast, "scale", rest_scale, 0.35) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	toast_tw.tween_interval(2.4 if ultimate else 0.85)
	toast_tw.tween_property(hud_toast.material, "shader_parameter/dissolve", 1.0, 0.55)
	toast_tw.parallel().tween_property(hud_toast, "position:y", target.y + 26.0, 0.55)
	toast_tw.tween_callback(func() -> void: hud_toast.modulate.a = 0.0)


func _apply_pickup(kind: String) -> void:
	var was_surprise := kind == "surprise"
	if kind == "surprise":
		# the gamble: 65% debuff / 35% bonus (Stefan's odds). Ultimates are a
		# separate rare JACKPOT gate — they must NOT sit in the regular pool
		# (uniform membership made ZA WARUDO a 1-in-6 bonus, way too common)
		var want := "debuff" if randf() < 0.65 else "bonus"
		if randf() < QixConfig.ULT_CHANCE:
			kind = "debuff_ballmageddon" if want == "debuff" else "bonus_zawarudo"
		else:
			var pool: Array = []
			for k in QixPickups.WEIGHTS:
				if String(k).begins_with(want) and float(QixPickups.WEIGHTS[k]) > 0.0 						and not String(k) in ["bonus_zawarudo", "debuff_ballmageddon"]:
					pool.append(k)
			kind = pool[randi_range(0, pool.size() - 1)]
		print("SURPRISE -> ", kind)
	var good_bad := "pickup_bad" if kind.begins_with("debuff") else "pickup_good"
	var tcol := Color(1.0, 0.32, 0.25) if kind.begins_with("debuff") else Color(0.35, 0.85, 1.0)
	var tname: String = TOAST_NAMES.get(kind, kind.to_upper())
	var is_ult := kind in ["bonus_zawarudo", "debuff_ballmageddon"]
	if is_ult:
		good_bad = "ultimate"   # the jackpot sting IS the verdict
	if was_surprise:
		audio.play("pickup_surprise")
		var tws := create_tween()
		tws.tween_interval(0.35)   # the riddle sting resolves, THEN the verdict
		tws.tween_callback(audio.play.bind(good_bad))
		tws.parallel().tween_callback(_pickup_toast.bind(tname, tcol, is_ult))
	else:
		audio.play(good_bad)
		_pickup_toast(tname, tcol, is_ult)
	match kind:
		"bonus_speed":     fx["speed"] = 5.0
		"bonus_freeze":    fx["freeze"] = 6.0   # +1s: let the chill be seen (Stefan)
		"bonus_time":
			time_left += 10.0
			timebar_mat.set_shader_parameter("flash", 1.0)
			var tfl := create_tween()
			tfl.tween_property(timebar_mat, "shader_parameter/flash", 0.0, 0.7)
			_hud_pulse(hud_percent, "+10s", Color(0.3, 0.85, 1.0))
		"bonus_score":
			score += 1000
			_hud_pulse(hud_score, "+1000", Color(0.3, 0.85, 1.0))
		"bonus_life":
			lives = mini(lives + 1, 5)   # hearts cap at 5
			_hud_pulse(hearts_box, "+1", Color(0.4, 1.0, 0.6))
		"debuff_blackout": fx["blackout"] = QixConfig.BLACKOUT_DARK + QixConfig.BLACKOUT_RESTORE
		"debuff_enemyfast": fx["enemyfast"] = 5.0
		"debuff_selfslow": fx["selfslow"] = 5.0
		"debuff_addball":
			# SPLIT: a random soft/hard ball divides in place, the halves fly
			# in opposite directions, the clone derezzes after 8s. Never evil.
			var b := enemies.split_ball(8.0)
			if not b.is_empty():
				_spawn_ball_node(b)
		"debuff_ballmageddon":
			# the ULTIMATE: every single ball splits at once — 8s of chaos
			for cb in enemies.ballmageddon(8.0):
				_spawn_ball_node(cb)
		"bonus_zawarudo":
			fx["zawarudo"] = 6.5    # THE WORLD: everything crawls at 10% (trimmed again)
		"debuff_meteor":
			fx["penetration"] = 3.0   # all balls turn meteor: carve through claimed ground
	_recompute_mults()


func _update_fx(delta: float) -> void:
	var dirty := false
	for k in fx.keys():
		fx[k] -= delta
		if fx[k] <= 0.0:
			fx.erase(k)
			dirty = true
	# blackout: BOOM -> pitch dark for BLACKOUT_DARK (world hidden, only balls
	# and mines glow in the void), then the light CRAWLS back over
	# BLACKOUT_RESTORE via the environment brightness ramp — not an instant pop
	var rem := float(fx.get("blackout", 0.0))
	var bo := rem > QixConfig.BLACKOUT_RESTORE
	if bo != blackout_on:
		blackout_on = bo
		for n in world_nodes:
			if is_instance_valid(n):
				n.visible = not bo
	if rem > 0.0 and not bo:
		var f := 1.0 - rem / QixConfig.BLACKOUT_RESTORE   # 0 -> 1 across restore
		env_ref.adjustment_brightness = lerpf(0.10, 1.0, pow(f, 1.5))
	elif env_ref.adjustment_brightness < 1.0:
		env_ref.adjustment_brightness = 1.0
	if dirty:
		_recompute_mults()


func _recompute_mults() -> void:
	player_speed_mul = 1.0
	if fx.has("speed"):
		player_speed_mul *= 1.5
	if fx.has("selfslow"):
		player_speed_mul *= 0.5
	var e := 1.0
	if fx.has("freeze"):
		e *= 0.4                    # a little more slow — the chill must be felt
	if fx.has("enemyfast"):
		e *= 1.5
	if fx.has("zawarudo"):
		e *= 0.1                    # ZA WARUDO — time nearly stops for ALL enemies
	enemies.speed_scale = e
	enemies.penetration = fx.has("penetration")
	# the CHILL (freeze or ZA WARUDO) frosts every enemy: balls, mines, saws
	var fz := fx.has("freeze") or fx.has("zawarudo")
	if fz != frozen_on:
		frozen_on = fz
		for grp in [enemies.balls, enemies.mines, enemies.saws]:
			for b in grp:
				if b.has("node") and b.node != null and is_instance_valid(b.node):
					var fr = b.node.get_node_or_null("Frost")
					if fr:
						fr.emitting = fz
	# the craft wears its own status: ice while slowed, flames while boosted
	if is_instance_valid(player_node):
		var pfrost := player_node.get_node_or_null("Frost")
		if pfrost:
			pfrost.emitting = fx.has("selfslow")
		var pfire := player_node.get_node_or_null("Fire")
		if pfire:
			pfire.emitting = fx.has("speed")


# ---------- rendering ----------

func _land_cell_xform(c: Vector2i) -> Transform3D:
	# cells OVERLAP a hair (1.004) so adjacent tops can't leave subpixel cracks
	# (the shimmering stripes/dots on captured ground — sea sparkling through
	# unshared box edges), and each cell sits at a hash-jittered micro-height
	# so the overlap strips never z-fight: the winner is deterministic.
	var jitter := fposmod(float(c.x) * 0.618 + float(c.y) * 0.414, 1.0) * 0.0012
	return Transform3D(Basis().scaled(Vector3(1.004, 1.0, 1.004)),
			Vector3(c.x + 0.5, QixConfig.PLATFORM_Y + jitter, c.y + 0.5))


## Which of this cell's four walls face OPEN space (anything not solid land).
func _cell_side_mask(c: Vector2i) -> Color:
	return Color(
			0.0 if _cell_filled(c + Vector2i(1, 0)) else 1.0,
			0.0 if _cell_filled(c + Vector2i(-1, 0)) else 1.0,
			0.0 if _cell_filled(c + Vector2i(0, 1)) else 1.0,
			0.0 if _cell_filled(c + Vector2i(0, -1)) else 1.0)


func _cell_filled(c: Vector2i) -> bool:
	return board.in_bounds(c) and board.cell(c) == QixBoard.LAND


func _refresh_cell_mask(c: Vector2i) -> void:
	var li: int = land_index.get(c, -1)
	if li >= 0:
		land_mm.set_instance_custom_data(li, _cell_side_mask(c))
		return
	var ri: int = rim_index.get(c, -1)
	if ri >= 0:
		rim_mm.set_instance_custom_data(ri, _cell_side_mask(c))


const SIDE4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


func _land_add(cells: Array) -> void:
	for c in cells:
		if land_index.has(c):
			continue
		var idx := land_list.size()
		land_mm.set_instance_transform(idx, _land_cell_xform(c))
		land_index[c] = idx
		land_list.append(c)
		land_mm.set_instance_custom_data(idx, _cell_side_mask(c))
		for d in SIDE4:
			_refresh_cell_mask(c + d)
	land_mm.visible_instance_count = land_list.size()


## Freshly captured tiles grow out of the sea floor (BAM — territory!).
func _update_rising(delta: float) -> void:
	if rising.is_empty():
		return
	var done_r: Array = []
	for r in rising:
		r.t += delta / QixConfig.RISE_TIME
		var tt: float = minf(float(r.t), 1.0)
		var e := 1.0 - pow(1.0 - tt, 3.0)   # cubic ease-out: fast pop, soft settle
		var idx: int = land_index.get(r.c, -1)
		if idx >= 0:
			var x := _land_cell_xform(r.c)
			x.origin.y -= QixConfig.RISE_DEPTH * (1.0 - e)
			land_mm.set_instance_transform(idx, x)
		if float(r.t) >= 1.0:
			done_r.append(r)
	for r in done_r:
		rising.erase(r)


func _land_remove(cells: Array) -> void:
	# swap-with-last removal keeps the instance buffer dense
	for c in cells:
		if not land_index.has(c):
			continue
		var idx: int = land_index[c]
		var last: int = land_list.size() - 1
		if idx != last:
			var moved: Vector2i = land_list[last]
			land_mm.set_instance_transform(idx, _land_cell_xform(moved))
			land_mm.set_instance_custom_data(idx, _cell_side_mask(moved))
			land_list[idx] = moved
			land_index[moved] = idx
		land_list.remove_at(last)
		land_index.erase(c)
		for d in SIDE4:
			_refresh_cell_mask(c + d)
	land_mm.visible_instance_count = land_list.size()


func _land_full_rebuild() -> void:
	land_list.clear()
	land_index.clear()
	for y in QixConfig.GRID_H:
		for x in QixConfig.GRID_W:
			var c := Vector2i(x, y)
			if board.grid[y * QixConfig.GRID_W + x] == QixBoard.LAND and not board.is_rim(c):
				land_mm.set_instance_transform(land_list.size(), _land_cell_xform(c))
				land_mm.set_instance_custom_data(land_list.size(), _cell_side_mask(c))
				land_index[c] = land_list.size()
				land_list.append(c)
	land_mm.visible_instance_count = land_list.size()
	for rc in rim_index:
		rim_mm.set_instance_custom_data(rim_index[rc], _cell_side_mask(rc))


## One ribbon segment: a thin glowing wall connecting the previous cell center
## to the new one — corners chain naturally, like the light-cycle wall.
func _trail_add(a: Vector2i, b: Vector2i) -> void:
	trail_segs.append({"a": a, "b": b})
	trail_mm.set_instance_transform(trail_count, _seg_xform(a, b))
	trail_mm.set_instance_color(trail_count, TRAIL_CYAN)
	trail_count += 1
	trail_mm.visible_instance_count = trail_count


func _seg_xform(a: Vector2i, b: Vector2i) -> Transform3D:
	var mid := Vector3((a.x + b.x) * 0.5 + 0.5, 0.55, (a.y + b.y) * 0.5 + 0.5)
	var bas := Basis()
	if a.y != b.y:
		bas = Basis(Vector3.UP, PI * 0.5)
	return Transform3D(bas, mid)


func _refresh(delta: float) -> void:
	if board.land_dirty:
		_land_full_rebuild()   # rare: initial build only — gameplay is incremental
		board.land_dirty = false
	if board.trail_dirty:
		# burn ticks / clear_trail / capture: rebuild the ribbon from the ordered
		# segments; while burning, heat spreads RED outward from the fronts
		trail_count = 0
		var fr := burn.front_indices()
		for i in trail_segs.size():
			var seg: Dictionary = trail_segs[i]
			if board.cell(seg.b) != QixBoard.TRAIL:
				continue
			var col := TRAIL_CYAN
			if burn.active:
				var di := float(mini(absi(i - fr.x), absi(i - fr.y)))
				col = TRAIL_CYAN.lerp(TRAIL_RED, clamp(1.0 - di / 6.0, 0.0, 1.0))
			trail_mm.set_instance_transform(trail_count, _seg_xform(seg.a, seg.b))
			trail_mm.set_instance_color(trail_count, col)
			trail_count += 1
		trail_mm.visible_instance_count = trail_count
		if trail_count == 0:
			trail_segs.clear()
		board.trail_dirty = false
	if state == "play":
		var bob := QixConfig.PLAYER_HOVER + sin(Time.get_ticks_msec() * 0.004) * 0.06
		# smooth visual follow of the discrete grid position (kills cell-snap vibration)
		var k := 1.0 - exp(-delta * 13.0)
		pvis = pvis.lerp(Vector2(player.x + 0.5, player.y + 0.5), k)
		player_node.position = Vector3(pvis.x, bob, pvis.y)
		if dir != Vector2i.ZERO:
			pyaw = atan2(-dir.x, -dir.y)
		player_node.rotation.y = lerp_angle(player_node.rotation.y, pyaw, 1.0 - exp(-delta * 10.0))
		player_node.visible = (not blackout_on) and (invuln <= 0.0 or fmod(Time.get_ticks_msec() * 0.006, 1.0) < 0.6)   # grace blink
	var dt := 0.0 if (state == "menu" and menu_resume) else 0.016
	for b in enemies.balls:
		var node: Node3D = b.node
		if node == null:
			continue
		var bsz: float = b.get("size", QixConfig.BALL_DIAMETER)
		node.position = Vector3(b.pos.x, 0.55 + bsz * 0.25, b.pos.y)
		var fire := node.get_node_or_null("Fire")
		var want_fire: bool = enemies.penetration and not String(b.type).begins_with("soft")
		if fire and fire.emitting != want_fire:
			fire.emitting = want_fire
		var vel: Vector2 = b.vel
		if vel.length() > 0.1:
			var axis := Vector3(vel.y, 0, -vel.x).normalized()
			node.rotate(axis, -vel.length() * dt / (QixConfig.BALL_DIAMETER * 0.5) / QixConfig.BALL_ROLL_SLOWDOWN)
	# feed ball positions to the sea shader (proximity vein flare)
	var bpos := PackedVector2Array()
	for b in enemies.balls:
		bpos.append(Vector2(b.pos))
	if bpos.size() > 16:
		bpos.resize(16)
	sea_mat.set_shader_parameter("ball_pos", bpos)
	sea_mat.set_shader_parameter("ball_count", bpos.size())
	var ppos := PackedVector2Array([pvis])
	land_mat.set_shader_parameter("ball_pos", ppos)
	rim_mat.set_shader_parameter("ball_pos", ppos)
	var tms := Time.get_ticks_msec()
	# saws: fast blade spin, sparks only while actually carving
	for sw in enemies.saws:
		var snode: Node3D = sw.node
		if snode == null:
			continue
		snode.position = Vector3(sw.pos.x, QixConfig.SAW_Y, sw.pos.y)
		snode.rotation.y += QixConfig.SAW_SPIN * dt
		var sparks := snode.get_node_or_null("Sparks")
		var cutting_now: bool = float(sw.get("carve_t", 0.0)) > 0.0
		if sparks and sparks.emitting != cutting_now:
			sparks.emitting = cutting_now
	# SP obstacles: slow spin around their center + gentle breathing pulse
	for ob in enemies.obstacles:
		var onode: Node3D = ob.node
		if onode:
			onode.rotation.y += 0.35 * dt
			onode.scale = Vector3.ONE * (1.0 + 0.05 * sin(tms * 0.0008 + float(ob.get("phase", 0.0))))
	for m in enemies.mines:
		var node: Node3D = m.node
		if node == null:
			continue
		node.position = Vector3(m.pos.x, QixConfig.MINE_Y + sin(tms * 0.003) * 0.05, m.pos.y)
		node.rotation.y += 0.8 * dt
		var beacon := node.get_node_or_null("Beacon")
		if beacon:
			beacon.visible = fmod(tms * 0.001 * 3.0, 1.0) < 0.55   # police blink
	if dt > 0.0:
		_update_rising(delta)
	var fronts := burn.front_cells()
	for i in burn_markers.size():
		var mk: MeshInstance3D = burn_markers[i]
		var lit := i < fronts.size()
		if mk.visible != lit:
			mk.visible = lit
			var fp := mk.get_node_or_null("Fire")
			if fp:
				fp.emitting = lit
		if lit:
			mk.position = Vector3(fronts[i].x + 0.5, 0.78, fronts[i].y + 0.5)
	hud_level.text = "SECTOR %d / %d" % [level + 1, QixConfig.LEVELS.size()]
	hud_percent.text = "%d%%  /  %d%%" % [int(board.percent), int(QixConfig.WIN_PERCENT)]
	for i in hearts.size():
		hearts[i].modulate = Color(0.30, 0.95, 1.0) if i < lives else Color(0.4, 0.7, 1.0, 0.10)
	hud_score.text = "SCORE %d" % score
	# the bottom bar IS the clock: fill drains, red pulse when low
	var low := time_left < 15.0 and state == "play"
	timebar_mat.set_shader_parameter("fill", clampf(time_left / QixConfig.LEVEL_TIME, 0.0, 1.0))
	timebar_mat.set_shader_parameter("low", 1.0 if low else 0.0)
	# the surrounding energy web IS the territory bar: capture gains ease in
	# (riding the capture pulse), losses snap down instantly
	bg_clock += delta
	backdrop_mat_ref.set_shader_parameter("clock", bg_clock)
	var bg_target: float = clamp(board.percent / QixConfig.WIN_PERCENT, 0.0, 1.0)
	if bg_target < bg_progress:
		bg_progress = bg_target
	else:
		bg_progress = move_toward(bg_progress, bg_target, delta * 0.30)
	backdrop_mat_ref.set_shader_parameter("progress", bg_progress)
	_update_camera()


func _update_camera() -> void:
	var center := Vector2(QixConfig.GRID_W / 2.0, QixConfig.GRID_H / 2.0)
	var off := pvis - center
	var target_pos := cam_base_pos + Vector3(off.x * cam_follow_pos, 0.0, off.y * cam_follow_pos * 0.75)
	var target_look := cam_base_look + Vector3(off.x * cam_follow_look, 0.0, off.y * cam_follow_look * 0.8)
	if cam_punch > 0.001:   # death: lunge toward the boom
		target_pos = target_pos.lerp(cam_punch_spot + Vector3(0.0, 7.0, 10.0), cam_punch * 0.5)
		target_look = target_look.lerp(cam_punch_spot, cam_punch * 0.85)
	if cam_wide > 0.001:    # game over / level out: pull back and up
		target_pos += Vector3(0.0, 16.0, 12.0) * cam_wide
	if absf(pause_orbit) > 0.0001:   # pause: slow cinematic orbit, then glide home
		var pivot := Vector3(center.x, 0.0, center.y)
		target_pos = pivot + (target_pos - pivot).rotated(Vector3.UP, pause_orbit)
		target_look = target_look.lerp(pivot, 0.35)
	if not cam.is_inside_tree():
		return
	cam.position = cam.position.lerp(target_pos, QixConfig.CAM_LERP)
	cam.look_at(target_look)
