"""The message bus between phones, the shell and the daemon's own features.

Every topic of mobile/protocol/protocol.json has one owner: the daemon, the
shell or the phone. The owner publishes the topic's state and answers its
calls; everybody else subscribes and calls. The hub caches the last snapshot,
routes calls to the owner and refuses whatever belongs to a plugin that is off.
"""

import asyncio
import hashlib
import hmac
import itertools
import json
import os
import secrets
import time
from pathlib import Path

from . import config

DEFAULT_TIMEOUT = 15
MAX_TIMEOUT = 3600


class Refused(Exception):
    def __init__(self, code, message=""):
        super().__init__(message or code)
        self.code = code
        self.message = message or code


class Peer:
    """One connection: a phone, the shell, or a command line tool."""

    kind = "cli"
    device = None  # the paired device, for phones

    def __init__(self):
        self.subs = set()
        self.name = ""
        self.calls = set()  # calls this peer made that are still being answered

    async def send(self, message):
        raise NotImplementedError

    async def send_bytes(self, data):
        pass

    @property
    def device_id(self):
        return self.device["id"] if self.device else None


class Blobs:
    """Files the phone may fetch: a token stands for one path at one mtime."""

    def __init__(self):
        self.secret = secrets.token_bytes(32)
        self.paths = {}

    def offer(self, path):
        path = str(path)
        if path.startswith("file://"):
            path = path[7:]
        try:
            stamp = os.stat(path).st_mtime_ns
        except OSError:
            return None
        token = hmac.new(self.secret, f"{path}|{stamp}".encode(), hashlib.sha256).hexdigest()[:40]
        self.paths[token] = path
        return f"/blob/{token}"

    def path(self, token):
        return self.paths.get(token)

    def wrap(self, data):
        """Replaces every {"$blob": path} with the URL the phone fetches it from;
        URLs that are not local files pass through."""
        if isinstance(data, dict):
            if set(data) == {"$blob"}:
                value = str(data["$blob"] or "")
                if value.startswith(("http://", "https://")):
                    return value
                return self.offer(value) if value else None
            return {key: self.wrap(value) for key, value in data.items()}
        if isinstance(data, list):
            return [self.wrap(value) for value in data]
        return data


