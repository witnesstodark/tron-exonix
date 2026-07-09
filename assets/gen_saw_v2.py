"""SAW A v2: remove the bracket/handle from the approved disc concept (it must
be a clean radially-symmetric disc — it spins in-game), then re-run Tripo.
Output: workspace concepts_v2/saw_A_disc_v2.png + assets/3d/saw_a.glb (replaced)."""
import base64, io, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
NB_EDIT = "https://queue.fal.run/fal-ai/nano-banana-pro/edit"
TRIPO = "https://queue.fal.run/tripo3d/h3.1/image-to-3d"
SRC = ROOT / "workspace/2026-07-06_qix-territory-reveal/concepts_v2"
GLBOUT = ROOT / "projects/tron-exonix/assets/3d"

EDIT_PROMPT = ("Edit this saw machine concept: REMOVE the mounting bracket / handle / arm attached to the disc "
               "completely. Output ONLY the perfectly circular, radially symmetric saw disc itself — glowing "
               "blade teeth all the way around the full rim with no gaps, the round hub in the center. Nothing "
               "may stick out beyond the circular silhouette. Keep the exact same style, colors, materials and "
               "lighting. Single object on the same black background, no text.")


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


def wait(status_url, response_url, deadline_s=1500):
    end = time.time() + deadline_s
    while time.time() < end:
        time.sleep(7)
        s = requests.get(status_url, headers=H).json()
        if s.get("status") == "COMPLETED":
            return requests.get(response_url, headers=H).json()
        if s.get("status") in ("FAILED", "ERROR"):
            raise RuntimeError(f"job failed: {s}")
    raise TimeoutError("fal job timed out")


# 1) clean the concept
src = (SRC / "saw_A_disc.webp").read_bytes()
r = requests.post(NB_EDIT, headers=H, json={
    "prompt": EDIT_PROMPT,
    "image_urls": [data_uri(src, "image/webp")],
    "num_images": 1,
})
r.raise_for_status()
j = r.json()
res = wait(j["status_url"], j["response_url"], 600)
img = fetch(res["images"][0]["url"])
(SRC / "saw_A_disc_v2.png").write_bytes(img)
print(f"clean disc image ok ({len(img)//1024} KB)")

# 2) Tripo the clean disc
r = requests.post(TRIPO, headers=H, json={
    "image_url": data_uri(img, "image/png"),
    "texture": True, "pbr": True,
    "texture_quality": "detailed", "geometry_quality": "detailed",
    "face_limit": 15000,
})
r.raise_for_status()
j = r.json()
res = wait(j["status_url"], j["response_url"], 1500)
url = (res.get("model_mesh") or {}).get("url")
if not url:
    urls = res.get("model_urls") or {}
    url = urls.get("glb") or urls.get("pbr_model") or urls.get("base_model")
data = fetch(url)
(GLBOUT / "saw_a.glb").write_bytes(data)
print(f"saw_a.glb replaced ({len(data)//1024} KB)")
print("ALL DONE")
