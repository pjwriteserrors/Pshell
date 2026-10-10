#!/usr/bin/env python3
"""The sound packs of the shell (core/services/Sounds.qml).

    scripts/sound_packs.py install <zip>   build a pack from its download
    scripts/sound_packs.py list            installed packs, and known ones whose zip is in ~/Downloads
    scripts/sound_packs.py remove <id>     take an installed pack away again

A pack is a folder of 48 kHz mono 16-bit WAV files, one for each sound of the
shell (ROLES), and a pack.json that says what it is. A pack whose licence
lets it be passed on lives in the repository (assets/sounds/<id>, `builtin`);
any other is built on each machine from the zip it came in, into
~/.local/share/pshell/sounds/<id>, and never enters the repository.

Each sound is one of the pack's, or a few of them played after each other –
a cut out of a longer one, raised or lowered in pitch (a switch that goes on
sounds a little higher than one that goes off). Everything is cut to what can
be heard, softened (a high-pass takes the thump, a low-pass the edge), brought
to the loudness of its kind (ROLES) and faded out, so every pack is as quiet
as the others.
"""

import json
import os
import shutil
import subprocess
import sys
import wave
import zipfile
from pathlib import Path

import numpy as np

RATE = 48000
ROOT = Path(__file__).resolve().parent.parent
BUILTIN = ROOT / "assets" / "sounds"
DATA = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "pshell" / "sounds"
DOWNLOADS = Path.home() / "Downloads"

# every sound of the shell, and how loud it is: the loudest 30 ms in dBFS
ROLES = {
	"tick": -27, "tick-up": -27, "tick-down": -27, "tap": -31,
	"pop-up": -25, "pop-down": -25, "pop": -26,
	"pluck": -24, "pluck-low": -24, "chime-up": -23, "chime-down": -23,
	"notify": -21, "notify-urgent": -20,
	"connect": -22, "disconnect": -22, "ready": -24, "eject": -24,
	"display-on": -22, "display-off": -22,
	"error": -22, "warn": -22, "reminder": -22, "startup": -22,
	"lock": -24, "unlock": -24,
}


def P(name, at=0, pitch=1.0, cut=None):
	"""A part of a sound: a file of the pack, `at` ms in, in another `pitch`
	(a factor), only from `cut` = (start, end) seconds of it."""
	return {"name": name, "at": at, "pitch": pitch, "cut": cut}


