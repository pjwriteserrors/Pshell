#!/usr/bin/env bash
# theme-hook: after-frame (reads THEME_FRAME)
# the wal colours and the shell's colour roles (style/theme/Theme.qml) as a
# marked block in BetterDiscord's custom.css, which dotfiles/betterdiscord/pshell.theme.css draws on
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
data_dir="$HOME/.config/BetterDiscord/data/stable"
[[ -d "$data_dir" ]] || skip "BetterDiscord not installed"
[[ -f "$WAL_CACHE_DIR/colors.css" ]] || skip "no colors.css"

exec python3 - "$data_dir/settings.json" "$data_dir/custom.css" "$WAL_CACHE_DIR" "$THEME_SCRIPTS_DIR" <<'PY'
import base64
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

settings_path, custom_path, wal_dir, scripts_dir = (Path(arg) for arg in sys.argv[1:5])
colors_path = wal_dir / "colors.css"


def shell_roles():
    """Theme.qml's roles, through the port spicetify uses."""
    spec = importlib.util.spec_from_file_location("pshell_spicetify", scripts_dir.parent / "dotfiles/spicetify/generate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    wal = json.loads((wal_dir / "colors.json").read_text())
    roles = module.derive(wal)
    dark = module.luminance(roles["bg"]) < 0.35
    names = ("bg", "fg", "primary", "secondary", "tertiary", "on-primary", "danger", "warning", "success")
    lines = [f"\t--pshell-{name}: #{roles[name].hex()};" for name in names]
    lines.append(f"\t--pshell-scheme: {'dark' if dark else 'light'};")
    lines.append(f"\t--pshell-shadow: rgba(0, 0, 0, {0.55 if dark else 0.28});")
    return lines


def window_radius():
    """niri's geometry-corner-radius, settings.kdl first (Theme.windowRadius)."""
    niri = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "niri"
    for name in ("settings.kdl", "config.kdl"):
        try:
            text = (niri / name).read_text()
        except OSError:
            continue
        text = re.sub(r"//.*$", "", re.sub(r"/\*[\s\S]*?\*/", "", text), flags=re.M)
        match = re.search(r"^\s*geometry-corner-radius\s+([\d.]+)", text, re.M)
        if match:
            return round(float(match.group(1)))
    return 7


def wallpaper():
    """the wallpaper's still frame, small, for the backdrop behind the panels"""
    frame = Path(os.environ.get("THEME_FRAME") or "")
    if not frame.is_file():
        match = re.search(r'--wallpaper:\s*url\("([^"]+)"\)', colors_path.read_text(errors="ignore"))
        frame = Path(match.group(1)) if match else Path()
    if not frame.is_file() or not shutil.which("magick"):
        return None
    result = subprocess.run(
        ["magick", str(frame), "-resize", "1280x1280>", "-strip", "-quality", "70", "jpg:-"],
        capture_output=True,
    )
    if result.returncode != 0 or not result.stdout:
        return None
    return "url(data:image/jpeg;base64," + base64.b64encode(result.stdout).decode() + ")"


try:
    roles = shell_roles()
except Exception as error:  # the wal colours alone still make a usable block
    print(f"shell roles unavailable: {error}", file=sys.stderr)
    roles = []
roles.append(f"\t--pshell-radius-window: {window_radius()}px;")
backdrop = wallpaper()
if backdrop:
    roles.append(f"\t--pshell-wallpaper: {backdrop};")

if settings_path.exists():
    data = json.loads(settings_path.read_text())
    customcss = data.setdefault("customcss", {})
    customcss["customcss"] = True
    customcss["liveUpdate"] = True
    settings_path.write_text(json.dumps(data, indent=4) + "\n")

# the shell's look, linked into the themes folder and switched on once (turning
# it off in BetterDiscord sticks; the state is read when Discord starts)
theme = scripts_dir.parent / "dotfiles/betterdiscord/pshell.theme.css"
theme_link = settings_path.parents[2] / "themes" / theme.name
if not theme_link.exists():
    theme_link.parent.mkdir(exist_ok=True)
    theme_link.unlink(missing_ok=True)
    theme_link.symlink_to(theme)
themes_path = settings_path.with_name("themes.json")
themes = json.loads(themes_path.read_text()) if themes_path.exists() else {}
if "Pshell" not in themes:
    themes["Pshell"] = True
    themes_path.write_text(json.dumps(themes, indent=4) + "\n")

start = "/* quickshell-wallust-colors:start */"
end = "/* quickshell-wallust-colors:end */"
existing = custom_path.read_text(errors="ignore") if custom_path.exists() else ""
block = "\n".join([
    start,
    "/* generated {} */".format(datetime.now().isoformat(timespec="seconds")),
    colors_path.read_text(errors="ignore").strip(),
    ":root {",
    *roles,
    "}",
    end,
])

if start in existing and end in existing:
    before, rest = existing.split(start, 1)
    _, after = rest.split(end, 1)
    output = before.rstrip() + "\n\n" + block + "\n" + after.lstrip()
else:
    output = existing.rstrip()
    if output:
        output += "\n\n"
    output += block + "\n"

# in place, so BetterDiscord keeps watching the same inode and reloads live
custom_path.write_text(output)
PY
