"""
QIX — unclaimed_B sea surface, full pipeline (Stefan 2026-07-08: unclaimed_A is
TOO RED — want near-black surface with sparse spreading red embeddings).
1. nano-banana-pro  -> source PNG (workspace surfaces_v2/unclaimed_B.png)
2. PATINA           -> assets/textures/unclaimed_B/{basecolor,normal,roughness,metalness,height}.webp
3. nano-banana edit -> assets/textures/unclaimed_B/emission.webp
For Blender preview confirmation FIRST — not wired into the game yet.
"""
import base64, io, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv
from PIL import Image

ROOT = Path(__file__).resolve().parents[4]  # C:/GIT/mr-mak
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
NB = "https://queue.fal.run/fal-ai/nano-banana-pro"
NB_EDIT = "https://queue.fal.run/fal-ai/nano-banana-pro/edit"
PATINA = "https://queue.fal.run/fal-ai/patina"
SRC_DIR = ROOT / "workspace/2026-07-06_qix-territory-reveal/surfaces_v2"
OUT = Path(__file__).parent / "unclaimed_B"
OUT.mkdir(exist_ok=True)

PROMPT = (
    "Seamless tileable game floor texture, strict top-down orthographic view, flat, no perspective, no props, "
    "evenly lit, repeats edge to edge. UNCLAIMED danger territory: NEAR-BLACK obsidian glass surface, matte black "
    "dominates at least 85 percent of the area. Sparse thin DEEP RED embedded veins spreading organically through "
    "the black like roots or cracks in volcanic rock, dim red circuit filaments branching and fading out, a few tiny "
    "faint red node points. The red is an accent only — subtle, menacing, embedded INSIDE the black surface, never "
    "large red areas, never a red wash. Elegant sparse pattern, cool dark palette, no orange, no grey, no cyan. "
    "High detail, sharp, high production value."
)

EMIT_PROMPT = (
    "Convert this game floor texture into its EMISSION MAP: output the exact same image where ONLY the thin glowing "
    "deep-red veins, filaments and node points remain visible, at full brightness and in their original red color, on "
    "a PURE BLACK background. Keep every glowing line in its exact position, scale and thickness — pixel-aligned with "
    "the input. Remove all non-glowing surface detail completely. Flat map, no lighting, no vignette, no text."
)


def data_uri(b: bytes, mime="image/png") -> str:
    return f"data:{mime};base64," + base64.b64encode(b).decode()


def wait(status_url, response_url, deadline_s=600):
    end = time.time() + deadline_s
    while time.time() < end:
        time.sleep(6)
        s = requests.get(status_url, headers=H).json()
        if s.get("status") == "COMPLETED":
            return requests.get(response_url, headers=H).json()
        if s.get("status") in ("FAILED", "ERROR"):
            raise RuntimeError(f"job failed: {s}")
    raise TimeoutError("fal job timed out")


# ---- 1. source ----
r = requests.post(NB, headers=H, json={"prompt": PROMPT, "num_images": 1, "aspect_ratio": "1:1"})
r.raise_for_status()
j = r.json()
res = wait(j["status_url"], j["response_url"])
src_png = requests.get(res["images"][0]["url"]).content
(SRC_DIR / "unclaimed_B.png").write_bytes(src_png)
print(f"source ok ({len(src_png)//1024} KB)")

# ---- 2. PATINA PBR set ----
r = requests.post(PATINA, headers=H, json={
    "image_url": data_uri(src_png),
    "maps": ["basecolor", "normal", "roughness", "metalness", "height"],
    "output_format": "webp",
})
r.raise_for_status()
j = r.json()
res = wait(j["status_url"], j["response_url"], 900)
for img in res.get("images", []):
    mt = img.get("map_type") or "image"
    data = requests.get(img["url"]).content
    (OUT / f"{mt}.webp").write_bytes(data)
    print(f"  unclaimed_B/{mt}.webp ({len(data)//1024} KB)")

# ---- 3. emission map from the PATINA basecolor ----
bc = (OUT / "basecolor.webp").read_bytes()
r = requests.post(NB_EDIT, headers=H, json={
    "prompt": EMIT_PROMPT,
    "image_urls": [data_uri(bc, "image/webp")],
    "num_images": 1,
})
r.raise_for_status()
j = r.json()
res = wait(j["status_url"], j["response_url"], 720)
raw = requests.get(res["images"][0]["url"]).content
img = Image.open(io.BytesIO(raw)).convert("RGB")
img.save(OUT / "emission.webp", "WEBP", quality=92)
print(f"  unclaimed_B/emission.webp ({(OUT / 'emission.webp').stat().st_size//1024} KB)")
print("ALL DONE")
