"""
QIX — PBR texture sets via fal.ai PATINA (image -> full map set).
Inputs: the 4 approved surface textures (workspace surfaces_v2 PNG originals).
Output: assets/textures/<material>/<map_type>.webp  (basecolor/normal/roughness/metalness/height)
Endpoint: queue.fal.run/fal-ai/patina  (image_url as base64 data URI, no prompt needed)
"""
import base64, io, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[4]  # C:/GIT/mr-mak
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
ENDPOINT = "https://queue.fal.run/fal-ai/patina"
SRC = ROOT / "workspace/2026-07-06_qix-territory-reveal/surfaces_v2"
OUT = Path(__file__).parent

MATERIALS = {
    "claim_L1_grid": "claim_L1_grid.png",
    "claim_L2_industrial": "claim_L2_industrial.png",
    "claim_L3_unstable": "claim_L3_unstable.png",
    "unclaimed_A": "unclaimed_A.png",
}
MAPS = ["basecolor", "normal", "roughness", "metalness", "height"]


def data_uri(p: Path) -> str:
    return "data:image/png;base64," + base64.b64encode(p.read_bytes()).decode()


def submit(name, src_file):
    payload = {
        "image_url": data_uri(SRC / src_file),
        "maps": MAPS,
        "output_format": "webp",
    }
    r = requests.post(ENDPOINT, headers=H, json=payload)
    r.raise_for_status()
    j = r.json()
    return {"name": name, "status_url": j["status_url"], "response_url": j["response_url"]}


def main():
    jobs = [submit(n, f) for n, f in MATERIALS.items()]
    print(f"Submitted {len(jobs)} PATINA jobs")
    done = {}
    deadline = time.time() + 900
    while len(done) < len(jobs) and time.time() < deadline:
        time.sleep(6)
        for j in jobs:
            if j["name"] in done:
                continue
            s = requests.get(j["status_url"], headers=H).json()
            if s.get("status") == "COMPLETED":
                res = requests.get(j["response_url"], headers=H).json()
                mat_dir = OUT / j["name"]
                mat_dir.mkdir(exist_ok=True)
                for img in res.get("images", []):
                    mt = img.get("map_type") or "image"
                    data = requests.get(img["url"]).content
                    (mat_dir / f"{mt}.webp").write_bytes(data)
                    print(f"  {j['name']}/{mt}.webp ({len(data)//1024} KB)")
                done[j["name"]] = True
            elif s.get("status") in ("FAILED", "ERROR"):
                done[j["name"]] = False
                print(f"  FAIL {j['name']}: {s}")
    for j in jobs:
        if j["name"] not in done:
            print(f"  ? {j['name']} timed out")
    print("done")


if __name__ == "__main__":
    main()