# a sound: (parts, low-pass Hz, fade-out ms)
PACKS = {
	"gibson": {
		"name": "Universal UI",
		"author": "Nathan Gibson",
		"url": "https://nathangibson.myportfolio.com",
		"license": "CC BY 4.0",
		"description": "Soft sine pops and ticks, marimba for devices",
		"builtin": True,
		"sounds": {
			"tick": ([P("Modern10")], 6000, 40),
			"tick-up": ([P("Modern12")], 6000, 40),
			"tick-down": ([P("Modern11")], 6000, 40),
			"tap": ([P("Abstract1")], 5000, 40),
			"pop-up": ([P("Modern4")], 5000, 40),
			"pop-down": ([P("Modern3")], 5000, 40),
			"pop": ([P("Modern2")], 5000, 40),
			"pluck": ([P("Coffee2")], 6000, 40),
			"pluck-low": ([P("Coffee1")], 6000, 40),
			"chime-up": ([P("Modern7")], 5000, 40),
			"chime-down": ([P("Modern6")], 5000, 40),
			"notify": ([P("Modern15")], 5000, 40),
			"notify-urgent": ([P("Modern16")], 5000, 40),
			"connect": ([P("African3"), P("African2", 110)], 4500, 40),
			"disconnect": ([P("African2"), P("African3", 110)], 4500, 40),
			"ready": ([P("Modern13")], 6000, 40),
			"eject": ([P("Modern12"), P("Modern10", 75), P("Modern11", 150)], 6000, 40),
			"display-on": ([P("Modern8")], 4500, 40),
			"display-off": ([P("Modern14")], 4500, 40),
			"error": ([P("Retro11")], 1800, 40),
			"warn": ([P("Retro12")], 2000, 40),
			"reminder": ([P("African1")], 4500, 40),
			"startup": ([P("Modern9")], 4500, 40),
			"lock": ([P("Wood Block2")], 3000, 40),
			"unlock": ([P("Wood Block1")], 3000, 40),
		},
	},
	"cosy": {
		"name": "Cosy",
		"author": "SampleKingdom",
		"url": "https://sample-kingdom.itch.io/cosy-user-interface-sfx",
		"license": "free, not to be shared",
		"description": "Wooden pops, little bells and murmuring voices",
		"builtin": False,
		"sounds": {
			"tick": ([P("SFX_Button_004")], 5000, 30),
			"tick-up": ([P("SFX_Button_004", pitch=1.12)], 5000, 30),
			"tick-down": ([P("SFX_Button_004", pitch=0.89)], 5000, 30),
			"tap": ([P("SFX_Item_Select_001")], 5000, 15),
			"pop-up": ([P("SFX_Button_018", pitch=1.12)], 5000, 40),
			"pop-down": ([P("SFX_Button_018", pitch=0.84)], 5000, 40),
			"pop": ([P("SFX_Button_018")], 5000, 40),
			"pluck": ([P("SFX_Coin_Particle_004")], 7000, 40),
			"pluck-low": ([P("SFX_Coin_Particle_004", pitch=0.75)], 6000, 40),
			"chime-up": ([P("SFX_Notification_008")], 6000, 60),
			"chime-down": ([P("SFX_Notification_008", pitch=0.75)], 6000, 60),
			"notify": ([P("SFX_Notification_008")], 6000, 60),
			"notify-urgent": ([P("SFX_Notification_008"), P("SFX_Notification_008", 280, 1.12)], 6000, 60),
			"connect": ([P("SFX_Button_018"), P("SFX_Button_018", 95, 1.26)], 5000, 40),
			"disconnect": ([P("SFX_Button_018", pitch=1.26), P("SFX_Button_018", 95)], 5000, 40),
			"ready": ([P("SFX_Notification_008", pitch=1.26)], 6000, 60),
			"eject": ([P("SFX_Button_004", pitch=1.26), P("SFX_Button_004", 75), P("SFX_Button_004", 150, 0.84)], 5000, 30),
			"display-on": ([P("SFX_Positive_Feedback_008", cut=(0, 1.0))], 5000, 300),
			"display-off": ([P("SFX_Positive_Feedback_008", pitch=0.8, cut=(0, 0.8))], 5000, 300),
			"error": ([P("SFX_Dialogue_VO_Frank_004")], 5000, 30),
			"warn": ([P("SFX_Dialogue_VO_Agathe_003")], 5000, 30),
			"reminder": ([P("SFX_Dialogue_VO_Jacob_002"), P("SFX_Dialogue_VO_Jacob_002", 150, 1.26)], 5000, 30),
			"startup": ([P("SFX_Positive_Feedback_008")], 5000, 200),
			"lock": ([P("SFX_Button_018", pitch=0.7)], 4000, 40),
			"unlock": ([P("SFX_Button_018"), P("SFX_Item_Select_001", 70)], 5000, 40),
		},
	},
	"cozy": {
		"name": "Cozy UI",
		"author": "Antahonist",
		"url": "https://antahonist.itch.io/103-cozy-ui-sound-effects",
		"license": "free, not to be shared",
		"description": "Wood clicks, warm pops and bells",
		"builtin": False,
		"sounds": {
			"tick": ([P("Button_Click_Wood_01")], 6000, 30),
			"tick-up": ([P("Button_Click_Wood_01", pitch=1.12)], 6000, 30),
			"tick-down": ([P("Button_Click_Wood_01", pitch=0.89)], 6000, 30),
			"tap": ([P("Button_Click_Wood_01", pitch=1.3)], 5000, 30),
			"pop-up": ([P("Item_Pickup_01", pitch=1.12, cut=(0, 0.25))], 5000, 60),
			"pop-down": ([P("Item_Pickup_01", pitch=0.89, cut=(0, 0.25))], 5000, 60),
			"pop": ([P("Item_Pickup_01", cut=(0, 0.22))], 5000, 60),
			"pluck": ([P("Item_Pickup_01", pitch=1.5, cut=(0, 0.25))], 6000, 60),
			"pluck-low": ([P("Button_Click_Wood_01"), P("Button_Click_Wood_01", 60, 0.8)], 6000, 30),
			"chime-up": ([P("Confirm_01", cut=(0, 1.41))], 6000, 250),
			"chime-down": ([P("Confirm_01", cut=(0.93, 1.41)), P("Confirm_01", 180, cut=(0.45, 0.93)), P("Confirm_01", 360, cut=(0, 0.45))], 6000, 200),
			"notify": ([P("Notification", cut=(0, 1.05))], 6000, 350),
			"notify-urgent": ([P("Notification", cut=(0, 2.0))], 6000, 450),
			"connect": ([P("Item_Pickup_01", cut=(0, 0.22)), P("Item_Pickup_01", 100, 1.26, (0, 0.3))], 5000, 80),
			"disconnect": ([P("Item_Pickup_01", pitch=1.26, cut=(0, 0.22)), P("Item_Pickup_01", 100, 1.0, (0, 0.3))], 5000, 80),
			"ready": ([P("Confirm_01", cut=(0.93, 1.41))], 6000, 150),
			"eject": ([P("Button_Click_Wood_01", pitch=1.26), P("Button_Click_Wood_01", 75), P("Button_Click_Wood_01", 150, 0.84)], 6000, 30),
			"display-on": ([P("Level_Up", cut=(0, 1.5))], 6000, 400),
			"display-off": ([P("Item_Pickup_01", pitch=0.75, cut=(0, 0.3)), P("Item_Pickup_01", 120, 0.6, (0, 0.3))], 5000, 80),
			"error": ([P("Item_Pickup_01", pitch=0.6, cut=(0, 0.2)), P("Item_Pickup_01", 120, 0.6, (0, 0.2))], 3000, 60),
			"warn": ([P("Item_Pickup_01", pitch=0.7, cut=(0, 0.25))], 3500, 60),
			"reminder": ([P("Notification", cut=(0, 0.5))], 6000, 150),
			"startup": ([P("Level_Up", cut=(0, 2.2))], 6000, 500),
			"lock": ([P("Button_Click_Wood_01", pitch=0.7)], 4000, 30),
			"unlock": ([P("Button_Click_Wood_01", pitch=0.9), P("Button_Click_Wood_01", 70, 1.2)], 6000, 30),
		},
	},
}


