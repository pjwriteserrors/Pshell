"""The security log: sign-ins, devices, confirmations, container actions,
memory pressure and services going down. Kept 90 days; the portal and the
shell read it, nothing acts on it.
"""
import json
import time

KINDS = ("login", "login_failed", "locked", "logout", "device_added", "device_revoked", "token_rotated",
         "device_changed", "password_changed", "totp_on", "totp_off", "user_added", "user_removed",
         "user_changed", "confirm", "container_action", "pressure", "service_down", "service_up",
         "settings_changed", "service_changed", "smarthome_changed")
KEEP_DAYS = 90


class Log:
    def __init__(self, db):
        self.db = db

    def add(self, kind, who="", ip="", detail=""):
        if isinstance(detail, (dict, list)):
            detail = json.dumps(detail, separators=(",", ":"))
        self.db.run("INSERT INTO log(at, kind, who, ip, detail) VALUES (?, ?, ?, ?, ?)",
                    time.time(), kind, str(who or ""), ip or "", str(detail or "")[:2000])

    def list(self, kind="", limit=100, who=None, before=None):
        sql = "SELECT at, kind, who, ip, detail FROM log WHERE 1=1"
        args = []
        if kind:
            kinds = [item for item in kind.split(",") if item]
            sql += f" AND kind IN ({','.join('?' * len(kinds))})"
            args += kinds
        if who is not None:
            sql += " AND who=?"
            args.append(who)
        if before:
            sql += " AND at<?"
            args.append(float(before))
        sql += " ORDER BY at DESC, id DESC LIMIT ?"
        args.append(max(1, min(1000, int(limit or 100))))
        return self.db.all(sql, *args)

    def prune(self):
        self.db.run("DELETE FROM log WHERE at<?", time.time() - KEEP_DAYS * 86400)
