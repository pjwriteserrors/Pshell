#!/usr/bin/env python3
"""A local model (Ollama) that helps to write a mail. Nothing leaves the machine.

  assist.py models          {"models": [{"name", "size"}, …]}: the ones that can be picked,
                            from the fastest to the best
  assist.py write REQUEST   the whole answer from notes: {"done": true, "text": …}
  assist.py frame REQUEST   {"greeting", "thanks", "closing"} around what was written

REQUEST is JSON (without "model" the fastest installed one is taken):
  {"model", "me", "to": [{"name", "email"}],
   "thread": [{"from", "email", "mine", "date", "text", "signature"}],
   "draft": what is written so far,
   "chat": [{"role": "user" | "assistant", "text"}]}       (write)

A mail always has the same build: "Hallo <name>," – a sentence of thanks –
what there is to say – a sentence that offers further help. The signature is
not the model's business; the mail program adds it. The model is a small one,
so it is asked for little: who is greeted is worked out here, from how
people sign their mails, and what it adds after the last sentence is cut.
An error is one line {"error": …}.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

HOST = os.environ.get("OLLAMA_HOST") or "http://127.0.0.1:11434"
if not HOST.startswith("http"):
    HOST = "http://" + HOST

WRITE = """Du schreibst eine E-Mail im Namen von {me}, in der Ich-Form. Du bekommst den Mailverlauf und Notizen von {me}: was erledigt wurde und wie die Mail sein soll. Die Anrede „{greeting}“ steht schon da. Du lieferst den Rest als JSON:
"thanks": ein Satz Dank oder Anerkennung, der zu dem passt, was in der letzten empfangenen Mail steht: bei einer Anfrage Dank für die Anfrage, bei einem Fehlerhinweis Dank für den Hinweis, bei einer Antwort Dank für die Rückmeldung.
"content": der Inhalt der Mail, ausformuliert aus den Notizen. Jede Angabe aus den Notizen kommt vor, genau so: Tage, Zeiten, Zahlen und Namen bleiben, was noch nicht geschehen ist, bleibt Zukunft, und was {me} braucht, bleibt eine Bitte. Erfinde nichts dazu. Die Notizen reden über die Person („er soll …“); in der Mail sprichst du sie direkt an. Kurz und freundlich, ohne Anrede, ohne Dank, ohne Schlusssatz.
"closing": ein Schlusssatz, der weitere Hilfe anbietet.
Keine Grußformel, kein Name, keine Signatur. {address}

Beispiel. Notizen: „rechnung korrigiert, geht morgen raus. er soll kurz bestätigen. freundlich“
Antwort: {example}
Wörter wie „freundlich“ oder „kurz halten“ sagen dir, wie du schreiben sollst; sie gehören nicht in die Mail."""

FRAME = """{me} hat den Inhalt einer Antwort-Mail selbst geschrieben. Du lieferst zwei Sätze dazu, als JSON:
"thanks": ein Satz Dank oder Anerkennung, der zu dem passt, was in der letzten empfangenen Mail steht: bei einer Anfrage Dank für die Anfrage, bei einem Fehlerhinweis Dank für den Hinweis, bei einer Antwort Dank für die Rückmeldung. Er steht direkt nach der Anrede.
"closing": ein Schlusssatz, der weitere Hilfe anbietet.
Beide Sätze sind ganze Sätze in normaler Rechtschreibung, wiederholen nichts aus dem Inhalt und sind je eine Zeile. {address}