def sources(pack: dict) -> set[str]:
	return {part["name"] for parts, _, _ in pack["sounds"].values() for part in parts}


def members(archive: zipfile.ZipFile) -> dict[str, str]:
	"""The pack's WAV files by name, wherever in the zip they are."""
	found = {}
	for member in archive.namelist():
		if member.startswith("__MACOSX") or not member.lower().endswith(".wav"):
			continue
		found.setdefault(Path(member).stem, member)
	return found


def recipe(path: Path) -> str | None:
	"""Which known pack a zip is."""
	try:
		with zipfile.ZipFile(path) as archive:
			names = set(members(archive))
	except (OSError, zipfile.BadZipFile):
		return None
	return next((pack_id for pack_id, pack in PACKS.items() if sources(pack) <= names), None)


def decode(data: bytes, part: dict, lowpass: int) -> np.ndarray:
	chain = [f"aresample={RATE}"]
	if part["cut"]:
		chain.append(f"atrim={part['cut'][0]}:{part['cut'][1]},asetpts=PTS-STARTPTS")
	if part["pitch"] != 1.0:
		chain.append(f"asetrate={round(RATE * part['pitch'])},aresample={RATE}")
	chain.append(f"highpass=f=140,lowpass=f={lowpass}:p=2")
	raw = subprocess.run(
		["ffmpeg", "-v", "error", "-i", "pipe:0", "-ac", "1", "-af", ",".join(chain), "-ar", str(RATE), "-f", "f32le", "pipe:1"],
		input=data, capture_output=True, check=True).stdout
	return np.frombuffer(raw, np.float32).astype(np.float64)


def trim(x: np.ndarray) -> np.ndarray:
	"""Cuts the silence around a sound, keeping a breath before it."""
	level = np.abs(x)
	loud = np.where(level > level.max() * 10 ** (-48 / 20))[0]
	start = max(0, loud[0] - int(RATE * 0.002))
	end = min(len(x), loud[-1] + int(RATE * 0.02))
	return x[start:end]


def loudest(x: np.ndarray) -> float:
	window = int(RATE * 0.03)
	power = np.convolve(x * x, np.ones(window) / window, mode="valid")
	return 10 * np.log10(power.max() + 1e-12)


