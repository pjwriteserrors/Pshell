#!/usr/bin/env python3
"""Put the wallpaper's colours on the hardware: keyboard, GPU, ARGB headers.

    apply_lighting.py                 derive everything from the current theme
    apply_lighting.py --only keyboard only the keyboard (or: leds)
    apply_lighting.py --restore       re-apply the last state (used at login)
    apply_lighting.py --watch         stay, and put the colours back whenever
                                      the keyboard is plugged in again
    apply_lighting.py --probe 0 30    light 30 LEDs on ARGB header 0, to count them
    apply_lighting.py --probe-order 0 paint it red/green/blue to read its wiring
    apply_lighting.py --dry-run       print what would be sent

The keyboard gets the wallpaper itself, projected onto its key matrix. The GPU
and the ARGB headers get a single colour picked from the Wallust palette - the
most colourful entry that is not the background, because a GPU shroud lit in
"#1A1E20" reads as "off".

Every run writes what it sent to a state file. --restore replays that file
verbatim, which is what a fresh login needs: the OpenRGB server comes up with
the devices dark, and recomputing from the theme would be both slower and
capable of disagreeing with what was on screen before the reboot.

The colours only stay while an OpenRGB server holds the devices: a keyboard in
Direct mode falls back to the colours it has stored the moment the program
that set them is gone, and `openrgb --client` without a server is such a
program. So a server is started here when none is listening - no unit has to
be installed for it, the same shell works on every machine the keyboard is
plugged into. A device that is not there is left out without a word, which is
what lets one configuration serve a desktop with fans and a laptop without.

The keyboard and the LEDs (GPU, ARGB headers) are two theme hooks, `openrgb`
and `openrgb-leds`, and two parts of the saved state.

Device roles, gains and the LED count of each ARGB header live in
hosts/<profile>-lighting.json, because only the person with the case open
knows how many LEDs are on a header.
"""

from __future__ import annotations

import argparse
import colorsys
import fcntl
import json
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import sys
import time

from PIL import Image, ImageEnhance, ImageOps


NA = -1
MATRIX_WIDTH = 22
MATRIX_HEIGHT = 6
LED_COUNT = 112

SHELL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SHELL_DIR / "scripts"))
import host  # noqa: E402

CONFIG_PATH = Path(os.environ.get("LIGHTING_CONFIG") or SHELL_DIR / "hosts" / f"{host.profile_name()}-lighting.json")
STATE_DIR = Path(os.environ.get("THEME_STATE_DIR", Path.home() / ".local/state/quickshell-theme"))
STATE_PATH = STATE_DIR / "lighting-state.json"
FRAME_PATH = STATE_DIR / "current" / "frame.png"
PALETTE_PATH = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "wal" / "colors.json"
LOCK_PATH = Path("/tmp/openrgb-lighting.lock")

SERVER = os.environ.get("OPENRGB_SERVER", "127.0.0.1:6742")
# the server of a machine that has the units installed, and the one started here
INSTALLED_UNIT = "openrgb-theme.service"
OWN_UNIT = "quickshell-openrgb.service"
# part of the state -> the theme hook that switches it
PARTS = {"keyboard": "openrgb", "leds": "openrgb-leds"}

# OpenRGB's ANSI matrix for SteelSeries Apex keyboards. Values are indices in
# the device's 112-entry LED array, not HID key codes.
BASE_MATRIX = [
    [37, NA, 53, 54, 55, 56, NA, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, NA, NA, NA, NA],
    [48, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 41, 42, 38, NA, 68, 69, 70, 94, 95, 96, 97],
    [39, NA, 16, 22, 4, 17, 19, 24, 20, 8, 14, 15, 43, 44, 88, 71, 72, 73, 106, 107, 108, 98],
    [52, NA, 0, 18, 3, 5, 6, 7, 9, 10, 11, 46, 47, 36, NA, NA, NA, NA, 103, 104, 105, NA],
    [80, NA, 25, 23, 2, 21, 1, 13, 12, 49, 50, 51, 84, NA, NA, NA, 77, NA, 100, 101, 102, 99],
    [79, 82, 81, NA, NA, NA, NA, 40, NA, NA, NA, 85, 86, 87, 83, 75, 76, 74, 109, NA, 110, NA],
]

