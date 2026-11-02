#!/usr/bin/env python3
"""Turns what was done into a world in 3D.

The world is worked out anew, day after day in the order things happened, so
nothing that stands moves when a day is added (only what it looks like: towns
get finer the denser they grow). Where the work comes from is sources.py.

  realm    → a kingdom with its own manner of building, around a seat that grows
             from a camp to a palace
  plot     → a patch of land that goes on growing (with the timer: a ticket)
  billable → a house per half hour, the rest → a tree per quarter
  people on a ticket → ten walkers each

The output is instance tables, one per unit shape, drawn by core/views/world:
colours are roles and animations are numbers the shader acts on.

  world.py          prints the world's directory, building it when out of date
  world.py --force  builds it in any case
"""

import hashlib
import heapq
import json
import math
import os
import random
import re
import shutil
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
import iso
import paint
import prefabs as kit
import sources
import sprites

VERSION = 24
PITCH = 16                 # world units between two lots
FLAT = .52                 # a circle on the ground, on screen
STEP = 9                   # how much higher each level of a town stands
CITY_HOUSES = 8            # from here on a town is planned
ISO = 1.55                 # how much wider they stand so that houses with gardens fit
HOUSE_MINUTES = 30
TREE_MINUTES = 15
WATER_ML = 250
BREAKS_PER_MEADOW = 3
ELF_TREES = 350
WORLD_TREE_TREES = 900
MARGIN = 13                # lots of sea around the land
PEOPLE_PER_PERSON = 10
MOST_WALKERS = 700
NEIGHBOURS = [(1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1), (1, -1)]
SEAT_HOURS = [3, 8, 16, 30, 60]
# one prop per this much of a source
EVERY = {"games": 240, "theatre": 300, "forge": 3, "ships": 6, "wilderness": 180}


def stable(*parts):
	return int(hashlib.md5("|".join(map(str, parts)).encode()).hexdigest()[:12], 16)


def chance(*parts):
	return stable(*parts) / 0xffffffffffff


def season_leaf(day_name, lot):
	month = int(day_name[5:7])
	pick = chance("leaf", *lot)
	if month in (3, 4, 5):
		return "leafSpring" if pick < .7 else "leaf"
	if month in (9, 10, 11):
		return "autumnA" if pick < .5 else ("autumnB" if pick < .85 else "leaf")
	if month in (12, 1, 2):
		return "pine"
	return "leaf"


def to_xz(lot):
	# the hex grid turned by 45 degrees and laid flat: the world seen isometrically
	q, r = lot
	x, z = PITCH * (q + r / 2) * ISO, PITCH * .866 * r * ISO
	return (x - z) * .7071, (x + z) * .3535


def wobble(lot, amount=.3):
	x, z = to_xz(lot)
	return (x + (chance("wx", *lot) - .5) * PITCH * amount * 2, z + (chance("wy", *lot) - .5) * PITCH * amount * 2)


def distance(a, b):
	dq, dr = a[0] - b[0], a[1] - b[1]
	return (abs(dq) + abs(dr) + abs(dq + dr)) / 2


