"""
TRON: EXONIX — game icon. nano-banana-pro, one square render of a Tron energy
sphere, downscaled to 256px game/icon.png (project + window icon).
"""
import io, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
NB = "https://queue.fal.run/fal-ai/nano-banana-pro"
GAME = Path(__file__).parent.parent / "game"

PROMPT = ("Video game app icon, square 1:1: a single glowing energy sphere floating in the center "
          "of a pitch-black void — a translucent dark glass ball wrapped in bright CYAN circuit "
          "lines and thin neon seams, like a TRON light-cycle world condensed into an orb, with a "
          "faint menacing red-orange ember glowing deep inside its core. Subtle cyan rim light, "
          "soft reflection under the sphere on a glossy black floor, gentle vignette. Bold, clean, "
          "instantly readable at small sizes. NO text, NO letters, NO watermark.")

r = requests.post(NB, headers=H, json={"prompt": PROMPT, "num_images": 1, "aspect_ratio": "1:1"})
r.raise_for_status()
j = r.json()
print("queued")
for i in range(90):
    time.sleep(5)
    st = requests.get(j["status_url"], headers=H).json()
    if st.get("status") == "COMPLETED":
        res = requests.get(j["response_url"], headers=H).json()
        raw = requests.get(res["images"][0]["url"], timeout=300).content
        img = Image.open(io.BytesIO(raw)).convert("RGB")
        img = img.resize((256, 256), Image.LANCZOS)
        img.save(GAME / "icon.png", optimize=True)
        big = Image.open(io.BytesIO(raw)).convert("RGB").resize((1024, 1024), Image.LANCZOS)
        big.save(Path(__file__).parent / "icon_src.webp", "WEBP", quality=92)
        print(f"icon.png written ({(GAME / 'icon.png').stat().st_size // 1024} KB)")
        break
    if st.get("status") in ("FAILED", "ERROR"):
        print("FAIL:", st)
        break
