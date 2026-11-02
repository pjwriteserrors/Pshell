#!/usr/bin/env python3
"""Builds the sound pack "pshell" (assets/sounds/pshell) from nothing but maths.

    scripts/sound_pshell.py        write the pack
    scripts/sound_pshell.py check  only say whether MOMENTS covers Sounds.qml

Glass marbles on felt and wood, in one small room: what is pressed is felt,
what opens springs like the shell's motion curves (it overshoots and settles),
results ring as glass, devices knock as wood, what is wireless glides, what
speaks to you is a bell and what went wrong is dull. Everything tuned stays in
D major pentatonic, so two sounds that follow each other never clash.

SOUNDS says what each file is, MOMENTS which moment of Sounds.qml plays it:
similar moments share a file, different ones do not.
"""

import json
import re
import sys
from pathlib import Path

import numpy as np

from sound_packs import BUILTIN, RATE, ROOT, loudest, write

NOTES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
rng = np.random.default_rng(1984)


def hz(note: str) -> float:
	"""A note by name: "A4", "F#5"."""
	semitone = NOTES[note[0]] + note.count("#") - note.count("b")
	return 440.0 * 2 ** ((semitone + 12 * (int(note[-1]) + 1) - 69) / 12)


def times(seconds: float) -> np.ndarray:
	return np.arange(int(RATE * seconds)) / RATE


def band(x: np.ndarray, low: float, high: float) -> np.ndarray:
	"""Keeps what lies between two frequencies, with soft edges."""
	spectrum = np.fft.rfft(x)
	freq = np.fft.rfftfreq(len(x), 1 / RATE)
	spectrum *= 1 / (1 + (low / np.maximum(freq, 1)) ** 4) / (1 + (freq / high) ** 4)
	return np.fft.irfft(spectrum, len(x))


def modes(f: float, seconds: float, ratios, amps, decays) -> np.ndarray:
	"""Something struck: partials that die away, the high ones first."""
	t = times(seconds)
	out = sum(a * np.sin(2 * np.pi * f * r * t) * np.exp(-t / (seconds * d)) for r, a, d in zip(ratios, amps, decays))
	return out * np.minimum(1, t / 0.001)


def glass(note, seconds=0.32, gain=1.0):
	return gain * modes(hz(note), seconds, (1, 2.76, 5.4), (1, 0.32, 0.1), (0.34, 0.12, 0.05))


def bell(note, seconds=0.85, gain=1.0):
	return gain * modes(hz(note), seconds, (1, 2, 3.01, 4.2, 5.4), (1, 0.42, 0.22, 0.1, 0.05), (0.38, 0.26, 0.15, 0.08, 0.05))


def wood(note, seconds=0.16, gain=1.0):
	return gain * modes(hz(note), seconds, (1, 3.93, 9.2), (1, 0.26, 0.05), (0.3, 0.1, 0.03))


def felt(seconds=0.02, low=500, high=3500, gain=1.0):
	"""A soft finger on felt: a short breath of noise."""
	t = times(seconds)
	return gain * band(rng.standard_normal(len(t)), low, high) * np.exp(-t / (seconds * 0.28))


def glide(start, end, seconds, gain=1.0, decay=0.4):
	"""A plain tone that slides from one frequency to another."""
	t = times(seconds)
	path = start * (end / start) ** (t / seconds)
	return gain * np.sin(2 * np.pi * np.cumsum(path) / RATE) * np.exp(-t / (seconds * decay)) * np.minimum(1, t / 0.002)


def spring(start, end, seconds, gain=1.0):
	"""A tone that shoots past where it is going and settles, like Motion.spatial."""
	t = times(seconds)
	path = end + (start - end) * np.exp(-5 * t / seconds) * np.cos(2 * np.pi * 1.3 * t / seconds)
	return gain * np.sin(2 * np.pi * np.cumsum(path) / RATE) * np.exp(-t / (seconds * 0.36)) * np.minimum(1, t / 0.004)


