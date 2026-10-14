"""Ollama for the file manager, on this machine only: a text model for names
and for understanding a search, a vision model (when one is there) for what
a picture shows, an embedding model for search by meaning.
"""
import base64
import json
import os
import urllib.error
import urllib.request

HOST = os.environ.get("OLLAMA_HOST") or "http://127.0.0.1:11434"
if not HOST.startswith("http"):
    HOST = "http://" + HOST

EMBED_MODELS = ("nomic-embed-text", "mxbai-embed-large", "bge-m3", "snowflake-arctic-embed", "all-minilm", "embeddinggemma")
VISION_MODELS = ("qwen2.5vl", "qwen3-vl", "llava", "llama3.2-vision", "moondream", "minicpm-v", "gemma3", "granite3.2-vision", "llava-phi3")
TEXT_PREFERRED = ("qwen3", "llama3.1", "llama3.2", "gemma3", "mistral", "qwen2.5", "phi4", "phi3")
SUGGESTED_EMBED = "nomic-embed-text"
# what each feature uses a model for, and the setting (aiModels in files.json) that picks it
FEATURES = {
    "name": {"text": "nameText", "vision": "nameVision"},
    "index": {"vision": "describe", "embed": "embed"},
    "search": {"text": "understand", "embed": "embed"},
    "translate": {"text": "translate"},
}
SETTINGS = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "pshell", "files.json")
SUGGESTED_VISION = "moondream"


class AiError(Exception):
    pass


def _post(path, body, timeout=120):
    request = urllib.request.Request(HOST + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise AiError(f"Ollama: {error.read().decode('utf-8', 'replace')[:200] or error.reason}")
    except (urllib.error.URLError, OSError) as error:
        raise AiError("Ollama is not running") from error


def models():
    try:
        with urllib.request.urlopen(HOST + "/api/tags", timeout=4) as response:
            return [model["name"] for model in json.loads(response.read()).get("models", [])]
    except (urllib.error.URLError, OSError, ValueError):
        return []


def _pick(names, wanted):
    for prefix in wanted:
        for name in names:
            if name.split(":")[0] == prefix or name.startswith(prefix):
                return name
    return ""


def chosen():
    """The models picked in the settings: { setting: name }; none means the one found here."""
    try:
        with open(SETTINGS, encoding="utf-8") as file:
            picked = (json.load(file).get("settings") or {}).get("aiModels") or {}
        return picked if isinstance(picked, dict) else {}
    except (OSError, ValueError, AttributeError):
        return {}


def status(feature="", picked=None):
    names = models()
    state = {
        "running": bool(names) or _alive(),
        "models": names,
        "embedModels": [name for name in names if _pick([name], EMBED_MODELS)],
        "text": _pick(names, TEXT_PREFERRED) or next((name for name in names if not _pick([name], EMBED_MODELS)), ""),
        "vision": _pick(names, VISION_MODELS),
        "embed": _pick(names, EMBED_MODELS),
        "suggestedEmbed": SUGGESTED_EMBED,
        "suggestedVision": SUGGESTED_VISION,
    }
    # a picked model that is still there wins over the one found
    picked = chosen() if picked is None else picked
    for role, key in FEATURES.get(feature, {}).items():
        if picked.get(key) in names:
            state[role] = picked[key]
    return state


def _alive():
    try:
        with urllib.request.urlopen(HOST + "/api/version", timeout=2):
            return True
    except (urllib.error.URLError, OSError):
        return False


def generate(model, prompt, images=(), as_json=False, timeout=120, system=""):
    body = {"model": model, "prompt": prompt, "stream": False, "think": False, "options": {"temperature": 0.2, "num_ctx": 4096}}
    if system:
        body["system"] = system
    if as_json:
        body["format"] = "json"
    if images:
        encoded = []
        for path in images:
            with open(path, "rb") as file:
                encoded.append(base64.b64encode(file.read()).decode())
        body["images"] = encoded
    try:
        answer = _post("/api/generate", body, timeout)
    except AiError as error:
        # an older Ollama does not know "think"
        if "think" not in str(error):
            raise
        body.pop("think")
        answer = _post("/api/generate", body, timeout)
    text = str(answer.get("response", "")).strip()
    if "<think>" in text:
        text = text.split("</think>")[-1].strip()
    if as_json:
        try:
            return json.loads(text)
        except ValueError:
            start, end = text.find("{"), text.rfind("}")
            if start >= 0 and end > start:
                try:
                    return json.loads(text[start:end + 1])
                except ValueError:
                    pass
            raise AiError("The model did not answer in JSON")
    return text


def embed(model, texts, timeout=120):
    answer = _post("/api/embed", {"model": model, "input": list(texts), "truncate": True}, timeout)
    return answer.get("embeddings") or []


def pull(model, report, cancelled):
    """Downloads a model; report(done, total, status)."""
    request = urllib.request.Request(HOST + "/api/pull", data=json.dumps({"model": model, "stream": True}).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=3600) as response:
            for line in response:
                if cancelled():
                    return False
                try:
                    data = json.loads(line)
                except ValueError:
                    continue
                if data.get("error"):
                    raise AiError(data["error"])
                report(int(data.get("completed") or 0), int(data.get("total") or 0), str(data.get("status", "")))
    except (urllib.error.URLError, OSError) as error:
        raise AiError("Ollama is not running") from error
    return True
