"""What a mail says, taken apart the way a chat shows it.

A mail body carries more than the message: the mails it answers, quoted
below, and the sender's signature. `split()` separates the three, so a
bubble shows what was written and keeps the rest one click away:

  {"html", "text", "signature", "quote", "quoted"}

`html` is a small, safe subset Qt's rich text draws (bold, italics, links,
lists, inline pictures); remote pictures are never loaded.
"""

from __future__ import annotations

import html as htmllib
import re
from html.parser import HTMLParser

# bodies kept by an older version are read again
VERSION = 7

BLOCKS = {
    "p", "div", "tr", "table", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre",
    "section", "article", "header", "footer", "address", "center", "dl", "dt", "dd", "hr", "figure",
}
SKIP = {"head", "style", "script", "title", "noscript", "template", "svg", "object", "embed", "iframe"}
VOID = {"br", "img", "hr", "meta", "link", "input", "col", "wbr", "area", "base"}

# where the mails being answered begin, by the element a mail program wraps them in
QUOTE_IDS = {"divrplyfwdmsg", "appendonsend", "mail-editor-reference-message-container", "ms-outlook-mobile-body-separator-line", "stopspelling"}
QUOTE_CLASSES = {"gmail_quote", "gmail_quote_container", "moz-cite-prefix", "yahoo_quoted", "protonmail_quote", "zmail_extra", "gmail_attr"}
QUOTE_STYLE = re.compile(r"border-top:\s*solid\s*#(?:e1e1e1|b5c4df)", re.I)
SIGNATURE_IDS = {"signature", "ms-outlook-mobile-signature"}
SIGNATURE_CLASSES = {"gmail_signature", "moz-signature", "protonmail_signature_block"}

QUOTE_LINE = re.compile(
    r"^\s*(?:-{2,}\s*(?:Original Message|Ursprüngliche Nachricht|Ursprüngliche Nachricht|Forwarded message|Weitergeleitete Nachricht)\s*-{2,}"
    r"|On .{6,200} wrote:|Am .{6,200} schrieb .{0,200}:|Le .{6,200} a écrit\s*:|_{20,})\s*$",
    re.I,
)
HEADER_LINE = re.compile(r"^\s*\**(?:Von|From|De)\**\s*:\s*\S", re.I)
HEADER_NEXT = re.compile(r"^\s*\**(?:Gesendet|Sent|Datum|Date|An|To|Betreff|Subject|Envoyé)\**\s*:", re.I)
CLOSING = re.compile(
    r"^\s*(?:mit freundlichen gr(?:ü|ue)(?:ß|ss)en|freundliche gr(?:ü|ue)(?:ß|ss)e|(?:viele|beste|liebe|herzliche|schöne) gr(?:ü|ue)(?:ß|ss)e"
    r"|gr(?:ü|ue)(?:ß|ss)e|mfg|vg|lg|best regards|kind regards|warm regards|regards|best wishes|best|cheers|thanks|thank you|many thanks"
    r"|sincerely|yours sincerely|danke|vielen dank|besten dank|danke und gru(?:ß|ss))\b[\s,.!]*(?:[\wÀ-ɏ.-]+\s*){0,3}$",
    re.I,
)
MOBILE = re.compile(r"^\s*(?:Sent from my |Gesendet von (?:meinem|Mail|Outlook)|Von meinem .{2,30} gesendet|Get Outlook for |Outlook für .{2,12} beziehen|Diese Nachricht wurde von meinem)", re.I)
URL = re.compile(r"((?:https?://|www\.)[^\s<>\"')\]]+[^\s<>\"')\].,;:!?])")
FORWARD = re.compile(r"^\s*(?:fwd?|wg|tr|i)\s*:", re.I)
PREFIX = re.compile(r"^\s*(?:(?:re|aw|antw|sv|fwd?|wg|tr|r)\s*(?:\[\d+\])?\s*:\s*)+", re.I)


def clean_subject(subject):
    """The subject without its Re:/AW:/Fwd: prefixes."""
    return PREFIX.sub("", str(subject or "")).strip()