class Hub:
    def __init__(self, devices):
        self.devices = devices
        self.topics = config.PROTOCOL["topics"]
        self.state = {}  # topic → data (daemon and shell topics)
        self.phone_state = {}  # device id → { topic → data }
        self.peers = set()
        self.actions = {}  # (topic, action) → (function, kinds)
        self.listeners = {}  # (topic, name) → [function]
        self.binary = {}  # frame type → function(peer, payload)
        self.pending = {}  # hub call id → future
        self.tasks = set()
        self.blobs = Blobs()
        self.ids = itertools.count(1)
        self.wanted = set()
        self._plugins = {}
        self._plugins_stamp = None
        self.hooks = {"connect": [], "disconnect": [], "plugins": [], "devices": []}

    # ── plugins ────────────────────────────────────────────────────────────
    def plugin_files(self):
        return (
            config.ROOT / "core" / "plugins.json",
            config.host.state_dir() / "plugins.json",
            config.ROOT / "hosts" / f"{config.host.profile_name()}.json",
            config.PROTOCOL_FILE,
        )

    def plugins(self):
        stamp = tuple(path.stat().st_mtime_ns if path.exists() else 0 for path in self.plugin_files())
        if stamp != self._plugins_stamp:
            self._plugins_stamp = stamp
            self._plugins = config.host.plugins()
            self.reload_catalogue()
        return self._plugins

    def reload_catalogue(self):
        """The catalogue is read again when it changes (a pull, a new topic)."""
        try:
            self.topics = json.loads(config.PROTOCOL_FILE.read_text())["topics"]
        except (OSError, ValueError, KeyError):
            pass

    def on(self, plugin):
        return self.plugins().get(plugin) is True

    def allowed(self, topic):
        spec = self.topics.get(topic)
        if spec is None:
            return False
        return self.on("phone") and all(self.on(plugin) for plugin in spec.get("plugins", []))

    def visible(self, topic, peer):
        """Topics marked local never leave the PC."""
        return peer.kind != "phone" or not self.topics.get(topic, {}).get("local")

    # ── registration (features) ────────────────────────────────────────────
    def action(self, topic, name, kinds=("phone", "shell", "cli")):
        def register(function):
            self.actions[(topic, name)] = (function, kinds)
            return function
        return register

    def on_event(self, topic, name):
        def register(function):
            self.listeners.setdefault((topic, name), []).append(function)
            return function
        return register

    def on_binary(self, kind):
        def register(function):
            self.binary[kind] = function
            return function
        return register

    def hook(self, name):
        def register(function):
            self.hooks[name].append(function)
            return function
        return register

    def spawn(self, coroutine):
        task = asyncio.get_running_loop().create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self._done)
        return task

    def _done(self, task):
        self.tasks.discard(task)
        if not task.cancelled() and task.exception():
            print(f"phone: task failed: {task.exception()!r}", flush=True)

    # ── peers ──────────────────────────────────────────────────────────────
    def phones(self):
        return [peer for peer in self.peers if peer.kind == "phone"]

    def phone(self, device_id=None):
        phones = self.phones()
        if device_id:
            return next((peer for peer in phones if peer.device_id == device_id), None)
        return phones[0] if phones else None

    def shell(self):
        return next((peer for peer in self.peers if peer.kind == "shell"), None)

    async def attach(self, peer):
        self.peers.add(peer)
        if peer.kind == "shell":
            await self.send(peer, {"type": "want", "topics": sorted(self.wanted)})
        for function in self.hooks["connect"]:
            await function(peer)

    async def detach(self, peer):
        self.peers.discard(peer)
        for task in list(peer.calls):
            task.cancel()
        if peer.kind == "shell":
            # what the shell published is stale without it
            for topic, spec in self.topics.items():
                if spec["owner"] == "shell" and topic in self.state:
                    del self.state[topic]
        if peer.kind == "phone" and not self.phone(peer.device_id):
            self.phone_state.pop(peer.device_id, None)
        for function in self.hooks["disconnect"]:
            await function(peer)
        await self.update_wanted()

    async def send(self, peer, message):
        try:
            await peer.send(message)
        except Exception:  # a peer that went away is detached by its reader
            pass

    async def update_wanted(self):
        wanted = set()
        for peer in self.peers:
            if peer.kind != "shell":
                wanted |= {topic for topic in peer.subs if self.topics.get(topic, {}).get("owner") == "shell"}
        if wanted != self.wanted:
            self.wanted = wanted
            for peer in self.peers:
                if peer.kind == "shell":
                    await self.send(peer, {"type": "want", "topics": sorted(wanted)})

    # ── state ──────────────────────────────────────────────────────────────
    async def publish(self, topic, data, device_id=None):
        """Stores a snapshot and sends it to every subscriber."""
        owner = self.topics.get(topic, {}).get("owner")
        if owner == "phone":
            if device_id is None:
                return
            self.phone_state.setdefault(device_id, {})[topic] = data
        else:
            if self.state.get(topic) == data and topic in self.state:
                return
            self.state[topic] = data
        if not self.allowed(topic):
            return
        message = {"type": "state", "topic": topic, "data": data}
        if device_id:
            message["device"] = device_id
        for peer in list(self.peers):
            if topic in peer.subs and self.visible(topic, peer) and peer.device_id != (device_id or object()):
                await self.send(peer, message)

    async def snapshot(self, peer, topic):
        if not self.allowed(topic) or not self.visible(topic, peer):
            return
        if self.topics[topic]["owner"] == "phone":
            for device_id, topics in self.phone_state.items():
                if topic in topics and device_id != peer.device_id:
                    await self.send(peer, {"type": "state", "topic": topic, "data": topics[topic], "device": device_id})
        elif topic in self.state:
            await self.send(peer, {"type": "state", "topic": topic, "data": self.state[topic]})

    # ── events ─────────────────────────────────────────────────────────────
    async def emit(self, topic, name, data=None, device_id=None, source=None):
        """An event from the daemon or the shell goes to the phones; one from a
        phone goes to the shell. Listeners in the daemon hear both."""
        if not self.allowed(topic):
            return
        for function in self.listeners.get((topic, name), []):
            self.spawn(function(source, data or {}))
        message = {"type": "event", "topic": topic, "name": name, "data": data or {}}
        from_phone = source is not None and source.kind == "phone"
        if from_phone:
            message["device"] = source.device_id
        for peer in list(self.peers):
            if peer is source or not self.visible(topic, peer):
                continue
            if from_phone and peer.kind != "shell":
                continue
            if not from_phone and peer.kind != "phone" and not (source is None and peer.kind == "shell"):
                continue
            if peer.kind == "phone" and device_id and peer.device_id != device_id:
                continue
            await self.send(peer, message)

    # ── calls ──────────────────────────────────────────────────────────────
    async def call(self, topic, action, args=None, device_id=None, timeout=DEFAULT_TIMEOUT, origin=None):
        """Calls a topic's owner and returns its answer; raises Refused."""
        spec = self.topics.get(topic)
        if spec is None:
            raise Refused("unknown-topic", topic)
        if not self.allowed(topic):
            raise Refused("plugin-off", topic)
        if origin is not None and not self.visible(topic, origin):
            raise Refused("local-only", topic)
        args = args or {}
        owner = spec["owner"]
        if owner == "daemon":
            entry = self.actions.get((topic, action))
            if entry is None:
                raise Refused("unknown-action", f"{topic}.{action}")
            function, kinds = entry
            if origin is not None and origin.kind not in kinds:
                raise Refused("not-allowed", f"{topic}.{action}")
            return await function(origin, args)
        target = self.shell() if owner == "shell" else self.phone(device_id)
        if target is None:
            raise Refused("unreachable", owner)
        call_id = f"h{next(self.ids)}"
        future = asyncio.get_running_loop().create_future()
        self.pending[call_id] = future
        message = {"type": "call", "id": call_id, "topic": topic, "action": action, "args": args}
        if origin is not None and origin.device_id:
            message["device"] = origin.device_id
        try:
            await target.send(message)
            return await asyncio.wait_for(future, min(MAX_TIMEOUT, max(1, timeout)))
        except asyncio.TimeoutError:
            await self.send(target, {"type": "cancel", "id": call_id})
            raise Refused("timeout", f"{topic}.{action}") from None
        except asyncio.CancelledError:
            # whoever asked is gone: the owner need not go on (a question on the phone closes)
            await self.send(target, {"type": "cancel", "id": call_id})
            raise
        finally:
            self.pending.pop(call_id, None)

    async def _answer(self, peer, message):
        call_id = message.get("id")
        try:
            data = await self.call(
                str(message.get("topic", "")),
                str(message.get("action", "")),
                message.get("args") if isinstance(message.get("args"), dict) else {},
                device_id=message.get("device"),
                timeout=float(message.get("timeout") or DEFAULT_TIMEOUT),
                origin=peer,
            )
            result = {"type": "result", "id": call_id, "ok": True, "data": data}
        except Refused as refused:
            result = {"type": "result", "id": call_id, "ok": False, "error": {"code": refused.code, "message": refused.message}}
        except Exception as error:  # a feature that fails must not take the link down
            print(f"phone: {message.get('topic')}.{message.get('action')} failed: {error!r}", flush=True)
            result = {"type": "result", "id": call_id, "ok": False, "error": {"code": "failed", "message": str(error)}}
        if call_id is not None:
            await self.send(peer, result)

    # ── incoming ───────────────────────────────────────────────────────────
    async def receive(self, peer, message):
        kind = message.get("type")
        if kind == "sub":
            topics = [t for t in message.get("topics", []) if t in self.topics and self.visible(t, peer)]
            fresh = [t for t in topics if t not in peer.subs]
            peer.subs |= set(topics)
            await self.update_wanted()
            for topic in fresh:
                await self.snapshot(peer, topic)
        elif kind == "unsub":
            peer.subs -= set(message.get("topics", []))
            await self.update_wanted()
        elif kind == "state":
            topic = message.get("topic")
            owner = self.topics.get(topic, {}).get("owner")
            if owner != peer.kind or owner == "daemon":
                return
            data = message.get("data")
            if peer.kind == "shell":
                data = self.blobs.wrap(data)
            await self.publish(topic, data, device_id=peer.device_id)
        elif kind == "call":
            task = self.spawn(self._answer(peer, message))
            peer.calls.add(task)
            task.add_done_callback(peer.calls.discard)
        elif kind == "result":
            future = self.pending.get(message.get("id"))
            if future and not future.done():
                if message.get("ok"):
                    data = message.get("data")
                    future.set_result(self.blobs.wrap(data) if peer.kind == "shell" else data)
                else:
                    error = message.get("error") or {}
                    future.set_exception(Refused(str(error.get("code", "failed")), str(error.get("message", ""))))
        elif kind == "event":
            topic = str(message.get("topic", ""))
            owner = self.topics.get(topic, {}).get("owner")
            if peer.kind == "phone" and owner != "phone":
                return
            data = message.get("data") if isinstance(message.get("data"), dict) else {}
            if peer.kind == "shell":
                data = self.blobs.wrap(data)
            await self.emit(topic, str(message.get("name", "")), data, device_id=message.get("device"), source=peer)

    async def receive_bytes(self, peer, data):
        if data and data[0] in self.binary:
            await self.binary[data[0]](peer, memoryview(data)[1:])

    # ── housekeeping ───────────────────────────────────────────────────────
    async def watch_plugins(self):
        """Publishes the plugin switches and tells features when they change."""
        last = None
        while True:
            current = self.plugins()
            if current != last:
                last = dict(current)
                await self.publish("plugins", current)
                for function in self.hooks["plugins"]:
                    await function(current)
                # topics a switch just allowed reach their subscribers now
                for peer in list(self.peers):
                    for topic in list(peer.subs):
                        if topic != "plugins":
                            await self.snapshot(peer, topic)
            await asyncio.sleep(1)


def encode(message):
    return json.dumps(message, separators=(",", ":"), ensure_ascii=False)


def now():
    return int(time.time() * 1000)


def expand(path):
    return Path(os.path.expanduser(str(path)))