TKL_PATCH = [
    (0, 15, NA), (0, 16, NA), (0, 17, 111),
    (1, 18, NA), (1, 19, NA), (1, 20, NA), (1, 21, NA),
    (2, 18, NA), (2, 19, NA), (2, 20, NA), (2, 21, NA),
    (3, 18, NA), (3, 19, NA), (3, 20, NA),
    (4, 18, NA), (4, 19, NA), (4, 20, NA), (4, 21, NA),
    (5, 18, NA), (5, 20, NA),
]

ISO_PATCH = [(2, 14, 36), (3, 13, 45), (4, 1, 78)]

DEFAULT_CONFIG = {
    "keyboard": {
        "enabled": True,
        "device": "SteelSeries Apex Pro TKL Gen 3",
        "layout": "us-tkl",
        "saturation": 1.35,
        "brightness": 0.95,
        "contrast": 1.45,
        "sharpness": 2.0,
    },
    "gpu": {
        "enabled": True,
        "device": "PowerColor Red Devil RX5700XT",
        "mode": "Static",
        "source": "accent",
        "order": "RGB",
        "saturation": 1.2,
        "saturation_floor": 1.0,
        "lightness": 0.5,
        "brightness": 1.0,
        "gains": {"r": 1.0, "g": 0.5, "b": 0.35},
    },
    "argb": {
        "enabled": True,
        "device": "ASUS ROG STRIX Z370-F GAMING Addressable",
        "mode": "Direct",
        "order": "RGB",
        "saturation": 1.2,
        "saturation_floor": 1.0,
        "lightness": 0.5,
        "brightness": 1.0,
        "gains": {"r": 1.0, "g": 0.5, "b": 0.35},
        # One entry per Addressable RGB Header. "leds" is how many LEDs are
        # physically on that header - 0 means nothing is plugged in. Fans are
        # usually daisy-chained, so one header can carry several of them.
        "headers": [
            {"zone": 0, "leds": 0, "source": "accent"},
            {"zone": 1, "leds": 0, "source": "accent"},
            {"zone": 2, "leds": 0, "source": "accent"},
            {"zone": 3, "leds": 0, "source": "accent"},
        ],
    },
}


# ------------------------------------------------------------------ palette ---

def load_config() -> dict:
    config = json.loads(json.dumps(DEFAULT_CONFIG))
    if CONFIG_PATH.is_file():
        try:
            stored = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            print(f"{CONFIG_PATH}: {error}; using defaults", file=sys.stderr)
            return config
        for section, values in stored.items():
            if isinstance(values, dict) and isinstance(config.get(section), dict):
                config[section].update(values)
            else:
                config[section] = values
    return config


def load_palette() -> dict[str, str]:
    data = json.loads(PALETTE_PATH.read_text(encoding="utf-8"))
    palette = {name: value.lstrip("#") for name, value in data["colors"].items()}
    palette.update({name: value.lstrip("#") for name, value in data["special"].items()})
    return palette


def saturation_of(hex_color: str) -> float:
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return colorsys.rgb_to_hls(r, g, b)[2]


def luminance_of(hex_color: str) -> float:
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def accents(palette: dict[str, str]) -> list[str]:
    """Palette entries ranked by how much colour they actually carry.

    A shroud or a fan ring is a single large light: it wants the entry with the
    most chroma that is still bright enough to be seen, not color1 by position.
    """
    candidates = [palette[f"color{i}"] for i in range(1, 7) if f"color{i}" in palette]
    ranked = sorted(
        candidates,
        key=lambda value: saturation_of(value) * (0.35 + luminance_of(value)),
        reverse=True,
    )
    return ranked or [palette.get("foreground", "FFFFFF")]


def resolve_source(name: str, palette: dict[str, str]) -> str:
    ranked = accents(palette)
    if name == "accent":
        return ranked[0]
    if name == "accent2":
        return ranked[1] if len(ranked) > 1 else ranked[0]
    if name == "accent3":
        return ranked[2] if len(ranked) > 2 else ranked[-1]
    return palette.get(name, ranked[0])


