"""The admin's way in from a shell on the Pi (`docker exec pshell-core corectl …`):

  import-nas PATH                 users and devices from the NAS's nas.db (once; safe to repeat)
  adduser NAME [--admin]          prints a new password once
  passwd NAME [--clear-totp]      prints a new password once; ends the user's sessions
  mint NAME KIND SCOPES_JSON      a device; prints {id, token} (the token only here)
  key SERVICE                     prints the service's key, made when missing
  users | devices
  settings get [KEY] | settings set KEY JSON

It works on core.db and the state folder directly; the running server
notices (settings are re-read, the rest lives in sqlite).
"""
import argparse
import json
import os
import secrets
import shutil
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

from .auth import Auth, Refused, random_password
from .db import Db
from .log import Log
from .settings import Settings


class FileServices:
    """The caps of the services as services.json has them, without starting anything."""

    def __init__(self, state):
        self.state = Path(state)
        try:
            self.entries = json.loads((self.state / "services.json").read_text())
        except (OSError, ValueError):
            from .services import DEFAULTS
            self.entries = DEFAULTS

    def caps(self, name):
        entry = self.entries.get(name)
        return None if entry is None else list(entry.get("caps") or [])

    def key(self, name):
        entry = self.entries.get(name)
        if not entry or entry.get("auth") != "core":
            raise SystemExit(f"{name} is not a service with auth core in services.json")
        keys = self.state / "keys"
        keys.mkdir(parents=True, exist_ok=True)
        os.chmod(keys, 0o700)
        path = keys / f"{name}.key"
        if not path.exists():
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as handle:
                handle.write(secrets.token_urlsafe(32) + "\n")
        return path.read_text().strip()


def import_nas(db, path):
    """Users (name, hash, role, totp) and devices (by token hash) of the NAS; sessions are not taken."""
    if not Path(path).is_file():
        raise SystemExit(f"No such file: {path}")
    # a copy (with its WAL): /storage is mounted read-only and the NAS may be writing
    temp = tempfile.mkdtemp(prefix="nas-import-")
    for suffix in ("", "-wal"):
        if Path(f"{path}{suffix}").exists():
            shutil.copyfile(f"{path}{suffix}", f"{temp}/nas.db{suffix}")
    source = sqlite3.connect(f"{temp}/nas.db")
    source.row_factory = sqlite3.Row
    out = {"users": {"added": [], "skipped": []}, "devices": {"added": [], "skipped": []}}
    with db.transaction() as conn:
        for row in source.execute("SELECT name, hash, role, totp, created FROM users"):
            if conn.execute("SELECT 1 FROM users WHERE name=?", (row["name"],)).fetchone():
                out["users"]["skipped"].append(row["name"])
                continue
            conn.execute("INSERT INTO users(name, hash, role, totp, created) VALUES (?, ?, ?, ?, ?)",
                         (row["name"], row["hash"], row["role"] if row["role"] in ("admin", "user") else "user",
                          row["totp"], row["created"] or time.time()))
            out["users"]["added"].append(row["name"])
        for row in source.execute("SELECT * FROM devices"):
            row = dict(row)
            if conn.execute("SELECT 1 FROM devices WHERE id=? OR token=?", (row["id"], row["token"])).fetchone():
                out["devices"]["skipped"].append(row["id"])
                continue
            try:
                caps = [cap for cap in json.loads(row.get("caps") or "[]") if isinstance(cap, str)]
            except ValueError:
                caps = []
            scopes = {"nas": caps, "core": ["read"] + (["admin"] if "admin" in caps else [])}
            kind = row.get("kind") if row.get("kind") in ("pc", "laptop", "phone") else "other"
            conn.execute("INSERT INTO devices(id, name, kind, token, scopes, mac, created, by, last_seen, last_ip)"
                         " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                         (row["id"], row.get("name") or row["id"], kind, row["token"], json.dumps(scopes),
                          row.get("mac") or "", row.get("created") or time.time(),
                          f"import from nas ({row.get('by') or ''})".replace(" ()", ""), row.get("last_seen") or 0,
                          row.get("last_address") or ""))
            out["devices"]["added"].append(row["id"])
    source.close()
    shutil.rmtree(temp, ignore_errors=True)
    return out


