"""Listening to an episode: one pass over its sound gives where it is silent, how
loud it is where, and (compared with another episode of the series) its intro and
outro. No state in here; needs ffmpeg and numpy."""
import json
import os
import subprocess
import tempfile

import numpy as np

RATE = 10  # loudness values a second
FINGERPRINT_RATE = 8.03
SAMPLE = 8000


def listen(url, on_part=None, limit=0):
    """The loudness of a stream, RATE values a second, in dB (int8). on_part is
    told what is known every few minutes of sound."""
    command = ["ffmpeg", "-v", "error", "-nostdin", "-i", url, "-ac", "1", "-ar", str(SAMPLE)]
    if limit:
        command += ["-t", str(limit)]
    process = subprocess.Popen([*command, "-f", "s16le", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    step = SAMPLE // RATE
    out, rest, told = [], np.zeros(0, dtype=np.int16), 0
    try:
        while True:
            chunk = process.stdout.read(SAMPLE * 2 * 30)
            if not chunk:
                break
            rest = np.concatenate([rest, np.frombuffer(chunk[:len(chunk) // 2 * 2], dtype=np.int16)])
            whole = len(rest) // step
            if whole:
                frames = rest[:whole * step].reshape(-1, step).astype(np.float64)
                rms = np.sqrt((frames ** 2).mean(axis=1)) + 1
                out.append(np.clip(20 * np.log10(rms / 32768), -100, 0).astype(np.int8))
                rest = rest[whole * step:]
            size = sum(len(part) for part in out)
            if on_part and size - told >= RATE * 300:
                told = size
                on_part(np.concatenate(out))
    finally:
        process.kill()
        process.wait()
    return np.concatenate(out) if out else np.zeros(0, dtype=np.int8)


def silences(levels, shortest=1.5):
    """[[start, end]] in seconds: what lies far under the talk around it."""
    if len(levels) < RATE * 10:
        return []
    speech = np.percentile(levels, 70)
    quiet = levels < max(speech - 22, -70)
    out, start = [], None
    for index, value in enumerate(quiet.tolist() + [False]):
        if value and start is None:
            start = index
        elif not value and start is not None:
            if (index - start) / RATE >= shortest:
                # a little stays, so words do not get cut
                out.append([round(start / RATE + 0.25, 1), round(index / RATE - 0.25, 1)])
            start = None
    return out


def gains(levels, every=1.0, most=8.0):
    """[dB] for each `every` seconds that bring the loud and the quiet closer: a
    shout gets turned down before it comes, a whisper up. The player can look ahead,
    which a compressor cannot."""
    if len(levels) < RATE * 10:
        return []
    size = int(RATE * every)
    blocks = len(levels) // size
    loud = levels[:blocks * size].reshape(-1, size).astype(np.float64).max(axis=1)
    speech = np.percentile(loud[loud > -60], 60) if (loud > -60).any() else -20
    wanted = np.clip(speech - loud, -most, most * 0.75)
    wanted[loud < -55] = 0
    # the loudest in the next seconds decides, then it eases
    width = 4
    ahead = np.array([wanted[i:i + width].min() for i in range(len(wanted))])
    kernel = np.ones(5) / 5
    smooth = np.convolve(ahead, kernel, mode="same")
    return np.round(smooth, 1).tolist()


def fingerprint(url, start=0, limit=420):
    """A stretch of sound as Chromaprint sees it, about eight values a second."""
    with tempfile.TemporaryDirectory(prefix="pshell-streams-") as folder:
        wav = os.path.join(folder, "a.wav")
        seek = ["-ss", str(int(start))] if start else []
        subprocess.run(["ffmpeg", "-v", "error", "-nostdin", *seek, "-i", url, "-t", str(limit), "-ac", "1", "-ar", "11025", wav], check=False, timeout=240)
        if not os.path.exists(wav):
            return []
        done = subprocess.run(["fpcalc", "-raw", "-json", "-length", str(limit), wav], capture_output=True, text=True, timeout=120, check=False)
    try:
        return json.loads(done.stdout)["fingerprint"]
    except (ValueError, KeyError):
        return []


def match(first, second, shortest=6):
    """The longest stretch two fingerprints share at any offset: (start in first,
    start in second, length) in seconds, or None. A shared intro under talk stays
    similar enough; chance gives a few seconds at most."""
    a, b = np.array(first, dtype=np.uint32), np.array(second, dtype=np.uint32)
    if min(len(a), len(b)) < FINGERPRINT_RATE * shortest:
        return None
    best = (0, 0, 0)
    for lag in range(-len(b) + 40, len(a) - 40):
        start_a, start_b = max(lag, 0), max(-lag, 0)
        size = min(len(a) - start_a, len(b) - start_b)
        errors = np.unpackbits((a[start_a:start_a + size] ^ b[start_b:start_b + size]).view(np.uint8)).reshape(-1, 32).sum(axis=1)
        good = errors <= 10
        # a quick look first: most offsets have nothing
        if good.sum() <= best[0]:
            continue
        run = longest = end = missed = 0
        for index, value in enumerate(good.tolist()):
            if value:
                run += 1
                missed = 0
            else:
                missed += 1
                if missed > 8:
                    run = 0
            if run > longest:
                longest, end = run, index
        if longest > best[0]:
            best = (longest, start_a + end - longest, start_b + end - longest)
    seconds = best[0] / FINGERPRINT_RATE
    return (best[1] / FINGERPRINT_RATE, best[2] / FINGERPRINT_RATE, seconds) if seconds >= shortest else None