# LED strips do not all take their bytes in the same order. A WS2812 wants
# green first; some fan rings swap green and blue. Sending sRGB to a strip that
# expects something else does not just shift the hue, it lands somewhere else
# entirely - an orange arrives as pink. --probe-order reads the wiring off the
# hardware; this then permutes every colour on the way out.
CHANNEL_ORDERS = {
    "RGB": (0, 1, 2),
    "RBG": (0, 2, 1),
    "GRB": (1, 0, 2),
    "GBR": (1, 2, 0),
    "BRG": (2, 0, 1),
    "BGR": (2, 1, 0),
}


def reorder(hex_color: str, order: str) -> str:
    """Permute a colour so a strip wired in `order` displays it as intended.

    `order` names the order the strip reads its bytes in. Position i of the
    output is the intended channel that the strip will read there.
    """
    mapping = CHANNEL_ORDERS.get(order.upper())
    if mapping is None or mapping == (0, 1, 2):
        return hex_color
    channels = [hex_color[0:2], hex_color[2:4], hex_color[4:6]]
    return "".join(channels[index] for index in mapping)


def adjust(hex_color: str, saturation: float, brightness: float, gains: dict,
           saturation_floor: float = 0.0, lightness_target: float | None = None) -> str:
    """Shape the colour in HLS, then calibrate the channels on the way out.

    Order matters. Gains used to run first, before the saturation floor, which
    made them nearly pointless: renormalising to full saturation afterwards puts
    back most of what they took away, so they only nudged the hue. They are
    output calibration and belong last, where turning green down actually turns
    the green LED down. That is the knob for "the wallpaper's brick red arrives
    as plain orange": these LEDs' green is far more efficient than their red, so
    even a small green value drags the mix towards orange.

    `saturation_floor` is what makes a wallpaper colour survive the trip to a
    lamp. A palette entry like "#D45A44" is a muted brick: every channel is lit,
    the darkest sitting at 68/255. A screen shows that as brick because it is
    also showing everything around it. A diffused LED has no surroundings, so
    that floor is just white mixed in, and the fans come out pink. Raising the
    saturation to the floor keeps the hue and drops the white.

    `lightness_target` finishes the job. Saturation alone cannot clear the white
    when the colour is lighter than mid: at L=0.53 even S=1.0 leaves every
    channel at 14/255. L=0.5 with S=1.0 is the one point where a hue is pure -
    one channel at full, one at zero - which is the brightest honest version of
    a colour an LED can show. `brightness` then dims from there.
    """
    def to_linear(value: float) -> float:
        value /= 255
        return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4

    def to_srgb(value: float) -> int:
        value = max(0.0, min(1.0, value))
        srgb = 12.92 * value if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055
        return int(round(srgb * 255))

    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (0, 2, 4))

    hue, lightness, sat = colorsys.rgb_to_hls(r, g, b)
    sat = max(0.0, min(1.0, sat * saturation))
    sat = max(sat, max(0.0, min(1.0, saturation_floor)))
    if lightness_target is not None:
        lightness = lightness_target
    lightness = max(0.0, min(1.0, lightness * brightness))
    r, g, b = colorsys.hls_to_rgb(hue, lightness, sat)

    # Channel calibration, in linear light because that is where an LED's output
    # actually is: halving the green gain halves the light the green die emits.
    linear = [to_linear(c * 255) for c in (r, g, b)]
    linear = [
        linear[0] * float(gains.get("r", 1.0)),
        linear[1] * float(gains.get("g", 1.0)),
        linear[2] * float(gains.get("b", 1.0)),
    ]

    return "{:02X}{:02X}{:02X}".format(*(to_srgb(c) for c in linear))


# ----------------------------------------------------------------- keyboard ---

def keyboard_matrix(layout: str) -> list[list[int]]:
    matrix = [row[:] for row in BASE_MATRIX]
    for row, column, value in TKL_PATCH:
        matrix[row][column] = value
    if layout == "de-tkl":
        for row, column, value in ISO_PATCH:
            matrix[row][column] = value
    return matrix