def air(seconds, low, high, peak=0.4, gain=1.0):
	"""A breath that swells and fades: what moves through the room."""
	t = times(seconds) / seconds
	shape = np.where(t < peak, t / peak, (1 - t) / (1 - peak)) ** 2
	return gain * band(rng.standard_normal(len(t)), low, high) * shape


def mix(*parts) -> np.ndarray:
	"""Plays parts together; a part may be (milliseconds, sound)."""
	placed = [(int(RATE * part[0] / 1000), part[1]) if isinstance(part, tuple) else (0, part) for part in parts]
	out = np.zeros(max(at + len(sound) for at, sound in placed))
	for at, sound in placed:
		out[at:at + len(sound)] += sound / max(np.abs(sound).max(), 1e-9) * np.abs(sound).max()
	return out


def bounce(notes, first=0.075, sound=glass, seconds=0.2):
	"""The marble: each knock quieter and sooner than the one before."""
	parts = []
	at = 0.0
	gap = first * 1000
	for index, note in enumerate(notes):
		parts.append((at, sound(note, seconds, 0.72 ** index)))
		at += gap
		gap *= 0.72
	return mix(*parts)


t_room = times(0.22)
ROOM = band(rng.standard_normal(len(t_room)), 300, 5200) * np.exp(-t_room / 0.05)
ROOM /= np.sqrt(np.sum(ROOM ** 2))


def room(x: np.ndarray, wet: float) -> np.ndarray:
	"""The one small room all of them are in."""
	size = len(x) + len(ROOM)
	tail = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ROOM, size), size)
	dry = np.zeros(size)
	dry[:len(x)] = x
	return dry + wet * tail


