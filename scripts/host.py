#!/usr/bin/env python3
"""The host profile for shell scripts, resolved exactly like core/services/Host.qml.

  host.py name              profile name (PSHELL_HOST, else hosts/machines.json)
  host.py has <feature>     exit 0 when the feature is on
  host.py get <key.path>    a value; strings plain, everything else as JSON
  host.py hooks             enabled theme hooks, one per line, in order
"""

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def profile_name():
    if os.environ.get("PSHELL_HOST"):
        return os.environ["PSHELL_HOST"]
    try:
        hostname = Path("/etc/hostname").read_text().strip()
    except OSError:
        hostname = os.uname().nodename
    return str(load(ROOT / "hosts" / "machines.json").get(hostname, ""))


def profile():
    name = profile_name()
    return load(ROOT / "hosts" / f"{name}.json") if name else {}


def lookup(data, key):
    for part in key.split("."):
        if not isinstance(data, dict) or part not in data:
            return None
        data = data[part]
    return data


def main(args):
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    command = args[0]
    if command == "name":
        print(profile_name())
        return 0
    if command == "has" and len(args) == 2:
        return 0 if lookup(profile(), f"features.{args[1]}") is True else 1
    if command == "get" and len(args) == 2:
        value = lookup(profile(), args[1])
        if value is None:
            return 1
        print(os.path.expanduser(value) if isinstance(value, str) else json.dumps(value))
        return 0
    if command == "hooks":
        for hook in profile().get("themeHooks", []):
            print(hook)
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
