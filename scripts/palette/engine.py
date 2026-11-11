"""The Pshell palette engine: the colours of a picture, in any style.

analysis.py reads a picture once (its tones and its hue spectrum, kept as
JSON); compose() makes a scheme from that, without pixels and without numpy,
in a millisecond: background and text from the tones, the accents from the
spectrum's peaks, the sixteen terminal colours near their ANSI meaning but
drawn toward the picture, and the shell's roles.

Everything is done in OKLab / OKLCh, so lightness and chroma mean what they
look like, and every colour is mapped into sRGB by giving up chroma, never
hue.
"""

from __future__ import annotations

import math

from version import COMPOSE_VERSION  # noqa: F401


# ── colour math ───────────────────────────────────────────────────────────

def lch_to_lab(L, C, h):
    r = math.radians(h)
    return (L, C * math.cos(r), C * math.sin(r))


def lab_to_lch(lab):
    L, a, b = (float(v) for v in lab)
    return L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360


# OKLab back to linear sRGB (Björn Ottosson's inverse matrices)
_I2 = [[1.0, 0.3963377774, 0.2158037573],
       [1.0, -0.1055613458, -0.0638541728],
       [1.0, -0.0894841775, -1.2914855480]]
_I1 = [[4.0767416621, -3.3077115913, 0.2309699292],
       [-1.2684380046, 2.6097574011, -0.3413193965],
       [-0.0041960863, -0.7034186147, 1.7076147010]]


def _lab_to_linear(L, a, b):
    l_ = _I2[0][0] * L + _I2[0][1] * a + _I2[0][2] * b
    m_ = _I2[1][0] * L + _I2[1][1] * a + _I2[1][2] * b
    s_ = _I2[2][0] * L + _I2[2][1] * a + _I2[2][2] * b
    l3, m3, s3 = l_ ** 3, m_ ** 3, s_ ** 3
    return tuple(row[0] * l3 + row[1] * m3 + row[2] * s3 for row in _I1)


def _gamma(c):
    c = min(max(c, 0.0), 1.0)
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def _fits(L, C, h, eps=1e-4):
    return all(-eps <= v <= 1 + eps for v in _lab_to_linear(*lch_to_lab(L, C, h)))


def in_gamut(lab, eps=1e-4):
    return all(-eps <= v <= 1 + eps for v in _lab_to_linear(*(float(x) for x in lab)))


def lch_to_rgb(L, C, h):
    """OKLCh to sRGB 0..1; out of gamut the chroma gives way, the hue stays."""
    L = min(max(L, 0.0), 1.0)
    if not _fits(L, C, h):
        lo, hi = 0.0, C
        for _ in range(16):
            mid = (lo + hi) / 2
            if _fits(L, mid, h):
                lo = mid
            else:
                hi = mid
        C = lo
    return tuple(_gamma(v) for v in _lab_to_linear(*lch_to_lab(L, C, h)))


