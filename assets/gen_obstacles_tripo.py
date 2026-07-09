"""
Obstacle production run (Stefan picked concepts 3/5/7/9/10 from the board,
2026-07-09): Tripo image-to-3d from the approved concept renders.
  grid_upheaval     -> sp_rift        static_tree -> sp_storm
  firewall_shard    -> sp_firewall    corrupted_bloom -> sp_bloom
  singularity_spire -> sp_spire
GLBs land in assets/3d/, embedded textures auto-shrunk to <=512 (glb_shrink),
concept sources copied to 3d/src/ for provenance.
"""
import base64, io, os, shutil, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).parent))
from glb_shrink import shrink

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
TRIPO = "https://queue.fal.run/tripo3d/h3.1/image-to-3d"
SRC = ROOT / "workspace/2026-07-09_exonix-obstacle-concepts/images"
OUT = Path(__file__).parent / "3d"

PICKS = {
    "sp_rift": "grid_upheaval.webp",
    "sp_storm": "static_tree.webp",
    "sp_firewall": "firewall_shard.webp",
    "sp_bloom": "corrupted_bloom.webp",
    "sp_spire": "singularity_spire.webp",
}


def data_uri(b: bytes, mime: str) -> str:
    return f"data:{mime};base64," + base64.b64encode(b).decode()


def fetch(url, tries=4):
    for i in range(tries):
        try:
            return requests.get(url, timeout=600).content
        except Exception as e:
            if i == tries - 1:
                raise
            print(f"  retry {i + 1}: {type(e).__name__}")
            time.sleep(5 * (i + 1))


def model_url(res: dict) -> str:
    u = (res.get("model_mesh") or {}).get("url")
    if u:
        return u
    urls = res.get("model_urls") or {}
    return urls.get("glb") or urls.get("pbr_model") or urls.get("base_model")


only = sys.argv[1] if len(sys.argv) > 1 else ""
todo = {k: v for k, v in PICKS.items() if only in k}
jobs = []
for name, img_file in todo.items():
    img = (SRC / img_file).read_bytes()
    r = requests.post(TRIPO, headers=H, json={
        "image_url": data_uri(img, "image/webp"),
        "texture": True, "pbr": True,
        "texture_quality": "detailed", "geometry_quality": "detailed",
        "face_limit": 15000,
    })
    r.raise_for_status()
    j = r.json()
    jobs.append({"name": name, "src": img_file, "s": j["status_url"], "r": j["response_url"]})
    print("queued", name)

done = {}
end = time.time() + 2400
while len(done) < len(jobs) and time.time() < end:
    time.sleep(10)
    for j in jobs:
        if j["name"] in done:
            continue
        st = requests.get(j["s"], headers=H).json()
        if st.get("status") == "COMPLETED":
            res = requests.get(j["r"], headers=H).json()
            url = model_url(res)
            if not url:
                done[j["name"]] = False
                print("  NO URL", j["name"], list(res.keys()))
                continue
            p = OUT / f"{j['name']}.glb"
            p.write_bytes(fetch(url))
            b, a, n = shrink(p)
            shutil.copy(SRC / j["src"], OUT / "src" / f"{j['name']}.webp")
            done[j["name"]] = True
            print(f"  ok {j['name']}: {b//1024}KB -> {a//1024}KB ({n} imgs shrunk)")
        elif st.get("status") in ("FAILED", "ERROR"):
            done[j["name"]] = False
            print("  FAIL", j["name"], st)
fails = [k for k, v in done.items() if not v]
print("FAILED:", fails if fails else "none")
print("ALL DONE")
