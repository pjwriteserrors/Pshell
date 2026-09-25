#!/usr/bin/env bash
# the wal colours as a marked block in BetterDiscord's custom.css
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
data_dir="$HOME/.config/BetterDiscord/data/stable"
[[ -d "$data_dir" ]] || skip "BetterDiscord not installed"
[[ -f "$WAL_CACHE_DIR/colors.css" ]] || skip "no colors.css"

exec python3 - "$data_dir/settings.json" "$data_dir/custom.css" "$WAL_CACHE_DIR/colors.css" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

settings_path, custom_path, colors_path = (Path(arg) for arg in sys.argv[1:4])

if settings_path.exists():
    data = json.loads(settings_path.read_text())
    customcss = data.setdefault("customcss", {})
    customcss["customcss"] = True
    customcss["liveUpdate"] = True
    settings_path.write_text(json.dumps(data, indent=4) + "\n")

start = "/* quickshell-wallust-colors:start */"
end = "/* quickshell-wallust-colors:end */"
existing = custom_path.read_text(errors="ignore") if custom_path.exists() else ""
block = "\n".join([
    start,
    "/* generated {} */".format(datetime.now().isoformat(timespec="seconds")),
    colors_path.read_text(errors="ignore").strip(),
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
