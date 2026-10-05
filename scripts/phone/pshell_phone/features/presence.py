"""presence: the phone leaving (the link gone for a while) and coming back
make things happen on the PC. What happens is in the host profile:

    "phone": { "presence": { "after": 120, "leave": ["lock", "pause"], "arrive": [] } }

Actions: "lock" (the lock screen), "pause" (every player), "timer" (pause the
time tracker), or a shell command as { "run": "…" }.
"""

import asyncio

from .. import config

SCRIPTS = config.ROOT / "scripts"


async def act(action):
    if isinstance(action, dict) and action.get("run"):
        command = ["sh", "-c", str(action["run"])]
    elif action == "lock":
        command = [str(SCRIPTS / "ipc.sh"), "lock", "lock"]
    elif action == "pause":
        command = ["playerctl", "--all-players", "pause"]
    elif action == "timer":
        command = ["python3", str(SCRIPTS / "qtrack" / "qtrack-local"), "pause"]
    else:
        return
    try:
        process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        await asyncio.wait_for(process.wait(), 20)
    except (OSError, asyncio.TimeoutError):
        pass


def setup(hub, daemon):
    state = {"present": False, "timer": None}

    def settings():
        value = config.settings().get("presence", {})
        return value if isinstance(value, dict) else {}

    async def publish():
        await hub.publish("presence", {"present": state["present"], "after": int(settings().get("after", 120)), "leave": settings().get("leave", ["lock", "pause"]), "arrive": settings().get("arrive", [])})

    async def left():
        await asyncio.sleep(int(settings().get("after", 120)))
        if hub.phones() or not state["present"]:
            return
        state["present"] = False
        await publish()
        if hub.allowed("presence"):
            for action in settings().get("leave", ["lock", "pause"]):
                await act(action)

    @hub.hook("connect")
    async def connected(peer):
        if peer.kind != "phone":
            return
        if state["timer"]:
            state["timer"].cancel()
            state["timer"] = None
        if not state["present"]:
            state["present"] = True
            await publish()
            if hub.allowed("presence"):
                for action in settings().get("arrive", []):
                    await act(action)

    @hub.hook("disconnect")
    async def disconnected(peer):
        if peer.kind == "phone" and not hub.phones() and state["present"] and state["timer"] is None:
            state["timer"] = hub.spawn(left())
            state["timer"].add_done_callback(lambda _task: state.update(timer=None))

    daemon.background.append(publish)
