# TRON: EXONIX — Game Architecture

Godot 4.7, Forward+. AirXonix-style territory capture. Written to be picked up
cold by any agent — read this file, then `scripts/qix_config.gd`.

## File map

```
game/
├── project.godot            main scene = main3d.tscn, Forward+
├── main3d.tscn              one Node3D root + scripts/main.gd (everything built in code)
├── main.tscn / main.gd      LEGACY 2D prototype (reference only, do not extend)
├── ARCHITECTURE.md          this file
└── scripts/
    ├── qix_config.gd        ALL tuning knobs (class_name QixConfig). Change numbers HERE.
    ├── qix_board.gd         pure grid state: SEA/LAND/TRAIL, flood-fill capture, smash bites
    ├── qix_enemies.gd       balls (soft/hard/evil) + mines: movement, homing, hit tests
    ├── qix_burn.gd          trail-burn: ball hits the line -> two fronts eat it at 2x player speed
    ├── qix_assets.gd        static loaders: PATINA floor shader-materials, GLB enemies/hero
    ├── qix_audio.gd         runtime OGG audio: SFX pools, positional loops, music crossfade
    └── main.gd              orchestrator: scene build, input, level flow, rendering, HUD
```

## Core rules (locked with Stefan — see workspace Mechanics tab)

- Per-level grid 60×60 → 90×90, 1 cell = 1 world unit. Outer 2-cell rim pre-claimed,
  indestructible.
- Player moves on claimed land; stepping into the sea draws a 1-unit trail; returning
  to land captures every sea region that contains no ball/saw (flood-fill from enemies).
- Dynamic win threshold: `QixConfig.calc_win_percent` (base 85, −1.5/soft −2/hard
  −2.5/evil −3/saw, floor 69). 3 lives, 75s per level. 7 levels (`QixConfig.LEVELS`).
- Balls: **soft** (bounce only) / **hard** (smashes platform bites, 3s cooldown) /
  **evil** (laggy homing at 0.8x speed, also smashes). Ball hits PLAYER while
  cutting -> death, respawn at bottom start.
- Ball hits the TRAIL -> not death: the line burns from the hit point in both
  directions at 2x player speed (`qix_burn.gd`). Reach land first -> surviving
  line becomes platform (capture as usual; a burned gap breaks the enclosure).
  Burn reaches the player -> death.
- Mines: spawn at the top border (`mines` per level), patrol land only, contact -> death.
- Saws (L3+): slow straight-line cutters carving through captured ground; count as
  balls for capture flood-fill. Obstacles: SP monuments, 3 ball hits destroy, touch = death.

## Rendering / assets

- Floors: ShaderMaterial (see `qix_assets.gd`) — world-XZ UVs tile the PATINA sets
  (`../assets/textures/<set>/{basecolor,normal,roughness,metalness,emission}.webp`)
  continuously across cells. Emission energies are Stefan-tuned (in LEVELS + SEA_EMISSION);
  glow animates DOWN from the tuned peak, never above it.
- Land cells + trail: MultiMesh, rebuilt only when board.land_dirty / trail_dirty.
- Enemies/hero: GLBs loaded at runtime from `../assets/3d/` (no import pipeline),
  normalized to target size in `QixAssets.make_enemy_node`; emissive sphere fallback.
- Environment: procedural dark sky (ambient + reflections) + SSR + glow; perspective
  camera from the south with soft player-follow (all knobs in QixConfig).

## Conventions for future agents

- Game rules live in the qix_* modules; main.gd only orchestrates. Keep it that way.
- New tuning numbers go in QixConfig, never inline.
- Textures/GLBs stay OUTSIDE the project in ../assets/ (single source of truth).
  Blender files live in the assets root, fully PACKED (self-contained):
  assets/assets.blend (model+material review) and assets/textures.blend (the
  labeled floor-texture catalog for per-level picking).
- Run via godot MCP (`run_project`) or game/play.bat; check debug output after changes.
- Next planned: pickups (bonus/debuff/surprise — see Mechanics tab), scatter props
  on claimed ground, L3 unstable-platform collapse, backdrop environment image.
