import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUTS = [
    ("icon", "materials/entities/evil_crawler.png", (128, 128)),
    ("icon_loose", "materials/entities/evil_crawler_loose.png", (128, 128)),
    ("thumbnail", "workshop/thumbnail.jpg", (512, 512)),
    ("preview_floor", "workshop/preview_floor.jpg", None),
    ("preview_ceiling", "workshop/preview_ceiling.jpg", None),
]

renders = sys.argv[1]
for shot, path, size in OUTPUTS:
    im = Image.open(os.path.join(renders, shot + ".png")).convert("RGB")
    if size:
        im = im.resize(size, Image.LANCZOS)
    out = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if out.endswith(".jpg"):
        im.save(out, quality=92, optimize=True)
    else:
        im.save(out, optimize=True)
    print("%s  %dx%d  %d KB" % (path, im.width, im.height, os.path.getsize(out) // 1024))