Beispiel: {example}"""

# how the two sentences sound, by how the thread speaks: the model takes its tone from them
TONES = {
    "du": ("Duze die Person. Schreibe deutsch.", {"thanks": "danke für deinen Hinweis.", "content": "Ich habe die Rechnung korrigiert, sie geht morgen an dich raus. Kannst du mir bitte kurz den Eingang bestätigen?", "closing": "Wenn noch etwas unklar ist, melde dich gern."}),
    "sie": ("Sieze die Person durchgehend, auch im Dank und im Schlusssatz. Schreibe deutsch.", {"thanks": "vielen Dank für Ihren Hinweis.", "content": "Ich habe die Rechnung korrigiert, sie geht morgen an Sie raus. Können Sie mir bitte kurz den Eingang bestätigen?", "closing": "Wenn Sie noch Fragen haben, melden Sie sich gern."}),
    "en": ("The thread is in English: write every part in English.", {"thanks": "thanks for pointing that out.", "content": "I have corrected the invoice; it will go out to you tomorrow. Could you briefly confirm that you received it?", "closing": "If anything is unclear, just let me know."}),
}

SCHEMA = {"type": "object", "properties": {"thanks": {"type": "string"}, "closing": {"type": "string"}}, "required": ["thanks", "closing"]}
WHOLE = {"type": "object", "properties": {"thanks": {"type": "string"}, "content": {"type": "string"}, "closing": {"type": "string"}}, "required": ["thanks", "content", "closing"]}
# how a mail is signed off, and what is no first name
REGARDS = re.compile(r"^(?:(?:viele|liebe|beste|herzliche|freundliche|sonnige|schöne)\s+grüße|mit\s+(?:freundlichen|besten|lieben)\s+grüßen|(?:lieben?\s+|besten?\s+)?gru[ßs]|lg|vg|mfg|best(?:\s+regards)?|kind\s+regards|regards|cheers)\b[\s,!.]*(.*)$", re.I)
NO_NAME = re.compile(r"gmbh|\bag\b|\bkg\b|\bug\b|team|service|support|info|office|kontakt|shop|studio|sales|noreply|no-reply|newsletter|@", re.I)
# "Sie" inside a sentence: at its beginning it may be "she"
FORMAL = re.compile(r"(?<=[a-zäöüß,] )(?:Sie|Ihnen|Ihre[mnrs]?|Ihr)\b")
SHARED = {"info", "service", "support", "kontakt", "contact", "office", "mail", "hello", "hallo", "team", "sales", "vertrieb", "buchhaltung", "rechnung", "billing", "noreply", "no-reply", "newsletter", "admin", "post", "shop", "bestellung", "order", "orders"}


class Failure(Exception):
    pass


def out(**fields):
    sys.stdout.write(json.dumps(fields, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def call(path, body=None, timeout=600):
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


# a model larger than this takes minutes for a mail on a processor alone, and the memory with it
LARGEST = 10 * 1024 ** 3


def models():
    """What is installed and of use here, the smallest – the fastest – first."""
    listed = json.load(call("/api/tags", timeout=10)).get("models", [])
    fitting = [entry for entry in listed if 0 < entry.get("size", 0) <= LARGEST and "embed" not in entry["name"]]
    return [{"name": entry["name"], "size": entry["size"]} for entry in sorted(fitting, key=lambda entry: entry["size"])]


def plain(markup):
    text = re.sub(r"<br\s*/?>|</(?:p|div|tr|li)>", "\n", str(markup or ""), flags=re.I)
    return re.sub(r"\n\s*\n+", "\n", re.sub(r"<[^>]+>", "", text)).strip()


def first_name(display, mails):
    """What someone is called: how they sign their mails, else the first name of how they are shown."""
    for mail in reversed(mails):
        lines = [line.strip() for line in (str(mail.get("text") or "") + "\n" + plain(mail.get("signature"))).split("\n") if line.strip()]
        for index, line in enumerate(lines):
            # regards stand on a short line of their own, alone or with the name
            signed = REGARDS.match(line) if len(line) < 40 else None
            if not signed:
                continue
            # the name stands behind the regards or on the next line
            for candidate in (signed.group(1), lines[index + 1] if index + 1 < len(lines) else ""):
                word = re.sub(r"[^\w\s-]", "", candidate).strip().split(" ")[0] if candidate else ""
                if re.fullmatch(r"[A-ZÄÖÜ][\w-]{1,20}", word) and not NO_NAME.search(candidate) and not REGARDS.match(candidate.strip()):
                    return word
    display = str(display or "").strip()
    if not display or NO_NAME.search(display):
        return ""
    if "," in display:
        display = display.split(",", 1)[1]
    word = re.sub(r"^(?:dr|prof|herr|frau|mr|mrs|ms)\.?\s+", "", display.strip(), flags=re.I).split(" ")[0]
    return word.capitalize() if re.fullmatch(r"[^\W\d_][\w-]{1,20}", word) else ""


def language(request):
    """"en" when the last mail that came in is English, else "de"."""
    theirs = [mail for mail in request.get("thread") or [] if not mail.get("mine")]
    words = re.findall(r"[a-zäöüß]+", str(theirs[-1].get("text") or "").lower()) if theirs else []
    german = sum(word in ("der", "die", "das", "und", "ich", "nicht", "ist", "für", "mit", "wir", "du", "sie", "ein", "eine", "auf", "dass", "danke", "viele", "grüße") for word in words)
    english = sum(word in ("the", "and", "is", "for", "you", "with", "we", "this", "that", "are", "have", "thanks", "regards", "it", "of", "to") for word in words)
    return "en" if english > german else "de"


def greeting(request):
    """„Hallo <name>,“ for who the answer goes to: two by name, more – or nobody with a name – all together."""
    thread = request.get("thread") or []
    names = []
    for entry in request.get("to") or []:
        theirs = [mail for mail in thread if not mail.get("mine") and mail.get("email") == entry.get("email")]
        # a mailbox many people read has no first name
        shared = str(entry.get("email") or "").split("@")[0].lower() in SHARED
        names.append(first_name("" if shared else entry.get("name"), theirs))
    english = language(request) == "en"
    # with Sie nobody is called by the first name alone
    if tone(request) == "sie":
        formal = [surname(entry, thread) for entry in request.get("to") or []]
        if len(formal) == 1 and formal[0]:
            return ("Hallo " if formal[0].startswith(("Frau ", "Herr ")) else "Guten Tag ") + formal[0] + ","
        return "Guten Tag," if len(formal) <= 1 else "Guten Tag zusammen,"
    if not names or len(names) > 2 or not all(names):
        return "Hello everyone," if english and len(names) != 1 else ("Hello," if english else ("Hallo," if len(names) == 1 else "Hallo zusammen,"))
    return ("Hello " if english else "Hallo ") + (" and " if english else " und ").join(names) + ","


def tone(request):
    """"du", "sie" or "en", as the others write."""
    if language(request) == "en":
        return "en"
    theirs = " ".join(str(mail.get("text") or "") for mail in request.get("thread") or [] if not mail.get("mine"))
    return "sie" if FORMAL.search(theirs) or re.search(r"sehr\s+geehrte", theirs, re.I) else "du"


def guide(request, parts):
    """How the person is addressed, and an example that sounds like it: for a prompt's {address} and {example}."""
    address, example = TONES[tone(request)]
    return {"address": address, "example": json.dumps({key: example[key] for key in parts}, ensure_ascii=False)}


