#!/usr/bin/env python3
"""Pshell Files as every app's file chooser (plugin "files-chooser").

    portal_setup.py on       make it so (nothing is touched when it already is)
    portal_setup.py off      give the choosers back as they were
    portal_setup.py status   what is set up, as JSON

What "on" sets up, all of it in the user's home (no root needed):
  * the backend: ~/.local/share/pshell/portals/ holds pshell.portal beside
    links to the system's backends, and xdg-desktop-portal reads that folder
    (XDG_DESKTOP_PORTAL_DIR in a drop-in of its user unit) – it reads only
    /usr/share otherwise; D-Bus starts scripts/files/portal.py by its name
  * the choice: <desktop>-portals.conf names pshell first for FileChooser
    (the line before is remembered and comes back with "off")
  * apps that only ask the portal when told to: GTK (GTK_USE_PORTAL,
    GDK_DEBUG=portals in environment.d, for apps started after the next
    login) and Floorp/Firefox (widget.use-xdg-desktop-portal.file-picker in
    each profile's user.js, after its next start); Chromium and Electron
    apps ask the portal anyway
xdg-desktop-portal is restarted only when something changed.
"""
import configparser
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import host  # noqa: E402

HERE = Path(__file__).resolve().parent
HOME = Path.home()
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local" / "share")
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
SYSTEM_PORTALS = Path("/usr/share/xdg-desktop-portal/portals")
PORTALS = DATA / "pshell" / "portals"
SERVICE = DATA / "dbus-1" / "services" / "org.freedesktop.impl.portal.desktop.pshell.service"
DROPIN = CONFIG / "systemd" / "user" / "xdg-desktop-portal.service.d" / "pshell.conf"
ENVIRONMENT = CONFIG / "environment.d" / "pshell-file-chooser.conf"
STATE = host.state_dir() / "file-chooser.json"
FIREFOX_DIRS = [CONFIG / "floorp", HOME / ".floorp", HOME / ".mozilla" / "firefox", HOME / ".librewolf"]
PREF = 'user_pref("widget.use-xdg-desktop-portal.file-picker", 1); // pshell file chooser'
KEY = "org.freedesktop.impl.portal.FileChooser"


def desktop():
    return (os.environ.get("XDG_CURRENT_DESKTOP") or "niri").split(":")[0].lower()


def conf_path():
    return CONFIG / "xdg-desktop-portal" / f"{desktop()}-portals.conf"


def load_state():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=1))


def write_if_changed(path, text):
    try:
        if path.read_text() == text:
            return False
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return True


# ── the backend ───────────────────────────────────────────────────────────
def portal_file():
    return ("[portal]\n"
            "DBusName=org.freedesktop.impl.portal.desktop.pshell\n"
            f"Interfaces={KEY};\n"
            "UseIn=niri\n")


def sync_portals():
    """Our folder: pshell.portal and a link to each of the system's."""
    changed = write_if_changed(PORTALS / "pshell.portal", portal_file())
    wanted = {path.name: path for path in SYSTEM_PORTALS.glob("*.portal") if path.name != "pshell.portal"}
    for entry in PORTALS.iterdir():
        if entry.name == "pshell.portal" or entry.name.endswith(".conf"):
            continue
        if entry.name not in wanted or not entry.is_symlink() or Path(os.readlink(entry)) != wanted[entry.name]:
            entry.unlink()
            changed = True
    for name, source in wanted.items():
        if not (PORTALS / name).is_symlink():
            (PORTALS / name).symlink_to(source)
            changed = True
    # with XDG_DESKTOP_PORTAL_DIR set the choice is read from that folder
    # only: the user's own file is linked in (the one "on" edits)
    for name in (conf_path().name, "portals.conf"):
        user = CONFIG / "xdg-desktop-portal" / name
        link = PORTALS / name
        if user.exists() or name == conf_path().name:
            if not link.is_symlink() or Path(os.readlink(link)) != user:
                if link.exists() or link.is_symlink():
                    link.unlink()
                link.symlink_to(user)
                changed = True
    return changed


def service_file():
    return ("[D-BUS Service]\n"
            "Name=org.freedesktop.impl.portal.desktop.pshell\n"
            f"Exec=/usr/bin/python3 {HERE / 'portal.py'}\n")


def dropin_file():
    return ("# Pshell: xdg-desktop-portal reads its backends from here (see scripts/files/portal_setup.py)\n"
            "[Service]\n"
            f"Environment=XDG_DESKTOP_PORTAL_DIR={PORTALS}\n")


# ── which backend is chosen ───────────────────────────────────────────────
def read_conf(path):
    try:
        return path.read_text().splitlines()
    except OSError:
        system = Path("/usr/share/xdg-desktop-portal") / path.name
        try:
            return system.read_text().splitlines()
        except OSError:
            return ["[preferred]", "default=gtk;"]


def current_choice(lines):
    for line in lines:
        if line.strip().startswith(KEY + "="):
            return line.strip().split("=", 1)[1]
    return None


