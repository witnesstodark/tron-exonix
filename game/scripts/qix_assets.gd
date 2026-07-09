class_name QixAssets
## Static asset helpers: runtime texture loading (single source of truth in
## ../assets/textures), the floor shader, flat emissive materials, and GLB
## loading for enemies/hero (../assets/3d). No import-cache dependency.

const FLOOR_SHADER := "
shader_type spatial;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D metal_tex : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D emis_tex : source_color, hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D height_tex : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float emission_energy = 1.0;
uniform float tile = 8.0;
uniform float albedo_mul = 1.0;      // darken/kill tint (sea red reduction)
uniform float rough_mul = 0.45;      // Tron wet-glass: pull roughness DOWN
uniform float rough_override = -1.0; // >=0: flat roughness, ignore the map (Stefan's Blender values)
uniform float metal_override = -1.0; // >=0: flat metallic, ignore the map
uniform float rough_min = 0.05;
uniform float spec = 0.7;            // stronger dielectric reflections
uniform float wave_strength = 0.4;   // traveling gradient glow depth (peak = tuned)
uniform float wave_len = 34.0;       // world units per glow wave
uniform float wave_speed = 0.45;     // rad/s — slow sweep
uniform float wave_unevenness = 5.0; // height-map phase offset -> organic uneven sweep
uniform float edge_glow = 0.0;       // dashed glow on vertical faces (land frontier walls)
uniform vec3 edge_col : source_color = vec3(0.2, 0.95, 1.0);
uniform float wall_top = 1.08;       // world y of the platform top edge
uniform float dash_freq = 3.0;       // slash-ticks per world unit (short, even)
uniform vec2 arena = vec2(60.0, 60.0); // outer rim detection
uniform vec3 wall_albedo : source_color = vec3(0.012, 0.025, 0.04); // walls: flat dark, NO texture
uniform vec2 ball_pos[16];           // sea only: rolling balls flare the red veins
uniform int ball_count = 0;
uniform float ball_glow_radius = 5.0;
uniform float ball_glow_energy = 0.0;
uniform float normal_depth = 1.0;    // >1 punches up the relief (sea reflectivity)
varying vec3 wpos;
varying vec3 wnorm;
varying vec4 side_mask;              // per-instance: which walls face open space
varying vec3 iorigin;                // instance origin = cell center
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	side_mask = INSTANCE_CUSTOM;     // r:+x g:-x b:+z a:-z (1 = exposed)
	iorigin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}
