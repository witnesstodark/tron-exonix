"""
Basecolor/emission de-noise — kill lossy-webp block mottling, keep the design
(Stefan 2026-07-09: 'pixelization' on L1 claimed floor, worst in game where
albedo_mul 1.6 + gloss amplify it). Both maps came out of generation as
heavily-quantized lossy webp (basecolors as small as 5-7KB/1024^2).

basecolor: selective smoothing — pixels that differ little from a 2px blur are
flat-field block noise and take the blurred value; strong features (seams,
arcs, veins) differ a lot and stay crisp.
emission:  everything darker than the noise floor goes to true black; the
glowing lines themselves are untouched.
Both saved back LOSSLESS webp. Idempotent; run any time. CLI arg = set filter.
"""
import io, sys
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
from PIL import Image, ImageFilter

OUT = Path(__file__).parent
SETS = ["claim_v4_1", "claim_v4_2", "claim_v4_3", "claim_v4_4", "claim_v4_5",
        "claim_c1", "claim_c2", "claim_c3", "claim_c4", "claim_c5",
        "unclaimed_A", "unclaimed_B", "unclaimed_C", "unclaimed_D", "unclaimed_E"]
FLAT_T = 10        # |pixel - blur| below this = block noise -> smoothed
EMIT_FLOOR = 12    # emission channel max below this = noise -> pure black

only = sys.argv[1] if len(sys.argv) > 1 else ""
for s in [x for x in SETS if only in x]:
    bc_p = OUT / s / "basecolor.webp"
    em_p = OUT / s / "emission.webp"
    if not bc_p.exists():
        continue
    im = Image.open(bc_p).convert("RGB")
    a = np.asarray(im).astype(np.int16)
    blur = np.asarray(im.filter(ImageFilter.GaussianBlur(2.0))).astype(np.int16)
    diff = np.abs(a - blur).max(axis=2, keepdims=True)
    out = np.where(diff < FLAT_T, blur, a).astype(np.uint8)
    flat_pct = 100.0 * (diff < FLAT_T).mean()
    before = bc_p.stat().st_size // 1024
    Image.fromarray(out).save(bc_p, "WEBP", lossless=True, quality=100)

    e = np.asarray(Image.open(em_p).convert("RGB")).astype(np.uint8)
    dark = e.max(axis=2, keepdims=True) < EMIT_FLOOR
    e = np.where(dark, 0, e).astype(np.uint8)
    dark_pct = 100.0 * dark.mean()
    Image.fromarray(e).save(em_p, "WEBP", lossless=True, quality=100)
    print(f"{s}: basecolor {before}KB->{bc_p.stat().st_size // 1024}KB ({flat_pct:.0f}% smoothed), "
          f"emission floor-cleaned ({dark_pct:.0f}% true black), both lossless")
print("DONE")
