"""
GLB texture shrinker (permanent pipeline tool, extracted 2026-07-09).
Downscales every embedded image to <=MAX_PX and re-encodes it in the format
the GLB DECLARES (mimeType) — Blender exports carry image/webp via
EXT_texture_webp, Tripo ships PNG; feeding Godot bytes that don't match the
declared mime fails with ERR_FILE_CORRUPT. Buffer is rebuilt surgically:
meshes, materials, animations untouched.
Usage: python glb_shrink.py <file-or-dir> [more...]
"""
import io, json, struct, sys
from pathlib import Path
from PIL import Image

MAX_PX = 512
JSON_CT, BIN_CT = 0x4E4F534A, 0x004E4942


def encode(im: Image.Image, mime: str) -> bytes:
    buf = io.BytesIO()
    if mime == "image/webp":
        im.save(buf, "WEBP", quality=92)
    elif mime == "image/jpeg":
        im.convert("RGB").save(buf, "JPEG", quality=90)
    else:
        im.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def shrink(path: Path) -> tuple[int, int, int]:
    raw = path.read_bytes()
    magic, ver, _ = struct.unpack_from("<III", raw, 0)
    assert magic == 0x46546C67 and ver == 2, f"not a GLB2: {path.name}"
    off, gltf, bin_data = 12, None, b""
    while off < len(raw):
        clen, ctype = struct.unpack_from("<II", raw, off)
        chunk = raw[off + 8:off + 8 + clen]
        if ctype == JSON_CT:
            gltf = json.loads(chunk)
        elif ctype == BIN_CT:
            bin_data = chunk
        off += 8 + clen

    views = gltf.get("bufferViews", [])
    replaced, n_img = {}, 0
    for img in gltf.get("images", []):
        vi = img.get("bufferView")
        if vi is None:
            continue
        v = views[vi]
        s = v.get("byteOffset", 0)
        data = bin_data[s:s + v["byteLength"]]
        im = Image.open(io.BytesIO(data))
        mime = img.get("mimeType", "image/png")
        if max(im.size) <= MAX_PX:
            continue
        im = im.resize((min(im.size[0], MAX_PX), min(im.size[1], MAX_PX)), Image.LANCZOS)
        replaced[vi] = encode(im, mime)
        n_img += 1

    if not replaced:
        return path.stat().st_size, path.stat().st_size, 0

    out = bytearray()
    for i, v in enumerate(views):
        s = v.get("byteOffset", 0)
        data = replaced.get(i, bin_data[s:s + v["byteLength"]])
        while len(out) % 4:
            out.append(0)
        v["byteOffset"] = len(out)
        v["byteLength"] = len(data)
        out += data
    gltf["buffers"][0]["byteLength"] = len(out)

    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    bn = bytes(out) + b"\0" * (-len(out) % 4)
    total = 12 + 8 + len(js) + 8 + len(bn)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), JSON_CT) + js)
        f.write(struct.pack("<II", len(bn), BIN_CT) + bn)
    return len(raw), total, n_img


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        p = Path(arg)
        files = sorted(p.rglob("*.glb")) if p.is_dir() else [p]
        for f in files:
            b, a, n = shrink(f)
            print(f"{b/1048576:6.1f} -> {a/1048576:5.1f} MB  ({n} imgs)  {f.name}")