void fragment() {
	vec2 uv = wpos.xz / tile;
	// GEOMETRIC normal from screen derivatives — vertex normals proved
	// unreliable here (every wall gate keyed on them silently failed)
	vec3 gn = normalize(cross(dFdx(wpos), dFdy(wpos)));
	float wallf = step(0.5, 1.0 - abs(gn.y));      // 1 on vertical faces
	// INTERIOR walls are DISCARDED outright (Stefan's split): solid ground has
	// no inner vertical geometry left to bleed through the top seams — only
	// contour walls exist. The sea plane has no walls, so it never discards.
	if (wallf > 0.5) {
		// which side is this wall on? Judged by POSITION relative to the cell
		// center — derivative normals flip sign between Vulkan and GL (dFdy
		// direction), which inverted the mask on the web build.
		vec2 rel = wpos.xz - iorigin.xz;
		float keep;
		if (abs(rel.x) > abs(rel.y)) {
			keep = rel.x > 0.0 ? side_mask.r : side_mask.g;
		} else {
			keep = rel.y > 0.0 ? side_mask.b : side_mask.a;
		}
		if (keep < 0.5) { discard; }
	}
	// SEPARATION (Stefan): tops wear the platform texture; walls are their own
	// flat dark surface — no texture, no normal map — carrying ONLY the lights
	ALBEDO = mix(texture(albedo_tex, uv).rgb * albedo_mul, wall_albedo, wallf);
	// walls go MATTE: gloss on vertical faces mirrored the bright sun/sky into
	// big white bars. TOPS keep the wet-glass shine — but it must FADE at
	// grazing view angles too: Fresnel turns the glossy patches of the rough-
	// ness pattern into horizon mirrors (the alternating white segments on the
	// far rim). Near/mid field (steeper view) keeps the full shine.
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float gloss_ok = smoothstep(0.12, 0.42, ndv);
	float r_tex = max(texture(rough_tex, uv).r * rough_mul, rough_min);
	if (rough_override >= 0.0) { r_tex = rough_override; }
	ROUGHNESS = mix(0.92, r_tex, gloss_ok * (1.0 - wallf));
	float mtl = metal_override >= 0.0 ? metal_override : texture(metal_tex, uv).r;
	METALLIC = mtl * (1.0 - wallf) * gloss_ok;
	SPECULAR = mix(0.06, spec, gloss_ok * (1.0 - wallf));
	NORMAL_MAP = mix(texture(normal_tex, uv).rgb, vec3(0.5, 0.5, 1.0), wallf);
	// distance-adaptive shading = manual specular AA: far pixels flatten the
	// normal map and roughen up, so subpixel relief can't sparkle (Forward+
	// has a screen-space roughness limiter; GL Compatibility has none)
	float cam_d = length(CAMERA_POSITION_WORLD - wpos);
	float far_k = clamp((cam_d - 30.0) / 70.0, 0.0, 1.0);
	NORMAL_MAP_DEPTH = normal_depth * (1.0 - 0.85 * far_k);
	ROUGHNESS = mix(ROUGHNESS, max(ROUGHNESS, 0.5), far_k);
	// gradient glow: slow diagonal sweep, phase-shifted per-pixel by the HEIGHT map
	// so areas light up unevenly/organically; the tuned level stays the PEAK.
	float h = texture(height_tex, uv).r;
	float wave = 1.0 - wave_strength * (0.5 + 0.5 * sin((wpos.x + wpos.z) * (6.2831 / wave_len) - TIME * wave_speed + h * wave_unevenness));
	// texture emission on TOP faces only — on walls the XZ projection smears
	// bright seams into solid slabs, so gate it out. ALSO fade it at grazing
	// view angles: an emissive seam near a platform edge seen edge-on compresses
	// into a white-hot bar hugging the frontier (the block artifact).
	float topface = 1.0 - wallf;
	float graze = smoothstep(0.12, 0.45, clamp(dot(NORMAL, VIEW), 0.0, 1.0));
	// ball-proximity flare (sea): veins flame up within ball_glow_radius of any
	// ball, quadratic gradient falloff — quiet base emission otherwise
	float prox = 0.0;
	for (int i = 0; i < ball_count; i++) {
		float bd = distance(wpos.xz, ball_pos[i]);
		prox = max(prox, 1.0 - smoothstep(0.0, ball_glow_radius, bd));
	}
	float e_energy = emission_energy + ball_glow_energy * prox * prox;
	EMISSION = texture(emis_tex, uv).rgb * e_energy * wave * topface * graze;
	// slash-ticks on vertical faces: short tilted dashes ( / / / / ), evenly
	// alternating glow/dark along the whole claimed frontier perimeter
	if (edge_glow > 0.001 && wallf > 0.5) {
		float band = smoothstep(-0.05, 0.12, wpos.y);      // soft base fade
		// OUTER arena rim -> one continuous solid light band (Stefan's rule);
		// INNER claimed frontiers -> slash-ticks only
		float d_edge = min(min(wpos.x, arena.x - wpos.x), min(wpos.z, arena.y - wpos.z));
		if (d_edge < 0.06) {
			EMISSION += edge_col * band * edge_glow * 0.8;
		} else {
			float along = abs(gn.z) > abs(gn.x) ? wpos.x : wpos.z;
			float coord = along + (wall_top - wpos.y) * 0.9;   // tilt -> slash look
			float f = fract(coord * dash_freq);
			float tick = smoothstep(0.05, 0.15, f) * (1.0 - smoothstep(0.45, 0.55, f));
			float ppp = fwidth(coord * dash_freq);             // subpixel -> average, no aliasing lottery
			float unresolved = clamp((ppp - 0.25) / 0.5, 0.0, 1.0);
			float cov = mix(tick, 0.22, unresolved);
			EMISSION += edge_col * cov * band * edge_glow;
		}
	}
}
"

