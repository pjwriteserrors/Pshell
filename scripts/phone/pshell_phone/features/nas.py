"""nas: the phone's way into pshell-nas (docs/nas.md, "Phone"; docs/mobile.md, "NAS").

The NAS knows devices by a Bearer token of their own. The phone gets its
token from here: when a paired phone connects and has none yet, this PC
mints one (kind "phone", cap "files") and sends it as the event `nas.token`;
the app asks with `nas token` too (`fresh: true` when the NAS refused the one
it has). A token is minted once per phone and kept in the daemon's state
(`phone/nas.json`, mode 600), so a reconnect does not make a new device on the
NAS each time.

Minting goes through `scripts/nas/nas.py call mint` (the PC's NAS client),
or – where that is missing – straight to the NAS with the PC's admin token from
`~/.local/state/pshell/nas.json` (`POST /api/devices`).

The laptop asks for a token of its own over the PC link (`pc.nas-token`,
features/pcs.py), minted the same way with kind "laptop".

  nas token {fresh?}  → { server_id, addresses: {home, vpn}, device, token, name }
  nas open {path}     → opens a NAS path on this PC (scripts/ipc.sh nas open)
"""

import asyncio
import json
import os
import sys
import time

import aiohttp

from .. import config
from ..hub import Refused

ADDRESSES = {"home": "http://192.168.178.22:8096", "vpn": "http://10.8.0.1:8096"}
CACHE = config.STATE / "nas.json"


def nas_script():
    """scripts/nas/nas.py; PSHELL_NAS_PY points elsewhere (the tests: "" for none)."""
    override = os.environ.get("PSHELL_NAS_PY")
    if override is None:
        return str(config.ROOT / "scripts" / "nas" / "nas.py")
    return override or None


