"""The meaning index: an embedding (Ollama, nomic-embed-text) of what is
known about each file – its path, place, people and description from the
server, the first lines of a document's text."""
import base64
import json
import shutil
import subprocess
import urllib.error
import urllib.request

from . import TaskError, kind_of

MODEL = "nomic-embed-text"
TEXT_LIMIT = 1500


def post(ctx, path, body, timeout=300):
    request = urllib.request.Request(ctx.ollama.rstrip("/") + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise TaskError(f"Ollama: {detail[:200]}")
    except (urllib.error.URLError, OSError) as error:
        raise TaskError(f"Ollama is not reachable at {ctx.ollama} ({error})")


def ensure_model(ctx):
    try:
        with urllib.request.urlopen(ctx.ollama.rstrip("/") + "/api/tags", timeout=60) as response:
            tags = json.loads(response.read() or b"{}")
    except (urllib.error.URLError, OSError) as error:
        raise TaskError(f"Ollama is not reachable at {ctx.ollama} ({error})")
    if not any(model.get("name", "").split(":")[0] == MODEL for model in tags.get("models", [])):
        ctx.progress(0.01, f"Downloading {MODEL}")
        post(ctx, "/api/pull", {"model": MODEL, "stream": False}, 3600)


def document_text(ctx, item):
    kind = kind_of(item["path"])
    if (item.get("size") or 0) > 50 << 20:
        return ""
    try:
        local = ctx.fetch(item["path"])
        if kind == "pdf" and shutil.which("pdftotext"):
            out = subprocess.run(["pdftotext", "-l", "3", "-q", local, "-"], capture_output=True, timeout=60)
            return out.stdout.decode("utf-8", "replace")[:TEXT_LIMIT]
        if kind in ("text", "code"):
            with open(local, "rb") as file:
                return file.read(TEXT_LIMIT * 2).decode("utf-8", "replace")[:TEXT_LIMIT]
    except (OSError, subprocess.SubprocessError, TaskError):
        pass
    return ""


def run(ctx, inputs, options):
    ensure_model(ctx)
    known = options.get("_texts") or {}
    texts = []
    for item in inputs:
        ctx.check()
        words = known.get(item["path"]) or item["path"]
        words = words.replace("/", " ").replace("_", " ")
        texts.append("search_document: " + (words + "\n" + document_text(ctx, item)).strip())
    answer = post(ctx, "/api/embed", {"model": MODEL, "input": texts, "truncate": True})
    vectors = answer.get("embeddings") or []
    if len(vectors) != len(inputs):
        raise TaskError("Ollama gave no embeddings")
    import array
    out = {}
    for item, vector in zip(inputs, vectors):
        out[item["path"]] = base64.b64encode(array.array("f", vector).tobytes()).decode()
    ctx.progress(1.0)
    return {"embeddings": out, "model": MODEL}