def main(argv=None):
    try:
        run(argv)
    except (Refused, ValueError, KeyError) as error:
        sys.exit(f"corectl: {error}")


def run(argv=None):
    parser = argparse.ArgumentParser(prog="corectl")
    parser.add_argument("--state", default=os.environ.get("CORE_STATE", "/state"))
    sub = parser.add_subparsers(dest="what", required=True)
    sub.add_parser("import-nas").add_argument("path")
    add = sub.add_parser("adduser")
    add.add_argument("name")
    add.add_argument("--admin", action="store_true")
    add.add_argument("--password")
    passwd = sub.add_parser("passwd")
    passwd.add_argument("name")
    passwd.add_argument("--password")
    passwd.add_argument("--clear-totp", action="store_true")
    mint = sub.add_parser("mint")
    mint.add_argument("name")
    mint.add_argument("kind")
    mint.add_argument("scopes")
    mint.add_argument("--mac", default="")
    sub.add_parser("key").add_argument("service")
    sub.add_parser("users")
    sub.add_parser("devices")
    settings = sub.add_parser("settings").add_subparsers(dest="action", required=True)
    settings.add_parser("get").add_argument("key", nargs="?")
    put = settings.add_parser("set")
    put.add_argument("key")
    put.add_argument("value")
    args = parser.parse_args(argv)

    state = Path(args.state)
    state.mkdir(parents=True, exist_ok=True)
    db = Db(state / "core.db")
    store = Settings(state / "settings.json")
    log = Log(db)
    auth = Auth(db, store, log)
    auth.services = FileServices(state)

    if args.what == "import-nas":
        result = import_nas(db, args.path)
        log.add("user_added", "corectl", "", {"import_nas": result["users"]["added"]})
        print(json.dumps(result, indent=1))
    elif args.what == "adduser":
        password = args.password or random_password()
        auth.add_user(args.name, password, "admin" if args.admin else "user")
        log.add("user_added", "corectl", "", {"user": args.name})
        print(password)
    elif args.what == "passwd":
        if not auth.user(args.name):
            sys.exit("No such user")
        password = args.password or random_password()
        auth.set_password(args.name, password)
        if args.clear_totp:
            db.run("UPDATE users SET totp=NULL, totp_pending=NULL WHERE name=?", args.name)
            log.add("totp_off", "corectl", "", {"user": args.name})
        log.add("password_changed", "corectl", "", {"user": args.name})
        print(password)
    elif args.what == "mint":
        try:
            scopes = json.loads(args.scopes)
        except ValueError:
            sys.exit('SCOPES_JSON is like {"nas": ["files"], "core": ["read"]}')
        row, token = auth.add_device(args.name, args.kind, scopes, "corectl", args.mac)
        log.add("device_added", "corectl", "", {"id": row["id"], "name": row["name"]})
        print(json.dumps({"id": row["id"], "device": row["id"], "name": row["name"], "token": token,
                          "scopes": json.loads(row["scopes"])}))
    elif args.what == "key":
        print(auth.services.key(args.service))
    elif args.what == "users":
        for row in auth.users():
            print(json.dumps(row))
    elif args.what == "devices":
        for row in db.all("SELECT * FROM devices ORDER BY name"):
            print(json.dumps(auth.device_json(row)))
    else:
        if args.action == "get":
            values = store.all()
            print(json.dumps(values.get(args.key) if args.key else values, indent=1))
        else:
            try:
                value = json.loads(args.value)
            except ValueError:
                value = args.value
            store.update({args.key: value})
            print(json.dumps(store.get(args.key)))


if __name__ == "__main__":
    main()
