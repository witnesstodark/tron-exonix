class_name QixAudio
extends Node
## Runtime-loaded audio (../assets/audio/{sfx,music}/*.ogg — same no-import
## pipeline as textures/GLBs). One node, created by main. Three layers:
##   play(name)          non-positional one-shots (UI, stings, player events)
##   play_at(name, pos)  positional one-shots from a small 3D-player pool
##   attach_loop(...)    looping 3D emitter glued to a moving node (saw)
##   loop_start/stop     non-positional loops (the burn)
##   music(name)         two-player crossfade + duck for menus/boards
## Master knobs live in QixConfig (SFX_DB / MUSIC_DB); per-sound trim is VOL.

static var _cache := {}                # name -> AudioStream (survives reloads)

# per-sound trim, dB (0 = as normalized by the pipeline)
const VOL := {
	"bounce_soft": -9.0, "bounce_hard": -6.0, "smash": -4.0,
	"burn_start": -2.0, "burn_loop": -5.0, "saw_loop": -4.0,
	"death": 0.0, "respawn": -4.0, "cut_start": -8.0, "cut_loop": -14.0,
	"platform_rise": -8.0,
	"capture_small": -4.0, "capture_big": -2.0,
	"obstacle_hit": -6.0, "obstacle_break": -3.0,
	"pickup_good": -4.0, "pickup_bad": -4.0, "pickup_surprise": -4.0,
	"pickup_spawn": -12.0, "pickup_boom": -7.0, "pulse": -5.0,
	"ui_move": -12.0, "ui_select": -9.0, "board_show": -6.0,
	"level_clear": 0.0, "game_over": 0.0, "win_final": 0.0,
	"time_warn": 0.0,   # -6 buried it under the music
}
# min seconds between two plays of the same sound (anti-spam for bounces)
const GAP := {"bounce_soft": 0.10, "bounce_hard": 0.12, "smash": 0.15,
	"pickup_boom": 0.12, "obstacle_hit": 0.12, "pickup_spawn": 0.25}

var _last := {}                        # name -> last play time (s)
var _pool3d: Array = []                # AudioStreamPlayer3D one-shot pool
var _pool: Array = []                  # AudioStreamPlayer one-shot pool
var _loops := {}                       # name -> AudioStreamPlayer (flat loops)
var _mus_a: AudioStreamPlayer
var _mus_b: AudioStreamPlayer
var _mus_use_a := true
var _mus_cur := ""
var _duck := 0.0                       # extra dB on music (<= 0)
var _world3d: Array = []               # attached world loops (saw) — pausable


static func _dir() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../assets/audio")


static func stream(snd: String) -> AudioStream:
	if _cache.has(snd):
		return _cache[snd]
	var s: AudioStream = null
	for sub in ["sfx", "music"]:
		var p := _dir().path_join(sub).path_join(snd + ".ogg")
		if FileAccess.file_exists(p):
			s = AudioStreamOggVorbis.load_from_file(p)
			break
	if s == null:
		push_warning("QixAudio: missing " + snd + ".ogg")
	_cache[snd] = s
	return s


func _ready() -> void:
	for i in 12:
		var p := AudioStreamPlayer3D.new()
		# the camera listens from ~90 units out — keep attenuation gentle so
		# positional sounds pan but never vanish
		p.unit_size = 45.0
		p.max_distance = 400.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_pool3d.append(p)
	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_mus_a = AudioStreamPlayer.new()
	_mus_b = AudioStreamPlayer.new()
	add_child(_mus_a)
	add_child(_mus_b)


func _gate(snd: String) -> bool:
	var now := Time.get_ticks_msec() * 0.001
	if now - float(_last.get(snd, -99.0)) < float(GAP.get(snd, 0.04)):
		return false
	_last[snd] = now
	return true


func _db(snd: String, off: float) -> float:
	return QixConfig.SFX_DB + linear_to_db(maxf(QixConfig.SFX_VOL, 0.0005)) \
			+ float(VOL.get(snd, 0.0)) + off


