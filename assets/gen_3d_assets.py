"""
QIX — 15 game assets: enemies (4) + pickups (11).
Stage A: nano-banana-pro/edit isolates each object (remove halo ring / floor glow /
labels / reticle overlays; object alone on plain background) -> assets/3d/src/
Stage B: fal.ai tripo3d/h3.1/image-to-3d (Stefan's pick), HD quality
(texture+geometry "detailed"), PBR, per-asset face budget -> assets/3d/<name>.glb
Both stages run per-asset as a pipeline (no barrier): as soon as an image is
isolated its Tripo job is submitted.
"""
import base64, io, os, sys, time, threading
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")
FAL_H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}

MECH = (ROOT / "workspace/2026-07-06_qix-territory-reveal/mech_v1").resolve()
OUT = Path(__file__).parent / "3d"
SRC = OUT / "src"
OUT.mkdir(exist_ok=True)
SRC.mkdir(exist_ok=True)

ISOLATE = ("Show ONLY {} completely alone, centered on a plain flat dark charcoal background. "
           "Remove the glowing ring or halo beneath it, any floor glow, reflections, shadows, labels, text "
           "and 2D overlay effects. Keep the object's own design, colors and emissive glow on the object "
           "itself unchanged. Whole object in frame with margin, nothing cropped.")

ASSETS = [
    # name, source file, what to isolate, face budget
    ("ball_soft",  "balls_lineup.webp", "the LEFT sphere (the smooth glossy calm cyan-blue SOFT sphere)", 5000),
    ("ball_hard",  "balls_lineup.webp", "the MIDDLE sphere (the armored orange-amber plated HARD sphere)", 15000),
    ("ball_evil",  "balls_lineup.webp", "the RIGHT sphere (the dark crimson spiked EVIL sphere with the single red eye) — also remove the red targeting reticle circles around it", 25000),
    ("mine",       "enemy_mine.webp",   "the black hover-mine disc with red spikes and red scanner eye — remove the thin red patrol ring around it", 15000),
    ("bonus_speed",     "bonus_speed.webp",     "the cyan double-chevron speed token", 5000),
    ("bonus_freeze",    "bonus_freeze.webp",    "the cyan snowflake/ice-shard token", 5000),
    ("bonus_time",      "bonus_time.webp",      "the glowing hourglass token", 5000),
    ("bonus_score",     "bonus_score.webp",     "the glowing star coin token", 5000),
    ("bonus_life",      "bonus_life.webp",      "the glossy glowing heart token", 5000),
    ("debuff_blackout", "debuff_blackout.webp", "the cracked dark lightbulb", 5000),
    ("debuff_meteor",   "debuff_meteor.webp",   "the burning jagged meteor rock", 5000),
    ("debuff_enemyfast","debuff_enemyfast.webp","the red enemy sphere with speed streaks", 5000),
    ("debuff_selfslow", "debuff_selfslow.webp", "the red tar blob with the weight", 5000),
    ("debuff_addball",  "debuff_addball.webp",  "the red spawn-portal token with the small ball", 5000),
    ("surprise",        "surprise.webp",        "the mystery cube with the question mark", 5000),
]

lock = threading.Lock()
def log(msg):
    with lock:
        print(msg, flush=True)


def data_uri(b: bytes, mime) -> str:
    return f"data:{mime};base64," + base64.b64encode(b).decode()


def fal_edit(prompt: str, img_bytes: bytes) -> bytes:
    r = requests.post("https://queue.fal.run/fal-ai/nano-banana-pro/edit", headers=FAL_H,
                      json={"prompt": prompt, "image_urls": [data_uri(img_bytes, "image/webp")], "num_images": 1})
    r.raise_for_status()
    j = r.json()
    deadline = time.time() + 420
    while time.time() < deadline:
        time.sleep(5)
        s = requests.get(j["status_url"], headers=FAL_H).json()
        if s.get("status") == "COMPLETED":
            res = requests.get(j["response_url"], headers=FAL_H).json()
            return requests.get(res["images"][0]["url"]).content
        if s.get("status") in ("FAILED", "ERROR"):
            raise RuntimeError(str(s))
    raise TimeoutError("fal edit")


def tripo_generate(png_path: Path, faces: int) -> dict:
    payload = {
        "image_url": data_uri(png_path.read_bytes(), "image/png"),
        "texture": True,
        "pbr": True,
        "texture_quality": "detailed",
        "geometry_quality": "detailed",
        "face_limit": faces,
    }
    r = requests.post("https://queue.fal.run/tripo3d/h3.1/image-to-3d", headers=FAL_H, json=payload)
    r.raise_for_status()
    return r.json()   # {status_url, response_url, request_id}


def tripo_wait_fetch(job: dict, dst: Path) -> None:
    deadline = time.time() + 1500
    while time.time() < deadline:
        time.sleep(8)
        s = requests.get(job["status_url"], headers=FAL_H).json()
        st = s.get("status")
        if st == "COMPLETED":
            res = requests.get(job["response_url"], headers=FAL_H).json()
            url = None
            mesh = res.get("model_mesh") or {}
            url = mesh.get("url")
            if not url:
                urls = res.get("model_urls") or {}
                url = urls.get("glb") or urls.get("pbr_model") or urls.get("base_model")
            if not url:
                raise RuntimeError(f"completed but no mesh url: {list(res.keys())}")
            data = requests.get(url, timeout=600).content
            dst.write_bytes(data)
            return
        if st in ("FAILED", "ERROR"):
            raise RuntimeError(f"tripo failed: {s}")
    raise TimeoutError(str(job.get("request_id")))


def process(name, src_file, desc, faces):
    try:
        glb = OUT / f"{name}.glb"
        if glb.exists():
            log(f"  = {name}: glb exists, skip")
            return
        iso_png = SRC / f"{name}.png"
        if not iso_png.exists():
            raw = (MECH / src_file).read_bytes()
            edited = fal_edit(ISOLATE.format(desc), raw)
            img = Image.open(io.BytesIO(edited)).convert("RGB")
            img.save(iso_png, "PNG")
            log(f"  A {name}: isolated ({iso_png.stat().st_size//1024} KB)")
        job = tripo_generate(iso_png, faces)
        log(f"  B {name}: tripo h3.1 submitted ({faces} tris) id={job.get('request_id')}")
        tripo_wait_fetch(job, glb)
        log(f"  ✓ {name}.glb ({glb.stat().st_size//1024} KB)")
    except Exception as e:
        log(f"  ✗ {name}: {e}")


def main():
    print(f"{len(ASSETS)} assets -> {OUT}")
    threads = []
    for spec in ASSETS:
        t = threading.Thread(target=process, args=spec)
        t.start()
        threads.append(t)
        time.sleep(2.5)  # stagger submissions
    for t in threads:
        t.join()
    done = sorted(p.name for p in OUT.glob("*.glb"))
    print(f"finished: {len(done)}/{len(ASSETS)} glbs")
    for d in done:
        print("  ", d)


if __name__ == "__main__":
    main()
