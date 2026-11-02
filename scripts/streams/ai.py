"""Asking a language model: Ollama on this machine, or the Claude and Codex command
line tools with the subscription they are signed in to. Those run with no tools, in
an empty folder and with API keys taken out of their environment: what they read
are subtitles from the internet, which must never be able to do anything, and a
subscription must not turn into a bill."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

import net

OLLAMA = os.environ.get("STREAMS_TEST_OLLAMA", "http://localhost:11434")
# what Ollama lists but cannot hold a conversation
NOT_FOR_TEXT = re.compile(r"embed|moondream|llava|vl\d|intern", re.I)
PROVIDERS = ("ollama", "claude", "codex")
CLAUDE_MODELS = ["haiku", "sonnet", "opus"]


def status():
    """What can be used here."""
    out = {"ollama": {"ready": False, "models": []}, "claude": {"ready": False, "models": CLAUDE_MODELS}, "codex": {"ready": False, "models": []}}
    try:
        tags = net.fetch_json(f"{OLLAMA}/api/tags", timeout=3)
        out["ollama"] = {"ready": True, "models": [item["name"] for item in tags.get("models", []) if not NOT_FOR_TEXT.search(item["name"])]}
    except net.Failure:
        pass
    home = os.path.expanduser("~")
    out["claude"]["ready"] = bool(shutil.which("claude")) and os.path.exists(f"{home}/.claude/.credentials.json")
    out["codex"]["ready"] = bool(shutil.which("codex")) and os.path.exists(f"{home}/.codex/auth.json")
    out["codex"]["models"] = codex_models()
    return out


def codex_models():
    """What the signed-in Codex offers: a configured default may not be allowed."""
    try:
        with open(os.path.expanduser("~/.codex/models_cache.json"), encoding="utf-8") as file:
            data = json.load(file)
        items = data.get("models", data) if isinstance(data, dict) else data
        return [item["slug"] for item in items if isinstance(item, dict) and item.get("slug") and item.get("visibility", "list") == "list"]
    except (OSError, ValueError, TypeError):
        return []


def _clean_environment():
    env = dict(os.environ)
    for name in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"):
        env.pop(name, None)
    return env


def _ollama(prompt, model, schema, words, timeout):
    body = {"model": model, "prompt": prompt, "stream": False, "think": False, "options": {"temperature": 0, "num_ctx": 4096, "num_predict": words}, "keep_alive": "10m"}
    if schema:
        body["format"] = schema
    try:
        data = net.fetch_json(f"{OLLAMA}/api/generate", {"Content-Type": "application/json"}, json.dumps(body).encode(), timeout=timeout)
    except net.Failure as error:
        raise net.Failure(f"Ollama did not answer ({error})") from error
    return data.get("response", "")


def _claude(prompt, model, schema, timeout):
    command = ["claude", "-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config"]
    if model:
        command += ["--model", model]
    if schema:
        command += ["--json-schema", json.dumps(schema)]
    with tempfile.TemporaryDirectory(prefix="pshell-ai-") as folder:
        done = subprocess.run(command, input=prompt, capture_output=True, text=True, timeout=timeout, cwd=folder, env=_clean_environment(), check=False)
    try:
        data = json.loads(done.stdout)
    except ValueError as error:
        raise net.Failure((done.stderr.strip() or done.stdout.strip() or "Claude gave no answer")[:200]) from error
    if data.get("is_error"):
        raise net.Failure(str(data.get("result") or "Claude refused")[:200])
    if data.get("structured_output") is not None:
        return json.dumps(data["structured_output"])
    return data.get("result", "")


def _codex(prompt, model, schema, timeout):
    with tempfile.TemporaryDirectory(prefix="pshell-ai-") as folder:
        answer = os.path.join(folder, "answer.txt")
        command = ["codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never", "-C", folder, "-o", answer]
        model = model or next(iter(codex_models()), "")
        if model:
            command += ["-m", model]
        if schema:
            shape = os.path.join(folder, "schema.json")
            with open(shape, "w", encoding="utf-8") as file:
                json.dump(_strict(schema), file)
            command += ["--output-schema", shape]
        done = subprocess.run([*command, "-"], input=prompt, capture_output=True, text=True, timeout=timeout, env=_clean_environment(), check=False)
        if not os.path.exists(answer):
            raise net.Failure((done.stderr.strip().splitlines() or ["Codex gave no answer"])[-1][:200])
        with open(answer, encoding="utf-8") as file:
            return file.read()


def _strict(schema):
    """Codex wants every property required and nothing else allowed."""
    out = dict(schema)
    if out.get("type") == "object" or "properties" in out:
        out["additionalProperties"] = False
        out["required"] = list(out.get("properties", {}))
        out["properties"] = {key: _strict(value) for key, value in out.get("properties", {}).items()}
    if "items" in out:
        out["items"] = _strict(out["items"])
    return out


def ask(prompt, provider="ollama", model="", schema=None, words=200, timeout=300):
    """The model's answer as text."""
    if provider == "claude":
        return _claude(prompt, model, schema, timeout)
    if provider == "codex":
        return _codex(prompt, model, schema, timeout)
    if not model:
        models = status()["ollama"]["models"]
        if not models:
            raise net.Failure("Ollama has no model that can write")
        model = next((name for name in models if name.startswith("llama3.1")), models[0])
    return _ollama(prompt, model, schema, words, timeout)


def ask_json(prompt, provider="ollama", model="", schema=None, words=200, timeout=300):
    text = ask(prompt, provider, model, schema, words, timeout)
    found = re.search(r"\{.*\}", text, re.S)
    if not found:
        return None
    try:
        return json.loads(found.group(0))
    except ValueError:
        return None


def test(provider, model):
    began = time.time()
    answer = ask("Answer with exactly one word: what colour is the sky on a clear day?", provider, model, words=12, timeout=120)
    return {"answer": answer.strip()[:60], "seconds": round(time.time() - began, 1)}