# Procedural energy-web backdrop AND the territory progress indicator:
# a broken, maze-like network of thin lines (some segments missing, a slice of
# them slowly re-rolling) that starts energized only FAR out at 0% territory,
# crawls inward as capture grows, and finally plugs into the platform at 100%
# of the win threshold. Sparse pioneer sparks flicker ahead of the frontier.
const BACKDROP_SHADER := "
shader_type spatial;
render_mode unshaded;
uniform vec3 line_col : source_color = vec3(0.10, 0.65, 0.85);
uniform float cell = 4.0;
uniform float base_glow = 0.5;
uniform float pulse_glow = 2.4;
uniform vec2 center = vec2(30.0, 30.0);
uniform float fade_start = 55.0;
uniform float fade_end = 360.0;
uniform vec2 arena_min = vec2(0.0, 0.0);
uniform vec2 arena_max = vec2(60.0, 60.0);
uniform float progress = 0.0;    // territory percent / win threshold, 0..1
uniform float density = 0.60;    // fraction of segments that exist at all
uniform float clock = 0.0;       // main-driven clock (matches pulse_t timing)
uniform float pulse_t = -100.0;  // clock stamp of the last capture pulse
varying vec3 wpos;
float hash(vec2 n) { return fract(sin(dot(n, vec2(127.1, 311.7))) * 43758.5453); }
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float seg_energy(vec2 id, float salt, float d) {
	float h = hash(id + vec2(salt * 17.31, salt * 3.7));
	// a restless slice of segments re-rolls slowly -> the pattern breathes
	float restless = step(0.82, hash(id + vec2(salt, 9.17)));
	float slot = floor(TIME * 0.20 + h * 6.0) * restless;
	// the web DENSIFIES as territory grows — the filling itself is visible
	float dens = clamp(density * (0.85 + 0.9 * clamp(progress, 0.0, 1.0)), 0.0, 0.97);
	float exist = step(hash(id + vec2(slot * 0.913, salt * 1.3)), dens);
	// converging frontier: starts CLOSE enough to read (60 out, not 105) and
	// crawls INWARD with territory progress, plugging into the edge at 100%
	float reach = mix(60.0, -6.0, clamp(progress, 0.0, 1.0)) + (h - 0.5) * 26.0;
	float act = smoothstep(reach - 7.0, reach + 7.0, d);
	// sparse pioneer sparks flickering ahead of the frontier
	float pioneer = step(0.95, hash(id * 1.61 + vec2(salt, salt)))
			* (0.35 + 0.65 * (0.5 + 0.5 * sin(TIME * (1.2 + h * 2.4) + h * 37.0)));
	return exist * max(act, pioneer);
}
void fragment() {
	vec2 p = wpos.xz / cell;
	vec2 over = max(max(arena_min - wpos.xz, wpos.xz - arena_max), vec2(0.0));
	float d = length(over);   // world distance outside the arena rectangle
	// hairline AA masks — lines stay ~1px thin and dissolve with distance
	vec2 dd = fwidth(p) + 1e-6;
	vec2 f = fract(p);
	vec2 q = min(f, 1.0 - f) / dd;
	float lx = 1.0 - min(q.x, 1.0);
	float lz = 1.0 - min(q.y, 1.0);
	// per-SEGMENT ids: each 1-cell piece of line decides its own fate
	vec2 id_x = vec2(floor(p.x + 0.5), floor(p.y));
	vec2 id_z = vec2(floor(p.x), floor(p.y + 0.5));
	float ex = seg_energy(id_x, 1.0, d);
	float ez = seg_energy(id_z, 2.0, d);
	// uneven brightness so the web shimmers instead of reading as a sheet
	float vx = 0.45 + 0.55 * hash(id_x * 2.13);
	float vz = 0.45 + 0.55 * hash(id_z * 2.71);
	// data bits drifting along energized lines
	float px = fract(p.y * 0.04 - TIME * (0.03 + 0.05 * hash(vec2(id_x.x, 3.7))));
	float bit_x = smoothstep(0.012, 0.0, abs(px - 0.5)) * step(hash(vec2(id_x.x, 7.3)), 0.22);
	float pz = fract(p.x * 0.04 - TIME * (0.03 + 0.05 * hash(vec2(id_z.y, 5.1))));
	float bit_z = smoothstep(0.012, 0.0, abs(pz - 0.5)) * step(hash(vec2(id_z.y, 9.1)), 0.22);
	float glow = lx * ex * (base_glow * vx + bit_x * pulse_glow)
			+ lz * ez * (base_glow * vz + bit_z * pulse_glow);
	// sparse dash-filled panels: a few cells carry diagonal hatch dashes (kin
	// of the inner-wall slashes) — volume between the lines, fewer than lines
	vec2 cid = floor(p);
	if (hash(cid * 3.77) < 0.10) {
		float pe = seg_energy(cid, 3.0, d);
		float su = (f.x + f.y) * 6.0;
		float sv = (f.x - f.y) * 3.0;
		float stripe = smoothstep(0.34, 0.22, abs(fract(su) - 0.5));
		float dash = step(fract(sv + hash(cid * 1.31)), 0.55);
		float inset = step(0.10, f.x) * step(f.x, 0.90) * step(0.10, f.y) * step(f.y, 0.90);
		float ppw = fwidth(su);
		float hatch = mix(stripe * dash, 0.26, clamp((ppw - 0.5) / 1.0, 0.0, 1.0));
		glow += hatch * inset * pe * base_glow * 0.38 * (0.5 + 0.5 * hash(cid * 5.13));
	}
	// breathing: ONE long wave (λ ~115 units — a single crest on screen)
	// rolling INWARD; faster + deeper the closer we are to completion.
	// Short λ read as \"many small pulses\" — Stefan wants one big one.
	float prg = clamp(progress, 0.0, 1.0);
	glow *= 1.0 + (0.22 + 0.24 * prg) * sin(d * 0.055 + clock * (1.8 + 4.2 * prg));
	glow *= 1.0 + 0.35 * prg;   // the whole web charges up as capture grows
	// capture pulse: a bright ring sweeps from deep space into the platform,
	// riding over the web while `progress` eases up to reveal the new reach
	float age = clock - pulse_t;
	if (age >= 0.0 && age < 1.7) {
		// one BIG wide ring per capture (widened + brightened per Stefan)
		float pr = mix(150.0, 0.0, age / 1.7);
		glow *= 1.0 + exp(-abs(d - pr) * 0.05) * (1.0 - age / 1.7) * 3.4;
	}
	float fade = 1.0 - smoothstep(fade_start, fade_end, distance(wpos.xz, center));
	fade = fade * fade * fade;   // mist-like: near reads, far melts away
	vec3 c = line_col * glow * fade;
	ALBEDO = c;
	EMISSION = c * 1.2;
}
"


