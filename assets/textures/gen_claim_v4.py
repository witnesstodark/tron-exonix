"""
QIX Asset Set V4 production run (Stefan approved 2026-07-08):
1. 5 claimed-surface tiles: PATINA PBR sets + nano-banana emission maps
   -> assets/textures/claim_v4_1..5/{basecolor,normal,roughness,metalness,height,emission}.webp
2. SAW A (flat spinning disc enemy): Tripo h3.1 image-to-3d
   -> assets/3d/saw_a.glb (15k faces, detailed)
Sources: workspace concepts_v2 webp images. Blender preview wiring happens after.
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
PATINA = "https://queue.fal.run/fal-ai/patina"
NB_EDIT = "https://queue.fal.run/fal-ai/nano-banana-pro/edit"
TRIPO = "https://queue.fal.run/tripo3d/h3.1/image-to-3d"
SRC = ROOT / "workspace/2026-07-06_qix-territory-reveal/concepts_v2"
TEXOUT = Path(__file__).parent
GLBOUT = ROOT / "projects/tron-exonix/assets/3d"

SURFACES = {
    "claim_v4_1": "claim_v3_1_seams.webp",
    "claim_v4_2": "claim_v3_2_traces.webp",
    "claim_v4_3": "claim_v3_3_arcs.webp",
    "claim_v4_4": "claim_v3_4_conduit.webp",
    "claim_v4_5": "claim_v3_5_nodes.webp",
}
EMIT_PROMPT = ("Convert this game floor texture into its EMISSION MAP: output the exact same image where ONLY the "
               "glowing cyan lines, dashes and node points remain visible, at full brightness and in their original "
               "color, on a PURE BLACK background. Keep every glowing element in its exact position, scale and "
               "thickness — pixel-aligned with the input. Remove all non-glowing surface detail completely. "
               "Flat map, no lighting, no vignette, no text.")


def data_uri(b: bytes, mime: str) -> str:
    return f"data:{mime};base64," + base64.b64encode(b).decode()


def fetch(url: str, tries: int = 4) -> bytes:
    """Download with retries — a flaky connection killed the first run."""
    for i in range(tries):
        try:
            return requests.get(url, timeout=300).content
        except Exception as e:
            if i == tries - 1:
                raise
            print(f"  retry {i + 1} after: {type(e).__name__}")
            time.sleep(4 * (i + 1))


def wait(status_url, response_url, deadline_s=900):
    end = time.time() + deadline_s
    while time.time() < end:
        time.sleep(7)
        s = requests.get(status_url, headers=H).json()
        if s.get("status") == "COMPLETED":
            return requests.get(response_url, headers=H).json()
        if s.get("status") in ("FAILED", "ERROR"):
            raise RuntimeError(f"job failed: {s}")
    raise TimeoutError("fal job timed out")


# ---- kick off the saw FIRST (Tripo is the slowest) ----
saw_src = (SRC / "saw_A_disc.webp").read_bytes()
r = requests.post(TRIPO, headers=H, json={
    "image_url": data_uri(saw_src, "image/webp"),
    "texture": True, "pbr": True,
    "texture_quality": "detailed", "geometry_quality": "detailed",
    "face_limit": 15000,
})
r.raise_for_status()
saw_job = r.json()
print("saw A tripo submitted")

# ---- PATINA all five surfaces in parallel ----
jobs = []
for name, src in SURFACES.items():
    img = (SRC / src).read_bytes()
    r = requests.post(PATINA, headers=H, json={
        "image_url": data_uri(img, "image/webp"),
        "maps": ["basecolor", "normal", "roughness", "metalness", "height"],
        "output_format": "webp",
    })
    r.raise_for_status()
    j = r.json()
    jobs.append({"name": name, "s": j["status_url"], "r": j["response_url"]})
print(f"patina submitted: {len(jobs)}")

done = {}
deadline = time.time() + 1200
while len(done) < len(jobs) and time.time() < deadline:
    time.sleep(7)
    for j in jobs:
        if j["name"] in done:
            continue
        st = requests.get(j["s"], headers=H).json()
        if st.get("status") == "COMPLETED":
            res = requests.get(j["r"], headers=H).json()
            mat_dir = TEXOUT / j["name"]
            mat_dir.mkdir(exist_ok=True)
            for img in res.get("images", []):
                mt = img.get("map_type") or "image"
                data = fetch(img["url"])
                (mat_dir / f"{mt}.webp").write_bytes(data)
            done[j["name"]] = True
            print(f"  patina ok {j['name']}")
        elif st.get("status") in ("FAILED", "ERROR"):
            done[j["name"]] = False
            print(f"  patina FAIL {j['name']}: {st}")

# ---- emission maps from the PATINA basecolors ----
ejobs = []
for name in SURFACES:
    bc = TEXOUT / name / "basecolor.webp"
    if not bc.exists():
        print(f"  skip emission {name} (no basecolor)")
        continue
    r = requests.post(NB_EDIT, headers=H, json={
        "prompt": EMIT_PROMPT,
        "image_urls": [data_uri(bc.read_bytes(), "image/webp")],
        "num_images": 1,
    })
    r.raise_for_status()
    j = r.json()
    ejobs.append({"name": name, "s": j["status_url"], "r": j["response_url"]})
print(f"emission submitted: {len(ejobs)}")

done = {}
deadline = time.time() + 900
while len(done) < len(ejobs) and time.time() < deadline:
    time.sleep(7)
    for j in ejobs:
        if j["name"] in done:
            continue
        st = requests.get(j["s"], headers=H).json()
        if st.get("status") == "COMPLETED":
            res = requests.get(j["r"], headers=H).json()
            raw = fetch(res["images"][0]["url"])
            img = Image.open(io.BytesIO(raw)).convert("RGB")
            img.save(TEXOUT / j["name"] / "emission.webp", "WEBP", quality=92)
            done[j["name"]] = True
            print(f"  emission ok {j['name']}")
        elif st.get("status") in ("FAILED", "ERROR"):
            done[j["name"]] = False
            print(f"  emission FAIL {j['name']}: {st}")

# ---- collect the saw ----
res = wait(saw_job["status_url"], saw_job["response_url"], 1500)
url = (res.get("model_mesh") or {}).get("url")
if not url:
    urls = res.get("model_urls") or {}
    url = urls.get("glb") or urls.get("pbr_model") or urls.get("base_model")
data = fetch(url)
(GLBOUT / "saw_a.glb").write_bytes(data)
print(f"saw_a.glb ({len(data)//1024} KB)")
print("ALL DONE")
