"""
Texture round 2 — palette for the 10-level redesign (Stefan 2026-07-09).
5 CORRUPTED claimed surfaces (cool cyan grid invaded by warm ember-orange —
enemy territory feel, balanced: never strongly red nor strongly blue) and
3 new UNCLAIMED sea floors (near-black + sparse red family, like unclaimed_B).
Pipeline per set: nano-banana flat albedo -> PATINA PBR -> nano-banana emission.
Output: claim_c1..c5/, unclaimed_C..E/ {basecolor,normal,roughness,metalness,height,emission}.webp
Sources kept in src_round2/*.webp. CLI arg = name filter for single-set rerolls.
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
OUT = Path(__file__).parent
SRCDIR = OUT / "src_round2"
SRCDIR.mkdir(exist_ok=True)

FLAT = ("FLAT UNLIT ALBEDO TEXTURE MAP for a game engine, seamless tileable, strict top-down, perfectly even — "
        "absolutely NO lighting, NO shading, NO reflections, NO highlights, NO gradients, NO vignette: this is a "
        "raw color map, not a photo or render. Uniform DEEP BLACK surface (a flat near-black color across at "
        "least 90 percent of the image). The only details: {} Crisp thin lines, minimal, elegant, no grey.")

CORRUPT_TAIL = (" Palette: cool blue-black invaded by warm ember accents — CYAN and AMBER-ORANGE in careful "
                "balance, neither strongly red nor strongly blue overall.")
SEA_TAIL = " Palette: cool near-black with DEEP RED accents only — subtle, menacing, no orange, no cyan."

PROMPTS = {
    # claimed-but-corrupted: our grid on enemy ground
    "claim_c1": FLAT.format(
        "sparse thin CYAN hairline seams at wide spacing, several segments glitching into AMBER-ORANGE where a "
        "corruption spreads along the line, tiny orange node dots at the infected joints.") + CORRUPT_TAIL,
    "claim_c2": FLAT.format(
        "EXTREMELY SPARSE right-angle circuit traces — at most five or six short thin traces across the whole "
        "tile, most in CYAN, one or two burnt AMBER-ORANGE and slightly fragmented, each ending in a small "
        "scorched dot. Everything between them stays pure flat near-black.") + CORRUPT_TAIL,
    "claim_c3": FLAT.format(
        "faint thin fragments of a few large concentric CYAN arcs, interrupted by short jagged AMBER-ORANGE "
        "fracture ticks where the arcs decay. The background between arcs is PURE FLAT NEAR-BLACK — "
        "not teal, not dark blue, not grey.") + CORRUPT_TAIL,
    "claim_c4": FLAT.format(
        "very occasional diagonal 45-degree conduit lines alternating cool CYAN and ember ORANGE, a few of them "
        "breaking into dashed corrupted segments.") + CORRUPT_TAIL,
    "claim_c5": FLAT.format(
        "a sparse constellation of tiny plus-sign nodes and rare short dashes, half CYAN and half ember-ORANGE, "
        "as if the grid is contested cell by cell.") + CORRUPT_TAIL,
    # unclaimed sea: the dangerous dark, red family like unclaimed_B
    "unclaimed_C": FLAT.format(
        "sparse thin DEEP RED crack veins branching organically through volcanic obsidian, like roots of fire "
        "under black glass, a few tiny faint red node points.") + SEA_TAIL,
    "unclaimed_D": FLAT.format(
        "a sparse dormant circuit web of long broken DEEP RED filaments crossing the tile, clearly visible thin "
        "red lines with rare brighter ember dots at junctions, on PURE FLAT NEAR-BLACK — not grey, not washed "
        "out.") + SEA_TAIL,
    "unclaimed_E": FLAT.format(
        "large dark tectonic plates separated by hairline DEEP RED seams, one or two plates carrying a faint red "
        "scar glyph, everything else pure black.") + SEA_TAIL,
}

EMIT = {
    "claim": ("Convert this game floor texture into its EMISSION MAP: output the exact same image where ONLY the "
              "cyan and amber-orange lines, dashes and node points remain visible, at full brightness in their "
              "original colors, on a PURE BLACK background. Pixel-aligned with the input — keep every element in "
              "its exact position, scale and thickness. Remove everything else. Flat map, no lighting, no text."),
    "unclaimed": ("Convert this game floor texture into its EMISSION MAP: output the exact same image where ONLY "
                  "the thin glowing deep-red veins, filaments and node points remain visible, at full brightness "
                  "in their original red color, on a PURE BLACK background. Pixel-aligned with the input — keep "
                  "every element in its exact position, scale and thickness. Remove everything else. Flat map, "
                  "no lighting, no text."),
}

MAX_PX = 1024   # Stefan's cap: floor tiles never need more than 1K


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


def save_capped(raw: bytes, path: Path) -> None:
    img = Image.open(io.BytesIO(raw))
    if max(img.size) > MAX_PX:
        img = img.resize((MAX_PX, MAX_PX), Image.LANCZOS)
    img.save(path, "WEBP", quality=92)


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


only = sys.argv[1] if len(sys.argv) > 1 else ""
todo = {k: v for k, v in PROMPTS.items() if only in k}
print(f"sets: {list(todo)}")

# ---- 1. flat albedo sources ----
jobs = []
for name, prompt in todo.items():
    r = requests.post(NB, headers=H, json={"prompt": prompt, "num_images": 1, "aspect_ratio": "1:1"})
    r.raise_for_status()
    j = r.json()
    jobs.append({"name": name, "s": j["status_url"], "r": j["response_url"]})
print(f"albedo sources submitted: {len(jobs)}")

sources = {}
def save_src(name, res):
    raw = fetch(res["images"][0]["url"])
    save_capped(raw, SRCDIR / f"{name}_flat.webp")
    sources[name] = (SRCDIR / f"{name}_flat.webp").read_bytes()
    print(f"  source ok {name} ({len(sources[name])//1024} KB)")
run_jobs(jobs, save_src, 900)

# ---- 2. PATINA PBR sets ----
jobs = []
for name, img in sources.items():
    r = requests.post(PATINA, headers=H, json={
        "image_url": data_uri(img, "image/webp"),
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
        save_capped(fetch(img["url"]), mat_dir / f"{mt}.webp")
        got.append(mt)
    if not got:
        raise RuntimeError(f"no images in response: {list(res.keys())}")
    print(f"  patina ok {name}: {got}")
run_jobs(jobs, save_maps, 1500)

# ---- 3. emission maps ----
jobs = []
for name in todo:
    bc = OUT / name / "basecolor.webp"
    if not bc.exists():
        print(f"  skip emission {name}")
        continue
    kind = "claim" if name.startswith("claim") else "unclaimed"
    r = requests.post(NB_EDIT, headers=H, json={
        "prompt": EMIT[kind],
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
    if max(img.size) > MAX_PX:
        img = img.resize((MAX_PX, MAX_PX), Image.LANCZOS)
    img.save(OUT / name / "emission.webp", "WEBP", quality=92)
    print(f"  emission ok {name}")
run_jobs(jobs, save_emit, 900)
print("ALL DONE")
