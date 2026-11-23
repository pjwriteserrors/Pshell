"""Effects: a chain of a few kinds (EQ, compressor, limiter, reverb, gain),
played by LADSPA plugins – the same ones in ffmpeg (rendering) and in a
PipeWire filter-chain (hearing the microphone live), so both sound alike.
The reverb is a convolution with a room made up here (afir in ffmpeg, the
filter-chain's convolver live): zita-reverb reads memory it never cleared
and now and then puts out noise at full scale.

A chain is a list of {"kind", "on", "name", "params": {...}} in units a
person thinks in (dB, Hz, ms, %); `controls()` turns one into the plugin's
own ports.
"""

from __future__ import annotations

import json
import math
import os
import re
import struct
import subprocess
from pathlib import Path

LADSPA = Path(os.environ.get("PSHELL_LADSPA_DIR") or "/usr/lib/ladspa")
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "rhymes"
LSP = "lsp-plugins-ladspa"
LSP_URI = "http://lsp-plug.in/plugins/ladspa/"

# kind → (plugin file, label)
PLUGINS = {
    "eq": (LSP, LSP_URI + "para_equalizer_x8_stereo"),
    "compressor": (LSP, LSP_URI + "compressor_stereo"),
    "limiter": (LSP, LSP_URI + "limiter_stereo"),
}

BANDS = 8
BAND_TYPES = {"off": 0, "bell": 1, "lowcut": 2, "highshelf": 3, "highcut": 4, "lowshelf": 5}

# what a person sets, per kind: key, label, from, to, default, unit, scale
KINDS = {
    "eq": {"name": "EQ", "params": []},  # its bands are a list of their own
    "compressor": {"name": "Compressor", "params": [
        {"key": "threshold", "label": "Threshold", "from": -60, "to": 0, "default": -18, "unit": "dB", "step": 0.5},
        {"key": "ratio", "label": "Ratio", "from": 1, "to": 20, "default": 4, "unit": ":1", "step": 0.1, "log": True},
        {"key": "attack", "label": "Attack", "from": 0.1, "to": 200, "default": 10, "unit": "ms", "step": 0.1, "log": True},
        {"key": "release", "label": "Release", "from": 5, "to": 2000, "default": 100, "unit": "ms", "step": 1, "log": True},
        {"key": "knee", "label": "Knee", "from": 0, "to": 24, "default": 6, "unit": "dB", "step": 0.5},
        {"key": "makeup", "label": "Makeup", "from": -12, "to": 30, "default": 0, "unit": "dB", "step": 0.5},
        {"key": "mix", "label": "Mix", "from": 0, "to": 100, "default": 100, "unit": "%", "step": 1},
    ]},
    "limiter": {"name": "Limiter", "params": [
        {"key": "threshold", "label": "Ceiling", "from": -24, "to": 0, "default": -1, "unit": "dB", "step": 0.1},
        {"key": "gain", "label": "Input", "from": -12, "to": 24, "default": 0, "unit": "dB", "step": 0.5},
        {"key": "release", "label": "Release", "from": 0.25, "to": 20, "default": 6, "unit": "ms", "step": 0.05, "log": True},
    ]},
    "reverb": {"name": "Reverb", "params": [
        {"key": "time", "label": "Length", "from": 0.3, "to": 8, "default": 2, "unit": "s", "step": 0.05},
        {"key": "predelay", "label": "Pre-delay", "from": 0, "to": 150, "default": 20, "unit": "ms", "step": 1},
        {"key": "damping", "label": "Damping", "from": 1500, "to": 20000, "default": 6000, "unit": "Hz", "step": 10, "log": True},
        {"key": "low", "label": "Lows", "from": -20, "to": 6, "default": 0, "unit": "dB", "step": 0.5},
        {"key": "high", "label": "Highs", "from": -20, "to": 6, "default": 0, "unit": "dB", "step": 0.5},
        {"key": "mix", "label": "Wet", "from": 0, "to": 100, "default": 20, "unit": "%", "step": 1},
    ]},
    "gain": {"name": "Gain", "params": [
        {"key": "gain", "label": "Gain", "from": -24, "to": 24, "default": 0, "unit": "dB", "step": 0.1},
    ]},
}


