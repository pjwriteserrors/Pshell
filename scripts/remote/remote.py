#!/usr/bin/env python3
"""Remote PCs, the PC's side (docs/core.md "Remote power").

As the user (the shell's Remote.qml):
  status                    → {host, moonlight, sunshine, sunshine_running, creds}
  sunshine start|stop       start Sunshine (its user unit, else the binary) and wait for its port
  pin PIN NAME              hand a Moonlight PIN to the local Sunshine (needs creds)
  creds USER                remember Sunshine's web login, the password on stdin
                            (checked when Sunshine runs)

As root (pshell-remote.service, installed by system/install-remote-login.sh):
  greeter                   while nobody is signed in: ask core for a ticket of
                            this PC; one with `login` signs the user in once
                            (an SDDM autologin drop-in and a restart of the
                            display manager), the drop-in goes once the session is up.

Answers are one JSON line; exit 0 = ok, 2 = usage, 3 = no creds, 4 = creds wrong,
5 = Sunshine is not there, 1 = anything else.
"""
import base64
import json
import os
import pwd
import shutil
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SUNSHINE_UNITS = ("app-dev.lizardbyte.app.Sunshine.service", "sunshine.service")
SUNSHINE_PORT = 47989
SUNSHINE_WEB = "https://127.0.0.1:47990"
SYSTEM_CONFIG = Path(os.environ.get("PSHELL_REMOTE_CONFIG", "/etc/pshell-remote.json"))
DROPIN = Path(os.environ.get("PSHELL_REMOTE_DROPIN", "/etc/sddm.conf.d/zz-pshell-remote.conf"))
CORE_PORT = 8097


def answer(data, code=0):
    print(json.dumps(data), flush=True)
    sys.exit(code)


def fail(message, code=1, **extra):
    answer({"error": message, **extra}, code)


def state_dir(home=None):
    home = Path(home or os.environ.get("HOME") or Path.home())
    return Path(os.environ.get("XDG_STATE_HOME") or home / ".local" / "state") / "pshell"


def creds_path():
    return state_dir() / "sunshine.json"


def listening(port, host="127.0.0.1", timeout=0.6):
    try:
        with socket.create_connection((host, port), timeout):
            return True
    except OSError:
        return False


def moonlight():
    """How to run Moonlight here: a command list, or None."""
    for name in ("moonlight", "moonlight-qt"):
        path = shutil.which(name)
        if path:
            return [path]
    if shutil.which("flatpak"):
        try:
            out = subprocess.run(["flatpak", "info", "com.moonlight_stream.Moonlight"], capture_output=True, timeout=5)
            if out.returncode == 0:
                return ["flatpak", "run", "com.moonlight_stream.Moonlight"]
        except (OSError, subprocess.TimeoutExpired):
            pass
    return None


