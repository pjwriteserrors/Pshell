"""pcore/client/pshell_core_client.py against a running core: verify for
cookie, bearer and Basic, the 30 s cache and its bound, revocations through
the poller, unreachable cores (refused and silent), minting on behalf."""
import base64
import socket
import time

from common import Client, Core, run, wait_for

import pshell_core_client
from pshell_core_client import Core as CoreClient, CoreUnreachable


async def main():
    core = await Core().start()
    core.add_user("lu", "lu password 1", "admin")
    core.add_user("anna", "anna password", "user")
    lu = Client(core.base)
    await lu.login("lu", "lu password 1")
    status, data = await lu.post("/api/devices", {"name": "pc", "kind": "pc",
                                                  "scopes": {"nas": ["files", "admin"], "core": ["read"]}})
    pc, pc_token = data["device"], data["token"]
    status, data = await lu.post("/api/devices", {"name": "phone", "kind": "phone", "scopes": {"nas": ["files"]}})
    phone, phone_token = data["device"], data["token"]
    lu_sid = next(cookie.value for cookie in lu.session.cookie_jar if cookie.key == "pshell_session")
    client = CoreClient(core.base, str(core.key_path("nas")))
    try:
        assert client.reachable is None and client.enabled()
        answer = await client.verify("nas", bearer=pc_token, ip="192.168.178.30")
        assert answer["ok"] and answer["id"] == pc["id"] and answer["caps"] == ["files", "admin"]
        assert client.reachable is True
        assert (await client.verify("nas", bearer="Bearer " + phone_token))["caps"] == ["files"]
        answer = await client.verify("nas", cookie=lu_sid)
        assert answer["kind"] == "user" and answer["caps"] == ["files", "worker", "admin"] and answer["session"]
        header = "Basic " + base64.b64encode(b"anna:anna password").decode()
        assert (await client.verify("nas", basic=header))["caps"] == ["files"]
        assert (await client.verify("nas", basic=header[6:]))["name"] == "anna"
        assert (await client.verify("nas")) == {"ok": False, "reason": "no credential"}
        assert (await client.verify("nas", bearer="psh_nope"))["ok"] is False
        # bearer wins over cookie, as core itself decides
        assert (await client.verify("nas", cookie=lu_sid, bearer=pc_token))["kind"] == "device"

        # cached: a device removed behind core's back still answers from the cache …
        core.app["db"].run("DELETE FROM devices WHERE id=?", phone["id"])
        assert (await client.verify("nas", bearer=phone_token))["ok"] is True
        # … until a revocation names it
        core.app["auth"].revoke("id", phone["id"])
        ids, sessions = await client.poll_revoked()
        assert phone["id"] in ids
        assert (await client.verify("nas", bearer=phone_token))["ok"] is False

        # the poller drops a rotated device and an ended session within its interval
        client.start(every=0.1)
        assert (await client.verify("nas", bearer=pc_token))["ok"]
        await lu.post(f"/api/devices/{pc['id']}/rotate")
        await wait_for(lambda: not any(entry[1].get("id") == pc["id"] for entry in client.cache.values()))
        assert (await client.verify("nas", bearer=pc_token))["ok"] is False
        assert (await client.verify("nas", cookie=lu_sid))["ok"]
        other = Client(core.base)
        await other.login("anna", "anna password")
        anna_sid = next(cookie.value for cookie in other.session.cookie_jar if cookie.key == "pshell_session")
        assert (await client.verify("nas", cookie=anna_sid))["ok"]
        await other.post("/api/auth/logout")
        await wait_for(lambda: not any(entry[1].get("name") == "anna" and entry[1].get("session")
                                       for entry in client.cache.values()))
        assert (await client.verify("nas", cookie=anna_sid))["ok"] is False
        await other.close()

        # minting on behalf of a nas admin
        status, data = await lu.post("/api/devices", {"name": "admin-pc", "kind": "pc",
                                                      "scopes": {"nas": ["files", "admin"], "core": ["read"]}})
        admin_token = data["token"]
        status, data = await client.create_device("new laptop", "laptop", ["files", "worker"],
                                                  bearer=admin_token, ip="192.168.178.50")
        assert status == 200 and data["token"].startswith("psh_") and data["device"]["scopes"] == {
            "nas": ["files", "worker"], "core": ["read"]}
        minted = await client.verify("nas", bearer=data["token"])
        assert minted["caps"] == ["files", "worker"]
        status, data = await client.create_device("x", "pc", ["files"], basic=header)       # anna: no nas admin
        assert status == 403
        status, data = await client.create_device("x", "pc", ["files"])
        assert status == 400

        # the cache is bounded
        small = CoreClient(core.base, str(core.key_path("nas")), size=5)
        for index in range(12):
            await small.verify("nas", bearer=f"psh_wrong{index}")
        assert len(small.cache) == 5
        await small.close()

        # a wrong key: a clear refusal, not "unreachable"
        bad_key = core.tmp / "bad.key"
        bad_key.write_text("nope\n")
        wrong = CoreClient(core.base, str(bad_key))
        answer = await wrong.verify("nas", bearer=admin_token)
        assert answer["ok"] is False and answer["status"] == 403 and not answer.get("unreachable")
        await wrong.close()
    finally:
        await client.close()

    # unreachable: nothing listens, or something listens and never answers
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        closed_port = sock.getsockname()[1]
    away = CoreClient(f"http://127.0.0.1:{closed_port}", str(core.key_path("nas")))
    answer = await away.verify("nas", bearer=admin_token)
    assert answer["ok"] is False and answer["unreachable"] and away.reachable is False
    assert not away.cache
    try:
        await away.create_device("x", "pc", ["files"], bearer=admin_token)
        raise AssertionError("no exception")
    except CoreUnreachable:
        pass
    await away.close()

    silent = socket.socket()
    silent.bind(("127.0.0.1", 0))
    silent.listen(5)
    slow = CoreClient(f"http://127.0.0.1:{silent.getsockname()[1]}", str(core.key_path("nas")), timeout=0.3)
    started = time.monotonic()
    answer = await slow.verify("nas", bearer=admin_token)
    assert answer["unreachable"] and time.monotonic() - started < 1.5
    assert pshell_core_client.TIMEOUT == 2.0
    await slow.close()
    silent.close()

    nokey = CoreClient(core.base, str(core.tmp / "missing.key"))
    assert not nokey.enabled() and (await nokey.verify("nas", bearer=admin_token))["unreachable"]
    await nokey.close()

    await lu.close()
    await core.stop()


if __name__ == "__main__":
    run(main)
