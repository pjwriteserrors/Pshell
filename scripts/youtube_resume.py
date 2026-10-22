#!/usr/bin/env python3
"""Packs the YouTube resume extension (dotfiles/floorp/youtube-resume).

  youtube_resume.py pack       writes ~/.local/state/pshell/pshell-youtube-resume.xpi
  youtube_resume.py install    packs it and hands it to Floorp, which asks once

The extension needs nothing from the shell: it keeps how far every video was
watched in the browser's own extension storage. It is not signed: Floorp
installs it once xpinstall.signatures.required is false in about:config.
"""

import subprocess
import sys
import zipfile
from pathlib import Path

import host

ROOT = Path(__file__).resolve().parent.parent
EXTENSION = ROOT / "dotfiles" / "floorp" / "youtube-resume"
PACKAGE = host.state_dir() / "pshell-youtube-resume.xpi"


def pack():
    PACKAGE.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(PACKAGE, "w", zipfile.ZIP_DEFLATED) as package:
        for file in sorted(EXTENSION.iterdir()):
            package.write(file, file.name)
    print(f"extension: {PACKAGE}")
    return 0


def install():
    pack()
    subprocess.Popen(["floorp", str(PACKAGE)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    print("Floorp asks to add it")
    return 0


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "pack":
        sys.exit(pack())
    if command == "install":
        sys.exit(install())
    print(__doc__.strip())
    sys.exit(2)
