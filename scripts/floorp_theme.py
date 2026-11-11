#!/usr/bin/env python3
"""Puts the shell's look on Floorp, or takes it off again.

  floorp_theme.py install [--profile DIR] [--all]
  floorp_theme.py remove  [--profile DIR] [--all]
  floorp_theme.py settle  [--profile DIR] [--all]
  floorp_theme.py status

install links dotfiles/floorp/pshell.css into <profile>/chrome/CSS/, with
two sheets beside it that the shell keeps up to date: pshell-vars.css (the
shell's corner radius, type, spacing and motion, written by the shell into
~/.local/state/pshell/floorp/) and pshell-roles.css (the palette engine's
roles in ~/.cache/wal, used while the Pshell extension does not colour the
browser). Floorp's own CSS loader picks them up at the next start (or at
once with ☰ → userChrome CSS → Rebuild).

The layout needs a few of Floorp's settings: tabs in a rail on the left that
expands while the pointer rests on it (Firefox's own vertical tabs), tab
groups and the preview card of a tab, and Floorp's panel sidebar on the left
(its buttons at the foot of the rail, its panel between the rail and the page).
install writes them into a marked block of <profile>/user.js, after keeping
what the profile had (~/.local/state/pshell/floorp-prefs-backup.json). Once
Floorp has started with them and saved them, `settle` takes the block out
again, so they are ordinary settings that can be changed in Floorp as usual.
remove unlinks the sheets and writes the kept values back the same way.

install also lets the profile load the Pshell extension straight from the
repo: a proxy file <profile>/extensions/downloads@pshell naming
dotfiles/floorp/pshell, and the settings an unsigned extension in the
profile needs (signatures not required, extensions of the profile not
disabled on arrival, experiment APIs for its part in the browser window:
the rail's style from Settings › Browser › Tabs). An edit of the extension applies at Floorp's next start.
Nothing else of the profile is touched.

The colours come from the Pshell extension (dotfiles/floorp/pshell), which
sets them through the browser's theme as the wallpaper changes.
Without --profile the profile Floorp starts with is used.
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "dotfiles" / "floorp" / "pshell.css"
EXTENSION = ROOT / "dotfiles" / "floorp" / "pshell"
EXTENSION_ID = "downloads@pshell"
NAME = "pshell.css"
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "pshell"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
# sheets kept by others, linked beside pshell.css: name in chrome/CSS → where it lives
COMPANIONS = {
    # the shell's metrics (written by the shell, core/services)
    "pshell-vars.css": STATE / "floorp" / "pshell-vars.css",
    # the roles of the palette engine (scripts/palette/palette.py apply)
    "pshell-roles.css": CACHE / "wal" / "pshell-roles.css",
}
BACKUP = STATE / "floorp-prefs-backup.json"
FLOORP_DIRS = [Path.home() / ".config" / "floorp", Path.home() / ".floorp"]

# what the layout needs
PREFS: dict[str, object] = {
    # the tabs in a rail on the left, icons only until the pointer rests on it
    "sidebar.revamp": True,
    "sidebar.verticalTabs": True,
    "sidebar.position_start": True,
    "sidebar.visibility": "expand-on-hover",
    # opening and closing on the shell's long motion, after a short rest
    "sidebar.animation.enabled": True,
    "sidebar.animation.expand-on-hover.duration-ms": 300,
    "sidebar.animation.expand-on-hover.delay-duration-ms": 200,
    # resting on a tab shows its card
    "browser.tabs.hoverPreview.enabled": True,
    "browser.tabs.hoverPreview.showThumbnails": True,
    "browser.tabs.groups.enabled": True,
    # the Pshell extension, unsigned, from the profile's extensions folder
    "xpinstall.signatures.required": False,
    "extensions.autoDisableScopes": 14,
    # its part in the browser window (experiments/chrome.js: the rail's style)
    "extensions.experiments.enabled": True,
}
# Floorp keeps its panel sidebar's settings as JSON in one pref: these keys change
# (position_start false is the left with the tabs at the start; pshell.css puts
# its buttons under the rail and its panel beside it)
PANEL_PREF = "floorp.panelSidebar.config"
PANEL_KEYS = {"position_start": False}
# Firefox's defaults, for a pref the profile never had (its value is not in prefs.js)
DEFAULTS: dict[str, object] = {
    "sidebar.revamp": True,
    "sidebar.verticalTabs": False,
    "sidebar.position_start": True,
    "sidebar.visibility": "always-show",
    "sidebar.animation.enabled": True,
    "sidebar.animation.expand-on-hover.duration-ms": 400,
    "sidebar.animation.expand-on-hover.delay-duration-ms": 200,
    "browser.tabs.hoverPreview.enabled": True,
    "browser.tabs.hoverPreview.showThumbnails": True,
    "browser.tabs.groups.enabled": True,
    "xpinstall.signatures.required": True,
    "extensions.autoDisableScopes": 15,
    "extensions.experiments.enabled": False,
}
BEGIN = "// ── pshell: begin"
END = "// ── pshell: end"


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


# ── the sheets ───────────────────────────────────────────────────────────────
def target(profile: Path) -> Path:
    return profile / "chrome" / "CSS" / NAME


def ours(path: Path, source: Path = SOURCE) -> bool:
    return path.is_symlink() and path.resolve() == source.resolve()


def link_companions(profile: Path) -> None:
    for name, source in COMPANIONS.items():
        link = profile / "chrome" / "CSS" / name
        if ours(link, source):
            continue
        if link.exists() or link.is_symlink():
            print(f"{link} exists and is not ours; leaving it alone", file=sys.stderr)
            continue
        if not source.exists():
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("")
        link.symlink_to(source)
        print(f"linked {link}")


def unlink_companions(profile: Path) -> None:
    for name, source in COMPANIONS.items():
        link = profile / "chrome" / "CSS" / name
        if ours(link, source):
            link.unlink()
            print(f"removed {link}")


# ── the settings ─────────────────────────────────────────────────────────────
def js_value(value: object) -> str:
    return json.dumps(value)


def read_prefs(profile: Path) -> dict[str, object]:
    """What prefs.js holds (user_pref lines only)."""
    found: dict[str, object] = {}
    path = profile / "prefs.js"
    if not path.exists():
        return found
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r'\s*user_pref\("([^"]+)",\s*(.*)\);\s*$', line)
        if not match:
            continue
        try:
            found[match.group(1)] = json.loads(match.group(2))
        except ValueError:
            pass
    return found


def panel_value(current: object, keys: dict[str, object]) -> str:
    try:
        config = json.loads(current) if isinstance(current, str) else {}
    except ValueError:
        config = {}
    if not isinstance(config, dict):
        config = {}
    config.update(keys)
    return json.dumps(config, separators=(",", ":"))


def block_of(profile: Path) -> tuple[str, str, str]:
    """user.js split around our block: before, block, after."""
    path = profile / "user.js"
    text = path.read_text(errors="replace") if path.exists() else ""
    start = text.find(BEGIN)
    if start < 0:
        return text, "", ""
    end = text.find(END, start)
    end = len(text) if end < 0 else text.find("\n", end) + 1 or len(text)
    return text[:start], text[start:end], text[end:]


def write_block(profile: Path, values: dict[str, object], why: str) -> None:
    before, _, after = block_of(profile)
    lines = [f"{BEGIN} ({why}, {int(time.time())}); floorp_theme.py settle takes it out once Floorp has saved these"]
    lines += [f'user_pref("{key}", {js_value(value)});' for key, value in values.items()]
    lines.append(END)
    body = before.rstrip("\n")
    text = (body + "\n" if body else "") + "\n".join(lines) + "\n" + after.lstrip("\n")
    (profile / "user.js").write_text(text)
    print(f"  settings in {profile / 'user.js'} ({why}); restart Floorp")


def load_backup() -> dict:
    try:
        return json.loads(BACKUP.read_text())
    except (OSError, ValueError):
        return {}


def keep_previous(profile: Path) -> None:
    """What the profile had before the layout, once."""
    backup = load_backup()
    if str(profile) in backup:
        return
    current = read_prefs(profile)
    kept = {key: current.get(key) for key in PREFS}
    kept[PANEL_PREF] = current.get(PANEL_PREF)
    backup[str(profile)] = kept
    BACKUP.parent.mkdir(parents=True, exist_ok=True)
    BACKUP.write_text(json.dumps(backup, indent=2) + "\n")


def layout_values(profile: Path) -> dict[str, object]:
    values = dict(PREFS)
    values[PANEL_PREF] = panel_value(read_prefs(profile).get(PANEL_PREF), PANEL_KEYS)
    return values


def restore_values(profile: Path) -> dict[str, object]:
    kept = load_backup().get(str(profile), {})
    values: dict[str, object] = {}
    for key in PREFS:
        value = kept.get(key)
        values[key] = DEFAULTS.get(key) if value is None else value
    if kept.get(PANEL_PREF) is not None:
        values[PANEL_PREF] = kept[PANEL_PREF]
    return values


def settle(profile: Path) -> bool:
    """Takes the block out once Floorp has started with it and saved it."""
    before, block, after = block_of(profile)
    if not block:
        return True
    stamp = re.search(r"\((?:[^,]*), (\d+)\)", block)
    written = int(stamp.group(1)) if stamp else 0
    prefs = profile / "prefs.js"
    if not prefs.exists() or prefs.stat().st_mtime <= written:
        print(f"{profile}: waiting for Floorp to start with the settings")
        return False
    saved = read_prefs(profile)
    for line in block.splitlines():
        match = re.match(r'user_pref\("([^"]+)",\s*(.*)\);$', line)
        if not match:
            continue
        key, value = match.group(1), json.loads(match.group(2))
        # a value equal to Firefox's default is not saved at all
        if key in saved and saved[key] != value:
            print(f"{profile}: {key} is not saved yet")
            return False
    (profile / "user.js").write_text((before.rstrip("\n") + "\n" if before.strip() else "") + after.lstrip("\n"))
    if not (profile / "user.js").read_text().strip():
        (profile / "user.js").unlink()
    print(f"{profile}: settings settled")
    if "restore" in block:
        backup = load_backup()
        if backup.pop(str(profile), None) is not None:
            BACKUP.write_text(json.dumps(backup, indent=2) + "\n")
    return True


# ── the commands ─────────────────────────────────────────────────────────────
def install(profile: Path) -> bool:
    settle(profile)
    path = target(profile)
    if not ours(path):
        if path.exists() or path.is_symlink():
            print(f"{path} exists and is not ours; leaving it alone", file=sys.stderr)
            return False
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(SOURCE)
        print(f"linked {path}")
    else:
        print(f"already in {profile}")
    link_companions(profile)
    link_extension(profile)
    keep_previous(profile)
    values = layout_values(profile)
    saved = read_prefs(profile)
    if any(saved.get(key, DEFAULTS.get(key)) != value for key, value in values.items()):
        write_block(profile, values, "layout")
    if disabled_in(profile):
        print("  note: pshell.css is unticked in ☰ → userChrome CSS; tick it there")
    print("  restart Floorp, or ☰ → userChrome CSS → Rebuild")
    return True


def remove(profile: Path) -> bool:
    unlink_companions(profile)
    unlink_extension(profile)
    path = target(profile)
    if path.exists() or path.is_symlink():
        if not ours(path):
            print(f"{path} is not ours; leaving it alone", file=sys.stderr)
            return False
        path.unlink()
        print(f"removed {path}")
    else:
        print(f"not in {profile}")
    if str(profile) in load_backup():
        write_block(profile, restore_values(profile), "restore")
    print("  restart Floorp, or ☰ → userChrome CSS → Rebuild")
    return True


def extension_proxy(profile: Path) -> Path:
    return profile / "extensions" / EXTENSION_ID


def link_extension(profile: Path) -> None:
    """A proxy file: Firefox loads the extension from the folder it names."""
    proxy = extension_proxy(profile)
    if proxy.is_file() and proxy.read_text().strip() == str(EXTENSION):
        return
    packed = profile / "extensions" / f"{EXTENSION_ID}.xpi"
    if proxy.exists() or packed.exists():
        print(f"  the Pshell extension is installed otherwise ({proxy.name}); leaving it")
        return
    proxy.parent.mkdir(parents=True, exist_ok=True)
    proxy.write_text(str(EXTENSION) + "\n")
    print(f"linked {proxy} → {EXTENSION}")


def unlink_extension(profile: Path) -> None:
    proxy = extension_proxy(profile)
    if proxy.is_file() and proxy.read_text().strip() == str(EXTENSION):
        proxy.unlink()
        print(f"removed {proxy}")


def disabled_in(profile: Path) -> bool:
    """Floorp keeps the CSS files unticked in its menu in a pref."""
    value = read_prefs(profile).get("UserCSSLoader.disabled_list")
    return isinstance(value, str) and NAME in value


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
        if block_of(profile)[1]:
            state += ", settings waiting in user.js"
        mark = " (starts with Floorp)" if profile in default else ""
        print(f"{profile}{mark}: {state}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("install", "remove", "settle"):
        command = sub.add_parser(name)
        command.add_argument("--profile", type=Path, help="a Floorp profile directory")
        command.add_argument("--all", action="store_true", help="every Floorp profile")
    sub.add_parser("status")
    args = parser.parse_args()

    if args.command == "status":
        return status()
    chosen = [args.profile.expanduser().resolve()] if args.profile else profiles(args.all)
    if not chosen:
        print("no Floorp profile found (--profile DIR)", file=sys.stderr)
        return 1
    action = {"install": install, "remove": remove, "settle": settle}[args.command]
    results = [action(profile) for profile in chosen]
    return 0 if args.command == "settle" or all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