def surname(entry, thread):
    """„Frau Hartmann“ when the user's own mails say whether it is Frau or Herr, else first and last name."""
    words = [word for word in re.sub(r"^(?:(?:dr|prof|herr|frau)\.?\s+)+", "", str(entry.get("name") or "").strip(), flags=re.I).split() if word]
    if "," in str(entry.get("name") or "") or len(words) < 2 or NO_NAME.search(str(entry.get("name") or "")):
        return ""
    last = words[-1]
    said = re.search(rf"\b(Frau|Herr)n?\s+(?:(?:Dr|Prof)\.\s+)*{re.escape(last)}\b", " ".join(str(mail.get("text") or "") for mail in thread if mail.get("mine")))
    return f"{said.group(1)} {last}" if said else " ".join(words)


def situation(request):
    """The thread, oldest first, as the model reads it."""
    parts = ["Mailverlauf (älteste Mail zuerst):"]
    for mail in (request.get("thread") or [])[-4:]:
        who = f"{request.get('me') or 'ich'} (ich)" if mail.get("mine") else str(mail.get("from") or "")
        parts.append(f"--- Von {who}:\n{str(mail.get('text') or '').strip()[:1500]}")
    parts.append("---")
    return "\n".join(parts)


def tail_cut(text, me):
    """Without the regards and the name a model adds although the signature follows."""
    lines = text.rstrip().split("\n")
    own = {part.lower() for part in str(me or "").split()} | {str(me or "").lower()}
    while len(lines) > 1:
        last = lines[-1].strip().strip(",.!").lower()
        if last == "" or (len(last) < 40 and REGARDS.match(last)) or last in own or re.fullmatch(r"(?:hallo|hello|hi)\b.*", last) or last.startswith("["):
            lines.pop()
        else:
            break
    return "\n".join(line.rstrip() for line in lines)


