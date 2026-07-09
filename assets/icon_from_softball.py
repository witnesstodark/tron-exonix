"""
TRON: EXONIX icon v2 — Stefan's pick: JUST the soft ball, no border, transparent
background. Source: assets/3d/src/ball_soft.png (clean render on flat dark bg).
Cut the sphere with a feathered circular mask + add a soft cyan halo, 256px RGBA.
"""
import io, sys
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SRC = Path(__file__).parent / "3d" / "src" / "ball_soft.png"
DST = Path(__file__).parent.parent / "game" / "icon.png"

img = Image.open(SRC).convert("RGB")
a = np.asarray(img).astype(np.int32)

# background = the corner color; the ball is everything far from it
bg = a[3, 3]
dist = np.abs(a - bg).sum(axis=2)
mask = dist > 60
ys, xs = np.where(mask)
cx, cy = (xs.min() + xs.max()) / 2.0, (ys.min() + ys.max()) / 2.0
r = max(xs.max() - xs.min(), ys.max() - ys.min()) / 2.0
print(f"ball: center=({cx:.0f},{cy:.0f}) r={r:.0f}")

# square crop with halo headroom
S = int(r * 2.5)
box = (int(cx - S / 2), int(cy - S / 2), int(cx + S / 2), int(cy + S / 2))
ball = img.crop(box)

W = ball.size[0]
ccx = ccy = W / 2.0

# feathered disc alpha for the ball itself
alpha = Image.new("L", (W, W), 0)
d = ImageDraw.Draw(alpha)
d.ellipse([ccx - r, ccy - r, ccx + r, ccy + r], fill=255)
alpha = alpha.filter(ImageFilter.GaussianBlur(2.5))

# soft cyan halo underneath (like the reference aura), fading to nothing
halo = Image.new("RGBA", (W, W), (0, 0, 0, 0))
hd = ImageDraw.Draw(halo)
steps = 48
for i in range(steps, 0, -1):
    rr = r * (1.0 + 0.5 * i / steps)
    aa = int(70 * (1.0 - i / steps) ** 2)
    hd.ellipse([ccx - rr, ccy - rr, ccx + rr, ccy + rr], fill=(90, 220, 255, aa))
halo = halo.filter(ImageFilter.GaussianBlur(6))

out = halo.copy()
ball_rgba = ball.convert("RGBA")
ball_rgba.putalpha(alpha)
out.alpha_composite(ball_rgba)
out = out.resize((256, 256), Image.LANCZOS)
out.save(DST, optimize=True)
print(f"icon.png written ({DST.stat().st_size // 1024} KB, 256px RGBA transparent)")