def db(value: float) -> float:
    return 10 ** (float(value) / 20)


def defaults(kind: str) -> dict:
    if kind == "eq":
        return {"bands": [{"type": "lowcut", "freq": 80, "gain": 0, "q": 0.7}, {"type": "bell", "freq": 300, "gain": 0, "q": 1},
                          {"type": "bell", "freq": 3000, "gain": 0, "q": 1}, {"type": "highshelf", "freq": 10000, "gain": 0, "q": 0.7}]}
    return {p["key"]: p["default"] for p in KINDS[kind]["params"]}


def effect(kind: str, params: dict | None = None, name: str = "") -> dict:
    return {"kind": kind, "on": True, "name": name or KINDS[kind]["name"], "params": {**defaults(kind), **(params or {})}}


def available() -> dict:
    """Which kinds can be played here (their plugin is installed)."""
    return {kind: kind not in PLUGINS or (LADSPA / f"{PLUGINS[kind][0]}.so").exists() for kind in KINDS}


# ── the plugins' own ports ──────────────────────────────────────────────
_ports: dict[tuple, list] = {}


def ports(file: str, label: str) -> list[str]:
    """The plugin's control inputs in order (ffmpeg's c0, c1, …), from analyseplugin, kept in the cache."""
    key = (file, label)
    if key in _ports:
        return _ports[key]
    so = LADSPA / f"{file}.so"
    cache = CACHE / "ladspa-ports.json"
    stamp = f"{so.stat().st_mtime:.0f}" if so.exists() else "0"
    known = {}
    try:
        known = json.loads(cache.read_text())
    except (OSError, ValueError):
        pass
    entry = known.get(f"{file}|{label}")
    if not entry or entry.get("stamp") != stamp:
        out = subprocess.run(["analyseplugin", str(so), label], capture_output=True, text=True, timeout=30).stdout
        entry = {"stamp": stamp, "ports": re.findall(r'"([^"]+)" input, control', out)}
        if not entry["ports"]:
            raise RuntimeError(f"{label} is not installed")
        known[f"{file}|{label}"] = entry
        CACHE.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(known))
    _ports[key] = entry["ports"]
    return entry["ports"]


def controls(fx: dict) -> dict:
    """Port name → value for the plugin playing this effect."""
    kind, p = fx["kind"], {**defaults(fx["kind"]), **(fx.get("params") or {})}
    if kind == "eq":
        out = {}
        for i in range(BANDS):
            band = (p.get("bands") or [])[i] if i < len(p.get("bands") or []) else None
            kind_of = BAND_TYPES.get((band or {}).get("type", "off"), 0) if band and band.get("on", True) else 0
            out[f"Filter type {i}"] = kind_of
            if kind_of:
                out[f"Frequency {i} (Hz)"] = min(24000, max(10, float(band.get("freq", 1000))))
                out[f"Gain {i} (G)"] = min(63.0957, max(0.01585, db(band.get("gain", 0))))
                out[f"Quality factor {i}"] = min(100, max(0, float(band.get("q", 1))))
                # cuts: 12 dB an octave
                out[f"Filter slope {i}"] = 1 if kind_of in (2, 4) else 0
        return out
    if kind == "compressor":
        knee = float(p["knee"])
        return {"Attack threshold (G)": db(p["threshold"]), "Ratio": float(p["ratio"]), "Attack time (ms)": float(p["attack"]),
                "Release time (ms)": float(p["release"]), "Knee (G)": min(1, max(0.0631, db(-knee))), "Makeup gain (G)": db(p["makeup"]),
                "Dry gain (G)": 1 - float(p["mix"]) / 100, "Wet gain (G)": float(p["mix"]) / 100}
    if kind == "limiter":
        return {"Threshold (G)": min(1, max(0.00398107, db(p["threshold"]))), "Input gain (G)": db(p["gain"]),
                "Release time (ms)": float(p["release"]), "Automatic level regulation": 0, "Lookahead (ms)": 2}
    return {}


