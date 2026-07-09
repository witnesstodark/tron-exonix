class_name QixConfig
## All game-design tuning knobs in ONE place. Change numbers here, not in logic.

# grid size is PER LEVEL now (LEVELS[n].grid) — main sets these at scene start
static var GRID_W := 60
static var GRID_H := 60
const BORDER := 2                  # pre-claimed rim thickness (indestructible)
static var WIN_PERCENT := 85.0     # per level — see calc_win_percent()
const LEVEL_TIME := 75.0           # seconds per level (60 was too tight)


## Stefan's coverage math: base 85%, minus 1.5% per soft / 2% per hard /
## 2.5% per evil ball / 3% per saw; never below the 69% floor.
static func calc_win_percent(cfg: Dictionary) -> float:
	if cfg.has("threshold"):       # level-designed explicit requirement wins
		return float(cfg.threshold)
	var need := 85.0
	for t in cfg.balls:
		var s := String(t)
		if s.begins_with("soft"):
			need -= 1.5
		elif s.begins_with("hard"):
			need -= 2.0
		elif s.begins_with("evil"):
			need -= 2.5
	need -= 3.0 * float(cfg.get("saws", 0))
	return maxf(need, 69.0)
const MOVE_INTERVAL := 0.045       # player: seconds per cell
const START_LIVES := 3

# --- visuals
const TILE_REPEAT := 16.0          # floor texture repeats every N world units
const EMISSION_PULSE := 0.12       # platform glow dip (peak = tuned level)
const SEA_PULSE_DEPTH := 0.45      # floor glow dips to 55% and back
const SEA_PULSE_SPEED := 1.2       # rad/s (~5.2s cycle)
const PLATFORM_HEIGHT := 1.2
const PLATFORM_Y := 0.48           # instance origin so the slab sits on the sea
const PLAYER_HOVER := 1.45
const HERO_SIZE := 4.5             # +10% per Stefan (2026-07-08)
const HERO_YAW_DEG := 90.0         # GLB forward-axis fix
const BALL_DIAMETER := 1.95
const BALL_ROLL_SLOWDOWN := 4.3    # visual roll divisor (another -30%)
const MINE_SIZE := 4.0             # 2.5x bigger per Stefan
const MINE_Y := 1.95

# --- backdrop: procedural infinite animated grid
const BG_CELL := 4.0               # world units per grid cell
const BG_BASE_GLOW := 0.32
const BG_PULSE_GLOW := 1.6         # "data bits" running along lines
const BG_FADE_START := 55.0
const BG_FADE_END := 200.0

# --- camera (proportional to field size)
const CAM_FOV := 50.0
const CAM_GROWTH := 0.55           # camera size grows at 55% of grid growth past 60
const CAM_HEIGHT_K := 0.70         # * GRID_H — closer to the action (Stefan)
const CAM_DIST_K := 1.26           # * GRID_H behind the field
const CAM_LOOK_K := 0.55           # look target z (bigger = bottom edge + player visible with margin)
const CAM_FOLLOW_POS := 0.40       # stronger drift with the player
const CAM_FOLLOW_LOOK := 0.50
const CAM_LERP := 0.08

