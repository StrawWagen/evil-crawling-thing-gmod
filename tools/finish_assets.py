import math
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUTS = [
    ("thumbnail", "workshop/thumbnail.jpg", (512, 512)),
    ("preview_floor", "workshop/preview_floor.jpg", None),
    ("preview_ceiling", "workshop/preview_ceiling.jpg", None),
]
KILLICON_HEIGHT = 48

# The suite's spawn icon tile. Keep in step with the fungus's tools/make_spawnicon.py.
SIZE = 128
INK = (226, 219, 207)
BG_IN = (42, 38, 41)
BG_OUT = (12, 11, 12)
BOX = (112, 84)
FLOOR = 104
CEILING = 24
ICONS = [
    ("materials/entities/evil_crawler.png", False),
    ("materials/entities/evil_crawler_loose.png", True),
]


def tile(alpha, hanging=False):
    """The silhouette fitted into the box, stood on the floor or hung from the ceiling."""
    alpha = alpha.crop(alpha.getbbox())
    k = min(BOX[0] / alpha.width, BOX[1] / alpha.height)
    alpha = alpha.resize((max(1, round(alpha.width * k)), max(1, round(alpha.height * k))), Image.LANCZOS)
    if hanging:
        alpha = alpha.transpose(Image.FLIP_TOP_BOTTOM)
    y = CEILING if hanging else FLOOR - alpha.height
    bg = Image.new("RGB", (SIZE, SIZE))
    px = bg.load()
    for j in range(SIZE):
        for i in range(SIZE):
            t = min(1, math.hypot(i - SIZE / 2, j - SIZE / 2) / (SIZE * 0.72)) ** 2
            px[i, j] = tuple(round(a + (b - a) * t) for a, b in zip(BG_IN, BG_OUT))
    bg.paste(Image.new("RGB", alpha.size, INK), ((SIZE - alpha.width) // 2, y), alpha)
    return bg


renders = sys.argv[1]

silhouette = Image.open(os.path.join(renders, "killicon.png")).getchannel("A")
alpha = silhouette.crop(silhouette.getbbox())
alpha = alpha.resize((round(alpha.width * KILLICON_HEIGHT / alpha.height), KILLICON_HEIGHT), Image.LANCZOS)
icon = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
icon.putalpha(alpha)
out = os.path.join(ROOT, "materials/killicons/evil_crawler.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
icon.save(out, optimize=True)
print("materials/killicons/evil_crawler.png  %dx%d" % icon.size)

for path, hanging in ICONS:
    out = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tile(silhouette, hanging).save(out, optimize=True)
    print("%s  %dx%d" % (path, SIZE, SIZE))

for shot, path, size in OUTPUTS:
    src = os.path.join(renders, shot + ".png")
    if not os.path.exists(src):
        print("%s  skipped, no %s render" % (path, shot))
        continue
    im = Image.open(src).convert("RGB")
    if size:
        im = im.resize(size, Image.LANCZOS)
    out = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if out.endswith(".jpg"):
        im.save(out, quality=92, optimize=True)
    else:
        im.save(out, optimize=True)
    print("%s  %dx%d  %d KB" % (path, im.width, im.height, os.path.getsize(out) // 1024))
