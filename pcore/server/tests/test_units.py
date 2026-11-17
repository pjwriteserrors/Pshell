"""Pieces without a server: passwords, TOTP, the `next` check, settings,
health from fake /proc and /sys, history thinning, guard levels, and the
NAS import from a nas.db made with the NAS's own schema and hashes."""
import importlib.util
import json
import sqlite3
import tempfile
import time
from pathlib import Path

from common import HERE, run, write_proc, write_sys

from pshell_core import auth, ctl
from pshell_core.db import Db
from pshell_core.guard import level_of
from pshell_core.health import History, Sampler, average
from pshell_core.settings import Settings

NAS = HERE.parent.parent / "nas" / "server" / "pshell_nas"


def load_nas(module):
    spec = importlib.util.spec_from_file_location(f"nas_{module}", NAS / f"{module}.py")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def passwords_and_totp():
    stored = auth.hash_password("correct horse")
    assert stored.startswith("scrypt$16384$8$1$")
    assert auth.check_password("correct horse", stored)
    assert not auth.check_password("wrong", stored)
    assert not auth.check_password("x", "garbage")
    secret = auth.totp_secret()
    now = time.time()
    code = auth.totp_at(secret, int(now // 30))
    assert auth.totp_ok(secret, code, now)
    assert auth.totp_ok(secret, code[:3] + " " + code[3:], now)
    assert auth.totp_ok(secret, auth.totp_at(secret, int(now // 30) - 1), now)      # one step of drift
    assert not auth.totp_ok(secret, auth.totp_at(secret, int(now // 30) - 3), now)
    assert not auth.totp_ok(secret, "", now)
    # RFC 6238 test vector (SHA-1, T=59 → 94287082, 6 digits → 287082)
    import base64
    rfc = base64.b32encode(b"12345678901234567890").decode()
    assert auth.totp_at(rfc, 59 // 30) == "287082"
    token = auth.new_token()
    assert token.startswith("psh_") and len(token) == 47
    assert auth.new_device_id().startswith("dev_") and len(auth.new_device_id()) == 14
    assert auth.parse_basic("Basic " + base64.b64encode(b"dev_x:psh_y").decode()) == ("dev_x", "psh_y")
    assert auth.parse_basic(base64.b64encode(b"lu:pa:ss").decode()) == ("lu", "pa:ss")
    assert auth.parse_basic("Basic !!!") is None
    assert auth.parse_basic("Basic " + base64.b64encode(b"nocolon").decode()) is None


def next_check():
    host, ports = "192.168.178.22:8097", {8096, 8097, 80, 8123}
    ok = auth.safe_next
    assert ok("http://192.168.178.22:8096/files?x=1", host, ports) == "http://192.168.178.22:8096/files?x=1"
    assert ok("http://192.168.178.22/admin/", host, ports)                # Pi-hole on 80
    assert ok("/devices", host, ports) == "/devices"
    assert ok("https://192.168.178.22:8123/", host, ports)
    for bad in ("http://evil.example:8096/", "//evil.example/", "http://192.168.178.22:9999/",
                "http://192.168.178.22:8096@evil.example/", "http://evil@192.168.178.22:8096/",
                "javascript:alert(1)", "http://192.168.178.22:8096/\\@evil", "/\\evil.example",
                "http://192.168.178.22.evil.example:8096/", "ftp://192.168.178.22:8096/", "", None, 5,
                "http://192.168.178.22:99999/", "https://192.168.178.22/", "\n/x"):
        assert ok(bad, host, ports) is None, bad
    assert ok("http://10.8.0.1:8096/", "10.8.0.1:8097", ports)
    assert ok("http://192.168.178.22:8096/", "10.8.0.1:8097", ports) is None   # another host
    assert ok("http://[::1]:8096/", "[::1]:8097", ports)


def settings():
    path = Path(tempfile.mkdtemp()) / "settings.json"
    store = Settings(path)
    assert store.get("tight_mb") == 900 and store.get("alerts.failed") == 3
    store.update({"alerts": {"failed": 5}, "tight_mb": 1000})
    assert json.loads(path.read_text()) == {"alerts.failed": 5, "tight_mb": 1000}
    assert Settings(path).get("alerts.failed") == 5
    for bad in ({"nope": 1}, {"guard_stop": "yes"}, {"tight_mb": True}, {"session_days": 0}, {"tight_psi": "x"}):
        try:
            store.update(bad)
        except (KeyError, ValueError):
            continue
        raise AssertionError(f"accepted {bad}")


def health():
    tmp = Path(tempfile.mkdtemp())
    write_proc(tmp / "proc", available_mb=1234, some=3.5, full=0.25)
    write_sys(tmp / "sys", temp=48500, throttled="0x50005")
    sampler = Sampler(tmp / "proc", tmp / "sys", tmp)
    first = sampler.sample({"pshell-nas": {"mem": 300 << 20}, "gone": {"mem": None}})
    assert first["mem_available"] == 1234 and first["mem_total"] == 7800, first
    assert first["swap_used"] == 50, first
    assert first["psi_some10"] == 3.5 and first["psi_full10"] == 0.25
    assert first["load1"] == 0.52 and first["load15"] == 0.31
    assert first["temp"] == 48.5 and first["throttled"] == 0x50005
    assert first["uptime"] == 12345.67
    assert first["cpu"] is None                                   # needs two readings
    assert first["disk"]["total"] > 0 and first["containers"] == {"pshell-nas": 300}
    write_proc(tmp / "proc", available_mb=1234, idle=1300, busy=200)   # +100 busy, +300 idle → 25 %
    assert sampler.sample()["cpu"] == 25.0
    # major faults per second over the window (the kernel without PSI): one reading says nothing
    from unittest import mock
    import pshell_core.health as health_mod
    clock = [1000.0]
    vmstat = tmp / "proc" / "vmstat"
    with mock.patch.object(health_mod.time, "monotonic", lambda: clock[0]):
        vm = Sampler(tmp / "proc", tmp / "sys", tmp)
        vmstat.write_text("nr_free_pages 1\npswpin 10\npswpout 0\npgmajfault 5000\n")
        assert vm.thrash() == {"faults": None, "swapin": None}
        clock[0] += 5
        vmstat.write_text("pswpin 10\npgmajfault 5010\n")
        assert vm.thrash() == {"faults": 2.0, "swapin": 0.0}
        for step in range(4):                 # 300 faults/s for 20 s: the window holds the last 15 s
            clock[0] += 5
            vmstat.write_text(f"pswpin {10 + 50 * (step + 1)}\npgmajfault {5010 + 1500 * (step + 1)}\n")
            rate = vm.thrash()
        assert rate["faults"] == 300.0 and rate["swapin"] == 10.0, rate
        quick = vm.quick()
        assert quick["mem_available"] == 1234 and "faults" in quick and "load1" not in quick
    # nothing readable: nulls, no exceptions
    empty = Sampler(tmp / "none", tmp / "none", tmp / "none").sample()
    assert empty["faults"] is None and empty["swapin"] is None
    assert empty["mem_available"] is None and empty["temp"] is None and empty["throttled"] is None
    assert empty["disk"] is None and empty["cpu"] is None

    db = Db(tmp / "core.db")
    store = Settings(tmp / "settings.json")
    history = History(db, store)
    now = time.time()
    base = (now - 3 * 86400) // 60 * 60
    for index in range(6):                          # three minutes, two samples each, three days ago
        history.add({"at": base + index * 30, "mem_available": 1000 + index * 10, "cpu": 10.0})
    history.add({"at": now - 9 * 86400, "mem_available": 1})        # older than history_days
    history.add({"at": now - 60, "mem_available": 2000})            # fresh: stays raw
    assert history.thin(now) == 6
    rows = db.all("SELECT at, data, thinned FROM samples ORDER BY at")
    assert len(rows) == 4, rows
    first = json.loads(rows[0]["data"])
    assert rows[0]["thinned"] == 1 and first["mem_available"] == 1005 and first["mem_available_min"] == 1000
    assert rows[-1]["thinned"] == 0
    assert history.thin(now) == 0                     # folding twice changes nothing
    assert len(history.since(24)) == 1 and len(history.since(24 * 4)) == 4
    assert len(average([{"at": 0, "cpu": 1}, {"at": 10, "cpu": 3}, {"at": 400, "cpu": 5}], 300)) == 2


def guard_levels():
    store = Settings(Path(tempfile.mkdtemp()) / "settings.json")
    assert level_of({"mem_available": 4000, "psi_some10": 0, "psi_full10": 0}, store) == "ok"
    assert level_of({"mem_available": 800, "psi_some10": 0, "psi_full10": 0}, store) == "tight"
    assert level_of({"mem_available": 4000, "psi_some10": 25, "psi_full10": 0}, store) == "tight"
    assert level_of({"mem_available": 400, "psi_some10": 0, "psi_full10": 0}, store) == "critical"
    assert level_of({"mem_available": 4000, "psi_some10": 0, "psi_full10": 11}, store) == "critical"
    assert level_of({"mem_available": None, "psi_some10": None, "psi_full10": None}, store) == "ok"
    # no PSI (the Pi): the fault rate
    assert level_of({"mem_available": 4000, "psi_some10": None, "faults": 3}, store) == "ok"
    assert level_of({"mem_available": 4000, "psi_some10": None, "faults": 80}, store) == "tight"
    assert level_of({"mem_available": 4000, "psi_some10": None, "faults": 400}, store) == "critical"


def nas_import():
    nas_db = load_nas("db")
    nas_auth = load_nas("auth")
    tmp = Path(tempfile.mkdtemp())
    source = nas_db.Db(tmp / "nas.db")              # the NAS's own schema
    source.run("INSERT INTO users(name, hash, role, totp, created) VALUES (?, ?, ?, ?, ?)",
               "lu", nas_auth.hash_password("nas password"), "admin", "JBSWY3DPEHPK3PXP", 1700000000)
    source.run("INSERT INTO users(name, hash, role, created) VALUES (?, ?, ?, ?)",
               "anna", nas_auth.hash_password("anna password"), "user", 1700000001)
    pc_token, phone_token = nas_auth.new_token(), nas_auth.new_token()
    source.run("INSERT INTO devices(id, name, kind, caps, token, mac, last_seen, last_address, created, by)"
               " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", "lu-pc", "lu-pc", "pc", '["files","worker","admin"]',
               nas_auth.token_hash(pc_token), "aa:bb:cc:dd:ee:ff", 1700000500, "192.168.178.30", 1700000100, "nasctl")
    source.run("INSERT INTO devices(id, name, kind, caps, token, created, by) VALUES (?, ?, ?, ?, ?, ?, ?)",
               "phone", "Pixel", "phone", '["files"]', nas_auth.token_hash(phone_token), 1700000200, "lu")
    source.run("INSERT INTO sessions(id, user, created, expires) VALUES ('x', 'lu', 0, 9999999999)")

    state = tmp / "core"
    ctl.main(["--state", str(state), "adduser", "anna", "--password", "already-here"])
    ctl.main(["--state", str(state), "import-nas", str(tmp / "nas.db")])
    db = Db(state / "core.db")
    users = {row["name"]: row for row in db.all("SELECT * FROM users")}
    assert set(users) == {"lu", "anna"}
    assert auth.check_password("nas password", users["lu"]["hash"]) and users["lu"]["role"] == "admin"
    assert users["lu"]["totp"] == "JBSWY3DPEHPK3PXP"
    assert auth.check_password("already-here", users["anna"]["hash"])          # existing name skipped
    devices = {row["id"]: row for row in db.all("SELECT * FROM devices")}
    assert json.loads(devices["lu-pc"]["scopes"]) == {"nas": ["files", "worker", "admin"], "core": ["read", "admin"]}
    assert json.loads(devices["phone"]["scopes"]) == {"nas": ["files"], "core": ["read"]}
    assert devices["lu-pc"]["mac"] == "aa:bb:cc:dd:ee:ff" and devices["lu-pc"]["last_ip"] == "192.168.178.30"
    assert devices["lu-pc"]["last_seen"] == 1700000500 and devices["phone"]["name"] == "Pixel"
    assert db.value("SELECT COUNT(*) FROM sessions") == 0                       # sessions are not taken
    # the NAS token works with core: found by hash
    store = Settings(state / "settings.json")
    from pshell_core.log import Log
    core_auth = auth.Auth(db, store, Log(db))
    assert core_auth.device_by_token(pc_token)["id"] == "lu-pc"
    assert core_auth.device_by_basic("Pixel", phone_token)["id"] == "phone"
    assert core_auth.device_by_basic("phone", pc_token) is None
    # again: nothing new, everything listed as skipped
    result = ctl.import_nas(db, tmp / "nas.db")
    assert result["users"]["added"] == [] and sorted(result["users"]["skipped"]) == ["anna", "lu"]
    assert result["devices"]["added"] == [] and sorted(result["devices"]["skipped"]) == ["lu-pc", "phone"]
    assert db.value("SELECT COUNT(*) FROM devices") == 2
    sqlite3.connect(tmp / "nas.db").close()


def ctl_commands():
    import contextlib
    import io
    state = Path(tempfile.mkdtemp()) / "state"

    def out(*args):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            ctl.main(["--state", str(state), *args])
        return buffer.getvalue().strip()

    password = out("adduser", "lu", "--admin")
    db = Db(state / "core.db")
    assert auth.check_password(password, db.value("SELECT hash FROM users WHERE name='lu'"))
    minted = json.loads(out("mint", "laptop", "laptop", '{"nas": ["files"], "core": ["read"]}'))
    assert minted["token"].startswith("psh_") and minted["id"].startswith("dev_")
    key = out("key", "nas")
    assert len(key) >= 40 and out("key", "nas") == key
    assert (state / "keys" / "nas.key").stat().st_mode & 0o777 == 0o600
    try:
        out("mint", "x", "pc", '{"nas": ["root"]}')
        raise AssertionError("an unknown cap was accepted")
    except SystemExit:
        pass
    try:
        out("key", "pihole")
        raise AssertionError("a key for an auth-own service")
    except SystemExit:
        pass
    new = out("passwd", "lu", "--clear-totp")
    assert new != password and auth.check_password(new, db.value("SELECT hash FROM users WHERE name='lu'"))
    assert json.loads(out("users"))["name"] == "lu"
    assert json.loads(out("devices"))["name"] == "laptop"
    out("settings", "set", "tight_mb", "1200")
    assert out("settings", "get", "tight_mb") == "1200"


async def main():
    passwords_and_totp()
    next_check()
    settings()
    health()
    guard_levels()
    nas_import()
    ctl_commands()


if __name__ == "__main__":
    run(main)
