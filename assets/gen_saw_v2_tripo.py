"""SAW v2 Tripo step only (the edit already succeeded). Defensive URL
extraction — the previous run got a response without model_mesh.url."""
import base64, io, json, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
TRIPO = "https://queue.fal.run/tripo3d/h3.1/image-to-3d"
SRC = ROOT / "workspace/2026-07-06_qix-territory-reveal/concepts_v2/saw_A_disc_v2.png"
DST = ROOT / "projects/tron-exonix/assets/3d/saw_a.glb"


def find_urls(obj, out):
    if isinstance(obj, dict):
        for v in obj.values():
            find_urls(v, out)
    elif isinstance(obj, list):
        for v in obj:
            find_urls(v, out)
    elif isinstance(obj, str) and obj.startswith("http"):
        out.append(obj)


img = SRC.read_bytes()
r = requests.post(TRIPO, headers=H, json={
    "image_url": "data:image/png;base64," + base64.b64encode(img).decode(),
    "texture": True, "pbr": True,
    "texture_quality": "detailed", "geometry_quality": "detailed",
    "face_limit": 15000,
})
r.raise_for_status()
j = r.json()
print("submitted")

deadline = time.time() + 1500
res = None
while time.time() < deadline:
    time.sleep(8)
    s = requests.get(j["status_url"], headers=H).json()
    if s.get("status") == "COMPLETED":
        res = requests.get(j["response_url"], headers=H).json()
        break
    if s.get("status") in ("FAILED", "ERROR"):
        raise RuntimeError(f"tripo failed: {s}")
if res is None:
    raise TimeoutError("tripo timed out")

print("response keys:", json.dumps({k: type(v).__name__ for k, v in res.items()}))
urls = []
find_urls(res, urls)
print("urls found:", urls)
glb_url = next((u for u in urls if ".glb" in u.lower()), None) or (urls[0] if urls else None)
if not glb_url:
    raise RuntimeError("no url in response: " + json.dumps(res)[:2000])

for i in range(4):
    try:
        data = requests.get(glb_url, timeout=600).content
        break
    except Exception as e:
        if i == 3:
            raise
        print(f"retry {i + 1}: {type(e).__name__}")
        time.sleep(5 * (i + 1))
DST.write_bytes(data)
print(f"saw_a.glb replaced ({len(data)//1024} KB)")
print("ALL DONE")
