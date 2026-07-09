"""
Custom TRON night panorama for environment reflections (Stefan 2026-07-09:
the Poly Haven night maps are all WARM — he wants cold moonlight/cyan).
nano-banana 16:9 -> resized to 2:1 equirect (2048x1024), seam edge-blended so
the wrap doesn't show in reflections. Output: assets/sky/tron_night.webp
Also: cold-grades night_stars.webp -> night_stars_cold.webp as a fallback.
"""
import base64, io, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
import requests
from dotenv import load_dotenv
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
NB = "https://queue.fal.run/fal-ai/nano-banana-pro"
SKY = Path(__file__).parent / "sky"

PROMPT = ("Seamless 360-degree equirectangular HDRI panorama of a digital night sky in the style of "
          "TRON: pure black space above, a cold pale blue-white moonlight glow low on one side, "
          "scattered tiny cool white-blue points of light, thin CYAN neon light strips and distant "
          "glowing grid lines along the horizon, faint cold haze. STRICTLY COLD PALETTE — deep "
          "blacks, blues, cyans, icy white; absolutely NO warm colors, no orange, no yellow, no "
          "red. Dark, minimal, elegant. No ground, no text, no watermark.")


def seam_blend(img: Image.Image, w: int = 80) -> Image.Image:
    a = np.asarray(img).astype(np.float32)
    left = a[:, :w].copy()
    right = a[:, -w:].copy()
    t = np.linspace(0.0, 1.0, w)[None, :, None]
    a[:, :w] = left * t + right * (1.0 - t)          # left edge eases into the right
    a[:, -w:] = right * (1.0 - t[:, ::-1]) + left * t[:, ::-1]
    return Image.fromarray(a.clip(0, 255).astype(np.uint8))


# 1) cold-grade the Satara stars fallback
p = SKY / "night_stars.webp"
if p.exists():
    a = np.asarray(Image.open(p).convert("RGB")).astype(np.float32)
    a[..., 0] *= 0.68   # kill the warm cast
    a[..., 1] *= 0.88
    a[..., 2] *= 1.22
    Image.fromarray(a.clip(0, 255).astype(np.uint8)).save(SKY / "night_stars_cold.webp", "WEBP", quality=90)
    print("night_stars_cold.webp graded")

# 2) generate the custom TRON panorama
r = requests.post(NB, headers=H, json={"prompt": PROMPT, "num_images": 1, "aspect_ratio": "16:9"})
r.raise_for_status()
j = r.json()
print("queued tron_night")
for i in range(120):
    time.sleep(6)
    st = requests.get(j["status_url"], headers=H).json()
    if st.get("status") == "COMPLETED":
        res = requests.get(j["response_url"], headers=H).json()
        raw = requests.get(res["images"][0]["url"], timeout=300).content
        img = Image.open(io.BytesIO(raw)).convert("RGB").resize((2048, 1024), Image.LANCZOS)
        img = seam_blend(img)
        img.save(SKY / "tron_night.webp", "WEBP", quality=90)
        print(f"tron_night.webp saved ({(SKY / 'tron_night.webp').stat().st_size // 1024} KB)")
        break
    if st.get("status") in ("FAILED", "ERROR"):
        print("FAIL:", st)
        break
print("DONE")

# ---- 3) true HDR variant: inverse-tonemap boost, Radiance RGBE (game prefers .hdr)
def write_hdr(src_webp: Path, dst_hdr: Path, size=(1024, 512), k=6.0):
    a = np.asarray(Image.open(src_webp).convert("RGB").resize(size, Image.LANCZOS)).astype(np.float32) / 255.0
    lin = a ** 2.2
    boost = lin * (1.0 + k * lin ** 3)
    h, w, _ = boost.shape
    maxc = boost.max(axis=2)
    rgbe = np.zeros((h, w, 4), dtype=np.uint8)
    nz = maxc > 1e-9
    m, e = np.frexp(maxc[nz])
    scale = m * 256.0 / maxc[nz]
    for c in range(3):
        rgbe[nz, c] = np.clip(boost[nz, c] * scale, 0, 255).astype(np.uint8)
    rgbe[nz, 3] = (e + 128).astype(np.uint8)
    with open(dst_hdr, "wb") as f:
        f.write(b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n")
        f.write(f"-Y {h} +X {w}\n".encode())
        f.write(rgbe.tobytes())
    print(dst_hdr.name, "written")

if (SKY / "tron_night.webp").exists():
    write_hdr(SKY / "tron_night.webp", SKY / "tron_night.hdr")