def pc_state():
    """The PC's own NAS settings: its admin token, the addresses, the server id."""
    try:
        value = json.loads((config.host.state_dir() / "nas.json").read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def addresses(value):
    """{home, vpn} from whatever form the PC keeps them in (a dict, or a list of URLs)."""
    found = {}
    if isinstance(value, dict):
        found = {key: str(value.get(key) or "") for key in ("home", "vpn")}
    elif isinstance(value, list):
        for url in map(str, value):
            if "//10.8." in url:
                found.setdefault("vpn", url)
            else:
                found.setdefault("home", url)
    for key, default in ADDRESSES.items():
        if not found.get(key):
            found[key] = default
    return {key: found[key].rstrip("/") for key in ("home", "vpn")}


def configured():
    """Whether this PC has a NAS token of its own (nas.py needs it as much as the fallback)."""
    return bool(pc_state().get("token"))


async def mint_with_script(script, name, kind):
    process = await asyncio.create_subprocess_exec(
        sys.executable, str(script), "call", "mint", json.dumps({"name": name, "kind": kind}),
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(process.communicate(), 30)
    except asyncio.TimeoutError:
        process.kill()
        raise Refused("timeout", "The NAS did not answer") from None
    text = out.decode(errors="replace").strip()
    # nas.py prints the data indented; a single line from anything else
    answer = {}
    for candidate in (text, text.splitlines()[-1] if text else ""):
        try:
            answer = json.loads(candidate) if candidate else {}
            break
        except ValueError:
            continue
    # {ok, data} like the socket answers, or the data as it is
    if isinstance(answer, dict) and "ok" in answer:
        if not answer.get("ok"):
            error = answer.get("error")
            raise Refused("nas", str(error.get("message") if isinstance(error, dict) else error or "The NAS refused"))
        answer = answer.get("data") or {}
    if process.returncode != 0 or not isinstance(answer, dict) or not answer.get("token"):
        raise Refused("nas", (err.decode(errors="replace").strip().splitlines() or ["Could not mint a NAS token"])[-1][:300])
    return answer


async def mint_over_http(name, kind):
    state = pc_state()
    token = state.get("token")
    if not token:
        raise Refused("no-nas", "This PC is not set up for the NAS")
    found = addresses(state.get("addresses"))
    last = "The NAS is not reachable"
    timeout = aiohttp.ClientTimeout(total=15, sock_connect=4)
    async with aiohttp.ClientSession(timeout=timeout, headers={"Authorization": f"Bearer {token}"}) as session:
        for base in (found["home"], found["vpn"]):
            try:
                async with session.get(f"{base}/api/hello") as response:
                    hello = await response.json(content_type=None)
                server_id = str(hello.get("server_id") or "")
                if state.get("server_id") and server_id != state["server_id"]:
                    last = f"{base} is another server"
                    continue
                async with session.post(f"{base}/api/devices", json={"name": name, "kind": kind, "caps": ["files"]}) as response:
                    answer = await response.json(content_type=None)
                    if response.status >= 400:
                        raise Refused("nas", str((answer or {}).get("error") or f"HTTP {response.status}"))
                device = answer.get("device") if isinstance(answer.get("device"), dict) else answer
                return {
                    "id": str(device.get("id") or answer.get("id") or ""),
                    "token": str(answer.get("token") or device.get("token") or ""),
                    "server_id": server_id,
                    "addresses": found,
                }
            except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ValueError, AttributeError) as error:
                last = f"{base}: {error or type(error).__name__}"
    raise Refused("unreachable", last)


async def mint(name, kind):
    """A new device token on the NAS: {id, token, server_id, addresses}."""
    script = nas_script()
    if script and os.path.exists(script):
        answer = await mint_with_script(script, name, kind)
    else:
        answer = await mint_over_http(name, kind)
    if not answer.get("token"):
        raise Refused("nas", "The NAS gave no token")
    return answer


def setup(hub, daemon):
    daemon.nas = Feature(hub, daemon)


class Feature:
    def __init__(self, hub, daemon):
        self.hub = hub
        self.daemon = daemon
        self.lock = asyncio.Lock()
        self.cache = self.load()
        hub.hooks["connect"].append(self.connected)

        @hub.action("nas", "token", kinds=("phone",))
        async def token(peer, args):
            return await self.token_for(peer.device_id, "phone", fresh=bool(args.get("fresh")))

        @hub.action("nas", "open", kinds=("phone", "shell", "cli"))
        async def open_path(_peer, args):
            path = str(args.get("path") or "")
            if not path.startswith("/") or "\0" in path or "/../" in f"{path}/":
                raise Refused("bad-path", "A NAS path is needed")
            ipc = config.ROOT / "scripts" / "ipc.sh"
            process = await asyncio.create_subprocess_exec(str(ipc), "nas", "open", path, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            try:
                out, err = await asyncio.wait_for(process.communicate(), 15)
            except asyncio.TimeoutError:
                process.kill()
                raise Refused("timeout", "The shell did not answer") from None
            if process.returncode != 0:
                raise Refused("failed", (err or out).decode(errors="replace").strip()[:300] or "The shell could not open it")
            return {}

        @hub.action("nas", "tokens", kinds=("shell", "cli"))
        async def tokens(_peer, _args):
            """Which devices got a token from here (without the tokens)."""
            return {"devices": [{"for": key, "device": value.get("device", ""), "name": value.get("name", ""), "kind": value.get("kind", ""), "minted": value.get("minted", 0)} for key, value in self.cache.items()]}

        @hub.action("nas", "forget", kinds=("shell", "cli"))
        async def forget(_peer, args):
            self.cache.pop(str(args.get("id") or ""), None)
            self.save()
            return {}

    # ── the cache ──────────────────────────────────────────────────────────
    def load(self):
        try:
            value = json.loads(CACHE.read_text())
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    def save(self):
        temporary = CACHE.with_suffix(".tmp")
        with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            json.dump(self.cache, file, indent=1)
        os.replace(temporary, CACHE)

    # ── tokens ─────────────────────────────────────────────────────────────
    async def token_for(self, device_id, kind, fresh=False):
        """The token of one paired device, minted the first time it is asked for."""
        device = self.hub.devices.get(device_id) if device_id else None
        if device is None:
            raise Refused("not-paired", "Only a paired device gets a NAS token")
        async with self.lock:
            entry = self.cache.get(device_id)
            server_id = str(pc_state().get("server_id") or "")
            stale = entry is None or fresh or (server_id and entry.get("server_id") and entry["server_id"] != server_id)
            if stale:
                name = str(device.get("name") or kind)
                answer = await mint(name, kind)
                entry = {
                    "server_id": str(answer.get("server_id") or server_id),
                    "addresses": addresses(answer.get("addresses")),
                    "device": str(answer.get("id") or answer.get("device") or ""),
                    "token": str(answer["token"]),
                    "name": name,
                    "kind": kind,
                    "minted": int(time.time()),
                }
                self.cache[device_id] = entry
                self.save()
        return {key: entry[key] for key in ("server_id", "addresses", "device", "token", "name")}

    async def connected(self, peer):
        """A phone that comes is handed its token, minted the first time."""
        if peer.kind != "phone" or getattr(peer, "watch", False) or not self.hub.allowed("nas"):
            return
        if peer.device_id not in self.cache and not configured():
            return

        async def hand():
            try:
                data = await self.token_for(peer.device_id, "phone")
            except Refused as refused:
                print(f"phone: no NAS token for {peer.name or peer.device_id}: {refused.message}", flush=True)
                return
            # to this phone only: hub.emit would show the shell the token too
            if peer in self.hub.peers and self.hub.allowed("nas"):
                await self.hub.send(peer, {"type": "event", "topic": "nas", "name": "token", "data": data})

        self.hub.spawn(hand())
