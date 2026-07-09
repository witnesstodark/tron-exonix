"""
Claim V4 take 3 — the unclaimed_B pipeline (which Stefan approved), with the
lesson applied: the SOURCE must be a FLAT UNLIT ALBEDO MAP, not a glossy render.
nano-banana (strict flat-map prompts) -> PATINA image mode -> nano-banana
emission edit. Output: claim_v4_1..5/{basecolor,normal,roughness,metalness,height,emission}.webp
"""
import base64, io, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv
from PIL import Image

ROOT = Path(__file__).resolve().parents[4]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
NB = "https://queue.fal.run/fal-ai/nano-banana-pro"
NB_EDIT = "https://queue.fal.run/fal-ai/nano-banana-pro/edit"
PATINA = "https://queue.fal.run/fal-ai/patina"
SRCDIR = ROOT / "workspace/2026-07-06_qix-territory-reveal/concepts_v2"
OUT = Path(__file__).parent

BASE = ("FLAT UNLIT ALBEDO TEXTURE MAP for a game engine, seamless tileable, strict top-down, perfectly even — "
        "absolutely NO lighting, NO shading, NO reflections, NO highlights, NO gradients, NO vignette: this is a "
        "raw color map, not a photo or render. Uniform DEEP BLACK surface (a flat near-black color across at "
        "least 90 percent of the image). The only details: sparse thin CYAN {} Crisp thin lines, minimal, "
        "elegant, cool blue-black palette, no grey, no warm colors.")

PROMPTS = {
    "claim_v4_1": BASE.format("hairline seam lines crossing at very wide spacing, tiny node dots at intersections."),
    "claim_v4_2": BASE.format("right-angle circuit traces, rare and far apart, each ending in a small dot."),
    "claim_v4_3": BASE.format("faint concentric arc segments — a few fragments of large circles, barely visible."),
    "claim_v4_4": BASE.format("diagonal 45-degree conduit lines, very occasional, each carrying one or two short dashes."),
    "claim_v4_5": BASE.format("tiny plus-sign nodes and rare short dashes scattered like a sparse constellation."),
}

EMIT_PROMPT = ("Convert this game floor texture into its EMISSION MAP: output the exact same image where ONLY the "
               "cyan lines, dashes and node points remain visible, at full brightness in their original color, on a "
               "PURE BLACK background. Pixel-aligned with the input — keep every element in its exact position, "
               "scale and thickness. Remove everything else. Flat map, no lighting, no text.")


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


def run_jobs(jobs, handler, deadline_s):
    done = {}
    end = time.time() + deadline_s
    while len(done) < len(jobs) and time.time() < end:
        time.sleep(7)
        for j in jobs:
            if j["name"] in done:
                continue
            st = requests.get(j["s"], headers=H).json()
            if st.get("status") == "COMPLETED":
                res = requests.get(j["r"], headers=H).json()
                try:
                    handler(j["name"], res)
                    done[j["name"]] = True
                except Exception as e:
                    done[j["name"]] = False
                    print(f"  handler FAIL {j['name']}: {e}")
            elif st.get("status") in ("FAILED", "ERROR"):
                done[j["name"]] = False
                print(f"  FAIL {j['name']}: {st}")
    return done


# ---- 1. flat albedo sources ----
jobs = []
for name, prompt in PROMPTS.items():
    r = requests.post(NB, headers=H, json={"prompt": prompt, "num_images": 1, "aspect_ratio": "1:1"})
    r.raise_for_status()
    j = r.json()
    jobs.append({"name": name, "s": j["status_url"], "r": j["response_url"]})
print(f"albedo sources submitted: {len(jobs)}")

sources = {}
def save_src(name, res):
    img = fetch(res["images"][0]["url"])
    (SRCDIR / f"{name}_flat.png").write_bytes(img)
    sources[name] = img
    print(f"  source ok {name} ({len(img)//1024} KB)")
run_jobs(jobs, save_src, 700)

# ---- 2. PATINA image mode on the flat sources ----
jobs = []
for name, img in sources.items():
    r = requests.post(PATINA, headers=H, json={
        "image_url": data_uri(img, "image/png"),
        "maps": ["basecolor", "normal", "roughness", "metalness", "height"],
        "output_format": "webp",
    })
    r.raise_for_status()
    j = r.json()
    jobs.append({"name": name, "s": j["status_url"], "r": j["response_url"]})
print(f"patina submitted: {len(jobs)}")

def save_maps(name, res):
    mat_dir = OUT / name
    mat_dir.mkdir(exist_ok=True)
    got = []
    for img in res.get("images", []):
        mt = img.get("map_type") or "image"
        (mat_dir / f"{mt}.webp").write_bytes(fetch(img["url"]))
        got.append(mt)
    if not got:
        raise RuntimeError(f"no images in response: {list(res.keys())}")
    print(f"  patina ok {name}: {got}")
run_jobs(jobs, save_maps, 1200)

# ---- 3. emission maps ----
jobs = []
for name in PROMPTS:
    bc = OUT / name / "basecolor.webp"
    if not bc.exists():
        print(f"  skip emission {name}")
        continue
    r = requests.post(NB_EDIT, headers=H, json={
        "prompt": EMIT_PROMPT,
        "image_urls": [data_uri(bc.read_bytes(), "image/webp")],
        "num_images": 1,
    })
    r.raise_for_status()
    j = r.json()
    jobs.append({"name": name, "s": j["status_url"], "r": j["response_url"]})
print(f"emission submitted: {len(jobs)}")

def save_emit(name, res):
    raw = fetch(res["images"][0]["url"])
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    img.save(OUT / name / "emission.webp", "WEBP", quality=92)
    print(f"  emission ok {name}")
run_jobs(jobs, save_emit, 900)
print("ALL DONE")