# Samples per key and axis before a key's colour is chosen: a key covers a
# patch of the picture, and the patch is looked at as 5x5 points.
KEY_SAMPLES = 5


def key_columns(matrix: list[list[int]]) -> tuple[int, int]:
    """The first and last column of the matrix that has a key on this layout."""
    present = [column for column in range(MATRIX_WIDTH)
               if any(matrix[row][column] != NA for row in range(MATRIX_HEIGHT))]
    return (present[0], present[-1] + 1) if present else (0, MATRIX_WIDTH)


def medoid(samples: list[tuple[int, int, int]]) -> tuple[int, int, int]:
    """The sample closest to all the others: a colour that is in the patch.

    The mean of a patch that is half orange and half blue is grey, and the
    mean of a bright patch with a dark edge is a pale wash - colours the
    picture never had. The medoid is one of the pixels, so a key shows what
    most of its patch shows.
    """
    best, best_cost = samples[0], float("inf")
    for candidate in samples:
        cost = 0
        for other in samples:
            cost += (candidate[0] - other[0]) ** 2 + (candidate[1] - other[1]) ** 2 + (candidate[2] - other[2]) ** 2
            if cost >= best_cost:
                break
        if cost < best_cost:
            best, best_cost = candidate, cost
    return best


def sampled_colors(image_path: Path, settings: dict) -> list[str]:
    with Image.open(image_path) as source:
        source.seek(0)
        rgba = source.convert("RGBA")
        background = Image.new("RGBA", rgba.size, (0, 0, 0, 255))
        image = Image.alpha_composite(background, rgba).convert("RGB")

    matrix = keyboard_matrix(settings.get("layout", "us-tkl"))
    first, last = key_columns(matrix)
    columns = last - first

    # The whole picture over the keys that exist: the top row of keys shows
    # the top of the wallpaper, the bottom row its bottom, the left and right
    # edges its edges. Fitting the picture into the matrix' aspect ratio
    # instead cropped it to a band through the middle, so the sky or the
    # ground was never on the keyboard; and the columns of a layout without
    # a numpad used to take the right fifth of the picture with them.
    patches = image.resize(
        (columns * KEY_SAMPLES, MATRIX_HEIGHT * KEY_SAMPLES),
        resample=Image.Resampling.BOX,
    )
    keys = Image.new("RGB", (columns, MATRIX_HEIGHT))
    pixels = patches.load()
    for row in range(MATRIX_HEIGHT):
        for column in range(columns):
            samples = [
                pixels[column * KEY_SAMPLES + dx, row * KEY_SAMPLES + dy]
                for dy in range(KEY_SAMPLES)
                for dx in range(KEY_SAMPLES)
            ]
            keys.putpixel((column, row), medoid(samples))

    # the same grading as before: the contrast is what makes a backlit key
    # read at all, so it is left to the settings
    keys = ImageEnhance.Color(keys).enhance(float(settings.get("saturation", 1.35)))
    keys = ImageEnhance.Brightness(keys).enhance(float(settings.get("brightness", 0.95)))
    keys = ImageEnhance.Contrast(keys).enhance(float(settings.get("contrast", 1.45)))
    keys = ImageEnhance.Sharpness(keys).enhance(float(settings.get("sharpness", 2.0)))

    colors = ["000000"] * LED_COUNT
    graded = keys.load()
    for row in range(MATRIX_HEIGHT):
        for column in range(first, last):
            led = matrix[row][column]
            if led == NA:
                continue
            red, green, blue = graded[column - first, row]
            colors[led] = f"{red:02X}{green:02X}{blue:02X}"
    return colors


# ------------------------------------------------------------------ openrgb ---

def openrgb(*args: str, timeout: float = 35) -> subprocess.CompletedProcess:
    command = ["openrgb", "--client", SERVER, *args]
    return subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=False)


