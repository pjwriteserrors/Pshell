"""The world's buildings and trees in true isometric view: tiled roofs tile by
tile, half-timbering, gardens round the houses, crowns made of hundreds of leaves.
Everything is painted once and kept on disk; a sprite costs nothing afterwards."""

import math
import random

import numpy as np

import sprites as sp
from sprites import Sheet, shade, rgb

LIGHT, DARK = .10, -.24   # left faces take the sun, right faces lie in shade


CULTURES = {
	"nordic": {"roof": "#7d6a4e", "wall": "log", "base": "#8a5f3c", "trim": "#4a3222"},
	"alpine": {"roof": "#c9713a", "wall": "timber", "base": "#efe6d2", "trim": "#5a3a24"},
	"southern": {"roof": "#c4623c", "wall": "plaster", "base": "#ead9b8", "trim": "#8a6a48"},
	"hanse": {"roof": "#a5443a", "wall": "brick", "base": "#a8543f", "trim": "#e8dfc9"},
	"eastern": {"roof": "#2f8a84", "wall": "plaster", "base": "#e8dfc9", "trim": "#7a4a30"},
	"arcane": {"roof": "#5b4f93", "wall": "stone", "base": "#a9a59b", "trim": "#3f3a5a"},
}


def culture_of(name):
	return CULTURES.get(name, CULTURES["alpine"])


ALT_WALL = {"log": ("timber", "stone"), "timber": ("plaster", "brick"), "plaster": ("timber", "stone"), "brick": ("timber", "stone"), "stone": ("plaster", "timber")}


class Iso(Sheet):
	"""A sheet addressed in ground coordinates and height."""

	@staticmethod
	def p(x, y, h=0):
		return (x - y, (x + y) * .5 - h)

	def quad(self, points, fill):
		self.poly([self.p(*point) for point in points], fill)

	def ground_shadow(self, x0, y0, dx, dy, height, strength=110):
		fall = height * .55
		pts = [(x0, y0 + dy), (x0 + dx, y0 + dy), (x0 + dx, y0), (x0 + dx + fall, y0 + fall * .1), (x0 + dx + fall, y0 + dy + fall * .1), (x0 + fall, y0 + dy + fall * .1)]
		self.shadow_poly([self.p(*point) for point in pts], strength)


class Wide(Sheet):
	"""For what is as large as a town: no finer than it will be kept."""

	k = sp.FINAL


class Face:
	"""A quad on the sheet, addressed from 0 to 1 across and down."""

	def __init__(self, sheet, a, b, c, d):
		self.s, self.a, self.b, self.c, self.d = sheet, a, b, c, d

	def at(self, u, v):
		top = (self.a[0] + (self.b[0] - self.a[0]) * u, self.a[1] + (self.b[1] - self.a[1]) * u)
		bottom = (self.d[0] + (self.c[0] - self.d[0]) * u, self.d[1] + (self.c[1] - self.d[1]) * u)
		return (top[0] + (bottom[0] - top[0]) * v, top[1] + (bottom[1] - top[1]) * v)

	def fill(self, color):
		self.s.poly([self.a, self.b, self.c, self.d], color)

	def poly(self, points, color):
		self.s.poly([self.at(*point) for point in points], color)

	def rect(self, u0, v0, u1, v1, color):
		self.poly([(u0, v0), (u1, v0), (u1, v1), (u0, v1)], color)

	def line(self, a, b, color, width=.3):
		self.s.line([self.at(*a), self.at(*b)], color, width)


def stone_face(face, base, rows, cols, rnd):
	face.fill(shade(base, -.14))
	for r in range(rows):
		offset = .5 if r % 2 else 0
		for c in range(-1, cols + 1):
			u0, u1 = max(0, (c + offset) / cols + .006), min(1, (c + offset + 1) / cols - .006)
			if u1 <= u0:
				continue
			face.rect(u0, r / rows + .012, u1, (r + 1) / rows - .012, shade(base, rnd.uniform(-.12, .1)))


def wood_face(face, base, boards, rnd):
	for i in range(boards):
		tone = shade(base, rnd.uniform(-.16, .1))
		face.rect(i / boards, 0, (i + 1) / boards, 1, tone)
		face.line((i / boards, 0), (i / boards, 1), shade(base, -.34), .14)


def log_face(face, base, rows, rnd):
	for r in range(rows):
		tone = shade(base, rnd.uniform(-.12, .08))
		face.rect(0, r / rows, 1, (r + 1) / rows, tone)
		face.rect(0, r / rows, 1, (r + .3) / rows, shade(tone, .14))
		face.line((0, (r + 1) / rows), (1, (r + 1) / rows), shade(base, -.42), .16)


def plaster_face(face, base, rnd):
	face.fill(base)
	for _ in range(40):
		u, v = rnd.random(), rnd.random()
		face.rect(u, v, min(1, u + rnd.uniform(.02, .07)), min(1, v + rnd.uniform(.01, .05)), (*shade(base, rnd.choice((-.06, .05)))[:3], 150))
	face.rect(0, .9, 1, 1, shade(base, -.16))


def timber_face(face, base, trim, rnd, length):
	plaster_face(face, base, rnd)
	bays = max(2, round(length / 3.4))
	for i in range(bays + 1):
		face.line((i / bays, 0), (i / bays, 1), trim, .5)
	face.line((0, 0), (1, 0), trim, .55)
	face.line((0, .5), (1, .5), trim, .42)
	face.line((0, 1), (1, 1), trim, .6)
	for i in range(bays):
		if rnd.random() < .6:
			if rnd.random() < .5:
				face.line((i / bays, .5), ((i + 1) / bays, 1), trim, .34)
			else:
				face.line(((i + 1) / bays, 0), (i / bays, .5), trim, .34)


def dress_wall(face, culture, rnd, length, height, tone=0):
	base = shade(culture["base"], tone)
	trim = shade(culture["trim"], tone)
	kind = culture["wall"]
	if kind == "log":
		log_face(face, base, max(4, round(height / .9)), rnd)
	elif kind == "timber":
		timber_face(face, base, trim, rnd, length)
	elif kind == "brick":
		stone_face(face, base, max(5, round(height / .55)), max(4, round(length / 1.1)), rnd)
	elif kind == "stone":
		stone_face(face, base, max(4, round(height / 1)), max(3, round(length / 1.8)), rnd)
	else:
		plaster_face(face, base, rnd)
		face.line((0, 0), (1, 0), trim, .4)


def window(face, u, v, w, h, trim, shutters=True):
	face.rect(u - w * .62, v - h * .58, u + w * .62, v + h * .62, trim)
	face.rect(u - w * .5, v - h * .5, u + w * .5, v + h * .5, "#f3cf7a")
	face.line((u, v - h * .5), (u, v + h * .5), trim, .14)
	face.line((u - w * .5, v), (u + w * .5, v), trim, .14)
	if shutters:
		face.rect(u - w * 1.15, v - h * .5, u - w * .62, v + h * .5, shade(trim, .12))
		face.rect(u + w * .62, v - h * .5, u + w * 1.15, v + h * .5, shade(trim, .12))


def door(face, u, w, h, trim):
	face.poly([(u - w * .62, 1), (u - w * .62, 1 - h), (u, 1 - h * 1.18), (u + w * .62, 1 - h), (u + w * .62, 1)], trim)
	face.poly([(u - w * .46, 1), (u - w * .46, 1 - h * .92), (u, 1 - h * 1.08), (u + w * .46, 1 - h * .92), (u + w * .46, 1)], "#6a4128")
	face.line((u, 1 - h * 1.05), (u, 1), "#3f2616", .14)


def tiled(s, a, b, c, d, base, rows, cols, rnd):
	"""A roof slope, a is the ridge's left end and d below it; each tile laid on its own."""
	face = Face(s, a, b, c, d)
	face.fill(shade(base, -.3))
	for r in range(rows):
		offset = .5 if r % 2 else 0
		for i in range(-1, cols + 1):
			u0, u1 = max(0, (i + offset) / cols), min(1, (i + offset + 1) / cols)
			if u1 <= u0:
				continue
			v0, v1 = r / rows, (r + 1.12) / rows
			tone = shade(base, rnd.uniform(-.13, .12))
			face.poly([(u0 + .004, v0), (u1 - .004, v0), (u1 - .004, min(1, v1 - .02)), ((u0 + u1) / 2, min(1, v1)), (u0 + .004, min(1, v1 - .02))], tone)
			face.line((u0, min(1, v1 - .02)), (u1, min(1, v1 - .02)), shade(tone, -.28), .1)
	face.line((0, 0), (1, 0), shade(base, -.34), .34)
	face.line((0, 0), (0, 1), shade(base, -.3), .28)
	face.line((1, 0), (1, 1), shade(base, -.3), .28)
	face.line((0, 1), (1, 1), shade(base, -.42), .3)


def box(s, x, y, h, dx, dy, dz, color, top=None):
	s.quad([(x, y + dy, h + dz), (x + dx, y + dy, h + dz), (x + dx, y + dy, h), (x, y + dy, h)], shade(color, LIGHT))
	s.quad([(x + dx, y + dy, h + dz), (x + dx, y, h + dz), (x + dx, y, h), (x + dx, y + dy, h)], shade(color, DARK))
	s.quad([(x, y, h + dz), (x + dx, y, h + dz), (x + dx, y + dy, h + dz), (x, y + dy, h + dz)], top or shade(color, .18))


def wall_faces(s, x, y, h, dx, dy, dz):
	p = s.p
	left = Face(s, p(x, y + dy, h + dz), p(x + dx, y + dy, h + dz), p(x + dx, y + dy, h), p(x, y + dy, h))
	right = Face(s, p(x + dx, y + dy, h + dz), p(x + dx, y, h + dz), p(x + dx, y, h), p(x + dx, y + dy, h))
	return left, right


def volume(s, culture, x, y, dx, dy, dz, rnd, axis="x", h=0, pitch=.62, over=.8, roof=None, windows=True, ground_door=None, cols=None):
	"""Walls and a saddle roof along an axis, the end gable towards the viewer."""
	roof = roof or culture["roof"]
	p = s.p
	left, right = wall_faces(s, x, y, h, dx, dy, dz)
	dress_wall(left, culture, rnd, dx, dz, .03)
	dress_wall(right, culture, rnd, dy, dz, -.2)
	trim = culture["trim"]
	span = dy if axis == "x" else dx
	top = h + dz
	rise = span * pitch
	if axis == "x":
		ym = y + dy / 2
		tri = [p(x + dx, y + dy, top), p(x + dx, ym, top + rise), p(x + dx, y, top)]
		s.poly(tri, shade(culture["base"], -.18))
		tiled(s, p(x - over, ym, top + rise), p(x + dx + over, ym, top + rise), p(x + dx + over, y + dy + over, top - over * pitch), p(x - over, y + dy + over, top - over * pitch), shade(roof, .04), max(5, round(span * .75)), max(6, round(dx * 1.1)), rnd)
		s.line([p(x + dx + over, y + dy + over, top - over * pitch), p(x + dx + over, ym, top + rise), p(x + dx + over, y - over, top - over * pitch)], shade(trim, -.05), .55)
		gable = Face(s, p(x + dx, ym + .2, top + rise * .55), p(x + dx, ym - .2, top + rise * .55), p(x + dx, ym - .2, top + rise * .15), p(x + dx, ym + .2, top + rise * .15))
	else:
		xm = x + dx / 2
		tri = [p(x, y + dy, top), p(xm, y + dy, top + rise), p(x + dx, y + dy, top)]
		s.poly(tri, shade(culture["base"], .02))
		tiled(s, p(xm, y + dy + over, top + rise), p(xm, y - over, top + rise), p(x + dx + over, y - over, top - over * pitch), p(x + dx + over, y + dy + over, top - over * pitch), shade(roof, -.14), max(5, round(span * .75)), max(6, round(dy * 1.1)), rnd)
		s.line([p(x - over, y + dy + over, top - over * pitch), p(xm, y + dy + over, top + rise), p(x + dx + over, y + dy + over, top - over * pitch)], shade(trim, .05), .55)
		gable = Face(s, p(xm - .5, y + dy, top + rise * .55), p(xm + .5, y + dy, top + rise * .55), p(xm + .5, y + dy, top + rise * .15), p(xm - .5, y + dy, top + rise * .15))
	gable.rect(.1, .05, .9, .95, trim)
	gable.rect(.22, .15, .78, .85, "#f3cf7a")
	if windows:
		storeys = max(1, round(dz / 3.6))
		for n in range(storeys):
			v = (n + .46) / storeys
			count = max(1, round(dx / 3.8))
			for i in range(count):
				if ground_door is None or abs((i + .5) / count - ground_door) > .17 or n < storeys - 1:
					window(left, (i + .5) / count, v, 1.05 / dx, 1.5 / dz, trim)
			count = max(1, round(dy / 4))
			for i in range(count):
				window(right, (i + .5) / count, v, 1.0 / dy, 1.5 / dz, trim, shutters=False)
	if ground_door is not None:
		door(left, ground_door, 2 / dx, min(.8, 2.8 / dz), trim)
	return left, right, top + rise


def chimney(s, x, y, h, rnd, height=3.6):
	box(s, x, y, h, 1.5, 1.5, height, "#9b6a52")
	left, right = wall_faces(s, x, y, h, 1.5, 1.5, height)
	stone_face(left, shade("#a4705a", .06), 6, 3, rnd)
	stone_face(right, shade("#a4705a", -.22), 6, 3, rnd)
	box(s, x - .2, y - .2, h + height, 1.9, 1.9, .5, "#857062", "#2f2a26")


def dormer(s, culture, x, y, h, rnd, axis):
	if axis == "x":
		volume(s, culture, x, y, 2.3, 1.7, 1.5, rnd, axis="y", h=h, pitch=.7, over=.25, windows=False)
		left, _ = wall_faces(s, x, y, h, 2.3, 1.7, 1.5)
		window(left, .5, .46, .34, .5, culture["trim"], shutters=False)
	else:
		volume(s, culture, x, y, 1.7, 2.3, 1.5, rnd, axis="x", h=h, pitch=.7, over=.25, windows=False)
		_, right = wall_faces(s, x, y, h, 1.7, 2.3, 1.5)
		window(right, .5, .46, .34, .5, culture["trim"], shutters=False)


# ── plants ──────────────────────────────────────────────────────────────────

def leaves(s, rnd, cx, cy, rx, ry, colors, count, size=1.0):
	"""A crown out of many small clumps, lit from the upper left."""
	base, light, dark = colors
	blobs = []
	for _ in range(count):
		a, d = rnd.uniform(0, math.tau), math.sqrt(rnd.random())
		nx, ny = math.cos(a) * d, math.sin(a) * d
		blobs.append((nx, ny))
	blobs.sort(key=lambda b: (b[1] + b[0] * .2))
	for pass_, grow in ((0, 1.25), (1, 1)):
		for nx, ny in blobs:
			lum = -nx * .45 - ny * .75 + rnd.uniform(-.28, .28)
			x, y = cx + nx * rx, cy + ny * ry
			r = rnd.uniform(.85, 1.5) * size * grow
			if pass_ == 0:
				s.oval(x, y + .35, r, r * .92, shade(dark, -.14))
				continue
			tone = light if lum > .28 else base if lum > -.25 else dark
			tone = shade(tone, rnd.uniform(-.07, .07))
			s.oval(x, y, r, r * .9, tone)
			s.oval(x - r * .25, y - r * .28, r * .42, r * .34, shade(tone, .16))


def bark(s, x, top, bottom, width, color, rnd):
	s.poly([(x - width * .55, top), (x + width * .55, top), (x + width, bottom), (x + width * 1.6, bottom + .7), (x, bottom + .3), (x - width * 1.6, bottom + .7), (x - width, bottom)], color)
	s.poly([(x + width * .1, top), (x + width * .55, top), (x + width, bottom), (x + width * .25, bottom + .4)], shade(color, -.26))
	for _ in range(5):
		u = rnd.uniform(-.4, .3) * width
		y = rnd.uniform(top, bottom - 1)
		s.line([(x + u, y), (x + u, y + rnd.uniform(.8, 1.8))], shade(color, -.34), .16)