func _music_db() -> float:
	return QixConfig.MUSIC_DB + linear_to_db(maxf(QixConfig.MUSIC_VOL, 0.0005)) + _duck


## Options menu moved the music slider — retune the live player instantly.
func music_volume_changed() -> void:
	var on: AudioStreamPlayer = _mus_b if _mus_use_a else _mus_a
	if on.playing:
		on.volume_db = _music_db()


func play(snd: String, off := 0.0, jitter := 0.05) -> void:
	var s := QixAudio.stream(snd)
	if s == null or not _gate(snd):
		return
	for p in _pool:
		if not p.playing:
			p.stream = s
			p.volume_db = _db(snd, off)
			p.pitch_scale = randf_range(1.0 - jitter, 1.0 + jitter)
			p.play()
			return


func play_at(snd: String, pos: Vector3, off := 0.0, jitter := 0.07) -> void:
	var s := QixAudio.stream(snd)
	if s == null or not _gate(snd):
		return
	for p in _pool3d:
		if not p.playing:
			p.position = pos
			p.stream = s
			p.volume_db = _db(snd, off)
			p.pitch_scale = randf_range(1.0 - jitter, 1.0 + jitter)
			p.play()
			return


func loop_start(snd: String, off := 0.0) -> void:
	if _loops.has(snd):
		return
	var s := QixAudio.stream(snd)
	if s == null:
		return
	if s is AudioStreamOggVorbis:
		s.loop = true
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.volume_db = -60.0
	add_child(p)
	p.play()
	var tw := create_tween()
	tw.tween_property(p, "volume_db", _db(snd, off), 0.25)
	_loops[snd] = p


func loop_stop(snd: String) -> void:
	if not _loops.has(snd):
		return
	var p: AudioStreamPlayer = _loops[snd]
	_loops.erase(snd)
	var tw := create_tween()
	tw.tween_property(p, "volume_db", -60.0, 0.3)
	tw.tween_callback(p.queue_free)


## Looping 3D emitter riding a node (the saw). Dies with its parent.
func attach_loop(snd: String, parent: Node3D, off := 0.0) -> void:
	var s := QixAudio.stream(snd)
	if s == null:
		return
	if s is AudioStreamOggVorbis:
		s.loop = true
	var p := AudioStreamPlayer3D.new()
	p.stream = s
	p.unit_size = 40.0
	p.max_distance = 400.0
	p.volume_db = _db(snd, off)
	p.pitch_scale = randf_range(0.96, 1.04)
	parent.add_child(p)
	p.play()
	_world3d.append(p)


## True pause: freeze world sounds (loops, positional), keep UI blips and music.
func set_paused(paused: bool) -> void:
	for pl in _pool3d:
		pl.stream_paused = paused
	for k in _loops:
		_loops[k].stream_paused = paused
	for pl in _world3d:
		if is_instance_valid(pl):
			pl.stream_paused = paused


func music(snd: String) -> void:
	if snd == _mus_cur:
		return
	_mus_cur = snd
	var s := QixAudio.stream(snd)
	if s == null:
		return
	if s is AudioStreamOggVorbis:
		s.loop = true
	var on: AudioStreamPlayer = _mus_a if _mus_use_a else _mus_b
	var offp: AudioStreamPlayer = _mus_b if _mus_use_a else _mus_a
	_mus_use_a = not _mus_use_a
	on.stream = s
	on.volume_db = -50.0
	on.play()
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(on, "volume_db", _music_db(), 1.2)
	if offp.playing:
		tw.tween_property(offp, "volume_db", -50.0, 1.2)
		tw.chain().tween_callback(offp.stop)


## Sink the music under overlays (board / game over); 0 restores.
func music_duck(db: float) -> void:
	_duck = db
	var on: AudioStreamPlayer = _mus_b if _mus_use_a else _mus_a
	if on.playing:
		var tw := create_tween()
		tw.tween_property(on, "volume_db", _music_db(), 0.6)
