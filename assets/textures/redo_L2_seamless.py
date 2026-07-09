"""
L2 industrial redo: the V3 texture had a border frame — regenerate strictly
seamless (edge-to-edge, no frame), then chain: PATINA set -> emission map.
Overwrites: workspace surfaces_v2/claim_L2_industrial.png (+dashboard webp via
optimizer later) and assets/textures/claim_L2_industrial/*.
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
WS_SRC = ROOT / "workspace/2026-07-06_qix-territory-reveal/surfaces_v2/claim_L2_industrial.png"
MAT_DIR = Path(__file__).parent / "claim_L2_industrial"

TEX_PROMPT = (
    "Seamless tileable game floor texture, strict top-down orthographic view, flat, no perspective, no props, "
    "evenly lit. CLAIMED territory level 2, INDUSTRIAL: obsidian black glass with glowing CYAN circuit lines — "
    "recessed panel seams, small bolt and rivet nodes, vent-grate slots and conduit runs drawn as glowing cyan "
    "edges on black glass, denser than a simple grid. Cool blue-black palette, NO grey steel, NO orange, NO warm "
    "colors. CRITICAL: the pattern must run EDGE TO EDGE and tile perfectly in all directions — absolutely NO "
    "border, NO frame, NO outer rim, NO vignette; cut lines continue past every edge of the image. "
    "High detail, sharp, high production value.")

EMIT_PROMPT = (
    "Convert this game floor texture into its EMISSION MAP: output the exact same image where ONLY the glowing "
    "cyan panel seams, rivet nodes, vent glow and conduit lines remain visible, at full brightness and original "
    "color, on a PURE BLACK background. Keep every glowing element in its exact position, scale and thickness — "
    "pixel-aligned with the input. Remove all non-glowing detail. Flat map, no lighting, no vignette, no text.")


def wait(status_url, response_url, timeout=420):
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(5)
        s = requests.get(status_url, headers=H).json()
        if s.get("status") == "COMPLETED":
            return requests.get(response_url, headers=H).json()
        if s.get("status") in ("FAILED", "ERROR"):
            raise RuntimeError(str(s))
    raise TimeoutError(status_url)


def q(endpoint, payload):
    r = requests.post(f"https://queue.fal.run/{endpoint}", headers=H, json=payload)
    r.raise_for_status()
    j = r.json()
    return wait(j["status_url"], j["response_url"])


def data_uri(b: bytes, mime="image/png") -> str:
    return f"data:{mime};base64," + base64.b64encode(b).decode()


# 1) regenerate the base texture, seamless
print("1/3 texture...")
res = q("fal-ai/nano-banana-pro", {"prompt": TEX_PROMPT, "num_images": 1, "aspect_ratio": "1:1"})
png = requests.get(res["images"][0]["url"]).content
WS_SRC.write_bytes(png)
print(f"  texture -> {WS_SRC.name} ({len(png)//1024} KB)")

# 2) PATINA set from it
print("2/3 PATINA set...")
res = q("fal-ai/patina", {"image_url": data_uri(png), "maps": ["basecolor", "normal", "roughness", "metalness", "height"], "output_format": "webp"})
MAT_DIR.mkdir(exist_ok=True)
for img in res.get("images", []):
    mt = img.get("map_type") or "image"
    data = requests.get(img["url"]).content
    (MAT_DIR / f"{mt}.webp").write_bytes(data)
    print(f"  {mt}.webp ({len(data)//1024} KB)")

# 3) emission from the new basecolor
print("3/3 emission...")
bc = (MAT_DIR / "basecolor.webp").read_bytes()
res = q("fal-ai/nano-banana-pro/edit", {"prompt": EMIT_PROMPT, "image_urls": [data_uri(bc, "image/webp")], "num_images": 1})
raw = requests.get(res["images"][0]["url"]).content
img = Image.open(io.BytesIO(raw)).convert("RGB")
img.save(MAT_DIR / "emission.webp", "WEBP", quality=92)
print(f"  emission.webp ({(MAT_DIR / 'emission.webp').stat().st_size//1024} KB)")
print("done")
