#!/usr/bin/env python3
"""Put the wallpaper's colours on the hardware: keyboard, GPU, ARGB headers.

    apply_lighting.py                 derive everything from the current theme
    apply_lighting.py --restore       re-apply the last state (used at login)
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

Device roles, gains and the LED count of each ARGB header live in
lighting.json next to the shell, because only the person with the case open
knows how many LEDs are on a header.
"""

from __future__ import annotations

import argparse
import colorsys
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from PIL import Image, ImageEnhance, ImageOps


NA = -1
MATRIX_WIDTH = 22
MATRIX_HEIGHT = 6
LED_COUNT = 112

SHELL_DIR = Path(__file__).resolve().parent.parent
CONFIG_PATH = SHELL_DIR / "lighting.json"
STATE_DIR = Path(os.environ.get("THEME_STATE_DIR", Path.home() / ".local/state/quickshell-theme"))
STATE_PATH = STATE_DIR / "lighting-state.json"
FRAME_PATH = STATE_DIR / "current" / "frame.png"
PALETTE_PATH = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "wal" / "colors.json"
LOCK_PATH = Path("/tmp/openrgb-lighting.lock")

SERVER = os.environ.get("OPENRGB_SERVER", "127.0.0.1:6742")

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


def sampled_colors(image_path: Path, settings: dict) -> list[str]:
    with Image.open(image_path) as source:
        source.seek(0)
        rgba = source.convert("RGBA")
        background = Image.new("RGBA", rgba.size, (0, 0, 0, 255))
        image = Image.alpha_composite(background, rgba).convert("RGB")

    # Keep the full-resolution source until the final projection. Reducing only
    # once avoids throwing away detail before it reaches the keyboard matrix.
    image = ImageOps.fit(
        image,
        (MATRIX_WIDTH, MATRIX_HEIGHT),
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )
    image = ImageEnhance.Color(image).enhance(float(settings.get("saturation", 1.35)))
    image = ImageEnhance.Brightness(image).enhance(float(settings.get("brightness", 0.95)))
    image = ImageEnhance.Contrast(image).enhance(float(settings.get("contrast", 1.45)))
    image = ImageEnhance.Sharpness(image).enhance(float(settings.get("sharpness", 2.0)))

    colors = ["000000"] * LED_COUNT
    matrix = keyboard_matrix(settings.get("layout", "us-tkl"))
    pixels = image.load()
    for row in range(MATRIX_HEIGHT):
        for column in range(MATRIX_WIDTH):
            led = matrix[row][column]
            if led == NA:
                continue
            red, green, blue = pixels[column, row]
            colors[led] = f"{red:02X}{green:02X}{blue:02X}"
    return colors


# ------------------------------------------------------------------ openrgb ---

def openrgb(*args: str, timeout: float = 35) -> subprocess.CompletedProcess:
    command = ["openrgb", "--client", SERVER, *args]
    return subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=False)


def wait_for_server(attempts: int = 60, delay: float = 1.0) -> bool:
    """A login restore races the OpenRGB server's own startup and detection."""
    for _ in range(attempts):
        result = openrgb("--list-devices", timeout=15)
        if result.returncode == 0 and result.stdout.strip():
            return True
        time.sleep(delay)
    return False


def build_plan(config: dict) -> list[dict]:
    """The exact set of openrgb invocations, as data so it can be saved."""
    plan: list[dict] = []
    palette = load_palette()

    keyboard = config.get("keyboard", {})
    if keyboard.get("enabled", True) and FRAME_PATH.is_file():
        colors = sampled_colors(FRAME_PATH, keyboard)
        plan.append({
            "what": "keyboard",
            "args": ["--device", keyboard["device"], "--mode", "Direct", "--color", ",".join(colors)],
        })

    gpu = config.get("gpu", {})
    if gpu.get("enabled", True):
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
            "args": ["--device", gpu["device"], "--mode", gpu.get("mode", "Static"), "--color", color],
        })

    argb = config.get("argb", {})
    if argb.get("enabled", True):
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
                # --size before --color: a zone that is still 0 LEDs long has
                # nothing to colour.
                "args": [
                    "--device", argb["device"],
                    "--zone", str(header["zone"]),
                    "--size", str(leds),
                    "--mode", argb.get("mode", "Direct"),
                    "--color", ",".join([color] * leds),
                ],
            })

    return plan


def run_plan(plan: list[dict], dry_run: bool) -> int:
    failures = 0
    for step in plan:
        if dry_run:
            printable = [a if len(a) < 70 else a[:67] + "..." for a in step["args"]]
            print(f"{step['what']}: openrgb {' '.join(printable)}")
            continue
        result = openrgb(*step["args"])
        if result.returncode != 0:
            failures += 1
            print(f"{step['what']} failed: {result.stderr.strip() or result.stdout.strip()}", file=sys.stderr)
    return failures


def save_state(plan: list[dict]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {"version": 1, "saved": time.time(), "plan": plan}
    temporary = STATE_PATH.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload), encoding="utf-8")
    temporary.replace(STATE_PATH)


def load_state() -> list[dict] | None:
    try:
        payload = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    plan = payload.get("plan")
    return plan if isinstance(plan, list) and plan else None


# --------------------------------------------------------------------- main ---

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", nargs="?", type=Path,
                        help="wallpaper frame to project (default: the current theme's)")
    parser.add_argument("--restore", action="store_true",
                        help="re-apply the last saved state instead of recomputing")
    parser.add_argument("--wait", action="store_true",
                        help="wait for the OpenRGB server to answer first")
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

    if args.wait and not args.dry_run and not wait_for_server():
        print("OpenRGB server did not answer", file=sys.stderr)
        return 1

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
            "args": [
                "--device", argb["device"], "--zone", str(zone),
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
            "args": [
                "--device", argb["device"], "--zone", str(zone),
                "--size", str(leds), "--mode", argb.get("mode", "Direct"),
                "--color", ",".join(["FF2000"] * max(1, leds)),
            ],
        }]
        return 1 if run_plan(plan, args.dry_run) else 0

    LOCK_PATH.touch(exist_ok=True)
    with LOCK_PATH.open("w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)

        plan = None
        if args.restore:
            plan = load_state()
            if plan is None:
                print("no saved lighting state; deriving it from the current theme", file=sys.stderr)

        if plan is None:
            if not FRAME_PATH.is_file():
                print(f"no wallpaper frame at {FRAME_PATH}", file=sys.stderr)
            if not PALETTE_PATH.is_file():
                print(f"no palette at {PALETTE_PATH}", file=sys.stderr)
                return 2
            plan = build_plan(config)
            if not args.dry_run:
                save_state(plan)

        if not plan:
            print("nothing to light: every device is disabled or unconfigured", file=sys.stderr)
            return 0

        return 1 if run_plan(plan, args.dry_run) else 0


if __name__ == "__main__":
    raise SystemExit(main())
