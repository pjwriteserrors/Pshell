"""chat: the PC's local models (Ollama) answer the phone. The model runs on
the PC; the phone sends the conversation and gets the answer word by word
(events `delta`, then `done`)."""

import asyncio
import json

import aiohttp

from ..hub import Refused

OLLAMA = "http://127.0.0.1:11434"


def setup(hub, daemon):
    running = {}

    @hub.action("chat", "models", kinds=("phone",))
    async def models(_peer, _args):
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=5)) as session:
                async with session.get(f"{OLLAMA}/api/tags") as response:
                    data = await response.json()
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError):
            raise Refused("no-ollama", "Ollama is not running on the PC") from None
        return {"models": [{"name": m["name"], "size": m.get("size", 0), "parameters": (m.get("details") or {}).get("parameter_size", "")} for m in data.get("models", [])]}

    async def answer(peer, chat_id, model, messages):
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, sock_read=300)) as session:
                async with session.post(f"{OLLAMA}/api/chat", json={"model": model, "messages": messages, "stream": True}) as response:
                    if response.status != 200:
                        raise Refused("failed", (await response.text())[:200])
                    async for line in response.content:
                        if not line.strip():
                            continue
                        chunk = json.loads(line)
                        text = (chunk.get("message") or {}).get("content", "")
                        if text:
                            await hub.send(peer, {"type": "event", "topic": "chat", "name": "delta", "data": {"id": chat_id, "text": text}})
                        if chunk.get("done"):
                            break
            await hub.send(peer, {"type": "event", "topic": "chat", "name": "done", "data": {"id": chat_id}})
        except asyncio.CancelledError:
            await hub.send(peer, {"type": "event", "topic": "chat", "name": "done", "data": {"id": chat_id, "stopped": True}})
        except (aiohttp.ClientError, Refused, ValueError) as error:
            await hub.send(peer, {"type": "event", "topic": "chat", "name": "done", "data": {"id": chat_id, "error": str(error) or "Ollama is not running on the PC"}})
        finally:
            running.pop(chat_id, None)

    @hub.action("chat", "send", kinds=("phone",))
    async def send(peer, args):
        chat_id = str(args.get("id", ""))
        messages = []
        for m in args.get("messages", []):
            if m.get("role") not in ("system", "user", "assistant"):
                continue
            message = {"role": str(m["role"]), "content": str(m.get("content", ""))}
            # pictures, base64, for models that see
            images = [str(image) for image in m.get("images", []) if isinstance(image, str)][:6]
            if images:
                message["images"] = images
            messages.append(message)
        if not chat_id or not messages or not args.get("model"):
            raise Refused("bad-request", "A model and a message are needed")
        running[chat_id] = hub.spawn(answer(peer, chat_id, str(args["model"]), messages))
        return {}

    @hub.action("chat", "stop", kinds=("phone",))
    async def stop(_peer, args):
        task = running.get(str(args.get("id", "")))
        if task:
            task.cancel()
        return {}