# file: (the sound, how much room, loudest 30 ms in dBFS)
SOUNDS = {
	# ── pressed: felt, short ───────────────────────────────────────────────
	"press": lambda: (mix(felt(0.018, 700, 3800, 0.6), glide(620, 520, 0.04, 0.8, 0.6)), 0.06, -29),
	"press-small": lambda: (mix(felt(0.012, 1200, 5000, 0.35), glide(1050, 950, 0.03, 0.8, 0.6)), 0.05, -32),
	"press-row": lambda: (mix(felt(0.016, 400, 2200, 0.5), glide(410, 370, 0.04, 0.9, 0.6)), 0.05, -31),
	"press-confirm": lambda: (mix(felt(0.016, 700, 3800), glide(620, 520, 0.03, 0.6), (14, glass("D6", 0.12, 0.8))), 0.08, -27),
	"press-danger": lambda: (mix(felt(0.02, 300, 1800), glide(260, 190, 0.07, 1.0)), 0.06, -27),
	"choice": lambda: (mix(felt(0.01, 1000, 4500, 0.5), wood("A5", 0.06)), 0.05, -30),
	"step": lambda: (mix(wood("E5", 0.05, 0.7), (42, wood("A5", 0.06))), 0.05, -30),
	"switch-on": lambda: (mix(felt(0.012, 900, 4200, 0.6), glide(760, 1180, 0.055, 0.9, 0.6)), 0.05, -29),
	"switch-off": lambda: (mix(felt(0.012, 600, 3000, 0.6), glide(960, 620, 0.055, 0.9, 0.6)), 0.05, -29),
	"level": lambda: (glide(880, 700, 0.075, 1.0), 0.05, -26),
	# ── surfaces: a spring and a breath ────────────────────────────────────
	"panel-open": lambda: (mix(spring(420, 640, 0.15), air(0.12, 900, 4200, 0.35, 0.12)), 0.1, -28),
	"panel-close": lambda: (mix(spring(600, 390, 0.12), air(0.09, 700, 3000, 0.2, 0.09)), 0.1, -29),
	"launcher-open": lambda: (mix(spring(560, 1040, 0.15), (45, glass("A6", 0.1, 0.1)), air(0.13, 1800, 7000, 0.3, 0.14)), 0.12, -28),
	"launcher-close": lambda: (mix(spring(900, 520, 0.11), air(0.08, 1200, 5000, 0.2, 0.1)), 0.1, -29),
	"dialog-open": lambda: (mix(spring(300, 470, 0.17), (70, glass("D6", 0.2, 0.2))), 0.14, -27),
	"dialog-close": lambda: (mix(spring(460, 280, 0.14)), 0.12, -28),
	"slide": lambda: (mix(air(0.12, 500, 2600, 0.45, 0.5), (20, glide(330, 440, 0.08, 0.4, 0.5))), 0.1, -31),
	"glide-away": lambda: (mix(air(0.28, 1200, 5000, 0.3, 0.35), glide(520, 900, 0.22, 0.8, 0.5)), 0.2, -27),
	"glide-home": lambda: (mix(air(0.24, 800, 3200, 0.6, 0.35), glide(900, 520, 0.22, 0.8, 0.6)), 0.2, -27),
	# ── results: glass ─────────────────────────────────────────────────────
	"copied": lambda: (mix(glass("E6", 0.14), (48, glass("A6", 0.16, 0.55))), 0.12, -25),
	"saved": lambda: (mix(glass("A6", 0.12, 0.7), (55, glass("D6", 0.24))), 0.14, -25),
	"color": lambda: (mix(glide(1100, 2400, 0.07, 1.0, 0.7), (58, glass("B6", 0.13, 0.5))), 0.12, -26),
	"pinned": lambda: (mix(felt(0.02, 300, 1600, 0.8), wood("B4", 0.14), (9, glass("F#6", 0.08, 0.25))), 0.12, -25),
	"filed": lambda: (mix(wood("D5", 0.1, 0.8), (62, wood("A5", 0.12))), 0.12, -25),
	"trashed": lambda: (mix(air(0.16, 700, 3600, 0.2, 0.5), glide(340, 170, 0.14, 0.9), (95, wood("D3", 0.09, 0.6))), 0.12, -26),
	"shutter": lambda: (mix(felt(0.016, 1400, 6500, 0.5), glide(420, 300, 0.04, 0.8, 0.6), (62, felt(0.02, 900, 4800, 0.4)), (62, glide(300, 220, 0.05, 0.75, 0.6))), 0.14, -24),
	"rec-on": lambda: (mix(glass("A5", 0.18), (105, glass("E6", 0.3))), 0.14, -24),
	"rec-off": lambda: (mix(glass("E6", 0.18), (105, glass("A5", 0.34))), 0.14, -24),
	"hush": lambda: (band(mix(bell("B5", 0.34), (120, bell("F#5", 0.46, 0.8))), 200, 2200), 0.16, -25),
	"unhush": lambda: (mix(bell("F#5", 0.26, 0.8), (110, bell("B5", 0.42))), 0.16, -24),
	"done": lambda: (mix(glass("D6", 0.2, 0.85), (92, glass("A6", 0.36))), 0.16, -24),
	"sent": lambda: (mix(air(0.18, 1500, 6000, 0.35, 0.28), glide(700, 1450, 0.14, 0.7, 0.6), (128, glass("A6", 0.26, 0.8))), 0.16, -24),
	"arrived": lambda: (mix(bounce(("A5", "D6", "D6", "D6"), 0.1, glass, 0.26)), 0.16, -24),
	"launch": lambda: (mix(spring(280, 620, 0.26, 0.8), (85, glass("D6", 0.3, 0.45)), (150, glass("A6", 0.38, 0.5))), 0.2, -24),
	"list-done": lambda: (mix(glass("D6", 0.22, 0.75), (85, glass("F#6", 0.22, 0.8)), (170, glass("A6", 0.24, 0.85)), (255, bell("D7", 0.55, 0.65))), 0.2, -23),
	# ── devices: wood, wireless glides ─────────────────────────────────────
	"plug-in": lambda: (mix(wood("A4", 0.14), (88, wood("D5", 0.18))), 0.12, -23),
	"plug-out": lambda: (mix(wood("D5", 0.14), (88, wood("A4", 0.18))), 0.12, -23),
	"drive-in": lambda: (mix(wood("A4", 0.14), (88, wood("D5", 0.14)), (176, glass("A6", 0.24, 0.5))), 0.14, -24),
	"drive-out": lambda: (mix(wood("A5", 0.08), (70, wood("E5", 0.08, 0.85)), (140, wood("A4", 0.13, 0.7))), 0.12, -24),
	"wireless-on": lambda: (mix(glide(620, 980, 0.11, 0.7, 0.7), (92, glass("B6", 0.22, 0.65))), 0.2, -24),
	"wireless-off": lambda: (mix(glass("B6", 0.14, 0.5), (64, glide(980, 520, 0.16, 0.8, 0.6))), 0.2, -24),
	"online": lambda: (mix(glide(740, 990, 0.08, 0.8, 0.8)), 0.2, -28),
	"offline": lambda: (mix(glide(990, 620, 0.1, 0.8, 0.7)), 0.2, -28),
	"screen-on": lambda: (mix(air(0.3, 500, 3000, 0.7, 0.2), (130, bell("D5", 0.38, 0.75)), (130, bell("A5", 0.42, 0.55))), 0.2, -24),
	"screen-off": lambda: (mix(bell("A5", 0.26, 0.5), bell("D5", 0.3, 0.7), (30, air(0.26, 400, 2000, 0.18, 0.2))), 0.2, -24),
	"power-in": lambda: (mix(wood("D3", 0.12, 0.9), (54, spring(180, 370, 0.22, 0.75))), 0.16, -23),
	"power-out": lambda: (mix(spring(370, 170, 0.2, 0.75), (120, wood("D3", 0.1, 0.55))), 0.16, -24),
	# ── speaking up: bells; what went wrong: dull ──────────────────────────
	"notify": lambda: (mix(bell("A5", 0.42, 0.85), (155, bell("D6", 0.7))), 0.2, -21),
	"notify-urgent": lambda: (mix(bell("D6", 0.3), (135, bell("A6", 0.3)), (300, bell("D6", 0.3)), (435, bell("A6", 0.55))), 0.2, -20),
	"reminder": lambda: (mix(wood("F#5", 0.28, 0.85), (190, wood("B5", 0.42))), 0.2, -23),
	"question": lambda: (mix(glass("B5", 0.18, 0.8), (118, glass("E6", 0.3))), 0.14, -22),
	"warn": lambda: (mix(wood("F#4", 0.17), (150, wood("D4", 0.2)), (420, wood("F#4", 0.17, 0.8)), (570, wood("D4", 0.22, 0.8))), 0.12, -22),
	"error": lambda: (mix(wood("A3", 0.2), wood("Bb3", 0.2, 0.75), (135, wood("E3", 0.28)), (135, wood("F3", 0.28, 0.7))), 0.1, -22),
	"denied": lambda: (mix(glide(300, 250, 0.075, 1.0), (88, glide(250, 195, 0.11, 1.0))), 0.08, -23),
	# ── coming and going ───────────────────────────────────────────────────
	"lock": lambda: (mix(felt(0.012, 1400, 5500, 0.6), wood("D4", 0.09), (70, felt(0.014, 500, 2200, 0.8)), (70, wood("A3", 0.13))), 0.12, -24),
	"unlock": lambda: (mix(felt(0.014, 500, 2200, 0.7), wood("A3", 0.09), (66, felt(0.012, 1400, 5500, 0.6)), (66, wood("D4", 0.09)), (130, glass("A6", 0.26, 0.28))), 0.14, -24),
	"sleep": lambda: (band(mix(bell("A5", 0.42, 0.7), (190, bell("D5", 0.62))), 150, 1500), 0.2, -24),
	"startup": lambda: (mix(
		air(1.2, 300, 1800, 0.45, 0.06),
		spring(146.83, 146.83, 1.5, 0.28), (0, spring(220, 220, 1.5, 0.2)),
		(110, bell("D5", 0.8, 0.55)), (250, bell("A5", 0.8, 0.6)), (390, bell("B5", 0.8, 0.55)),
		(530, bell("F#6", 1.1, 0.65))), 0.25, -22),
}