def server_listening() -> bool:
    address, _, port = SERVER.rpartition(":")
    try:
        with socket.create_connection((address or "127.0.0.1", int(port or 6742)), timeout=1):
            return True
    except (OSError, ValueError):
        return False


def systemctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["systemctl", "--user", *args], text=True, capture_output=True, check=False)


def start_server() -> None:
    if systemctl("cat", INSTALLED_UNIT).returncode == 0:
        systemctl("start", INSTALLED_UNIT)
        return
    address, _, port = SERVER.rpartition(":")
    systemctl("reset-failed", OWN_UNIT)
    subprocess.run(
        ["systemd-run", "--user", "--quiet", "--collect", f"--unit={OWN_UNIT}",
         "--property=Restart=on-failure", "--property=RestartSec=2",
         "openrgb", "--server", "--server-host", address or "127.0.0.1", "--server-port", port or "6742", "--loglevel", "3"],
        capture_output=True, check=False,
    )


def stop_server() -> None:
    for unit in (OWN_UNIT, INSTALLED_UNIT):
        if systemctl("is-active", "--quiet", unit).returncode == 0:
            systemctl("stop", unit)
    for _ in range(20):
        if not server_listening():
            return
        time.sleep(0.25)


def list_devices() -> dict[str, str]:
    """The devices the server holds: index -> name."""
    result = openrgb("--list-devices", timeout=15)
    return dict(re.findall(r"^(\d+): (.+?)\s*$", result.stdout, re.M)) if result.returncode == 0 else {}


def ensure_server(patience: float = 60) -> bool:
    """A server that answers and has found its devices; True when it was started here.

    Asking `openrgb --client` is no test: without a server it quietly looks
    for the devices itself, and answers.
    """
    started = False
    if not server_listening():
        start_server()
        started = True
    deadline = time.time() + patience
    while time.time() < deadline:
        if server_listening() and list_devices():
            break
        time.sleep(0.5)
    return started


def find_devices(name: str, devices: dict[str, str]) -> list[str]:
    """The indices a device goes by. OpenRGB versions disagree about suffixes
    ("… Gen 3" is "… Gen 3 Wired" to a newer one), and a keyboard may be listed
    once per interface it has: all of them are told, the one with the keys
    listens."""
    wanted = name.strip().lower()
    exact = [index for index, found in devices.items() if found.lower() == wanted]
    return exact or [index for index, found in devices.items() if wanted in found.lower() or found.lower() in wanted]


def build_plan(config: dict, parts: list[str]) -> list[dict]:
    """The exact set of openrgb invocations, as data so it can be saved."""
    plan: list[dict] = []
    palette = load_palette() if "leds" in parts else {}

    keyboard = config.get("keyboard", {})
    if "keyboard" in parts and keyboard.get("enabled", True) and FRAME_PATH.is_file():
        colors = sampled_colors(FRAME_PATH, keyboard)
        plan.append({
            "what": "keyboard",
            "part": "keyboard",
            "device": keyboard["device"],
            "args": ["--mode", "Direct", "--color", ",".join(colors)],
        })

    gpu = config.get("gpu", {})
    if "leds" in parts and gpu.get("enabled", True):
        color = reorder(adjust(
            resolve_source(gpu.get("source", "accent"), palette),
            float(gpu.get("saturation", 1.2)),
            float(gpu.get("brightness", 1.0)),
            gpu.get("gains", {}),
            float(gpu.get("saturation_floor", 1.0)),
            gpu.get("lightness", 0.5),
        ), gpu.get("order", "RGB"))
        plan.append({
            "what": "gpu",
            "part": "leds",
            "device": gpu["device"],
            "args": ["--mode", gpu.get("mode", "Static"), "--color", color],
        })

    argb = config.get("argb", {})
    if "leds" in parts and argb.get("enabled", True):
        for header in argb.get("headers", []):
            leds = int(header.get("leds", 0))
            if leds <= 0:
                continue
            color = reorder(adjust(
                resolve_source(header.get("source", "accent"), palette),
                float(argb.get("saturation", 1.2)),
                float(argb.get("brightness", 1.0)),
                argb.get("gains", {}),
                float(argb.get("saturation_floor", 1.0)),
                argb.get("lightness", 0.5),
            ), header.get("order", argb.get("order", "RGB")))
            plan.append({
                "what": f"argb header {header['zone']}",
                "part": "leds",
                "device": argb["device"],
                # --size before --color: a zone that is still 0 LEDs long has
                # nothing to colour.
                "args": [
                    "--zone", str(header["zone"]),
                    "--size", str(leds),
                    "--mode", argb.get("mode", "Direct"),
                    "--color", ",".join([color] * leds),
                ],
            })

    return plan


