#!/usr/bin/env python3
"""Builds assets/sounds/ from Nathan Gibson's Universal UI Soundpack (CC BY 4.0).

    scripts/build_sounds.py ~/Downloads/"UI Soundpack.zip"

Every sound of the shell is one of the pack's, or two or three of them
played after each other; each is cut to what can be heard, softened
(a low-pass takes the edge off the clicks, a high-pass the thump), brought
to the same loudness as the others of its kind and written as 48 kHz mono
16-bit WAV, which is what QtMultimedia's SoundEffect plays without delay.
Which moment plays which file is decided in core/services/Sounds.qml.
"""

import subprocess
import sys
import wave
import zipfile
from pathlib import Path

import numpy as np

RATE = 48000
OUT = Path(__file__).resolve().parent.parent / "assets" / "sounds"

# name: (parts [(source, offset ms)], low-pass Hz, loudness dBFS)
# loudness is the loudest 30 ms of the sound, so short and long ones match
SOUNDS = {
	# buttons
	"tick": ([("Modern10", 0)], 6000, -27),
	"tick-up": ([("Modern12", 0)], 6000, -27),
	"tick-down": ([("Modern11", 0)], 6000, -27),
	"tap": ([("Abstract1", 0)], 5000, -31),
	"pop-up": ([("Modern4", 0)], 5000, -25),
	"pop-down": ([("Modern3", 0)], 5000, -25),
	"pop": ([("Modern2", 0)], 5000, -26),
	"pluck": ([("Coffee2", 0)], 6000, -24),
	"pluck-low": ([("Coffee1", 0)], 6000, -24),
	"chime-up": ([("Modern7", 0)], 5000, -23),
	"chime-down": ([("Modern6", 0)], 5000, -23),
	# the system
	"notify": ([("Modern15", 0)], 5000, -21),
	"notify-urgent": ([("Modern16", 0)], 5000, -20),
	"connect": ([("African3", 0), ("African2", 110)], 4500, -22),
	"disconnect": ([("African2", 0), ("African3", 110)], 4500, -22),
	"ready": ([("Modern13", 0)], 6000, -24),
	"eject": ([("Modern12", 0), ("Modern10", 75), ("Modern11", 150)], 6000, -24),
	"display-on": ([("Modern8", 0)], 4500, -22),
	"display-off": ([("Modern14", 0)], 4500, -22),
	"error": ([("Retro11", 0)], 1800, -22),
	"warn": ([("Retro12", 0)], 2000, -22),
	"reminder": ([("African1", 0)], 4500, -22),
	"startup": ([("Modern9", 0)], 4500, -22),
	"lock": ([("Wood Block2", 0)], 3000, -24),
	"unlock": ([("Wood Block1", 0)], 3000, -24),
}


def decode(pack: zipfile.ZipFile, name: str, lowpass: int) -> np.ndarray:
	data = pack.read(f"UI Soundpack/WAV/{name}.wav")
	raw = subprocess.run(
		["ffmpeg", "-v", "error", "-i", "pipe:0", "-ac", "1", "-ar", str(RATE),
		 "-af", f"highpass=f=140,lowpass=f={lowpass}:p=2", "-f", "f32le", "pipe:1"],
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


def build(pack: zipfile.ZipFile, parts, lowpass: int, target: float) -> np.ndarray:
	pieces = [(trim(decode(pack, name, lowpass)), int(RATE * offset / 1000)) for name, offset in parts]
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
	fade_out = min(len(out), int(RATE * 0.04))
	out[-fade_out:] *= np.linspace(1, 0, fade_out) ** 2
	return out


def write(path: Path, x: np.ndarray) -> None:
	pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
	with wave.open(str(path), "wb") as out:
		out.setnchannels(1)
		out.setsampwidth(2)
		out.setframerate(RATE)
		out.writeframes(pcm.tobytes())


def main() -> int:
	if len(sys.argv) != 2:
		print(__doc__.strip(), file=sys.stderr)
		return 2
	OUT.mkdir(parents=True, exist_ok=True)
	with zipfile.ZipFile(sys.argv[1]) as pack:
		for name, (parts, lowpass, target) in SOUNDS.items():
			sound = build(pack, parts, lowpass, target)
			write(OUT / f"{name}.wav", sound)
			print(f"{name:14} {len(sound) / RATE:5.2f} s  {' + '.join(part for part, _ in parts)}")
	return 0


if __name__ == "__main__":
	sys.exit(main())
