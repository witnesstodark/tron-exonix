# CLAUDE.md — how this game was built, and how to rebuild the setup

This file is for the next AI agent (and its human). TRON: EXONIX was built almost
entirely by Claude Code driving a toolchain of MCP servers and generation APIs,
with the human acting as game designer / art director. Read `README.md` for the
story and mechanics; read this to assemble the same pipeline yourself.

## The concept

One coding agent (Claude Code) owns the whole loop:

1. **Write** — all GDScript/shaders are written with plain file tools. The Godot
   editor is never used for authoring; the entire scene is built in code.
2. **Run & observe** — the agent launches the game and reads its debug output
   through Godot MCP, then fixes what it sees. Forensic `print()`s are the eyes.
3. **Generate assets** — textures, 3D models, SFX and music come from generation
   APIs (fal.ai, Tripo), driven by small Python scripts the agent writes into
   `assets/` (kept in the repo as working references — see `gen_*.py`).
4. **Human confirms taste** — materials are staged in Blender via Blender MCP;
   the human tunes roughness/metallic/emission by hand, the agent reads those
   exact values back and mirrors them into the game's shaders.
5. **Iterate** — the loop is *commit → play → feedback → adjust*. No design docs.
   Ship a working default, let the human react.

## Godot MCP

- Server: [`@coding-solo/godot-mcp`](https://github.com/Coding-Solo/godot-mcp) (node, runs via npx).
- Register (Claude Code, user scope):
  ```
  claude mcp add godot --scope user -e GODOT_PATH=C:\path\to\Godot_v4.7-stable_win64.exe -- cmd /c npx -y @coding-solo/godot-mcp
  ```
- What you actually use: `run_project` / `stop_project` / `get_debug_output`.
  It spawns its own Godot processes (does not attach to a running editor) — no
  screenshots, no input simulation. That's enough: a game like this is ~95% code.
- **Gotcha:** after adding a new `class_name` script, the global class cache is
  stale and the game breaks with "Could not find type X". Fix:
  `godot --headless --path game --import` once, then run again.

## Blender MCP

- Server: [`blender-mcp`](https://github.com/ahujasid/blender-mcp) (Python).
  Install as a tool: `uv tool install blender-mcp`, then register the resulting
  exe as a stdio MCP server (`.mcp.json` → `"command": ".../blender-mcp.exe"`).
- Blender side: install the companion addon from the same repo, enable it, and
  press **Connect to MCP** in the 3D-view sidebar (default port 9876).
- Used here for: building material preview planes (the human tunes Principled
  BSDF values on them), reading those values back via `execute_blender_code`,
  verification renders (`render_thumbnail_to_path`) before wiring anything into
  the game, and GLB export of human-made objects.
- **Gotchas:** operators need a real context — wrap in `temp_override(...)` and
  set actual selection (`obj.select_set(True)`) before `bpy.ops.export_scene.gltf`;
  export with `export_image_format='WEBP'` to keep files small.

## Generation APIs (all through fal.ai, one key)

Auth: `FALAI_KEY` in a gitignored `.env` at the repo root. Everything uses the
same queue pattern — `POST https://queue.fal.run/<model-id>` with a JSON body,
then poll the returned `status_url` / fetch `response_url`. Working reference
implementations live in `assets/gen_*.py` (retry helper included; the API drops
connections occasionally).

| Model | Used for |
|---|---|
| `fal-ai/nano-banana-pro` (+`/edit`) | concepts, icon, **flat albedo sources** for textures, emission maps (edit mode: "keep only the glowing lines on pure black") |
| `fal-ai/patina` | albedo image → PBR set (basecolor/normal/roughness/metalness/height). `image_url` is REQUIRED (no text mode); it can NOT make emission maps |
| `tripo3d/.../image-to-3d` | image → GLB models (the saw, pickups). Parse the model URL defensively — its response schema moves around |
| `fal-ai/elevenlabs/sound-effects/v2` | all SFX. `duration_seconds` 0.5–22 (0.4 fails validation!), `loop: true` for seamless loops |
| `fal-ai/stable-audio-25/text-to-audio` | music. Post-process with ffmpeg: `loudnorm`, then a crossfade loop-splice — `acrossfade(track, first_3s)` and drop the first 3s → seamless loop |

**The one texture lesson that matters:** if a texture source is meant for PATINA,
the prompt must demand a "FLAT UNLIT ALBEDO TEXTURE MAP — NO lighting, NO
reflections, NO gradients". A pretty glossy render bakes its highlights into the
basecolor and the material is ruined. Verify flatness numerically (channel std)
before spending on PBR conversion.

**Texture budgets (the camera never gets close):** floor tile sets 1024px max,
everything embedded in a GLB (balls, pickups, props) 512px max. Generation APIs
return 2-4K — always downscale before committing. When shrinking images inside
a GLB, the re-encoded bytes MUST match the declared `mimeType` (Blender-exported
GLBs use `image/webp` via EXT_texture_webp; feeding them PNG bytes makes Godot's
webp decoder fail with ERR_FILE_CORRUPT). `assets/textures/*.py` and the shrink
scripts are the working references.

## Project conventions (keep them)

- `game/scripts/qix_config.gd` — every tuning number lives here, never inline.
- Assets load at **runtime** from `assets/` (outside `res://`) — no import step;
  what's in the repo is what runs. Static session caches avoid re-decoding.
- `game/ARCHITECTURE.md` — code map + core rules; start there before editing.
- Debug: keys 1–7 jump to any sector; F1–F5 isolate render layers.
- Workflow: small commits after every confirmed change; the human plays the
  build between iterations and steers with feedback, not specs.

## Running

Godot 4.7 (standard build). Open `game/project.godot` and press F5, or point
`game/play.bat` at your Godot exe. No other dependencies at play time — the
Python scripts and API keys are only needed to regenerate assets.