# ── the reverb's room ───────────────────────────────────────────────────
def impulse(params: dict) -> str:
    """A stereo room (48 kHz WAV, float) for these settings: noise dying away, the highs
    sooner above the damping, shaped by the lows and highs; kept in the cache."""
    import hashlib
    p = {**defaults("reverb"), **(params or {})}
    shape = {k: round(float(p[k]), 3) for k in ("time", "predelay", "damping", "low", "high")}
    out = CACHE / "rooms" / (hashlib.sha1(json.dumps(shape, sort_keys=True).encode()).hexdigest()[:16] + ".wav")
    if out.exists():
        return str(out)
    import wave
    import numpy as np
    rate, size, hop = 48000, 1024, 256
    length = min(10.0, shape["time"] * 1.25 + 0.05)
    frames = int(length * rate / hop) + 4
    freqs = np.fft.rfftfreq(size, 1 / rate)
    rt = shape["time"] / (1 + (freqs / max(500.0, shape["damping"])) ** 2)
    rt = np.maximum(rt, 0.05)
    tone = 10 ** ((shape["low"] / (1 + (freqs / 250) ** 2) + shape["high"] / (1 + (4000 / np.maximum(freqs, 1)) ** 2)) / 20)
    rng = np.random.default_rng(7)
    window = np.hanning(size)
    channels = []
    for _ in range(2):
        signal = np.zeros(frames * hop + size)
        for f in range(frames):
            t = f * hop / rate
            spectrum = tone * np.exp(-6.91 * t / rt) * np.exp(2j * np.pi * rng.random(len(freqs)))
            signal[f * hop:f * hop + size] += np.fft.irfft(spectrum, size) * window
        # a softer start than a wall of noise
        attack = int(0.008 * rate)
        signal[:attack] *= np.linspace(0, 1, attack)
        channels.append(signal[:int(length * rate)])
    room = np.stack(channels, axis=1)
    room /= np.sqrt((room ** 2).sum() / 2) + 1e-12
    room *= 0.5
    pad = np.zeros((int(shape["predelay"] / 1000 * rate), 2))
    room = np.concatenate([pad, room]).astype("<f4")
    out.parent.mkdir(parents=True, exist_ok=True)
    for old in sorted(out.parent.glob("*.wav"), key=lambda f: f.stat().st_mtime)[:-24]:
        old.unlink(missing_ok=True)
    part = out.with_suffix(".part")
    with open(part, "wb") as file:
        data = room.tobytes()
        # WAV with IEEE float samples (format 3)
        file.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, 2, rate, rate * 8, 8, 32)
                   + b"data" + struct.pack("<I", len(data)) + data)
    part.rename(out)
    return str(out)


def live(chain: list) -> list:
    return [fx for fx in chain or [] if fx.get("on", True) and fx.get("kind") in KINDS and available().get(fx["kind"])]


# ── ffmpeg ──────────────────────────────────────────────────────────────
def _escape(value: str) -> str:
    # a value inside a filter's option, inside a filter graph
    return value.replace("\\", "\\\\\\\\").replace(":", "\\\\:").replace("'", "\\\\'")


