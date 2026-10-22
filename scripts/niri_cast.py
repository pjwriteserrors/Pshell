"""What every cast of niri's org.gnome.Mutter.ScreenCast needs: the formats
GStreamer can import (scripts/lighting_live.py mirrors a screen,
scripts/window_shots.py pictures windows for the switcher)."""

from __future__ import annotations

import json
import subprocess

CAST = "org.gnome.Mutter.ScreenCast"

# DRM fourccs GStreamer names the formats of a cast by
FOURCCS = {"BGRx": "XR24", "BGRA": "AR24", "RGBx": "XB24", "RGBA": "AB24", "xRGB": "BX24", "xBGR": "RX24"}


def plain_modifiers(node: int) -> list[str]:
    """The cast's formats GL can import, best first.

    A compressed modifier (AMD's DCC, Intel's CCS) carries its metadata in
    extra planes that GStreamer does not hand to EGL, so the import fails with
    EGL_BAD_MATCH. niri prefers exactly those; they are left out here, and the
    tiled ones without compression stay ahead of linear.
    """
    try:
        dump = json.loads(subprocess.run(["pw-dump", str(node)], capture_output=True, text=True, timeout=5).stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return []
    out = []
    for item in dump:
        if item.get("id") != node:
            continue
        for param in (item.get("info", {}).get("params", {}).get("EnumFormat") or []):
            fourcc = FOURCCS.get(param.get("format"))
            modifiers = param.get("modifier")
            if not fourcc or modifiers is None:
                continue
            if isinstance(modifiers, dict):
                modifiers = [modifiers.get("default"), *[v for k, v in modifiers.items() if k.startswith("alt")]]
            elif not isinstance(modifiers, list):
                modifiers = [modifiers]
            for modifier in modifiers:
                # DRM_FORMAT_MOD_INVALID: "whatever the driver likes", which is DCC again
                if not isinstance(modifier, int) or modifier < 0 or modifier == (1 << 56) - 1:
                    continue
                vendor = modifier >> 56
                if vendor == 0x02 and modifier & (1 << 13):          # AMD, DCC
                    continue
                if vendor == 0x01 and (modifier & 0xFF) not in (1, 2, 3, 9):  # Intel CCS and friends
                    continue
                name = fourcc if modifier == 0 else f"{fourcc}:0x{modifier:016x}"
                if name not in out:
                    out.append(name)
    out.sort(key=lambda name: ":" not in name)
    return out
