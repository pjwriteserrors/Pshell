"""The drawn things of the world: trees, houses, castles, elven towers.

Everything is drawn here in code, too big and scaled down, sharp enough to look
into a city. The light comes from the upper left, as on the terrain. Every colour
passes through `natural`, so the world wears the shell's colours.
"""

import colorsys
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

VERSION = 34
OVER = 3        # drawn this much too big
FINAL = 6       # kept at this many pixels per world unit, for looking into a city
K = OVER * FINAL

ROOFS = ["#b4553a", "#4f6d8f", "#5f7d45", "#7d4f7f", "#c08a35", "#3f8580", "#94403f", "#a8627a"]
WALLS = ["#ead9b8", "#dcc7a2", "#e6d6c6"]
SEASONS = {
	"spring": [("#6fae4d", "#8fce5f", "#4c8a3b"), ("#79b555", "#a3d86c", "#578f3f")],
	"summer": [("#658754", "#94ac6a", "#3f6547"), ("#476f59", "#78977a", "#315246")],
	"autumn": [("#c9832e", "#e8ab42", "#9c5f26"), ("#b9552c", "#dd7b38", "#8c3f26"), ("#a9a03a", "#cdc14c", "#7f7a2d")],
	"winter": [("#6f8f7b", "#a9c0b0", "#4f6f62"), ("#7c9a86", "#c0d2c4", "#587868")],
}


SHELL = []       # the shell's colours, set by use_palette
PRIMARY = None
_seen = {}


def use_palette(colors, primary):
	global SHELL, PRIMARY
	SHELL = [hexa(color) for color in colors]
	PRIMARY = hexa(primary) if primary else None
	_seen.clear()


def hexa(value):
	value = value.lstrip("#")[-6:]
	return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def natural(value):
	"""An obvious colour by way of the shell: its nearest colour when near enough, else mixed with its accent."""
	if value in _seen:
		return _seen[value]
	r, g, b = value
	out = value
	if SHELL:
		hue, light, sat = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
		best, score = None, 0
		for color in SHELL:
			h2, _l2, s2 = colorsys.rgb_to_hls(*(c / 255 for c in color))
			apart = abs(hue - h2)
			apart = min(apart, 1 - apart)
			near = (1 - min(1, apart / .14)) * min(1, s2 / .28)
			if near > score:
				best, score = (h2, s2), near
		if sat < .12:
			mix = .05
		elif best and score >= .5:
			# A restrained tint preserves material identity across shell themes.
			delta = (best[0] - hue + .5) % 1 - .5
			out = tuple(round(c * 255) for c in colorsys.hls_to_rgb((hue + delta * .18) % 1, light, sat * .94))
			mix = 0
		else:
			mix = .045
		if mix and PRIMARY:
			out = tuple(round(a + (p - a) * mix) for a, p in zip(value, PRIMARY))
	_seen[value] = out
	return out


def rgb(value):
	return natural(hexa(value))


def ink(value):
	"""A colour for PIL: words through the palette, numbers as they are."""
	if isinstance(value, str):
		return rgb(value)
	return value


def shade(value, amount):
	"""Lighter for a positive amount, darker for a negative one."""
	r, g, b = rgb(value) if isinstance(value, str) else value[:3]
	target = 255 if amount > 0 else 0
	amount = abs(amount)
	return (round(r + (target - r) * amount), round(g + (target - g) * amount), round(b + (target - b) * amount))


class Sheet:
	"""One sprite: drawn around a foot point, in world pixels."""

	k = K

	def __init__(self, width, up, down=8):
		self.width, self.up, self.down = width, up, down
		self.image = Image.new("RGBA", (width * self.k, (up + down) * self.k), (0, 0, 0, 0))
		self.draw = ImageDraw.Draw(self.image, "RGBA")
		self.shadows = Image.new("L", self.image.size, 0)
		self.shadow_draw = ImageDraw.Draw(self.shadows)
		self.ox, self.oy = 0, 0

	def at(self, x, y):
		return ((self.width / 2 + x + self.ox) * self.k, (self.up + y + self.oy) * self.k)

	def pts(self, points):
		return [self.at(x, y) for x, y in points]

	def poly(self, points, fill):
		self.draw.polygon(self.pts(points), fill=ink(fill))

	def line(self, points, fill, width=1.0):
		self.draw.line(self.pts(points), fill=ink(fill), width=max(1, round(width * self.k)), joint="curve")

	def oval(self, x, y, rx, ry, fill):
		(a, b), (c, d) = self.at(x - rx, y - ry), self.at(x + rx, y + ry)
		self.draw.ellipse((a, b, c, d), fill=ink(fill))

	def rect(self, x, y, w, h, fill):
		(a, b), (c, d) = self.at(x, y), self.at(x + w, y + h)
		self.draw.rectangle((a, b, c, d), fill=ink(fill))

	def shadow(self, x, y, rx, ry, strength=120):
		(a, b), (c, d) = self.at(x - rx, y - ry), self.at(x + rx, y + ry)
		self.shadow_draw.ellipse((a, b, c, d), fill=strength)

	def shadow_poly(self, points, strength=120):
		self.shadow_draw.polygon(self.pts(points), fill=strength)

	def finish(self):
		soft = self.shadows.filter(ImageFilter.GaussianBlur(self.k * .75))
		out = Image.new("RGBA", self.image.size, (33, 43, 40, 0))
		out.putalpha(soft)
		out.alpha_composite(self.image)
		out = out.resize((self.width * FINAL, (self.up + self.down) * FINAL), Image.LANCZOS)
		return out, self.width / 2, self.up


