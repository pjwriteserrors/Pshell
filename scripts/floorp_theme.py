#!/usr/bin/env python3
"""Puts the shell's look on Floorp, or takes it off again.

  floorp_theme.py install [--profile DIR] [--all]
  floorp_theme.py remove  [--profile DIR] [--all]
  floorp_theme.py status

install links dotfiles/floorp/pshell.css into <profile>/chrome/CSS/, where
Floorp's own CSS loader picks it up at the next start (or at once with
☰ → userChrome CSS → Rebuild). Nothing of the profile is changed or replaced:
userChrome.css, userContent.css and every pref stay as they are, so remove
(or unticking pshell.css in that menu) brings back exactly the previous look.

The colours come from Pywalfox; keep the pywalfox theme hook enabled.
Without --profile the profile Floorp starts with is used.
"""

from __future__ import annotations

import argparse
import configparser
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "dotfiles" / "floorp" / "pshell.css"
NAME = "pshell.css"
FLOORP_DIRS = [Path.home() / ".config" / "floorp", Path.home() / ".floorp"]


def profiles(all_profiles: bool) -> list[Path]:
    """The profile Floorp starts with, or every profile."""
    found: list[Path] = []
    for base in FLOORP_DIRS:
        ini_path = base / "profiles.ini"
        if not ini_path.exists():
            continue
        ini = configparser.ConfigParser(strict=False, interpolation=None)
        ini.read(ini_path)

        def resolve(section: str) -> Path:
            # an absolute path stays absolute under pathlib's `/`
            return base / ini[section]["Path"]

        if all_profiles:
            found += [resolve(s) for s in ini.sections() if s.startswith("Profile")]
            continue
        # the install section names the profile this Floorp build starts with
        install = [s for s in ini.sections() if s.startswith("Install") and "Default" in ini[s]]
        if install:
            found.append(base / ini[install[0]]["Default"])
            continue
        default = [s for s in ini.sections() if s.startswith("Profile") and ini[s].get("Default") == "1"]
        if default:
            found.append(resolve(default[0]))
    return [path for path in dict.fromkeys(found) if path.is_dir()]


def target(profile: Path) -> Path:
    return profile / "chrome" / "CSS" / NAME


def ours(path: Path) -> bool:
    return path.is_symlink() and path.resolve() == SOURCE.resolve()


def install(profile: Path) -> bool:
    path = target(profile)
    if ours(path):
        print(f"already in {profile}")
        return True
    if path.exists() or path.is_symlink():
        print(f"{path} exists and is not ours; leaving it alone", file=sys.stderr)
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to(SOURCE)
    print(f"linked {path}")
    disabled = disabled_in(profile)
    if disabled:
        print("  note: pshell.css is unticked in ☰ → userChrome CSS; tick it there")
    print("  restart Floorp, or ☰ → userChrome CSS → Rebuild")
    return True


def remove(profile: Path) -> bool:
    path = target(profile)
    if not (path.exists() or path.is_symlink()):
        print(f"not in {profile}")
        return True
    if not ours(path):
        print(f"{path} is not ours; leaving it alone", file=sys.stderr)
        return False
    path.unlink()
    print(f"removed {path}")
    print("  restart Floorp, or ☰ → userChrome CSS → Rebuild")
    return True


def disabled_in(profile: Path) -> bool:
    """Floorp keeps the CSS files unticked in its menu in a pref."""
    prefs = profile / "prefs.js"
    if not prefs.exists():
        return False
    for line in prefs.read_text(errors="replace").splitlines():
        if '"UserCSSLoader.disabled_list"' in line and NAME in line:
            return True
    return False


def status() -> int:
    found = profiles(all_profiles=True)
    if not found:
        print("no Floorp profile found")
        return 1
    default = set(profiles(all_profiles=False))
    for profile in found:
        path = target(profile)
        if ours(path):
            state = "installed (unticked in Floorp)" if disabled_in(profile) else "installed"
        elif path.exists() or path.is_symlink():
            state = f"a different {NAME} is there"
        else:
            state = "not installed"
        mark = " (starts with Floorp)" if profile in default else ""
        print(f"{profile}{mark}: {state}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("install", "remove"):
        command = sub.add_parser(name)
        command.add_argument("--profile", type=Path, help="a Floorp profile directory")
        command.add_argument("--all", action="store_true", help="every Floorp profile")
    sub.add_parser("status")
    args = parser.parse_args()

    if args.command == "status":
        return status()
    chosen = [args.profile.expanduser()] if args.profile else profiles(args.all)
    if not chosen:
        print("no Floorp profile found (--profile DIR)", file=sys.stderr)
        return 1
    action = install if args.command == "install" else remove
    return 0 if all([action(profile) for profile in chosen]) else 1


if __name__ == "__main__":
    sys.exit(main())
