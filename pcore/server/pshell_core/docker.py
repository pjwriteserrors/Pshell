"""The docker socket: container state, memory and the few actions core may
take. One long-lived session over the unix socket; every call has its own
timeout and a missing socket (on the PC, in tests) only means "no docker".

Stats are asked for with `one-shot`, so docker answers at once instead of
waiting a second for a second reading; the CPU share is computed from the
previous answer of the same container instead.
"""
import asyncio
import json
import os
from datetime import datetime

import aiohttp

ACTIONS = ("start", "stop", "restart", "pause", "unpause")


class Docker:
    def __init__(self, path):
        self.path = path
        self.session = None
        self.cpu = {}                  # container id → (container total, system total)
        self.inspect_cache = {}        # container id → (status line, inspect answer)
        self.gate = asyncio.Semaphore(3)

    def available(self):
        return bool(self.path) and os.path.exists(self.path)

    async def call(self, method, path, timeout=10):
        if not self.available():
            return None, None
        if self.session is None or self.session.closed:
            self.session = aiohttp.ClientSession(connector=aiohttp.UnixConnector(path=self.path))
        async with self.gate:
            async with self.session.request(method, f"http://docker{path}",
                                            timeout=aiohttp.ClientTimeout(total=timeout)) as response:
                text = await response.text()
                try:
                    return response.status, json.loads(text) if text else None
                except ValueError:
                    return response.status, text

    async def close(self):
        if self.session:
            await self.session.close()

    async def containers(self):
        """name → {id, state, health, started, restarts, mem, mem_limit, cpu, image}; {} without docker."""
        try:
            status, items = await self.call("GET", "/containers/json?all=1")
        except (aiohttp.ClientError, OSError, asyncio.TimeoutError):
            return {}
        if status != 200 or not isinstance(items, list):
            return {}
        out = {}
        jobs = []
        for item in items:
            name = (item.get("Names") or ["?"])[0].lstrip("/")
            entry = {"id": item.get("Id", ""), "state": item.get("State", ""), "status": item.get("Status", ""),
                     "image": item.get("Image", ""), "health": _health_of(item.get("Status", "")),
                     "started": None, "restarts": 0, "mem": None, "mem_limit": None, "cpu": None}
            out[name] = entry
            jobs.append(self._details(entry))
        await asyncio.gather(*jobs, return_exceptions=True)
        alive = {entry["id"] for entry in out.values()}
        for ident in list(self.cpu):
            if ident not in alive:
                self.cpu.pop(ident, None)
        for ident in list(self.inspect_cache):
            if ident not in alive:
                self.inspect_cache.pop(ident, None)
        for entry in out.values():
            entry.pop("status", None)
        return out

    async def _details(self, entry):
        ident = entry["id"]
        # inspect only when docker's status line changed (it carries the uptime in minutes)
        cached = self.inspect_cache.get(ident)
        if cached and cached[0] == entry["status"]:
            info = cached[1]
        else:
            status, info = await self.call("GET", f"/containers/{ident}/json")
            if status == 200 and isinstance(info, dict):
                info = {"State": info.get("State") or {}, "RestartCount": info.get("RestartCount", 0)}
                self.inspect_cache[ident] = (entry["status"], info)
            else:
                info = None
        if info:
            state = info["State"]
            entry["restarts"] = info.get("RestartCount", 0)
            entry["started"] = _when(state.get("StartedAt"))
            if state.get("Health"):
                entry["health"] = state["Health"].get("Status")
        if entry["state"] != "running":
            self.cpu.pop(ident, None)
            return
        status, stats = await self.call("GET", f"/containers/{ident}/stats?stream=false&one-shot=true")
        if status != 200 or not isinstance(stats, dict):
            return
        memory = stats.get("memory_stats") or {}
        usage = memory.get("usage")
        if usage is not None:
            inner = memory.get("stats") or {}
            cache = inner.get("inactive_file", inner.get("total_inactive_file", 0)) or 0
            entry["mem"] = max(0, usage - cache)
            limit = memory.get("limit")
            # an unlimited container reports the host's memory as its limit
            entry["mem_limit"] = limit if limit and limit < (1 << 60) else None
        cpu = stats.get("cpu_stats") or {}
        total = (cpu.get("cpu_usage") or {}).get("total_usage")
        system = cpu.get("system_cpu_usage")
        if total is not None and system:
            before = self.cpu.get(ident)
            self.cpu[ident] = (total, system)
            cpus = cpu.get("online_cpus") or 1
            if before and system > before[1]:
                entry["cpu"] = round(max(0.0, (total - before[0]) / (system - before[1])) * cpus * 100, 1)

    async def action(self, name, action):
        if action not in ACTIONS:
            raise ValueError(f"action is one of {', '.join(ACTIONS)}")
        try:
            status, answer = await self.call("POST", f"/containers/{name}/{action}", timeout=60)
        except (aiohttp.ClientError, OSError, asyncio.TimeoutError) as error:
            return 502, f"docker: {error}"
        if status is None:
            return 503, "No docker socket here"
        if status in (204, 304):
            return 200, None
        message = answer.get("message") if isinstance(answer, dict) else answer
        return status, message


def _health_of(status):
    for word in ("healthy", "unhealthy", "starting"):
        if f"({word}" in status or f"(health: {word}" in status:
            return word
    return None


def _when(text):
    if not text or text.startswith("0001-"):
        return None
    try:
        return datetime.fromisoformat(text[:26].rstrip("Z") + "+00:00" if "." in text else text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None
