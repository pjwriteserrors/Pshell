"""Paints the world: the land as an illustrated map, what stands on it, and for
every city a sharp plate of its own to look into. World units go in, images come
out; the shell only moves over them, so this is where the beauty costs anything."""

import hashlib
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

import sprites as sp

BASE = 2.0            # pixels per world unit of the whole map
MOST = 3600           # and at most this wide
PLATE = sprites_final = sp.FINAL
PLATE_MOST = 2200


def blur(field, sigma):
	h, w = field.shape
	fy = np.fft.fftfreq(h)[:, None]
	fx = np.fft.rfftfreq(w)[None, :]
	return np.fft.irfft2(np.fft.rfft2(field) * np.exp(-2 * (math.pi * sigma) ** 2 * (fx * fx + fy * fy)), s=field.shape)


def noise(shape, cell, seed, octaves=4):
	h, w = shape
	rng = np.random.default_rng(seed)
	total = np.zeros(shape, dtype=np.float32)
	power, amp = 0, 1.0
	for _ in range(octaves):
		grid = rng.random((max(2, int(h / cell) + 3), max(2, int(w / cell) + 3)), dtype=np.float32)
		ys, xs = np.linspace(0, h / cell, h, endpoint=False), np.linspace(0, w / cell, w, endpoint=False)
		y0, x0 = ys.astype(int), xs.astype(int)
		ty, tx = ys - y0, xs - x0
		ty, tx = ty * ty * (3 - 2 * ty), tx * tx * (3 - 2 * tx)
		top = grid[np.ix_(y0, x0)] * (1 - tx) + grid[np.ix_(y0, x0 + 1)] * tx
		bottom = grid[np.ix_(y0 + 1, x0)] * (1 - tx) + grid[np.ix_(y0 + 1, x0 + 1)] * tx
		total += (top * (1 - ty)[:, None] + bottom * ty[:, None]) * amp
		power += amp
		amp *= .5
		cell = max(2, cell / 2)
	return (total / power - .5) * 2


