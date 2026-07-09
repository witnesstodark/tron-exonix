"""
PBR data-map regeneration — LOSSLESS + glossy metallic Tron (Stefan 2026-07-09).
Why: patina ships maps as brutally lossy webp (normal.webp ~21KB/1024^2); the
quantization patches are invisible as color but become faceted "big pixels"
once the Normal Map node reads them as surface angles. And patina inferred
matte dielectric (metalness = pure black) from our dark flat sources.

For every set: patina runs on the CURRENT basecolor.webp (pixel-aligned with
the approved basecolor + emission, so nothing Stefan approved changes), asking
for PNG output. Post-processing:
  normal, height -> saved as LOSSLESS webp (no more quantization facets)
  roughness      -> percentile-remapped into the glossy wet-glass range
  metalness      -> lifted to polished dark metal (Tron floors reflect)
basecolor.webp and emission.webp are NOT touched.
CLI arg = name filter for single-set reruns.
"""
import base64, io, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
import requests
from dotenv import load_dotenv
from PIL import Image

ROOT = Path(__file__).resolve().parents[4]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
PATINA = "https://queue.fal.run/fal-ai/patina"
OUT = Path(__file__).parent

SETS = ["claim_v4_1", "claim_v4_2", "claim_v4_3", "claim_v4_4", "claim_v4_5",
        "claim_c1", "claim_c2", "claim_c3", "claim_c4", "claim_c5",
        "unclaimed_A", "unclaimed_B", "unclaimed_C", "unclaimed_D", "unclaimed_E"]

# the look Stefan asked for: glossy reflective Tron, not matte
STYLE_PROMPT = ("polished reflective dark metal floor, glossy wet tron surface, "
                "smooth mirror-like finish, high gloss, metallic")
# Stefan's HAND-TUNED flat values (Blender session 2026-07-09, catalog file):
# captured = claim_v4_3 numbers, uncaptured = unclaimed_D numbers. Maps are
# written FLAT at these values — patina's rough/metal guesses are discarded.
def rough_base(set_name: str) -> float:
    return 0.18 if set_name.startswith("claim") else 0.13
def metal_base(set_name: str) -> float:
    return 0.60 if set_name.startswith("claim") else 0.88


def data_uri(b: bytes, mime: str) -> str:
    return f"data:{mime};base64," + base64.b64encode(b).decode()


def fetch(url: str, tries: int = 4) -> bytes:
    for i in range(tries):
        try:
            return requests.get(url, timeout=300).content
        except Exception as e:
            if i == tries - 1:
                raise
            print(f"  retry {i + 1} after: {type(e).__name__}")
            time.sleep(4 * (i + 1))


def submit(name: str):
    body = {
        "image_url": data_uri((OUT / name / "basecolor.webp").read_bytes(), "image/webp"),
        "maps": ["normal", "roughness", "metalness", "height"],
        "output_format": "png",
        "prompt": STYLE_PROMPT,
    }
    r = requests.post(PATINA, headers=H, json=body, timeout=120)
    if r.status_code >= 400:            # schema may not take a prompt — retry bare
        body.pop("prompt")
        r = requests.post(PATINA, headers=H, json=body, timeout=120)
    r.raise_for_status()
    j = r.json()
    return {"name": name, "s": j["status_url"], "r": j["response_url"]}


def save_lossless(img: Image.Image, path: Path):
    if max(img.size) > 1024:
        img = img.resize((1024, 1024), Image.LANCZOS)
    img.save(path, "WEBP", lossless=True, quality=100)


def handle(name: str, res: dict):
    mat_dir = OUT / name
    got = []
    for m in res.get("images", []):
        mt = m.get("map_type")
        if mt not in ("normal", "roughness", "metalness", "height"):
            continue
        img = Image.open(io.BytesIO(fetch(m["url"])))
        if mt == "roughness":
            a = np.full((img.size[1], img.size[0]), rough_base(name), dtype=np.float32)
            img = Image.fromarray((a * 255).astype(np.uint8))
        elif mt == "metalness":
            a = np.full((img.size[1], img.size[0]), metal_base(name), dtype=np.float32)
            img = Image.fromarray((a * 255).astype(np.uint8))
        elif mt == "normal":
            img = img.convert("RGB")
        else:
            img = img.convert("L")
        save_lossless(img, mat_dir / f"{mt}.webp")
        got.append(f"{mt}:{(mat_dir / (mt + '.webp')).stat().st_size // 1024}KB")
    if len(got) < 4:
        raise RuntimeError(f"only got {got}")
    print(f"  ok {name}: {' '.join(got)}")


only = sys.argv[1] if len(sys.argv) > 1 else ""
todo = [s for s in SETS if only in s and (OUT / s / "basecolor.webp").exists()]
print(f"sets: {todo}")

jobs = [submit(n) for n in todo]
print(f"patina submitted: {len(jobs)}")
done = {}
end = time.time() + 1800
while len(done) < len(jobs) and time.time() < end:
    time.sleep(8)
    for j in jobs:
        if j["name"] in done:
            continue
        st = requests.get(j["s"], headers=H).json()
        if st.get("status") == "COMPLETED":
            res = requests.get(j["r"], headers=H).json()
            try:
                handle(j["name"], res)
                done[j["name"]] = True
            except Exception as e:
                done[j["name"]] = False
                print(f"  handler FAIL {j['name']}: {e}")
        elif st.get("status") in ("FAILED", "ERROR"):
            done[j["name"]] = False
            print(f"  FAIL {j['name']}: {st}")
fails = [k for k, v in done.items() if not v] + [j["name"] for j in jobs if j["name"] not in done]
print("FAILED:", fails if fails else "none")
print("ALL DONE")