static func backdrop_mat() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = BACKDROP_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("cell", QixConfig.BG_CELL)
	m.set_shader_parameter("base_glow", QixConfig.BG_BASE_GLOW)
	m.set_shader_parameter("pulse_glow", QixConfig.BG_PULSE_GLOW)
	m.set_shader_parameter("center", Vector2(QixConfig.GRID_W / 2.0, QixConfig.GRID_H / 2.0))
	m.set_shader_parameter("fade_start", QixConfig.BG_FADE_START)
	m.set_shader_parameter("fade_end", QixConfig.BG_FADE_END)
	m.set_shader_parameter("arena_min", Vector2.ZERO)
	m.set_shader_parameter("arena_max", Vector2(QixConfig.GRID_W, QixConfig.GRID_H))
	return m


static func tex_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../assets/textures")


static func glb_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../assets/3d")


## HDRI panorama for sky reflections. Prefers a REAL .hdr (bright lights live
## above 1.0 -> punchy reflections, dark sky stays dark — the LDR webp capped
## every light at 1.0, Stefan's three.js instinct was right); .webp = fallback.
static func load_sky_panorama(sky_name: String) -> ImageTexture:
	if sky_name.is_empty():
		return null
	var root := ProjectSettings.globalize_path("res://").path_join("../assets/sky")
	var hdr := root.path_join(sky_name + ".hdr")
	if FileAccess.file_exists(hdr):
		var himg := Image.load_from_file(hdr)
		if himg != null:
			return ImageTexture.create_from_image(himg)
		push_warning("hdr load failed (runtime loader missing?), falling back to webp: " + hdr)
	var img := Image.load_from_file(root.path_join(sky_name + ".webp"))
	if img == null:
		push_warning("sky panorama missing: " + sky_name)
		return null
	return ImageTexture.create_from_image(img)


static var _tex_cache := {}
static var _glb_cache := {}
static var _ghost_sh: Shader = null
static var _ring_sh: Shader = null


static func load_tex(mat_name: String, map_name: String) -> ImageTexture:
	var path := tex_root().path_join(mat_name).path_join(map_name + ".webp")
	if _tex_cache.has(path):
		return _tex_cache[path]
	var img := Image.load_from_file(path)
	if img == null:
		push_warning("texture missing: " + path)
		return null
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_tex_cache[path] = t   # decode+mipmaps once per session — level swaps get instant
	return t


## Floor material: world-XZ UVs tile the PATINA set continuously across cells.
static func floor_mat(mat_name: String, emission_energy: float) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = FLOOR_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	for pair in [["albedo_tex", "basecolor"], ["normal_tex", "normal"], ["rough_tex", "roughness"],
			["metal_tex", "metalness"], ["emis_tex", "emission"], ["height_tex", "height"]]:
		var t := load_tex(mat_name, pair[1])
		if t:
			m.set_shader_parameter(pair[0], t)
	m.set_shader_parameter("emission_energy", emission_energy)
	m.set_shader_parameter("tile", QixConfig.TILE_REPEAT)
	return m