def smooth(a, b, x):
	t = np.clip((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)


def world_noise(shape, x, z, s, cell, seed, octaves=3):
	"""Sample one continuous landscape, independent of crop and render scale."""
	yy, xx = np.ogrid[:shape[0], :shape[1]]
	px, pz = x + (xx + .5) / s, z + (yy + .5) / s
	out = np.zeros(shape, dtype=np.float32)
	weight, total = 1., 0.
	for octave in range(octaves):
		u, v = px / cell, pz / cell
		i, j = np.floor(u).astype(np.int64), np.floor(v).astype(np.int64)
		fx, fy = u - i, v - j
		fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
		def lattice(a, b):
			n = (a * 374761393 + b * 668265263 + (seed + octave) * 1442695041) & 0xffffffff
			n = ((n ^ (n >> 13)) * 1274126177) & 0xffffffff
			return (n ^ (n >> 16)) / 4294967295.
		top = lattice(i, j) * (1 - fx) + lattice(i + 1, j) * fx
		bottom = lattice(i, j + 1) * (1 - fx) + lattice(i + 1, j + 1) * fx
		out += ((top * (1 - fy) + bottom * fy) * 2 - 1) * weight
		total += weight
		weight *= .5
		cell /= 2
	return out / total


def spline(points, step=5):
	if len(points) < 3:
		return points
	out = []
	pts = [points[0]] + list(points) + [points[-1]]
	for i in range(1, len(pts) - 2):
		p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
		for j in range(step):
			t = j / step
			out.append(tuple(.5 * (2 * p1[a] + (p2[a] - p0[a]) * t + (2 * p0[a] - 5 * p1[a] + 4 * p2[a] - p3[a]) * t * t + (3 * p1[a] - p0[a] - 3 * p2[a] + p3[a]) * t ** 3) for a in (0, 1)))
	out.append(points[-1])
	return out


def color(name):
	return np.array(sp.rgb(name), dtype=np.float32)


def mix(a, b, t):
	return a + (b - a) * t[..., None]


class Fields:
	"""The low-resolution truth of the land, read at any place and scale."""

	def __init__(self, ground):
		self.g = ground
		self.scale = ground["scale"]
		ground["wet"] = np.clip(blur(ground["wet"], 1.1), 0, 1)

	def read(self, name, x, z, w, h, s):
		field = self.g[name]
		scale = self.scale
		box = ((x - self.g["x0"]) * scale, (z - self.g["z0"]) * scale, (x + w - self.g["x0"]) * scale, (z + h - self.g["z0"]) * scale)
		size = (max(1, round(w * s)), max(1, round(h * s)))
		box = (max(0, box[0]), max(0, box[1]), min(field.shape[1], box[2]), min(field.shape[0], box[3]))
		return np.asarray(Image.fromarray(field.astype(np.float32), mode="F").resize(size, Image.BICUBIC, box=box), dtype=np.float32)


def sample_wet(ground, x, z):
	field = ground["wet"]
	v = min(field.shape[0] - 1, max(0, int((z - ground["z0"]) * ground["scale"])))
	u = min(field.shape[1] - 1, max(0, int((x - ground["x0"]) * ground["scale"])))
	return field[v, u]


def land_picture(fields, scene, x, z, w, h, s, seed):
	"""The ground as a painter would have it: light on the hills, ways worn into it."""
	height = fields.read("field", x, z, w, h, s)
	forest = np.clip(fields.read("forest", x, z, w, h, s), 0, 1)
	town = np.clip(fields.read("town", x, z, w, h, s), 0, 1)
	broad = fields.read("broad", x, z, w, h, s) * .5 + .5
	shape = height.shape
	coarse = world_noise(shape, x, z, s, 60, seed, 4)
	fine = world_noise(shape, x, z, s, 7, seed + 1, 3)
	grit = world_noise(shape, x, z, s, 1.4, seed + 2, 2)
	out = mix(np.broadcast_to(color("#788466"), (*shape, 3)).copy(), np.broadcast_to(color("#a49c75"), (*shape, 3)), smooth(.42, .78, broad + coarse * .25))
	out = mix(out, np.broadcast_to(color("#586e59"), (*shape, 3)), smooth(.1, .7, coarse + fine * .4) * .6)
	out *= (.98 + fine[..., None] * .09 + grit[..., None] * .035)
	# the sun from the upper left
	dy, dx = np.gradient(height)
	light = np.clip(1 + (-(dx + dy * .7) * s * .23), .62, 1.3)
	floor = color("#46684f") * (.94 + fine[..., None] * .12 + grit[..., None] * .06)
	out = mix(out, floor, smooth(.15, .7, forest + fine * .12) * .85)
	out = mix(out, color("#a89f73") * (.9 + grit[..., None] * .14), smooth(.3, .85, town + fine * .15) * .5)
	out = mix(out, color("#9b978a") * (.86 + fine[..., None] * .2 + grit[..., None] * .1), smooth(26, 40, height + fine * 8))
	# Shore vegetation and sand follow the actual water mask, including rivers.
	wet = np.clip(fields.read("wet", x, z, w, h, s), 0, 1)
	bank = smooth(.025, .18, wet) * (1 - smooth(.28, .6, wet))
	out = mix(out, color("#6d8363") * (.95 + fine[..., None] * .08), bank * .6)
	sand = smooth(.12, .4, wet) * (1 - smooth(.55, .85, wet))
	out = mix(out, color("#d3c39e") * (.97 + grit[..., None] * .06), sand)
	out *= light[..., None]
	if s >= 4:
		tuft = smooth(.34, .5, world_noise(shape, x, z, s, 1.1, seed + 3, 1))
		out = out * (1 - tuft[..., None] * .1)

	# what is worn or laid into it
	marks = {name: Image.new("L", (shape[1], shape[0]), 0) for name in ("way", "lane", "plaza", "border")}
	draws = {name: ImageDraw.Draw(image) for name, image in marks.items()}
	to = lambda p: ((p[0] - x) * s, (p[1] - z) * s)
	for road in scene["roads"]:
		# PIL clips each segment; filtering vertices joined unrelated road sections.
		if len(road) > 1:
			draws["way"].line([to(p) for p in road], fill=255, width=max(2, round(3.4 * s)), joint="curve")
	for lane in scene["lanes"]:
		draws["lane"].line([to(lane[0]), to(lane[1])], fill=255, width=max(1, round(2 * s)))
	for px, pz, r in scene["plazas"]:
		a, b = to((px - r, pz - r * .52)), to((px + r, pz + r * .52))
		draws["plaza"].ellipse((a[0], a[1], b[0], b[1]), fill=255)
	soft = lambda name, r: np.asarray(marks[name].filter(ImageFilter.GaussianBlur(r)), dtype=np.float32) / 255
	way = soft("way", max(.8, .4 * s))
	if way.max() > 0:
		edge = smooth(.04, .3, way) * (1 - smooth(.3, .7, way))
		out = out * (1 - edge[..., None] * .14)
		dirt = color("#a39270") * (.88 + fine[..., None] * .16 + grit[..., None] * .14)
		out = mix(out, dirt, smooth(.18, .65, way + fine * .07 + grit * .12))
	stones = cobble(shape, x, z, s)
	lane = soft("lane", max(.6, .25 * s))
	if lane.max() > 0:
		out = mix(out, color("#ad9f83") * stones[..., None], smooth(.3, .6, lane))
	plaza = soft("plaza", max(.6, .4 * s))
	if plaza.max() > 0:
		edge = smooth(.08, .34, plaza) * (1 - smooth(.34, .6, plaza))
		out = out * (1 - edge[..., None] * .3)
		out = mix(out, color("#c2b79e") * stones[..., None], smooth(.34, .62, plaza))
	return np.clip(out, 0, 255)


def cobble(shape, x, z, s):
	h, w = shape
	ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
	wx, wz = xs / s + x, ys / s + z
	if s < 4:
		return np.full(shape, .96, dtype=np.float32)
	row = np.floor(wz / 1.15)
	u = wx / 1.5 + row * .5
	ground = (np.abs(np.mod(u, 1) - .5) < .44) & (np.abs(np.mod(wz / 1.15, 1) - .5) < .42)
	rng = np.random.default_rng(5)
	shades = rng.uniform(.88, 1.06, 1024).astype(np.float32)
	tone = shades[((np.floor(u).astype(np.int64) * 73856093) ^ (row.astype(np.int64) * 19349663)) % 1024]
	return np.where(ground, tone, .66)


def place(cache, art, s, memo):
	key = (sp.key_of(art), s)
	if key not in memo:
		image, ax, ay = cache(art)
		if s != sp.FINAL:
			factor = s / sp.FINAL
			image = image.resize((max(1, round(image.width * factor)), max(1, round(image.height * factor))), Image.LANCZOS)
		alpha = image.getchannel("A").point(lambda v: 255 if v > 90 else 0)
		memo[key] = (image, ax * s, ay * s, alpha)
	return memo[key]


FLAT_THINGS = {"ferns", "reeds", "fallen_log", "terrace", "plaza", "ground_square", "field", "flowers", "floating_isle", "isle_shadow", "rope", "steps", "bridge", "mist", "fire", "milestone", "hedge", "sheep", "gold_pile", "crates", "boat", "harbour_ship"}
TREES = {"dead_tree", "oak", "pine", "birch", "palm", "world_tree", "great_tree", "elf_tower"}


def things_on(canvas, items, cache, x, z, s, memo, birth=None, sway=None):
	"""Back to front, so that what is nearer covers what is behind."""
	w, h = canvas.size
	for item in sorted(items, key=lambda it: (it.get("block", it["z"]), it.get("order", 0), it["z"], it["x"])):
		image, ax, ay, alpha = place(cache, item["art"], s, memo)
		px, py = round((item["x"] - x) * s - ax), round((item["z"] - item.get("lift", 0) - z) * s - ay)
		if px >= w or py >= h or px + image.width <= 0 or py + image.height <= 0:
			continue
		if px >= 0 and py >= 0 and px + image.width <= w and py + image.height <= h:
			canvas.alpha_composite(image, (px, py))
		else:
			left, top = max(0, -px), max(0, -py)
			canvas.alpha_composite(image.crop((left, top, min(image.width, w - px), min(image.height, h - py))), (max(0, px), max(0, py)))
		if birth is not None:
			birth.paste(min(254, item["day"]), (px, py), alpha)
		if sway is not None:
			sway.paste(255 if item["art"][0] in TREES else 0, (px, py), alpha)


def glow_of(objects):
	"""Where the windows are, for the night."""
	data = np.asarray(objects, dtype=np.int16)
	r, g, b, a = data[..., 0], data[..., 1], data[..., 2], data[..., 3]
	return ((r > 225) & (g > 185) & (g < 225) & (b > 90) & (b < 160) & (a > 200))


def bake(scene, ground, cache, out, plate_dir):
	"""Writes the map's layers and the plates; says what it wrote."""
	fields = Fields(ground)
	width, height, x0, z0 = ground["width"], ground["height"], ground["x0"], ground["z0"]
	s = min(BASE, MOST / max(width, height))
	memo = {}

	land = land_picture(fields, scene, x0, z0, width, height, s, 7)
	size = (land.shape[1], land.shape[0])
	Image.fromarray(land.astype(np.uint8), "RGB").save(out / "ground.jpg", quality=90)

	objects = Image.new("RGBA", size, (0, 0, 0, 0))
	days = Image.new("L", size, 255)
	afloat = ("boat", "harbour_ship", "ship", "bridge", "spring_head")
	wet_at = lambda x, z: sample_wet(ground, x, z)
	baked = [item for item in scene["items"] if item["art"][0] not in ("person", "cloud", "bird") and (item["art"][0] in afloat or item.get("kind") in ("boat", "house", "seat", "terrace", "wall") or item.get("city") or wet_at(item["x"], item["z"]) < .4)]
	sway = Image.new("L", size, 0)
	things_on(objects, baked, cache, x0, z0, s, memo, days, sway)
	sway.resize((size[0] // 2, size[1] // 2), Image.BOX).save(out / "sway.png", compress_level=2)
	objects.save(out / "objects.png", compress_level=2)

	# how near everything stands, and how high the ground is: people go behind what is in front of them
	rate = 2
	depth = np.zeros((round(height * rate) + 1, round(width * rate) + 1), dtype=np.uint16)
	level = np.zeros(depth.shape, dtype=np.uint8)
	depth_memo = {}
	for item in sorted(baked, key=lambda it: (it.get("block", it["z"]), it.get("order", 0), it["z"], it["x"])):
		name = item["art"][0]
		if name in FLAT_THINGS and name != "terrace":
			continue
		image, ax, ay, _ = place(cache, item["art"], rate, depth_memo)
		mask = np.asarray(image.getchannel("A")) > 170
		left, top = round((item["x"] - x0) * rate - ax), round((item["z"] - item.get("lift", 0) - z0) * rate - ay)
		y0, y1, x0_, x1 = max(0, top), min(depth.shape[0], top + mask.shape[0]), max(0, left), min(depth.shape[1], left + mask.shape[1])
		if y1 <= y0 or x1 <= x0_:
			continue
		area = mask[y0 - top:y1 - top, x0_ - left:x1 - left]
		if name == "terrace":
			level[y0:y1, x0_:x1][area] = min(255, round((item.get("lift", 0) + item["art"][3]) / 2))
		else:
			depth[y0:y1, x0_:x1][area] = int(max(1, min(65535, (item["z"] - item.get("lift", 0) - z0) / height * 65535)))
	Image.fromarray(np.dstack([(depth >> 8).astype(np.uint8), (depth & 255).astype(np.uint8), level]), "RGB").save(out / "depth.png", compress_level=2)
	del depth, level, depth_memo

	# what the shader needs to bring things and land about in time, and water to life
	wet = fields.read("wet", x0, z0, width, height, s / 2)
	half = (wet.shape[1], wet.shape[0])
	near = np.clip(blur(1 - wet.astype(np.float64), 13 * s / 2), 0, 1)
	glow = Image.fromarray((glow_of(objects) * 255).astype(np.uint8), "L").resize(half, Image.BOX).filter(ImageFilter.GaussianBlur(1.2))
	layer = np.stack([wet, np.clip(1 - near * 2.1, 0, 1), np.clip(np.asarray(glow, dtype=np.float32) / 255 * 3, 0, 1)], axis=-1)
	Image.fromarray((layer * 255).astype(np.uint8), "RGB").save(out / "water.png", compress_level=2)

	land_days = Image.new("L", size, 255)
	water_days = Image.new("L", size, 255)
	draw = ImageDraw.Draw(land_days)
	wdraw = ImageDraw.Draw(water_days)
	reach = 52 * s
	for (px, pz), day in sorted(scene["land_days"], key=lambda pair: -pair[1]):
		u, v = (px - x0) * s, (pz - z0) * s
		draw.ellipse((u - reach, v - reach, u + reach, v + reach), fill=min(254, day))
	for (px, pz), day in sorted(scene["water_days"], key=lambda pair: -pair[1]):
		u, v = (px - x0) * s, (pz - z0) * s
		wdraw.ellipse((u - 22 * s, v - 22 * s, u + 22 * s, v + 22 * s), fill=min(254, day))
	# a river comes with the water that fed it, but only the river itself: neither sea nor lake
	river_days = Image.new("L", size, 255)
	rdraw = ImageDraw.Draw(river_days)
	for x, z, day in sorted(scene.get("river_days", ()), key=lambda point: -point[2]):
		u, v = (x - x0) * s, (z - z0) * s
		rdraw.ellipse((u - 16 * s, v - 16 * s, u + 16 * s, v + 16 * s), fill=day)
	river = fields.read("river", x0, z0, width, height, s)
	water_days = Image.fromarray(np.where(river[:size[1], :size[0]] > .15, np.asarray(river_days), np.asarray(water_days)).astype(np.uint8), "L")
	half_size = (size[0] // 2, size[1] // 2)
	Image.merge("RGB", tuple(c.resize(half_size, Image.NEAREST) for c in (land_days, days, water_days))).save(out / "birth.png", compress_level=2)

	cities = []
	for city in scene["cities"]:
		x, z, w, h = city["rect"]
		rate = min(PLATE, PLATE_MOST / max(w, h))
		rate = max(r for r in (6, 5, 4, 3, 2) if r <= max(2, rate))
		mine = [item for item in baked if x - 70 < item["x"] < x + w + 70 and z - 40 < item["z"] < z + h + 130]
		digest = hashlib.sha256(repr((sp.VERSION, scene["palette"], city["rect"], rate, sorted((sp.key_of(i["art"]), round(i["x"], 1), round(i["z"], 1)) for i in mine), city["hash"])).encode()).hexdigest()[:18]
		path = plate_dir / f"{digest}.png"
		if not path.exists():
			picture = land_picture(fields, scene, x, z, w, h, rate, 7)
			wet_here = fields.read("wet", x, z, w, h, rate)
			shape = picture.shape[:2]
			ys, xs = np.mgrid[0:shape[0], 0:shape[1]].astype(np.float32)
			feather = np.minimum.reduce([xs, ys, shape[1] - 1 - xs, shape[0] - 1 - ys]) / max(1, 26 * rate)
			alpha = np.clip(feather, 0, 1) * (1 - smooth(.3, .62, wet_here))
			rgba = np.dstack([picture.astype(np.uint8), (alpha * 255).astype(np.uint8)])
			canvas = Image.fromarray(rgba, "RGBA")
			things = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
			things_on(things, mine, cache, x, z, rate, memo)
			mask = Image.fromarray((np.clip(feather, 0, 1) * 255).astype(np.uint8), "L")
			things.putalpha(Image.composite(things.getchannel("A"), Image.new("L", things.size, 0), mask))
			canvas.alpha_composite(things)
			canvas.save(path, compress_level=2)
		cities.append({**city["info"], "plate": {"file": str(path), "x": round(x - x0, 1), "z": round(z - z0, 1), "w": round(w, 1), "h": round(h, 1)}})
	return {"scale": s, "cities": cities, "used": {path.name for path in plate_dir.iterdir()} and {str(c["plate"]["file"]) for c in cities}}


def mini(items, cache, seed, path, memo, width=560, height=320, s=2.4):
	"""A small land of its own: an island, what stood on it, some people."""
	rnd = random.Random(seed)
	canvas = Image.new("RGBA", (width * 2, height * 2), (0, 0, 0, 0))
	cx, cy = width, height
	draw = ImageDraw.Draw(canvas)
	rx, ry = width * .9, height * .72
	cy -= 34
	wobble = [rnd.uniform(-.045, .045) for _ in range(9)]
	edge = lambda a: 1 + sum(wobble[k] * math.sin(a * (k + 2) + k * 1.7) for k in range(9))
	outline = [(cx + math.cos(i / 180 * math.pi) * rx * edge(i / 180 * math.pi), cy + math.sin(i / 180 * math.pi) * ry * edge(i / 180 * math.pi)) for i in range(360)]
	# the rock below, course on course, lit from the left and dark underneath
	fall = 118
	for row in range(int(fall / 13), -1, -1):
		y = row * 13
		shrink = 1 - (y / fall) ** 1.7 * .34
		for i in range(0, 180, 3):
			a0, a1 = i / 180 * math.pi, (i + 3) / 180 * math.pi
			(x0, y0), (x1, y1) = outline[i], outline[(i + 3) % 360]
			x0, x1 = cx + (x0 - cx) * shrink, cx + (x1 - cx) * shrink
			y0, y1 = cy + (y0 - cy) * shrink + y, cy + (y1 - cy) * shrink + y
			tone = (sp.shade("#8d8676", math.cos((a0 + a1) / 2) * -.2 - y / fall * .34 + rnd.uniform(-.07, .07)))
			draw.polygon([(x0, y0), (x1, y1), (x1, y1 + 15), (x0, y0 + 15)], fill=(*tone[:3], 255))
	draw.polygon(outline, fill=(*sp.rgb("#7ea552"), 255))
	tone = noise((height * 2, width * 2), 90, seed if isinstance(seed, int) else 3, 3)
	picture = np.array(canvas, dtype=np.float32)
	picture[..., :3] *= (1 + tone[..., None] * .16)
	canvas = Image.fromarray(np.clip(picture, 0, 255).astype(np.uint8), "RGBA")
	draw = ImageDraw.Draw(canvas)
	# grass in tufts, a bright rim, an overhanging fringe on the near side
	for _ in range(1500):
		a, d = rnd.uniform(0, math.tau), rnd.random() ** .5 * .95
		x, y = cx + math.cos(a) * rx * d, cy + math.sin(a) * ry * d
		c = sp.rgb(rnd.choice(("#6f9a4a", "#8ab35a", "#9abf66", "#5f8c44")))
		draw.ellipse((x - 6, y - 2.4, x + 6, y + 2.4), fill=(*c, 150))
	for i in range(0, 360, 2):
		x, y = outline[i]
		c = sp.rgb(rnd.choice(("#9fc46c", "#8ab35a", "#b2d07c")))
		draw.ellipse((x - 7, y - 4, x + 7, y + (9 if 0 < i < 180 else 4)), fill=(*c, 255))
	placed = []
	for art, fx, fz in items:
		ay = place(cache, art, s * 2, memo)[2]
		z = cy / (s * 2) + fz * ry / (s * 2) * .92
		placed.append({"art": art, "x": cx / (s * 2) + fx * rx / (s * 2) * .92, "z": max(z, ay / (s * 2) + 2), "day": 0})
	things_on(canvas, placed, cache, 0, 0, s * 2, memo)
	canvas.resize((width, height), Image.LANCZOS).save(path, compress_level=2)