# --- enemies
const BALL_TYPES := {
	"soft": {"speed_mul": 1.0,  "crash": false, "homing": false, "size_mul": 1.0, "outline": Color(0.5, 0.9, 1.0)},
	# soft speed variants (Stefan 2026-07-09): same ball, the OUTLINE tells the
	# speed — warm pastel tints, deliberately softer than the hard/evil outlines
	"soft_orange": {"speed_mul": 1.15, "crash": false, "homing": false, "size_mul": 1.0,
		"glb": "ball_soft", "outline": Color(1.0, 0.52, 0.05)},
	"soft_red": {"speed_mul": 1.30, "crash": false, "homing": false, "size_mul": 1.0,
		"glb": "ball_soft", "outline": Color(1.0, 0.24, 0.15)},
	"hard": {"speed_mul": 0.95, "crash": true,  "homing": false, "size_mul": 1.3, "outline": Color(1.0, 0.6, 0.1)},
	# "hard medium" (Stefan L3): +50% over hard's own pace, outline goes reddish
	"hard_medium": {"speed_mul": 1.425, "crash": true, "homing": false, "size_mul": 1.3,
		"glb": "ball_hard", "outline": Color(1.0, 0.33, 0.08)},
	"evil": {"speed_mul": 0.80, "crash": true,  "homing": true,  "size_mul": 1.0, "outline": Color(1.0, 0.15, 0.2)},
}
const EVIL_TURN_RATE := 0.9        # rad/s — homing "rotating with delay"
const CRASH_COOLDOWN := 0.0        # 0 = smash on EVERY hit (borders excepted)
const MINE_SPEED := 8.0            # cells/s on claimed ground
const HUNTER_SPEED := 2.4          # cells/s — the auto-target mine drifts slowly
const MINE_UNLOCK_PERCENT := 0.0   # mines roam the border from the very start
const KILL_RADIUS := 0.85

# --- the SAW: slow straight-line cutter (spins, carves through everything)
const SAW_SPEED := 4.5             # cells/s — deliberately slow
const SAW_SIZE := 4.0              # visual size (-20%: match the cut width)
const SAW_RADIUS := 1.9            # collision/kill radius
const SAW_Y := 1.15                # blade slices just above the platform top
const SAW_SPIN := 7.0              # rad/s visual spin
const SAW_TURN_MIN := 2.5          # seconds between random turns
const SAW_TURN_MAX := 6.5

# --- trail burn (ball hits the line)
const BURN_SPEED_MUL := 1.5        # x player speed (2.0 was no-fun fast)

# --- blackout debuff: BOOM -> pitch dark, then the light crawls back
const BLACKOUT_DARK := 1.5         # seconds of complete darkness
const BLACKOUT_RESTORE := 3.0      # seconds of gradual light recovery

# --- ultimates: jackpot gate INSIDE the surprise box (never a pool member)
const ULT_CHANCE := 0.10           # 10% of surprise rolls upgrade to the ultimate