class World:
	def __init__(self, days, used):
		self.days = days
		self.used = used
		self.lots = {}
		self.realms = {}
		self.realm_list = []
		self.plots = []
		self.things = []
		self.water = []
		self.rivers = []
		self.roads = []
		self.road_lots = set()
		self.water_plan = None
		self.water_credit = 0
		self.break_credit = 0
		self.seat_step = 0
		self.spots = {}
		self.path_nodes, self.path_links, self.path_lifts = [], [], []
		self.river_days, self.river_lines = [], []
		self.credit = defaultdict(float)
		self.ships = []
		self.city_walls = []

	plans = None

	def add_node(self, x, y, lift=0):
		self.path_nodes.append((x, y))
		self.path_lifts.append(lift)
		self.path_links.append(set())
		return len(self.path_nodes) - 1

	def add_link(self, a, b):
		if a != b:
			self.path_links[a].add(b)
			self.path_links[b].add(a)

	def free(self, lot):
		return lot not in self.lots

	def around(self, lot):
		return [(lot[0] + a, lot[1] + b) for a, b in NEIGHBOURS]

	def nearest_free(self, start, wanted=lambda lot: True, limit=60000):
		seen, ring = {start}, [start]
		count = 0
		while ring:
			following = []
			for lot in ring:
				if self.free(lot) and wanted(lot):
					return lot
				for other in self.around(lot):
					if other not in seen:
						seen.add(other)
						following.append(other)
						count += 1
				if count > limit:
					return lot
			ring = following
		return start

	def thing(self, make, lot, day, plot=None, realm=None, kind="", amount=.3, yaw=0.0, offset=(0, 0), scale=1.0):
		"""make(): a function giving a Kit, called late, because a town's look comes last."""
		x, z = wobble(lot, amount)
		item = {"make": make, "x": x + offset[0], "z": z + offset[1], "day": day, "plot": plot, "realm": realm, "kind": kind, "lot": lot, "yaw": yaw, "scale": scale}
		self.things.append(item)
		return item

	def take(self, lot, kind="prop", ring=0):
		self.lots[lot] = kind
		if ring:
			for other in self.around(lot):
				if self.free(other):
					self.lots[other] = kind

	# ── realms ───────────────────────────────────────────────────────────

	def realm(self, entry, day):
		key = entry["realmKey"]
		if key not in self.realms:
			self.realms[key] = self.new_realm(entry["realm"], key, day)
		return self.realms[key]

	def new_realm(self, name, key, day):
		index = len(self.realm_list)
		while True:
			self.seat_step += 1
			angle = self.seat_step * 2.39996
			radius = 10 * math.sqrt(self.seat_step)
			guess = (round(radius * math.cos(angle) - radius * math.sin(angle) * .577), round(radius * math.sin(angle) * 1.155))
			if all(self.free((guess[0] + a, guess[1] + b)) for a, b in ((0, 0), (-2, 4), (3, 0), (-3, 0), (0, -3), (0, 3), (-4, 6), (0, 6))):
				centre = guess
				break
		culture = kit.CULTURES[(stable("culture", key) + index) % len(kit.CULTURES)]
		# the stronghold's hill, and at its foot, down the stairs, the market square
		gate = (centre[0] - 2, centre[1] + 4)
		realm = {"index": index, "name": name, "key": key, "centre": centre, "gate": gate, "culture": culture, "bill": 0, "other": 0, "houses": 0, "trees": 0, "plots": [], "first": day}
		for a in range(-5, 6):
			for b in range(-5, 6):
				lot = (centre[0] + a, centre[1] + b)
				if distance(lot, centre) <= 3 and self.free(lot):
					self.lots[lot] = "seat"
				lot = (gate[0] + a, gate[1] + b)
				# what stands south of the square would hide it
				if (distance(lot, gate) <= 3 or (0 <= b <= 3 and abs(a) <= 3)) and self.free(lot):
					self.lots[lot] = "plaza"
		self.realm_list.append(realm)
		self.thing(lambda: kit.seat(culture, seat_level(realm), stable("seat", key)), centre, day, realm=index, kind="seat", amount=0)
		earlier = self.realm_list[:-1]
		if earlier:
			self.road(gate, min(earlier, key=lambda other: distance(other["centre"], centre))["gate"], day)
		return realm

	# ── plots ────────────────────────────────────────────────────────────

	def plot(self, realm, entry, day):
		key = entry["key"]
		for index in realm["plots"]:
			if self.plots[index]["key"] == key:
				return self.plots[index]
		plot = {"index": len(self.plots), "key": key, "name": entry["plot"], "project": entry.get("project", ""), "description": entry.get("description", ""),
		        "task": entry.get("task"), "realm": realm["index"], "bill": 0, "other": 0, "houses": 0, "trees": 0, "elves": 0, "bill_credit": 0, "other_credit": 0,
		        "anchor": None, "lots": [], "frontier": set(), "first": day, "last": day, "people": entry.get("people", 0)}
		self.plots.append(plot)
		realm["plots"].append(plot["index"])
		return plot

	def anchor(self, plot, realm, wants_house):
		centre = realm["gate"]
		others = [self.plots[i]["anchor"] for i in realm["plots"] if self.plots[i]["anchor"]]
		angle = chance("turn", plot["key"]) * math.tau
		reach = (4 + chance("reach", plot["key"]) * 3) if wants_house else 8 + stable("reach", plot["key"]) % 5
		start = (centre[0] + round(math.cos(angle) * reach), centre[1] + round(math.sin(angle) * reach))
		lot = self.nearest_free(start, lambda lot: all(distance(lot, other) >= 3 for other in others) and all(self.free(n) for n in self.around(lot)))
		plot["anchor"] = lot
		if wants_house:
			self.road(lot, centre, plot["first"])

	def road_cost(self, lot):
		kind = self.lots.get(lot)
		if kind is None or kind in ("road", "plaza", "meadow"):
			return 1 + chance("rc", *lot) * 2.2
		return 7 if kind == "water" else None

	def road(self, start, goal, day):
		path = self.search(start, lambda lot: lot == goal or lot in self.road_lots, self.road_cost, goal)
		if not path:
			return
		crossing = []
		for lot in path:
			kind = self.lots.get(lot)
			if kind == "water":
				crossing.append(lot)
			elif kind is None:
				self.lots[lot] = "road"
			self.road_lots.add(lot)
		for lot in crossing[::2]:
			self.thing(lambda: kit.bridge(0), lot, day, kind="bridge", amount=0)
		self.roads.append({"points": [wobble(lot, .16) for lot in path], "day": day})

	def search(self, start, done, cost, goal, limit=30000):
		queue, best, came = [(0, 0, start)], {start: 0}, {}
		steps = 0
		while queue and steps < limit:
			_, spent, lot = heapq.heappop(queue)
			steps += 1
			if done(lot) and lot != start:
				path = [lot]
				while path[-1] in came:
					path.append(came[path[-1]])
				return path
			for other in self.around(lot):
				step = cost(other) if other != goal else 1
				if step is None:
					continue
				total = spent + step
				if total < best.get(other, 1e9):
					best[other] = total
					came[other] = lot
					heapq.heappush(queue, (total + distance(other, goal), total, other))
		return None

	def best_lot(self, plot, realm, kind):
		"""The lot the patch would take next, in the manner of its people's towns."""
		frontier = plot["frontier"]
		for lot in [lot for lot in frontier if not self.free(lot)]:
			frontier.discard(lot)
		if not frontier:
			frontier.add(self.nearest_free(plot["anchor"]))
		anchor, seat, pattern = plot["anchor"], realm["gate"], realm["culture"]["pattern"]

		def score(lot):
			value = distance(lot, anchor) + chance("patch", plot["key"], *lot) * 2.4
			if kind == "house":
				value += .8 if not any(n in self.road_lots for n in self.around(lot)) else 0
				value += distance(lot, seat) * .12
				if pattern == "grid":
					value += .9 * (lot[0] % 3 == 0) + .9 * (lot[1] % 3 == 0)
				elif pattern == "ribbon":
					value += abs(lot[1] - anchor[1]) * .7
				elif pattern == "ring":
					value += abs(distance(lot, anchor) - 3) * .9
			else:
				value -= distance(lot, seat) * .2
			return value

		return min(frontier, key=score)

	def claim(self, plot, realm, kind):
		if plot["anchor"] is None:
			self.anchor(plot, realm, kind == "house")
			if self.free(plot["anchor"]):
				plot["frontier"].add(plot["anchor"])
		lot = self.best_lot(plot, realm, kind)
		plot["frontier"].discard(lot)
		self.lots[lot] = kind
		plot["lots"].append(lot)
		for other in self.around(lot):
			if self.free(other):
				plot["frontier"].add(other)
		return lot

	def house(self, plot, realm, day):
		lot = self.claim(plot, realm, "house")
		plot["houses"] += 1
		realm["houses"] += 1
		# which way it faces: a road when there is one, else the seat
		target = next((n for n in self.around(lot) if n in self.road_lots), realm["gate"])
		tx, tz = to_xz(target)
		x, z = to_xz(lot)
		yaw = round(math.atan2(tx - x, tz - z) / (math.pi / 4)) * math.pi / 4
		item = self.thing(None, lot, day, plot["index"], realm["index"], "house", yaw=yaw)
		item["make"] = lambda: house_art(realm, item.get("tier", 1), lot)
		if plot["houses"] % 5 == 0:
			garden = self.claim(plot, realm, "garden")
			if chance("field", *garden) < .4:
				self.thing(lambda: kit.field(stable(*garden) % 3), garden, day, plot["index"], realm["index"], "ground", amount=.1)
			elif chance("well", *garden) < .25:
				self.thing(lambda: kit.well(0), garden, day, plot["index"], realm["index"], "deco")
			elif chance("mill", *garden) < .3:
				self.thing(lambda: kit.windmill(realm["culture"], stable(*garden)), garden, day, plot["index"], realm["index"], "deco")

	def tree(self, plot, realm, day):
		lot = self.claim(plot, realm, "tree")
		plot["trees"] += 1
		realm["trees"] += 1
		leaf = season_leaf(self.days[day], lot)
		pick = chance("species", realm["key"], lot[0] // 4, lot[1] // 4)
		seed = stable("v", *lot) % 9
		if leaf == "pine" or pick < .24:
			make = lambda: kit.pine("pine", seed)
		elif pick < .38:
			make = lambda: kit.birch(leaf, seed)
		else:
			make = lambda: kit.oak(leaf, seed)
		self.thing(make, lot, day, plot["index"], realm["index"], "tree", amount=.42)
		wanted = plot["trees"] // ELF_TREES
		if wanted > plot["elves"]:
			plot["elves"] = wanted
			self.elf(plot, day)

	def elf(self, plot, day):
		trees = [item for item in self.things if item["plot"] == plot["index"] and item["kind"] == "tree"]
		towers = [item for item in self.things if item["plot"] == plot["index"] and item["kind"] == "elf"]
		if not trees:
			return
		cx = sum(item["x"] for item in trees) / len(trees)
		cz = sum(item["z"] for item in trees) / len(trees)

		def score(item):
			near = min((math.hypot(item["x"] - t["x"], item["z"] - t["z"]) for t in towers), default=PITCH * 8)
			return math.hypot(item["x"] - cx, item["z"] - cz) - min(near, PITCH * 6) * 3

		chosen = min(trees, key=score)
		seed = stable(*chosen["lot"])
		chosen.update(kind="elf", make=lambda: kit.elf_tower(seed), day=day)
		if plot["trees"] >= WORLD_TREE_TREES and not plot.get("world_tree"):
			plot["world_tree"] = True
			central = min(trees, key=lambda item: math.hypot(item["x"] - cx, item["z"] - cz))
			central.update(kind="elf", make=lambda: kit.world_tree(1), day=day)

	def track(self, entry, day):
		realm = self.realm(entry, day)
		plot = self.plot(realm, entry, day)
		plot["last"] = day
		houses = trees = 0
		if entry["bill"]:
			plot["bill"] += entry["bill"]
			realm["bill"] += entry["bill"]
			plot["bill_credit"] += entry["bill"]
			if plot["houses"] == 0:
				plot["bill_credit"] = max(plot["bill_credit"], HOUSE_MINUTES)
			while plot["bill_credit"] >= HOUSE_MINUTES:
				plot["bill_credit"] -= HOUSE_MINUTES
				self.house(plot, realm, day)
				houses += 1
		if entry["other"]:
			plot["other"] += entry["other"]
			realm["other"] += entry["other"]
			plot["other_credit"] += entry["other"]
			while plot["other_credit"] >= TREE_MINUTES:
				plot["other_credit"] -= TREE_MINUTES
				self.tree(plot, realm, day)
				trees += 1
		return plot, houses, trees

	# ── water and rest ───────────────────────────────────────────────────

	def add_water(self, day, near):
		plan = self.water_plan or self.plan_water(near)
		self.water_plan = plan
		if plan["kind"] == "lake":
			frontier = plan["frontier"]
			for lot in [lot for lot in frontier if self.lots.get(lot) is not None]:
				frontier.discard(lot)
			if not frontier:
				frontier.add(self.nearest_free(plan["seed"]))
			lot = min(frontier, key=lambda lot: distance(lot, plan["seed"]) + chance("lake", plan["seed"], *lot) * 2)
			frontier.discard(lot)
			self.lots[lot] = "water"
			self.water.append({"lot": lot, "day": day, "river": False})
			plan["lake"].append(lot)
			frontier.update(other for other in self.around(lot) if self.free(other))
			if len(plan["lake"]) == 4:
				self.thing(lambda: kit.boat(stable(*lot)), plan["seed"], day, kind="boat", amount=.1)
			if len(plan["lake"]) >= plan["size"]:
				self.water_plan = self.plan_river(plan["lake"])
		else:
			lot = plan["path"].pop(0)
			self.lots[lot] = "water"
			self.water.append({"lot": lot, "day": day, "river": True})
			plan["drawn"].append(lot)
			if not plan["path"]:
				self.thing(lambda: kit.spring_head(0), plan["head"], day, kind="deco", amount=.1)
				self.water_plan = None

	def plan_water(self, near):
		wide = lambda lot: all(self.free(n) and all(self.free(m) for m in self.around(n)) for n in self.around(lot))
		seed = self.nearest_free(near, wide)
		return {"kind": "lake", "seed": seed, "size": 12 + stable("lake", *seed) % 14, "lake": [], "frontier": {seed}}

	def plan_river(self, lake):
		mx = sum(l[0] for l in lake) / len(lake)
		mz = sum(l[1] for l in lake) / len(lake)
		angle = chance("river", *lake[0]) * math.tau
		reach = 14 + stable("riverlen", *lake[0]) % 14
		goal = self.nearest_free((round(mx + math.cos(angle) * reach), round(mz + math.sin(angle) * reach)))
		start = min(lake, key=lambda lot: distance(lot, goal))

		def cost(lot):
			if self.lots.get(lot) is not None:
				return None
			crowded = sum(1 for n in self.around(lot) if self.lots.get(n) not in (None, "water"))
			return 1 + crowded * .9 + chance("meander", *lot) * 2.2

		path = self.search(start, lambda lot: lot == goal, cost, goal)
		if not path or len(path) < 5:
			return None
		path = list(reversed(path))[1:]
		for lot in path:
			self.lots[lot] = "planned"
		drawn = [start]
		self.rivers.append(drawn)
		return {"kind": "river", "path": path, "head": path[-1], "drawn": drawn}

	def add_rest(self, day, near, index):
		lot = self.nearest_free(near)
		self.take(lot, "meadow")
		self.thing(lambda: kit.flowers(stable(*lot)), lot, day, kind="ground", amount=.25)
		if index % 7 == 3:
			self.thing(fire_kit, lot, day, kind="deco", amount=.1, offset=(5, 4))
		elif chance("sheep", *lot) < .5:
			for i in range(2):
				self.thing(lambda seed=stable(i, *lot): kit.sheep(seed), lot, day, kind="walker", amount=.5)

	def prop(self, make, day, near, ring=1, kind="prop", realm=None):
		wide = lambda lot: not ring or all(self.free(n) for n in self.around(lot))
		lot = self.nearest_free(near, wide)
		self.take(lot, "prop", ring=ring)
		return self.thing(make, lot, day, kind=kind, amount=.1, realm=realm, yaw=chance("py", *lot) * math.tau)


def fire_kit():
	return ("fire", 0)


def seat_level(realm):
	hours = (realm["bill"] + realm["other"] * .1) / 60
	return sum(1 for threshold in SEAT_HOURS if hours >= threshold)


def build_world(work, numbers, used):
	start = min(work) if work else ""
	names = sorted(set(work) | {day for role in ("water", "rest") for day in numbers[role] if day >= start})
	world = World(names, used)
	records = []
	for index, name in enumerate(names):
		before = len(world.things)
		per_plot = {}
		bill = other = 0
		near = world.realm_list[0]["centre"] if world.realm_list else (0, 0)
		for entry in sorted(work.get(name, []), key=lambda entry: entry.get("at", 0)):
			plot, houses, trees = world.track(entry, index)
			record = per_plot.setdefault(plot["index"], {"plot": plot["index"], "bill": 0, "other": 0, "houses": 0, "trees": 0})
			record["bill"] += entry["bill"]
			record["other"] += entry["other"]
			record["houses"] += houses
			record["trees"] += trees
			bill += entry["bill"]
			other += entry["other"]
			if plot["anchor"]:
				near = plot["anchor"]
		ml = int(numbers["water"].get(name, 0))
		world.water_credit += ml
		wet = 0
		while world.water_credit >= WATER_ML:
			world.water_credit -= WATER_ML
			world.add_water(index, near)
			wet += 1
		breaks = int(numbers["rest"].get(name, 0))
		world.break_credit += breaks
		rests = 0
		while world.break_credit >= BREAKS_PER_MEADOW:
			world.break_credit -= BREAKS_PER_MEADOW
			world.add_rest(index, near, len(world.things))
			rests += 1
		extras = add_day_extras(world, numbers, name, index, near)
		spots = [item for item in world.things[before:] if item["kind"] in ("house", "tree", "elf", "seat")]
		focus = [sum(item["x"] for item in spots) / len(spots), sum(item["z"] for item in spots) / len(spots)] if spots else list(to_xz(near))
		records.append({"day": name, "bill": bill, "other": other, "ml": ml, "breaks": breaks, "plots": sorted(per_plot.values(), key=lambda item: -(item["bill"] + item["other"])),
		                "houses": sum(item["houses"] for item in per_plot.values()), "trees": sum(item["trees"] for item in per_plot.values()),
		                "water": wet, "rests": rests, "focus": focus, **extras})
	return world, records


def add_day_extras(world, numbers, name, index, near):
	extras = {}
	credit = world.credit
	for role, make in (("games", kit.arena), ("theatre", kit.theatre), ("forge", kit.forge)):
		credit[role] += float(numbers.get(role, {}).get(name, 0))
		while credit[role] >= EVERY[role]:
			credit[role] -= EVERY[role]
			item = world.prop(lambda seed=stable(role, name, credit[role]), make=make: make(seed), index, near)
			world.spots[role] = (item["x"], item["z"])
			extras[role] = extras.get(role, 0) + 1
	credit["wilderness"] += float(numbers.get("wilderness", {}).get(name, 0))
	while credit["wilderness"] >= EVERY["wilderness"]:
		credit["wilderness"] -= EVERY["wilderness"]
		seed = stable("wild", name, credit["wilderness"])
		# far from everything, where nobody has been
		edge = world.nearest_free((near[0] + stable("mx", seed) % 41 - 20, near[1] + stable("mz", seed) % 41 - 20), lambda lot: all(world.free(n) for n in world.around(lot)))
		world.take(edge, "prop", ring=1)
		world.thing(lambda seed=seed: kit.mountain(seed), edge, index, kind="mountain", amount=.3)
	credit["ships"] += float(numbers.get("ships", {}).get(name, 0))
	while credit["ships"] >= EVERY["ships"]:
		credit["ships"] -= EVERY["ships"]
		world.ships.append(index)
		extras["ships"] = extras.get("ships", 0) + 1
	meetings = int(numbers.get("meetings", {}).get(name, 0))
	big, small = meetings // 100, meetings % 100
	for i in range(big):
		item = world.prop(lambda seed=stable(name, i): kit.tourney(seed), index, near)
		world.spots["meetings"] = (item["x"], item["z"])
	for i in range(small):
		item = world.prop(lambda seed=stable(name, i, "m"): kit.market(seed), index, near, ring=0)
		world.spots["meetings"] = (item["x"], item["z"])
	if big + small:
		extras["meetings"] = big + small
	if numbers.get("monuments", {}).get(name):
		item = world.prop(lambda seed=stable(name): kit.lighthouse(seed), index, near)
		world.spots["monuments"] = (item["x"], item["z"])
		extras["monuments"] = 1
	storm = float(numbers.get("storms", {}).get(name, 0))
	if storm >= (9 if world.used.get("storms") == "pressure" else 1):
		world.prop(lambda seed=stable(name, "storm"): kit.ruin(seed), index, near, ring=0)
		extras["storm"] = 1
	mist = float(numbers.get("mist", {}).get(name, 0))
	# little sleep, or without a watch a very long day at the screen
	if (world.used.get("mist") == "sleep" and 0 < mist < 6) or (world.used.get("mist") == "long-days" and mist >= 10):
		world.prop(lambda seed=stable(name, "mist"): kit.mist(seed), index, near, ring=0)
		extras["mist"] = 1
	return extras


# ── how towns look: decided last, from what stands around ───────────────────

def dress_towns(world):
	"""The denser a spot, the finer its houses; a big realm is planned as a town on its hill."""
	world.plans = []
	houses = [item for item in world.things if item["kind"] == "house"]
	grid = defaultdict(list)
	for item in houses:
		grid[(item["lot"][0] // 5, item["lot"][1] // 5)].append(item)
	for item in houses:
		cell = (item["lot"][0] // 5, item["lot"][1] // 5)
		count = 0
		for a in range(cell[0] - 1, cell[0] + 2):
			for b in range(cell[1] - 1, cell[1] + 2):
				count += sum(1 for other in grid.get((a, b), ()) if distance(other["lot"], item["lot"]) <= 3.4)
		item["density"] = count
	# rare grand houses keep their distance, or they would stand in each other
	placed = []
	for item in sorted(houses, key=lambda item: (-item["density"], item["lot"])):
		count = item["density"]
		tier = 0 if count < 2 else 1 if count < 4 else 2 if count < 7 else 3 if count < 11 else 4 if count < 15 else 5
		tier = min(5, max(0, tier + (stable("tv", *item["lot"]) % 3 == 0) - (stable("tw", *item["lot"]) % 4 == 0)))
		while tier >= 4 and any(distance(item["lot"], other) < (5 if tier == 5 else 3) for other in placed):
			tier -= 1
		if tier >= 4:
			placed.append(item["lot"])
		item["tier"] = tier
	for realm in world.realm_list:
		own = [item for item in houses if item["realm"] == realm["index"]]
		realm["own"] = len(own)
	for realm in sorted(world.realm_list, key=lambda r: -r["own"]):
		if realm["own"] >= CITY_HOUSES:
			plan_city(world, realm, [item for item in houses if item["realm"] == realm["index"]])
	for realm in world.realm_list:
		own = [item for item in houses if item["realm"] == realm["index"]]
		if len(own) < 3 or realm.get("plan"):
			continue
		dress_square(world, realm, len(own))
		if len(own) >= 16:
			holy = world.nearest_free(realm["gate"], lambda lot: all(world.free(n) for n in world.around(lot)[:3]))
			world.take(holy, "prop")
			world.thing(lambda c=realm["culture"], seed=stable(realm["key"], "t"): kit.temple(c, seed), holy, realm["first"], realm=realm["index"], kind="deco", amount=.05)


ARCHETYPES = {
	# ground, step between levels, wall, houses, keep, what it shows off with, trees
	"hill": {"ground": "stone", "step": 15, "wall": "ring", "houses": ("house", "house", "turret", "crooked"), "keep": "hall", "mark": "tree", "green": ("oak", "birch")},
	"canals": {"ground": "water", "step": 4, "wall": "towers", "houses": ("crooked", "house", "crooked", "turret"), "keep": "hall", "mark": "dragon", "green": ("birch", "oak")},
	"bastide": {"ground": "stone", "step": 0, "wall": "square", "houses": ("house", "turret", "house", "crooked"), "keep": "hall", "mark": "tree", "green": ("oak", "pine")},
	"grove": {"ground": "moss", "step": 8, "wall": "none", "houses": ("mushroom", "treehouse", "mushroom", "treehouse", "house"), "keep": "tree", "mark": "stones", "green": ("oak", "pine")},
	"crag": {"ground": "dark", "step": 20, "wall": "ring", "houses": ("dwarf", "dwarf", "dwarf", "turret"), "keep": "gate", "mark": "dragon", "green": ("pine", "pine")},
	"isles": {"ground": "moss", "step": 0, "wall": "none", "houses": ("wizard", "crystal", "wizard", "turret", "mushroom"), "keep": "spires", "mark": "portal", "green": ("birch", "oak")},
	"oasis": {"ground": "sand", "step": 8, "wall": "ring", "houses": ("dome", "dome", "dome", "dome", "turret"), "keep": "palace", "mark": "crystal", "green": ("palm", "palm")},
	"arcane": {"ground": "dark", "step": 13, "wall": "ring", "houses": ("wizard", "crystal", "crystal", "wizard", "house"), "keep": "citadel", "mark": "portal", "green": ("birch", "pine")},
}
VILLAGE_STYLES = {"arcane": ("wizard", "crystal", "house"), "eastern": ("dome", "dome", "house"), "southern": ("dome", "house", "house"), "nordic": ("house", "turret", "dwarf", "house"),
                  "hanse": ("crooked", "house", "turret"), "alpine": ("house", "mushroom", "house", "turret", "treehouse")}


def spacing(ring):
	"""Finer houses near the keep take more room."""
	return 27 + max(0, 3 - ring) * 2


def in_ellipse(x, z, cx, cz, rx):
	return ((x - cx) / rx) ** 2 + ((z - cz) / (rx * FLAT)) ** 2 < 1


def choose_archetype(world, realm):
	"""By the realm's name, and no two alike while there is another kind left."""
	names = sorted(ARCHETYPES)
	start = stable("archetype", realm["key"]) % len(names)
	used = [plan["kind"] for plan in world.plans]
	least = min(used.count(name) for name in names)
	for i in range(len(names)):
		name = names[(start + i) % len(names)]
		if used.count(name) == least:
			return name
	return names[start]


def house_style(realm, key):
	styles = realm.get("styles") or VILLAGE_STYLES.get(realm["culture"]["name"], ("house",))
	return styles[stable("style", *key) % len(styles)]


def house_art(realm, tier, key):
	style = house_style(realm, key)
	if style == "house":
		return kit.house(realm["culture"], tier, stable("h", *key) % 6)
	return kit.fhouse(style, realm["culture"], tier, stable("h", *key) % 6)


def plan_city(world, realm, houses):
	"""A town of its kind: what its people build, how it climbs or spreads, how it is defended."""
	count = len(houses)
	level = seat_level(realm)
	kind = choose_archetype(world, realm)
	shape = ARCHETYPES[kind]
	step = shape["step"]
	realm["styles"] = shape["houses"]
	big = 1 + max(0, level - 1) * .17
	top_rx = round((46 if shape["keep"] == "hall" else 40) * big) + 8
	rings, room = [], 0
	while room < count + 3 or not rings:
		rx = top_rx + 32 + len(rings) * (34 if kind != "canals" else 44)
		rings.append(rx)
		room += int(math.tau * rx * (.5 if kind == "crag" else .76) / spacing(len(rings) - 1)) - 4
	tiers = len(rings)
	side = 0
	if kind == "bastide":
		side = max(3, math.ceil(math.sqrt((count + 8) / .62) / 2))
		wall_rx = (side + 1) * 2 * 24
	elif kind == "isles":
		wall_rx = rings[-1] + 34
	else:
		wall_rx = rings[-1] + 25
	best = None
	for reach in range(0, 40):
		for a in range(-reach, reach + 1):
			for b in range(-reach, reach + 1):
				if max(abs(a), abs(b)) != reach:
					continue
				lot = (realm["centre"][0] + a, realm["centre"][1] + b)
				x, z = to_xz(lot)
				if all(math.hypot(x - o["x"], (z - o["z"]) / FLAT) > wall_rx + o["wall"] + 26 for o in world.plans):
					best = lot
					break
			if best:
				break
		if best:
			break
	realm["centre"] = best
	hx, hz = to_xz(best)
	lift_of = lambda ring: (tiers - 1 - ring) * step + (22 + (tiers - ring) * 9 if kind == "isles" else 0)
	top_lift = tiers * step if kind != "isles" else 30 + tiers * 9
	order_north = lambda t: (tiers - 1 - t) * 2 + 1
	order_south = lambda t: 2 * tiers + 4 + t * 2
	plan = {"x": hx, "z": hz, "wall": wall_rx, "realm": realm, "top": top_lift, "tiers": tiers, "rings": rings, "kind": kind}
	world.plans.append(plan)
	realm["plan"] = plan
	day = realm["first"]

	def place(art, x, z, order, lift=0, what="deco", when=None):
		return world.things.append({"make": lambda: art, "x": x, "z": z, "day": day if when is None else when, "plot": None, "realm": realm["index"], "kind": what, "lot": best,
		                            "yaw": 0, "scale": 1.0, "block": hz, "order": order, "lift": lift, "city": True})

	# clear the ground: what stood here moves out to the nearest free place
	footprint = wall_rx + 24
	reach = int(footprint / (PITCH * ISO * .7)) + 6
	inside = set()
	for a in range(-reach, reach + 1):
		for b in range(-reach, reach + 1):
			lot = (best[0] + a, best[1] + b)
			if in_ellipse(*to_xz(lot), hx, hz, footprint):
				inside.add(lot)
	for lot in inside:
		world.lots[lot] = "seat"
		world.road_lots.discard(lot)
	for item in world.things:
		if item is None or item.get("city") or item["kind"] == "house" and item["realm"] == realm["index"]:
			continue
		if item["kind"] == "seat" and item["realm"] == realm["index"]:
			continue
		if in_ellipse(item["x"], item["z"], hx, hz, footprint):
			what = item["kind"]
			lot = world.nearest_free(item["lot"], limit=20000)
			if lot is None:
				continue
			world.lots[lot] = "tree" if what == "tree" else "prop"
			item["lot"] = lot
			item["x"], item["z"] = wobble(lot, .3)

	flights = [math.pi / 2 + (.46 if t % 2 else -.38) * (1 if stable(kind, realm["key"]) % 2 else -1) for t in range(tiers)]
	gate_angle = math.pi / 2 + (.22 if stable("gate", realm["key"]) % 2 else -.22)
	square_angle = gate_angle + (.95 if stable("sq", realm["key"]) % 2 else -.95)
	outer = rings[-1]
	square_radius = min(34, 15 + count * .45)
	sx, sz = hx + math.cos(square_angle) * outer * .96, hz + math.sin(square_angle) * outer * .96 * FLAT
	ground = shape["ground"]
	slots, gaps, spots, route, glows = [], [], [], [], []

	# the keep, on the highest ground
	style = shape["keep"]
	for item in world.things:
		if item.get("kind") == "seat" and item["realm"] == realm["index"]:
			item.update({"x": hx, "z": hz - 2, "block": hz, "order": 2 * tiers + 1, "lift": top_lift, "city": True})
			if style == "hall":
				item["make"] = lambda c=realm["culture"], s=stable("seat", realm["key"]): kit.seat(c, level, s)
			else:
				item["make"] = lambda c=realm["culture"], s=stable("seat", realm["key"]): kit.seatx(style, c, level, s)
	door = (hx - 15 * big, hz - 2 + 7.5 * big - top_lift - 3.4) if style == "hall" else (hx, hz + top_rx * FLAT * .45 - top_lift)

	if kind == "bastide":
		# straight streets, a square wall, the keep on its mound in the middle
		pitch = 24
		halfway = (side + 1) * pitch
		place(("ground_square", halfway, 3 + side), hx, hz, -2, 0, "terrace")
		place(("terrace", top_rx, round(top_rx * FLAT), 6, 9, (.93,), ground), hx, hz - 1, 2 * tiers, top_lift - 6 if top_lift else 0, "terrace")
		world.things[-1]["lift"] = 0
		top_lift = 6
		plan["top"] = 6
		for item in world.things:
			if item.get("kind") == "seat" and item["realm"] == realm["index"]:
				item["lift"] = 6
		door = (hx - 15 * big, hz - 2 + 7.5 * big - 9.4)
		for i in range(-side, side + 1):
			for j in range(-side, side + 1):
				if i % 3 == 0 or j % 3 == 0:
					continue
				x, z = hx + (i - j) * pitch * .96, hz + (i + j) * pitch * .48
				if in_ellipse(x, z, hx, hz, top_rx + 18):
					continue
				if math.hypot(x - sx, (z - sz) / FLAT) < square_radius + 19:
					continue
				slots.append((0, x, z))
				spots.append([x + 8, z + 8])
		gate = (hx, hz + halfway * .96)
		sx, sz = hx - halfway * .55, hz + halfway * .4
		slots = [slot for slot in slots if math.hypot(slot[1] - sx, (slot[2] - sz) / FLAT) > square_radius + 19]
		corners = [(hx, hz - halfway * .96), (hx + halfway * 1.92, hz), (hx, hz + halfway * .96), (hx - halfway * 1.92, hz)]
		for c in range(4):
			(ax, az), (bx, bz) = corners[c], corners[(c + 1) % 4]
			pieces = max(3, int(math.hypot(bx - ax, bz - az) / 36))
			for n in range(pieces):
				x, z = ax + (bx - ax) * n / pieces, az + (bz - az) * n / pieces
				u, v = ax + (bx - ax) * (n + 1) / pieces, az + (bz - az) * (n + 1) / pieces
				south = z + v > 2 * hz
				order = 2 * tiers + 40 if south else -1
				if not (south and abs((x + u) / 2 - gate[0]) < 18):
					place(kit.wall(round(u - x), round(v - z)), x, z, order, 0, "wall")
				place(kit.wall_tower(realm["culture"]), x, z + .5, order, 0, "wall")
		place(kit.gatehouse(realm["culture"]), gate[0], gate[1], 2 * tiers + 41, 0, "wall")
		route = [door, (hx, hz + top_rx * FLAT), gate]
	elif kind == "isles":
		# no ground at all: every quarter of the town floats, tied to the next with ropes
		place(("isle_shadow", top_rx + 8), hx + 8, hz + 10, -2, 0, "terrace")
		place(("floating_isle", top_rx + 6, 9), hx, hz, 2 * tiers, top_lift, "terrace")
		last = (hx, hz + top_rx * FLAT * .4 - top_lift)
		route = [door, last]
		for i, rx in enumerate(rings):
			n = max(4, int(math.tau * rx * .76 / 66))
			for j in range(n):
				a = -math.pi / 2 + (j + (i % 2) * .5) * math.tau / n
				ix, iz = hx + math.cos(a) * rx, hz + math.sin(a) * rx * FLAT
				lift = lift_of(i) + (stable(i, j) % 3) * 4
				ir = 30
				south = iz > hz
				order = order_south(i) if south else order_north(i)
				place(("isle_shadow", ir), ix + 8, iz + 10, -2, 0, "terrace")
				place(("floating_isle", ir, stable(i, j) % 4), ix, iz, order - 1, lift, "terrace")
				if j % 2 == 0:
					u, v = hx + math.cos(a) * top_rx * .9, hz + math.sin(a) * top_rx * .9 * FLAT - top_lift + 2
					dx, dy = round(ix - u), round(iz - lift - v)
					place(("rope", dx, dy), u, v + top_lift - 2, order - 1, top_lift - 2, "stairs") if i == 0 else None
				for k, (ox, oz) in enumerate(((-13, -3), (12, -4), (0, 3), (-3, -9), (5, 8))):
					slots.append((i, ix + ox, iz + oz * .9, lift, order))
				spots.append([ix, iz - lift + 4])
		gate = (hx, hz + wall_rx * FLAT)
	else:
		# rings of houses round the keep, each level higher than the one outside it
		for t in range(tiers):
			t_ring = tiers - 1 - t
			rx = rings[t_ring] + 15 if t else wall_rx - 3
			marks = (round((rings[t_ring] - 15) / rx, 3),)
			height = 1 if t == 0 else max(1, step)
			place(("terrace", rx, round(rx * FLAT), height, 3 + t, marks, ground), hx, hz, order_north(t_ring) - 1, lift_of(t_ring) - height if t else 0, "terrace")
		place(("terrace", top_rx, round(top_rx * FLAT), max(1, step), 9, (.93,), ground), hx, hz, 2 * tiers, top_lift - max(1, step), "terrace")
		arc = (lambda a: math.sin(a) > -.12) if kind == "crag" else (lambda a: True)
		if kind == "crag":
			# the mountain the town is cut into stands right behind the keep
			place(kit.mountain(stable(realm["key"]) % 3), hx - top_rx * .9, hz - top_rx * .34, -3, 0, "deco")
			place(kit.mountain(stable(realm["key"]) % 3 + 1), hx + top_rx * 1.1, hz - top_rx * .4, -3, 0, "deco")
			place(kit.mountain(stable(realm["key"]) % 3 + 2), hx + top_rx * .1, hz - top_rx * .52, -3, 0, "deco")
		base = lift_of(0)
		foot = (hx - 13 * big if style == "hall" else hx, hz + top_rx * FLAT * .98 - base)
		place(("steps", round(door[0] - foot[0]), round(door[1] - foot[1]), 9), foot[0], foot[1] + base, order_south(tiers - 1) - 1, base, "stairs")
		route = [door, foot]
		for t in range(0, tiers - 1):
			rx = rings[t] + 15
			a = flights[t]
			ux, uz = hx + math.cos(a) * rx, hz + math.sin(a) * rx * FLAT
			upper, lower = lift_of(t), lift_of(t + 1)
			if step:
				place(("steps", 0, -(upper - lower) - 9, 7), ux, uz + 9, order_south(t + 1) - 1, lower, "stairs")
			route += [(ux, uz - upper), (ux, uz + 9 - lower)]
		gate = (hx + math.cos(gate_angle) * wall_rx, hz + math.sin(gate_angle) * wall_rx * FLAT)
		for i, rx in enumerate(rings):
			n = int(math.tau * rx * .76 / spacing(i))
			for j in range(n):
				a = -math.pi / 2 + (j + (i % 2) * .5) * math.tau / n
				jitter = (chance("jr", i, j) - .5) * 8 if kind == "grove" else 0
				x, z = hx + math.cos(a) * (rx + jitter), hz + math.sin(a) * (rx + jitter) * FLAT
				if not arc(a):
					continue
				if abs(math.remainder(a - gate_angle, math.tau)) * rx < 22 or abs(math.remainder(a - flights[i], math.tau)) * rx < 15 or abs(math.remainder(a - flights[max(0, i - 1)], math.tau)) * rx < 13:
					continue
				if i == 0 and abs(math.remainder(a - math.pi / 2, math.tau)) * rx < 36:
					continue
				if math.hypot(x - sx, (z - sz) / FLAT) < square_radius + 19:
					continue
				slots.append((i, x, z))
				gaps.append((i, hx + math.cos(a + 1.5 * math.pi / n) * rx * 1.02, hz + math.sin(a + 1.5 * math.pi / n) * rx * FLAT * 1.02))
			for j in range(8):
				a = j / 8 * math.tau + i
				spots.append([hx + math.cos(a) * (rx - 13), hz + math.sin(a) * (rx - 13) * FLAT - lift_of(i)])
		# the defences of its kind
		if shape["wall"] == "ring":
			n = max(12, int(math.tau * wall_rx * .78 / 36))
			joint = lambda i: (hx + math.cos(i / n * math.tau + gate_angle) * wall_rx, hz + math.sin(i / n * math.tau + gate_angle) * wall_rx * FLAT)
			for i in range(n):
				(x, z), (u, v) = joint(i), joint(i + 1)
				order = 2 * tiers + 40 if max(z, v) > hz else -1
				if i != 0:
					place(kit.wall(round(u - x), round(v - z)), x, z, order, 0, "wall")
				place(kit.gatehouse(realm["culture"]) if i == 0 else kit.wall_tower(realm["culture"]), x, z + .5, order + (i == 0), 0, "wall")
		elif shape["wall"] == "towers":
			for i in range(8):
				a = i / 8 * math.tau + .3
				x, z = hx + math.cos(a) * wall_rx, hz + math.sin(a) * wall_rx * FLAT
				place(kit.wall_tower(realm["culture"]), x, z, 2 * tiers + 40 if z > hz else -1, 0, "wall")
		mark_angle = math.pi / 2
		tx, tz = hx + math.cos(mark_angle) * (rings[0] - 4), hz + math.sin(mark_angle) * (rings[0] - 4) * FLAT
		mark = shape["mark"]
		place(("great_tree", stable(realm["key"]) % 2) if mark == "tree" else ("landmark", mark, stable(realm["key"])), tx, tz, order_south(tiers - 1), lift_of(0))
		if mark in ("crystal", "portal"):
			glows.append((tx, tz - lift_of(0) - 18))

	plan["route"] = route
	plan["gate"] = gate
	# the ways people can walk, and only those
	first = len(world.path_nodes)
	node = world.add_node

	def round_way(cx, cy, rx, ry, count, lift=0):
		ids = [node(cx + math.cos(i / count * math.tau) * rx, cy + math.sin(i / count * math.tau) * ry, lift) for i in range(count)]
		for i in range(count):
			world.add_link(ids[i], ids[(i + 1) % count])
		return ids

	def tie(a, ids):
		world.add_link(a, min(ids, key=lambda b: (world.path_nodes[b][0] - world.path_nodes[a][0]) ** 2 + (world.path_nodes[b][1] - world.path_nodes[a][1]) ** 2))

	gate_node = node(gate[0], gate[1] - 2)
	if kind == "bastide":
		grid = {}
		for i in range(-side, side + 1):
			for j in range(-side, side + 1):
				if i % 3 == 0 or j % 3 == 0:
					x, z = hx + (i - j) * 24 * .96, hz + (i + j) * 24 * .48
					if not in_ellipse(x, z, hx, hz, top_rx + 6):
						grid[(i, j)] = node(x, z)
		for (i, j), a in grid.items():
			if j % 3 == 0 and (i + 1, j) in grid:
				world.add_link(a, grid[(i + 1, j)])
			if i % 3 == 0 and (i, j + 1) in grid:
				world.add_link(a, grid[(i, j + 1)])
		streets = list(grid.values())
		tie(gate_node, streets)
		top_ids = round_way(hx, hz - top_lift, top_rx * .86, top_rx * .86 * FLAT, 12, top_lift)
		tie(top_ids[3], streets)
	elif kind == "isles":
		streets = round_way(hx, hz - top_lift + 3, top_rx * .78, top_rx * .78 * FLAT, 12, 255)
		for i, rx in enumerate(rings):
			count_ = max(4, int(math.tau * rx * .76 / 66))
			for j in range(count_):
				a = -math.pi / 2 + (j + (i % 2) * .5) * math.tau / count_
				ix, iz = hx + math.cos(a) * rx, hz + math.sin(a) * rx * FLAT
				round_way(ix, iz - lift_of(i) - (stable(i, j) % 3) * 4, 24, 12, 7, 255)
		streets_low = round_way(hx, hz + wall_rx * FLAT - 8, 12, 5, 5)
		tie(gate_node, streets_low)
		streets = streets_low
	else:
		levels = []
		for i, rx in enumerate(rings):
			street = rx - 13
			levels.append(round_way(hx, hz - lift_of(i), street, street * FLAT, max(14, int(street / 7)), lift_of(i)))
		streets = levels[-1]
		tie(gate_node, levels[-1])
		top_ids = round_way(hx, hz - top_lift, top_rx * .86, top_rx * .86 * FLAT, 12, top_lift)
		foot_node, door_node = node(route[1][0], route[1][1], lift_of(0)), node(door[0], door[1] + 1, top_lift)
		world.add_link(foot_node, door_node)
		tie(foot_node, levels[0])
		tie(door_node, top_ids)
		for t in range(0, tiers - 1):
			rx = rings[t] + 15
			a = flights[t]
			ux, uz = hx + math.cos(a) * rx, hz + math.sin(a) * rx * FLAT
			high, low = node(ux, uz - lift_of(t) - 1, lift_of(t)), node(ux, uz + 9 - lift_of(t + 1), lift_of(t + 1))
			world.add_link(high, low)
			tie(high, levels[t])
			tie(low, levels[t + 1])
	ring = round_way(sx, sz, square_radius * .46, square_radius * .46 * FLAT, 9)
	tie(ring[2], streets)
	plan["gate_node"] = gate_node
	realm["nodes"] = [first, len(world.path_nodes)]
	plan["door"] = door
	plan["spots"] = spots
	plan["glows"] = glows
	if kind == "isles":
		world.things[-1]["make"] = world.things[-1]["make"]
	realm["square"] = (sx, sz, square_radius)
	realm["stalls"] = []
	dress_square(world, realm, count, (sx, sz), order_south(0), hz)
	if kind == "isles":
		place(("landmark", shape["mark"], stable(realm["key"])), hx, hz + top_rx * FLAT * .6, 2 * tiers + 2, top_lift)

	plan["slots"] = slots
	finest = lambda ring: max(1, 4 - ring) if ring < 4 else 1 + (ring % 2)

	def stand(item, slot):
		ring, x, z = slot[:3]
		lift = slot[3] if len(slot) > 3 else lift_of(ring) if step else 0
		order = slot[4] if len(slot) > 3 else (order_south(ring) if z > hz else order_north(ring))
		key = item["lot"]
		item.update({"x": x, "z": z, "block": hz, "lift": lift, "order": order, "tier": finest(ring), "city": True, "ring": ring})
		item["make"] = lambda r=finest(ring), k=key: house_art(realm, r, k)

	for item, slot in zip(sorted(houses, key=lambda it: (it["day"], it["lot"])), slots):
		stand(item, slot)
	plan["used"] = min(len(houses), len(slots))
	plan["lift"] = lambda slot: slot[3] if len(slot) > 3 else lift_of(slot[0]) if step else 0

	# what is not built on yet is garden, and between the houses things grow
	greens = shape["green"]

	def green(slot, seed):
		ring, x, z = slot[:3]
		lift = plan["lift"](slot)
		order = slot[4] if len(slot) > 3 else (order_south(ring) if z > hz else order_north(ring))
		tree = greens[seed % len(greens)]
		art = (kit.field(seed % 3) if seed % 5 == 0 and tree != "palm" else kit.well(0) if seed % 11 == 0 else kit.hedge(seed % 3) if seed % 3 == 0 and tree != "palm"
		       else ("palm", seed) if tree == "palm" else kit.pine("pine", seed % 4) if tree == "pine" else kit.birch("leaf", seed % 5) if tree == "birch" else kit.oak("leaf", seed % 5))
		place(art, x, z, order, lift)

	for i, slot in enumerate(slots[plan["used"]:]):
		green(slot, stable(realm["key"], "free", i))
	for i, gap in enumerate(gaps):
		if chance(realm["key"], "gap", i) < (.75 if kind == "grove" else .5):
			green(gap, stable(realm["key"], "gap", i) | 2)
	if count >= 16 and kind not in ("bastide", "isles"):
		a = -math.pi / 2 + .9
		x, z = hx + math.cos(a) * rings[0], hz + math.sin(a) * rings[0] * FLAT
		place(kit.temple(realm["culture"], stable(realm["key"], "t")), x, z, order_north(tiers - 1), lift_of(0))


def dress_square(world, realm, houses, at=None, order=0, block=None):
	"""The market: a fountain, stalls round it by how big the town is, crates, a statue when it can afford one."""
	gx, gz = at or to_xz(realm["gate"])
	radius = realm["square"][2] if at else min(30, 13 + houses * .55)
	realm["square"] = (gx, gz, radius)
	day, index = realm["first"], realm["index"]
	put = lambda art, x, z: world.things.append({"make": lambda: art, "x": x, "z": z, "day": day, "plot": None, "realm": index, "kind": "deco", "lot": realm["gate"], "yaw": 0, "scale": 1.0, **({"block": block, "order": order, "city": True} if at else {})})
	if at:
		put(("plaza", round(radius)), gx, gz)
	else:
		first = len(world.path_nodes)
		for i in range(9):
			a = i / 9 * math.tau
			world.add_node(gx + math.cos(a) * radius * .46, gz + math.sin(a) * radius * .46 * FLAT)
		for i in range(9):
			world.add_link(first + i, first + (i + 1) % 9)
		realm["nodes"] = [first, first + 9]
		realm["plaza_node"] = first + 2
	put(kit.fountain(0), gx, gz)
	count = min(14, 2 + houses // 3)
	stalls = []
	for i in range(count):
		a = (i + .5) / count * math.tau + chance("sq", realm["key"]) * 2
		x, z = gx + math.cos(a) * radius * .72, gz + math.sin(a) * radius * .72 * FLAT
		put(kit.stall(stable(realm["key"], i) % 6), x, z)
		stalls.append((x, z + 3))
		if i % 3 == 0:
			put(kit.crates(i % 3), x + 7, z + 1.5)
	if houses >= 12:
		put(kit.statue(0), gx - radius * .32, gz + radius * .38)
	realm["stalls"] = stalls


def add_walkers(world, people):
	"""Ten people for everyone on a ticket, about the patch; the shell walks them."""
	total = 0
	world.groups = []
	for plot in world.plots:
		if not plot["lots"]:
			continue
		names = people.get(str(plot.get("task")), []) if plot.get("task") else []
		persons = len(names) or plot.get("people") or 1
		plot["persons"] = names
		count = min(persons * PEOPLE_PER_PERSON, 16 + plot["houses"] + plot["trees"] // 6, MOST_WALKERS - total)
		if count <= 0:
			continue
		total += count
		own = [item for item in world.things if item["plot"] == plot["index"] and item["kind"] in ("house", "tree") and not item.get("city")]
		if own:
			world.groups.append({"plot": plot["index"], "count": count, "first": plot["first"], "at": (own[0]["x"], own[0]["z"])})


def add_sea_life(world, ground):
	extra = lambda art, x, z, day=0, kind="boat": world.things.append({"make": lambda: art, "x": x, "z": z, "day": day, "plot": None, "realm": None, "kind": kind, "lot": (0, 0), "yaw": 0, "scale": 1.0})
	cx, cz = ground["width"] / 2 + ground["x0"], ground["height"] / 2 + ground["z0"]
	for i, day in enumerate(world.ships):
		a = stable("ship", i) % 628 / 100
		for r in np.linspace(.3, .5, 14) * min(ground["width"], ground["height"]):
			x, z = cx + math.cos(a) * r, cz + math.sin(a) * r
			if ground["height_at"](x, z) < -1:
				extra(kit.harbour_ship(i), x, z, day)
				break


def add_treasure(world, numbers):
	"""What went to Teamwork is gold at the seat, what has not yet is carts on their way."""
	for realm in world.realm_list:
		sent = numbers.get("sent", {}).get(realm["key"], 0)
		unsent = numbers.get("unsent", {}).get(realm["key"], 0)
		if sent >= 30:
			item = world.prop(lambda amount=int(sent / 60), seed=realm["key"]: kit.gold_pile(amount, seed), realm["first"], realm["centre"], ring=0, kind="deco", realm=realm["index"])
			world.spots.setdefault("gold", (item["x"], item["z"]))
		lots = sorted(lot for lot in world.road_lots if distance(lot, realm["centre"]) < 14)
		for i in range(min(5, int(unsent / 90))):
			if lots:
				lot = lots[stable(realm["key"], "cart", i) % len(lots)]
				item = world.thing(lambda seed=stable(realm["key"], i): kit.cart(seed), lot, len(world.days) - 1, realm=realm["index"], kind="walker", amount=.1)
				item["radius"] = 22
	done, open_ = numbers.get("todos", (0, 0))
	if (done or open_) and world.realm_list:
		first = world.realm_list[0]
		road = sorted(world.road_lots, key=lambda lot: distance(lot, first["centre"]))
		for i in range(min(done, 80, len(road))):
			if i % 3 == 0:
				world.thing(lambda seed=i: kit.milestone(seed), road[i], 0, kind="deco", amount=.32, offset=(5, 3))
		for i in range(min(open_, 30)):
			lot = world.nearest_free((first["centre"][0] + 9 + i % 3, first["centre"][1] - 9 - i // 3))
			world.take(lot, "prop")
			world.thing(lambda seed=i: kit.hedge(seed), lot, len(world.days) - 1, kind="deco", amount=.2)


# ── the ground ──────────────────────────────────────────────────────────────

from_paint = (paint.blur, paint.noise, paint.smooth, paint.spline)
blur, noise, smooth, spline = from_paint


def sample(field, x, z, x0, z0, scale):
	h, w = field.shape
	u, v = (x - x0) * scale, (z - z0) * scale
	u, v = min(w - 1.001, max(0, u)), min(h - 1.001, max(0, v))
	a, b = int(u), int(v)
	fu, fv = u - a, v - b
	return float(field[b, a] * (1 - fu) * (1 - fv) + field[b, a + 1] * fu * (1 - fv) + field[b + 1, a] * (1 - fu) * fv + field[b + 1, a + 1] * fu * fv)


RIVER_ITEMS = 20  # every so much water drunk another river


def carve_rivers(world, land, water, town, broad, shape, pos, scale, x0, z0, lw, lh):
	"""Water runs: from the lakes, later from springs in the hills, down to the sea or into another
	river, round the towns; the more is drunk the more rivers there are, and they widen on the way."""
	count = min(9, (len(world.water) + RIVER_ITEMS - 1) // RIVER_ITEMS)
	if not count:
		return np.zeros(shape, dtype=np.float32)
	cell = 3
	gh, gw = lh // cell + 1, lw // cell + 1
	coarse = lambda field: np.asarray(Image.fromarray(np.asarray(field, dtype=np.float32), mode="F").resize((gw, gh), Image.BILINEAR), dtype=np.float32)
	sea = coarse(land) < .5
	lakes = coarse(water) > .5
	price = 1 + (coarse(noise(shape, 24 * scale, 61, 4)) * .5 + .5) * 5 + coarse(town) * 7 + np.maximum(0, coarse(broad)) * 1.5
	blocked = np.zeros((gh, gw), dtype=bool)
	ys, xs = np.ogrid[:gh, :gw]
	for plan in world.plans:
		cx, cy = pos((plan["x"], plan["z"]))
		rx = (plan["wall"] + 22) * scale / cell
		blocked |= ((xs - cx / cell) / rx) ** 2 + ((ys - cy / cell) / (rx * FLAT)) ** 2 < 1
	for lot, kind in world.lots.items():
		if kind in ("house", "seat", "plaza"):
			x, y = pos(to_xz(lot))
			u, v = int(x / cell), int(y / cell)
			if 0 <= v < gh and 0 <= u < gw:
				price[max(0, v - 1):v + 2, max(0, u - 1):u + 2] += 40
	inland = blur(np.asarray(land, dtype=np.float64), 40 * scale)
	flowing = np.zeros((gh, gw), dtype=bool)
	lake_lots = [item for item in world.water if not item["river"]]
	sources = []
	for n in range(count):
		day = world.water[min(len(world.water) - 1, n * RIVER_ITEMS)]["day"]
		if n % 2 == 0 and n < len(lake_lots):
			x, y = pos(to_xz(lake_lots[n]["lot"]))
			spring = False
		else:
			# a spring high up and far from the sea, somewhere new
			best, x, y, spring = -1, 0, 0, True
			for t in range(60):
				u, v = chance("spring", n, t, 1) * (lw - 1), chance("spring", n, t, 2) * (lh - 1)
				if blocked[int(v / cell), int(u / cell)]:
					continue
				near = min((math.hypot(u - a, v - b) for a, b, _, _ in sources), default=200)
				score = inland[int(v), int(u)] * (1 + broad[int(v), int(u)] * .4) * min(1, near / 80)
				if score > best:
					best, x, y = score, u, v
		sources.append((x, y, day, spring))
	image = Image.new("F", (lw, lh), 0)
	draw = ImageDraw.Draw(image)
	for x, y, day, spring in sources:
		start = (min(gh - 1, int(y / cell)), min(gw - 1, int(x / cell)))
		if sea[start] or blocked[start]:
			continue
		seen = {start: None}
		spent = {start: 0.0}
		heap = [(0.0, start)]
		end = None
		while heap and len(seen) < 90000:
			cost, here = heapq.heappop(heap)
			if cost > spent[here]:
				continue
			if sea[here] or (flowing[here] and here != start):
				end = here
				break
			for dv, du in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
				v, u = here[0] + dv, here[1] + du
				if not (0 <= v < gh and 0 <= u < gw) or blocked[v, u]:
					continue
				step = price[v, u] * (1.41 if dv and du else 1) * (.3 if lakes[v, u] else 1)
				if cost + step < spent.get((v, u), 1e18):
					spent[(v, u)] = cost + step
					seen[(v, u)] = here
					heapq.heappush(heap, (cost + step, (v, u)))
		if end is None:
			continue
		path = []
		here = end
		while here is not None:
			path.append(here)
			here = seen[here]
		path.reverse()
		if len(path) < 30:
			continue
		for place in path:
			flowing[place] = True
		points = [((u + .5) * cell, (v + .5) * cell) for v, u in path[::3]] + [((path[-1][1] + .5) * cell, (path[-1][0] + .5) * cell)]
		points = spline(points, 4)
		total = max(1, len(points) - 1)
		for i, (a, b) in enumerate(zip(points, points[1:])):
			width = (4.6 + 7 * i / total) * scale
			draw.line([a, b], fill=1, width=max(2, round(width)))
			draw.ellipse((a[0] - width / 2, a[1] - width / 2, a[0] + width / 2, a[1] + width / 2), fill=1)
			if i % 4 == 0:
				world.river_days.append((a[0] / scale + x0, a[1] / scale + z0, min(254, day + int(6 * i / total))))
		if spring:
			world.things.append({"make": lambda: kit.spring_head(0), "x": points[0][0] / scale + x0, "z": points[0][1] / scale + z0 - 3, "day": day, "plot": None, "realm": None, "kind": "boat", "lot": (0, 0), "yaw": 0, "scale": 1.0})
	return smooth(.3, .6, blur(np.asarray(image, dtype=np.float32), max(.5, 1.6 * scale)))


def make_ground(world):
	lots = [lot for lot, kind in world.lots.items() if kind != "planned"] or [(0, 0)]
	spots = [to_xz(lot) for lot in lots]
	xs, zs = [p[0] for p in spots], [p[1] for p in spots]
	pad = MARGIN * PITCH
	x0, z0 = min(xs) - pad, min(zs) - pad
	width, height = max(xs) + pad - x0, max(zs) + pad - z0
	scale = min(1.0, 2048 / max(width, height)) * .5
	lw, lh = int(width * scale) + 2, int(height * scale) + 2
	shape = (lh, lw)

	def pos(point):
		return (point[0] - x0) * scale, (point[1] - z0) * scale

	def paint(items, radius):
		image = Image.new("F", (lw, lh), 0)
		draw = ImageDraw.Draw(image)
		r = radius * PITCH * scale
		for lot in items:
			x, y = pos(to_xz(lot))
			draw.ellipse((x - r, y - r, x + r, y + r), fill=1)
		return np.asarray(image, dtype=np.float32)

	land_mask = paint(lots, 1.85)
	kinds = lambda *names: [lot for lot in lots if world.lots[lot] in names]
	forest = blur(paint(kinds("tree"), .95), PITCH * .55 * scale)
	town = blur(paint(kinds("house", "seat", "garden", "road", "prop"), .95), PITCH * .45 * scale)
	coast = noise(shape, PITCH * 7 * scale, 11, 5)
	broad = noise(shape, 90 * scale, 23, 4)
	field = blur(land_mask, PITCH * .7 * scale) + blur(land_mask, PITCH * 3 * scale) * .55 + coast * .3
	land = smooth(.32, .5, field)

	wet_image = Image.new("F", (lw, lh), 0)
	wet_draw = ImageDraw.Draw(wet_image)
	river_image = Image.new("F", (lw, lh), 0)
	river_draw = ImageDraw.Draw(river_image)
	for item in world.water:
		if not item["river"]:
			x, y = pos(to_xz(item["lot"]))
			r = PITCH * 1.05 * scale
			wet_draw.ellipse((x - r, y - r, x + r, y + r), fill=1)
	for path in world.rivers:
		points = spline([pos(wobble(lot, .22)) for lot in path], 6)
		if len(points) > 1:
			river_draw.line(points, fill=1, width=max(2, round(PITCH * .55 * scale)), joint="curve")
	lake = smooth(.38, .62, blur(np.asarray(wet_image, dtype=np.float32), PITCH * .42 * scale) + coast * .1)
	river = smooth(.3, .6, blur(np.asarray(river_image, dtype=np.float32), PITCH * .12 * scale))
	water = np.maximum(lake, river)
	for plan in world.plans:
		mask = Image.new("F", (lw, lh), 0)
		cx, cy = pos((plan["x"], plan["z"]))
		rx, ry = (plan["wall"] + 30) * scale, (plan["wall"] + 30) * FLAT * scale
		ImageDraw.Draw(mask).ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=1)
		mask = blur(np.asarray(mask, dtype=np.float32), 2 * scale * 5)
		water = water * (1 - np.clip(mask * 1.4, 0, 1))
		land = np.maximum(land, np.clip(mask * 1.4, 0, 1))
		town = np.maximum(town, np.clip(mask * 1.4, 0, 1))

	rivers = carve_rivers(world, land, water, town, broad, shape, pos, scale, x0, z0, lw, lh)
	river_land = (rivers * (land > .5) * (water < .5)).astype(np.float32)
	water = np.maximum(water, rivers)

	# heights: flats where people live, rolling land elsewhere, under water below 0
	hills = (broad * .5 + .5) ** 1.5 * 26 * (1 - np.clip(town * 1.25, 0, 1)) + 5 + coast * 2.5
	rim = np.clip(field - .5, 0, 1)
	height_field = land * (hills * smooth(0, .7, rim + .22) + 1.5) - (1 - land) * 12 - water * 11
	height_field = blur(height_field.astype(np.float64), 1.1).astype(np.float32)

	wet = np.clip((1 - land) + water, 0, 1)
	return {"x0": x0, "z0": z0, "width": width, "height": height, "scale": scale, "field": height_field,
	        "forest": forest, "town": town, "broad": broad, "wet": wet, "river": river_land, "height_at": lambda x, z: sample(height_field, x, z, x0, z0, scale)}


def land_days(world):
	days = {}
	for item in world.things:
		if item["lot"] != (0, 0) and (item["lot"] not in days or item["day"] < days[item["lot"]]):
			days[item["lot"]] = item["day"]
	for item in world.water:
		days.setdefault(item["lot"], item["day"])
	return days


def next_site(world, plot, ground, cache):
	"""What goes up next on a plot and how far it is, for the running timer."""
	realm = world.realm_list[plot["realm"]]
	if plot["anchor"] is None:
		return None
	billable = plot["houses"] > 0 or plot["trees"] == 0
	lot = world.best_lot(plot, realm, "house" if billable else "tree")
	x, z = wobble(lot)
	plan = realm.get("plan")
	if billable and plan and plan["used"] < len(plan["slots"]):
		slot = plan["slots"][plan["used"]]
		x, z = slot[1], slot[2] - plan["lift"](slot)
	art = house_art(realm, min(3, 1 + plot["houses"] // 6), lot) if billable else kit.oak("leaf", stable(*lot) % 5)
	image, ax, ay = cache(art)
	return {"x": round(x - ground["x0"], 1), "z": round(z - ground["z0"], 1), "kind": "house" if billable else "tree", "file": str(cache.dir / f"{sprites.key_of(art)}.png"),
	        "w": round(image.width / sprites.FINAL, 1), "h": round(image.height / sprites.FINAL, 1), "ax": round(ax, 1), "ay": round(ay, 1),
	        "credit": plot["bill_credit"] if billable else plot["other_credit"], "unit": HOUSE_MINUTES if billable else TREE_MINUTES}


def sea_lanes(ground):
	"""Where a boat can sail back and forth."""
	lanes = []
	for i in range(40):
		x = ground["x0"] + chance("bx", i) * ground["width"]
		z = ground["z0"] + chance("bz", i) * ground["height"]
		if all(ground["height_at"](x + d, z) < -1.5 for d in (-50, 0, 50)):
			lanes.append([round(x - ground["x0"], 1), round(z - ground["z0"], 1)])
		if len(lanes) >= 7:
			break
	return lanes


def write_minis(world, records, cache, out):
	"""A day or a ticket as a little land of its own, not a crop of the map."""
	folder = out / "mini"
	folder.mkdir()
	memo = {}

	def spread(rnd, sector, width):
		a = sector + rnd.uniform(-.5, .5) * width
		r = math.sqrt(rnd.uniform(.03, 1))
		return math.cos(a) * r, math.sin(a) * r

	for index, record in enumerate(records):
		rnd = random.Random(record["day"])
		items = []
		parts = record["plots"]
		width = math.tau / max(1, len(parts))
		for s, part in enumerate(parts):
			plot = world.plots[part["plot"]]
			culture = world.realm_list[plot["realm"]]["culture"]
			for i in range(min(part["houses"], 24)):
				items.append((kit.house(culture, min(4, part["houses"] // 4), (stable(s, i) % 5)), *spread(rnd, s * width + .4, width)))
			for i in range(min(part["trees"], 44)):
				art = kit.pine("pine", i % 4) if i % 4 == 0 else kit.oak(season_leaf(record["day"], (s, i)), i % 5)
				items.append((art, *spread(rnd, s * width + .4, width)))
		for i in range(min(record["rests"], 5)):
			items.append((kit.flowers(i % 4), *spread(rnd, rnd.uniform(0, 6.28), 6.28)))
		paint.mini(items, cache, index + 1, folder / f"day-{index}.png", memo)
	for plot in world.plots:
		own = [item for item in world.things if item["plot"] == plot["index"] and item["kind"] in ("house", "tree", "deco", "elf")]
		if not own:
			continue
		cx = sum(item["x"] for item in own) / len(own)
		cz = sum(item["z"] for item in own) / len(own)
		reach = max(30, max(math.hypot(item["x"] - cx, item["z"] - cz) for item in own))
		stride = max(1, len(own) // 90)
		items = [(item["make"](), (item["x"] - cx) / reach, (item["z"] - cz) / reach) for i, item in enumerate(own) if i % stride == 0 or item["kind"] == "elf"]
		paint.mini(items, cache, plot["index"] + 500, folder / f"plot-{plot['index']}.png", memo)


def road_scene(world, ground):
	"""The ways of the land and of the towns, for the painter."""
	roads = [spline(road["points"]) for road in world.roads]
	points = [p for road in world.roads for p in road["points"]]
	lanes = []
	for item in world.things:
		if item["kind"] == "house" and item.get("density", 0) >= 2 and not item.get("city"):
			realm = world.realm_list[item["realm"]]
			others = [p for p in points if abs(p[0] - item["x"]) < 60 and abs(p[1] - item["z"]) < 60]
			if realm.get("square"):
				others.append(realm["square"][:2])
			if others:
				near = min(others, key=lambda p: (p[0] - item["x"]) ** 2 + (p[1] - item["z"]) ** 2)
				if 4 < math.hypot(near[0] - item["x"], near[1] - item["z"]) < 44:
					lanes.append(((item["x"], item["z"] + 2.5), near))
	plazas = [realm["square"] for realm in world.realm_list if realm.get("square") and not realm.get("plan")]
	# the ways stop at a town's wall and go in by its gate
	clipped = []
	linked = set()
	for road in roads:
		piece = []
		for point in road:
			home = next((plan for plan in world.plans if in_ellipse(point[0], point[1], plan["x"], plan["z"], plan["wall"] + 8)), None)
			if home is None:
				piece.append(point)
				continue
			if piece:
				clipped.append(piece + [home["gate"]])
				linked.add(id(home))
				piece = []
		if len(piece) > 1:
			clipped.append(piece)
	outside = [p for road in clipped for p in road]
	for plan in world.plans:
		if id(plan) not in linked and outside:
			near = min(outside, key=lambda p: (p[0] - plan["gate"][0]) ** 2 + (p[1] - plan["gate"][1]) ** 2)
			clipped.append([plan["gate"], near])
	roads = clipped
	return roads, lanes, plazas


def ways_on_roads(world, roads, ground):
	"""The roads are ways for people too; where one meets water there is a bridge."""
	known = {}

	def road_node(point):
		key = (round(point[0] / 7), round(point[1] / 7))
		if key not in known:
			known[key] = world.add_node(point[0], point[1])
		return known[key]

	ids = []
	for road in roads:
		last, walked, before = None, 99, road[0]
		for point in road:
			walked += math.hypot(point[0] - before[0], point[1] - before[1])
			before = point
			if walked >= 13 or point is road[-1]:
				here = road_node(point)
				ids.append(here)
				if last is not None:
					world.add_link(last, here)
				last, walked = here, 0

	def near_road(x, y, within):
		if not ids:
			return None
		near = min(ids, key=lambda n: (world.path_nodes[n][0] - x) ** 2 + (world.path_nodes[n][1] - y) ** 2)
		return near if math.hypot(world.path_nodes[near][0] - x, world.path_nodes[near][1] - y) < within else None

	for plan in world.plans:
		near = near_road(*plan["gate"], 45)
		if near is not None:
			world.add_link(plan["gate_node"], near)
	for realm in world.realm_list:
		if realm.get("plaza_node") is not None:
			near = near_road(*world.path_nodes[realm["plaza_node"]], 60)
			if near is not None:
				world.add_link(realm["plaza_node"], near)
	for group in world.groups:
		near = near_road(*group["at"], 110)
		group["node"] = -1 if near is None else near
	for road in roads:
		run = []
		for a, b in zip(road, road[1:]):
			for t in (0, .5):
				x, z = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
				if paint.sample_wet(ground, x, z) > .5:
					run.append((x, z))
				elif run:
					mid = run[len(run) // 2]
					sign = int((b[0] - a[0]) * (b[1] - a[1]) < 0)
					world.things.append({"make": lambda sign=sign: ("bridge", sign), "x": mid[0], "z": mid[1], "day": 0, "plot": None, "realm": None, "kind": "bridge", "lot": (0, 0), "yaw": 0, "scale": 1.0})
					run = []


def plan_cities(world, ground, lanes):
	"""The towns worth a close look: the sharp picture's frame and how life moves there."""
	x0, z0 = ground["x0"], ground["z0"]
	cities = []
	off = lambda p: [round(p[0] - x0, 1), round(p[1] - z0, 1)]
	for plan in world.plans:
		realm = plan["realm"]
		gx, gz, radius = realm["square"]
		wall, hx, hz = plan["wall"], plan["x"], plan["z"]
		left, right = hx - wall - 26, hx + wall + 26
		top, bottom = hz - wall * FLAT - plan["top"] - 150, hz + wall * FLAT + 34
		own = [item for item in world.things if item["realm"] == realm["index"] and item.get("city")]
		spokes = [list(p) for p in realm.get("stalls", [])]
		spokes += plan["spots"]
		smoke = [(item["x"] + 2, item["z"] - item.get("lift", 0) - 16 - item.get("tier", 1) * 3) for item in own if item["kind"] == "house"][:26]
		info = {"name": title(realm["name"]), "realm": realm["index"], "first": realm["first"], "x": round(gx - x0, 1), "z": round(gz - z0, 1), "r": round(radius, 1), "people": min(80, 26 + realm["own"]),
		        "spokes": [off(p) for p in spokes[:70]], "stairs": [off(p) for p in plan["route"]], "smoke": [off(p) for p in smoke], "mills": [],
		        "centre": off((hx, hz - plan["top"] - 10)), "flag": off((hx, hz - plan["top"] - 62)) if plan["kind"] in ("hill", "canals", "bastide") else None, "planned": True,
		        "nodes": realm.get("nodes"), "kind": plan["kind"], "glows": [off(p) for p in plan["glows"]], "keep": off((hx, hz - plan["top"]))}
		cities.append({"rect": (left, top, right - left, bottom - top), "info": info, "hash": ""})
	for realm in sorted(world.realm_list, key=lambda r: -r["bill"])[:12]:
		if not realm.get("square") or realm.get("plan"):
			continue
		gx, gz, radius = realm["square"]
		cx, cz = to_xz(realm["centre"])
		own = [item for item in world.things if item["realm"] == realm["index"] and item["kind"] in ("house", "seat", "deco") and math.hypot(item["x"] - gx, item["z"] - gz) < 190]
		xs, zs = [item["x"] for item in own], [item["z"] for item in own]
		left, right = min(xs + [cx - 110]) - 34, max(xs + [cx + 110]) + 34
		top, bottom = min(zs + [cz - 170]) - 24, max(zs + [gz + radius]) + 40
		level = seat_level(realm)
		stairs = 24 + max(0, level - 2) * 6
		spokes = [list(p) for p in realm.get("stalls", [])]
		for lane in lanes:
			if abs(lane[1][0] - gx) < 2 and abs(lane[1][1] - gz) < 2:
				spokes.append([lane[0][0], lane[0][1]])
		smoke = [(item["x"] + 3, item["z"] - 14 - item.get("tier", 1) * 2.5) for item in own if item["kind"] == "house" and item.get("tier", 1) >= 1][:26]
		mills = [(item["x"], item["z"] - 19) for item in world.things if item["realm"] == realm["index"] and item["make"] and item["kind"] == "deco" and item["make"]()[0] == "windmill"][:6]
		info = {"name": title(realm["name"]), "realm": realm["index"], "first": realm["first"], "x": round(gx - x0, 1), "z": round(gz - z0, 1), "r": round(radius, 1), "people": min(50, 14 + realm.get("own", 0)),
		        "spokes": [[round(p[0] - x0, 1), round(p[1] - z0, 1)] for p in spokes[:40]],
		        "stairs": [[round(gx - x0, 1), round(gz - radius * .6 - z0, 1)], [round(cx - x0, 1), round(cz + stairs * .9 - z0, 1)], [round(cx - x0, 1), round(cz - 12 - level * 6 - z0, 1)]] if level >= 2 else [],
		        "smoke": [[round(p[0] - x0, 1), round(p[1] - z0, 1)] for p in smoke], "mills": [[round(p[0] - x0, 1), round(p[1] - z0, 1)] for p in mills],
		        "nodes": realm.get("nodes"), "centre": [round(cx - x0, 1), round(cz - 16 - z0, 1)], "flag": [round(cx - x0, 1), round(cz - 56 - z0, 1)]}
		cities.append({"rect": (left, top, right - left, bottom - top), "info": info, "hash": len(lanes) and str(sorted(map(str, lanes))[:0])})
	return cities


NAMED = {"tavern": "Taverne", "forge": "Schmiede", "arena": "Arena", "theatre": "Theater", "lighthouse": "Leuchtturm", "windmill": "Mühle", "ruin": "Ruine",
         "elf_tower": "Elfenturm", "world_tree": "Weltenbaum", "tourney": "Turnier", "market": "Markt", "temple": "Tempel", "spring_head": "Quelle"}


def labels_of(world, x0, z0):
	"""A name for everything one can look at closely: the tickets, and what stands for itself."""
	out = []
	seen = set()
	for item in world.things:
		y = item["z"] - item.get("lift", 0)
		if item["plot"] is not None and item["kind"] in ("house", "tree") and item["plot"] not in seen:
			seen.add(item["plot"])
			plot = world.plots[item["plot"]]
			out.append([round(item["x"] - x0, 1), round(y + 4 - z0, 1), title(plot["name"]), plot["houses"] * 3 + plot["trees"] * .3, item["day"]])
		name = NAMED.get(item["art"][0])
		if name:
			out.append([round(item["x"] - x0, 1), round(y + 5 - z0, 1), name, 3, item["day"]])
	return out


def title(name):
	"""A shop's address reads as its name on a map."""
	name = re.sub(r"\s+-\s+(www\.\S+|Shopware.*)$", "", name).strip()
	name = re.sub(r"^https?://(www\.)?", "", name).rstrip("/ ")
	return name or "—"


def describe(world, records, ground, stamp, used, painted, cache):
	x0, z0 = ground["x0"], ground["z0"]
	for record in records:
		record["focus"] = [round(record["focus"][0] - x0, 1), round(record["focus"][1] - z0, 1)]
	plots = []
	for plot in world.plots:
		spots = [(item["x"], item["z"] - item.get("lift", 0)) for item in world.things if item["plot"] == plot["index"] and item["kind"] in ("house", "tree")] or [to_xz(lot) for lot in plot["lots"]] or [to_xz(plot["anchor"] or (0, 0))]
		x, z = sum(s[0] for s in spots) / len(spots), sum(s[1] for s in spots) / len(spots)
		plots.append({"name": plot["name"], "project": plot["project"], "description": plot["description"], "realm": plot["realm"],
		              "x": round(x - x0, 1), "z": round(z - z0, 1), "bill": plot["bill"], "other": plot["other"], "houses": plot["houses"], "trees": plot["trees"], "elves": plot["elves"],
		              "first": plot["first"], "last": plot["last"], "persons": plot.get("persons", []), "site": next_site(world, plot, ground, cache)})
	realms = []
	for realm in world.realm_list:
		x, z = to_xz(realm["centre"])
		realms.append({"name": title(realm["name"]), "x": round(x - x0, 1), "z": round(z - z0, 1), "bill": realm["bill"], "other": realm["other"], "houses": realm["houses"], "trees": realm["trees"],
		               "level": seat_level(realm), "culture": realm["culture"]["name"], "first": realm["first"], "plots": len(realm["plots"])})
	picks = [[round(item["x"] - x0, 1), round(item["z"] - item.get("lift", 0) - z0, 1), item["plot"], item["day"]] for item in world.things if item["plot"] is not None and item["kind"] in ("house", "tree", "elf")]
	spots = {name: [round(place[0] - x0, 1), round(place[1] - z0, 1)] for name, place in world.spots.items()}
	if world.water:
		x, z = to_xz(world.water[-1]["lot"])
		spots["water"] = [round(x - x0, 1), round(z - z0, 1)]
	rests = [item for item in world.things if item["kind"] == "ground"]
	if rests:
		spots["rest"] = [round(rests[-1]["x"] - x0, 1), round(rests[-1]["z"] - z0, 1)]
	if world.realm_list:
		x, z = to_xz(world.realm_list[0]["centre"])
		spots["capital"] = [round(x - x0, 1), round(z - world.realm_list[0].get("plan", {}).get("top", 0) - z0, 1)]
	return {"stamp": stamp, "width": round(ground["width"], 1), "height": round(ground["height"], 1), "days": records, "realms": realms, "plots": plots, "picks": picks,
	        "spots": spots, "used": used, "scale": painted["scale"], "cities": painted["cities"],
	        "groups": [{"plot": g["plot"], "count": g["count"], "first": g["first"], "node": g["node"], "x": round(g["at"][0] - x0, 1), "z": round(g["at"][1] - z0, 1)} for g in world.groups if g.get("node", -1) >= 0],
	        "paths": {"nodes": [[round(p[0] - x0, 1), round(p[1] - z0, 1)] for p in world.path_nodes], "links": [sorted(links) for links in world.path_links], "lifts": world.path_lifts},
	        "labels": labels_of(world, x0, z0),
	        "mills": [[round(t["x"] - x0 - 1.6, 1), round(t["z"] - t.get("lift", 0) - 20 - z0, 1)] for t in world.things if t["art"][0] == "windmill"][:30],
	        "sprites": str(cache.dir), "boats": sea_lanes(ground),
	        "totals": {"bill": sum(r["bill"] for r in records), "other": sum(r["other"] for r in records), "ml": sum(r["ml"] for r in records),
	                   "houses": sum(1 for t in world.things if t["kind"] == "house"), "trees": sum(1 for t in world.things if t["kind"] == "tree"),
	                   "elves": sum(1 for t in world.things if t["kind"] == "elf"), "walkers": sum(g["count"] for g in world.groups),
	                   "water": len(world.water)}}


def fingerprint(work, numbers, used):
	digest = hashlib.sha256(f"{VERSION}".encode())
	digest.update(json.dumps(used, sort_keys=True).encode())
	for day in sorted(work):
		digest.update(day.encode())
		for entry in work[day]:
			digest.update(f"{entry['key']}|{entry['bill']}|{entry['other']}|{entry.get('sent')}".encode())
	digest.update(json.dumps(numbers, sort_keys=True, default=str).encode())
	return digest.hexdigest()[:16]


def palette_of(argv):
	"""The shell's colours as the shell hands them over: --palette '{"shell": [...], "primary": "#..."}'."""
	if "--palette" in argv:
		return json.loads(argv[argv.index("--palette") + 1])
	saved = sources.cache() / "world" / "palette.json"
	return json.loads(saved.read_text()) if saved.exists() else {"shell": [], "primary": None}


def main(argv):
	root = sources.cache() / "world"
	root.mkdir(parents=True, exist_ok=True)
	palette = palette_of(argv)
	(root / "palette.json").write_text(json.dumps(palette))
	work, numbers, used, _plugins = sources.gather()
	stamp = fingerprint(work, {**numbers, "palette": palette}, used)
	current = root / stamp
	if (current / "world.json").exists() and "--force" not in argv:
		print(current)
		return 0
	sprites.use_palette(palette.get("shell", []), palette.get("primary"))
	tone = hashlib.sha256(json.dumps(palette, sort_keys=True).encode()).hexdigest()[:10]
	cache = sprites.Cache(root / f"sprites-{sprites.VERSION}-{tone}")
	plates = root / f"plates-{sprites.VERSION}-{tone}"
	plates.mkdir(exist_ok=True)
	world, records = build_world(work, numbers, used)
	if not world.lots:
		world.lots[(0, 0)] = "seat"
	tasks = sorted({plot["task"] for plot in world.plots if plot.get("task")})
	people = sources.ticket_people(tasks) if tasks and used.get("realms") == "tickets" else {}
	add_treasure(world, numbers)
	if world.realm_list:
		tavern = world.prop(lambda: kit.tavern(3), 0, world.realm_list[0]["gate"], kind="deco")
	dress_towns(world)
	if world.realm_list:
		world.spots["tavern"] = (tavern["x"], tavern["z"])
	add_walkers(world, people)
	ground = make_ground(world)
	add_sea_life(world, ground)
	roads, lanes, plazas = road_scene(world, ground)
	ways_on_roads(world, roads, ground)
	for item in world.things:
		item["art"] = item["make"]()
	scene = {"roads": roads, "lanes": lanes, "plazas": plazas, "items": world.things, "palette": palette, "cities": plan_cities(world, ground, lanes),
	         "land_days": [(to_xz(lot), day) for lot, day in land_days(world).items()], "water_days": [(to_xz(item["lot"]), item["day"]) for item in world.water], "river_days": world.river_days}
	building = root / f".{stamp}.{os.getpid()}"
	shutil.rmtree(building, ignore_errors=True)
	building.mkdir(parents=True)
	painted = paint.bake(scene, ground, cache, building, plates)
	write_minis(world, records, cache, building)
	# the running timer's people and things drawn once
	for i in range(8):
		sheet = Image.new("RGBA", (72, 48), (0, 0, 0, 0))
		for frame in (0, 1):
			sheet.paste(iso.person(i * 7 + 1, frame)[0], (frame * 36, 0))
		sheet.save(cache.dir / f"person{i}.png")
	for name, made in (("smoke", iso.smoke(0)), ("blade", iso.sails()), ("scaffold", iso.scaffold(0)), ("boat", iso.boat(0)), ("flag", iso.flag(0)), ("foundation", iso.foundation(0))):
		made[0].save(cache.dir / f"_{name}.png")
	for name, color in (("glow", "#a9e8ff"), ("drop", "#d9f2fb"), ("spark", "#ff9a3c"), ("firefly", "#e8f59a"), ("mote", "#bfe8ff"), ("ember", "#ffd27a")):
		iso.glow(color).save(cache.dir / f"_{name}.png")
	sheet = Image.new("RGBA", (144, 96), (0, 0, 0, 0))
	for frame in (0, 1):
		sheet.paste(iso.golem(frame)[0], (frame * 72, 0))
	sheet.save(cache.dir / "_golem.png")
	data = describe(world, records, ground, stamp, used, painted, cache)
	(building / "world.json").write_text(json.dumps(data, separators=(",", ":")))
	shutil.rmtree(current, ignore_errors=True)
	building.rename(current)
	(root / "current").write_text(str(current))
	keep = {current.name, cache.dir.name, plates.name}
	for old in root.iterdir():
		if old.is_dir() and old.name not in keep and not old.name.startswith("."):
			shutil.rmtree(old, ignore_errors=True)
	wanted = {city["plate"]["file"] for city in data["cities"]}
	for old in plates.iterdir():
		if str(old) not in wanted:
			old.unlink(missing_ok=True)
	print(current)
	return 0


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
