"""Pairing: a one-time secret, shown as a QR code, that a phone trades for trust.

The code carries where the PC is, the fingerprint of its certificate and the
secret. The phone connects, pins that fingerprint, and proves the secret while
handing over its own certificate. A secret works once, for two minutes, and
dies after a few wrong guesses.

The secret is short enough to type (ABCDE-FGHJK), for another PC: it learns
the certificate only during the handshake, so it never sends the secret
itself but an HMAC of it over both fingerprints, and the PC answers with one
of its own. A machine in between holds other certificates, so neither proof
it could pass on fits, and it cannot guess the secret within two minutes.
"""

import asyncio
import hmac
import json
import secrets
import subprocess
import time
import hashlib
from urllib.parse import quote

from . import config

LIFETIME = 120
MAX_FAILURES = 5
SKIP_INTERFACES = ("lo", "docker", "br-", "virbr", "veth", "vnet")
# no 0/O, 1/I/L: what is read off a screen is typed right
ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"


def new_secret():
    code = "".join(secrets.choice(ALPHABET) for _ in range(10))
    return f"{code[:5]}-{code[5:]}"


def normalize(code):
    return "".join(c for c in str(code).upper() if c.isalnum())


def proof(secret, label, first, second):
    """What a PC sends instead of the secret: bound to both certificates."""
    message = f"pshell-{label}|{first}|{second}".encode()
    return hmac.new(normalize(secret).encode(), message, hashlib.sha256).hexdigest()


def addresses():
    """Where a phone may find this PC: the profile's own addresses first
    (a VPN name, say), then every address of a real interface."""
    found = [str(a) for a in config.settings().get("addresses", [])]
    try:
        output = subprocess.run(["ip", "-j", "-4", "addr"], capture_output=True, text=True, timeout=5).stdout
        for interface in json.loads(output or "[]"):
            if interface.get("ifname", "").startswith(SKIP_INTERFACES):
                continue
            for info in interface.get("addr_info", []):
                if info.get("local") and info["local"] not in found:
                    found.append(info["local"])
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return found


class Pairing:
    def __init__(self, fingerprint):
        self.fingerprint = fingerprint
        self.secret = None
        self.expires = 0
        self.failures = 0
        self.changed = None  # set by the feature: called when the state changes
        self._timer = None

    @property
    def active(self):
        return self.secret is not None and time.time() < self.expires

    def uri(self):
        return (
            f"pshell://pair?v={config.VERSION}&n={quote(config.hostname())}&a={quote(','.join(addresses()))}"
            f"&p={config.port()}&f={self.fingerprint}&s={self.secret}"
        )

    def state(self):
        if not self.active:
            return {"active": False}
        return {"active": True, "uri": self.uri(), "code": self.secret, "qr": str(self.qr_path()), "expires": int(self.expires * 1000)}

    def qr_path(self):
        return config.RUNTIME / "pairing.png"

    def start(self):
        self.secret = new_secret()
        self.expires = time.time() + LIFETIME
        self.failures = 0
        try:
            subprocess.run(["qrencode", "-o", str(self.qr_path()), "-s", "12", "-m", "2", "-l", "M", self.uri()], check=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            pass
        if self._timer:
            self._timer.cancel()
        self._timer = asyncio.get_running_loop().call_later(LIFETIME + 0.5, self._notify)
        self._notify()
        return self.state()

    def stop(self):
        self.secret = None
        self.qr_path().unlink(missing_ok=True)
        self._notify()

    def claim(self, secret):
        """True exactly once, for the right secret, while it is valid."""
        return self.claim_by(lambda known: hmac.compare_digest(normalize(secret).encode(), normalize(known).encode()))

    def claim_by(self, check):
        """Like claim, for a proof of the secret: check(secret) says whether it fits."""
        if not self.active:
            return False
        if not check(self.secret):
            self.failures += 1
            if self.failures >= MAX_FAILURES:
                self.stop()
            return False
        self.stop()
        return True

    def _notify(self):
        if self.changed:
            self.changed()