# --- levels: texture set, ball loadout, base speed, Stefan's emission, mines
# 5 levels; growing arenas; AirXonix-style gentle enemy ramp (start small,
# +1 ball most levels, evils only from mid-game)
const LEVELS := [
	# 7 levels, slow ramp. Themed middle acts: L3 soft swarm, L4 hard squad,
	# L5 evil hunt. ALL levels are map-driven now (gloss pass 2026-07-09):
	# roughness/metalness live in the texture maps = what the catalog shows.
	# L1 (Stefan's design session 2026-07-09): simple shapes — arcs over plates
	# (CAPTURED 3 + UNCAPTURED 4), 4 plain softs at base speed, explicit 92%.
	# Map-driven (no flat overrides): renders what the Blender catalog shows.
	{"tex": "claim_v4_3", "sea": "unclaimed_D", "grid": 60,
		"balls": ["soft", "soft", "soft", "soft"], "threshold": 92.0,
		"ob_pool": ["sp_bloom"],
		"speed": 14.0, "mines": 2, "obstacles": 1, "saws": 0,
		"emission": 10.0},
	# L2 (Stefan): CORRUPTED 5 over the same plates — first taste of orange
	# softs (+15%) and one hard; 90% required. No flat overrides: this set runs
	# on its maps, exactly as it looks in the Blender catalog.
	{"tex": "claim_c5", "sea": "unclaimed_D", "grid": 64,
		"balls": ["soft", "soft", "soft_orange", "soft_orange", "hard"],
		"ob_pool": ["sp_bloom", "sp_storm"],
		"threshold": 90.0, "speed": 14.5, "mines": 2, "obstacles": 1, "saws": 0,
		"emission": 10.0},
	# L3 (Stefan): the hard squad — 3 hard low + 1 hard_medium (+50%, reddish
	# outline), 3 mines, 2 obstacles, NO saw. CAPTURED 1 over UNCAPTURED 1.
	{"tex": "claim_v4_1", "sea": "unclaimed_B", "sea_tile": 12.0, "grid": 68,
		"balls": ["hard", "hard", "hard", "hard_medium"], "threshold": 85.0,
		"ob_pool": ["sp_bloom", "sp_storm"],
		"speed": 15.5, "mines": 3, "obstacles": 2, "saws": 0, "islands": 0.08,
		"emission": 10.0},
	# L4 (Stefan): the fast squad — 3 medium softs (+15%) + 3 medium hards
	# (+50%), 3 mines, 2 obstacles, NO saw (the saw debuts on L5).
	# CORRUPTED 1 over UNCAPTURED 5.
	{"tex": "claim_c1", "sea": "unclaimed_E", "sea_tile": 12.0, "grid": 72,
		"balls": ["soft_orange", "soft_orange", "soft_orange",
				"hard_medium", "hard_medium", "hard_medium"], "threshold": 83.0,
		"ob_pool": ["sp_bloom", "sp_storm"],
		"speed": 15.0, "mines": 3, "obstacles": 2, "saws": 0, "islands": 0.08,
		"emission": 10.0},
	# L5 (Stefan): the saws debut — 2 saws, 3 mines + 1 HUNTER mine (redder,
	# auto-target, surface-blind, kamikazes into obstacles), 2 orange + 2 red
	# softs. CORRUPTED 3 over UNCAPTURED 3.
	{"tex": "claim_c3", "sea": "unclaimed_C", "grid": 78,
		"balls": ["soft_orange", "soft_orange", "soft_red", "soft_red"],
		"ob_pool": ["sp_spire", "sp_storm"],
		"speed": 15.5, "mines": 3, "hunters": 1, "obstacles": 2, "saws": 2, "islands": 0.09,
		"emission": 10.0},
	# L6 (Stefan): the hunt — 2 HUNTER mines (no normal ones), 3 saws,
	# 3 hard_medium; CORRUPTED 4 over UNCAPTURED 1; 80% required, 2 obstacles.
	{"tex": "claim_c4", "sea": "unclaimed_B", "sea_tile": 12.0, "grid": 84,
		"balls": ["hard_medium", "hard_medium", "hard_medium", "hard_medium"], "threshold": 80.0,
		"ob_pool": ["sp_spire", "sp_storm"],
		"speed": 16.5, "mines": 0, "hunters": 2, "obstacles": 2, "saws": 3, "islands": 0.10,
		"emission": 10.0},
	# L7 (Stefan): evil endgame — 3 evils + 3 soft_red (+30%), 1 hunter +
	# 2 normal mines, 2 obstacles, NO saws; 89% required.
	{"tex": "claim_c2", "sea": "unclaimed_C", "grid": 90,
		"balls": ["evil", "evil", "evil", "soft_red", "soft_red", "soft_red"],
		"threshold": 89.0, "ob_pool": ["sp_spire", "sp_storm"],
		"speed": 17.5, "mines": 2, "hunters": 1, "obstacles": 2, "saws": 0, "islands": 0.10,
		"emission": 10.0},
	# L8-L10: placeholders — copies of L7 with the endgame obstacle pool
	# (rift/firewall/spire); Stefan designs them properly in a later session
	# L8 (Stefan): the red swarm — 10 soft_red (+30%), 4 normal mines,
	# 2 obstacles, no saws; 82%. CAPTURED 2 over UNCAPTURED 4.
	{"tex": "claim_v4_2", "sea": "unclaimed_D", "grid": 90,
		"balls": ["soft_red", "soft_red", "soft_red", "soft_red", "soft_red",
				"soft_red", "soft_red", "soft_red", "soft_red", "soft_red"],
		"threshold": 82.0, "ob_pool": ["sp_rift", "sp_spire"],
		"speed": 17.5, "mines": 4, "obstacles": 2, "saws": 0, "islands": 0.10,
		"emission": 10.0},
	# L9 (Stefan): the heavy squad — 6 hard_medium (+50%, red) + 1 evil,
	# 2 HUNTER mines only, NO obstacles, no saws; 82%. CORRUPTED 4 over
	# UNCAPTURED 2 (sea runs QUIET and IGNITES under rolling balls).
	{"tex": "claim_c4", "sea": "unclaimed_A", "sea_emission": 0.08, "sea_ball_glow": 34.0, "grid": 90,
		"balls": ["hard_medium", "hard_medium", "hard_medium", "hard_medium",
				"hard_medium", "hard_medium", "evil"],
		"threshold": 82.0, "ob_pool": ["sp_rift", "sp_spire"],
		"speed": 17.5, "mines": 0, "hunters": 2, "obstacles": 0, "saws": 0, "islands": 0.10,
		"emission": 10.0},
	# L10 (Stefan, the hardest): 2 hard + 3 hard_medium + 2 evil, 2 saws,
	# 2 HUNTER mines, 2 obstacles; 82%. CORRUPTED 3 over UNCAPTURED 2
	# (same quiet-then-ignite sea).
	{"tex": "claim_c3", "sea": "unclaimed_A", "sea_emission": 0.08, "sea_ball_glow": 34.0, "grid": 90,
		"balls": ["hard", "hard", "hard_medium", "hard_medium", "hard_medium", "evil", "evil"],
		"threshold": 82.0, "ob_pool": ["sp_rift", "sp_spire"],
		"speed": 17.5, "mines": 0, "hunters": 2, "obstacles": 2, "saws": 2, "islands": 0.10,
		"emission": 10.0},
]