def ffmpeg_graph(chain: list, source: str, tag: str) -> tuple[list, str]:
    """The chain as pieces of an ffmpeg filter graph from the stereo stream [source];
    gives the pieces and the label the result comes out of."""
    pieces, last = [], source
    for i, fx in enumerate(live(chain)):
        name = f"{tag}f{i}"
        kind, params = fx["kind"], {**defaults(fx["kind"]), **(fx.get("params") or {})}
        if kind == "gain":
            pieces.append(f"[{last}]volume={float(params['gain']):.2f}dB[{name}]")
        elif kind == "reverb":
            room = _escape(impulse(params))
            wet = float(params["mix"]) / 100
            pieces += [f"[{last}]asplit=2[{name}d][{name}w]", f"amovie={room}[{name}r]",
                       f"[{name}w][{name}r]afir=irnorm=-1:irgain=1:gtype=-1:minp=512:maxp=8192[{name}c]",
                       f"[{name}d][{name}c]amix=inputs=2:weights=1 {wet:.4f}:normalize=0:duration=first[{name}]"]
        else:
            file, label = PLUGINS[kind]
            names = ports(file, label)
            c = "|".join(f"c{names.index(k)}={v:.6g}" for k, v in controls(fx).items() if k in names)
            pieces.append(f"[{last}]ladspa=f={file}:p={_escape(label)}" + (f":c={c}" if c else "") + f"[{name}]")
        last = name
    return pieces, last


def ffmpeg_filters(chain: list) -> str:
    """The chain for -af on a stereo stream ('' when nothing is on)."""
    pieces, last = ffmpeg_graph(chain, "x0", "x")
    if not pieces:
        return ""
    return ";".join(["anull[x0]"] + pieces).removesuffix(f"[{last}]")


