"""
QIX — hero + prop sheets via fal tripo3d/h3.1.
Hero: isolate the Speeder Pod concept (remove glow cushion) -> H3.1 @ 20k faces.
Props: the 3 existing 5-prop sheet images go in AS-IS, one H3.1 job each @ 10k
faces (Stefan's credit-saving trick) -> one GLB per sheet, split by loose parts
in Blender afterwards.
Output: assets/3d/hero_a_pod.glb, props_L1_city.glb, props_L2_industrial.glb, props_L3_dune.glb
"""
import base64, io, os, sys, time, threading
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
WS = ROOT / "workspace/2026-07-06_qix-territory-reveal"
OUT = Path(__file__).parent / "3d"
SRC = OUT / "src"

JOBS = [
    # name, source image, isolate prompt (None = use as-is), faces
    ("hero_a_pod", WS / "assets_v1/hero_a_pod.webp",
     "Show ONLY the black hover-speeder pod vehicle completely alone, centered on a plain flat dark charcoal "
     "background. Remove the cyan light cushion and glow beneath it, any floor glow, reflections and shadows. "
     "Keep the vehicle's design, colors and its own emissive light lines unchanged. Whole vehicle in frame with margin.",
     20000),
    ("props_L1_city", WS / "surfaces_v2/props_L1_city.webp", None, 30000),
    ("props_L2_industrial", WS / "surfaces_v2/props_L2_industrial.webp", None, 30000),
    ("props_L3_dune", WS / "surfaces_v2/props_L3_dune.webp", None, 30000),
]

lock = threading.Lock()
def log(m):
    with lock:
        print(m, flush=True)


def data_uri(b: bytes, mime) -> str:
    return f"data:{mime};base64," + base64.b64encode(b).decode()


def fal_queue(endpoint, payload):
    r = requests.post(f"https://queue.fal.run/{endpoint}", headers=H, json=payload)
    r.raise_for_status()
    return r.json()


def fal_wait(job, timeout=1500):
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(8)
        s = requests.get(job["status_url"], headers=H).json()
        if s.get("status") == "COMPLETED":
            return requests.get(job["response_url"], headers=H).json()
        if s.get("status") in ("FAILED", "ERROR"):
            raise RuntimeError(str(s)[:300])
    raise TimeoutError(job.get("request_id"))


def process(name, src, iso_prompt, faces):
    try:
        dst = OUT / f"{name}.glb"
        if dst.exists():
            log(f"  = {name} exists, skip")
            return
        img_bytes = src.read_bytes()
        mime = "image/webp"
        if iso_prompt:
            iso_png = SRC / f"{name}.png"
            if iso_png.exists():
                img_bytes = iso_png.read_bytes()
                mime = "image/png"
            else:
                j = fal_queue("fal-ai/nano-banana-pro/edit",
                              {"prompt": iso_prompt, "image_urls": [data_uri(img_bytes, mime)], "num_images": 1})
                res = fal_wait(j, 420)
                raw = requests.get(res["images"][0]["url"]).content
                Image.open(io.BytesIO(raw)).convert("RGB").save(iso_png, "PNG")
                img_bytes = iso_png.read_bytes()
                mime = "image/png"
                log(f"  A {name}: isolated")
        j = fal_queue("tripo3d/h3.1/image-to-3d", {
            "image_url": data_uri(img_bytes, mime),
            "texture": True, "pbr": True,
            "texture_quality": "detailed", "geometry_quality": "detailed",
            "face_limit": faces,
        })
        log(f"  B {name}: h3.1 submitted ({faces} tris)")
        res = fal_wait(j)
        mesh = res.get("model_mesh") or {}
        url = mesh.get("url") or (res.get("model_urls") or {}).get("glb")
        if not url:
            raise RuntimeError(f"no mesh url: {list(res.keys())}")
        dst.write_bytes(requests.get(url, timeout=600).content)
        log(f"  ✓ {name}.glb ({dst.stat().st_size//1024} KB)")
    except Exception as e:
        log(f"  ✗ {name}: {e}")


threads = []
for spec in JOBS:
    t = threading.Thread(target=process, args=spec)
    t.start()
    threads.append(t)
    time.sleep(2)
for t in threads:
    t.join()
print("done:", sorted(p.name for p in OUT.glob("props_*.glb")) + [p.name for p in OUT.glob("hero_*.glb")])