# --- SP obstacles (rise from the ground; destroyed after 3 ball hits)
const OB_SIZE := 10.4              # HUGE — proper natural monuments (2x per Stefan)
const OB_RADIUS := 4.2             # tucked INSIDE the visible mesh (shapes taper)
const OB_HP := 3

const SEA_EMISSION := 0.22         # quiet base — the veins flame near balls instead
const SEA_BALL_GLOW := 20.0        # vein flare under rolling balls (round 2: more)
const SEA_BALL_RADIUS := 5.0       # cells: flare radius around each ball
const SEA_NORMAL_DEPTH := 1.6      # sea relief punched up — catches the reflections
const LAND_PLAYER_GLOW := 7.0      # platform seams flare around the player craft
const LAND_PLAYER_RADIUS := 4.5

# --- environment reflections: HDRI night panorama (reflection/ambient only —
# the visible background stays the black void). Files live in assets/sky/:
# night_city (Potsdamer Platz lights), night_stars (Satara), night_dark
# (Moonless Golf). "" = old procedural sky. All Poly Haven CC0.
const SKY_PANORAMA := "tron_night"   # custom cold generated panorama
const SKY_ENERGY := 1.6
# slow sky drift: the reflection cubemap yaws + tilts gently, so the glints
# CRAWL across the glossy floors — the motion is what sells the polish (Stefan)
const SKY_DRIFT_YAW := 0.035       # rad/s continuous rotation
const SKY_TILT := 0.05             # rad amplitude of the back-and-forth tilt
const SKY_TILT_SPEED := 0.14       # rad/s of the tilt oscillation

# --- audio (master knobs; per-sound trim lives in qix_audio.gd VOL)
const SFX_DB := 0.0                # anchor at 100%
const MUSIC_DB := -8.0             # anchor at 100%
static var SFX_VOL := 0.5          # user setting 0..1 (options menu; 50% default)
static var MUSIC_VOL := 0.5

# --- captured platform growth
const RISE_TIME := 0.35            # seconds for a claimed tile to grow out
const RISE_DEPTH := 1.7            # how deep it starts under the sea

# --- score
const SCORE_BIG_CUT_1 := 5.0       # % of field in one cut -> x2
const SCORE_BIG_CUT_2 := 12.0      # -> x4