def options(request):
    # a model that thinks aloud first is told not to: it costs most of the time
    quiet = " /no_think" if "qwen" in str(request.get("model", "")).lower() else ""
    return quiet, {"temperature": 0.2, "num_ctx": 4096}


def clean(text):
    """Without what a model thinks aloud, and without the fences some put around an answer."""
    text = re.sub(r"<think>.*?(?:</think>|$)", "", text, flags=re.S)
    return re.sub(r"^```\w*\n|\n```\s*$", "", text.strip()).strip()


def answer(request, messages, schema):
    quiet, tuned = options(request)
    if not request.get("model"):
        raise Failure("No model is installed (ollama pull …)")
    body = {"model": request["model"], "stream": False, "keep_alive": "5m", "format": schema, "options": tuned, "messages": messages}
    if quiet:
        body["think"] = False
    said = clean((json.load(call("/api/chat", body)).get("message") or {}).get("content") or "")
    try:
        found = json.loads(said[said.index("{"):said.rindex("}") + 1])
    except ValueError:
        raise Failure("The model did not answer in the form asked for")
    return {key: str(found.get(key) or "").strip() for key in schema["required"]}


def line(text):
    """One sentence on one line: what a model adds after the first full stop is not asked for
    (the stop of an abbreviation like "z. B." is none)."""
    flat = re.sub(r"\s+", " ", text).strip()
    return re.split(r"(?<=\w{3}[.!?])\s+(?=[A-ZÄÖÜ])", flat, maxsplit=1)[0]


def small(thanks):
    """After "Hallo Tom," the sentence goes on in small letters."""
    return thanks if re.match(r"(?:Sie|Ihnen|Ihre?[mnrs]?)\b", thanks) else thanks[:1].lower() + thanks[1:]


def write(request):
    me = request.get("me") or "mir"
    chat = [entry for entry in request.get("chat") or [] if str(entry.get("text") or "").strip()]
    if not chat or chat[-1].get("role") != "user":
        raise Failure("Nothing was asked")
    hello = greeting(request)
    first = situation(request)
    if str(request.get("draft") or "").strip():
        first += f"\n\nWas {me} schon geschrieben hat:\n{request['draft'].strip()[:1500]}"
    quiet, _tuned = options(request)
    messages = [{"role": "system", "content": WRITE.format(me=me, greeting=hello, **guide(request, WHOLE["required"])) + quiet}]
    for index, entry in enumerate(chat):
        text = entry["text"].strip()
        if entry.get("role") == "assistant":
            messages.append({"role": "assistant", "content": text})
            continue
        text = f"{first}\n\nNotizen von {me}:\n{text}" if index == 0 else f"Ändere die Mail so und gib sie wieder ganz als JSON aus: {text}"
        messages.append({"role": "user", "content": text + quiet})
    found = answer(request, messages, WHOLE)
    content = tail_cut(re.sub(r"\n{3,}", "\n\n", found["content"]), me)
    out(done=True, text="\n\n".join(part for part in (hello, small(line(found["thanks"])), content, line(found["closing"])) if part))


def frame(request):
    me = request.get("me") or "mir"
    written = str(request.get("draft") or "").strip()
    quiet, _tuned = options(request)
    ask = situation(request) + (f"\n\nWas {me} als Inhalt geschrieben hat:\n{written[:1500]}" if written else f"\n\n{me} hat den Inhalt noch nicht geschrieben.")
    found = answer(request, [{"role": "system", "content": FRAME.format(me=me, **guide(request, SCHEMA["required"])) + quiet}, {"role": "user", "content": ask + quiet}], SCHEMA)
    out(greeting=greeting(request), thanks=small(line(found["thanks"])), closing=line(found["closing"]))


def main(args):
    try:
        if args[:1] == ["models"]:
            out(models=models())
        elif args[:1] in (["write"], ["frame"]):
            request = json.loads(args[1])
            # unless one was picked, the smallest model that is installed: it answers soonest
            request["model"] = request.get("model") or next((entry["name"] for entry in models()), "")
            (write if args[0] == "write" else frame)(request)
        else:
            print(__doc__)
            return 2
    except Failure as error:
        out(error=str(error))
        return 1
    except (ValueError, KeyError, IndexError) as error:
        out(error=f"{type(error).__name__}: {error}"[:200])
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
