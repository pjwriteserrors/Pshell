"""The memory guard. The Pi runs Pi-hole (the home's DNS) next to the NAS;
when memory runs short it is better that the NAS pauses its indexing than
that the kernel picks a victim.

Levels come from the newest sample. Going up happens at once; going down
only after the sample stayed below the limits for two minutes, so a guard
on the edge does not flap. `shed: pressure` services are told the level,
at `critical` the `shed: stop` containers are stopped (if `guard_stop`)
and stay stopped until someone starts them. `critical` services and core
itself are never touched.
"""
import asyncio
import time

import aiohttp

from .services import shed_of

ORDER = {"ok": 0, "tight": 1, "critical": 2}


def level_of(sample, settings):
    available = sample.get("mem_available")
    some = sample.get("psi_some10")
    full = sample.get("psi_full10")
    faults = sample.get("faults")
    if (available is not None and available < settings.get("critical_mb")
            or full is not None and full > settings.get("critical_psi")
            or faults is not None and faults > settings.get("critical_faults")):
        return "critical"
    if (available is not None and available < settings.get("tight_mb")
            or some is not None and some > settings.get("tight_psi")
            or faults is not None and faults > settings.get("tight_faults")):
        return "tight"
    return "ok"


class Guard:
    def __init__(self, config, settings, services, hub, log):
        self.config = config
        self.settings = settings
        self.services = services
        self.hub = hub
        self.log = log
        self.level = "ok"
        self.since = time.time()
        self.lower_since = None        # when the samples first stayed below the current level
        self.actions = []              # newest last, bounded
        self.stopped = {}              # container the guard stopped → seen stopped since (until started by hand)
        self.session = None

    def state(self):
        return {"level": self.level, "since": self.since, "actions": list(reversed(self.actions)),
                "stopped": list(self.stopped)}

    def note(self, what):
        self.actions.append({"at": time.time(), "what": what})
        del self.actions[:-50]

    async def check(self, sample):
        raw = level_of(sample, self.settings)
        now = time.time()
        if ORDER[raw] > ORDER[self.level]:
            self.lower_since = None
            await self.enter(raw, sample)
        elif ORDER[raw] < ORDER[self.level]:
            if self.lower_since is None:
                self.lower_since = now
            elif now - self.lower_since >= self.config.guard_hold:
                self.lower_since = None
                await self.enter(raw, sample)
        else:
            self.lower_since = None
        # a container started by hand is no longer the guard's (the round right after
        # the stop may still show it running, so only once it was seen stopped)
        for name, seen_down in list(self.stopped.items()):
            info = self.services.containers.get(name)
            if info and info.get("state") != "running":
                self.stopped[name] = True
            elif info and seen_down:
                self.stopped.pop(name)

    async def enter(self, level, sample):
        was, self.level, self.since = self.level, level, time.time()
        available = sample.get("mem_available")
        self.note(f"{was} → {level} ({available} MB available, psi some {sample.get('psi_some10')}"
                  f" full {sample.get('psi_full10')}, {sample.get('faults')} faults/s)")
        told = await self.tell(level)
        stopped = []
        if level == "critical" and self.settings.get("guard_stop"):
            stopped = await self.stop_sheddable()
        self.log.add("pressure", "guard", "", {"level": level, "was": was, "available_mb": available,
                                               "faults": sample.get("faults"),
                                               "told": told, "stopped": stopped})
        self.hub.emit("pressure", level=level, was=was, available_mb=available, told=told, stopped=stopped)

    async def tell(self, level):
        """POST /api/core/pressure {level} to every `shed: pressure` service; the names that took it."""
        if self.session is None or self.session.closed:
            self.session = aiohttp.ClientSession(connector=aiohttp.TCPConnector(force_close=True))
        jobs = {}
        for name, entry in self.services.entries.items():
            if shed_of(entry) != "pressure" or not entry.get("port"):
                continue
            key = self.services.key(name)
            if not key:
                continue
            url = f"http://{self.config.probe_host}:{entry['port']}/api/core/pressure"
            jobs[name] = self.post(url, key, level)
        results = await asyncio.gather(*jobs.values())
        told = []
        for name, ok in zip(jobs, results):
            self.note(f"told {name}: {level}" if ok else f"could not tell {name}: {level}")
            if ok:
                told.append(name)
        return told

    async def post(self, url, key, level):
        try:
            async with self.session.post(url, json={"level": level}, headers={"X-Service-Key": key},
                                         timeout=aiohttp.ClientTimeout(total=5)) as response:
                await response.read()
                return response.status < 300
        except (aiohttp.ClientError, OSError, asyncio.TimeoutError):
            return False

    async def stop_sheddable(self):
        stopped = []
        for name, entry in self.services.entries.items():
            container = entry.get("container")
            if (shed_of(entry) != "stop" or entry.get("critical") or not container
                    or container == self.config.own_container):
                continue
            info = self.services.containers.get(container)
            if info is not None and info.get("state") != "running":
                continue
            status, message = await self.services.docker.action(container, "stop")
            if status == 200:
                stopped.append(container)
                self.stopped[container] = False
                self.note(f"stopped {container}")
            else:
                self.note(f"could not stop {container}: {message}")
        return stopped

    async def close(self):
        if self.session:
            await self.session.close()
