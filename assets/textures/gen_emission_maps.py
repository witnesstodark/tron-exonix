"""
QIX — emission maps via Nano Banana Pro EDIT.
Input: each material's PATINA basecolor (so the emission aligns with the set).
Instruction: keep only self-glowing elements at full brightness on pure black.
Output: assets/textures/<material>/emission.webp
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
ENDPOINT = "https://queue.fal.run/fal-ai/nano-banana-pro/edit"
OUT = Path(__file__).parent

GLOW = {
    "claim_L1_grid": "the thin glowing cyan circuit seams and lines",
    "claim_L2_industrial": "the glowing cyan hazard strips, vents glow and panel edge lights",
    "claim_L3_unstable": "the glowing cyan fault-line cracks and small white hot-spots",
    "unclaimed_A": "the dim glowing blood-red circuit lines and nodes",
}

PROMPT = ("Convert this game floor texture into its EMISSION MAP: output the exact same image where ONLY {} "
          "remain visible, at full brightness and in their original color, on a PURE BLACK background. "
          "Keep every glowing line and shape in its exact position, scale and thickness — pixel-aligned with "
          "the input. Remove all non-glowing surface detail completely. Flat map, no lighting, no vignette, no text.")


def data_uri(p: Path) -> str:
    return "data:image/webp;base64," + base64.b64encode(p.read_bytes()).decode()


def submit(name):
    payload = {
        "prompt": PROMPT.format(GLOW[name]),
        "image_urls": [data_uri(OUT / name / "basecolor.webp")],
        "num_images": 1,
    }
    r = requests.post(ENDPOINT, headers=H, json=payload)
    r.raise_for_status()
    j = r.json()
    return {"name": name, "status_url": j["status_url"], "response_url": j["response_url"]}


def main():
    names = sys.argv[1:] or list(GLOW)
    jobs = [submit(n) for n in names if n in GLOW]
    print(f"Submitted {len(jobs)} emission jobs")
    done = {}
    deadline = time.time() + 720
    while len(done) < len(jobs) and time.time() < deadline:
        time.sleep(6)
        for j in jobs:
            if j["name"] in done:
                continue
            s = requests.get(j["status_url"], headers=H).json()
            if s.get("status") == "COMPLETED":
                res = requests.get(j["response_url"], headers=H).json()
                url = res["images"][0]["url"]
                raw = requests.get(url).content
                img = Image.open(io.BytesIO(raw)).convert("RGB")
                dst = OUT / j["name"] / "emission.webp"
                img.save(dst, "WEBP", quality=92)
                done[j["name"]] = True
                print(f"  {j['name']}/emission.webp ({dst.stat().st_size//1024} KB, {img.size[0]}x{img.size[1]})")
            elif s.get("status") in ("FAILED", "ERROR"):
                done[j["name"]] = False
                print(f"  FAIL {j['name']}: {s}")
    for j in jobs:
        if j["name"] not in done:
            print(f"  ? {j['name']} timed out")
    print("done")


if __name__ == "__main__":
    main()
