#!/usr/bin/env python3
"""Cuts out what is in front of a picture with rembg, inside the viewer's
own venv (viewer.py cutoutinstall makes it).

    cutout_worker.py IN OUT     writes OUT, a grey mask the size of IN

Tells how far it is as lines of JSON, `{"value": 0..1, "text": ...}`. The
model (isnet-general-use) is downloaded into $U2NET_HOME the first time.
"""
import json
import os
import sys

MODEL = "isnet-general-use"


def say(value, text):
    print(json.dumps({"value": value, "text": text}), flush=True)


def main(source, target):
    from PIL import Image, ImageOps
    home = os.environ.get("U2NET_HOME") or os.path.expanduser("~/.u2net")
    os.makedirs(home, exist_ok=True)
    if os.path.exists(os.path.join(home, MODEL + ".onnx")):
        say(0.1, "Loading the model")
    else:
        say(0.1, "Downloading the model (about 180 MB, once)")
    from rembg import new_session, remove
    session = new_session(MODEL)
    say(0.5, "Finding what is in front")
    image = ImageOps.exif_transpose(Image.open(source)).convert("RGB")
    mask = remove(image, session=session, only_mask=True, post_process_mask=True)
    if mask.mode != "L":
        mask = mask.convert("L")
    say(0.95, "Saving the mask")
    mask.save(target, "PNG")
    say(1, "Done")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: cutout_worker.py IN OUT", file=sys.stderr)
        sys.exit(2)
    try:
        main(sys.argv[1], sys.argv[2])
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
