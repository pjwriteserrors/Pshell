#!/usr/bin/env python3
"""Prints the paired KDE Connect devices as one JSON array.

[{ id, name, type, reachable, battery, charging, network, signal }]
battery is -1 when unknown, signal is 0..4 or -1.
"""
import json
import subprocess

SERVICE = "org.kde.kdeconnect"
BASE = "/modules/kdeconnect/devices"


def prop(path, interface, name):
    try:
        out = subprocess.run(
            ["busctl", "--user", "--json=short", "get-property", SERVICE, path, interface, name],
            capture_output=True, text=True, timeout=3,
        )
        if out.returncode != 0:
            return None
        return json.loads(out.stdout).get("data")
    except Exception:
        return None


def device_ids():
    try:
        out = subprocess.run(["kdeconnect-cli", "-l", "--id-only"], capture_output=True, text=True, timeout=5)
        return [line.strip() for line in out.stdout.splitlines() if line.strip()]
    except Exception:
        return []


devices = []
for dev in device_ids():
    path = f"{BASE}/{dev}"
    iface = "org.kde.kdeconnect.device"
    if not prop(path, iface, "isPaired"):
        continue
    reachable = bool(prop(path, iface, "isReachable"))
    entry = {
        "id": dev,
        "name": prop(path, iface, "name") or dev,
        "type": prop(path, iface, "type") or "phone",
        "reachable": reachable,
        "battery": -1,
        "charging": False,
        "network": "",
        "signal": -1,
    }
    if reachable:
        charge = prop(f"{path}/battery", "org.kde.kdeconnect.device.battery", "charge")
        if isinstance(charge, int):
            entry["battery"] = charge
        entry["charging"] = bool(prop(f"{path}/battery", "org.kde.kdeconnect.device.battery", "isCharging"))
        report = "org.kde.kdeconnect.device.connectivity_report"
        entry["network"] = prop(f"{path}/connectivity_report", report, "cellularNetworkType") or ""
        strength = prop(f"{path}/connectivity_report", report, "cellularNetworkStrength")
        entry["signal"] = strength if isinstance(strength, int) else -1
    devices.append(entry)

print(json.dumps(devices))
