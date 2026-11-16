"""nasctl – the admin's way in from a shell on the Pi (inside the container):

  nasctl device add NAME --kind pc|laptop|phone --caps files,worker,admin [--mac aa:bb:…]
  nasctl device list | device remove ID
  nasctl user reset NAME [--password P]     (prints the new password once)
  nasctl user add NAME [--role admin|user] [--password P]
  nasctl user list
  nasctl settings get [KEY] | settings set KEY JSON

It works on nas.db and settings.json directly; the running server notices.
"""
import argparse
import json
import os
import sys
from pathlib import Path

from .auth import Auth, random_password
from .config import Settings
from .db import Db

ADDRESSES = {"home": "http://192.168.178.22:8096", "vpn": "http://10.8.0.1:8096"}


def main(argv=None):
    parser = argparse.ArgumentParser(prog="nasctl")
    parser.add_argument("--state", default=os.environ.get("NAS_STATE", "/storage/pshell-nas"))
    sub = parser.add_subparsers(dest="what", required=True)
    device = sub.add_parser("device").add_subparsers(dest="action", required=True)
    add = device.add_parser("add")
    add.add_argument("name")
    add.add_argument("--kind", default="pc")
    add.add_argument("--caps", default="files")
    add.add_argument("--mac", default="")
    add.add_argument("--json", action="store_true", help="the output is JSON anyway")
    device.add_parser("list")
    remove = device.add_parser("remove")
    remove.add_argument("id")
    user = sub.add_parser("user").add_subparsers(dest="action", required=True)
    reset = user.add_parser("reset")
    reset.add_argument("name")
    reset.add_argument("--password")
    user_add = user.add_parser("add")
    user_add.add_argument("name")
    user_add.add_argument("--role", default="user")
    user_add.add_argument("--password")
    user.add_parser("list")
    settings = sub.add_parser("settings").add_subparsers(dest="action", required=True)
    get = settings.add_parser("get")
    get.add_argument("key", nargs="?")
    put = settings.add_parser("set")
    put.add_argument("key")
    put.add_argument("value")
    args = parser.parse_args(argv)

    state = Path(args.state)
    if not (state / "nas.db").exists():
        sys.exit(f"No nas.db in {state} – has the server run once?")
    db = Db(state / "nas.db")
    store = Settings(state / "settings.json")
    auth = Auth(db, store)

    if args.what == "device":
        if args.action == "add":
            ident, token = auth.add_device(args.name, args.kind, args.caps.split(","), "nasctl", args.mac)
            print(json.dumps({"id": ident, "device": ident, "token": token, "server_id": db.meta("server_id"),
                              "addresses": ADDRESSES}))
        elif args.action == "list":
            for row in db.all("SELECT id, name, kind, caps, mac, last_seen, last_address FROM devices"):
                print(json.dumps(row))
        else:
            db.run("DELETE FROM devices WHERE id=?", args.id)
            print("removed", args.id)
    elif args.what == "user":
        if args.action == "list":
            for row in db.all("SELECT name, role, totp IS NOT NULL AS totp FROM users"):
                print(json.dumps(row))
            return
        password = args.password or random_password()
        if args.action == "reset":
            if not auth.user(args.name):
                auth.add_user(args.name, password, "admin" if args.name == "lu" else "user")
            else:
                auth.set_password(args.name, password)
                db.run("UPDATE users SET totp=NULL, totp_pending=NULL WHERE name=?", args.name)
        else:
            if auth.user(args.name):
                sys.exit("That user exists")
            auth.add_user(args.name, password, args.role)
        print(password)
    else:
        if args.action == "get":
            values = store.all(secrets=False)
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
