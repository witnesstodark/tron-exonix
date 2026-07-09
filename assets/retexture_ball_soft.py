"""
Soft ball redo: clean Blender UV-sphere GLB -> Tripo texture-edit (3D AI Studio)
with our soft-ball reference image. Steps: fal storage upload (public URL) ->
texture-edit (image reference passed via extras; prompt as fallback signal) ->
poll -> download over assets/3d/ball_soft.glb.
"""
import base64, io, os, sys, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")
load_dotenv(Path.home() / ".claude/skills/3d-ai-studio-api/.env")
FAL_KEY = os.environ["FALAI_KEY"]
S3D_KEY = os.environ["3D_AI_STUDIO_API_KEY"]
S3D = os.environ.get("3D_AI_STUDIO_API_URL", "https://api.3daistudio.com/v1").rstrip("/")
S3D_H = {"Authorization": f"Bearer {S3D_KEY}", "Content-Type": "application/json"}

HERE = Path(__file__).parent
SPHERE = HERE / "3d/src/sphere_base.glb"
REF = HERE / "3d/src/ball_soft.png"
DST = HERE / "3d/ball_soft.glb"

PROMPT = ("Smooth glossy translucent cyan-blue energy orb: clean glass-like surface, soft white "
          "inner-glow core, gentle top highlight, subtle darker blue at the bottom, seamless "
          "gradient, no patterns, no seams, no text. Matches the provided reference sphere.")


def fal_upload(path: Path) -> str:
    r = requests.post("https://rest.fal.ai/storage/upload/initiate",
                      headers={"Authorization": f"Key {FAL_KEY}", "Content-Type": "application/json"},
                      json={"file_name": path.name, "content_type": "model/gltf-binary"})
    r.raise_for_status()
    j = r.json()
    up, url = j.get("upload_url"), j.get("file_url")
    if not up or not url:
        raise RuntimeError(f"unexpected initiate response: {j}")
    put = requests.put(up, data=path.read_bytes(), headers={"Content-Type": "model/gltf-binary"})
    put.raise_for_status()
    return url


def texture_edit(file_url: str, with_image: bool) -> str:
    payload = {"file_url": file_url, "prompt": PROMPT, "pbr": True, "texture_quality": "detailed"}
    if with_image:
        payload["image"] = "data:image/png;base64," + base64.b64encode(REF.read_bytes()).decode()
    r = requests.post(f"{S3D}/3d-models/tripo/texture-edit/", headers=S3D_H, json=payload)
    if r.status_code >= 400:
        raise RuntimeError(f"HTTP {r.status_code}: {r.text[:300]}")
    j = r.json()
    return j.get("task_id") or j.get("id") or j.get("request_id")


def wait_fetch(task_id: str) -> None:
    deadline = time.time() + 1200
    while time.time() < deadline:
        time.sleep(8)
        s = requests.get(f"{S3D}/generation-request/{task_id}/status/", headers=S3D_H).json()
        st = s.get("status")
        if st == "FINISHED":
            for res in (s.get("results") or []):
                url = res.get("asset")
                if url:
                    DST.write_bytes(requests.get(url, timeout=300).content)
                    print(f"ball_soft.glb ({DST.stat().st_size//1024} KB)")
                    return
            raise RuntimeError("finished, no asset url")
        if st == "FAILED":
            raise RuntimeError(f"FAILED: {s}")
    raise TimeoutError(task_id)


print("1/3 upload sphere...")
url = fal_upload(SPHERE)
print("  ", url)
print("2/3 texture-edit...")
try:
    tid = texture_edit(url, with_image=True)
    print("   task (with image ref):", tid)
except Exception as e:
    print("   image-ref payload rejected:", e)
    tid = texture_edit(url, with_image=False)
    print("   task (prompt only):", tid)
print("3/3 wait + fetch...")
wait_fetch(tid)
print("done")
