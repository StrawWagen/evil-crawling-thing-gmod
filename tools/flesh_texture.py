# /// script
# dependencies = ["numpy", "pillow"]
# ///
import os

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "materials", "evil_crawler", "flesh.png")
PREVIEW = os.path.join(ROOT, "renders", "flesh_preview.png")
W, H = 256, 512
SEED = 7

MUSCLE = np.array([236, 214, 212])
FIBER = np.array([168, 120, 126])
VEIN = np.array([92, 52, 98])
FASCIA = np.array([255, 244, 232])
PIT = np.array([70, 36, 44])
BRUISE = np.array([120, 62, 62])
TINT = np.array([92, 34, 38])

rng = np.random.default_rng(SEED)
fy = np.fft.fftfreq(H)[:, None] * H
fx = np.fft.fftfreq(W)[None, :] * W


def band(across, along, falloff=2.0):
    k = np.sqrt((fx / across) ** 2 + (fy / along) ** 2)
    spectrum = np.exp(-(k ** falloff))
    spectrum[0, 0] = 0
    noise = np.fft.fft2(rng.standard_normal((H, W)))
    field = np.real(np.fft.ifft2(noise * spectrum))
    return field / field.std()


def sample(field, x, y):
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    tx, ty = x - x0, y - y0
    x0, y0 = x0 % W, y0 % H
    x1, y1 = (x0 + 1) % W, (y0 + 1) % H
    top = field[y0, x0] * (1 - tx) + field[y0, x1] * tx
    bottom = field[y1, x0] * (1 - tx) + field[y1, x1] * tx
    return top * (1 - ty) + bottom * ty


def warp(field, amount, across, along):
    yy, xx = np.mgrid[0:H, 0:W].astype(float)
    return sample(field, xx + band(across, along) * amount, yy + band(across, along) * amount)


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


mottle = band(3, 3) * 0.6 + band(9, 9) * 0.4
bundles = warp(band(10, 0.9), 3, 3, 1.5)
fibers = warp(band(90, 2.5, 1.2), 1.5, 6, 3)
veins = warp(band(2.5, 0.8), 5, 3, 2)
twigs = warp(band(8, 3), 3, 8, 6)
fascia = warp(band(5, 0.9), 3, 4, 2)
pits = band(60, 40)

cord = smooth(0.0, 1.1, np.abs(bundles))
vein = np.exp(-(veins / 0.07) ** 2) * smooth(-0.6, 0.6, band(2, 1.5))
twig = np.exp(-(twigs / 0.05) ** 2) * smooth(0.4, 1.4, band(3, 3)) * 0.5
vein = np.clip(vein + twig, 0, 1)
sheet = smooth(1.4, 2.2, fascia) * 0.6
pit = smooth(2.7, 3.4, pits)
fiber = smooth(-1.4, 1.8, fibers)
bruise = smooth(0.2, 1.8, mottle)

col = MUSCLE[None, None, :] * (0.45 + 0.55 * cord[..., None])
col = col * (1 - 0.3 * fiber[..., None]) + FIBER * 0.3 * fiber[..., None]
col = col * (1 - 0.4 * bruise[..., None]) + BRUISE * 0.4 * bruise[..., None]
col = col * (1 - sheet[..., None]) + FASCIA * (0.6 + 0.4 * cord[..., None]) * sheet[..., None]
col = col * (1 - vein[..., None]) + VEIN * vein[..., None]
col = col * (1 - pit[..., None]) + PIT * pit[..., None]
col = np.clip(col, 0, 255).astype(np.uint8)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
Image.fromarray(col, "RGB").save(OUT, optimize=True)

tinted = np.clip(col.astype(float) * TINT / 255 * 2.2, 0, 255).astype(np.uint8)
tiled = np.vstack([np.hstack([tinted] * 2)] * 2)
Image.fromarray(np.hstack([np.vstack([col] * 2), tiled]), "RGB").save(PREVIEW)
print(OUT, col.reshape(-1, 3).mean(0).round(1))
