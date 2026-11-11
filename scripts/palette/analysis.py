"""Reading a picture for the palette engine (engine.py composes from it).

The picture shrunk to some 64 000 pixels (a JPEG decoded at 1/2–1/8 straight
away, a video's frame a second in through ffmpeg) and read twice:

tones     a weighted k-means in OKLab over a 15-bit colour histogram – what
          the picture is made of, light and dark; the middle counts a little
          more than the edges
spectrum  the chromatic pixels by hue, 10° a bin, each with its mean hue,
          its lightness and how vivid it gets (the 75th percentile of
          chroma); vivid pixels count more, a hue is what one notices, not
          what covers most

and a few numbers about the whole. Small, kept as JSON per media.
"""

from __future__ import annotations

import math
import subprocess
from pathlib import Path

import numpy as np

from version import ANALYSIS_VERSION

SAMPLE_PIXELS = 64_000
TONE_CLUSTERS = 12
HUE_BINS = 36
# below this chroma a pixel says nothing about hue
CHROMATIC = 0.035

VIDEO_SUFFIXES = {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".gif"}


def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(np.maximum(c, 0), 1 / 2.4) - 0.055)


_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]])
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])


def rgb_to_oklab(rgb):
    """sRGB (…, 3) in 0..1 to OKLab."""
    lms = srgb_to_linear(rgb) @ _M1.T
    return np.cbrt(lms) @ _M2.T


# ── reading the picture ──────────────────────────────────────────────────

