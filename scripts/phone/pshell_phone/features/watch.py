"""watch: the BLE end for the watch app (pshell_phone/watch.py), running while
the plugin `watch` is on."""

import asyncio

from .. import watch


def setup(hub, daemon):
    service = daemon.watch_service = watch.Service(hub)
    running = {"on": False, "failed": None}
    lock = asyncio.Lock()

    async def apply(plugins):
        want = plugins.get("watch") is True and plugins.get("phone") is True
        async with lock:
            if want == running["on"]:
                return
            if want:
                try:
                    await service.start()
                    running["on"] = True
                    running["failed"] = None
                    print("phone: waiting for the watch over Bluetooth", flush=True)
                except Exception as error:
                    # no adapter, BlueZ not running: tried again with the next switch
                    if running["failed"] != str(error):
                        print(f"phone: no Bluetooth for the watch: {error}", flush=True)
                    running["failed"] = str(error)
            else:
                await service.stop()
                running["on"] = False

    hub.hooks["plugins"].append(apply)

    async def retry():
        """BlueZ may come up after the daemon, or the adapter be switched on later."""
        while True:
            await asyncio.sleep(30)
            if running["failed"] is not None:
                await apply(hub.plugins())

    daemon.background.append(retry)

    async def stop():
        await service.stop()

    daemon.closing.append(stop)
