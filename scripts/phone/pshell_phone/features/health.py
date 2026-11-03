"""health: what the watch measured, from wherever it was fetched – the
phone app (its own link to the watch, features/Watch.kt) or the shell's
Amazfit daemon – kept in the watch's health history (pshell_phone/health.py)
and seen by both: the topic "health" for the phone, "watch" for >watch."""


def setup(hub, daemon):
    # features load by name: watch's service is there once the daemon runs
    def health():
        return daemon.watch_service.health

    async def publish():
        await hub.publish("health", health().view())
        await daemon.watch_service.publish()

    @hub.action("health", "add", kinds=("phone", "shell", "cli"))
    async def add(origin, args):
        changed = health().merge(args.get("days"), args.get("nights"), args.get("synced"), args.get("battery"))
        if changed:
            await publish()
        return {"changed": changed}

    @hub.action("health", "get", kinds=("phone", "shell", "cli"))
    async def get(origin, args):
        return health().view()

    async def first():
        await hub.publish("health", health().view())

    daemon.background.append(first)