def _ffmpeg_pixels(path: Path, width: int, video: bool):
    def run(seek):
        cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error"]
        if seek:
            cmd += ["-ss", "00:00:01"]
        cmd += ["-i", str(path), "-frames:v", "1", "-vf", f"scale={width}:-2:flags=area",
                "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
        out = subprocess.run(cmd, capture_output=True, timeout=60)
        return out.stdout if out.returncode == 0 else b""

    data = run(True) if video else b""
    if not data:
        data = run(False)
    if not data:
        raise ValueError(f"cannot read {path}")
    return np.frombuffer(data, dtype=np.uint8).reshape(-1, width, 3)


def load_pixels(path: Path) -> np.ndarray:
    """The picture (or a video's frame a second in) as an (h, w, 3) uint8
    array of about SAMPLE_PIXELS pixels."""
    if path.suffix.lower() not in VIDEO_SUFFIXES:
        try:
            from PIL import Image

            with Image.open(path) as im:
                w, h = im.size
                scale = math.sqrt(SAMPLE_PIXELS / max(1, w * h))
                target = (max(1, round(w * scale)), max(1, round(h * scale)))
                # a JPEG is decoded at 1/2, 1/4 or 1/8 straight away
                im.draft("RGB", (target[0] * 2, target[1] * 2))
                im = im.convert("RGB")
                if im.size != target:
                    im = im.resize(target, Image.Resampling.BOX, reducing_gap=2.0)
                return np.asarray(im)
        except Exception:
            pass
    # videos, and whatever Pillow cannot open
    return _ffmpeg_pixels(path, 320, True)


# ── analysis ──────────────────────────────────────────────────────────────

def _kmeans(points, weights, k, iterations=14):
    """Weighted k-means, seeded the k-means++ way but deterministically
    (the heaviest point first, then the farthest weighted ones)."""
    k = min(k, len(points))
    centers = [points[int(np.argmax(weights))]]
    dist = np.sum((points - centers[0]) ** 2, axis=1)
    for _ in range(1, k):
        idx = int(np.argmax(dist * weights))
        centers.append(points[idx])
        dist = np.minimum(dist, np.sum((points - points[idx]) ** 2, axis=1))
    centers = np.array(centers)
    for _ in range(iterations):
        d = ((points[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2)
        label = np.argmin(d, axis=1)
        moved = False
        for i in range(k):
            m = label == i
            w = weights[m]
            if w.sum() <= 0:
                continue
            c = (points[m] * w[:, None]).sum(axis=0) / w.sum()
            if np.any(np.abs(c - centers[i]) > 1e-5):
                moved = True
            centers[i] = c
        if not moved:
            break
    d = ((points[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2)
    label = np.argmin(d, axis=1)
    mass = np.bincount(label, weights=weights, minlength=k)
    return centers, mass


def analyse_pixels(pixels: np.ndarray) -> dict:
    h, w, _ = pixels.shape
    flat = pixels.reshape(-1, 3).astype(np.int64)

    # what lies near the middle counts a little more than the edges
    yy, xx = np.mgrid[0:h, 0:w]
    dx = (xx / max(1, w - 1) - 0.5) * 2
    dy = (yy / max(1, h - 1) - 0.5) * 2
    center = (1.0 + 0.6 * np.exp(-(dx ** 2 + dy ** 2) / 0.6)).reshape(-1)

    # 15-bit histogram: each bin's mean colour and its weight
    q = ((flat[:, 0] >> 3) << 10) | ((flat[:, 1] >> 3) << 5) | (flat[:, 2] >> 3)
    mass = np.bincount(q, weights=center, minlength=32768)
    used = np.nonzero(mass)[0]
    sums = np.stack([np.bincount(q, weights=flat[:, c] * center, minlength=32768)[used] for c in range(3)], axis=1)
    bin_rgb = sums / mass[used][:, None] / 255.0
    bin_w = mass[used] / mass[used].sum()
    bin_lab = rgb_to_oklab(bin_rgb)

    # tones
    centers, cmass = _kmeans(bin_lab, bin_w, TONE_CLUSTERS)
    order = np.argsort(-cmass)
    tones = [[round(float(v), 5) for v in centers[i]] + [round(float(cmass[i]), 5)]
             for i in order if cmass[i] > 0.002]

    # hue spectrum of the chromatic bins
    L, a, b = bin_lab[:, 0], bin_lab[:, 1], bin_lab[:, 2]
    C = np.hypot(a, b)
    hue = np.degrees(np.arctan2(b, a)) % 360
    chroma_mask = C > CHROMATIC
    spectrum = []
    total_chromatic = float(bin_w[chroma_mask].sum())
    if chroma_mask.any():
        # vivid pixels count more: a hue is what you notice, not what covers most
        cw = bin_w * np.minimum(C / 0.12, 2.0)
        index = (hue // (360 / HUE_BINS)).astype(int) % HUE_BINS
        for i in range(HUE_BINS):
            m = chroma_mask & (index == i)
            if not m.any():
                spectrum.append([i * 10 + 5, 0.0, 0.0, 0.0])
                continue
            ww = cw[m]
            # the circular mean hue of the bin, its weighted lightness, and
            # how vivid it gets (the 75th weighted percentile of chroma)
            hr = np.radians(hue[m])
            hmean = math.degrees(math.atan2(float((np.sin(hr) * ww).sum()), float((np.cos(hr) * ww).sum()))) % 360
            lmean = float((L[m] * ww).sum() / ww.sum())
            cs = np.argsort(C[m])
            cum = np.cumsum(ww[cs]) / ww.sum()
            c75 = float(C[m][cs][min(len(cs) - 1, int(np.searchsorted(cum, 0.75)))])
            spectrum.append([round(hmean, 2), float(ww.sum()), round(lmean, 4), round(c75, 4)])
        total = sum(s[1] for s in spectrum) or 1.0
        for s in spectrum:
            s[1] = round(s[1] / total, 5)
    else:
        spectrum = [[i * 10 + 5, 0.0, 0.0, 0.0] for i in range(HUE_BINS)]

    Ls = np.sort(L)
    cum = np.cumsum(bin_w[np.argsort(L)])

    def lq(p):
        return round(float(Ls[min(len(Ls) - 1, int(np.searchsorted(cum, p)))]), 4)

    return {
        "version": ANALYSIS_VERSION,
        "tones": tones,
        "spectrum": spectrum,
        "stats": {
            "lightness": round(float((L * bin_w).sum()), 4),
            "dark": lq(0.1),
            "light": lq(0.9),
            "chroma": round(float((C * bin_w).sum()), 4),
            "chromatic": round(total_chromatic, 4),
        },
    }


def analyse(path: Path) -> dict:
    return analyse_pixels(load_pixels(path))