def run_plan(plan: list[dict], dry_run: bool) -> int:
    failures = 0
    devices = {} if dry_run else list_devices()
    for step in plan:
        if dry_run:
            printable = [a if len(a) < 70 else a[:67] + "..." for a in step["args"]]
            print(f"{step['what']}: openrgb --device {step['device']!r} {' '.join(printable)}")
            continue
        # none: not on this machine, or not plugged in right now
        results = [openrgb("--device", index, *step["args"]) for index in find_devices(step["device"], devices)]
        if results and all(result.returncode != 0 for result in results):
            failures += 1
            print(f"{step['what']} failed: {results[0].stderr.strip() or results[0].stdout.strip()}", file=sys.stderr)
    return failures


def load_state() -> dict[str, list[dict]]:
    """The saved steps by part."""
    try:
        payload = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    parts = payload.get("parts")
    if isinstance(parts, dict):
        return {part: steps for part, steps in parts.items() if isinstance(steps, list)}
    # the state of before the parts: one plan, the device among the arguments
    state: dict[str, list[dict]] = {}
    for step in payload.get("plan") or []:
        args = list(step.get("args") or [])
        if args[:1] != ["--device"] or len(args) < 2:
            continue
        part = "keyboard" if step.get("what") == "keyboard" else "leds"
        state.setdefault(part, []).append({"what": step.get("what", part), "part": part, "device": args[1], "args": args[2:]})
    return state


def save_state(plan: list[dict], parts: list[str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state = load_state()
    for part in parts:
        state[part] = [step for step in plan if step["part"] == part]
    payload = {"version": 2, "saved": time.time(), "parts": state}
    temporary = STATE_PATH.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload), encoding="utf-8")
    temporary.replace(STATE_PATH)


def parts_on() -> list[str]:
    hooks = host.hooks()
    return [part for part, hook in PARTS.items() if hook in hooks]