def oak(colors, seed):
	rnd = random.Random(seed + 11)
	size = 1 + seed % 3 * .12
	s = Iso(36, 32, 7)
	s.shadow(3, 1, 9 * size, 4.2 * size, 95)
	bark(s, 0, -9, 0, 1.3 * size, "#5f4530", rnd)
	for sign in (-1, 1):
		s.line([(0, -7 * size), (sign * 4 * size, -11 * size)], "#553d2a", .8)
	crown = -15.5 * size
	for ox, oy, rx, ry, count in ((-3.6, 1.6, 6, 5, 62), (3.8, 1.8, 6, 5, 62), (0, -2.8, 7.4, 6.4, 110), (0, 2.2, 7.8, 4.8, 90)):
		leaves(s, rnd, ox * size, crown + oy * size, rx * size, ry * size, colors, count)
	return s.finish()


def birch(colors, seed):
	rnd = random.Random(seed + 41)
	s = Iso(26, 34, 6)
	s.shadow(2.5, 1, 6.5, 3.2, 100)
	s.poly([(-.55, -14), (.55, -14), (.8, 0), (-.8, 0)], "#ebe7dc")
	s.poly([(.05, -14), (.55, -14), (.8, 0), (.1, 0)], "#c5c1b6")
	for _ in range(9):
		y = rnd.uniform(-13, -1)
		s.line([(-.7, y), (rnd.uniform(-.1, .5), y + .2)], "#3b3832", .2)
	leaves(s, rnd, 0, -18, 5.2, 7.6, colors, 150, .78)
	return s.finish()


def pine(colors, seed):
	rnd = random.Random(seed + 71)
	base, light, dark = colors
	s = Iso(26, 40, 5)
	s.shadow(3, 1, 7, 3, 110)
	s.rect(-.8, -4, 1.6, 4, "#533c2a")
	tiers = 6 + seed % 2
	for tier in range(tiers):
		t = tier / (tiers - 1)
		y, width, tall = -3 - t * 24, 8 - t * 6.2, 8 - t * 3
		for _ in range(int(70 - t * 42)):
			u = rnd.uniform(-1, 1)
			top = y - tall * (1 - abs(u)) * rnd.uniform(.55, 1)
			x = u * width * rnd.uniform(.7, 1)
			end = y + rnd.uniform(-.4, 1)
			tone = light if u < -.25 and rnd.random() < .5 else dark if u > .2 else base
			s.poly([(x - .7, end), (x + .7, end), (x * .85, top)], shade(tone, rnd.uniform(-.1, .08)))
	return s.finish()


def bush(s, rnd, x, y, r=1.6, colors=("#4c8041", "#6fa453", "#34603a"), flowers=None):
	leaves(s, rnd, x, y - r * .7, r, r * .85, colors, int(r * 11), .42)
	if flowers:
		for _ in range(int(r * 5)):
			a, d = rnd.uniform(0, 6.28), rnd.random() ** .5
			s.oval(x + math.cos(a) * d * r, y - r * .7 + math.sin(a) * d * r * .8, .26, .24, flowers)


FLOWERS = ["#d9503f", "#e8a13a", "#c56fb0", "#f0e6d2", "#8f6fd0", "#e87f6a"]


def yard(s, rnd, x, y, dx, dy, fenced=False):
	"""The plot: a raised lawn with an edge, beds and a little path."""
	p = s.p
	s.quad([(x, y + dy, 0), (x + dx, y + dy, 0), (x + dx, y + dy, -.9), (x, y + dy, -.9)], "#4d6d36")
	s.quad([(x + dx, y + dy, 0), (x + dx, y, 0), (x + dx, y, -.9), (x + dx, y + dy, -.9)], "#3f5c30")
	s.quad([(x, y, 0), (x + dx, y, 0), (x + dx, y + dy, 0), (x, y + dy, 0)], "#6f9a4e")
	for _ in range(int(dx * dy * .8)):
		u, v = x + rnd.random() * dx, y + rnd.random() * dy
		a = p(u, v)
		s.line([a, (a[0] + rnd.uniform(-.3, .3), a[1] - .5)], rnd.choice(("#5f8a44", "#83ad5c", "#74a052")), .15)
	if fenced:
		for i in range(int(dx / 1.6) + 1):
			a = p(x + i * 1.6, y + dy)
			s.line([a, (a[0], a[1] - 1.3)], "#7b5c3e", .24)
		s.line([p(x, y + dy, 1), p(x + dx, y + dy, 1)], "#8d6c4a", .2)


# ── buildings ───────────────────────────────────────────────────────────────