def user_unit():
    for unit in SUNSHINE_UNITS:
        try:
            out = subprocess.run(["systemctl", "--user", "cat", unit], capture_output=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if out.returncode == 0:
            return unit
    return None


def status():
    creds = creds_path()
    answer({
        "host": socket.gethostname().split(".")[0],
        "moonlight": moonlight(),
        "sunshine": bool(shutil.which("sunshine")) or user_unit() is not None,
        "sunshine_running": listening(SUNSHINE_PORT),
        "creds": creds.exists(),
    })


def sunshine(action):
    unit = user_unit()
    if action == "stop":
        if unit:
            subprocess.run(["systemctl", "--user", "stop", unit], capture_output=True, timeout=20)
        else:
            subprocess.run(["pkill", "-x", "sunshine"], capture_output=True)
        answer({"running": False})
    if listening(SUNSHINE_PORT):
        answer({"running": True, "already": True})
    if unit:
        out = subprocess.run(["systemctl", "--user", "start", unit], capture_output=True, text=True, timeout=30)
        if out.returncode != 0:
            fail(out.stderr.strip() or f"{unit} did not start")
    elif shutil.which("sunshine"):
        subprocess.Popen(["sunshine"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    else:
        fail("Sunshine is not installed", 5)
    for _ in range(60):
        if listening(SUNSHINE_PORT):
            answer({"running": True})
        time.sleep(0.5)
    fail("Sunshine did not open its port")


def sunshine_call(path, body=None, creds=None):
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE        # Sunshine's own certificate, on this PC
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(SUNSHINE_WEB + path, data=data, method="POST" if data else "GET")
    request.add_header("Content-Type", "application/json")
    if creds:
        token = base64.b64encode(f"{creds['user']}:{creds['password']}".encode()).decode()
        request.add_header("Authorization", f"Basic {token}")
    with urllib.request.urlopen(request, timeout=8, context=context) as response:
        text = response.read().decode() or "{}"
        try:
            return json.loads(text)
        except ValueError:
            return {"text": text}


def load_creds():
    try:
        data = json.loads(creds_path().read_text())
        if data.get("user") and data.get("password"):
            return data
    except (OSError, ValueError):
        pass
    return None


def pin(code, name):
    creds = load_creds()
    if not creds:
        fail("Sunshine's login is not known on this PC", 3)
    if not listening(SUNSHINE_PORT):
        fail("Sunshine is not running", 5)
    try:
        data = sunshine_call("/api/pin", {"pin": str(code), "name": str(name or "Moonlight")}, creds)
    except urllib.error.HTTPError as error:
        if error.code == 401:
            fail("Sunshine's login is wrong", 4)
        fail(f"Sunshine said {error.code}")
    except OSError as error:
        fail(str(error))
    if str(data.get("status", "true")).lower() not in ("true", "1"):
        fail("Sunshine did not take the PIN", 1, data=data)
    answer({"ok": True})


def save_creds(user, password):
    if listening(SUNSHINE_PORT):
        try:
            sunshine_call("/api/config", None, {"user": user, "password": password})
        except urllib.error.HTTPError as error:
            if error.code == 401:
                fail("Sunshine's login is wrong", 4)
        except OSError:
            pass
    path = creds_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump({"user": user, "password": password}, handle)
    answer({"ok": True})


# ── root: the greeter loop ──────────────────────────────────────────────────
def log(*args):
    print("pshell-remote:", *args, file=sys.stderr, flush=True)


def system_config():
    try:
        data = json.loads(SYSTEM_CONFIG.read_text())
    except (OSError, ValueError):
        data = {}
    return {"user": data.get("user") or "", "session": data.get("session") or "niri.desktop",
            "core": data.get("core") or [], "display_manager": data.get("display_manager") or "display-manager.service"}


def device_of(user):
    """The PC's core token and the addresses of core, from the user's nas.json."""
    try:
        home = os.environ.get("PSHELL_REMOTE_HOME") or pwd.getpwnam(user).pw_dir
    except KeyError:
        return None, []
    try:
        data = json.loads((state_dir(home) / "nas.json").read_text())
    except (OSError, ValueError):
        return None, []
    bases = []
    if data.get("core_url"):
        bases.append(str(data["core_url"]).rstrip("/"))
    for address in [data.get("address"), *(data.get("addresses") or {}).values(), "http://192.168.178.22:8096", "http://10.8.0.1:8096"]:
        if isinstance(address, str) and "://" in address:
            host = address.split("://", 1)[1].split("/", 1)[0].rsplit(":", 1)[0]
            base = f"http://{host}:{CORE_PORT}"
            if base not in bases:
                bases.append(base)
    return data.get("token"), bases


def core_call(bases, token, method, path):
    for base in bases:
        request = urllib.request.Request(base + path, method=method, data=b"{}" if method != "GET" else None,
                                         headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                                                  "X-Pshell": "1", "User-Agent": "pshell-remote"})
        try:
            with urllib.request.urlopen(request, timeout=4) as response:
                return json.loads(response.read().decode() or "{}"), base
        except urllib.error.HTTPError as error:
            log(base, path, error.code)
            return None, base
        except (OSError, ValueError):
            continue
    return None, None


def signed_in(user):
    """True while the user has a graphical session (or any session at all on a seat)."""
    try:
        out = subprocess.run(["loginctl", "list-sessions", "--no-legend"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 3 or parts[2] != user:
            continue
        try:
            props = subprocess.run(["loginctl", "show-session", parts[0], "-p", "Type", "-p", "Class", "-p", "State"],
                                   capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        values = dict(line.split("=", 1) for line in props.splitlines() if "=" in line)
        if values.get("Class") == "user" and values.get("Type") in ("wayland", "x11") and values.get("State") in ("active", "online"):
            return True
    return False


def write_dropin(user, session):
    DROPIN.parent.mkdir(parents=True, exist_ok=True)
    DROPIN.write_text(f"# pshell remote login: one sign-in, removed once the session is up\n"
                      f"[Autologin]\nUser={user}\nSession={session}\nRelogin=false\n")
    os.chmod(DROPIN, 0o644)


def drop_dropin():
    try:
        DROPIN.unlink()
        log("autologin drop-in removed")
    except FileNotFoundError:
        pass


def greeter():
    if os.geteuid() != 0 and "PSHELL_REMOTE_DROPIN" not in os.environ:
        fail("greeter runs as root")
    config = system_config()
    user = config["user"]
    if not user:
        fail("No user in " + str(SYSTEM_CONFIG))
    # a drop-in left from before a crash or a power cut never signs in by itself
    drop_dropin()
    started = time.monotonic()
    while True:
        if signed_in(user):
            drop_dropin()
            time.sleep(30)
            continue
        token, bases = device_of(user)
        bases = list(config["core"]) + [b for b in bases if b not in config["core"]]
        if token and bases:
            ticket, _ = core_call(bases, token, "GET", "/api/power/ticket")
            if ticket and ticket.get("login"):
                taken, _ = core_call(bases, token, "POST", "/api/power/boot")
                if taken and taken.get("login") and not signed_in(user):
                    log("ticket: signing in", user)
                    write_dropin(user, config["session"])
                    subprocess.run(["systemctl", "restart", config["display_manager"]], timeout=60)
                    for _ in range(60):
                        if signed_in(user):
                            break
                        time.sleep(2)
                    drop_dropin()
                    continue
        # often in the first minutes after a boot (that is when a woken PC asks), seldom later
        time.sleep(4 if time.monotonic() - started < 300 else 15)


def main(argv):
    if not argv:
        fail(__doc__.strip().splitlines()[0], 2)
    command, rest = argv[0], argv[1:]
    if command == "status":
        status()
    elif command == "sunshine" and rest and rest[0] in ("start", "stop"):
        sunshine(rest[0])
    elif command == "pin" and len(rest) >= 1:
        pin(rest[0], rest[1] if len(rest) > 1 else "Moonlight")
    elif command == "creds" and len(rest) == 1:
        password = sys.stdin.readline().rstrip("\n")
        if not password:
            fail("No password on stdin", 2)
        save_creds(rest[0], password)
    elif command == "greeter":
        greeter()
    fail("Usage: remote.py status | sunshine start|stop | pin PIN NAME | creds USER (password on stdin) | greeter", 2)


if __name__ == "__main__":
    main(sys.argv[1:])