def light(parts: list[str], restore: bool, dry_run: bool = False) -> int:
    """Sends the parts' colours: the saved ones, or new ones from the theme."""
    LOCK_PATH.touch(exist_ok=True)
    with LOCK_PATH.open("w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not dry_run:
            ensure_server()

        plan: list[dict] = []
        missing = list(parts)
        if restore:
            state = load_state()
            missing = [part for part in parts if part not in state]
            for part in parts:
                plan += state.get(part, [])
        if missing:
            if "leds" in missing and not PALETTE_PATH.is_file():
                print(f"no palette at {PALETTE_PATH}", file=sys.stderr)
                return 2
            if "keyboard" in missing and not FRAME_PATH.is_file():
                print(f"no wallpaper frame at {FRAME_PATH}", file=sys.stderr)
            fresh = build_plan(load_config(), missing)
            if not dry_run:
                save_state(fresh, missing)
            plan += fresh
        return 1 if run_plan(plan, dry_run) else 0


# -------------------------------------------------------------------- watch ---

def keyboard_event(block: dict[str, str], name: str) -> bool:
    """Whether a udev event says the keyboard was plugged in."""
    if block.get("ACTION") != "add" or not block.get("DEVPATH"):
        return False
    try:
        uevent = Path("/sys" + block["DEVPATH"], "device", "uevent").read_text()
    except OSError:
        return False
    found = re.search(r"^HID_NAME=(.+)$", uevent, re.M)
    if not found:
        return False
    plugged, wanted = found.group(1).strip().lower(), name.strip().lower()
    return plugged in wanted or wanted in plugged


def watch() -> int:
    """Keeps the colours on: at the start when no server ran, and whenever the
    keyboard comes back (a KVM switch, a cable), since it comes back with the
    colours it has stored and the server still talks to the one that left."""
    if not parts_on():
        return 0
    if not server_listening():
        light(parts_on(), restore=True)

    name = load_config().get("keyboard", {}).get("device", "")
    monitor = subprocess.Popen(
        ["udevadm", "monitor", "--udev", "--property", "--subsystem-match=hidraw"],
        stdout=subprocess.PIPE,
    )
    channel = monitor.stdout.fileno()
    pending = b""
    block: dict[str, str] = {}
    due = 0.0
    while monitor.poll() is None:
        ready, _, _ = select.select([channel], [], [], 0.5)
        if ready:
            chunk = os.read(channel, 65536)
            if not chunk:
                break
            *lines, pending = (pending + chunk).split(b"\n")
            for line in (raw.decode("utf-8", "replace").strip() for raw in lines):
                if "=" in line:
                    key, _, value = line.partition("=")
                    block[key] = value
                    continue
                # the keyboard arrives as several interfaces: once they are all in
                if keyboard_event(block, name):
                    due = time.time() + 2.5
                block = {}
        elif due and time.time() >= due:
            due = 0.0
            parts = parts_on()
            if "keyboard" in parts:
                stop_server()
                light(parts, restore=True)
    return 1


# --------------------------------------------------------------------- main ---

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", nargs="?", type=Path,
                        help="wallpaper frame to project (default: the current theme's)")
    parser.add_argument("--restore", action="store_true",
                        help="re-apply the last saved state instead of recomputing")
    parser.add_argument("--only", choices=list(PARTS),
                        help="only this part (default: both, or with --restore the ones whose hook is on)")
    parser.add_argument("--watch", action="store_true",
                        help="stay and put the colours back when the keyboard is plugged in again")
    parser.add_argument("--wait", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--probe", nargs=2, metavar=("ZONE", "LEDS"), type=int,
                        help="light LEDS LEDs on an ARGB header so you can count them")
    parser.add_argument("--probe-order", metavar="ZONE", type=int,
                        help="paint a header in three blocks - intended red, green, blue - "
                             "so the order you actually see names its wiring")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    global FRAME_PATH
    if args.image is not None:
        FRAME_PATH = args.image.expanduser().resolve()

    config = load_config()

    if args.watch:
        return watch()
    if not args.dry_run and (args.probe or args.probe_order is not None):
        ensure_server()

    if args.probe_order is not None:
        zone = args.probe_order
        argb = config.get("argb", {})
        # Deliberately short. Spreading the three blocks over the configured
        # length hides two of them whenever the chain is shorter than that, and
        # the chain's real length is exactly what nobody knows. Twelve LEDs fit
        # inside a single fan, so all three colours are always on screen.
        leds = 12
        block = leds // 3
        blocks = ["FF0000"] * block + ["00FF00"] * block + ["0000FF"] * (leds - 2 * block)
        plan = [{
            "what": f"order probe header {zone}",
            "device": argb["device"],
            "args": [
                "--zone", str(zone),
                "--size", str(leds), "--mode", argb.get("mode", "Direct"),
                "--color", ",".join(blocks),
            ],
        }]
        print(f"header {zone}: first third sent as RED, middle as GREEN, last as BLUE")
        return 1 if run_plan(plan, args.dry_run) else 0

    if args.probe:
        zone, leds = args.probe
        argb = config.get("argb", {})
        plan = [{
            "what": f"probe header {zone}",
            "device": argb["device"],
            "args": [
                "--zone", str(zone),
                "--size", str(leds), "--mode", argb.get("mode", "Direct"),
                "--color", ",".join(["FF2000"] * max(1, leds)),
            ],
        }]
        return 1 if run_plan(plan, args.dry_run) else 0

    parts = [args.only] if args.only else (parts_on() if args.restore else list(PARTS))
    if not parts:
        print("nothing to light: both lighting hooks are off", file=sys.stderr)
        return 0
    return light(parts, args.restore, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