def build(archive: zipfile.ZipFile, files: dict, parts, lowpass: int, fade: int, target: float) -> np.ndarray:
	pieces = [(trim(decode(archive.read(files[part["name"]]), part, lowpass)), int(RATE * part["at"] / 1000)) for part in parts]
	out = np.zeros(max(len(piece) + at for piece, at in pieces))
	for piece, at in pieces:
		out[at:at + len(piece)] += piece
	out = trim(out)
	out *= 10 ** ((target - loudest(out)) / 20)
	# never louder than -3 dBFS, whatever the target says
	out *= min(1.0, 10 ** (-3 / 20) / np.abs(out).max())
	# a soft start (no click) and a tail that fades instead of stopping
	fade_in = min(len(out), int(RATE * 0.0015))
	out[:fade_in] *= np.linspace(0, 1, fade_in)
	fade_out = min(len(out), int(RATE * fade / 1000))
	out[-fade_out:] *= np.linspace(1, 0, fade_out) ** 2
	return out


def write(path: Path, x: np.ndarray) -> None:
	pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
	with wave.open(str(path), "wb") as out:
		out.setnchannels(1)
		out.setsampwidth(2)
		out.setframerate(RATE)
		out.writeframes(pcm.tobytes())


def info(pack_id: str) -> dict:
	pack = PACKS[pack_id]
	return {key: pack[key] for key in ("name", "author", "url", "license", "description", "builtin")} | {"id": pack_id}


def install(path: Path) -> int:
	pack_id = recipe(path)
	if pack_id is None:
		print(f"{path}: not a sound pack this script knows ({', '.join(PACKS)})", file=sys.stderr)
		return 1
	pack = PACKS[pack_id]
	target = (BUILTIN if pack["builtin"] else DATA) / pack_id
	work = target.with_name(f".{pack_id}.new")
	shutil.rmtree(work, ignore_errors=True)
	work.mkdir(parents=True)
	with zipfile.ZipFile(path) as archive:
		files = members(archive)
		for role, (parts, lowpass, fade) in pack["sounds"].items():
			write(work / f"{role}.wav", build(archive, files, parts, lowpass, fade, ROLES[role]))
	(work / "pack.json").write_text(json.dumps(info(pack_id) | {"sounds": sorted(pack["sounds"])}, indent="\t") + "\n")
	# a README of the pack in the repository stays where it is
	if (target / "README.md").exists():
		shutil.copy(target / "README.md", work / "README.md")
	shutil.rmtree(target, ignore_errors=True)
	work.rename(target)
	print(f"{pack_id}: {len(pack['sounds'])} sounds in {target}")
	return 0


def installed() -> list[dict]:
	packs = []
	for base in (BUILTIN, DATA):
		for meta in sorted(base.glob("*/pack.json")):
			try:
				packs.append(json.loads(meta.read_text()) | {"dir": str(meta.parent)})
			except (OSError, ValueError):
				continue
	return packs


def listing() -> dict:
	have = {pack["id"] for pack in installed()}
	zips = {}
	for path in sorted(DOWNLOADS.glob("*.zip")) if DOWNLOADS.is_dir() else []:
		if path.stat().st_size < 512 * 1024 * 1024:
			pack_id = recipe(path)
			if pack_id and pack_id not in have:
				zips.setdefault(pack_id, str(path))
	available = [info(pack_id) | {"zip": zips.get(pack_id, "")} for pack_id in PACKS if pack_id not in have]
	return {"packs": installed(), "available": available}


def remove(pack_id: str) -> int:
	target = DATA / pack_id
	if not (target / "pack.json").exists():
		print(f"{pack_id}: no pack of that name in {DATA}", file=sys.stderr)
		return 1
	shutil.rmtree(target)
	return 0


def main() -> int:
	args = sys.argv[1:]
	if args[:1] == ["install"] and len(args) == 2:
		return install(Path(args[1]).expanduser())
	if args == ["list"]:
		print(json.dumps(listing()))
		return 0
	if args[:1] == ["remove"] and len(args) == 2:
		return remove(args[1])
	print(__doc__.strip(), file=sys.stderr)
	return 2


if __name__ == "__main__":
	sys.exit(main())
