"""
Claim V4 take 2 (Stefan: image-based sets baked reflections into albedo — bad).
PATINA TEXT-to-material this time: clean flat maps straight from prompts,
emission requested as a native PATINA map. -> claim_v4_1..5/*.webp
"""
import io, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[4]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
PATINA = "https://queue.fal.run/fal-ai/patina"
OUT = Path(__file__).parent

BASE = ("Seamless tileable sci-fi floor material, Tron Legacy style: DEEP BLACK polished obsidian anthracite "
        "tile, uniform near-black albedo, absolutely NO baked lighting, NO reflections, NO gradients, NO color "
        "washes — flat clean texture maps. At least 90 percent plain deep black surface, calm and not "
        "distracting. The ONLY details: sparse thin glowing CYAN {} Elegant, minimal, high detail, sharp thin "
        "lines, cool blue-black palette, no grey, no warm colors.")

PROMPTS = {
    "claim_v4_1": BASE.format("hairline seam lines crossing at very wide spacing, with tiny glowing node dots at the intersections."),
    "claim_v4_2": BASE.format("right-angle circuit traces, rare and far apart, each ending in a small glowing dot."),
    "claim_v4_3": BASE.format("faint concentric arc segments, just a few fragments of large circles, barely visible."),
    "claim_v4_4": BASE.format("diagonal 45-degree conduit lines, very occasional, each carrying one or two short bright glow dashes."),
    "claim_v4_5": BASE.format("tiny plus-sign nodes and rare short dashes scattered like a sparse constellation."),
}


def fetch(url: str, tries: int = 4) -> bytes:
    for i in range(tries):
        try:
            return requests.get(url, timeout=300).content
        except Exception as e:
            if i == tries - 1:
                raise
            print(f"  retry {i + 1} after: {type(e).__name__}")
            time.sleep(4 * (i + 1))


jobs = []
for name, prompt in PROMPTS.items():
    r = requests.post(PATINA, headers=H, json={
        "prompt": prompt,
        "maps": ["basecolor", "normal", "roughness", "metalness", "height", "emission"],
        "output_format": "webp",
    })
    r.raise_for_status()
    j = r.json()
    jobs.append({"name": name, "s": j["status_url"], "r": j["response_url"]})
print(f"submitted {len(jobs)} text-to-material jobs")

done = {}
deadline = time.time() + 1500
while len(done) < len(jobs) and time.time() < deadline:
    time.sleep(7)
    for j in jobs:
        if j["name"] in done:
            continue
        st = requests.get(j["s"], headers=H).json()
        if st.get("status") == "COMPLETED":
            res = requests.get(j["r"], headers=H).json()
            mat_dir = OUT / j["name"]
            mat_dir.mkdir(exist_ok=True)
            got = []
            for img in res.get("images", []):
                mt = img.get("map_type") or "image"
                (mat_dir / f"{mt}.webp").write_bytes(fetch(img["url"]))
                got.append(mt)
            done[j["name"]] = True
            print(f"  ok {j['name']}: {got}")
        elif st.get("status") in ("FAILED", "ERROR"):
            done[j["name"]] = False
            print(f"  FAIL {j['name']}: {st}")
for j in jobs:
    if j["name"] not in done:
        print(f"  ? {j['name']} timed out")
print("done")
