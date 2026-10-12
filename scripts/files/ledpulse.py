#!/usr/bin/env python3
"""ledpulse.py [hex colour] – the keyboard breathes twice in a colour, then
shows what it showed before (the file manager: a long job is through while
you are elsewhere). Without an OpenRGB server, or with the keyboard mirroring
the screen live, nothing happens.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import openrgb_sdk  # noqa: E402

KEYBOARD = 5


def main():
    colour = (sys.argv[1] if len(sys.argv) > 1 else "#5fd38d").lstrip("#")
    red, green, blue = (int(colour[i:i + 2], 16) for i in (0, 2, 4))
    try:
        client = openrgb_sdk.Client(name="pshell files")
    except OSError:
        return 0
    try:
        keyboards = [device for device in openrgb_sdk.unique(client.devices()) if device.type == KEYBOARD and device.leds > 0]
        if not keyboards:
            return 0
        before = {device.index: device.colors for device in keyboards}
        for _ in range(2):
            for step in list(range(0, 11)) + list(range(10, -1, -1)):
                share = step / 10
                for device in keyboards:
                    frame = bytes(int(value * share + base * (1 - share)) for base_rgb in [device.colors] for i in range(device.leds)
                                  for value, base in zip((red, green, blue), base_rgb[i * 3:i * 3 + 3] or b"\x00\x00\x00"))
                    client.update_leds(device, frame)
                time.sleep(0.03)
        for device in keyboards:
            if before.get(device.index):
                client.update_leds(device, before[device.index])
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
