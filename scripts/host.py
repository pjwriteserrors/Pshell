#!/usr/bin/env python3
"""The host profile for shell scripts, resolved exactly like core/services/Host.qml.

  host.py name              profile name (PSHELL_HOST, else hosts/machines.json)
  host.py has <plugin>      exit 0 when the plugin is on
  host.py plugins           the plugins that are on, one per line
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


def state_dir():
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "pshell"


def plugins():
    """Every plugin's state, resolved exactly like core/services/Plugins.qml."""
    registry = load(ROOT / "core" / "plugins.json") or []
    by_id = {plugin["id"]: plugin for plugin in registry}
    defaults = profile().get("plugins", {})
    switches = load(state_dir() / "plugins.json")
    if not isinstance(switches, dict):
        switches = {}
    state = {}

    def wanted(plugin):
        for source in (switches, defaults):
            if plugin["id"] in source:
                return source[plugin["id"]] is True
        return plugin.get("default") is not False

    def resolve(name):
        if name not in state:
            plugin = by_id.get(name)
            state[name] = False
            if plugin:
                state[name] = wanted(plugin) and all(resolve(required) for required in plugin.get("requires", []))
        return state[name]

    for name in by_id:
        resolve(name)
    return state


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
        return 0 if plugins().get(args[1]) is True else 1
    if command == "plugins":
        for name, on in plugins().items():
            if on:
                print(name)
        return 0
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