# moment of Sounds.qml → file
MOMENTS = {
	"click": "press", "iconTap": "press-small", "row": "press-row", "confirm": "press-confirm", "danger": "press-danger",
	"toggleOn": "switch-on", "toggleOff": "switch-off", "select": "choice", "navigate": "step",
	"open": "panel-open", "close": "panel-close", "launcherOpen": "launcher-open", "launcherClose": "launcher-close",
	"dialogOpen": "dialog-open", "dialogClose": "dialog-close", "volume": "level", "workspace": "slide",
	"captured": "shutter", "copied": "copied", "saved": "saved", "colorPicked": "color", "pinned": "pinned",
	"filed": "filed", "trashed": "trashed",
	"recordingStarted": "rec-on", "recordingStopped": "rec-off", "dndOn": "hush", "dndOff": "unhush", "listDone": "list-done",

	"notification": "notify", "notificationCritical": "notify-urgent",
	"usbIn": "plug-in", "usbOut": "plug-out", "driveMounted": "drive-in", "driveUnmounted": "drive-out",
	"displayIn": "screen-on", "displayOut": "screen-off",
	"bluetoothIn": "wireless-on", "bluetoothOut": "wireless-off", "phoneIn": "wireless-on", "phoneOut": "wireless-off",
	"mouseAway": "glide-away", "mouseHome": "glide-home",
	"chargerIn": "power-in", "chargerOut": "power-out", "batteryLow": "warn",
	"networkUp": "online", "networkDown": "offline",
	"error": "error", "denied": "denied", "attention": "question",
	"taskDone": "done", "sent": "sent", "received": "arrived", "download": "arrived", "gameStart": "launch",
	"reminder": "reminder", "locked": "lock", "unlocked": "unlock", "suspend": "sleep", "startup": "startup",
}


