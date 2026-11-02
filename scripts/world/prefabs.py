"""What the layout places, in words: (name, *args). sprites.py draws them, and a
culture is who built it, which sprites.py knows the look of."""

CULTURES = [
	{"name": "nordic", "pattern": "ribbon"},
	{"name": "alpine", "pattern": "organic"},
	{"name": "southern", "pattern": "ring"},
	{"name": "hanse", "pattern": "grid"},
	{"name": "eastern", "pattern": "ring"},
	{"name": "arcane", "pattern": "organic"},
]


def __getattr__(name):
	if name.startswith("__"):
		raise AttributeError(name)
	return lambda *args: (name, *args)