# ── trees ───────────────────────────────────────────────────────────────────


# ── houses ──────────────────────────────────────────────────────────────────


STONE = "#b7b1a4"


# ── elves ───────────────────────────────────────────────────────────────────


# ── what else stands around ─────────────────────────────────────────────────


# ── the peoples' houses ─────────────────────────────────────────────────────

STYLES = {
	"nordic": {"walls": ["#8a6a48", "#7a5c3e"], "roofs": ["#b89a58", "#7f8a55", "#a58a4e"], "skin": "log", "tower": "cone"},
	"alpine": {"walls": ["#efe3cc", "#e8d8bc", "#f2ead8"], "roofs": ["#a6523a", "#7f4a36", "#94503a"], "skin": "timber", "tower": "cone"},
	"southern": {"walls": ["#e8cfa4", "#eedcb8", "#dfc08f"], "roofs": ["#c4673f", "#b85c38", "#d07a4a"], "skin": "plaster", "tower": "dome"},
	"hanse": {"walls": ["#a5553f", "#99503f", "#b0604a"], "roofs": ["#5a4a48", "#3f4a5c", "#6b5550"], "skin": "brick", "tower": "crown"},
	"eastern": {"walls": ["#ece2d0", "#e4d6c0", "#efe8da"], "roofs": ["#2f7f78", "#b03a3a", "#36708f"], "skin": "plaster", "tower": "onion"},
	"arcane": {"walls": ["#8f93a8", "#9b9fb2", "#858aa0"], "roofs": ["#4a3f8f", "#2f5f8f", "#5f3f8a"], "skin": "stone", "tower": "needle"},
}
AWNINGS = ["#c0443c", "#3f7fa8", "#c9973a", "#4f8f58", "#8f4f8f", "#d0703a"]


# ── the market and its people ───────────────────────────────────────────────


SKINS = ["#e3b48f", "#c98f64", "#f0c9a6", "#8f6244"]
CLOTHES = ["#a33f3a", "#3f6fa3", "#d0a13a", "#4f8a54", "#7f4f90", "#c9703a", "#e0d8c4", "#3c3f50"]


# ── what else the shell puts on the land ────────────────────────────────────


LEAVES = {"leaf": SEASONS["summer"][0], "leafSpring": SEASONS["spring"][0], "autumnA": SEASONS["autumn"][0], "autumnB": SEASONS["autumn"][1], "pine": SEASONS["summer"][1]}


def draw(art):
	"""An (name, *args) from prefabs as an image with its foot point."""
	import iso
	return iso.draw(art)


def key_of(art):
	# These builders intentionally expose a bounded, deterministic variant set.
	# Share their disk renders across plots with different historical IDs.
	art = list(art)
	name = art[0]
	if name == "house": art[3] = int(art[3]) % 8
	elif name in ("oak", "birch", "pine"): art[2] = int(art[2]) % 12
	elif name in ("palm", "great_tree"): art[1] = int(art[1]) % 6
	elif name in ("rock", "mountain", "ruin") and len(art)>1: art[1] = int(art[1]) % 12
	elif name in ("ferns", "reeds", "fallen_log", "dead_tree", "shrine", "lantern_post"): art[1] = int(art[1]) % 8
	parts = []
	for value in art:
		parts.append(value["name"] if isinstance(value, dict) else str(value))
	return "-".join(parts).replace("/", "_")


class Cache:
	"""Sprites on disk per palette, so that a new house costs nothing."""

	def __init__(self, directory):
		self.dir = Path(directory)
		self.dir.mkdir(parents=True, exist_ok=True)
		self.loaded = {}

	def __call__(self, art):
		key = key_of(art)
		if key not in self.loaded:
			path = self.dir / f"{key}.png"
			meta = self.dir / f"{key}.txt"
			if path.exists() and meta.exists():
				image = Image.open(path).convert("RGBA")
				image.load()
				ax, ay = map(float, meta.read_text().split())
			else:
				image, ax, ay = draw(art)
				box = image.getbbox() or (0, 0, 1, 1)
				image = image.crop(box)
				ax -= box[0] / FINAL
				ay -= box[1] / FINAL
				image.save(path, compress_level=2)
				meta.write_text(f"{ax} {ay}")
			self.loaded[key] = (image, ax, ay)
		return self.loaded[key]
