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
KILLICON_HEIGHT = 48

renders = sys.argv[1]

alpha = Image.open(os.path.join(renders, "killicon.png")).getchannel("A")
alpha = alpha.crop(alpha.getbbox())
alpha = alpha.resize((round(alpha.width * KILLICON_HEIGHT / alpha.height), KILLICON_HEIGHT), Image.LANCZOS)
icon = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
icon.putalpha(alpha)
out = os.path.join(ROOT, "materials/killicons/evil_crawler.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
icon.save(out, optimize=True)
print("materials/killicons/evil_crawler.png  %dx%d" % icon.size)

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