static func flat_mat(albedo: Color, emissive := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emissive
		m.emission_energy_multiplier = energy
	return m


static func load_glb_scene(glb_name: String) -> Node3D:
	var path := glb_root().path_join(glb_name + ".glb")
	if _glb_cache.has(path):
		return _glb_cache[path].duplicate()
	if not FileAccess.file_exists(path):
		return null
	var doc := GLTFDocument.new()
	var gstate := GLTFState.new()
	if doc.append_from_file(path, gstate) != OK:
		return null
	var scene := doc.generate_scene(gstate)
	_glb_cache[path] = scene   # parse once; hand out duplicates
	return scene.duplicate()


static func merged_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var first := true
	var stack: Array = [node]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D:
			var a: AABB = n.transform * n.get_aabb()
			if first:
				aabb = a
				first = false
			else:
				aabb = aabb.merge(a)
		for c in n.get_children():
			stack.append(c)
	return aabb


## SP obstacle node: Stefan's sp_* GLB when exported (base anchored at the
## origin so it can RISE from the ground), else a distinct emissive primitive.
static func make_obstacle_node(kind: String, size: float) -> Node3D:
	var holder := Node3D.new()
	var scene := load_glb_scene(kind)
	if scene:
		holder.add_child(scene)
		var aabb := merged_aabb(scene)
		var m: float = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		if m > 0.0001:
			var sc := size / m
			scene.scale = Vector3(sc, sc, sc)
			var center := (aabb.position + aabb.size * 0.5) * sc
			scene.position = Vector3(-center.x, -aabb.position.y * sc, -center.z)
		return holder
	var mi := MeshInstance3D.new()
	var col := Color(0.5, 0.9, 1.0)
	match kind:
		"sp_crystal":
			var pm := PrismMesh.new()
			pm.size = Vector3(size * 0.62, size, size * 0.62)
			mi.mesh = pm
			col = Color(0.45, 0.9, 1.0)
		"sp_rock":
			var sm := SphereMesh.new()
			sm.radius = size * 0.5
			sm.height = size * 0.82
			mi.mesh = sm
			col = Color(0.4, 0.55, 0.7)
		_:
			var cm := CylinderMesh.new()
			cm.top_radius = 0.06
			cm.bottom_radius = size * 0.34
			cm.height = size
			mi.mesh = cm
			col = Color(0.7, 0.5, 1.0)
	mi.mesh.material = flat_mat(col * 0.25, col, 0.5)   # quiet fallback, not a beacon
	mi.position.y = size * 0.5
	holder.add_child(mi)
	return holder


## GLB wrapped + normalized to target_size; emissive sphere fallback.
## yaw_deg fixes a wrong forward axis in the source GLB (rotates the content
## inside the wrapper, so gameplay steering stays untouched).
static func make_enemy_node(glb_name: String, target_size: float, fallback: Color, yaw_deg := 0.0) -> Node3D:
	var holder := Node3D.new()
	var scene := load_glb_scene(glb_name)
	if scene:
		var yawer := Node3D.new()
		yawer.rotation.y = deg_to_rad(yaw_deg)
		holder.add_child(yawer)
		yawer.add_child(scene)
		var aabb := merged_aabb(scene)
		var m: float = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		if m > 0.0001:
			var s := target_size / m
			scene.scale = Vector3(s, s, s)
			var center := (aabb.position + aabb.size * 0.5) * s
			scene.position = -center
	else:
		var mi := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = target_size * 0.5
		sph.height = target_size
		sph.material = flat_mat(fallback * 0.15, fallback, 2.4)
		mi.mesh = sph
		holder.add_child(mi)
	return holder


## Per-channel albedo tint (the hunter mine reads REDDER than its siblings).
static func tint_materials(node: Node3D, tint: Color) -> void:
	var stack: Array = [node]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and n.mesh:
			for si in n.mesh.get_surface_count():
				var mat = n.get_active_material(si)
				if mat is BaseMaterial3D:
					var m2: BaseMaterial3D = mat.duplicate()
					m2.albedo_color = Color(m2.albedo_color.r * tint.r, m2.albedo_color.g * tint.g,
							m2.albedo_color.b * tint.b, m2.albedo_color.a)
					n.set_surface_override_material(si, m2)
		for c in n.get_children():
			stack.append(c)


## Darken a GLB's materials (albedo multiply), e.g. a too-bright hero.
static func dim_materials(node: Node3D, mul: float) -> void:
	var stack: Array = [node]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and n.mesh:
			for si in n.mesh.get_surface_count():
				var mat = n.get_active_material(si)
				if mat is BaseMaterial3D:
					var m2: BaseMaterial3D = mat.duplicate()
					m2.albedo_color = Color(m2.albedo_color.r * mul, m2.albedo_color.g * mul, m2.albedo_color.b * mul, m2.albedo_color.a)
					n.set_surface_override_material(si, m2)
		for c in n.get_children():
			stack.append(c)


## Ghost props: textured but DESATURATED and pulled toward the cool blue-black
## family so they read as city silhouettes without fighting the floor (no
## emission; modest spec stays). Alpha is a per-instance uniform for the fade.
const GHOST_SHADER := "
shader_type spatial;
render_mode cull_back;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform float sat = 0.55;
uniform float brightness = 0.9;
uniform float alpha = 0.45;
void fragment() {
	vec4 c = texture(albedo_tex, UV);
	float luma = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
	vec3 col = mix(vec3(luma), c.rgb, sat) * brightness;
	col = mix(col, col * vec3(0.80, 0.95, 1.12), 0.30);
	ALBEDO = col;
	ALPHA = alpha;
	ROUGHNESS = 0.65;
	SPECULAR = 0.45;
}
"

static func make_ghost(node: Node3D, alpha: float) -> Array:
	var mats: Array = []
	if _ghost_sh == null:
		_ghost_sh = Shader.new()
		_ghost_sh.code = GHOST_SHADER
	var stack: Array = [node]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and n.mesh:
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			for si in n.mesh.get_surface_count():
				var mat = n.get_active_material(si)
				if mat is BaseMaterial3D:
					var m2 := ShaderMaterial.new()
					m2.shader = _ghost_sh
					if mat.albedo_texture:
						m2.set_shader_parameter("albedo_tex", mat.albedo_texture)
					m2.set_shader_parameter("alpha", alpha)
					n.set_surface_override_material(si, m2)
					mats.append(m2)
		for c in n.get_children():
			stack.append(c)
	return mats


## Tron light-ribbon wall for the player trail: translucent emissive slab,
## brighter along the top edge; COLOR carries the per-instance tint so the
## burn can paint segments red as it spreads.
const TRAIL_SHADER := "
shader_type spatial;
render_mode blend_mix, cull_disabled;
uniform float energy = 3.0;
uniform float alpha = 0.62;
varying float vy;
void vertex() { vy = VERTEX.y; }
void fragment() {
	float topline = smoothstep(0.42, 0.62, vy);
	ALBEDO = COLOR.rgb * 0.3;
	EMISSION = COLOR.rgb * energy * (0.75 + 0.9 * topline);
	ALPHA = alpha;
}
"

static func trail_wall_mat() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = TRAIL_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	return m


## Fire VFX for meteor-mode balls: additive billboard sparks, world-space so
## the flames trail behind the moving ball. Toggle via .emitting.
static func make_fire_particles(radius: float, col := Color(1.0, 0.45, 0.1)) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Fire"
	p.amount = 70
	p.lifetime = 0.55
	p.emitting = false
	p.local_coords = false
	var quad := QuadMesh.new()
	quad.size = Vector2(0.42, 0.42)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 2.5
	quad.material = m
	p.draw_pass_1 = quad
	var ppm := ParticleProcessMaterial.new()
	ppm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ppm.emission_sphere_radius = radius * 0.75
	ppm.direction = Vector3(0, 1, 0)
	ppm.spread = 55.0
	ppm.initial_velocity_min = 1.6
	ppm.initial_velocity_max = 3.6
	ppm.gravity = Vector3(0, 3.0, 0)
	ppm.scale_min = 0.5
	ppm.scale_max = 1.2
	var grad := Gradient.new()
	var hot := col.lerp(Color.WHITE, 0.45)
	hot.a = 0.9
	var mid := col
	mid.a = 0.7
	var cold := col.darkened(0.6)
	cold.a = 0.0
	grad.set_color(0, hot)
	grad.set_color(1, cold)
	grad.add_point(0.45, mid)
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	ppm.color_ramp = gt
	p.process_material = ppm
	return p


## Procedural Tron heart for the lives HUD (implicit heart curve, drawn once).
static var _heart_texture: ImageTexture = null

static func heart_tex() -> ImageTexture:
	if _heart_texture:
		return _heart_texture
	var s := 48
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	for y in s:
		for x in s:
			var nx := (float(x) - s / 2.0 + 0.5) / (s * 0.30)
			var ny := -(float(y) - s / 2.0 + 2.5) / (s * 0.30)
			var f := pow(nx * nx + ny * ny - 1.0, 3.0) - nx * nx * ny * ny * ny
			var a := 1.0 - smoothstep(-0.08, 0.10, f)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_heart_texture = ImageTexture.create_from_image(img)
	return _heart_texture


## Tiny procedural 6-armed snowflake sprite for the freeze VFX (drawn once).
static var _flake_tex: ImageTexture = null

static func _snowflake_tex() -> ImageTexture:
	if _flake_tex:
		return _flake_tex
	var s := 32
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := Vector2(s / 2.0 - 0.5, s / 2.0 - 0.5)
	for y in s:
		for x in s:
			var p := Vector2(x, y) - c
			var r := p.length()
			var a := 0.0
			if r < 1.6:
				a = 1.0
			else:
				var ang := fposmod(p.angle(), PI / 3.0)      # 6-fold symmetry
				var d: float = min(ang, PI / 3.0 - ang) * r  # distance to nearest arm
				if d < 0.9 and r < s * 0.48:
					a = clampf(1.2 - d, 0.0, 1.0) * clampf(1.0 - r / (s * 0.48), 0.15, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_flake_tex = ImageTexture.create_from_image(img)
	return _flake_tex


## FREEZE bonus chill: crisp little snowflakes spill off a frozen ball and
## sink, world-space — so a moving ball leaves a chilly trace behind it.
static func make_frost_particles(radius: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Frost"
	p.amount = 72
	p.lifetime = 1.0
	p.emitting = false
	p.local_coords = false
	var quad := QuadMesh.new()
	quad.size = Vector2(0.46, 0.46)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = _snowflake_tex()
	m.albedo_color = Color(0.8, 0.94, 1.0)
	m.emission_enabled = true
	m.emission = Color(0.55, 0.85, 1.0)
	m.emission_energy_multiplier = 3.4
	quad.material = m
	p.draw_pass_1 = quad
	var ppm := ParticleProcessMaterial.new()
	ppm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ppm.emission_sphere_radius = radius * 0.9
	ppm.direction = Vector3(0, -1, 0)
	ppm.spread = 40.0
	ppm.initial_velocity_min = 0.3
	ppm.initial_velocity_max = 1.1
	ppm.gravity = Vector3(0, -1.6, 0)
	ppm.angle_min = 0.0
	ppm.angle_max = 360.0
	ppm.scale_min = 0.5
	ppm.scale_max = 1.1
	var grad := Gradient.new()
	grad.set_color(0, Color(0.95, 1.0, 1.0, 0.95))
	grad.set_color(1, Color(0.5, 0.8, 1.0, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	ppm.color_ramp = gt
	p.process_material = ppm
	return p


## Hologram scan shell around the player: a horizontal energy band sweeps
## top->bottom when `prog` runs 0..1 (outside that range = invisible).
const SCAN_SHADER := "
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, shadows_disabled, depth_draw_never;
uniform vec3 col : source_color = vec3(0.2, 0.95, 1.0);
uniform float prog = -1.0;
uniform float half_h = 2.0;
varying float vh;
void vertex() { vh = clamp(VERTEX.y / (half_h * 2.0) + 0.5, 0.0, 1.0); }
void fragment() {
	float band = 1.0 - smoothstep(0.0, 0.14, abs((1.0 - vh) - prog));
	float vis = step(0.0, prog) * (1.0 - step(1.0, prog));
	ALBEDO = col * band * vis * 2.2;
}
"

static func make_scan_shell(size: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "ScanShell"
	var sm := SphereMesh.new()
	sm.radius = size * 0.62
	sm.height = size * 1.24
	mi.mesh = sm
	var sh := Shader.new()
	sh.code = SCAN_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("half_h", size * 0.62)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Constant crackling electricity around a mine: short-lived bright sparks
## jittering on a shell just outside the body.
static func make_electric_particles(radius: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Electric"
	p.amount = 26
	p.lifetime = 0.22
	p.emitting = true
	p.local_coords = true
	var quad := QuadMesh.new()
	quad.size = Vector2(0.55, 0.07)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(0.75, 0.9, 1.0)
	m.emission_enabled = true
	m.emission = Color(0.6, 0.85, 1.0)
	m.emission_energy_multiplier = 3.5
	quad.material = m
	p.draw_pass_1 = quad
	var ppm := ParticleProcessMaterial.new()
	ppm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	ppm.emission_sphere_radius = radius * 1.05
	ppm.direction = Vector3(0, 0, 0)
	ppm.spread = 180.0
	ppm.initial_velocity_min = 0.4
	ppm.initial_velocity_max = 1.6
	ppm.gravity = Vector3.ZERO
	ppm.angle_min = 0.0
	ppm.angle_max = 360.0
	ppm.scale_min = 0.5
	ppm.scale_max = 1.4
	var grad := Gradient.new()
	grad.set_color(0, Color(0.9, 0.97, 1.0, 1.0))
	grad.set_color(1, Color(0.4, 0.7, 1.0, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	ppm.color_ramp = gt
	p.process_material = ppm
	return p


## Continuous sawdust/spark spray while the saw carves ground: hot debris
## kicked up and out, falling back down. Toggle via .emitting.
static func make_saw_sparks(radius: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Sparks"
	p.amount = 70
	p.lifetime = 0.5
	p.emitting = false
	p.local_coords = false
	var quad := QuadMesh.new()
	quad.size = Vector2(0.3, 0.09)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(1.0, 0.8, 0.35)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.7, 0.25)
	m.emission_energy_multiplier = 3.0
	quad.material = m
	p.draw_pass_1 = quad
	var ppm := ParticleProcessMaterial.new()
	ppm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ppm.emission_sphere_radius = radius * 0.9
	ppm.direction = Vector3(0, 1, 0)
	ppm.spread = 70.0
	ppm.initial_velocity_min = 4.0
	ppm.initial_velocity_max = 9.0
	ppm.gravity = Vector3(0, -16.0, 0)
	ppm.scale_min = 0.5
	ppm.scale_max = 1.2
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.95, 0.75, 1.0))
	grad.set_color(1, Color(1.0, 0.35, 0.05, 0.0))
	grad.add_point(0.4, Color(1.0, 0.7, 0.2, 0.8))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	ppm.color_ramp = gt
	p.process_material = ppm
	return p


## One-shot colored explosion burst (pickup destroyed by a ball): additive
## billboard sparks flying radially, then the node frees itself.
static func make_burst(color: Color, radius: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Burst"
	p.amount = 55
	p.lifetime = 0.6
	p.one_shot = true
	p.explosiveness = 1.0
	p.local_coords = false
	p.emitting = true
	var quad := QuadMesh.new()
	quad.size = Vector2(0.5, 0.5)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 3.0
	quad.material = m
	p.draw_pass_1 = quad
	var ppm := ParticleProcessMaterial.new()
	ppm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ppm.emission_sphere_radius = radius * 0.35
	ppm.direction = Vector3(0, 1, 0)
	ppm.spread = 180.0
	ppm.initial_velocity_min = 4.0
	ppm.initial_velocity_max = 9.0
	ppm.gravity = Vector3(0, -4.0, 0)
	ppm.scale_min = 0.5
	ppm.scale_max = 1.1
	var grad := Gradient.new()
	grad.set_color(0, Color(color.r, color.g, color.b, 1.0))
	grad.set_color(1, Color(color.r * 0.4, color.g * 0.4, color.b * 0.4, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	ppm.color_ramp = gt
	p.process_material = ppm
	p.finished.connect(p.queue_free)
	return p


## Contour outline via the classic toon inverted-hull hack: duplicate each
## mesh, cull FRONT faces, grow vertices along their normals. Reads as a crisp
## silhouette line hugging the actual shape (unlike the sphere shell below).
static func add_mesh_outline(holder: Node3D, color: Color, thickness := 0.09) -> void:
	var targets: Array = []
	var stack: Array = [[holder, 1.0]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node = e[0]
		var sc: float = e[1]
		if n is Node3D:
			var nsc: Vector3 = n.scale
			sc *= (abs(nsc.x) + abs(nsc.y) + abs(nsc.z)) / 3.0
		if n is MeshInstance3D and n.mesh:
			targets.append([n, sc])
		for c in n.get_children():
			stack.append([c, sc])
	for t in targets:
		var src: MeshInstance3D = t[0]
		var shell := MeshInstance3D.new()
		shell.name = "ContourOutline"
		shell.mesh = src.mesh
		var m := StandardMaterial3D.new()
		m.cull_mode = BaseMaterial3D.CULL_FRONT
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = color
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.7
		m.grow = true
		m.grow_amount = thickness / max(float(t[1]), 0.0001)
		shell.material_override = m
		src.add_child(shell)


## Glowing ground circle under a pickup (Mechanics-page concept): additive
## pulsing ring + faint fill, pinned to the platform top by the caller.
const RING_SHADER := "
shader_type spatial;
render_mode unshaded, blend_add, shadows_disabled, depth_draw_never;
uniform vec3 col : source_color = vec3(0.2, 0.6, 1.0);
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float ring = smoothstep(0.09, 0.015, abs(r - 0.60));
	float fill = smoothstep(0.72, 0.0, r) * 0.14;
	float pulse = 0.72 + 0.28 * sin(TIME * 2.4);
	float a = (ring + fill) * pulse * smoothstep(1.0, 0.85, r);
	ALBEDO = col * a * 2.4;
}
"

static func make_ground_ring(color: Color, size: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "GroundRing"
	var pm := PlaneMesh.new()
	pm.size = Vector2(size, size)
	mi.mesh = pm
	if _ring_sh == null:
		_ring_sh = Shader.new()
		_ring_sh.code = RING_SHADER
	var m := ShaderMaterial.new()
	m.shader = _ring_sh
	m.set_shader_parameter("col", Vector3(color.r, color.g, color.b))
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Bright inverted-hull outline shell (readability against the dark field).
static func add_outline(holder: Node3D, size: float, color: Color) -> void:
	var shell := MeshInstance3D.new()
	shell.name = "Outline"
	var sm := SphereMesh.new()
	sm.radius = size * 0.5 * 1.08
	sm.height = size * 1.08
	var m := StandardMaterial3D.new()
	m.cull_mode = BaseMaterial3D.CULL_FRONT
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 1.6
	sm.material = m
	shell.mesh = sm
	holder.add_child(shell)
