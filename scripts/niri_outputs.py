"""Which monitor an output block means.

niri matches a block by connector ("DP-2") or by "Make Model Serial". The
connector of a monitor changes with the port and the dock it hangs on, and
another monitor takes the same one at another desk, so the shell writes
blocks by make, model and serial and reads either.
"""

import json
import subprocess


def connected():
    """niri's outputs by connector, each with `id`: the name its block gets."""
    try:
        raw = subprocess.run(["niri", "msg", "-j", "outputs"], capture_output=True, text=True, timeout=5).stdout
        data = json.loads(raw)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}
    if not isinstance(data, dict):
        return {}
    names = {connector: identity(output) for connector, output in data.items()}
    for connector, output in data.items():
        name = names[connector]
        # two of the same monitor without a serial can only be told apart by connector
        unique = name and sum(1 for other in names.values() if other and other.lower() == name.lower()) == 1
        output["id"] = name if unique else connector
    return data


def identity(output):
    """"Make Model Serial" the way niri spells it, None when it knows none of them."""
    make = output.get("make") or "Unknown"
    model = output.get("model") or "Unknown"
    serial = output.get("serial") or "Unknown"
    if (make, model, serial) == ("Unknown", "Unknown", "Unknown"):
        return None
    return f"{make} {model} {serial}"


def connector(name, outputs):
    """The connector of the plugged-in monitor a block name means, or None."""
    wanted = str(name).lower()
    for key, output in outputs.items():
        if wanted == key.lower():
            return key
    for key, output in outputs.items():
        if wanted == str(output.get("id") or "").lower() or wanted == str(identity(output) or "").lower():
            return key
    return None


def canonical(name, outputs):
    """The name a block is written with: the monitor's id while it is plugged in."""
    key = connector(name, outputs)
    return outputs[key]["id"] if key else str(name)


def canonical_blocks(blocks, outputs):
    """Output blocks (JSON nodes) renamed to ids; niri uses the first block
    that fits a monitor, so a later one for the same monitor is dropped."""
    seen, result = set(), []
    for block in blocks:
        if block.get("name") != "output" or not block.get("args"):
            result.append(block)
            continue
        name = canonical(block["args"][0], outputs)
        if name.lower() in seen:
            continue
        seen.add(name.lower())
        result.append(dict(block, args=[name] + list(block["args"][1:])))
    return result
