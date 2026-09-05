#!/usr/bin/env bash

set -euo pipefail

python3 - <<'PY'
import configparser
import json
import re
import subprocess
import sys
from pathlib import Path

firefox_dir = Path.home() / ".mozilla/firefox"
profiles_ini = firefox_dir / "profiles.ini"

if not profiles_ini.exists():
    raise SystemExit("Firefox profiles.ini not found")

pattern = re.compile(r'user_pref\("extensions\.webextensions\.uuids",\s*(.*)\);')

config = configparser.ConfigParser()
config.read(profiles_ini)


def profile_from_path(path, is_relative=True):
    if not path:
        return None
    return firefox_dir / path if is_relative else Path(path)


def pywalfox_uuid(profile_path):
    prefs_path = profile_path / "prefs.js"
    if not prefs_path.exists():
        return None

    for line in prefs_path.read_text(errors="ignore").splitlines():
        match = pattern.match(line)
        if not match:
            continue
        raw = json.loads(match.group(1))
        data = json.loads(raw)
        return data.get("pywalfox@frewacom.org")

    return None


candidates = []

for section in config.sections():
    if section.startswith("Install"):
        profile = profile_from_path(config.get(section, "Default", fallback=""))
        if profile:
            candidates.append(profile)

for section in config.sections():
    if not section.startswith("Profile"):
        continue
    if config.get(section, "Default", fallback="0") != "1":
        continue
    profile = profile_from_path(
        config.get(section, "Path", fallback=""),
        config.get(section, "IsRelative", fallback="1") == "1",
    )
    if profile:
        candidates.append(profile)

for section in config.sections():
    if not section.startswith("Profile"):
        continue
    profile = profile_from_path(
        config.get(section, "Path", fallback=""),
        config.get(section, "IsRelative", fallback="1") == "1",
    )
    if profile:
        candidates.append(profile)

seen = set()
for profile_path in candidates:
    key = str(profile_path)
    if key in seen:
        continue
    seen.add(key)
    uuid = pywalfox_uuid(profile_path)
    if uuid:
        break
else:
    raise SystemExit("Pywalfox extension UUID not found in Firefox profiles")

url = f"moz-extension://{uuid}/ui/settings.html"
subprocess.Popen(["firefox", "--new-tab", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
