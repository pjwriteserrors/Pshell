"""Pairing: a one-time secret, shown as a QR code, that a phone trades for trust.

The code carries where the PC is, the fingerprint of its certificate and the
secret. The phone connects, pins that fingerprint, and proves the secret while
handing over its own certificate. A secret works once, for two minutes, and
dies after a few wrong guesses.
"""

import asyncio
import hmac
import json
import secrets
import subprocess
import time
from urllib.parse import quote

from . import config

LIFETIME = 120
MAX_FAILURES = 5
SKIP_INTERFACES = ("lo", "docker", "br-", "virbr", "veth", "vnet")


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
        return {"active": True, "uri": self.uri(), "qr": str(self.qr_path()), "expires": int(self.expires * 1000)}

    def qr_path(self):
        return config.RUNTIME / "pairing.png"

    def start(self):
        self.secret = secrets.token_urlsafe(24)
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
        if not self.active:
            return False
        if not hmac.compare_digest(str(secret).encode(), self.secret.encode()):
            self.failures += 1
            if self.failures >= MAX_FAILURES:
                self.stop()
            return False
        self.stop()
        return True

    def _notify(self):
        if self.changed:
            self.changed()
