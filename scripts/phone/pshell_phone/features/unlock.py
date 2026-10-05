"""unlock: a fingerprint on the phone unlocks the PC's lock screen.

The phone makes a second key in its secure hardware, one that signs only
right after a fingerprint. Its public half is enrolled here, once, while the
PC is unlocked and somebody confirms it on the PC. To unlock, the phone asks
for a challenge, signs it, and the daemon checks the signature before it
tells the shell to lift the lock.

Only on the local network, only for the lock screen: the keyring stays
locked, since no password was entered. Off unless phone-unlock is on.
"""

import asyncio
import base64
import ipaddress
import json
import os
import secrets
import time

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from .. import config
from ..hub import Refused

FILE = config.STATE / "unlock.json"
CHALLENGE_SECONDS = 60


def load():
    try:
        data = json.loads(FILE.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save(keys):
    descriptor = os.open(FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(keys, handle, indent="\t")


def local(address):
    try:
        ip = ipaddress.ip_address(str(address).split("%")[0])
    except ValueError:
        return False
    return ip.is_private or ip.is_loopback or ip.is_link_local


def setup(hub, daemon):
    challenges = {}  # device id → (nonce, expires)
    proofs = {}  # proof id → (nonce, future): sudo and the like, waiting for a fingerprint

    @hub.action("unlock", "status", kinds=("phone",))
    async def status(peer, _args):
        return {"enrolled": peer.device_id in load(), "local": local(peer.address)}

    @hub.action("unlock", "enroll", kinds=("phone",))
    async def enroll(peer, args):
        try:
            der = base64.b64decode(str(args.get("key", "")))
            key = serialization.load_der_public_key(der)
            if not isinstance(key, ec.EllipticCurvePublicKey):
                raise ValueError
        except (ValueError, TypeError):
            raise Refused("bad-key", "Not a key") from None
        if (hub.state.get("session") or {}).get("locked"):
            raise Refused("locked", "Unlock the PC first")
        answer = await hub.call("session", "confirm", {
            "title": f"Let {peer.name} unlock this PC?",
            "body": "A fingerprint on that phone will lift the lock screen while it is in this network.",
            "accept": "Allow",
        }, timeout=90)
        if not (answer or {}).get("accepted"):
            raise Refused("denied", "Not allowed on the PC")
        keys = load()
        keys[peer.device_id] = base64.b64encode(der).decode()
        save(keys)
        return {"enrolled": True}

    @hub.action("unlock", "forget", kinds=("phone",))
    async def forget(peer, _args):
        keys = load()
        if keys.pop(peer.device_id, None) is not None:
            save(keys)
        return {}

    @hub.action("unlock", "challenge", kinds=("phone",))
    async def challenge(peer, _args):
        if peer.device_id not in load():
            raise Refused("not-enrolled", "This phone may not unlock the PC")
        if not local(peer.address):
            raise Refused("not-local", "Only in the same network")
        nonce = secrets.token_bytes(32)
        challenges[peer.device_id] = (nonce, time.time() + CHALLENGE_SECONDS)
        return {"nonce": base64.b64encode(nonce).decode()}

    @hub.action("unlock", "answer", kinds=("phone",))
    async def answer(peer, args):
        nonce, expires = challenges.pop(peer.device_id, (None, 0))
        stored = load().get(peer.device_id)
        if nonce is None or time.time() > expires or stored is None or not local(peer.address):
            raise Refused("no-challenge", "Ask for a new challenge")
        try:
            key = serialization.load_der_public_key(base64.b64decode(stored))
            key.verify(base64.b64decode(str(args.get("signature", ""))), nonce, ec.ECDSA(hashes.SHA256()))
        except (InvalidSignature, ValueError, TypeError):
            raise Refused("bad-signature", "That signature does not fit") from None
        await hub.call("session", "unlock", {}, timeout=10)
        return {"unlocked": True}

    # ── a fingerprint for something else: sudo, say ────────────────────────
    @hub.action("unlock", "pam", kinds=("cli", "shell"))
    async def pam(_peer, args):
        """Asks every enrolled, connected phone for a fingerprint and waits for
        the first; scripts/phone/pam_phone uses it from PAM."""
        keys = load()
        phones = [peer for peer in hub.phones() if peer.device_id in keys and local(peer.address)]
        if not phones:
            raise Refused("no-phone", "No enrolled phone is connected")
        nonce = secrets.token_bytes(32)
        proof_id = str(args.get("id") or secrets.token_hex(8))[:32]
        future = asyncio.get_running_loop().create_future()
        proofs[proof_id] = (nonce, future)
        request = {
            "id": proof_id,
            "nonce": base64.b64encode(nonce).decode(),
            "title": str(args.get("what") or f"Allow on {config.hostname()}?"),
            "body": str(args.get("body") or "Put your finger on the sensor to allow it."),
            "timeout": int(args.get("timeout", 60)),
        }
        for peer in phones:
            hub.spawn(hub.call("phone.unlock", "prove", request, device_id=peer.device_id, timeout=int(args.get("timeout", 60)) + 5))
        try:
            device_id = await asyncio.wait_for(future, int(args.get("timeout", 60)))
        except asyncio.TimeoutError:
            raise Refused("timeout", "Nobody put a finger on it") from None
        finally:
            proofs.pop(proof_id, None)
            # the password was typed, the asker gave up, or a finger came: the phones let go of the request
            for peer in phones:
                hub.spawn(hub.call("phone.unlock", "settle", {"id": proof_id}, device_id=peer.device_id, timeout=5))
        return {"device": device_id, "name": (hub.devices.get(device_id) or {}).get("name", "")}

    @hub.action("unlock", "prove", kinds=("phone",))
    async def prove(peer, args):
        """The phone's signature for a request of `pam`."""
        entry = proofs.get(str(args.get("id", "")))
        stored = load().get(peer.device_id)
        if entry is None or stored is None or not local(peer.address):
            raise Refused("no-challenge", "That request is gone")
        nonce, future = entry
        try:
            key = serialization.load_der_public_key(base64.b64decode(stored))
            key.verify(base64.b64decode(str(args.get("signature", ""))), nonce, ec.ECDSA(hashes.SHA256()))
        except (InvalidSignature, ValueError, TypeError):
            raise Refused("bad-signature", "That signature does not fit") from None
        if not future.done():
            future.set_result(peer.device_id)
        return {"accepted": True}

    @hub.hook("devices")
    async def cleanup():
        """A phone that was un-paired may not unlock any more."""
        keys = load()
        kept = {device_id: key for device_id, key in keys.items() if hub.devices.get(device_id)}
        if kept != keys:
            save(kept)
