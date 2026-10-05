#!/usr/bin/env python3
"""Sets the shell up on a machine and checks that everything it needs is there.

  setup.py install [--host PROFILE] [--dry-run] [--migrate-from DIR]
      links the dotfiles (dotfiles/manifest), maps this machine to a host
      profile, moves runtime state of the old ~/.config/quickshell/main over
      and enables the user services, then runs `doctor`.
  setup.py doctor
      programs, python modules, fonts, dotfiles and config the enabled
      plugins and theme hooks rely on. Exit 1 when something required is
      missing.
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOME = Path.home()
CONFIG_DIR = HOME / ".config" / "quickshell" / "shell"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local" / "state")) / "pshell"
OLD_SHELL = HOME / ".config" / "quickshell" / "main"
OLD_STATE_FILES = [
    "notes.json", "dnd.json", "updates.json", "launcher-usage.json", "launcher-ai-state.json",
    "todo-pins.json", "beautify-presets.json", "color-history.json", "rpg-state.json",
]

sys.path.insert(0, str(ROOT / "scripts"))
import host  # noqa: E402

# (program, why) per plugin; "core" is every machine
PROGRAMS = {
    "core": [
        ("quickshell", "the shell"), ("niri", "compositor"), ("python3", "scripts"),
        ("cliphist", "clipboard"), ("wl-copy", "clipboard"), ("wl-paste", "clipboard"),
        ("grim", "screenshots"), ("slurp", "recording"), ("wf-recorder", "recording"),
        ("magick", "screenshot editor"), ("tesseract", "OCR"), ("zbarimg", "QR codes"),
        ("ffmpeg", "wallpaper frames"), ("wallust", "colours"), ("swaybg", "wallpaper"),
        ("awww", "image wallpapers"), ("awww-daemon", "image wallpapers"), ("mpvpaper", "video wallpapers"),
        ("app2unit", "launching apps"), ("curl", "weather, updates"), ("nmcli", "network"),
        ("wpctl", "audio"), ("pactl", "audio"), ("cava", "media spectrum"),
        ("pacman", "updates"), ("yay", "AUR updates"), ("fakeroot", "update check"),
        ("kitty", "terminal for updates and SSH"), ("gio", "moving wallpapers to the trash"),
        ("notify-send", "failure notices"), ("gsettings", "GTK, icons, cursor"),
        ("flock", "theme scripts"), ("git", "style switching"),
    ],
    "song-detection": [("parec", "listening to what plays")],
    "backlight": [("brightnessctl", "screen brightness")],
    "ddc": [("ddcutil", "monitor brightness")],
    "power-profiles": [("powerprofilesctl", "power profiles")],
    "kdeconnect": [("kdeconnect-cli", "phone")],
    "phone": [("qrencode", "pairing code"), ("ip", "finding this PC's addresses")],
    "phone-keyboard": [("wtype", "typing from the phone")],
    "phone-presence": [("playerctl", "pausing when the phone leaves")],
    "fingerprint": [("fprintd-list", "fingerprint unlock")],
    "ssh": [("secret-tool", "SSH passwords")],
    "display-profiles": [("jq", "display profiles")],
    "microsoft-calendar": [("wl-copy", "sign-in code"), ("xdg-open", "sign-in page, joining meetings")],
}
OPTIONAL_PROGRAMS = [
    ("ollama", "launcher chat and >ollama"), ("pdftotext", "chat attachments"), ("pandoc", "chat attachments"),
    ("upower", "mouse battery"), ("qsb", "shader animation previews"),
    ("gst-inspect-1.0", "live pins (with gst-plugin-pipewire)"),
]
HOOK_PROGRAMS = {
    "kitty": [("kitty", "")], "pywalfox": [("pywalfox", "")], "telegram": [("wal-telegram", "")],
    "openrgb": [("openrgb", "")], "oomox": [("oomox-cli", ""), ("gtk-update-icon-cache", "")],
    "spicetify": [("spicetify", "")],
}
PYTHON_MODULES = {
    "core": [("numpy", "scrolling screenshots, live pins, song detection"), ("dbus", "bluetooth pairing, live pins"), ("gi", "bluetooth pairing, live pins")],
    "hook:openrgb": [("PIL", "lighting")],
}
# the phone daemon runs with the system's python, whatever `python3` is in the shell
PHONE_PYTHON = "/usr/bin/python3"
PHONE_MODULES = [("aiohttp", "the port phones talk to"), ("zeroconf", "being found on the LAN"), ("cryptography", "certificates"), ("PIL", "wallpaper for the app")]
OPTIONAL_MODULES = [("cv2", "smart select finds cards, fields and panels (python-opencv)")]
FONTS = [("Symbols Nerd Font", "icons"), ("Adwaita Sans", "text")]


class Report:
    def __init__(self):
        self.failures = 0

    def section(self, title):
        print(f"\n{title}")

    def ok(self, text):
        print(f"  ✓ {text}")

    def warn(self, text):
        print(f"  ! {text}")

    def fail(self, text):
        self.failures += 1
        print(f"  ✗ {text}")


def manifest_entries():
    for line in (ROOT / "dotfiles" / "manifest").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        mode, source, target, when = line.split()
        yield mode, ROOT / "dotfiles" / source, Path(os.path.expanduser(target)), when


def applies(when, profile_name, profile):
    if when == "all":
        return True
    kind, _, value = when.partition(":")
    if kind == "host":
        return value == profile_name
    if kind == "plugin":
        return host.plugins().get(value) is True
    if kind == "hook":
        return value in host.hooks()
    raise ValueError(f"unknown condition in dotfiles/manifest: {when}")


# Qt keeps its tools outside PATH; build_animation_preview.py looks here too
QT_TOOL_DIRS = ["/usr/lib/qt6/bin", "/usr/lib/qt/bin", "/usr/local/lib/qt6/bin"]


def installed(program):
    if shutil.which(program):
        return True
    return any(os.access(f"{d}/{program}", os.X_OK) for d in QT_TOOL_DIRS)


def module_available(name):
    return importlib.util.find_spec(name) is not None


def font_available(family):
    result = subprocess.run(["fc-list", family], capture_output=True, text=True)
    return bool(result.stdout.strip())


def doctor():
    report = Report()
    name = host.profile_name()
    profile = host.profile()

    report.section("Host")
    if not name:
        hostname = Path("/etc/hostname").read_text().strip()
        report.fail(f"{hostname} is not in hosts/machines.json (setup.py install --host <profile>)")
    elif not profile:
        report.fail(f"hosts/{name}.json is missing or not valid JSON")
    else:
        report.ok(f"profile {name}")

    if ROOT != CONFIG_DIR.resolve():
        report.warn(f"repository is at {ROOT}; `quickshell -c shell` expects {CONFIG_DIR}")

    report.section("Programs")
    before = report.failures
    plugins = ["core"] + [key for key, on in host.plugins().items() if on]
    for plugin in plugins:
        for program, why in PROGRAMS.get(plugin, []):
            if installed(program):
                continue
            label = why if plugin == "core" else f"{why} ({plugin})"
            report.fail(f"{program} – {label}")
    for program, why in OPTIONAL_PROGRAMS:
        if not installed(program):
            report.warn(f"{program} – {why}")
    if report.failures == before:
        report.ok("everything required is installed")

    report.section("Python modules")
    hooks = host.hooks()
    groups = ["core"] + [f"hook:{hook}" for hook in hooks]
    missing = [(module, why) for group in groups for module, why in PYTHON_MODULES.get(group, []) if not module_available(module)]
    for module, why in missing:
        report.fail(f"{module} – {why}")
    for module, why in OPTIONAL_MODULES:
        if not module_available(module):
            report.warn(f"{module} – {why}")
    if not missing:
        report.ok("all present")

    if "phone" in plugins:
        report.section("Phone app")
        before = report.failures
        for module, why in PHONE_MODULES + ([("evdev", "the touchpad")] if "phone-touchpad" in plugins else []):
            if subprocess.run([PHONE_PYTHON, "-c", f"import {module}"], capture_output=True).returncode != 0:
                report.fail(f"{module} for {PHONE_PYTHON} – {why}")
        if "phone-touchpad" in plugins:
            if not os.access("/dev/uinput", os.W_OK):
                report.fail("/dev/uinput is not writable – the touchpad (a udev rule or the input group)")
            config = Path(os.path.expanduser("~/.config/niri/config.kdl"))
            block = re.search(r"^\s*touchpad\s*\{(.*?)^\s*\}", config.read_text() if config.exists() else "", re.S | re.M)
            if block and re.search(r"^\s*off\b", block.group(1), re.M):
                report.warn("niri has `touchpad { off }` – it ignores the phone's touchpad as well")
        active = subprocess.run(["systemctl", "--user", "is-active", "pshell-phone.service"], capture_output=True, text=True).stdout.strip()
        if active != "active":
            report.fail("pshell-phone.service is not running (systemctl --user enable --now pshell-phone)")
        if report.failures == before:
            report.ok("daemon running, everything it needs is there")

    report.section("Fonts")
    for family, why in FONTS:
        (report.ok if font_available(family) else report.fail)(f"{family} – {why}")

    report.section("Theme")
    library = Path(os.path.expanduser(profile.get("wallpapers", "~/Pictures/Wallpapers")))
    if library.is_dir() and any(library.iterdir()):
        report.ok(f"wallpapers in {library}")
    else:
        report.fail(f"no wallpapers in {library}")
    for hook in hooks:
        script = ROOT / "scripts" / "theme-hooks" / f"{hook}.sh"
        if not script.exists():
            report.fail(f"theme hook {hook}: no {script.relative_to(ROOT)}")
            continue
        absent = [program for program, _ in HOOK_PROGRAMS.get(hook, []) if not installed(program)]
        config = profile.get("hookConfig", {}).get(hook, {})
        paths = [Path(os.path.expanduser(value)) for key, value in config.items() if key in ("generator", "script")]
        gone = [str(path) for path in paths if not path.exists()]
        if absent or gone:
            report.warn(f"theme hook {hook}: missing {', '.join(absent + gone)} (skipped when applying)")
        else:
            report.ok(f"theme hook {hook}")
    if "pywalfox" in hooks:
        state = subprocess.run([sys.executable, str(ROOT / "scripts" / "floorp_theme.py"), "status"],
                               capture_output=True, text=True).stdout
        started = next((line for line in state.splitlines() if "(starts with Floorp)" in line), "")
        if started.endswith(": installed"):
            report.ok("Floorp in the shell's look")
        elif started:
            report.warn("Floorp has its own look (scripts/floorp_theme.py install for the shell's)")

    report.section("Dotfiles")
    before = report.failures
    for mode, source, target, when in manifest_entries():
        if not applies(when, name, profile):
            continue
        if mode == "link" and not (target.is_symlink() and target.resolve() == source.resolve()):
            report.fail(f"{target} is not linked to {source.relative_to(ROOT)}")
        elif mode == "seed" and not target.exists():
            report.fail(f"{target} does not exist")
    if report.failures == before:
        report.ok("linked")

    report.section("niri")
    niri_config = HOME / ".config" / "niri" / "config.kdl"
    text = niri_config.read_text() if niri_config.exists() else ""
    if 'include "pshell.kdl"' in text:
        report.ok("config.kdl includes pshell.kdl")
    else:
        report.fail('add `include "pshell.kdl"` to ~/.config/niri/config.kdl')
    for stale in ('"quickshell -c main"', '"-c" "main"', "qs -c main"):
        if stale in text:
            report.fail(f"config.kdl still starts or calls the old shell ({stale})")
            break

    print()
    if report.failures:
        print(f"{report.failures} problem(s)")
        return 1
    print("all good")
    return 0


def link(source, target, dry_run):
    if target.is_symlink() and target.resolve() == source.resolve():
        return
    if target.exists() or target.is_symlink():
        backup = target.with_name(f"{target.name}.pre-pshell-{datetime.date.today():%Y%m%d}")
        print(f"  backup {target} → {backup.name}")
        if not dry_run:
            target.rename(backup)
    print(f"  link   {target}")
    if not dry_run:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(source)


def install(profile_arg, dry_run, old_shell=OLD_SHELL):
    hostname = Path("/etc/hostname").read_text().strip()
    machines_path = ROOT / "hosts" / "machines.json"
    machines = json.loads(machines_path.read_text())

    if profile_arg:
        if not (ROOT / "hosts" / f"{profile_arg}.json").exists():
            print(f"no hosts/{profile_arg}.json", file=sys.stderr)
            return 1
        if machines.get(hostname) != profile_arg:
            print(f"map {hostname} → {profile_arg} in hosts/machines.json")
            machines[hostname] = profile_arg
            if not dry_run:
                machines_path.write_text(json.dumps(machines, indent="\t") + "\n")
    elif hostname not in machines:
        print(f"{hostname} has no profile yet: setup.py install --host <profile>", file=sys.stderr)
        return 1

    name = profile_arg or machines[hostname]
    profile = json.loads((ROOT / "hosts" / f"{name}.json").read_text())

    if ROOT != CONFIG_DIR.resolve() and not CONFIG_DIR.exists():
        print(f"link   {CONFIG_DIR} → {ROOT}")
        if not dry_run:
            CONFIG_DIR.symlink_to(ROOT)

    print("dotfiles")
    for mode, source, target, when in manifest_entries():
        if not applies(when, name, profile):
            continue
        if mode == "link":
            link(source, target, dry_run)
        elif mode == "seed" and not target.exists():
            print(f"  seed   {target}")
            if not dry_run:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)

    moved = [file for file in OLD_STATE_FILES if (old_shell / file).exists() and not (STATE_DIR / file).exists()]
    if moved:
        print(f"state from {old_shell}")
        for file in moved:
            print(f"  copy   {file}")
            if not dry_run:
                STATE_DIR.mkdir(parents=True, exist_ok=True)
                shutil.copy2(old_shell / file, STATE_DIR / file)

    units = [target.name for mode, _, target, when in manifest_entries()
             if target.suffix == ".service" and applies(when, name, profile)]
    if units and not dry_run:
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=False)
        subprocess.run(["systemctl", "--user", "enable", "--now", *units], check=False)
    for unit in units:
        print(f"enable {unit}")

    print()
    return doctor()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    install_parser = sub.add_parser("install")
    install_parser.add_argument("--host", default="")
    install_parser.add_argument("--dry-run", action="store_true")
    install_parser.add_argument("--migrate-from", type=Path, default=OLD_SHELL,
                                help="old shell directory whose state files move over")
    sub.add_parser("doctor")
    args = parser.parse_args()
    if args.command == "install":
        return install(args.host, args.dry_run, args.migrate_from.expanduser())
    return doctor()


if __name__ == "__main__":
    sys.exit(main())