class Line:
    __slots__ = ("runs", "bullet", "depth", "offset")

    def __init__(self, offset=None):
        # where the line begins in the document it was read from
        self.offset = offset
        self.runs = []       # (text, bold, italic, href) or ("\0img", cid, alt, None)
        self.bullet = ""
        self.depth = 0

    def text(self):
        return "".join(run[0] for run in self.runs if run[0] != "\0img").replace(" ", " ")

    def blank(self):
        return not self.text().strip() and not any(run[0] == "\0img" for run in self.runs)


class Reader(HTMLParser):
    """HTML → lines of styled runs, remembering where quote and signature start."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lines = [Line()]
        self.skip = 0
        self.bold = 0
        self.italic = 0
        self.href = []
        self.lists = []
        self.pre = 0
        self.quote_at = None
        self.signature_at = None
        self.quote_offset = None
        self.signature_offset = None
        self.cite = 0
        self.starts = [0]

    def feed(self, data):
        self.starts = [0] + [match.end() for match in re.finditer("\n", data)]
        super().feed(data)

    def pos(self):
        line, column = self.getpos()
        return self.starts[min(line, len(self.starts)) - 1] + column

    def line(self):
        return self.lines[-1]

    def newline(self, force=False):
        if force or self.line().runs or self.line().bullet:
            self.lines.append(Line(self.pos()))
        else:
            self.line().offset = self.pos()

    def mark(self, attrs):
        ident = (attrs.get("id") or "").lower()
        classes = set((attrs.get("class") or "").lower().split())
        style = attrs.get("style") or ""
        index = len(self.lines) - (0 if self.line().runs else 1)
        if self.quote_at is None and (ident in QUOTE_IDS or classes & QUOTE_CLASSES or QUOTE_STYLE.search(style)):
            self.quote_at = index
            self.quote_offset = self.pos()
        if self.signature_at is None and self.quote_at is None and (ident in SIGNATURE_IDS or classes & SIGNATURE_CLASSES):
            self.signature_at = index
            self.signature_offset = self.pos()

    def handle_starttag(self, tag, attrs):
        attrs = {key: value or "" for key, value in attrs}
        if tag in SKIP:
            self.skip += 1
            return
        if self.skip:
            return
        self.mark(attrs)
        if tag == "blockquote":
            if self.quote_at is None and (attrs.get("type") == "cite" or "cite" in attrs or self.cite == 0):
                self.newline()
                self.quote_at = len(self.lines) - 1
                self.quote_offset = self.pos()
            self.cite += 1
        if tag in BLOCKS:
            self.newline()
        if tag == "br":
            self.newline(force=True)
        elif tag in ("b", "strong") or tag in ("h1", "h2", "h3", "h4"):
            self.bold += 1
        elif tag in ("i", "em"):
            self.italic += 1
        elif tag == "a":
            target = attrs.get("href", "").strip()
            self.href.append(target if re.match(r"(?:https?:|mailto:|tel:)", target, re.I) else "")
        elif tag in ("ul", "ol"):
            self.lists.append([tag, 0])
        elif tag == "li":
            self.newline()
            if self.lists:
                self.lists[-1][1] += 1
                self.line().bullet = "•" if self.lists[-1][0] == "ul" else f"{self.lists[-1][1]}."
                self.line().depth = len(self.lists) - 1
            else:
                self.line().bullet = "•"
        elif tag == "td" or tag == "th":
            if self.line().runs:
                self.line().runs.append(("  ", False, False, None))
        elif tag == "pre":
            self.pre += 1
        elif tag == "img":
            source = attrs.get("src", "")
            if source.lower().startswith("cid:"):
                self.line().runs.append(("\0img", source[4:].strip("<>"), attrs.get("alt", ""), None))

    def handle_endtag(self, tag):
        if tag in SKIP:
            self.skip = max(0, self.skip - 1)
            return
        if self.skip:
            return
        if tag in ("b", "strong") or tag in ("h1", "h2", "h3", "h4"):
            self.bold = max(0, self.bold - 1)
        elif tag in ("i", "em"):
            self.italic = max(0, self.italic - 1)
        elif tag == "a" and self.href:
            self.href.pop()
        elif tag in ("ul", "ol") and self.lists:
            self.lists.pop()
        elif tag == "pre":
            self.pre = max(0, self.pre - 1)
        elif tag == "blockquote":
            self.cite = max(0, self.cite - 1)
        if tag in BLOCKS or tag == "li":
            self.newline()
            # a paragraph keeps a blank line after it
            if tag in ("p", "ul", "ol", "table", "h1", "h2", "h3", "h4", "pre", "blockquote") and len(self.lines) > 1 and not self.lines[-2].blank():
                self.newline(force=True)

    def handle_data(self, data):
        if self.skip:
            return
        if self.pre:
            parts = data.split("\n")
            for index, part in enumerate(parts):
                if index:
                    self.newline(force=True)
                if part:
                    self.line().runs.append((part, self.bold > 0, self.italic > 0, self.href[-1] if self.href else None))
            return
        text = re.sub(r"[ \t\r\n\f​‌﻿]+", " ", data)
        if not text:
            return
        if text == " " and not self.line().runs:
            return
        if not self.line().runs:
            text = text.lstrip(" ")
        self.line().runs.append((text, self.bold > 0, self.italic > 0, (self.href[-1] or None) if self.href else None))


def from_plain(text):
    lines = []
    for raw in str(text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = Line()
        position = 0
        for match in URL.finditer(raw):
            if match.start() > position:
                line.runs.append((raw[position:match.start()], False, False, None))
            target = match.group(1)
            line.runs.append((target, False, False, target if target.lower().startswith("http") else "https://" + target))
            position = match.end()
        if position < len(raw):
            line.runs.append((raw[position:], False, False, None))
        lines.append(line)
    return lines


def tidy(lines):
    """No blank lines at the ends, never two in a row."""
    out = []
    for line in lines:
        if line.blank() and (not out or out[-1].blank()):
            continue
        out.append(line)
    while out and out[-1].blank():
        out.pop()
    return out


def render(lines, images):
    parts = []
    for line in tidy(lines):
        if line.blank():
            parts.append("")
            continue
        text = ""
        for run in line.runs:
            if run[0] == "\0img":
                path = images.get(run[1]) if images else None
                if path:
                    text += f'<img src="file://{htmllib.escape(path, quote=True)}" width="{images.get(run[1] + ":w", 280)}">'
                continue
            piece = htmllib.escape(run[0], quote=False).replace(" ", "&nbsp;")
            if run[1]:
                piece = f"<b>{piece}</b>"
            if run[2]:
                piece = f"<i>{piece}</i>"
            if run[3]:
                piece = f'<a href="{htmllib.escape(run[3], quote=True)}">{piece}</a>'
            text += piece
        if line.bullet:
            text = "&nbsp;" * (4 * line.depth) + f"{line.bullet}&nbsp;" + text
        parts.append(text)
    return "<br>".join(parts)


def plain(lines):
    return "\n".join((f"{line.bullet} " if line.bullet else "") + line.text().rstrip() for line in tidy(lines))


def find_quote(lines):
    """The first line of what was quoted from older mails, or None."""
    for index, line in enumerate(lines):
        text = line.text()
        if QUOTE_LINE.match(text):
            # a ruler only counts with the mail's header under it
            if re.match(r"^\s*_{20,}\s*$", text) and not any(HEADER_LINE.match(other.text()) for other in lines[index + 1:index + 4]):
                continue
            return index
        if HEADER_LINE.match(text) and any(HEADER_NEXT.match(other.text()) for other in lines[index + 1:index + 5]):
            return index
    # a trailing block of "> " lines
    end = len(lines)
    while end > 0 and lines[end - 1].blank():
        end -= 1
    start = end
    while start > 0 and (lines[start - 1].text().lstrip().startswith(">") or lines[start - 1].blank()):
        start -= 1
    while start < end and lines[start].blank():
        start += 1
    if end - start >= 1 and start > 0:
        return start
    return None


def find_signature(lines):
    for index, line in enumerate(lines):
        if line.text().rstrip("  ") in ("--", "-- ", "—", "––") and index > 0:
            return index
    for index, line in enumerate(lines):
        if MOBILE.match(line.text()):
            return index
    # a closing formula near the end takes the name and address under it along
    filled = [index for index, line in enumerate(lines) if not line.blank()]
    for index in reversed(filled[-14:]):
        if index == filled[0]:
            break
        text = lines[index].text().strip()
        if len(text) <= 60 and CLOSING.match(text):
            return index
    return None


def split(body, is_html=True, subject="", images=None, keep_quote=False, raw=False):
    """Body → what was written, the signature and what was quoted.

    The signature of an HTML mail keeps its layout (`signatureRich`); with
    `raw` it also comes as the sender wrote it (`signatureRaw`), to be sent
    again.
    """
    source = str(body or "")
    quote_offset = signature_offset = None
    if is_html:
        reader = Reader()
        try:
            reader.feed(source)
            reader.close()
        except Exception:  # a broken document still yields what was read so far
            pass
        lines = reader.lines
        quote_at, signature_at = reader.quote_at, reader.signature_at
        quote_offset, signature_offset = reader.quote_offset, reader.signature_offset
    else:
        lines = from_plain(body)
        quote_at = signature_at = None

    found = find_quote(lines)
    if found is not None and (quote_at is None or found < quote_at):
        quote_at, quote_offset = found, lines[found].offset
    # a forward is its quoted mail
    forward = keep_quote or bool(FORWARD.match(str(subject or "")))
    quote = []
    if quote_at is not None and not forward:
        own, quote = lines[:quote_at], lines[quote_at:]
        # nothing above the quote: the mail answers inline, keep it whole
        if not any(not line.blank() for line in own):
            own, quote = lines, []
    else:
        own = lines
    if not quote:
        quote_offset = None

    if signature_at is not None and signature_at >= len(own):
        signature_at = signature_offset = None
    found = find_signature(own)
    if found is not None and (signature_at is None or found < signature_at):
        signature_at, signature_offset = found, own[found].offset
    signature = []
    if signature_at is not None and any(not line.blank() for line in own[:signature_at]):
        own, signature = own[:signature_at], own[signature_at:]
    else:
        signature_offset = None

    # the signature as it was laid out, cut from the document
    fragment = ""
    if is_html and signature and signature_offset is not None:
        end = quote_offset if quote_offset is not None and quote_offset > signature_offset else len(source)
        fragment = source[signature_offset:end]
    rich = clean(fragment, images) if fragment and any(not line.blank() for line in signature) else ""

    # a mail built from tables and pictures is a layout, not a note
    written = source[:signature_offset if signature_offset is not None else (quote_offset if quote_offset is not None else len(source))] if is_html else ""
    designed = len(re.findall(r"<table", written, re.I)) >= 2 or len(re.findall(r"<img", written, re.I)) >= 2

    text = plain(own)
    result = {
        "designed": designed,
        # where what was written (signature included) ends in the document
        # where what is drawn ends: a note before its signature (that folds away), a layout before what it quotes
        "pageEnd": signature_offset if signature_offset is not None and not designed else (quote_offset if quote_offset is not None else len(source)),
        # the pictures inside what was written and inside the signature
        "cids": [run[1] for line in own for run in line.runs if run[0] == "\0img"] + re.findall(r"""src\s*=\s*["']?cid:([^"'\s>]+)""", fragment, re.I),
        "html": render(own, images)[:60000],
        "text": text[:20000],
        "signature": rich[:60000] if rich else render(signature, images)[:8000],
        "signatureRich": bool(rich),
        "signatureText": plain(signature)[:4000],
        "quote": render(quote[:400], None)[:30000],
        "quoted": bool(quote),
        "v": VERSION,
    }
    if raw:
        result["signatureRaw"] = clean(fragment, None, faithful=True) if fragment and rich else ""
    return result


