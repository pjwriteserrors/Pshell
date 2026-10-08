#!/usr/bin/env python3
"""Display setups for the launcher's >setup view.

  display_setup.py list            -> JSON: the saved setups with their monitor
                                      geometry, the active one and the live outputs
  display_setup.py live <json>     -> applies outputs right away (until niri reloads)
  display_setup.py save <name> <json> -> writes the outputs as a setup
  display_setup.py delete <name>   -> removes a saved setup, hides a built-in one
  display_setup.py activate <file> <name> -> makes a setup the active one
                                      (display-profile.kdl): its monitors take
                                      the setup's arrangement and keep the rest
                                      of what they had (VRR, hot corners, …)

Built-in setups live in scripts/display-profiles, saved ones in
$XDG_STATE_HOME/pshell/display-profiles and win over built-ins of the same
name. display_profile.sh applies either.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

BUILTIN = Path(__file__).resolve().parent / "display-profiles"
SAVED = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "pshell" / "display-profiles"
ACTIVE = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "niri" / "display-profile.kdl"

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$")
# niri msg -j spells transforms differently than the config
TRANSFORMS = {
    "Normal": "normal", "90": "90", "180": "180", "270": "270",
    "Flipped": "flipped", "Flipped90": "flipped-90", "Flipped180": "flipped-180", "Flipped270": "flipped-270",
}


def blocks(text):
    """Top-level KDL nodes as (head, body lines, raw text); comments outside nodes are dropped."""
    result, depth, head, body, raw = [], 0, "", [], []
    for line in text.splitlines():
        stripped = line.strip()
        if depth == 0:
            if not stripped or stripped.startswith("//"):
                continue
            head, body, raw = stripped, [], [line]
        else:
            raw.append(line)
            if depth == 1 and stripped and stripped != "}":
                body.append(stripped)
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            depth = 0
            result.append((head, body, "\n".join(raw)))
    return result


def parse(path):
    outputs, rules = [], []
    for head, body, raw in blocks(path.read_text()):
        match = re.match(r'output\s+"([^"]+)"', head)
        if not match:
            rules.append(raw)
            continue
        output = {"name": match.group(1), "x": 0, "y": 0, "scale": 1.0, "transform": "normal", "mode": "", "off": False}
        for line in body:
            if m := re.match(r'mode\s+"([^"]+)"', line):
                output["mode"] = m.group(1)
            elif m := re.match(r"position\s+x=(-?\d+)\s+y=(-?\d+)", line):
                output["x"], output["y"] = int(m.group(1)), int(m.group(2))
            elif m := re.match(r"scale\s+([\d.]+)", line):
                output["scale"] = float(m.group(1))
            elif m := re.match(r'transform\s+"([^"]+)"', line):
                output["transform"] = m.group(1)
            elif line == "off":
                output["off"] = True
        outputs.append(output)
    return outputs, rules


def live():
    try:
        raw = subprocess.run(["niri", "msg", "-j", "outputs"], capture_output=True, text=True, timeout=5).stdout
        data = json.loads(raw)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return []
    result = []
    for output in data.values():
        current_mode = output.get("current_mode")
        mode = output["modes"][current_mode] if current_mode is not None and output.get("modes") else None
        logical = output.get("logical")
        modes = sorted({(m["width"], m["height"]) for m in output.get("modes") or []}, reverse=True)
        result.append({
            "name": output["name"],
            "label": " ".join(part for part in (output.get("make"), output.get("model")) if part and part != "Unknown"),
            "x": logical["x"] if logical else 0,
            "y": logical["y"] if logical else 0,
            "scale": logical["scale"] if logical else 1.0,
            "transform": TRANSFORMS.get(logical["transform"], "normal") if logical else "normal",
            "mode": f'{mode["width"]}x{mode["height"]}@{mode["refresh_rate"] / 1000:.3f}' if mode else "",
            "modeWidth": mode["width"] if mode else (modes[0][0] if modes else 1920),
            "modeHeight": mode["height"] if mode else (modes[0][1] if modes else 1080),
            "off": logical is None,
        })
    return sorted(result, key=lambda o: (o["off"], o["x"], o["y"]))


def mode_size(output, connected):
    if m := re.match(r"(\d+)x(\d+)", output.get("mode") or ""):
        return int(m.group(1)), int(m.group(2))
    known = connected.get(output["name"])
    return (known["modeWidth"], known["modeHeight"]) if known else (1920, 1080)


def with_size(output, connected):
    """Adds the logical width/height the output takes in the layout."""
    width, height = mode_size(output, connected)
    if output["transform"].endswith(("90", "270")):
        width, height = height, width
    scale = output["scale"] or 1.0
    return dict(output, width=round(width / scale), height=round(height / scale), connected=output["name"] in connected)


def profiles():
    found = {}
    for directory, builtin in ((BUILTIN, True), (SAVED, False)):
        for path in sorted(directory.glob("*.kdl")):
            if not (SAVED / f"{path.stem}.hidden").exists():
                found[path.stem] = (path, builtin)
    return found


def current():
    try:
        for line in ACTIVE.read_text().splitlines():
            if line.startswith("// display profile: "):
                return line.removeprefix("// display profile: ").strip()
    except OSError:
        pass
    return ""


def cmd_list():
    outputs = live()
    connected = {o["name"]: o for o in outputs}
    result = []
    for name, (path, builtin) in profiles().items():
        try:
            parsed, rules = parse(path)
        except OSError:
            continue
        result.append({
            "name": name,
            "builtin": builtin,
            "rules": len(rules),
            "outputs": [with_size(o, connected) for o in parsed],
        })
    print(json.dumps({
        "current": current(),
        "profiles": result,
        "live": [with_size(o, connected) for o in outputs],
    }))


def number(value):
    return f"{float(value):g}" if float(value) != int(float(value)) else f"{int(float(value))}.0"


def niri_output(name, *args):
    subprocess.run(["niri", "msg", "output", name, *map(str, args)], capture_output=True, timeout=10)


def cmd_live(outputs):
    """Only what differs is sent, so untouched monitors do not flicker."""
    connected = {o["name"]: o for o in live()}
    wanted = [o for o in outputs if o["name"] in connected]
    for output in wanted:
        now = connected[output["name"]]
        if output.get("off"):
            if not now["off"]:
                niri_output(output["name"], "off")
            continue
        if now["off"]:
            niri_output(output["name"], "on")
        if output.get("mode") and output["mode"] != now["mode"]:
            niri_output(output["name"], "mode", output["mode"])
        if float(output.get("scale") or 1) != float(now["scale"]):
            niri_output(output["name"], "scale", number(output["scale"]))
        if (output.get("transform") or "normal") != now["transform"]:
            niri_output(output["name"], "transform", output.get("transform") or "normal")
    # positions last: they depend on the sizes the transforms gave
    for output in wanted:
        now = connected[output["name"]]
        if not output.get("off") and (now["off"] or int(output["x"]) != now["x"] or int(output["y"]) != now["y"]):
            niri_output(output["name"], "position", "set", "--", int(output["x"]), int(output["y"]))


def cmd_save(name, outputs):
    if not NAME.match(name):
        sys.exit(f"invalid name: {name}")
    existing = profiles().get(name)
    kept, rules = parse(existing[0]) if existing else ([], [])
    # monitors of the old version that are not plugged in now stay as they were
    named = {o["name"] for o in outputs}
    outputs = outputs + [o for o in kept if o["name"] not in named]

    lines = [f"// display profile: {name}", ""]
    for output in outputs:
        lines.append(f'output "{output["name"]}" {{')
        if output.get("off"):
            lines.append("    off")
        if output.get("mode"):
            lines.append(f'    mode "{output["mode"]}"')
        lines.append(f'    position x={int(output["x"])} y={int(output["y"])}')
        lines.append(f'    scale {number(output.get("scale") or 1)}')
        lines.append(f'    transform "{output.get("transform") or "normal"}"')
        lines += ["}", ""]
    for rule in rules:
        lines += [rule, ""]

    SAVED.mkdir(parents=True, exist_ok=True)
    (SAVED / f"{name}.hidden").unlink(missing_ok=True)
    target = SAVED / f"{name}.kdl"
    temp = target.with_suffix(".tmp")
    temp.write_text("\n".join(lines).rstrip() + "\n")
    check = subprocess.run(["niri", "validate", "-c", str(temp)], capture_output=True, text=True)
    if check.returncode != 0:
        temp.unlink()
        sys.exit(f"niri rejected the setup:\n{check.stderr.strip()}")
    temp.replace(target)


def cmd_delete(name):
    path = SAVED / f"{name}.kdl"
    if path.is_file():
        path.unlink()
    if (BUILTIN / f"{name}.kdl").is_file():
        SAVED.mkdir(parents=True, exist_ok=True)
        (SAVED / f"{name}.hidden").touch()


ARRANGEMENT = {"mode", "position", "scale", "transform", "off"}


def cmd_activate(source, name):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import niri_kdl as kdl

    wanted = [n for n in kdl.parse(Path(source).read_text()) if not n.disabled]
    try:
        active = [n for n in kdl.parse(ACTIVE.read_text()) if not n.disabled]
    except OSError:
        active = []
    kept = {str(n.args[0]): kdl.to_json(n) for n in active if n.name == "output" and n.args}
    outputs = []
    for node in wanted:
        if node.name != "output" or not node.args:
            continue
        block = kdl.to_json(node)
        block.pop("comment", None)
        before = kept.pop(str(node.args[0]), None)
        if before:
            block["children"] = [c for c in block.get("children") or [] if c["name"] in ARRANGEMENT] + \
                [c for c in before.get("children") or [] if c["name"] not in ARRANGEMENT]
        outputs.append(block)
    # a monitor the setup does not name is placed by niri, as before
    for block in kept.values():
        block["children"] = [c for c in block.get("children") or [] if c["name"] not in ARRANGEMENT]
        if block["children"]:
            outputs.append(block)
    rules = [kdl.to_json(n) for n in wanted if n.name != "output"]
    text = kdl.render(outputs + rules, [f"display profile: {name}"])
    error = kdl.validate(ACTIVE.parent / "config.kdl", {str(ACTIVE): text}) if (ACTIVE.parent / "config.kdl").exists() else None
    if error:
        sys.exit(f"niri rejected the setup:\n{error}")
    kdl.atomic_write(ACTIVE, text)


def main():
    args = sys.argv[1:]
    if args == ["list"]:
        cmd_list()
    elif len(args) == 2 and args[0] == "live":
        cmd_live(json.loads(args[1]))
    elif len(args) == 3 and args[0] == "save":
        cmd_save(args[1], json.loads(args[2]))
    elif len(args) == 3 and args[0] == "activate":
        cmd_activate(args[1], args[2])
    elif len(args) == 2 and args[0] == "delete":
        cmd_delete(args[1])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
