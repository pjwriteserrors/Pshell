"""Text files and PDFs in another language, saved beside them as
"name (EN).txt": online through Google's translation (fast; the text leaves
the PC) or on this PC through a text model of Ollama (slower, private).
"""
import json
import os
import re
import subprocess
import urllib.parse
import urllib.request

import ai
import lookup

NAMES = {"en": "English", "de": "German", "fr": "French", "es": "Spanish", "it": "Italian", "nl": "Dutch", "pl": "Polish",
         "pt": "Portuguese", "ru": "Russian", "tr": "Turkish", "uk": "Ukrainian", "ja": "Japanese", "zh": "Chinese", "ar": "Arabic"}


class TranslateError(Exception):
    pass


def text_of(path):
    if path.lower().endswith(".pdf"):
        out = subprocess.run(["pdftotext", "-layout", "-q", path, "-"], capture_output=True, timeout=120)
        text = out.stdout.decode("utf-8", "replace")
    else:
        with open(path, "rb") as file:
            text = lookup.decode(file.read(2_000_000))
    if not text.strip():
        raise TranslateError(f"{os.path.basename(path)} has no text to translate (a scan needs OCR first)")
    return text


def chunks(text, size):
    """Pieces of about `size` characters, cut between paragraphs where possible."""
    pieces, current = [], ""
    for paragraph in re.split(r"(\n\s*\n)", text):
        if len(current) + len(paragraph) > size and current:
            pieces.append(current)
            current = ""
        while len(paragraph) > size:
            cut = paragraph.rfind(". ", 0, size)
            cut = cut + 1 if cut > size // 3 else size
            pieces.append(paragraph[:cut])
            paragraph = paragraph[cut:]
        current += paragraph
    if current:
        pieces.append(current)
    return pieces


def google(piece, target):
    data = urllib.parse.urlencode({"client": "gtx", "sl": "auto", "tl": target, "dt": "t", "q": piece}).encode()
    request = urllib.request.Request("https://translate.googleapis.com/translate_a/single", data=data,
                                     headers={"Content-Type": "application/x-www-form-urlencoded;charset=utf-8", "User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            answer = json.loads(response.read())
    except (OSError, ValueError) as error:
        raise TranslateError(f"The translation service did not answer ({error})")
    return "".join(segment[0] for segment in answer[0] if segment and isinstance(segment[0], str))


def local(piece, target, model):
    prompt = f"Translate the following text into {NAMES.get(target, target)}. Keep the line breaks and the layout, translate everything, add nothing, answer only with the translation.\n\n{piece}"
    return ai.generate(model, prompt, timeout=300)


def translate(path, target, engine, unique, report, check):
    text = text_of(path)
    if engine == "local":
        model = ai.status()["text"]
        if not model:
            raise TranslateError("Translating on this PC needs a text model in Ollama")
        pieces = chunks(text, 2500)
    else:
        pieces = chunks(text, 4500)
    out = []
    for index, piece in enumerate(pieces):
        check()
        if not piece.strip():
            out.append(piece)
            continue
        try:
            out.append(local(piece, target, model) if engine == "local" else google(piece, target))
        except ai.AiError as error:
            raise TranslateError(str(error))
        report((index + 1) / len(pieces))
    stem, ext = os.path.splitext(path)
    keep = ext.lower() in (".md", ".markdown", ".txt", ".srt", ".vtt", ".html", ".htm")
    target_path = unique(f"{stem} ({target.upper()}){ext if keep else '.txt'}")
    joined = ("\n\n" if engine == "local" else "").join(out)
    with open(target_path, "w", encoding="utf-8") as file:
        file.write(joined if joined.endswith("\n") else joined + "\n")
    return target_path
