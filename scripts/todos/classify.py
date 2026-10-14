#!/usr/bin/env python3
"""Sorts a task into one of its group's categories with a local model (Ollama).
Nothing leaves the machine.

  classify.py models            {"models": [{"name", "size"}, …]}: the ones that can be
                                picked, from the fastest to the best
  classify.py classify REQUEST  {"category": one of the categories, or ""}

REQUEST is JSON (without "model" the fastest installed one is taken):
  {"model", "group", "categories": [names], "title", "description",
   "notes": [{"name", "text"}]}

The answer is held to the categories by a schema; "" means none fits. An
error is one line {"error": …}.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

HOST = os.environ.get("OLLAMA_HOST") or "http://127.0.0.1:11434"
if not HOST.startswith("http"):
    HOST = "http://" + HOST

# a model larger than this is slow for one word, and holds the memory with it
LARGEST = 10 * 1024 ** 3
NONE = "-"

PROMPT = """Du ordnest eine Aufgabe aus dem Projekt „{group}“ genau einer Kategorie zu.
Kategorien: {categories}
Antworte als JSON {{"category": …}} mit genau einem Namen aus der Liste, so geschrieben wie dort. Passt keine Kategorie, antworte „{none}“."""


class Failure(Exception):
    pass


def out(**fields):
    sys.stdout.write(json.dumps(fields, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def call(path, body=None, timeout=300):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(HOST + path, data=data, headers={"Content-Type": "application/json"})
    try:
        return urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        try:
            detail = json.load(error).get("error", "")
        except ValueError:
            detail = ""
        raise Failure(detail or f"Ollama: HTTP {error.code}")
    except (urllib.error.URLError, OSError):
        raise Failure("Ollama is not running")


def models():
    """What is installed and of use here, the smallest – the fastest – first."""
    listed = json.load(call("/api/tags", timeout=10)).get("models", [])
    fitting = [entry for entry in listed if 0 < entry.get("size", 0) <= LARGEST and "embed" not in entry["name"]]
    return [{"name": entry["name"], "size": entry["size"]} for entry in sorted(fitting, key=lambda entry: entry["size"])]


def task_text(request):
    parts = [f"Aufgabe: {request.get('title', '').strip()}"]
    if str(request.get("description") or "").strip():
        parts.append(f"Beschreibung:\n{request['description'].strip()}")
    budget = 6000
    for note in request.get("notes") or []:
        text = str(note.get("text") or "").strip()[:budget]
        if not text:
            continue
        budget -= len(text)
        parts.append(f"Notiz „{note.get('name', '')}“:\n{text}")
        if budget <= 0:
            break
    return "\n\n".join(parts)


def classify(request):
    categories = [str(name) for name in request.get("categories") or [] if str(name).strip()]
    if not categories:
        return ""
    model = request.get("model") or (models() or [{}])[0].get("name")
    if not model:
        raise Failure("No model is installed (ollama pull …)")
    schema = {"type": "object", "properties": {"category": {"type": "string", "enum": categories + [NONE]}}, "required": ["category"]}
    body = {
        "model": model, "stream": False, "keep_alive": "5m", "format": schema, "think": False,
        "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": PROMPT.format(group=request.get("group", ""), categories=", ".join(f"„{name}“" for name in categories), none=NONE)},
            {"role": "user", "content": task_text(request)},
        ],
    }
    try:
        said = (json.load(call("/api/chat", body)).get("message") or {}).get("content") or ""
    except Failure as error:
        # older models refuse "think"
        if "think" not in str(error):
            raise
        del body["think"]
        said = (json.load(call("/api/chat", body)).get("message") or {}).get("content") or ""
    said = re.sub(r"<think>.*?(?:</think>|$)", "", said, flags=re.S)
    try:
        found = str(json.loads(said[said.index("{"):said.rindex("}") + 1]).get("category") or "")
    except ValueError:
        raise Failure("The model did not answer in the form asked for")
    match = next((name for name in categories if name.lower() == found.strip().lower()), "")
    return match


def main(args):
    try:
        if args[:1] == ["models"]:
            out(models=models())
        elif args[:1] == ["classify"] and len(args) > 1:
            out(category=classify(json.loads(args[1])))
        else:
            out(error="usage: classify.py models | classify REQUEST")
            return 2
    except Failure as error:
        out(error=str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