SAFE_TAGS = {
    "table", "tbody", "thead", "tfoot", "tr", "td", "th", "p", "div", "span", "br", "b", "strong", "i", "em", "u", "s", "a", "img", "font",
    "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "sup", "sub", "center", "blockquote", "small", "big", "pre",
}
SAFE_ATTRIBUTES = {"width", "height", "align", "valign", "color", "bgcolor", "cellpadding", "cellspacing", "border", "colspan", "rowspan", "alt", "face", "size", "title"}


class Cleaner(HTMLParser):
    """A piece of a mail as a document of its own: tags balanced, nothing that runs or tracks.

    For the screen (`faithful` off) only what Qt's rich text draws is kept
    and pictures inside the mail point at their files; `faithful` keeps the
    sender's markup so the piece can be sent again.
    """

    def __init__(self, images, faithful):
        super().__init__(convert_charrefs=True)
        self.images = images or {}
        self.faithful = faithful
        self.out = []
        self.open = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in SKIP or tag in ("html", "body", "meta", "link", "base", "form", "input", "button"):
            self.skip += 1 if tag in SKIP else 0
            return
        if self.skip or (tag not in SAFE_TAGS and not self.faithful) or ":" in tag:
            return
        kept = []
        for name, value in attrs:
            name, value = name.lower(), (value or "").strip()
            if name.startswith("on"):
                continue
            if name == "href":
                if not re.match(r"(?:https?:|mailto:|tel:)", value, re.I):
                    continue
            elif name == "src":
                if value.lower().startswith("cid:"):
                    if not self.faithful:
                        cid = value[4:]
                        path = self.images.get(cid)
                        if not path:
                            return
                        value = f"file://{path}"
                        if not any(key.lower() == "width" for key, _ in attrs):
                            kept.append(("width", str(self.images.get(cid + ":w", 280))))
                elif not value.lower().startswith("https://"):
                    return
            elif name == "style":
                value = ";".join(part for part in value.split(";") if "url(" not in part.lower() and "expression" not in part.lower())
            elif name not in SAFE_ATTRIBUTES and not (self.faithful and name in ("id", "class", "dir", "lang", "role", "name")):
                continue
            kept.append((name, value))
        self.out.append("<" + tag + "".join(f' {name}="{htmllib.escape(value, quote=True)}"' for name, value in kept) + ">")
        if tag not in VOID:
            self.open.append(tag)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.open and self.open[-1] == tag:
            self.out.append(f"</{self.open.pop()}>")

    def handle_endtag(self, tag):
        if tag in SKIP:
            self.skip = max(0, self.skip - 1)
            return
        if self.skip or tag not in self.open:
            return
        while self.open:
            closed = self.open.pop()
            self.out.append(f"</{closed}>")
            if closed == tag:
                break

    def handle_data(self, data):
        if not self.skip:
            self.out.append(htmllib.escape(data, quote=False))


def clean(fragment, images=None, faithful=False):
    cleaner = Cleaner(images, faithful)
    try:
        cleaner.feed(str(fragment or ""))
        cleaner.close()
    except Exception:
        pass
    while cleaner.open:
        cleaner.out.append(f"</{cleaner.open.pop()}>")
    return "".join(cleaner.out).strip()


def preview(text, limit=140):
    return re.sub(r"\s+", " ", str(text or "")).strip()[:limit]


def to_html(text):
    """What was typed, as the HTML a mail carries."""
    lines = []
    for line in str(text or "").replace("\r\n", "\n").split("\n"):
        escaped = htmllib.escape(line, quote=False)
        escaped = URL.sub(lambda match: f'<a href="{match.group(1) if match.group(1).lower().startswith("http") else "https://" + match.group(1)}">{match.group(1)}</a>', escaped)
        lines.append(escaped or "&nbsp;")
    return "".join(f"<div>{line}</div>" for line in lines)