def uncovered() -> list[str]:
	"""What does not fit together: a moment without a file, a file nothing plays."""
	table = (ROOT / "core" / "services" / "Sounds.qml").read_text()
	ids = set(re.findall(r'\{ id: "(\w+)", kind:', table))
	problems = [f"moment without a file: {moment}" for moment in sorted(ids - set(MOMENTS))]
	problems += [f"not a moment: {moment}" for moment in sorted(set(MOMENTS) - ids)]
	problems += [f"no such file: {name}" for name in sorted(set(MOMENTS.values()) - set(SOUNDS))]
	problems += [f"nothing plays: {name}" for name in sorted(set(SOUNDS) - set(MOMENTS.values()))]
	return problems


def finish(x: np.ndarray, wet: float, target: float) -> np.ndarray:
	x = room(x, wet)
	level = np.abs(x)
	x = x[:np.where(level > level.max() * 10 ** (-48 / 20))[0][-1] + 1]
	x *= 10 ** ((target - loudest(x)) / 20)
	# a transient stays near the rest of the sound, so nothing snaps
	x *= min(1.0, 10 ** ((target + 12) / 20) / np.abs(x).max())
	fade_in = min(len(x), int(RATE * 0.001))
	x[:fade_in] *= np.linspace(0, 1, fade_in)
	fade_out = min(len(x), max(int(RATE * 0.012), len(x) // 4))
	x[-fade_out:] *= np.linspace(1, 0, fade_out) ** 2
	return x


def main() -> int:
	problems = uncovered()
	for problem in problems:
		print(problem, file=sys.stderr)
	if problems:
		return 1
	if sys.argv[1:] == ["check"]:
		print(f"{len(MOMENTS)} moments, {len(SOUNDS)} files")
		return 0
	target = BUILTIN / "pshell"
	target.mkdir(parents=True, exist_ok=True)
	for old in target.glob("*.wav"):
		old.unlink()
	for name, make in SOUNDS.items():
		sound, wet, level = make()
		write(target / f"{name}.wav", finish(sound, wet, level))
	(target / "pack.json").write_text(json.dumps({
		"id": "pshell",
		"name": "Pshell",
		"author": "Pshell",
		"url": "",
		"license": "made for the shell",
		"description": "Glass marbles on felt and wood",
		"builtin": True,
		"sounds": sorted(SOUNDS),
		"moments": MOMENTS,
	}, indent="\t") + "\n")
	print(f"pshell: {len(SOUNDS)} files for {len(MOMENTS)} moments in {target}")
	return 0


if __name__ == "__main__":
	sys.exit(main())