def house(culture_name, tier, seed):
	rnd = random.Random(hash((culture_name, tier, seed)) & 0xffff)
	culture = dict(culture_of(culture_name))
	# no two alike: another wall here, a weathered roof there
	culture["wall"] = (culture["wall"], ALT_WALL[culture["wall"]][0], culture["wall"], ALT_WALL[culture["wall"]][1], culture["wall"], culture["wall"])[seed % 6]
	culture["base"] = {"log": "#8a5f3c", "timber": "#efe6d2", "plaster": culture["base"] if culture["wall"] == culture_of(culture_name)["wall"] else "#ead9b8", "brick": "#a8543f", "stone": "#a9a59b"}[culture["wall"]]
	culture["roof"] = shade(culture["roof"], (-.14, .1, 0, -.06, .14, -.1)[(seed + tier) % 6])
	tier = max(0, min(4, tier))
	s = Iso(58, 38, 18)
	dx, dy = 8 + tier * 1.2 + seed % 2 * 1.5, 6 + tier * .7
	dz = 3.4 + tier * 1.25
	pad = 3.4
	x, y = -dx / 2, -dy / 2
	s.shadow(2, 1.5, (dx + dy) * .85, (dx + dy) * .4, 60)
	yard(s, rnd, x - pad, y - pad, dx + pad * 2, dy + pad * 2 + 1, fenced=seed % 3 == 0)
	axis = "x" if seed % 2 == 0 else "y"
	# what stands behind the house
	for _ in range(2 + tier):
		bush(s, rnd, *s.p(x - pad + rnd.random() * (dx + pad), y - pad + .6), rnd.uniform(1.1, 1.8))
	s.ground_shadow(x, y, dx, dy, dz + 2, 120)
	wing = tier >= 2 and seed % 3 != 1
	if wing and axis == "x":
		volume(s, culture, x + 1, y - 3, 4, 4, dz * .8, rnd, axis="y")
	if wing and axis == "y":
		volume(s, culture, x - 3, y + 1, 4, 4, dz * .8, rnd, axis="x")
	ground = (.5 + (seed % 3 - 1) * .2)
	if tier >= 3:
		stone = dict(culture, wall="stone", base="#a59f92")
		box(s, x, y, 0, dx, dy, 2.6, "#a59f92")
		left, right = wall_faces(s, x, y, 0, dx, dy, 2.6)
		stone_face(left, "#b0aa9c", 3, 6, rnd)
		stone_face(right, "#8c8678", 3, 5, rnd)
		door(left, ground, 2 / dx, .86, culture["trim"])
		_, _, ridge = volume(s, culture, x, y, dx, dy, dz - 2.6, rnd, axis=axis, h=2.6, pitch=.72)
		top = dz
	else:
		_, _, ridge = volume(s, culture, x, y, dx, dy, dz, rnd, axis=axis, pitch=.68, ground_door=ground)
		top = dz
	span = dy if axis == "x" else dx
	rise = span * .68
	# dormers sit on the slope that faces the viewer, then the chimney on the ridge
	for i in range(0 if tier == 0 else 1 + (seed + tier) % 2 + (tier >= 3)):
		along = .28 + i * .36
		if axis == "x":
			dormer(s, culture, x + dx * along - 1, y + dy * .68, top + rise * .32, rnd, "x")
		else:
			dormer(s, culture, x + dx * .68, y + dy * along - 1, top + rise * .32, rnd, "y")
	if axis == "x":
		chimney(s, x + dx * (.25 + seed % 3 * .22), y + dy / 2 - .5, top + rise * .74, rnd)
	else:
		chimney(s, x + dx / 2 - .5, y + dy * (.25 + seed % 3 * .22), top + rise * .74, rnd)
	# the path from the door, the beds, the bushes in front
	dist = (x + dx * ground, y + dy)
	s.quad([(dist[0] - 1, dist[1], 0), (dist[0] + 1, dist[1], 0), (dist[0] + 1, y + dy + pad + 1, 0), (dist[0] - 1, y + dy + pad + 1, 0)], "#c6b48e")
	for i in range(4):
		v = dist[1] + i * .9 + .3
		s.quad([(dist[0] - .9, v, 0), (dist[0] + .9, v, 0), (dist[0] + .9, v + .55, 0), (dist[0] - .9, v + .55, 0)], shade("#ab9a78", rnd.uniform(-.1, .1)))
	for i in range(int(dx * .9)):
		u = x + rnd.random() * dx
		if abs(u - dist[0]) > 1.6:
			bush(s, rnd, *s.p(u, y + dy + rnd.uniform(.5, 1.6)), rnd.uniform(.55, 1), flowers=rnd.choice(FLOWERS))
	for i in range(int(dy * .7)):
		bush(s, rnd, *s.p(x + dx + rnd.uniform(.6, 1.8), y + rnd.random() * dy), rnd.uniform(.55, .95), flowers=rnd.choice(FLOWERS))
	for _ in range(1 + tier // 2):
		bush(s, rnd, *s.p(x + dx + pad - 1, y + dy + pad - rnd.uniform(.5, 3)), rnd.uniform(1.2, 2))
	return s.finish()


def round_tower(s, x, y, h, r, tall, culture, rnd, roof=True, cone=None):
	cx, cy = s.p(x, y, h)
	stone = "#a9a397"
	s.poly([(cx - r, cy), (cx - r, cy - tall), (cx + r, cy - tall), (cx + r, cy)], stone)
	s.oval(cx, cy, r, r * .5, stone)
	rows = max(3, int(tall / 1.15))
	for row in range(rows):
		v = cy - row * tall / rows
		count = max(5, int(r * 2.2))
		for i in range(count):
			a0, a1 = (i + (row % 2) * .5) / count * math.pi, (i + (row % 2) * .5 + 1) / count * math.pi
			u0, u1 = -math.cos(min(a0, math.pi)), -math.cos(min(a1, math.pi))
			tone = shade(stone, (-(u0 + u1) / 2) * -.0 + (u0 + u1) / 2 * -.28 + rnd.uniform(-.08, .08))
			y0 = v + math.sin(a0) * r * .5
			y1 = v + math.sin(min(a1, math.pi)) * r * .5
			s.poly([(cx + u0 * r, y0 - tall / rows + .1), (cx + u1 * r, y1 - tall / rows + .1), (cx + u1 * r, y1), (cx + u0 * r, y0)], tone)
	top = cy - tall
	s.oval(cx, top, r + .35, (r + .35) * .5, shade(stone, .1))
	s.oval(cx, top, r - .3, (r - .3) * .5, shade(stone, -.25))
	for i in range(7):
		a = i / 7 * math.pi
		px = cx - math.cos(a) * (r + .1)
		s.rect(px - .4, top + math.sin(a) * r * .5 - 1.1, .8, 1.3, shade(stone, -(math.cos(a)) * -.2 + .04))
	if rnd.random() < 2:
		for i in range(max(1, int(tall / 7))):
			wy = top + 3 + i * 6
			s.rect(cx - r * .3 - .35, wy, .7, 1.4, "#2f2a26")
			s.rect(cx - r * .3 - .22, wy + .1, .44, 1.2, "#f3cf7a")
	if roof:
		base = cone or culture["roof"]
		height = r * 2.3
		rows = max(4, int(height / 1.1))
		for row in range(rows):
			t0, t1 = row / rows, (row + 1) / rows
			r0, r1 = (r + .9) * (1 - t0), (r + .9) * (1 - t1)
			y0, y1 = top - height * t0, top - height * t1
			count = max(3, int(r0 * 2))
			for i in range(count):
				u0, u1 = -1 + i * 2 / count, -1 + (i + 1) * 2 / count
				tone = shade(base, (u0 + u1) / 2 * -.3 + rnd.uniform(-.1, .1))
				bow = lambda u, rad: math.sqrt(max(0, 1 - u * u)) * rad * .5
				s.poly([(cx + u0 * r1, y1 + bow(u0, r1)), (cx + u1 * r1, y1 + bow(u1, r1)), (cx + u1 * r0, y0 + bow(u1, r0)), (cx + u0 * r0, y0 + bow(u0, r0))], tone)
		s.line([(cx, top - height), (cx, top - height - 3)], "#3f352b", .28)
		s.poly([(cx, top - height - 3), (cx + 2.4, top - height - 2.4), (cx, top - height - 1.6)], "#c84b34")


def keep_door(level):
	big = 1 + max(0, level - 1) * .17
	return (int(0), 22 * big * .5 + 4)


def keep(culture_name, level, seed):
	"""The stronghold: a great hall on a stone plinth with its towers behind and beside it."""
	rnd = random.Random(seed * 13 + level)
	culture = dict(culture_of(culture_name), wall="stone", base="#b3ad9f", trim="#4a3a2c")
	big = 1 + max(0, level - 1) * .17
	dx, dy = 18 * big, 30 * big
	wall = 11 * big
	s = Iso(int(110 * big) + 16, int(92 * big) + 8, int(32 * big))
	x, y = -dx / 2, -dy / 2
	pad = 5
	s.shadow(6, 3, dx + 8, dy * .55, 80)
	# the plinth
	box(s, x - pad, y - pad, 0, dx + pad * 2, dy + pad * 2, 3.4, "#a39d90", "#8fae68")
	left, right = wall_faces(s, x - pad, y - pad, 0, dx + pad * 2, dy + pad * 2, 3.4)
	stone_face(left, "#b5afa1", 3, int((dx + pad * 2) / 2.2), rnd)
	stone_face(right, "#8e8879", 3, int((dy + pad * 2) / 2.2), rnd)
	if level >= 2:
		round_tower(s, x - 1, y - 2, 3.4, 4.6 * big, 34 * big, culture, rnd)
	if level >= 3:
		round_tower(s, x + dx + 1, y - 3, 3.4, 3.6 * big, 25 * big, culture, rnd)
		round_tower(s, x - 4, y + dy * .55, 3.4, 3.4 * big, 21 * big, culture, rnd)
	_, _, _ = volume(s, culture, x, y, dx, dy, wall, rnd, axis="y", h=3.4, pitch=.85, over=1.4, windows=False)
	left, right = wall_faces(s, x, y, 3.4, dx, dy, wall)
	# tall windows along the hall, buttresses between them
	bays = max(4, int(dy / 5))
	for i in range(bays):
		u = (i + .5) / bays
		window(right, u, .42, .5 / bays, .46, "#3f352b", shutters=False)
		if i:
			at = y + dy - i * dy / bays
			box(s, x + dx, at - .6, 3.4, 1.3, 1.2, wall * .78, "#a39d90")
	portal = .5
	left.poly([(.5 - .22, 1), (.5 - .22, .42), (.5, .16), (.5 + .22, .42), (.5 + .22, 1)], "#7d7568")
	left.poly([(.5 - .15, 1), (.5 - .15, .48), (.5, .28), (.5 + .15, .48), (.5 + .15, 1)], "#3b2a1c")
	left.line((.5, .3), (.5, 1), "#1f160e", .18)
	for sign in (-1, 1):
		left.rect(.5 + sign * .3 - .05, .18, .5 + sign * .3 + .05, .62, "#a63c2e")
		left.poly([(.5 + sign * .3 - .05, .62), (.5 + sign * .3 + .05, .62), (.5 + sign * .3, .7)], "#a63c2e")
	window(left, .5, .08, .1, .1, "#3f352b", shutters=False)
	# a small spire on the ridge
	if level >= 2:
		xm = x + dx / 2
		round_tower(s, xm, y + dy * .3, wall + 3.4 + dx * .85 * .55, 1.8 * big, 5, culture, rnd, cone=shade(culture["roof"], -.08))
	for _ in range(int(14 * big)):
		bush(s, rnd, *s.p(x - pad + rnd.random() * (dx + pad * 2), y + dy + pad - rnd.uniform(.3, 2), 3.4), rnd.uniform(.8, 1.3), flowers=rnd.choice(FLOWERS) if rnd.random() < .4 else None)
	return s.finish()


def temple(culture_name, seed):
	rnd = random.Random(seed + 91)
	culture = dict(culture_of(culture_name), wall="plaster", base="#e6dcc6", trim="#6a4a30")
	s = Iso(70, 62, 14)
	s.shadow(3, 2, 22, 10, 100)
	x, y, dx, dy = -6, -11, 12, 22
	box(s, x - 2, y - 2, 0, dx + 4, dy + 4, 1.1, "#b0aa9c", "#c7c0af")
	round_tower(s, x + 1, y - 1.5, 1.1, 3.4, 26, culture, rnd)
	volume(s, culture, x, y, dx, dy, 8, rnd, axis="y", h=1.1, pitch=.72)
	left, _ = wall_faces(s, x, y, 1.1, dx, dy, 8)
	door(left, .5, .3, .62, culture["trim"])
	window(left, .5, .16, .16, .2, culture["trim"], shutters=False)
	return s.finish()


def tavern(culture_name, seed):
	rnd = random.Random(seed + 7)
	culture = culture_of(culture_name)
	s = Iso(60, 40, 16)
	yard(s, rnd, -12, -9, 24, 21)
	s.shadow(3, 2, 16, 8, 100)
	volume(s, culture, -9, -6, 18, 11, 7.5, rnd, axis="x", pitch=.68, ground_door=.42)
	chimney(s, -3, -1, 7.5 + 3.5, rnd)
	dormer(s, culture, -6, 2, 7.5 + 1.6, rnd, "x")
	dormer(s, culture, 2, 2, 7.5 + 1.6, rnd, "x")
	sx, sy = s.p(4, 6.2, 5)
	s.line([(sx, sy), (sx + 2.2, sy)], "#3f2a1a", .3)
	s.rect(sx + 1, sy, 1.8, 2, "#c9973a")
	box(s, -7, 7.5, 0, 2.5, 1.2, 1.2, "#80593a")
	box(s, 4, 7, 0, 2.5, 1.2, 1.2, "#80593a")
	return s.finish()


def stall(seed):
	rnd = random.Random(seed + 200)
	s = Iso(24, 15, 6)
	s.shadow(1, .6, 7, 3.4, 90)
	color = ("#a63c2e", "#2f6f8f", "#c9973a", "#5b7f46", "#7a4f9a", "#c0653a")[seed % 6]
	box(s, -4.5, -2.2, 0, 9, 4.4, 2.2, "#8d6a48", "#a58259")
	for _ in range(16):
		a = s.p(rnd.uniform(-4, 4), rnd.uniform(-1.7, 1.7), 2.4)
		s.oval(a[0], a[1], .5, .42, rnd.choice(("#d9503f", "#e8a13a", "#7fae4a", "#c0955f", "#f0e0a0", "#8f5fa8")))
	for px, py in ((-4.6, 2.2), (4.6, 2.2), (4.6, -2.2)):
		s.line([s.p(px, py, 0), s.p(px, py, 6.4)], "#5a3d28", .3)
	stripes = 7
	p = s.p
	for i in range(stripes):
		u0, u1 = -5 + i * 10 / stripes, -5 + (i + 1) * 10 / stripes
		tone = color if i % 2 == 0 else "#f0e8d8"
		s.poly([p(u0, -2.8, 7.6), p(u1, -2.8, 7.6), p(u1, 3, 5.4), p(u0, 3, 5.4)], shade(tone, .03))
		s.poly([p(u0, 3, 5.4), p(u1, 3, 5.4), p(u1, 3, 4.5), ((p(u0, 3, 4.5)[0] + p(u1, 3, 4.5)[0]) / 2, (p(u0, 3, 4.5)[1] + p(u1, 3, 4.5)[1]) / 2 + .35), p(u0, 3, 4.5)], shade(tone, -.14))
	return s.finish()


def fountain(_seed):
	rnd = random.Random(5)
	s = Iso(38, 26, 12)
	s.shadow(2, 1, 12, 6, 90)
	stone = "#b8b2a4"
	for y, r, c in ((.8, 11, shade(stone, -.2)), (0, 11, stone)):
		s.oval(0, y, r, r * .5, c)
	s.oval(0, -.3, 9.6, 4.8, "#3f89a8")
	for _ in range(30):
		a, d = rnd.uniform(0, 6.28), rnd.random() ** .5
		s.oval(math.cos(a) * d * 9, -.3 + math.sin(a) * d * 4.4, rnd.uniform(.3, .9), .16, "#9fd8e8")
	s.poly([(-1.1, -.5), (1.1, -.5), (.7, -7), (-.7, -7)], stone)
	s.poly([(.1, -.5), (1.1, -.5), (.7, -7), (.1, -7)], shade(stone, -.2))
	s.oval(0, -7, 4.2, 2.1, shade(stone, -.1))
	s.oval(0, -7.3, 3.4, 1.7, "#4c9dbc")
	s.poly([(-.5, -7), (.5, -7), (.3, -11), (-.3, -11)], stone)
	s.oval(0, -11.4, 1, .9, shade(stone, .12))
	return s.finish()


def well(_seed):
	rnd = random.Random(9)
	culture = culture_of("alpine")
	s = Iso(18, 14, 5)
	s.shadow(1, .6, 5, 2.4, 80)
	round_tower(s, 0, 0, 0, 2.6, 2.4, culture, rnd, roof=False)
	for x in (-2.6, 2.6):
		s.line([(x, -1), (x, -8)], "#5a3d28", .4)
	tiled(s, (-3.6, -9.6), (3.6, -9.6), (3.6, -6.8), (-3.6, -6.8), culture["roof"], 3, 6, rnd)
	return s.finish()


def field(seed):
	"""A vegetable patch or a little orchard row, in a raised bed."""
	rnd = random.Random(seed + 301)
	s = Iso(46, 8, 14)
	dx, dy = 15, 11
	x, y = -dx / 2, -dy / 2
	s.quad([(x, y + dy, 0), (x + dx, y + dy, 0), (x + dx, y + dy, -.7), (x, y + dy, -.7)], "#5d4632")
	s.quad([(x + dx, y + dy, 0), (x + dx, y, 0), (x + dx, y, -.7), (x + dx, y + dy, -.7)], "#4b3827")
	s.quad([(x, y, 0), (x + dx, y, 0), (x + dx, y + dy, 0), (x, y + dy, 0)], "#7a5c40")
	crop = (("#4c8041", "#6fa453", "#34603a"), ("#a89a3c", "#d0c052", "#7a7030"), ("#4c8041", "#7db05a", "#34603a"))[seed % 3]
	fruit = ("#e8802c", None, "#d9503f")[seed % 3]
	rows = 5
	for r in range(rows):
		yy = y + (r + .5) * dy / rows
		s.line([s.p(x + .4, yy), s.p(x + dx - .4, yy)], "#5e4531", .3)
		for i in range(int(dx / 1.5)):
			bush(s, rnd, *s.p(x + .7 + i * 1.5, yy + .4), rnd.uniform(.55, .9), crop, fruit)
	return s.finish()


def hedge(seed):
	rnd = random.Random(seed + 330)
	s = Iso(16, 8, 4)
	s.shadow(.6, .4, 5, 1.6, 70)
	for i in range(5):
		bush(s, rnd, -4 + i * 2, .4 - i * .1, rnd.uniform(1, 1.5))
	return s.finish()


def windmill(culture_name, seed):
	"""A mill that is one: a tapered tower, a wooden cap, a gallery; the shell turns its sails."""
	rnd = random.Random(seed + 77)
	culture = culture_of(culture_name)
	s = Iso(44, 34, 10)
	s.shadow(2.5, 1.4, 11, 5, 80)
	yard(s, rnd, -9, -9, 18, 18)
	tall, bottom, top = 17, 6, 3.8
	stone = "#cfc7b4"
	rows = 12
	for row in range(rows):
		t0, t1 = row / rows, (row + 1) / rows
		r0, r1 = bottom + (top - bottom) * t0, bottom + (top - bottom) * t1
		y0, y1 = -t0 * tall, -t1 * tall
		for i in range(8):
			u0, u1 = -1 + i / 4, -1 + (i + 1) / 4
			s.poly([(u0 * r0, y0 + math.sqrt(max(0, 1 - u0 * u0)) * r0 * .5), (u1 * r0, y0 + math.sqrt(max(0, 1 - u1 * u1)) * r0 * .5), (u1 * r1, y1 + math.sqrt(max(0, 1 - u1 * u1)) * r1 * .5), (u0 * r1, y1 + math.sqrt(max(0, 1 - u0 * u0)) * r1 * .5)], shade(stone, (u0 + u1) / 2 * -.28 + rnd.uniform(-.05, .05)))
	s.oval(0, -8, 6.8, 3.2, "#6a4a30")
	s.oval(0, -8.5, 6.6, 3, "#8d6a48")
	s.poly([(-1, 2.8), (-1, -.4), (0, -1.4), (1, -.4), (1, 2.8)], "#5a3d28")
	s.rect(-2.8, -13, 1.1, 1.6, "#f3cf7a")
	roof = shade(culture["roof"], -.05)
	for i in range(10):
		u0, u1 = -1 + i / 5, -1 + (i + 1) / 5
		s.poly([(0, -tall - 7), (u0 * (top + 1), -tall + math.sqrt(max(0, 1 - u0 * u0)) * (top + 1) * .5), (u1 * (top + 1), -tall + math.sqrt(max(0, 1 - u1 * u1)) * (top + 1) * .5)], shade(roof, (u0 + u1) / 2 * -.3 + rnd.uniform(-.06, .06)))
	return s.finish()


def forge(_seed):
	rnd = random.Random(44)
	culture = dict(culture_of("hanse"), wall="stone", base="#8e8a7e", roof="#5a4a42")
	s = Iso(46, 32, 13)
	yard(s, rnd, -11, -9, 22, 19)
	s.shadow(3, 2, 13, 6, 100)
	volume(s, culture, -7, -5, 14, 10, 5, rnd, axis="x", pitch=.6, ground_door=.34)
	chimney(s, 3, -3, 8, rnd, 7)
	box(s, -8, 6, 0, 3, 1.6, 1.4, "#4a4641")
	s.oval(*s.p(2, 7, .5), 1.6, .9, "#f08a32")
	return s.finish()


def round_hall(kind, _seed=0):
	rnd = random.Random(6 + len(kind))
	culture = culture_of("southern")
	s = Iso(64, 28, 20)
	s.shadow(3, 2, 25, 12, 100)
	r = 22
	stone = "#b7b1a4"
	s.oval(0, 0, r, r * .5, shade(stone, -.2))
	s.poly([(-r, -8), (r, -8), (r, 0), (-r, 0)], stone)
	s.oval(0, 0, r, r * .5, stone)
	s.oval(0, -8, r, r * .5, shade(stone, .1))
	s.oval(0, -8, r - 4, (r - 4) * .5, "#d7bf8e" if kind == "arena" else "#a33f3a")
	for i in range(18):
		a = i / 18 * math.pi
		x, y = -math.cos(a) * r, math.sin(a) * r * .5
		s.rect(x - .75, y - 5.6, 1.5, 4, "#3f352b")
		s.oval(x, y - 5.6, .75, .7, "#3f352b")
	for i in (0, 5, 9, 13):
		a = i / 18 * math.tau
		x, y = math.cos(a) * r, -8 + math.sin(a) * r * .5
		s.line([(x, y), (x, y - 5)], "#3f352b", .25)
		s.poly([(x, y - 5), (x + 2.4, y - 4.4), (x, y - 3.7)], rnd.choice(("#c84b34", "#c9973a", "#2f6f8f")))
	return s.finish()


# ── what a city is built of ─────────────────────────────────────────────────

GROUNDS = {
	"stone": ("#a8a295", "#8f9360", ("#6f9a4e", "#8ab263", "#a39a70", "#b0a57e", "#87905c", "#769f52"), "#c0b39b"),
	"moss": ("#6f7a62", "#5f8a4c", ("#4f7f42", "#6fa053", "#5f8f4a", "#7fae58", "#3d6b3a", "#6f9a4e"), "#a89a6e"),
	"sand": ("#d2b98c", "#d8c08f", ("#e2cc9c", "#cfb684", "#d9c28f", "#c8ab7a", "#e8d6a8", "#bfa373"), "#efe0bb"),
	"dark": ("#5f5f5c", "#7c7a72", ("#6d6b64", "#85827a", "#74726a", "#8d8a80", "#66645e", "#7a786f"), "#9b978c"),
	"water": ("#9a9484", "#9aa06c", ("#7f9f58", "#8fae66", "#a39a70", "#a8a07c", "#87905c", "#769f52"), "#c9c0a8"),
}


def terrace(rx, ry, height, seed, marks, kind="stone"):
	"""A level of the town: a retaining wall in a ring, its top of the land's own ground."""
	rnd = random.Random(seed)
	rx, ry = int(rx), int(ry)
	moat = 11 if kind == "water" else 0
	s = Wide(rx * 2 + 20 + moat * 2, ry + int(height) + 8 + moat, ry + 16 + moat)
	stone, top_color, specks, street = GROUNDS[kind]
	if moat:
		s.oval(0, 1, rx + moat, ry + moat * .52, "#7f7a6a")
		s.oval(0, 0, rx + moat - 1, ry + moat * .52 - .6, "#3f89a8")
		for _ in range(rx * 3):
			a = rnd.uniform(0, 6.28)
			d = rnd.uniform(1.01, 1 + moat / rx * .9)
			s.oval(math.cos(a) * rx * d, math.sin(a) * ry * d, rnd.uniform(.6, 1.8), .22, "#9fd8e8")
	top = -height
	if height > 1:
		s.shadow(2.5, 5, rx + 3, ry + 3, 165)
	s.oval(0, 0, rx, ry, shade(stone, -.2))
	s.poly([(-rx, top), (rx, top), (rx, 0), (-rx, 0)], stone)
	# blocks along the visible front of the wall
	if height > 0:
		count = int(rx * 2.4 / 3.2)
		rows = max(2, int(height / 1.5))
		for row in range(rows):
			for i in range(count):
				a0, a1 = (i + (row % 2) * .5) / count * math.pi, (i + (row % 2) * .5 + .94) / count * math.pi
				if a1 > math.pi:
					continue
				x0, x1 = -math.cos(a0) * rx, -math.cos(a1) * rx
				y0, y1 = math.sin(a0) * ry, math.sin(a1) * ry
				off0, off1 = -height * row / rows, -height * (row + .92) / rows
				tone = shade(stone, (x0 + x1) / (2 * rx) * -.3 + (row / rows - .55) * .34 + rnd.uniform(-.08, .06))
				s.poly([(x0, y0 + off1), (x1, y1 + off1), (x1, y1 + off0), (x0, y0 + off0)], tone)
		for i in range(int(rx / 9)):
			a = rnd.uniform(.05, math.pi - .05)
			x, y = -math.cos(a) * rx, math.sin(a) * ry
			for _ in range(14):
				s.oval(x + rnd.uniform(-1.8, 1.8), y - rnd.uniform(0, height), rnd.uniform(.4, .9), rnd.uniform(.3, .7), rnd.choice(("#4f7f42", "#6fa053", "#3d6b3a")))
	s.oval(0, top, rx, ry, top_color)
	area = rx * ry
	for _ in range(int(area / 7)):
		a, d = rnd.uniform(0, 6.28), rnd.random() ** .5
		x, y = math.cos(a) * d * rx, top + math.sin(a) * d * ry
		s.oval(x, y, rnd.uniform(.5, 2.4), rnd.uniform(.3, 1.2), rnd.choice(specks))
	# the street along the ring
	band = marks
	if band:
		for i in range(int(rx * 7)):
			a = i / (rx * 7) * math.tau
			for f in band:
				for width in (-3.4, -1.1, 1.1, 3.4):
					x = math.cos(a) * (rx * f + width) * rnd.uniform(.995, 1.005)
					y = top + math.sin(a) * (ry * f + width * .52) * rnd.uniform(.995, 1.005)
					s.oval(x + rnd.uniform(-1, 1), y + rnd.uniform(-.5, .5), rnd.uniform(.9, 1.4), rnd.uniform(.5, .75), shade(street, rnd.uniform(-.14, .1)))
	# the kerb: a bright edge against the dark wall below it, a little parapet at the front
	for i in range(int(rx * 2.6)):
		a = i / (rx * 2.6) * math.tau
		x, y = math.cos(a) * (rx - .4), top + math.sin(a) * (ry - .4)
		s.oval(x, y, 1.2, .72, shade(stone, .22 + rnd.uniform(-.08, .1)))
		if height > 1 and math.sin(a) > 0 and i % 3 == 0:
			s.rect(x - .9, y - 1.3, 1.8, 1.5, shade(stone, .14 + rnd.uniform(-.08, .08)))
	return s.finish()


def ground_square(half, seed):
	"""A planned town's floor: a paved diamond, streets on a grid."""
	rnd = random.Random(seed)
	half = int(half)
	w = int(half * 1.92)
	h = int(half * .96)
	s = Wide(w * 2 + 8, h + 6, h + 6)
	s.poly([(0, -h), (w, 0), (0, h), (-w, 0)], "#8f9360")
	for _ in range(w * h // 5):
		u, v = rnd.uniform(-1, 1), rnd.uniform(-1, 1)
		s.oval((u - v) * w / 2, (u + v) * h / 2, rnd.uniform(.6, 2.2), rnd.uniform(.3, 1.1), rnd.choice(("#6f9a4e", "#a39a70", "#b0a57e", "#87905c")))
	pitch = 24
	for line in range(-int(half / pitch), int(half / pitch) + 1):
		if line % 3:
			continue
		for along in range(-half, half, 2):
			x, y = (line * pitch - along) * .96, (line * pitch + along) * .48
			s.oval(x + rnd.uniform(-1, 1), y + rnd.uniform(-.6, .6), rnd.uniform(1, 1.7), rnd.uniform(.5, .8), shade("#c0b39b", rnd.uniform(-.14, .1)))
			x, y = (along - line * pitch) * .96, (along + line * pitch) * .48
			s.oval(x + rnd.uniform(-1, 1), y + rnd.uniform(-.6, .6), rnd.uniform(1, 1.7), rnd.uniform(.5, .8), shade("#c0b39b", rnd.uniform(-.14, .1)))
	return s.finish()


def plaza(radius):
	"""The market's paving, stone by stone."""
	rnd = random.Random(radius)
	rx, ry = radius + 6, round((radius + 6) * .52)
	s = Wide(rx * 2 + 6, ry + 4, ry + 4)
	s.oval(0, .6, rx, ry, "#7d7566")
	s.oval(0, 0, rx, ry, "#a69d8a")
	for _ in range(rx * ry // 2):
		a, d = rnd.uniform(0, 6.28), rnd.random() ** .5
		s.oval(math.cos(a) * d * (rx - 1), math.sin(a) * d * (ry - .6), rnd.uniform(.8, 1.3), rnd.uniform(.45, .7), shade("#c4baa2", rnd.uniform(-.14, .1)))
	return s.finish()


def steps(dx, dy, width):
	"""A flight of steps, tread and riser each to be seen, between thick side walls."""
	dx, dy, width = int(dx), int(dy), int(width)
	reach = abs(dx) + width + 8
	s = Sheet(reach * 2, abs(dy) + 8, 7)
	stone = "#bdb6a5"
	length = math.hypot(dx, dy) or 1
	nx, ny = -dy / length, dx / length
	half = width / 2
	across = lambda x, y, sign, extra=0: (x + sign * nx * (half + extra), y + sign * ny * (half + extra) * .55)
	s.shadow(dx / 2 + 2.5, dy / 2 + 1.5, width * .8 + abs(dx) / 2, abs(dy) / 2 + 2, 130)
	count = max(4, int(length / 1.5))
	for i in range(count):
		t0, t_mid, t1 = i / count, (i + .42) / count, (i + 1) / count
		a, b, c = (dx * t0, dy * t0), (dx * t_mid, dy * t_mid), (dx * t1, dy * t1)
		s.poly([across(*a, -1), across(*a, 1), across(*b, 1), across(*b, -1)], shade(stone, -.42))
		s.poly([across(*b, -1), across(*b, 1), across(*c, 1), across(*c, -1)], shade(stone, .16))
	for sign, tone in ((-1, shade(stone, .02)), (1, shade(stone, -.34))):
		out = 1.6
		s.poly([across(0, 0, sign), across(dx, dy, sign), across(dx, dy, sign, out), across(dx, dy + 2.4, sign, out), across(0, 2.4, sign, out), across(0, 2.4, sign)], tone)
		s.line([across(0, 0, sign, out * .5), across(dx, dy, sign, out * .5)], shade(stone, .3), .5)
		for t in (0, 1):
			x, y = across(dx * t, dy * t, sign, out * .5)
			s.rect(x - .7, y - 3.8, 1.4, 4, shade(stone, -.3))
			s.oval(x, y - 4.2, .8, .75, "#f3cf7a")
	return s.finish()


def wall(dx, dy):
	"""A stretch of town wall between two points, seen from outside or within."""
	dx, dy = int(dx), int(dy)
	rnd = random.Random(dx * 31 + dy)
	tall, thick = 8.5, 3
	s = Sheet(abs(dx) * 2 + 10, abs(dy) + int(tall) + 8, abs(dy) + 6)
	stone = "#a8a295"
	s.shadow(dx / 2, dy / 2 + 1.5, abs(dx) / 2 + 2, abs(dy) / 2 + 2, 90)
	face = Face(s, (0, -tall), (dx, dy - tall), (dx, dy), (0, 0))
	tone = shade(stone, -.2 * dx / (abs(dx) + abs(dy) + 1))
	stone_face(face, tone, 5, max(3, int((abs(dx) + abs(dy)) / 3)), rnd)
	s.poly([(0, -tall), (dx, dy - tall), (dx, dy - tall - thick * .5), (0, -tall - thick * .5)], shade(stone, .16))
	count = max(2, int((abs(dx) + abs(dy)) / 3.4))
	for i in range(count + 1):
		t = i / count
		x, y = dx * t, dy * t - tall
		s.rect(x - .9, y - 2.2, 1.8, 2.2, shade(stone, rnd.uniform(-.06, .1)))
	return s.finish()


def wall_tower(culture_name):
	rnd = random.Random(12)
	s = Iso(18, 30, 6)
	s.shadow(1.2, .8, 6, 3, 90)
	round_tower(s, 0, 0, 0, 4, 13, culture_of(culture_name), rnd)
	return s.finish()


def gatehouse(culture_name):
	rnd = random.Random(13)
	culture = culture_of(culture_name)
	s = Sheet(40, 42, 8)
	s.__class__ = Iso
	s.shadow(1, 1, 18, 5, 100)
	stone = "#a8a295"
	face = Face(s, (-10, -16), (10, -16), (10, 0), (-10, 0))
	stone_face(face, stone, 7, 8, rnd)
	s.poly([(-5, 0), (-5, -9), (0, -13), (5, -9), (5, 0)], "#6d6658")
	s.poly([(-3.8, 0), (-3.8, -8.6), (0, -11.6), (3.8, -8.6), (3.8, 0)], "#32261b")
	for x in (-2.4, -.8, .8, 2.4):
		s.line([(x, -10.5), (x, -3.6)], "#57473a", .3)
	for i in range(7):
		s.rect(-10 + i * 3.1, -18, 1.8, 2.2, shade(stone, .08))
	round_tower(s, -11, 0, 0, 4.4, 19, culture, rnd) if False else None
	for x in (-12, 12):
		ax = (x + 0) / 2
		round_tower(s, ax, -ax, 0, 4.4, 19, culture, rnd)
	s.rect(-6, -15, 3, 5, "#a63c2e")
	s.rect(3, -15, 3, 5, "#a63c2e")
	return s.finish()


def great_tree(seed):
	"""The tree in the middle of a town, on its stone ring."""
	rnd = random.Random(seed + 500)
	colors = ("#8d6fb0", "#d9a8d8", "#5f4a86") if seed % 2 else ("#d97d9a", "#f4bdc9", "#a85775")
	s = Iso(60, 50, 12)
	s.shadow(2, 1, 19, 9, 90)
	s.oval(0, 1, 14, 7, "#8e8879")
	s.oval(0, 0, 14, 7, "#b5af9f")
	s.oval(0, 0, 11.5, 5.8, "#6f9a4e")
	bark(s, 0, -16, 0, 2, "#6a5040", rnd)
	for ox, oy, rx, ry, count in ((-8, -22, 9, 7, 150), (8, -22, 9, 7, 150), (0, -30, 13, 9, 260), (0, -22, 13, 7, 170)):
		leaves(s, rnd, ox, oy, rx, ry, colors, count)
	return s.finish()


def mountain(seed):
	"""A real peak: ridges falling away, rock in facets, snow in the gullies."""
	rnd = random.Random(seed + 900)
	s = Sheet(96, 66, 12)
	s.shadow(6, 2, 42, 11, 100)
	peaks = [(0, -56, 34), (-20, -34, 24), (22, -38, 26), (-34, -20, 15), (36, -18, 14)]
	for px, py, half in sorted(peaks, key=lambda p: p[1]):
		base = 4 + rnd.uniform(-1, 2)
		for i in range(26):
			u0, u1 = i / 26, (i + 1) / 26
			x0, x1 = px - half + u0 * half * 2, px - half + u1 * half * 2
			lit = (u0 < .5)
			tone = shade("#8d8a84", (.1 if lit else -.26) + rnd.uniform(-.09, .09))
			s.poly([(px + rnd.uniform(-.6, .6), py), (x0, base + rnd.uniform(-2, 2)), (x1, base + rnd.uniform(-2, 2))], tone)
		for _ in range(9):
			a = rnd.uniform(-1, 1)
			t = rnd.uniform(.2, .9)
			x = px + a * half * t
			y = py + (base - py) * t
			s.line([(x, y), (x + a * 3, y + rnd.uniform(3, 7))], shade("#6d6a64", rnd.uniform(-.1, .1)), .5)
		snow = .34 if py < -30 else .16
		s.poly([(px, py), (px - half * snow, py + (base - py) * snow), (px - half * snow * .4, py + (base - py) * snow * .78), (px - half * snow * .1, py + (base - py) * snow * 1.15), (px + half * snow * .3, py + (base - py) * snow * .8), (px + half * snow, py + (base - py) * snow)], "#f2f4f6")
		s.poly([(px, py), (px + half * snow, py + (base - py) * snow), (px + half * snow * .3, py + (base - py) * snow * .8), (px, py + (base - py) * snow * .5)], "#c9d2db")
	for _ in range(40):
		x = rnd.uniform(-46, 46)
		s.oval(x, rnd.uniform(1, 6), rnd.uniform(1, 2.2), rnd.uniform(.8, 1.4), rnd.choice(("#4f7f42", "#3d6b3a", "#5f8f4a")))
	return s.finish()


# ── fantasy ─────────────────────────────────────────────────────────────────

def dome(s, cx, cy, r, color, rnd, onion=False):
	"""A dome from ribs of tile, with a finial on top."""
	height = r * (1.5 if onion else 1.05)
	for i in range(14):
		u0, u1 = -1 + i / 7, -1 + (i + 1) / 7
		tone = shade(color, (u0 + u1) / 2 * -.3 + .05 + rnd.uniform(-.05, .05))
		pts = []
		for t in range(9):
			v = t / 8
			w = (math.sin(v * math.pi * .8 + .5) * 1.2 if onion else math.cos(v * math.pi / 2)) * r
			pts.append((cx + u0 * w, cy - height * v + math.sqrt(max(0, 1 - u0 * u0)) * w * .4))
		for t in range(8, -1, -1):
			v = t / 8
			w = (math.sin(v * math.pi * .8 + .5) * 1.2 if onion else math.cos(v * math.pi / 2)) * r
			pts.append((cx + u1 * w, cy - height * v + math.sqrt(max(0, 1 - u1 * u1)) * w * .4))
		s.poly(pts, tone)
	s.line([(cx, cy - height), (cx, cy - height - r * .55)], "#d9b24c", .3)
	s.oval(cx, cy - height - r * .55, .5, .5, "#f0d060")


def crystal(s, cx, cy, tall, width, color, rnd):
	"""A shard of crystal: facets, bright edge, glow at its foot."""
	s.oval(cx, cy, width * 1.5, width * .7, (*rgb(color), 70))
	s.poly([(cx - width, cy - tall * .18), (cx, cy - tall), (cx, cy + width * .3)], shade(color, .22))
	s.poly([(cx + width, cy - tall * .2), (cx, cy - tall), (cx, cy + width * .3)], shade(color, -.18))
	s.poly([(cx - width * .35, cy - tall * .5), (cx, cy - tall), (cx + width * .25, cy - tall * .55), (cx, cy - tall * .3)], shade(color, .5))
	s.line([(cx, cy - tall), (cx, cy + width * .3)], shade(color, .6), .16)


def wizard_body(s, x, y, h, r, tall, rnd, roof, base="#9f9aa8"):
	"""A thin tower with a jutting top room and a bent pointed hat."""
	culture = {"roof": roof, "wall": "stone", "base": base, "trim": "#3f3a5a"}
	round_tower(s, x, y, h, r, tall, culture, rnd, roof=False)
	cx, cy = s.p(x, y, h + tall)
	room = r * 1.5
	s.poly([(cx - r, cy + r * .9), (cx + r, cy + r * .9), (cx + room, cy), (cx - room, cy)], shade(base, -.25))
	s.poly([(cx - room, cy), (cx - room, cy - 4.4), (cx + room, cy - 4.4), (cx + room, cy)], base)
	s.poly([(cx, cy), (cx, cy - 4.4), (cx + room, cy - 4.4), (cx + room, cy)], shade(base, -.24))
	s.oval(cx, cy, room, room * .5, base)
	for wx in (-room * .55, 0, room * .55):
		s.rect(cx + wx - .55, cy - 3.6, 1.1, 2.4, "#f3cf7a")
	tip = rnd.choice((-1, 1)) * r * 1.1
	steps_ = 8
	last = None
	for i in range(steps_):
		t0, t1 = i / steps_, (i + 1) / steps_
		bend = lambda t: tip * t * t
		wide = lambda t: (room + 1) * (1 - t) ** 1.1
		y0, y1 = cy - 4.4 - t0 * r * 5, cy - 4.4 - t1 * r * 5
		s.poly([(cx + bend(t0) - wide(t0), y0), (cx + bend(t0) + wide(t0), y0), (cx + bend(t1) + wide(t1), y1), (cx + bend(t1) - wide(t1), y1)], shade(roof, .1 - i * .01 + rnd.uniform(-.06, .06)))
		s.poly([(cx + bend(t0) + wide(t0) * .2, y0), (cx + bend(t0) + wide(t0), y0), (cx + bend(t1) + wide(t1), y1), (cx + bend(t1) + wide(t1) * .2, y1)], shade(roof, -.24))
	for _ in range(5):
		t = rnd.uniform(.1, .8)
		s.oval(cx + tip * t * t + rnd.uniform(-1, 1) * (room * (1 - t)) * .7, cy - 4.4 - t * r * 5, .28, .28, "#ffe9a0")
	return cx + tip, cy - 4.4 - r * 5


def fhouse(style, culture_name, tier, seed):
	"""The houses of the stranger peoples."""
	rnd = random.Random(hash((style, culture_name, tier, seed)) & 0xffff)
	tier = max(0, min(4, tier))
	if style == "turret":
		image_s = Iso(58, 48, 18)
		culture = culture_of(culture_name)
		s = image_s
		yard(s, rnd, -9, -8, 18, 17)
		s.shadow(2, 1.5, 15, 7, 60)
		round_tower(s, -6.5, -5.5, 0, 2.6, 11 + tier * 2, culture, rnd, cone=shade(culture["roof"], .08))
		volume(s, culture, -6, -4, 11, 8, 4 + tier, rnd, axis="x" if seed % 2 else "y", pitch=.72, ground_door=.5 if seed % 2 else None)
		for _ in range(6):
			bush(s, rnd, *s.p(rnd.uniform(-8, 8), 6.5), rnd.uniform(.6, 1), flowers=rnd.choice(FLOWERS))
		return s.finish()
	if style == "crooked":
		s = Iso(44, 58, 16)
		culture = culture_of(culture_name)
		yard(s, rnd, -7, -7, 14, 14)
		s.shadow(2, 1.5, 10, 5, 60)
		w = 7.5
		h = 0
		for i in range(2 + tier // 2 + 1):
			shift = (seed % 3 - 1) * i * .7
			step = 3.6
			left, right = wall_faces(s, -w / 2 + shift, -w / 2 - shift, h, w, w, step)
			dress_wall(left, culture, rnd, w, step)
			dress_wall(right, culture, rnd, w, step, -.2)
			window(left, .5, .5, .24, .4, culture["trim"])
			window(right, .5, .5, .24, .4, culture["trim"], shutters=False)
			if i == 0:
				door(left, .3, .26, .78, culture["trim"])
			h += step
			w += .7
		shift = (seed % 3 - 1) * (2 + tier // 2 + 1) * .7
		volume(s, culture, -w / 2 + shift, -w / 2 - shift, w, w, .2, rnd, axis="x" if seed % 2 else "y", h=h, pitch=1.15, windows=False, over=1)
		return s.finish()
	if style == "mushroom":
		s = Iso(44, 44, 14)
		cap = ("#c0392f", "#7a4fa8", "#2f8f8a", "#c9772f", "#a63c6a", "#4a7fb8")[seed % 6]
		yard(s, rnd, -8, -7, 16, 15)
		s.shadow(2.5, 1.2, 11, 5, 70)
		r = 6.5 + tier * .9
		tall = 6 + tier * 1.4
		stem = "#efe6d0"
		s.poly([(-r * .46, 0), (-r * .34, -tall), (r * .34, -tall), (r * .46, 0)], stem)
		s.oval(0, 0, r * .46, r * .24, stem)
		s.poly([(r * .05, 0), (r * .05, -tall), (r * .34, -tall), (r * .46, 0)], shade(stem, -.2))
		s.poly([(-1.1, 1), (-1.1, -2.2), (0, -3.2), (1.1, -2.2), (1.1, 1)], "#6a4128")
		s.rect(-2.6, -5, 1.3, 1.4, "#f3cf7a")
		s.oval(0, -tall + .3, r * 1.06, r * .44, shade(cap, -.4))
		for i in range(16):
			a0, a1 = i / 16 * math.pi, (i + 1) / 16 * math.pi
			x0, x1 = -math.cos(a0), -math.cos(a1)
			tone = shade(cap, (x0 + x1) / 2 * -.28 + .04)
			s.poly([(x0 * r, -tall + math.sin(a0) * r * .3), (x1 * r, -tall + math.sin(a1) * r * .3), (x1 * r * .3, -tall - r * .9 + (1 - abs(x1)) * -r * .12), (x0 * r * .3, -tall - r * .9 + (1 - abs(x0)) * -r * .12)], tone)
		s.oval(0, -tall - r * .86, r * .36, r * .16, shade(cap, .12))
		for _ in range(9 + tier * 2):
			a = rnd.uniform(.2, math.pi - .2)
			d = rnd.uniform(.25, .9)
			x, y = -math.cos(a) * d * r, -tall - (1 - d) * r * .8 + math.sin(a) * r * .24 * d
			size = rnd.uniform(.5, 1.05)
			s.oval(x, y, size, size * .68, "#f6efe0")
		s.line([(r * .45, -tall - r * .55), (r * .5, -tall - r * 1.05)], "#7a5c44", .7)
		for _ in range(5):
			bush(s, rnd, *s.p(rnd.uniform(-7, 7), 6), rnd.uniform(.5, .9), flowers=rnd.choice(FLOWERS))
		return s.finish()
	if style == "treehouse":
		s = Iso(62, 64, 12)
		s.shadow(3, 1, 13, 6, 80)
		bark(s, 0, -24, 0, 3.4, "#5f4530", rnd)
		colors = (("#3f7f4a", "#6bb06a", "#2b5c3b"), ("#3f8f7f", "#79c7b0", "#2a6258"), ("#5f8f3f", "#93bf5c", "#3f662c"))[seed % 3]
		for ox, oy, rx, ry, count in ((-7, -36, 10, 8, 150), (7, -36, 10, 8, 150), (0, -43, 13, 10, 240)):
			leaves(s, rnd, ox, oy, rx, ry, colors, count)
		# the deck, the cabin on it, the lantern and the stair round the trunk
		s.oval(0, -19, 10, 5, "#6a4a30")
		s.oval(0, -19.8, 10, 5, "#8d6a48")
		for i in range(14):
			a = i / 14 * math.pi
			x, y = -math.cos(a) * 10, -20 + math.sin(a) * 5
			s.line([(x, y), (x, y - 1.6)], "#5a3d28", .25)
		culture = {"roof": "#7f6a3f", "wall": "log", "base": "#8a6a44", "trim": "#4a3222"}
		sheet = s
		x, y = sheet.p(0, 0, 0)
		s.oy -= 20
		volume(s, culture, -3, -3, 6, 5.4, 3.4, rnd, axis="x", pitch=.8, ground_door=.5)
		s.oy += 20
		for t in (1.2, 5, 9, 13):
			s.line([(-3.4 - t * .4, -t), (3.4 - t * .1, -t - 1)], "#8d6a48", .55)
		for lx, ly in ((-9, -24), (8, -23)):
			s.line([(lx, ly - 2), (lx, ly)], "#3f2a1a", .16)
			s.oval(lx, ly + .4, .6, .7, "#ffd27a")
		return s.finish()
	if style == "dome":
		s = Iso(50, 42, 16)
		base = ("#ead9b8", "#e6c9a0", "#f0e6d2", "#dcc2a8")[seed % 4]
		cap = ("#2f8a84", "#c9973a", "#3f6fa8", "#a8503f")[(seed + tier) % 4]
		yard(s, rnd, -9, -9, 18, 18)
		s.shadow(2, 1.5, 14, 7, 60)
		culture = {"roof": cap, "wall": "plaster", "base": base, "trim": "#8a6a48"}
		w, h = 10 + tier * .6, 4.5 + tier
		left, right = wall_faces(s, -w / 2, -w / 2, 0, w, w, h)
		plaster_face(left, base, rnd)
		plaster_face(right, shade(base, -.2), rnd)
		for face, shadeit in ((left, 0), (right, 1)):
			for i in range(2 + tier // 2):
				u = (i + .5) / (2 + tier // 2)
				face.poly([(u - .1, .78), (u - .1, .36), (u, .2), (u + .1, .36), (u + .1, .78)], "#6a4a30" if i == 0 and not shadeit else "#f3cf7a")
		s.quad([(-w / 2, -w / 2, h), (w / 2, -w / 2, h), (w / 2, w / 2, h), (-w / 2, w / 2, h)], shade(base, .08))
		for i in range(int(w * 2)):
			t = i / int(w * 2)
			s.rect(*s.p(-w / 2 + t * w, w / 2, h + .7), .5, .7, shade(base, -.06))
			s.rect(*s.p(w / 2, w / 2 - t * w, h + .7), .5, .7, shade(base, -.22))
		cx, cy = s.p(0, 0, h)
		dome(s, cx, cy, w * .36, cap, rnd, onion=seed % 2 == 0)
		if tier >= 2:
			px, py = s.p(w / 2 + .6, -w / 2 - .6, 0)
			s.poly([(px - 1.2, py), (px - .9, py - h * 2.2), (px + .9, py - h * 2.2), (px + 1.2, py)], base)
			s.poly([(px, py), (px, py - h * 2.2), (px + .9, py - h * 2.2), (px + 1.2, py)], shade(base, -.22))
			dome(s, px, py - h * 2.2, 1.5, cap, rnd, onion=True)
		return s.finish()
	if style == "dwarf":
		s = Iso(56, 34, 16)
		stone = ("#6f6e6a", "#7a7063", "#5f6468")[seed % 3]
		s.shadow(2.5, 1.5, 15, 7, 90)
		w, d = 13 + tier, 9 + tier * .6
		box(s, -w / 2 - 1.5, -d / 2 - 1.5, 0, w + 3, d + 3, 1.2, shade(stone, -.1), shade(stone, .12))
		for level, (shrink, tall) in enumerate(((0, 4 + tier), (2.2, 2.6), (4.4, 2))):
			h = 1.2 + ((4 + tier) if level >= 1 else 0) + (2.6 if level >= 2 else 0)
			left, right = wall_faces(s, -w / 2 + shrink, -d / 2 + shrink * .6, h, w - shrink * 2, d - shrink * 1.2, tall)
			stone_face(left, shade(stone, .1), 3 + level, 6, rnd)
			stone_face(right, shade(stone, -.2), 3 + level, 5, rnd)
			s.quad([(-w / 2 + shrink, -d / 2 + shrink * .6, h + tall), (w / 2 - shrink, -d / 2 + shrink * .6, h + tall), (w / 2 - shrink, d / 2 - shrink * .6, h + tall), (-w / 2 + shrink, d / 2 - shrink * .6, h + tall)], shade(stone, .2))
		left, right = wall_faces(s, -w / 2, -d / 2, 1.2, w, d, 4 + tier)
		left.poly([(.34, 1), (.34, .3), (.5, .12), (.66, .3), (.66, 1)], "#3a342c")
		left.poly([(.4, 1), (.4, .36), (.5, .24), (.6, .36), (.6, 1)], "#ff9a3c")
		for u in (.14, .86):
			left.rect(u - .035, .25, u + .035, .75, "#7fd0e8")
		for v in (.3, .55):
			right.rect(.2, v, .3, v + .12, "#f08a32")
			right.rect(.7, v, .8, v + .12, "#f08a32")
		chimney(s, w / 2 - 4, -d / 2 + .5, 6, rnd, 6)
		return s.finish()
	if style == "crystal":
		s = Iso(44, 58, 14)
		color = ("#7fd0e8", "#b48cf0", "#6fe0b0", "#f08ad0")[seed % 4]
		s.shadow(2, 1, 10, 5, 70)
		s.oval(0, .8, 9, 4.5, "#5f5a68")
		s.oval(0, 0, 9, 4.5, "#878292")
		tall = 20 + tier * 5
		crystal(s, 0, -1, tall, 3.6 + tier * .4, color, rnd)
		for sign, size in ((-1, .55), (1, .45), (-.5, .35)):
			crystal(s, sign * 4.5, 1, tall * size, 1.8, color, rnd)
		culture = {"roof": "#3f3a5a", "wall": "stone", "base": "#a59fb0", "trim": "#3f3a5a"}
		volume(s, culture, 2, 0, 5, 4.4, 3, rnd, axis="y", pitch=.8, ground_door=.5)
		return s.finish()
	if style == "wizard":
		s = Iso(40, 66, 12)
		roof = ("#4a3f9a", "#7a2f7f", "#2f6f8f", "#8f3f4f")[seed % 4]
		yard(s, rnd, -6, -6, 12, 12)
		s.shadow(2, 1, 9, 4.5, 70)
		tipx, tipy = wizard_body(s, 0, 0, 0, 2.8 + tier * .2, 13 + tier * 2.4, rnd, roof)
		s.oval(tipx, tipy - 1.6, 1.1, 1.1, ("#ffe07a", "#9fe8ff", "#d8a0ff", "#a0ffb8")[seed % 4])
		return s.finish()
	return house(culture_name, tier, seed)


def palm(seed):
	rnd = random.Random(seed + 610)
	s = Iso(30, 28, 5)
	s.shadow(2.5, .8, 6, 2.6, 80)
	lean = (seed % 3 - 1) * 2.6
	for i in range(12):
		t0, t1 = i / 12, (i + 1) / 12
		y0, y1 = -t0 * 17, -t1 * 17
		s.poly([(lean * t0 * t0 - .8, y0), (lean * t0 * t0 + .8, y0), (lean * t1 * t1 + .7, y1 + .2), (lean * t1 * t1 - .7, y1 + .2)], shade("#8a6b48", .1 if i % 2 else -.1))
	for i in range(9):
		a = i / 9 * math.tau
		dx, dy = math.cos(a) * 9, math.sin(a) * 3 - 1
		pts = [(lean, -17), (lean + dx * .5, -17 + dy * .5 - 2.6), (lean + dx, -17 + dy + 1.6), (lean + dx * .5, -17 + dy * .5 - 1)]
		s.poly(pts, shade("#4f8f3f", rnd.uniform(-.14, .16)))
	for x in (-.8, .8):
		s.oval(lean + x, -16.2, .7, .7, "#6a4628")
	return s.finish()


def landmark(kind, seed):
	"""What a town shows off with."""
	rnd = random.Random(seed + 700)
	if kind == "crystal":
		s = Iso(40, 54, 10)
		color = ("#7fd0e8", "#b48cf0", "#6fe0b0")[seed % 3]
		s.shadow(2, 1, 11, 5, 70)
		s.oval(0, 0, 11, 5.5, "#6d6878")
		crystal(s, 0, 0, 40, 5, color, rnd)
		crystal(s, -6, 1.6, 20, 2.8, color, rnd)
		crystal(s, 6, 1.2, 25, 3.2, color, rnd)
		return s.finish()
	if kind == "stones":
		s = Iso(44, 18, 12)
		s.oval(0, 0, 17, 8.5, "#6f9a4e")
		for i in range(9):
			a = i / 9 * math.tau
			x, y = math.cos(a) * 14, math.sin(a) * 7
			tall = rnd.uniform(6, 11)
			s.shadow(x + 1, y + .4, 2.4, 1, 80)
			s.poly([(x - 1.5, y), (x - 1.1, y - tall), (x + 1.1, y - tall - .7), (x + 1.5, y)], "#94918a")
			s.poly([(x + .2, y), (x + .2, y - tall), (x + 1.1, y - tall - .7), (x + 1.5, y)], "#716e68")
			s.line([(x - .6, y - tall * .35), (x - .6, y - tall * .75)], "#7fe0f0", .3)
		s.oval(0, 0, 3, 1.5, (127, 224, 240, 150))
		return s.finish()
	if kind == "portal":
		s = Iso(36, 38, 8)
		s.shadow(1, 1, 12, 4, 80)
		stone = "#8f8a9a"
		for sign in (-1, 1):
			s.poly([(sign * 9 - 2, 0), (sign * 8 - 2, -20), (sign * 8 + 2, -20), (sign * 9 + 2, 0)], stone if sign < 0 else shade(stone, -.2))
		for i in range(16):
			a0, a1 = i / 16 * math.pi, (i + 1) / 16 * math.pi
			s.poly([(-math.cos(a0) * 10, -20 - math.sin(a0) * 10), (-math.cos(a1) * 10, -20 - math.sin(a1) * 10), (-math.cos(a1) * 6, -20 - math.sin(a1) * 6), (-math.cos(a0) * 6, -20 - math.sin(a0) * 6)], shade(stone, -.1 if i % 2 else .08))
		for r, tone in ((6, "#5f3fb0"), (4.8, "#8f6fe8"), (3.2, "#cdb8ff")):
			s.oval(0, -20, r, r, tone)
			s.poly([(-r, -20), (r, -20), (r * .92, -1), (-r * .92, -1)], tone)
		return s.finish()
	# a dragon of stone on its plinth
	s = Iso(46, 36, 8)
	s.shadow(1.5, 1, 11, 4.5, 80)
	box(s, -5, -5, 0, 10, 10, 3, "#9b978a", "#b0ac9e")
	stone = "#7f8580"
	s.poly([(-9, -9), (-1, -13), (5, -12), (9, -7), (5, -6), (-5, -6)], stone)
	s.poly([(-6, -12), (-11, -27), (-2, -22), (0, -28), (3, -21), (4, -12)], shade(stone, .12))
	s.poly([(4, -12), (8, -20), (12, -21), (14, -18), (9, -17), (8, -8)], stone)
	s.oval(13, -19, .5, .5, "#ff5a3c")
	s.line([(-9, -8), (-15, -6), (-17, -10)], stone, 1.2)
	return s.finish()


def seatx(style, culture_name, level, seed):
	"""The strongholds that are not halls."""
	rnd = random.Random(hash((style, level, seed)) & 0xffff)
	big = 1 + max(0, level - 1) * .17
	if style == "spires":
		s = Iso(int(100 * big), int(120 * big), 26)
		s.oval(0, 2, 34 * big, 17 * big, "#59536a")
		s.oval(0, 0, 34 * big, 17 * big, "#878292")
		roofs = ("#4a3f9a", "#7a2f7f", "#2f6f8f")
		spots = sorted(((math.cos(i * 1.9) * 20 * big, math.sin(i * 1.9) * 7 * big) for i in range(4 + level)), key=lambda p: p[1])
		for i, (x, y) in enumerate(spots):
			u, v = (y * 2 + x) / 2, (y * 2 - x) / 2
			wizard_body(s, u, v, 0, 3 + (i % 3), (20 + (i * 7) % 18) * big, rnd, roofs[i % 3])
		wizard_body(s, 0, 2, 0, 6 * big, 46 * big, rnd, roofs[seed % 3])
		crystal(s, 0, 10 * big, 14, 2, "#9fe8ff", rnd)
		return s.finish()
	if style == "palace":
		s = Iso(int(110 * big), int(84 * big), 28)
		base, cap = "#efe3c8", ("#2f8a84", "#c9973a", "#3f6fa8")[seed % 3]
		s.shadow(4, 2, 40 * big, 18 * big, 80)
		w = 30 * big
		box(s, -w / 2 - 4, -w / 2 - 4, 0, w + 8, w + 8, 2.4, base, shade(base, .1))
		h = 2.4
		left, right = wall_faces(s, -w / 2, -w / 2, h, w, w, 12 * big)
		plaster_face(left, base, rnd)
		plaster_face(right, shade(base, -.2), rnd)
		for face, dim in ((left, 0), (right, 1)):
			for i in range(5):
				u = (i + .5) / 5
				face.poly([(u - .06, .9), (u - .06, .4), (u, .22), (u + .06, .4), (u + .06, .9)], "#3b2a1c" if i == 2 and not dim else "#f3cf7a")
		s.quad([(-w / 2, -w / 2, h + 12 * big), (w / 2, -w / 2, h + 12 * big), (w / 2, w / 2, h + 12 * big), (-w / 2, w / 2, h + 12 * big)], shade(base, .08))
		for x, y, r in ((-w * .28, -w * .28, 5), (w * .28, -w * .28, 5), (-w * .28, w * .28, 5), (w * .28, w * .28, 5), (0, 0, 11)):
			cx, cy = s.p(x, y, h + 12 * big)
			dome(s, cx, cy, r * big, cap, rnd, onion=True)
		for x, y in ((-w / 2 - 3, -w / 2 - 3), (w / 2 + 3, -w / 2 - 3), (-w / 2 - 3, w / 2 + 3), (w / 2 + 3, w / 2 + 3)):
			px, py = s.p(x, y, 2.4)
			s.poly([(px - 2, py), (px - 1.4, py - 34 * big), (px + 1.4, py - 34 * big), (px + 2, py)], base)
			s.poly([(px, py), (px, py - 34 * big), (px + 1.4, py - 34 * big), (px + 2, py)], shade(base, -.2))
			dome(s, px, py - 34 * big, 2.4, cap, rnd, onion=True)
		return s.finish()
	if style == "gate":
		# a hall hewn out of the rock: stepped front, giants beside the glowing door
		s = Iso(int(100 * big), int(86 * big), 18)
		stone = "#6d6c68"
		s.shadow(3, 2, 34 * big, 13 * big, 100)
		w = 56 * big
		for i in range(5):
			shrink, top = i * 5 * big, (64 - i * 11) * big
			down = (i * 11) * big
			s.poly([(-w / 2 + shrink, -down), (-w / 2 + shrink, -down - 13 * big), (w / 2 - shrink, -down - 13 * big), (w / 2 - shrink, -down)], shade(stone, .04 - i * .01))
			for r in range(4):
				for c in range(int((w - shrink * 2) / 4)):
					x = -w / 2 + shrink + (c + (r % 2) * .5) * 4
					if x + 3.7 < w / 2 - shrink:
						s.rect(x, -down - (r + 1) * 3.2 * big, 3.7, 2.9 * big, shade(stone, rnd.uniform(-.1, .08)))
		s.poly([(-9 * big, 0), (-9 * big, -22 * big), (0, -32 * big), (9 * big, -22 * big), (9 * big, 0)], "#3a342c")
		s.poly([(-6.5 * big, 0), (-6.5 * big, -21 * big), (0, -28 * big), (6.5 * big, -21 * big), (6.5 * big, 0)], "#ff9a3c")
		s.poly([(-4 * big, 0), (-4 * big, -18 * big), (0, -24 * big), (4 * big, -18 * big), (4 * big, 0)], "#ffd27a")
		for sign in (-1, 1):
			x = sign * 20 * big
			s.poly([(x - 4, 0), (x - 3, -26 * big), (x + 3, -26 * big), (x + 4, 0)], shade(stone, .12))
			s.oval(x, -29 * big, 3, 3.2, shade(stone, .16))
			s.poly([(x - 3.2, -24 * big), (x - 6, -14 * big), (x - 3, -14 * big)], shade(stone, -.1))
			s.poly([(x + 3.2, -24 * big), (x + 6, -14 * big), (x + 3, -14 * big)], shade(stone, -.2))
			s.poly([(x - 2, -27 * big), (x + 2, -27 * big), (x, -18 * big)], "#d9d4c8")
		return s.finish()
	if style == "tree":
		s = Iso(int(130 * big), int(120 * big), 22)
		s.shadow(4, 2, 42 * big, 18 * big, 90)
		bark(s, 0, -58 * big, 0, 9 * big, "#6a5140", rnd)
		for sign in (-1, 1):
			s.line([(sign * 3, -40 * big), (sign * 26 * big, -62 * big)], "#5f4635", 3.4)
			s.line([(sign * 8, 2), (sign * 22, 6)], "#5f4635", 2.2)
		colors = ("#2f8f7f", "#7fe0c0", "#1f5f58")
		for ox, oy, rx, ry, count in ((-24, -66, 20, 14, 280), (24, -66, 20, 14, 280), (0, -84, 28, 19, 520), (0, -62, 28, 12, 300)):
			leaves(s, rnd, ox * big, oy * big, rx * big, ry * big, colors, count)
		culture = {"roof": "#2f7f6f", "wall": "plaster", "base": "#e8e6d2", "trim": "#5f4635"}
		for x, h in ((-13, 14), (11, 24), (-9, 34)):
			s.oval(x * big, -h * big + 2, 10, 5, "#8d6a48")
			s.oy -= h * big
			s.ox += x * big
			volume(s, culture, -3, -3, 6, 5, 3.4, rnd, axis="y" if h % 2 else "x", pitch=.9, ground_door=.5)
			s.oy += h * big
			s.ox -= x * big
		for _ in range(40):
			s.oval(rnd.uniform(-44, 44) * big, rnd.uniform(-100, -40) * big, .5, .5, "#ffe9a0")
		return s.finish()
	if style == "citadel":
		s = Iso(int(100 * big), int(120 * big), 24)
		color = ("#7fd0e8", "#b48cf0", "#6fe0b0")[seed % 3]
		s.shadow(3, 2, 34 * big, 15 * big, 80)
		s.oval(0, 2, 33 * big, 16.5 * big, "#55505f")
		s.oval(0, 0, 33 * big, 16.5 * big, "#878292")
		for i in range(7):
			a = i / 7 * math.tau + .3
			if math.sin(a) < 0:
				crystal(s, math.cos(a) * 22 * big, math.sin(a) * 11 * big, (34 + i * 3) * big, 5 * big, color, rnd)
		crystal(s, 0, -2, 92 * big, 12 * big, color, rnd)
		for i in range(7):
			a = i / 7 * math.tau + .3
			if math.sin(a) >= 0:
				crystal(s, math.cos(a) * 22 * big, math.sin(a) * 11 * big, (22 + i * 2) * big, 4 * big, color, rnd)
		s.poly([(-5, 15 * big), (-5, 4), (0, 0), (5, 4), (5, 15 * big)], "#3f3a5a")
		s.poly([(-3, 15 * big), (-3, 5), (0, 2.4), (3, 5), (3, 15 * big)], color)
		return s.finish()
	return keep(culture_name, level, seed)


def floating_isle(rx, seed):
	"""A chunk of land in the air, roots and rock below it, a thread of water falling off."""
	rnd = random.Random(seed + 810)
	rx = int(rx)
	ry = round(rx * .52)
	deep = int(rx * .9)
	s = Wide(rx * 2 + 8, ry + 6, ry + deep + 8)
	for i in range(int(rx * 1.6)):
		x = rnd.uniform(-rx, rx) * .96
		edge = math.sqrt(max(0, 1 - (x / rx) ** 2))
		down = edge * deep * rnd.uniform(.45, 1)
		tone = shade("#7a6a58", rnd.uniform(-.2, .1) + (x / rx) * -.18)
		s.poly([(x - rnd.uniform(1.5, 4), edge * ry * .6), (x + rnd.uniform(1.5, 4), edge * ry * .6), (x + rnd.uniform(-.6, .6), edge * ry * .6 + down)], tone)
	s.oval(0, 1.6, rx, ry, "#6a5a48")
	s.oval(0, 0, rx, ry, "#7fa55a")
	for _ in range(rx * ry // 7):
		a, d = rnd.uniform(0, 6.28), rnd.random() ** .5
		s.oval(math.cos(a) * d * rx, math.sin(a) * d * ry, rnd.uniform(.5, 2), rnd.uniform(.3, 1), rnd.choice(("#6f9a4e", "#8ab263", "#769f52")))
	fx = rx * .4
	for i in range(12):
		s.line([(fx + i * .15, ry * .7 + i * deep * .1), (fx + i * .15, ry * .7 + (i + 1) * deep * .1)], (*rgb("#bfe8f4"), 220 - i * 16), .8)
	return s.finish()


def isle_shadow(rx):
	rx = int(rx)
	s = Wide(rx * 2 + 8, rx // 2 + 6, rx // 2 + 6)
	s.oval(0, 0, rx, rx * .5, (20, 28, 26, 90))
	return s.finish()


def rope(dx, dy):
	dx, dy = int(dx), int(dy)
	s = Wide(abs(dx) * 2 + 8, abs(dy) + 8, abs(dy) + 8)
	for sag, c in ((0, "#8d6a48"), (-1.6, "#6a4a30")):
		pts = [(dx * i / 12, dy * i / 12 + math.sin(i / 12 * math.pi) * 4 + sag) for i in range(13)]
		s.line(pts, c, .6)
	for i in range(1, 12):
		x, y = dx * i / 12, dy * i / 12 + math.sin(i / 12 * math.pi) * 4
		s.line([(x, y), (x, y - 1.6)], "#6a4a30", .2)
	return s.finish()


# ── all the small things ────────────────────────────────────────────────────

def sheep(seed):
	rnd = random.Random(seed + 40)
	s = Iso(14, 8, 3)
	s.shadow(.8, .5, 3.4, 1.4, 90)
	for x in (-1.8, -.6, .8, 2):
		s.line([(x, -1.4), (x, .2)], "#3f3a36", .34)
	for _ in range(26):
		a, d = rnd.uniform(0, 6.28), rnd.random() ** .5
		x, y = math.cos(a) * d * 2.9, -2.7 + math.sin(a) * d * 1.6
		s.oval(x, y, .85, .75, shade("#eeeade", (-x * .03 - (y + 2.7) * .1 + rnd.uniform(-.05, .05))))
	side = 1 if seed % 2 else -1
	s.oval(side * 3.2, -3.2, 1, .85, "#3f3a36")
	s.oval(side * 2.7, -3.9, .5, .3, "#3f3a36")
	return s.finish()


def flowers(seed):
	rnd = random.Random(seed + 50)
	s = Iso(26, 8, 8)
	for _ in range(14):
		x, y = rnd.uniform(-10, 10), rnd.uniform(-3.5, 5)
		s.oval(x, y, rnd.uniform(1, 2.4), rnd.uniform(.5, 1), rnd.choice(("#79a854", "#5f9147", "#8ebb60")))
	for _ in range(70):
		x, y = rnd.uniform(-11, 11), rnd.uniform(-4, 6)
		tall = rnd.uniform(.7, 1.6)
		s.line([(x, y), (x + rnd.uniform(-.2, .2), y - tall)], "#4f7f42", .14)
		color = rnd.choice(FLOWERS)
		for a in range(4):
			s.oval(x + math.cos(a * 1.57) * .3, y - tall + math.sin(a * 1.57) * .2, .24, .2, color)
		s.oval(x, y - tall, .13, .13, "#ffe07a")
	return s.finish()


def rock(seed):
	rnd = random.Random(seed + 60)
	s = Iso(20, 10, 5)
	s.shadow(1.5, .8, 7, 2.8, 100)
	for ox, oy, size in ((-3, 0, 3.4), (2.6, .8, 4.4), (0, 1.8, 2.6)):
		tone = shade("#8f8b82", rnd.uniform(-.1, .08))
		s.poly([(ox - size, oy), (ox - size * .7, oy - size * .8), (ox + size * .1, oy - size * 1.2), (ox + size, oy - size * .5), (ox + size, oy + size * .2), (ox, oy + size * .4)], tone)
		s.poly([(ox + size * .1, oy - size * 1.2), (ox + size, oy - size * .5), (ox + size, oy + size * .2), (ox + size * .1, oy + size * .4)], shade(tone, -.24))
		s.poly([(ox - size * .7, oy - size * .8), (ox + size * .1, oy - size * 1.2), (ox + size * .1, oy - size * .4)], shade(tone, .16))
	return s.finish()


def cart(seed):
	rnd = random.Random(seed + 70)
	s = Iso(26, 15, 6)
	s.shadow(1.5, 1, 7, 3, 90)
	for x, y in ((-3, 2.6), (3, 2.6)):
		cx, cy = s.p(x, y, 1.4)
		s.oval(cx, cy, 1.5, 1.6, "#4a3222")
		s.oval(cx, cy, 1, 1.1, "#8d6a48")
		s.oval(cx, cy, .3, .3, "#3f2a1a")
	box(s, -5, -2, 1.6, 10, 4, 2.2, "#8d6a48", "#6a4a30")
	left, right = wall_faces(s, -5, -2, 1.6, 10, 4, 2.2)
	wood_face(left, "#9a7650", 8, rnd)
	wood_face(right, "#6f5236", 4, rnd)
	for _ in range(16):
		a = s.p(rnd.uniform(-4.2, 4.2), rnd.uniform(-1.4, 1.4), 3.9)
		s.oval(a[0], a[1] - rnd.uniform(0, .9), .75, .6, rnd.choice(("#d9b24c", "#c9973a", "#b8863a", "#e8c66a")))
	s.line([s.p(5, 0, 2), s.p(10, 0, 1)], "#6a4a30", .36)
	return s.finish()


def crates(seed):
	seed = seed if isinstance(seed, int) else 0
	rnd = random.Random(seed + 80)
	s = Iso(16, 10, 4)
	s.shadow(.8, .5, 5, 2, 90)
	for x, y, h, size in ((-2.6, -1.2, 0, 2.4), (.4, .6, 0, 2.2), (-1.6, -.6, 2.4, 1.7)):
		box(s, x, y, h, size, size, size, "#9a7650", "#b08b62")
		left, right = wall_faces(s, x, y, h, size, size, size)
		wood_face(left, "#a57f58", 3, rnd)
		wood_face(right, "#7a5a3c", 3, rnd)
	cx, cy = s.p(3.6, -1.6)
	s.poly([(cx - 1.2, cy), (cx - 1.4, cy - 1.6), (cx - 1, cy - 3), (cx + 1, cy - 3), (cx + 1.4, cy - 1.6), (cx + 1.2, cy)], "#8d6a48")
	s.oval(cx, cy - 3, 1, .5, "#5f4530")
	return s.finish()


def statue(seed):
	rnd = random.Random(seed + 90)
	s = Iso(18, 24, 5)
	s.shadow(1, .6, 5, 2.4, 90)
	box(s, -2.4, -2.4, 0, 4.8, 4.8, 2.6, "#a8a295", "#bdb7a9")
	left, right = wall_faces(s, -2.4, -2.4, 0, 4.8, 4.8, 2.6)
	stone_face(left, "#b4ae9f", 2, 3, rnd)
	stone_face(right, "#8e8879", 2, 3, rnd)
	bronze = "#5f8f7f"
	s.poly([(-1.7, -2.6), (-1.5, -8), (-1.8, -13), (1.8, -13), (1.5, -8), (1.7, -2.6)], bronze)
	s.poly([(.2, -2.6), (.2, -13), (1.8, -13), (1.5, -8), (1.7, -2.6)], shade(bronze, -.24))
	s.oval(0, -14.4, 1.3, 1.4, shade(bronze, .1))
	s.line([(1.7, -12.4), (3.4, -18)], bronze, .6)
	s.line([(2.3, -16.4), (4.4, -16.8)], "#c9973a", .3)
	s.poly([(-1.8, -13), (-3, -8), (-1.6, -7)], shade(bronze, .12))
	return s.finish()


def gold_pile(amount, seed=0):
	rnd = random.Random(f"gold{seed}")
	size = 2.4 + min(5, float(amount) if str(amount).replace(".", "").isdigit() else 2) * .5
	s = Iso(int(size * 5) + 6, int(size * 2.2) + 4, 4)
	s.shadow(.8, .4, size * 1.4, size * .55, 80)
	for _ in range(int(size * 42)):
		a, d = rnd.uniform(0, 6.28), rnd.random() ** .6
		x = math.cos(a) * d * size * 1.3
		y = -(1 - d) * size * 1.3 + math.sin(a) * d * size * .4
		tone = shade(rnd.choice(("#e8c044", "#d9a830", "#f4d868")), -x * .03)
		s.oval(x, y, .55, .36, shade(tone, -.3))
		s.oval(x, y - .12, .52, .32, tone)
	for _ in range(6):
		s.oval(rnd.uniform(-size, size), -rnd.uniform(0, size), .16, .16, "#fff6c8")
	return s.finish()


def milestone(seed):
	"""A standing stone with runes for a finished task."""
	rnd = random.Random(seed + 100)
	s = Iso(12, 12, 3)
	s.shadow(.7, .4, 3, 1.3, 90)
	s.poly([(-1.9, .3), (-1.5, -7), (-.2, -8.6), (.3, .6)], "#a9a59a")
	s.poly([(.3, .6), (-.2, -8.6), (1.4, -7.2), (1.9, -.1)], "#7f7c72")
	for i in range(4):
		y = -6.6 + i * 1.5
		s.line([(-1.1, y), (-.4, y + .5), (-.9, y + .9)], "#6fd0e0", .18)
	for _ in range(8):
		s.oval(rnd.uniform(-2.4, 2.4), rnd.uniform(-.2, .8), rnd.uniform(.3, .7), .3, rnd.choice(("#4f7f42", "#6fa053")))
	return s.finish()


def campfire(seed):
	rnd = random.Random(int(seed or 0) + 110)
	s = Iso(14, 11, 4)
	for i in range(9):
		a = i / 9 * 6.28
		s.oval(math.cos(a) * 3, math.sin(a) * 1.5, .75, .5, shade("#8f8b82", rnd.uniform(-.14, .1)))
	for a, b in (((-2.4, .6), (2, -1.2)), ((2.4, .6), (-2, -1.2)), ((0, 1), (0, -2))):
		s.line([a, b], "#5a3d28", .7)
	s.poly([(-1.6, 0), (-.8, -3), (0, -5.6), (.9, -3), (1.6, 0)], "#e8702c")
	s.poly([(-.9, 0), (-.3, -2.4), (.1, -3.8), (.7, -1.8), (.9, 0)], "#ffcf5a")
	return s.finish()


def ruin(seed):
	rnd = random.Random(seed + 120)
	s = Iso(50, 26, 12)
	s.shadow(2, 1, 14, 6, 90)
	stone = "#9a968a"
	s.quad([(-10, -8, 0), (10, -8, 0), (10, 8, 0), (-10, 8, 0)], "#7f8f62")
	for x, y, dx, dy, tall in ((-9, -7, 16, 2, 12), (-9, -7, 2, 14, 9), (6, -7, 2, 7, 6)):
		left, right = wall_faces(s, x, y, 0, dx, dy, tall)
		stone_face(left, shade(stone, .04), max(3, int(tall / 1.4)), max(2, int(dx / 1.7)), rnd)
		stone_face(right, shade(stone, -.2), max(3, int(tall / 1.4)), max(2, int(dy / 1.7)), rnd)
		s.quad([(x, y, tall), (x + dx, y, tall), (x + dx, y + dy, tall), (x, y + dy, tall)], shade(stone, .18))
		for _ in range(int(dx + dy) // 2):
			u = rnd.random()
			px, py = s.p(x + dx * u, y + dy, tall)
			s.rect(px - .8, py - rnd.uniform(0, 2.4), 1.6, rnd.uniform(.8, 2.4), (0, 0, 0, 0))
	# a broken arch, fallen blocks and ivy
	left, _ = wall_faces(s, -9, -7, 0, 16, 2, 12)
	left.poly([(.38, 1), (.38, .5), (.5, .34), (.62, .5), (.62, 1)], "#3f3a30")
	for _ in range(9):
		x, y = rnd.uniform(-8, 9), rnd.uniform(-3, 7)
		box(s, x, y, 0, rnd.uniform(1, 2.2), rnd.uniform(1, 2), rnd.uniform(.7, 1.4), stone)
	for _ in range(46):
		a = s.p(rnd.uniform(-9, 7), rnd.choice((-5, -6)), rnd.uniform(0, 10))
		s.oval(a[0], a[1], rnd.uniform(.3, .6), rnd.uniform(.25, .5), rnd.choice(("#4f7f42", "#6fa053", "#3d6b3a")))
	return s.finish()


def pavilion(s, x, y, r, tall, color, rnd):
	cx, cy = s.p(x, y)
	s.oval(cx + .8, cy + .4, r * 1.1, r * .55, (*rgb("#1a2018"), 80))
	wall = tall * .45
	s.poly([(cx - r, cy), (cx - r, cy - wall), (cx + r, cy - wall), (cx + r, cy)], "#efe8d8")
	s.oval(cx, cy, r, r * .5, "#efe8d8")
	stripes = 12
	for i in range(stripes):
		u0, u1 = -1 + i * 2 / stripes, -1 + (i + 1) * 2 / stripes
		tone = shade(color if i % 2 == 0 else "#f4eddc", (u0 + u1) / 2 * -.26)
		lift0, lift1 = math.sqrt(max(0, 1 - u0 * u0)) * r * .5, math.sqrt(max(0, 1 - u1 * u1)) * r * .5
		s.poly([(cx, cy - tall), (cx + u0 * r * 1.08, cy - wall + lift0), (cx + u1 * r * 1.08, cy - wall + lift1)], tone)
	s.poly([(cx - r * .22, cy + r * .5), (cx - r * .14, cy - wall * .9 + r * .4), (cx + r * .14, cy - wall * .9 + r * .4), (cx + r * .22, cy + r * .5)], "#3f2d20")
	s.line([(cx, cy - tall), (cx, cy - tall - 2.6)], "#3f352b", .22)
	s.poly([(cx, cy - tall - 2.6), (cx + 2, cy - tall - 2.1), (cx, cy - tall - 1.4)], color)


def market(seed):
	rnd = random.Random(seed + 130)
	s = Iso(44, 20, 12)
	colors = ("#a63c2e", "#2f6f8f", "#c9973a", "#5b7f46", "#7a4f9a")
	spots = ((-7, -5), (6, -6), (-4, 5), (7, 4))
	for i, (x, y) in enumerate(spots):
		pavilion(s, x, y, 4.2, 9.5, colors[(seed + i) % 5], rnd)
	return s.finish()


def tourney(seed):
	rnd = random.Random(seed + 140)
	s = Iso(66, 30, 18)
	s.quad([(-18, -11, 0), (18, -11, 0), (18, 11, 0), (-18, 11, 0)], "#8ca95e")
	s.quad([(-14, -1.2, 0), (14, -1.2, 0), (14, 1.2, 0), (-14, 1.2, 0)], "#b09b70")
	for i in range(11):
		s.line([s.p(-14 + i * 2.8, 0), s.p(-14 + i * 2.8, 0, 2)], "#6a4a30", .28)
	s.line([s.p(-14, 0, 1.9), s.p(14, 0, 1.9)], "#a63c2e", .38)
	colors = ("#a63c2e", "#2f6f8f", "#c9973a", "#7a4f9a")
	for i, (x, y) in enumerate(((-13, -9), (-2, -9), (9, -9), (14, 8))):
		pavilion(s, x, y, 5, 12, colors[(seed + i) % 4], rnd)
	return s.finish()


def lighthouse(seed):
	rnd = random.Random(seed + 150)
	s = Iso(26, 52, 8)
	s.shadow(2, 1, 8, 3.6, 90)
	culture = {"roof": "#a63c2e", "wall": "stone", "base": "#ddd5c4", "trim": "#3f352b"}
	round_tower(s, 0, 0, 0, 5, 28, culture, rnd, roof=False)
	for y0 in (-8, -20):
		s.poly([(-5, y0), (-5, y0 - 5), (5, y0 - 5), (5, y0)], "#c0453a")
		s.poly([(.5, y0), (.5, y0 - 5), (5, y0 - 5), (5, y0)], "#8f2f28")
	s.rect(-3, -36, 6, 6.5, "#ffe08a")
	for x in (-3, 0, 3):
		s.line([(x, -36), (x, -29.5)], "#3f352b", .3)
	round_tower(s, 0, 0, 34.5, 3.6, 0.1, culture, rnd, roof=True, cone="#a63c2e")
	return s.finish()


def boat(seed):
	rnd = random.Random(int(seed or 0) + 170)
	s = Iso(26, 26, 6)
	s.oval(0, 2.4, 9, 2.4, (*rgb("#1a3a50"), 110))
	p = s.p
	s.poly([p(-7, 0, 1.6), p(7, 0, 1.6), p(8.6, 0, 1.2), p(5, 2.8, 0), p(-6, 2.8, 0)], "#8a5f3c")
	s.poly([p(5, 2.8, 0), p(8.6, 0, 1.2), p(5, -2.8, 0)], "#6a4a30")
	s.poly([p(-7, -2.2, 1.7), p(7, -2.2, 1.7), p(8.6, 0, 1.7), p(7, 2.2, 1.7), p(-7, 2.2, 1.7)], "#b08b62")
	for i in range(6):
		s.line([p(-6 + i * 2.4, -2.2, 1.7), p(-6 + i * 2.4, 2.2, 1.7)], "#8a6a48", .14)
	s.line([p(0, 0, 1.7), p(0, 0, 17)], "#4d3c2d", .4)
	s.poly([p(0, 0, 16.4), p(.4, 0, 4), p(6.6, 0, 4.8)], "#f4eddc")
	s.poly([p(0, 0, 15), p(.2, 0, 4.4), p(-4.6, 0, 5)], "#d9cfb8")
	s.poly([p(0, 0, 17), p(2, 0, 16.6), p(0, 0, 16)], "#c84b34")
	return s.finish()


def galleon(seed):
	rnd = random.Random(int(seed or 0) + 180)
	s = Iso(42, 38, 8)
	s.oval(0, 4, 15, 4, (*rgb("#1a3a50"), 110))
	p = s.p
	s.poly([p(-12, 2, 4), p(12, 2, 4), p(15, 0, 3), p(10, 4.4, 0), p(-11, 4.4, 0)], "#7a5234")
	for i in range(7):
		s.line([p(-11, 2.4 + i * .28, 3.6 - i * .55), p(11, 2.4 + i * .28, 3.6 - i * .55)], "#5a3d28", .16)
	s.poly([p(-13, -2, 4.4), p(12, -2, 4.4), p(15, 0, 4), p(12, 2, 4.4), p(-13, 2, 4.4)], "#b08b62")
	box(s, -13, -2, 4.4, 6, 4, 3, "#8a5f3c", "#a58259")
	for mast, tall in ((-3, 24), (6, 20)):
		s.line([p(mast, 0, 4), p(mast, 0, tall)], "#4d3c2d", .5)
		for level, width in ((tall - 3, 4), (tall - 11, 5.6)):
			a, b, c, d = p(mast - width, 0, level), p(mast + width, 0, level), p(mast + width * .9, 0, level - 6.4), p(mast - width * .9, 0, level - 6.4)
			mid = ((a[0] + b[0]) / 2 + 1.2, (a[1] + b[1]) / 2 - 3.2)
			s.poly([a, b, c, mid, d], "#f4eddc")
			s.poly([mid, c, d], "#d9cfb8")
	s.poly([p(-3, 0, 24), p(0, 0, 23.4), p(-3, 0, 22.6)], "#c84b34")
	return s.finish()


def bridge_art(seed):
	"""A stone bridge with an arch; mirrored when the road runs the other way."""
	rnd = random.Random(7)
	s = Iso(46, 14, 18)
	stone = "#a8a295"
	p = s.p
	x0, x1, w = -12, 12, 3
	rise = lambda x: (1 - (x / 12) ** 2) * 4 + 1.6
	s.shadow(0, 3, 14, 5, 80)
	n = 16
	for i in range(n):
		u0, u1 = x0 + (x1 - x0) * i / n, x0 + (x1 - x0) * (i + 1) / n
		tone = shade(stone, rnd.uniform(-.08, .06))
		s.poly([p(u0, w, rise(u0)), p(u1, w, rise(u1)), p(u1, w, -2.4), p(u0, w, -2.4)], shade(tone, .06))
		s.poly([p(u0, -w, rise(u0)), p(u1, -w, rise(u1)), p(u1, w, rise(u1)), p(u0, w, rise(u0))], shade("#c4b89c", rnd.uniform(-.1, .06)))
	left = Face(s, p(-6, w, 3), p(6, w, 3), p(6, w, -2.4), p(-6, w, -2.4))
	left.poly([(0, 1), (0, .5), (.2, .16), (.5, .02), (.8, .16), (1, .5), (1, 1)], "#2c3a42")
	for side, d in ((w, .9), (-w, 0)):
		for i in range(n + 1):
			u = x0 + (x1 - x0) * i / n
			a = p(u, side, rise(u))
			s.rect(a[0] - .35, a[1] - 1.5, .7, 1.5, shade(stone, -.08 if side < 0 else .06))
		s.line([p(x0 + (x1 - x0) * i / n, side, rise(x0 + (x1 - x0) * i / n) + 1.4) for i in range(n + 1)], shade(stone, .14), .4)
	image, ax, ay = s.finish()
	from PIL import ImageOps
	return (ImageOps.mirror(image), image.width / sp.FINAL - ax, ay) if seed else (image, ax, ay)


def spring_head(seed):
	rnd = random.Random(int(seed or 0) + 190)
	s = Iso(26, 16, 8)
	s.oval(0, 3, 9, 4, "#3f89a8")
	for _ in range(12):
		s.oval(rnd.uniform(-7, 7), rnd.uniform(1, 5), rnd.uniform(.5, 1.4), .2, "#9fd8e8")
	for ox, oy, size in ((-5, -1, 4), (4, -2, 5), (0, -4, 6)):
		s.poly([(ox - size, oy + 2), (ox - size * .6, oy - size), (ox + size * .3, oy - size * 1.2), (ox + size, oy + 2)], "#8f8b82")
		s.poly([(ox + size * .1, oy - size * 1.2), (ox + size, oy + 2), (ox + size * .1, oy + 2)], "#6f6b64")
	for x in (-.6, .3, 1):
		s.line([(x, -6), (x, 2)], "#d9f2fb", .4)
	return s.finish()


def mist(seed):
	rnd = random.Random(seed + 200)
	s = Iso(40, 12, 8)
	for _ in range(30):
		s.oval(rnd.uniform(-15, 15), rnd.uniform(-7, 4), rnd.uniform(2.4, 5), rnd.uniform(1, 2.4), (238, 240, 240, 30))
	return s.finish()


def elf_tower(seed):
	"""A white tower grown among the trees: slender, ringed with balconies, a leaf for a roof."""
	rnd = random.Random(seed + 210)
	s = Iso(36, 72, 8)
	s.shadow(2.5, 1, 9, 4, 90)
	white, gold, leaf = "#ece8dc", "#d9b24c", "#3f9f7f"
	for ox, tall in ((-3, 7), (3, 6), (0, 9)):
		s.poly([(ox - 2.4, 1), (ox - .8, -tall), (ox + .8, -tall), (ox + 2.4, 1)], "#5f4a38")
	for i in range(28):
		t0, t1 = i / 28, (i + 1) / 28
		w = lambda t: 3.6 - t * 2 + math.sin(t * 9) * .22
		y0, y1 = -3 - t0 * 46, -3 - t1 * 46
		sway = math.sin(t0 * 2.6) * 1.1
		sway1 = math.sin(t1 * 2.6) * 1.1
		s.poly([(sway - w(t0), y0), (sway + w(t0), y0), (sway1 + w(t1), y1), (sway1 - w(t1), y1)], white)
		s.poly([(sway + w(t0) * .15, y0), (sway + w(t0), y0), (sway1 + w(t1), y1), (sway1 + w(t1) * .15, y1)], shade(white, -.2))
	for t, r in ((.3, 5.6), (.62, 4.6), (.88, 3.8)):
		sway = math.sin(t * 2.6) * 1.1
		y = -3 - t * 46
		s.oval(sway, y + .6, r, r * .42, shade(gold, -.25))
		s.oval(sway, y, r, r * .42, gold)
		for a in (-.5, .3):
			s.rect(sway + a * r * .7 - .35, y - 3, .7, 1.8, "#ffe9a0")
	sway = math.sin(2.6) * 1.1
	for sign, tone in ((-1, shade(leaf, .1)), (1, shade(leaf, -.2))):
		s.poly([(sway, -49), (sway + sign * 5, -52), (sway + sign * 3.2, -59), (sway, -66)], tone)
	s.line([(sway, -49), (sway, -66)], shade(leaf, .3), .25)
	s.oval(sway, -67, .6, .6, "#ffe9a0")
	for _ in range(20):
		s.oval(rnd.uniform(-5, 5), rnd.uniform(-40, -8), rnd.uniform(.4, .9), rnd.uniform(.3, .6), rnd.choice(("#4f8f5a", "#6fb078")))
	return s.finish()


def world_tree(scale):
	rnd = random.Random(909)
	size = max(1, min(2.2, float(scale or 1)))
	s = Iso(int(150 * size), int(150 * size), 26)
	s.shadow(5, 2, 50 * size, 22 * size, 100)
	colors = ("#3f9f8a", "#8fe8c8", "#22665c")
	for sign in (-1, 1):
		for i in range(3):
			x = sign * (7 + i * 6) * size
			s.line([(sign * 3 * size, -8 * size), (x, 3 + i * 2)], "#574132", 2.6 - i * .4)
	bark(s, 0, -76 * size, 0, 12 * size, "#6a5140", rnd)
	for sign in (-1, 1):
		s.line([(sign * 3 * size, -52 * size), (sign * 34 * size, -82 * size)], "#5f4635", 5)
		s.line([(sign * 4 * size, -66 * size), (sign * 18 * size, -96 * size)], "#5f4635", 3.6)
	for ox, oy, rx, ry, count in ((-34, -86, 26, 18, 420), (34, -86, 26, 18, 420), (0, -112, 36, 24, 720), (0, -84, 38, 15, 460)):
		leaves(s, rnd, ox * size, oy * size, rx * size, ry * size, colors, count)
	for _ in range(70):
		s.oval(rnd.uniform(-58, 58) * size, rnd.uniform(-132, -66) * size, .55, .55, "#fff2a8")
	return s.finish()


def person(seed, frame=0):
	"""A townsman from above and the side: clothes with light on them, a hat here and there."""
	rnd = random.Random(seed)
	s = Sheet(6, 7, 1)
	cloth = rnd.choice(("#a63c2e", "#2f6f8f", "#c9973a", "#5b7f46", "#7a4f9a", "#8a5f3c", "#3f6f6a", "#c0653a", "#596a8f", "#d9cfb8"))
	skin_ = rnd.choice(("#e8c4a0", "#d4a67e", "#a87850", "#f0d4b8", "#7f5a3c"))
	hair = rnd.choice(("#3f2a1a", "#6a4a2c", "#c9a24c", "#2a2420", "#8a8680", "#8f3f28"))
	stride = .55 if frame else -.55
	s.oval(.5, .3, 1.7, .6, (20, 26, 22, 90))
	for x, y in ((-.55 + stride * .5, .1 + stride * .25), (.55 - stride * .5, .1 - stride * .25)):
		s.line([(x * .8, -1.7), (x, y)], shade(cloth, -.46), .62)
		s.oval(x, y + .05, .42, .24, "#2f241a")
	long_ = seed % 3 == 0
	s.poly([(-1.05, -4.1), (1.05, -4.1), (1.25 if long_ else 1.05, -.5 if long_ else -1.6), (-1.25 if long_ else -1.05, -.5 if long_ else -1.6)], cloth)
	s.poly([(.2, -4.1), (1.05, -4.1), (1.25 if long_ else 1.05, -.5 if long_ else -1.6), (.2, -.5 if long_ else -1.6)], shade(cloth, -.24))
	s.line([(-1.05, -2.6), (1.05, -2.6)], shade(cloth, -.4), .22)
	s.line([(-1.2, -3.9), (-1.35 - stride * .4, -2.2)], shade(cloth, .1), .5)
	s.line([(1.2, -3.9), (1.35 + stride * .4, -2.2)], shade(cloth, -.3), .5)
	s.oval(0, -4.9, .82, .86, skin_)
	s.oval(-.1, -5.28, .84, .56, hair)
	if seed % 4 == 1:
		s.oval(0, -5.5, 1.12, .36, rnd.choice(("#6a4a2c", "#3f5f6f", "#7a2f2f")))
		s.oval(0, -5.8, .66, .46, rnd.choice(("#6a4a2c", "#3f5f6f", "#7a2f2f")))
	return s.finish()


def sails():
	"""A mill's four sails, turned by the shell."""
	s = Sheet(40, 20, 20)
	for a in range(4):
		a = a * math.pi / 2
		dx, dy = math.cos(a), math.sin(a)
		nx, ny = -dy, dx
		s.line([(0, 0), (dx * 18.5, dy * 18.5)], "#5a3d28", .55)
		s.poly([(dx * 3.5, dy * 3.5), (dx * 18.5, dy * 18.5), (dx * 18.5 + nx * 3.8, dy * 18.5 + ny * 3.8), (dx * 3.5 + nx * 3.2, dy * 3.5 + ny * 3.2)], (240, 232, 214, 235))
		for i in range(1, 8):
			t = 3.5 + i * 2.1
			s.line([(dx * t, dy * t), (dx * t + nx * 3.7, dy * t + ny * 3.7)], "#7a5c44", .2)
		s.line([(dx * 3.5 + nx * 3.4, dy * 3.5 + ny * 3.4), (dx * 18.5 + nx * 3.9, dy * 18.5 + ny * 3.9)], "#7a5c44", .22)
	s.oval(0, 0, 1.4, 1.4, "#4a3222")
	s.oval(-.3, -.3, .6, .6, "#8a6a48")
	return s.finish()


def scaffold(_seed):
	"""Poles and planks round what is being built."""
	s = Iso(36, 28, 6)
	p = s.p
	x, y, dx, dy = -9, -7, 18, 14
	for a, b in ((x, y + dy), (x + dx / 2, y + dy), (x + dx, y + dy), (x + dx, y + dy / 2), (x + dx, y)):
		s.line([p(a, b, 0), p(a, b, 16)], "#7a5c44", .4)
	for h in (5, 10, 15):
		s.line([p(x, y + dy, h), p(x + dx, y + dy, h)], "#a58259", .9)
		s.line([p(x + dx, y + dy, h), p(x + dx, y, h)], "#8d6a48", .9)
		s.line([p(x, y + dy, h - 3), p(x + dx / 2, y + dy, h)], "#7a5c44", .2)
	return s.finish()


def smoke(_seed):
	"""A puff with a lit side and a shaded one, soft at the rim."""
	rnd = random.Random(5)
	s = Sheet(10, 5, 5)
	for _ in range(16):
		a, d = rnd.uniform(0, 6.28), rnd.random() ** .7
		x, y = math.cos(a) * d * 2.8, math.sin(a) * d * 2.4
		s.oval(x, y, rnd.uniform(1, 2), rnd.uniform(.9, 1.7), (*rgb("#b9b6b0" if x + y > .5 else "#f2f0ea"), 46))
	return s.finish()


def flag(_seed):
	"""A pennant: cloth with folds and a hem."""
	s = Sheet(8, 3, 3)
	cloth = "#c84b34"
	for i in range(8):
		x0, x1 = -3.6 + i, -2.6 + i
		w0, w1 = 1.9 - i * .2, 1.9 - (i + 1) * .2
		s.poly([(x0, -w0), (x1, -w1), (x1, w1), (x0, w0)], shade(cloth, .16 if i % 2 else -.16))
	s.line([(-3.6, -1.9), (4.4, -.3)], "#f0d060", .16)
	s.line([(-3.6, 1.9), (4.4, .3)], "#f0d060", .16)
	s.line([(-3.7, -2.4), (-3.7, 2.4)], "#4d3c2d", .3)
	s.oval(-3.7, -2.4, .3, .3, "#f0d060")
	return s.finish()


def golem(frame):
	"""A walking stone man, runes burning in his chest."""
	rnd = random.Random(23)
	s = Sheet(12, 15, 1)
	stone = "#8f8f92"
	step = 1 if frame else -1
	s.oval(.8, .1, 4.4, 1.3, (20, 26, 22, 90))
	for x, lift in ((-2, max(0, step)), (2, max(0, -step))):
		s.poly([(x - 1.5, -5), (x + 1.5, -5), (x + 1.3, -lift), (x - 1.3, -lift)], shade(stone, -.2 if x > 0 else -.06))
	for sign, sw in ((-1, step), (1, -step)):
		s.poly([(sign * 3.2, -11), (sign * 5.2, -11), (sign * 5.3 + sw * .5, -5), (sign * 3.5 + sw * .5, -5)], shade(stone, -.26 if sign > 0 else .04))
	s.poly([(-3.8, -4.4), (-4.2, -11.4), (0, -12.2), (4.2, -11.4), (3.8, -4.4)], stone)
	s.poly([(0, -4.4), (0, -12.2), (4.2, -11.4), (3.8, -4.4)], shade(stone, -.2))
	for _ in range(20):
		x, y = rnd.uniform(-3.4, 3.4), rnd.uniform(-11, -5)
		s.line([(x, y), (x + rnd.uniform(.4, 1.2), y)], shade(stone, -.32), .1)
	s.poly([(-2, -12), (-2.1, -14.4), (2.1, -14.4), (2, -12)], shade(stone, .12))
	s.poly([(.2, -12), (.2, -14.4), (2.1, -14.4), (2, -12)], shade(stone, -.14))
	for x in (-1, .9):
		s.oval(x, -13.3, .44, .3, "#7fe7ff")
	s.line([(0, -10), (-.9, -8.4), (.9, -7.8), (0, -6.2)], "#7fe7ff", .28)
	for _ in range(8):
		s.oval(rnd.uniform(-4, 4), rnd.uniform(-12, -5), rnd.uniform(.3, .6), .3, rnd.choice(("#5f8f4a", "#7ba85a")))
	return s.finish()


def foundation(_seed):
	"""A dug plot: earth, stones laid out, a stake at each corner."""
	rnd = random.Random(31)
	s = Iso(30, 14, 12)
	s.quad([(-11, -9, 0), (11, -9, 0), (11, 9, 0), (-11, 9, 0)], "#8d7350")
	for _ in range(90):
		a = s.p(rnd.uniform(-10.5, 10.5), rnd.uniform(-8.5, 8.5))
		s.oval(a[0], a[1], rnd.uniform(.3, 1.1), rnd.uniform(.2, .5), rnd.choice(("#7a6244", "#9c8159", "#6d5a3f", "#a58a60")))
	for i in range(22):
		t = i / 22 * 4
		side = int(t)
		u = t - side
		x, y = [(-8 + 16 * u, -6), (8, -6 + 12 * u), (8 - 16 * u, 6), (-8, 6 - 12 * u)][side]
		box(s, x - .8, y - .7, 0, 1.6, 1.4, .8, shade("#a8a295", rnd.uniform(-.1, .08)))
	for x, y in ((-11, -9), (11, -9), (11, 9), (-11, 9)):
		s.line([s.p(x, y), s.p(x, y, 2.6)], "#6a4a30", .3)
	return s.finish()


def glow(color, size=64):
	"""A soft round light, for what shines and what floats."""
	from PIL import Image
	yy, xx = np.mgrid[:size, :size]
	d = np.hypot(xx - size / 2 + .5, yy - size / 2 + .5) / (size / 2)
	alpha = np.clip(1 - d, 0, 1) ** 2
	r, g, b = rgb(color)
	return Image.fromarray(np.dstack([np.full(d.shape, r), np.full(d.shape, g), np.full(d.shape, b), alpha * 255]).astype(np.uint8), "RGBA")


def draw(art):
	"""The picture of a thing, when it has an isometric one; it knows them all."""
	name, *a = art
	if name == "oak":
		return oak(sp.LEAVES[a[0]], a[1] % 5)
	if name == "birch":
		return birch(sp.LEAVES[a[0]], a[1] % 5)
	if name == "pine":
		return pine(sp.LEAVES["pine"], a[1] % 4)
	if name == "house":
		return house(a[0]["name"], a[1], a[2] % 6)
	if name == "seat":
		return keep(a[0]["name"], a[1], a[2] % 3)
	if name == "seatx":
		return seatx(a[0], a[1]["name"], a[2], a[3] % 3)
	if name == "fhouse":
		return fhouse(a[0], a[1]["name"], a[2], a[3] % 6)
	if name == "palm":
		return palm(a[0] % 3)
	if name == "landmark":
		return landmark(a[0], a[1] % 3)
	if name == "floating_isle":
		return floating_isle(a[0], a[1])
	if name == "isle_shadow":
		return isle_shadow(a[0])
	if name == "rope":
		return rope(a[0], a[1])
	simple = {"sheep": sheep, "flowers": flowers, "rock": rock, "cart": cart, "crates": crates, "statue": statue, "milestone": milestone, "fire": campfire, "ruin": ruin,
	          "market": market, "tourney": tourney, "lighthouse": lighthouse, "boat": boat, "harbour_ship": galleon, "bridge": bridge_art,
	          "spring_head": spring_head, "mist": mist, "elf_tower": elf_tower}
	if name in simple:
		return simple[name](a[0] if a else 0)
	if name == "world_tree":
		return world_tree(a[0] if a else 1)
	if name == "gold_pile":
		return gold_pile(a[0], a[1])
	if name == "temple":
		return temple(a[0]["name"], a[1] % 3)
	if name == "tavern":
		return tavern("alpine", a[0] if a else 0)
	if name == "stall":
		return stall(a[0] if a else 0)
	if name == "fountain":
		return fountain(0)
	if name == "well":
		return well(0)
	if name == "field":
		return field(a[0] if a else 0)
	if name == "hedge":
		return hedge(a[0] if a else 0)
	if name == "windmill":
		return windmill(a[0]["name"], a[1] % 3)
	if name == "forge":
		return forge(0)
	if name in ("arena", "theatre"):
		return round_hall(name)
	if name == "terrace":
		return terrace(*a)
	if name == "mountain":
		return mountain(a[0] if a else 0)
	if name == "plaza":
		return plaza(a[0])
	if name == "ground_square":
		return ground_square(a[0], a[1])
	if name == "steps":
		return steps(a[0], a[1], a[2])
	if name == "wall":
		return wall(a[0], a[1])
	if name == "wall_tower":
		return wall_tower(a[0]["name"])
	if name == "gatehouse":
		return gatehouse(a[0]["name"])
	if name == "great_tree":
		return great_tree(a[0] if a else 0)
	return None