# ── PipeWire ────────────────────────────────────────────────────────────
def _spa(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return f"{value:.6g}"
    if isinstance(value, dict):
        return "{ " + " ".join(f"{_spa_key(k)} = {_spa(v)}" for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "[ " + " ".join(_spa(v) for v in value) + " ]"
    return json.dumps(str(value))


def _spa_key(key: str) -> str:
    return key if re.fullmatch(r"[A-Za-z0-9_.\-]+", key) else json.dumps(key)


def filter_graph(chain: list) -> dict:
    """The chain as a filter-chain graph, stereo in and out."""
    nodes = [{"type": "builtin", "name": "inl", "label": "copy"}, {"type": "builtin", "name": "inr", "label": "copy"}]
    links = []
    last = ["inl:Out", "inr:Out"]

    def wire(ins):
        links.extend({"output": o, "input": i} for o, i in zip(last, ins))

    for i, fx in enumerate(live(chain)):
        name = f"fx{i}"
        kind, params = fx["kind"], {**defaults(fx["kind"]), **(fx.get("params") or {})}
        if kind == "gain":
            gain = db(params["gain"])
            nodes += [{"type": "builtin", "name": name + "l", "label": "linear", "control": {"Mult": gain}},
                      {"type": "builtin", "name": name + "r", "label": "linear", "control": {"Mult": gain}}]
            wire([f"{name}l:In", f"{name}r:In"])
            last = [f"{name}l:Out", f"{name}r:Out"]
        elif kind == "reverb":
            room, wet = impulse(params), float(params["mix"]) / 100
            outs = []
            for side, channel in (("l", 0), ("r", 1)):
                nodes += [{"type": "builtin", "name": f"{name}c{side}", "label": "convolver", "config": {"filename": room, "channel": channel}},
                          {"type": "builtin", "name": f"{name}m{side}", "label": "mixer", "control": {"Gain 1": 1.0, "Gain 2": wet}}]
                source = last[channel]
                links += [{"output": source, "input": f"{name}c{side}:In"}, {"output": source, "input": f"{name}m{side}:In 1"},
                          {"output": f"{name}c{side}:Out", "input": f"{name}m{side}:In 2"}]
                outs.append(f"{name}m{side}:Out")
            last = outs
        else:
            file, label = PLUGINS[kind]
            nodes.append({"type": "ladspa", "name": name, "plugin": str(LADSPA / f"{file}.so"), "label": label, "control": controls(fx)})
            wire([f"{name}:Input L", f"{name}:Input R"])
            last = [f"{name}:Output L", f"{name}:Output R"]
    return {"nodes": nodes, "links": links, "inputs": ["inl:In", "inr:In"], "outputs": last}


def pipewire_config(chain: list, source: str = "", sink: str = "", level: float = 1.0, quantum: int = 64, from_sink: bool = False) -> str:
    """A config for `pipewire -c`: the microphone through the chain into the headphones."""
    graph = filter_graph(chain)
    if level != 1.0:
        graph["nodes"] += [{"type": "builtin", "name": "vl", "label": "linear", "control": {"Mult": level}},
                           {"type": "builtin", "name": "vr", "label": "linear", "control": {"Mult": level}}]
        graph["links"] += [{"output": graph["outputs"][0], "input": "vl:In"}, {"output": graph["outputs"][1], "input": "vr:In"}]
        graph["outputs"] = ["vl:Out", "vr:Out"]
    latency = f"{quantum}/48000"
    capture = {"node.name": "pshell_rhymes_monitor_in", "node.passive": True, "audio.position": ["FL", "FR"],
               "node.latency": latency, "stream.dont-remix": False}
    if source:
        capture["target.object"] = source
    if from_sink:
        capture["stream.capture.sink"] = True
    playback = {"node.name": "pshell_rhymes_monitor_out", "node.description": "Rhymes · hearing the microphone",
                "audio.position": ["FL", "FR"], "node.latency": latency, "media.role": "Production"}
    if sink:
        playback["target.object"] = sink
    args = {"node.description": "Rhymes monitor", "media.name": "Rhymes monitor", "filter.graph": graph,
            "audio.channels": 2, "audio.position": ["FL", "FR"], "capture.props": capture, "playback.props": playback}
    return "\n".join([
        "context.properties = { log.level = 0 }",
        "context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert support.* = support/libspa-support }",
        "context.modules = [",
        "  { name = libpipewire-module-rt flags = [ ifexists nofail ] }",
        "  { name = libpipewire-module-protocol-native }",
        "  { name = libpipewire-module-client-node }",
        "  { name = libpipewire-module-adapter }",
        f"  {{ name = libpipewire-module-filter-chain args = {_spa(args)} }}",
        "]",
        "",
    ])


# ── FL Studio mixer states (.fst) ───────────────────────────────────────
def _events(data: bytes):
    if data[:4] != b"FLhd":
        raise ValueError("Not an FL Studio file")
    p = 8 + struct.unpack("<I", data[4:8])[0]
    if data[p:p + 4] != b"FLdt":
        raise ValueError("Not an FL Studio file")
    p += 8
    while p < len(data):
        event = data[p]
        p += 1
        if event < 64:
            yield event, data[p]
            p += 1
        elif event < 128:
            yield event, struct.unpack("<H", data[p:p + 2])[0]
            p += 2
        elif event < 192:
            yield event, struct.unpack("<I", data[p:p + 4])[0]
            p += 4
        else:
            size = shift = 0
            while True:
                b = data[p]
                p += 1
                size |= (b & 0x7F) << shift
                shift += 7
                if not b & 0x80:
                    break
            yield event, data[p:p + size]
            p += size


def _ints(blob: bytes) -> list[int]:
    n = len(blob) // 4
    return list(struct.unpack(f"<{n}i", blob[:n * 4]))


def _fl_freq(value: int) -> float:
    # Parametric EQ 2: 0…65536 over 20 Hz…20 kHz, logarithmic
    return round(20 * 1000 ** (value / 65536), 1)


def read_fst(path: str) -> dict:
    """What an FL Studio mixer insert holds: its name and its plugins, each with
    what could be read of it and the effect it turns into here (or None)."""
    data = Path(path).read_bytes()
    name, slots, current, mixes = "", [], None, {}
    for event, value in _events(data):
        if event == 204 and isinstance(value, bytes):
            name = value.decode("utf-16-le", "ignore").rstrip("\0")
        elif event == 201 and isinstance(value, bytes):
            current = {"plugin": value.decode("utf-16-le", "ignore").rstrip("\0"), "data": b""}
            slots.append(current)
        elif event == 213 and current is not None and isinstance(value, bytes):
            current["data"] = value
        elif event == 225 and isinstance(value, bytes):
            # the insert's parameters: per slot whether it is on and how much of it is mixed in
            for i in range(0, len(value) - 11, 12):
                kind, slot, mix = value[i + 4], value[i + 6] - 0x40, struct.unpack("<i", value[i + 8:i + 12])[0]
                if value[i + 5] == 0x1F and value[i + 7] == 0x20 and 0 <= slot < 10:
                    entry = mixes.setdefault(slot, {})
                    if kind == 0:
                        entry["on"] = bool(mix)
                    elif kind == 1:
                        entry["mix"] = mix / 12800
    chain, found = [], []
    for index, slot in enumerate(slots):
        state = mixes.get(index, {})
        on, mix = state.get("on", True), state.get("mix", 1.0)
        fx, note = _translate(slot["plugin"], slot["data"], mix)
        found.append({"plugin": slot["plugin"], "on": on, "mix": round(mix, 3), "becomes": fx["kind"] if fx else None, "note": note})
        if fx:
            fx["on"] = on
            chain.append(fx)
    return {"name": name or Path(path).stem, "chain": chain, "found": found}


def _translate(plugin: str, blob: bytes, mix: float):
    v = _ints(blob)
    if plugin == "Fruity Parametric EQ 2" and len(v) >= 29:
        levels, freqs, widths, types = v[1:8], v[8:15], v[15:22], v[22:29]
        named = {5: "lowshelf", 6: "bell", 7: "highshelf", 3: "lowcut", 1: "highcut"}
        bands = []
        for level, freq, width, kind in zip(levels, freqs, widths, types):
            if kind not in named:
                continue
            octaves = max(0.1, width / 65536 * 4)
            q = round(math.sqrt(2 ** octaves) / (2 ** octaves - 1), 2)
            bands.append({"type": named[kind], "freq": _fl_freq(freq), "gain": round(level / 100, 2), "q": q})
        return effect("eq", {"bands": bands}, "EQ"), "bands read"
    if plugin == "Fruity Compressor" and len(v) >= 6:
        return effect("compressor", {"threshold": v[1] / 10, "ratio": max(1, v[2] / 10), "makeup": v[3] / 10,
                                     "attack": max(0.1, v[4] / 100), "release": max(5, v[5] / 10), "mix": round(mix * 100)}, "Compressor"), "read"
    if plugin == "Fruity Limiter":
        return effect("limiter", {"threshold": -1, "release": 6}, "Limiter"), "approximated"
    if plugin == "Maximus":
        return effect("compressor", {"threshold": -20, "ratio": 2, "attack": 20, "release": 150, "knee": 12, "makeup": 2,
                                     "mix": round(mix * 100)}, "Glue (Maximus)"), "approximated"
    if plugin == "Patcher":
        text = blob.decode("utf-16-le", "ignore")
        if "Reeverb" in text or "Reverb" in text:
            wet = 18 if "1K Reverb" in text else 30
            return effect("reverb", {"time": 2.2, "predelay": 30, "damping": 7000, "low": -6, "mix": round(wet * mix)}, "Reverb"), "approximated"
        return None, "not played here"
    if plugin == "Fruity Balance" and len(v) >= 2:
        return effect("gain", {"gain": round(20 * math.log10(max(v[1], 1) / 256), 2)}, "Balance"), "read"
    if plugin == "Fruity Reeverb 2":
        return effect("reverb", {"mix": round(25 * mix)}, "Reverb"), "approximated"
    return None, "not played here"