def _lin(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    return 0.2126 * _lin(rgb[0]) + 0.7152 * _lin(rgb[1]) + 0.0722 * _lin(rgb[2])


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def to_hex(rgb):
    return "#" + "".join(f"{round(float(v) * 255):02X}" for v in rgb)


def hue_distance(a, b):
    d = abs(a - b) % 360
    return min(d, 360 - d)


def hue_toward(h, target, amount):
    """h turned toward target by a share of the shortest arc."""
    d = ((target - h + 180) % 360) - 180
    return (h + d * amount) % 360


# ── composing ─────────────────────────────────────────────────────────────

# where the ANSI colours sit on the OKLCh wheel, and how much lighter or
# darker each wants to be than the others to look like itself
ANSI = [
    ("red", 27, -0.02),
    ("green", 145, 0.0),
    ("yellow", 95, 0.06),
    ("blue", 262, -0.04),
    ("magenta", 335, -0.01),
    ("cyan", 200, 0.02),
]
SIGNAL = {"danger": 25, "warning": 70, "success": 148}


def _peaks(spectrum):
    """The hues the picture has, strongest first: local maxima of the
    smoothed spectrum, each with the hue, lightness and chroma around it."""
    n = len(spectrum)
    w = [s[1] for s in spectrum]
    smooth = [w[i - 1] * 0.25 + w[i] * 0.5 + w[(i + 1) % n] * 0.25 for i in range(n)]
    peaks = []
    for i in range(n):
        if smooth[i] <= 0.004:
            continue
        if smooth[i] < smooth[(i - 1) % n] or smooth[i] < smooth[(i + 1) % n]:
            continue
        group = [spectrum[(i + d) % n] for d in (-1, 0, 1) if spectrum[(i + d) % n][1] > 0]
        tw = sum(g[1] for g in group)
        hx = sum(math.cos(math.radians(g[0])) * g[1] for g in group)
        hy = sum(math.sin(math.radians(g[0])) * g[1] for g in group)
        peaks.append({
            "hue": math.degrees(math.atan2(hy, hx)) % 360,
            "weight": smooth[i],
            "L": sum(g[2] * g[1] for g in group) / tw,
            "C": max(g[3] for g in group),
        })
    peaks.sort(key=lambda p: -(p["weight"] ** 0.6) * (min(p["C"], 0.25) / 0.12) ** 0.8)
    return peaks


def _accents(analysis, variety):
    """Up to six hues for the accents: the picture's peaks, at least
    `spread` apart; where it has fewer, more are found by turning the first
    around the wheel – as many as variety asks for."""
    peaks = _peaks(analysis["spectrum"])
    spread = 12 + variety * 48
    # how far from the first hue the others may lie: with no variety they
    # are its neighbours only
    reach = 25 + variety * 155
    chosen = []
    for p in peaks:
        if chosen and hue_distance(p["hue"], chosen[0]["hue"]) > reach:
            continue
        if all(hue_distance(p["hue"], c["hue"]) >= spread for c in chosen):
            chosen.append(dict(p, made=False))
        if len(chosen) == 6:
            break
    if not chosen:
        # a grey picture: its tones' faint tint, else a cool blue
        tone = max(analysis["tones"], key=lambda t: math.hypot(t[1], t[2]) * t[3], default=None)
        if tone and math.hypot(tone[1], tone[2]) > 0.006:
            L, C, h = lab_to_lch(tone[:3])
        else:
            L, C, h = 0.6, 0.05, 250.0
        chosen.append({"hue": h, "weight": 1.0, "L": L, "C": max(C, 0.04), "made": True})
    wanted = 1 + round(variety * 5)
    turns = [180, 120, -120, 60, -60, 150, -150, 30, -30]
    base = chosen[0]
    for turn in turns:
        if len(chosen) >= wanted:
            break
        h = (base["hue"] + turn) % 360
        if all(hue_distance(h, c["hue"]) >= spread * 0.8 for c in chosen):
            chosen.append({"hue": h, "weight": 0.0, "L": base["L"], "C": base["C"] * 0.8, "made": True})
    return chosen, peaks


def _readable(L, C, h, bg, minimum, dark):
    """The colour at L, or – where it does not read on bg with the given
    contrast – the nearest lightness toward white (on dark) or black (on
    light) that does."""
    rgb = lch_to_rgb(L, C, h)
    if contrast(rgb, bg) >= minimum:
        return rgb, L
    far = 1.0 if dark else 0.0
    if contrast(lch_to_rgb(far, C, h), bg) < minimum:
        return lch_to_rgb(far, C, h), far
    near = L
    for _ in range(14):
        mid = (near + far) / 2
        if contrast(lch_to_rgb(mid, C, h), bg) >= minimum:
            far = mid
        else:
            near = mid
    return lch_to_rgb(far, C, h), far


DEFAULTS = {
    # chroma: how vivid the accents are (×); lightness: their lightness, ±
    # around the mode's own; depth: how deep the background is, 0 near the
    # middle grey, 1 the deepest; tint: how much of the picture's colour the
    # background takes; contrast: the least WCAG contrast of every colour on
    # the background; variety: how far apart the accents' hues are, and how
    # far the terminal colours may leave their ANSI meaning (less = further)
    "chroma": 1.0,
    "lightness": 0.0,
    "depth": 0.6,
    "tint": 0.4,
    "contrast": 4.0,
    "variety": 0.5,
}


def compose(analysis: dict, params: dict, mode: str = "dark") -> dict:
    p = dict(DEFAULTS)
    p.update({k: float(v) for k, v in (params or {}).items() if k in DEFAULTS})
    dark = mode != "light"
    stats = analysis["stats"]
    accents, peaks = _accents(analysis, p["variety"])
    primary = accents[0]

    # background: the picture's dominant dark (or light) tone, its hue and a
    # share of its chroma, at the depth asked for
    tones = analysis["tones"] or [[0.3, 0, 0, 1]]
    if dark:
        pool = [t for t in tones if t[0] < 0.55] or tones
        L_bg = 0.30 - p["depth"] * 0.22
    else:
        pool = [t for t in tones if t[0] > 0.45] or tones
        L_bg = 0.90 + p["depth"] * 0.085
    tone = max(pool, key=lambda t: t[3])
    _, tC, th = lab_to_lch(tone[:3])
    if tC < 0.012:
        th, tC = primary["hue"], 0.02
    bg_chroma = min(tC, 0.07) * p["tint"] * (0.9 if dark else 0.55)
    bg = lch_to_rgb(L_bg, bg_chroma, th)
    bg_hue = th

    # text: nearly neutral, a breath of the background's hue
    fg = lch_to_rgb(0.95 if dark else 0.24, 0.012 if dark else 0.02, bg_hue)
    fg, _ = _readable(0.95 if dark else 0.24, 0.012, bg_hue, bg, 9.0, dark)
    fg_dim = lch_to_rgb(0.82 if dark else 0.36, 0.015, bg_hue)
    fg_dim, _ = _readable(0.82 if dark else 0.36, 0.015, bg_hue, bg, 6.0, dark)

    base_L = (0.74 if dark else 0.52) + p["lightness"]
    cmax = 0.30

    def accent(src, extra_L=0.0, chroma=None):
        L = base_L + extra_L + (src["L"] - 0.6) * 0.22
        L = min(max(L, 0.25), 0.95)
        C = min((chroma if chroma is not None else src["C"]) * p["chroma"], cmax)
        rgb, L = _readable(L, C, src["hue"], bg, p["contrast"], dark)
        return rgb, L, C

    roles = {}
    names = ["primary", "secondary", "tertiary"]
    picked = []
    for i, name in enumerate(names):
        src = accents[i] if i < len(accents) else dict(primary, L=primary["L"] + (0.08 if i % 2 else -0.08))
        rgb, L, C = accent(src, extra_L=0.0 if i == 0 else (0.03 if i == 1 else -0.02))
        roles[name] = rgb
        picked.append((src["hue"], L, C))
    on_primary = bg if contrast(roles["primary"], bg) >= contrast(roles["primary"], fg) else fg
    roles["on_primary"] = on_primary

    # danger, warning and success keep their meaning, turned a little toward
    # the primary so they belong to the picture
    signal_C = max(0.13, min(primary["C"] * p["chroma"], 0.22))
    for name, h in SIGNAL.items():
        hh = hue_toward(h, primary["hue"], 0.12)
        rgb, _ = _readable(base_L + (0.04 if name == "warning" else 0.0), signal_C, hh, bg, max(p["contrast"], 3.4), dark)
        roles[name] = rgb

    # the terminal's six: each ANSI hue drawn toward the nearest hue of the
    # picture (within 60°); the less variety, the further
    pull = 0.45 + (1 - p["variety"]) * 0.45
    sources = [s for s in peaks if s["weight"] > 0.02] or accents
    normal, bright = [], []
    for _name, h, dL in ANSI:
        near = min(sources, key=lambda s: hue_distance(s["hue"], h))
        dist = hue_distance(near["hue"], h)
        if dist <= 70:
            hue = hue_toward(h, near["hue"], pull * (1 - dist / 110))
            C = (near["C"] + max(near["C"], 0.12)) / 2
        else:
            hue = h
            C = max(primary["C"] * 0.8, 0.09)
        rgb, L, C2 = accent({"hue": hue, "L": 0.6, "C": C}, extra_L=dL)
        normal.append(rgb)
        b_rgb, _ = _readable(L + (0.07 if dark else -0.06), min(C2 * 1.12, cmax), hue, bg, p["contrast"], dark)
        bright.append(b_rgb)

    bg_hi = lch_to_rgb(L_bg + (0.17 if dark else -0.2), bg_chroma * 1.3, bg_hue)
    bg_hi, _ = _readable(L_bg + (0.17 if dark else -0.2), bg_chroma * 1.3, bg_hue, bg, 2.2, dark)
    bg_lo = lch_to_rgb(L_bg + (0.025 if dark else -0.03), bg_chroma, bg_hue)

    colors = [bg_lo] + normal + [fg_dim] + [bg_hi] + bright + [fg]
    return {
        "background": to_hex(bg),
        "foreground": to_hex(fg),
        "cursor": to_hex(fg),
        "colors": [to_hex(c) for c in colors],
        "roles": {k: to_hex(v) for k, v in roles.items()},
        "accents": [to_hex(lch_to_rgb(base_L, min(a["C"] * p["chroma"], cmax), a["hue"])) for a in accents],
        "mode": "dark" if dark else "light",
        "picture": {"lightness": stats["lightness"], "chromatic": stats["chromatic"]},
    }
