"""
Gloss pass (Stefan 2026-07-09): ALL surfaces — captured and uncaptured — more
polished: roughness band remapped [0.10..0.45] -> [0.06..0.28] (keeps each
map's pattern, everything reflects more), metalness lifted to >= 0.90.
ONE-SHOT over the existing lossless maps; gen_pbr_lossless.py now bakes the
same band for future regenerations. Lossless webp in, lossless webp out.
"""
import io, sys
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
from PIL import Image

OUT = Path(__file__).parent
SETS = ["claim_v4_1", "claim_v4_2", "claim_v4_3", "claim_v4_4", "claim_v4_5",
        "claim_c1", "claim_c2", "claim_c3", "claim_c4", "claim_c5",
        "unclaimed_A", "unclaimed_B", "unclaimed_C", "unclaimed_D", "unclaimed_E"]
OLD_LO, OLD_HI = 0.10, 0.45
NEW_LO, NEW_HI = 0.06, 0.28
METAL = 0.60   # 0.90 killed the diffuse -> too dark in game

for s in SETS:
    rp = OUT / s / "roughness.webp"
    mp = OUT / s / "metalness.webp"
    if not rp.exists():
        continue
    r = np.asarray(Image.open(rp).convert("L")).astype(np.float32) / 255.0
    r = NEW_LO + (r - OLD_LO) * (NEW_HI - NEW_LO) / (OLD_HI - OLD_LO)
    r = np.clip(r, 0.04, 0.30)
    Image.fromarray((r * 255).astype(np.uint8)).save(rp, "WEBP", lossless=True, quality=100)
    m = np.asarray(Image.open(mp).convert("L")).astype(np.float32) / 255.0
    m = np.maximum(m, METAL)
    Image.fromarray((m * 255).astype(np.uint8)).save(mp, "WEBP", lossless=True, quality=100)
    print(f"{s}: rough {r.min():.2f}-{r.max():.2f}, metal >= {m.min():.2f}")
print("DONE")