def set_choice(lines, value):
    """The FileChooser line under [preferred]; None takes it out."""
    out, section, done = [], "", False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            if section == "preferred" and not done and value is not None:
                out.append(f"{KEY}={value}")
                done = True
            section = stripped.strip("[]")
        if stripped.startswith(KEY + "="):
            if value is not None and not done:
                out.append(f"{KEY}={value}")
                done = True
            continue
        out.append(line)
    if value is not None and not done:
        if section != "preferred":
            out.append("[preferred]")
        out.append(f"{KEY}={value}")
    return out


def pshell_choice(before):
    rest = [name for name in (before or "gtk").split(";") if name and name != "pshell"]
    return ";".join(["pshell", *(rest or ["gtk"])]) + ";"


# ── apps that have to be told ─────────────────────────────────────────────
def firefox_profiles():
    found = []
    for base in FIREFOX_DIRS:
        ini_path = base / "profiles.ini"
        if not ini_path.exists():
            continue
        ini = configparser.ConfigParser(strict=False, interpolation=None)
        ini.read(ini_path)
        for section in ini.sections():
            if section.startswith("Profile") and "Path" in ini[section]:
                path = Path(ini[section]["Path"])
                found.append(path if path.is_absolute() else base / path)
    return [path for path in dict.fromkeys(found) if path.is_dir()]


def set_firefox(on):
    changed = []
    if CONFIG != HOME / ".config":
        return changed
    for profile in firefox_profiles():
        user_js = profile / "user.js"
        try:
            lines = user_js.read_text().splitlines()
        except OSError:
            lines = []
        has = PREF in lines
        if on and not has:
            lines.append(PREF)
        elif not on and has:
            lines = [line for line in lines if line != PREF]
        else:
            continue
        if lines:
            user_js.write_text("\n".join(lines) + "\n")
        elif user_js.exists():
            user_js.unlink()
        changed.append(str(profile))
    return changed


def told(profile):
    try:
        return PREF in (profile / "user.js").read_text(errors="replace").splitlines()
    except OSError:
        return False


def environment_file():
    return ("# Pshell: GTK apps ask the file chooser portal (scripts/files/portal_setup.py)\n"
            "GTK_USE_PORTAL=1\n"
            "GDK_DEBUG=portals\n")


def run(*command):
    # a test home (another XDG_CONFIG_HOME) never reaches the real session
    if CONFIG != HOME / ".config":
        return
    try:
        subprocess.run(command, capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        pass


def restart_portal():
    run("systemctl", "--user", "daemon-reload")
    run("systemctl", "--user", "try-restart", "xdg-desktop-portal.service")


# ── on, off, status ───────────────────────────────────────────────────────
def on():
    state = load_state()
    changed = sync_portals()
    changed |= write_if_changed(SERVICE, service_file())
    dropin = write_if_changed(DROPIN, dropin_file())
    path = conf_path()
    lines = read_conf(path)
    before = current_choice(lines)
    if not state.get("on"):
        state["before"] = before
    wanted = pshell_choice(state.get("before") if state.get("on") else before)
    if before != wanted:
        if path.exists() and not path.with_name(path.name + ".bak-before-pshell").exists():
            shutil.copy2(path, path.with_name(path.name + ".bak-before-pshell"))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(set_choice(lines, wanted)) + "\n")
        changed = True
    if write_if_changed(ENVIRONMENT, environment_file()):
        run("systemctl", "--user", "set-environment", "GTK_USE_PORTAL=1", "GDK_DEBUG=portals")
    state["firefox"] = sorted(set(state.get("firefox", [])) | set(set_firefox(True)))
    state["on"] = True
    save_state(state)
    if changed or dropin:
        restart_portal()
    print(json.dumps({"on": True, "restarted": bool(changed or dropin)}))


def off():
    state = load_state()
    if not state.get("on") and not DROPIN.exists():
        print(json.dumps({"on": False, "restarted": False}))
        return
    path = conf_path()
    lines = read_conf(path)
    if path.exists():
        path.write_text("\n".join(set_choice(lines, state.get("before"))) + "\n")
    for each in (DROPIN, SERVICE, ENVIRONMENT):
        try:
            each.unlink()
        except OSError:
            pass
    shutil.rmtree(PORTALS, ignore_errors=True)
    run("systemctl", "--user", "unset-environment", "GTK_USE_PORTAL", "GDK_DEBUG")
    set_firefox(False)
    save_state({"on": False, "before": state.get("before")})
    restart_portal()
    print(json.dumps({"on": False, "restarted": True}))


def status():
    lines = read_conf(conf_path())
    try:
        active = subprocess.run(["systemctl", "--user", "show", "xdg-desktop-portal.service", "-p", "Environment"],
                                capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        active = ""
    print(json.dumps({
        "on": bool(load_state().get("on")),
        "choice": current_choice(lines),
        "conf": str(conf_path()),
        "backendDir": str(PORTALS) in active,
        "service": SERVICE.exists(),
        "gtk": ENVIRONMENT.exists(),
        "firefox": [str(p) for p in firefox_profiles() if told(p)],
    }))


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "status"
    {"on": on, "off": off, "status": status}.get(what, status)()
