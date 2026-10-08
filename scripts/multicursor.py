#!/usr/bin/env python3
"""Lines and cursors the way a code editor has them, in every text field.

  multicursor.py                          the daemon, run by core/services/Multicursor.qml
  multicursor.py try [--width N] [--firefox] "te|xt" step…
                                          what the steps leave in a text field
                                          that wraps after N letters, or one
                                          that stops twice where it wraps
                                          (| is the cursor, ¦ the other cursors)
      steps: move-up move-down copy-up copy-down cursor-up cursor-down pin
             go:N (a click on the Nth letter) type:TEXT esc
             left right up down home end backspace delete, with shift- and ctrl-

A text field cannot be asked for its text or told where to put a cursor. It
knows keys and the clipboard, and that is all this uses: it reads by selecting
and copying (Shift+Home, Ctrl+C), moves by the arrow keys and writes by
pasting or by the keys that were typed.

  move a line up or down        the line and its neighbour are selected,
                                compared with what was read and pasted swapped
  copy a line up or down        the line is pasted once more
  a cursor above or below       from then on every key is typed at each
                                cursor, one after the other; the real cursor
                                comes back to the first one. Letters, Backspace,
                                Delete, the arrows, Home, End, Ctrl for words,
                                Shift for selections, Ctrl+V. Escape, a click
                                or any other key leaves it.
  a cursor where the cursor is  with a click (Alt+click) the click puts it
                                there first. The first one only marks a place,
                                the second makes it two cursors.

Places are counted in letters from the cursor, so wrapped lines are no
trouble; a line is what stands between two line breaks. Nothing is pasted
over a selection that is not, letter for letter, what was read before, and
the clipboard gets back what it held, in every format it held it in.

To see a shortcut before the window does and to keep Alt out of what it types
itself, the daemon takes the keyboards for itself (evdev grab) and hands every
key on through a keyboard of its own (uinput), but only while the window that
has the keyboard is one the shell names. Both Shift keys and Escape together
give the keyboards back at once.

The shell says on stdin what holds:
{"active": bool, "window": id, "binds": {action: "Alt+Down", …}}.
"""

from __future__ import annotations

import contextlib
import ctypes
import json
import os
import select
import selectors
import socket
import struct
import subprocess
import sys
import threading
import time
import unicodedata
from collections import deque

NAME = "pshell multicursor"

CTRL, SHIFT, ALT, ALTGR = 29, 42, 56, 100
ESCAPE, BACKSPACE, DELETE = 1, 14, 111
HOME, UP, LEFT, RIGHT, END, DOWN = 102, 103, 105, 106, 107, 108
PAGE_UP, PAGE_DOWN = 104, 109
# held with other keys; their state is the compositor's as long as it is handed on
MODIFIERS = {29, 97, 42, 54, 56, 100, 125, 126}
# keys that move the cursor and leave the text alone
ARROWS = {HOME, UP, LEFT, RIGHT, END, DOWN, PAGE_UP, PAGE_DOWN}
BUTTONS = {"mouseleft": 0x110, "mouseright": 0x111, "mousemiddle": 0x112, "mouseback": 0x113, "mouseforward": 0x114}
TOUCH = 0x14a
# names niri has for keys that xkb calls otherwise
ALIASES = {"page_up": "prior", "page_down": "next", "enter": "return", "esc": "escape"}
ACTIONS = ("moveUp", "moveDown", "copyUp", "copyDown", "cursorUp", "cursorDown", "addCursor")

# seconds after a key of its own: the compositor reads 64 events at a time
STROKE = 0.0006
# seconds a window has to answer Ctrl+C at most, and at least
PATIENCE = (0.3, 0.08)
# seconds a window gets to put in what it pasted, and to put the cursor where it was clicked
PASTE, CLICK = 0.03, 0.05
# seconds a key that repeats may be old: what piled up behind a slow step is dropped
STALE = 0.08


def cells(text: str) -> list[str]:
    """A text as what one arrow key steps over: letters with their accents, whole emoji."""
    out: list[str] = []
    for char in text.replace("\r\n", "\n"):
        joins = out and out[-1] != "\n" and (
            unicodedata.combining(char) or char == "‍" or "︀" <= char <= "️"
            or "\U0001f3fb" <= char <= "\U0001f3ff" or out[-1][-1] == "‍"
            or ("\U0001f1e6" <= char <= "\U0001f1ff" and len(out[-1]) == 1 and "\U0001f1e6" <= out[-1] <= "\U0001f1ff"))
        if joins:
            out[-1] += char
        else:
            out.append(char)
    return out


# ── the clipboard ────────────────────────────────────────────────────────────

def number(value: int) -> bytes:
    return struct.pack("<I", value)


def string(value: str) -> bytes:
    data = value.encode() + b"\0"
    return number(len(data)) + data + b"\0" * (-len(data) % 4)


class Clipboard:
    """The clipboard, over the compositor's data control: told of every copy
    the moment it happens, reads every format of it and offers its own."""

    TEXT = ("text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT")
    # files are copied, not a text: whatever has the keyboard is no text field
    FILES = ("text/uri-list", "x-special/gnome-copied-files", "application/x-kde-cutselection")
    # history and hints leave alone what carries this
    SECRET = "x-kde-passwordManagerHint"
    MINE = "application/x-pshell-multicursor"
    UNSET = object()

    def __init__(self, notify=None):
        name = os.environ.get("WAYLAND_DISPLAY") or "wayland-0"
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(name if os.path.isabs(name) else os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""), name))
        self.data = b""
        self.fds: list[int] = []
        self.kinds = {1: "display"}
        self.last = 1
        self.globals: dict[str, int] = {}
        self.done = 0
        # the formats of every offer, the offer that is the clipboard and whether it is one of ours
        self.offers: dict[int, list[str]] = {}
        self.offer = 0
        self.mine = False
        # what our sources hand out, and the one that is the clipboard
        self.sources: dict[int, dict[str, bytes]] = {}
        self.own = 0
        self.changes = 0
        self.sends = 0
        self.patience = PATIENCE[0]
        # what the clipboard held before it was borrowed, and what got into it since
        self.kept = self.UNSET
        self.junk: set[bytes] = set()
        self.notify = notify or (lambda busy: None)
        registry = self.new("registry")
        self.send(1, 1, number(registry))
        self.roundtrip()
        manager = next((name for name in ("ext_data_control_manager_v1", "zwlr_data_control_manager_v1") if name in self.globals), None)
        if not manager or "wl_seat" not in self.globals:
            raise OSError("no data control")
        seat = self.bind(registry, "wl_seat", "seat")
        self.manager = self.bind(registry, manager, "manager")
        self.device = self.new("device")
        self.send(self.manager, 1, number(self.device) + number(seat))
        self.roundtrip()

    # the wire

    def new(self, kind: str) -> int:
        self.last += 1
        self.kinds[self.last] = kind
        return self.last

    def bind(self, registry: int, interface: str, kind: str) -> int:
        target = self.new(kind)
        self.send(registry, 0, number(self.globals[interface]) + string(interface) + number(1) + number(target))
        return target

    def send(self, target: int, opcode: int, body: bytes = b"", fds=()):
        message = struct.pack("<IHH", target, opcode, 8 + len(body)) + body
        if fds:
            socket.send_fds(self.sock, [message], list(fds))
        else:
            self.sock.sendall(message)

    def read(self):
        data, fds, _, _ = socket.recv_fds(self.sock, 65536, 16)
        if not data:
            raise OSError("the compositor is gone")
        self.data += data
        self.fds += fds

    def parse(self) -> bool:
        if len(self.data) < 8:
            return False
        target, opcode, size = struct.unpack_from("<IHH", self.data)
        if len(self.data) < size:
            return False
        body, self.data = self.data[8:size], self.data[size:]
        self.event(self.kinds.get(target), target, opcode, body)
        return True

    def pump(self, seconds: float = 0, until=None) -> bool:
        """Takes what the compositor says for that long, or until `until` holds."""
        end = time.monotonic() + seconds
        while True:
            while self.parse():
                pass
            if until and until():
                return True
            if not select.select([self.sock], [], [], max(0.0, end - time.monotonic()))[0]:
                return False
            self.read()

    def roundtrip(self):
        callback = self.new("callback")
        self.send(1, 0, number(callback))
        if not self.pump(2, lambda: self.done == callback):
            raise OSError("the compositor does not answer")

    def event(self, kind, target: int, opcode: int, body: bytes):
        def text(at: int = 0) -> str:
            size = struct.unpack_from("<I", body, at)[0]
            return body[at + 4:at + 3 + size].decode("utf-8", "replace")

        first = struct.unpack_from("<I", body)[0] if len(body) >= 4 else 0
        if kind == "display":
            if opcode == 0:
                raise OSError(text(8))
            self.kinds.pop(first, None)
        elif kind == "registry" and opcode == 0:
            self.globals[text(4)] = first
        elif kind == "callback":
            self.done = target
        elif kind == "device":
            if opcode == 0:
                self.kinds[first] = "offer"
                self.offers[first] = []
            elif opcode == 1:
                self.selected(first)
            elif opcode == 2:
                raise OSError("the clipboard is gone")
            elif first and first != self.offer:
                # the primary selection: not used
                self.forget(first)
        elif kind == "offer":
            self.offers.setdefault(target, []).append(text())
        elif kind == "source":
            if opcode == 0 and self.fds:
                self.sends += 1
                threading.Thread(target=self.pour, args=(self.fds.pop(0), self.sources.get(target, {}).get(text(), b"")), daemon=True).start()
            elif opcode == 1:
                self.send(target, 1)
                self.sources.pop(target, None)
                if self.own == target:
                    self.own = 0

    @staticmethod
    def pour(fd: int, data: bytes):
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
        except OSError:
            pass
        finally:
            os.close(fd)

    def forget(self, offer: int):
        if self.offers.pop(offer, None) is not None:
            self.send(offer, 1)

    def selected(self, offer: int):
        if self.offer and self.offer != offer:
            self.forget(self.offer)
        self.offer = offer
        self.mine = any(name == self.MINE for name in self.offers.get(offer, []))
        # a clipboard that is emptied is not a copy: the copy comes right behind
        if offer and not self.mine:
            self.changes += 1

    # reading and offering

    def receive(self, kind: str, seconds: float = 0.5) -> bytes | None:
        """What the clipboard holds in one format."""
        if self.mine and self.own in self.sources:
            return self.sources[self.own].get(kind)
        if not self.offer:
            return None
        offer = self.offer
        reader, writer = os.pipe()
        self.send(offer, 0, string(kind), [writer])
        os.close(writer)
        os.set_blocking(reader, False)
        chunks, end = [], time.monotonic() + seconds
        try:
            while True:
                left = end - time.monotonic()
                if left <= 0:
                    return None
                ready = select.select([reader, self.sock], [], [], left)[0]
                if self.sock in ready:
                    self.read()
                    while self.parse():
                        pass
                if reader in ready:
                    chunk = os.read(reader, 1 << 16)
                    if not chunk:
                        return b"".join(chunks)
                    chunks.append(chunk)
        except OSError:
            return None
        finally:
            os.close(reader)

    def raw(self) -> bytes:
        kinds = self.offers.get(self.offer, [])
        if any(kind in kinds for kind in self.FILES):
            return b""
        kind = next((kind for kind in self.TEXT if kind in kinds), None)
        return (self.receive(kind) or b"") if kind else b""

    def text(self) -> str:
        """The clipboard as text; "" when it holds something else."""
        return self.raw().decode("utf-8", "replace").replace("\r\n", "\n")

    def give(self, contents: dict[str, bytes]) -> int:
        """Makes the clipboard hold this, a format a key."""
        source = self.new("source")
        self.send(self.manager, 0, number(source))
        for kind in contents:
            self.send(source, 0, string(kind))
        self.sources[source] = contents
        self.send(self.device, 0, number(source))
        # not every compositor tells the one that set the clipboard about it
        self.own, self.mine = source, True
        self.roundtrip()
        return source

    # what the text field is read and written with

    def copy(self, press, sure: float = 0) -> str:
        """What `press` (Ctrl+C) copies; "" when nothing was selected. With
        `sure` something is selected: the seconds the window may take."""
        self.keep()
        self.pump()
        seen, start = self.changes, time.monotonic()
        press()
        if not self.pump(sure or self.patience, lambda: self.changes != seen):
            return ""
        took = time.monotonic() - start
        self.patience = min(PATIENCE[0], max(PATIENCE[1], took * 5, self.patience * 0.8))
        # browsers set the clipboard twice for one copy
        self.pump(0.003)
        data = self.raw()
        if data:
            self.junk.add(data)
        return data.decode("utf-8", "replace").replace("\r\n", "\n")

    def paste(self, text: str, press):
        """Has `press` (Ctrl+V) paste the text, and waits until the window has fetched it."""
        self.keep()
        data = text.encode()
        self.give({**{kind: data for kind in self.TEXT}, self.SECRET: b"secret", self.MINE: b""})
        # whoever watches the clipboard fetches it first
        end, seen = time.monotonic() + 0.15, -1
        while seen != self.sends and time.monotonic() < end:
            seen = self.sends
            self.pump(0.02)
        press()
        self.pump(0.4, lambda: self.sends != seen)
        self.settle()

    def settle(self):
        time.sleep(PASTE)

    def keep(self):
        """Remembers what the clipboard holds, before the first thing changes it."""
        if self.kept is not self.UNSET:
            return
        self.notify(True)
        self.pump()
        kinds = [kind for kind in self.offers.get(self.offer, []) if "/" in kind or kind in self.TEXT]
        if self.mine and self.own in self.sources:
            self.kept = self.sources[self.own]
        elif not kinds:
            self.kept = None
        else:
            contents: dict[str, bytes] = {}
            for kind in kinds[:24]:
                data = self.receive(kind, 0.3)
                if data is not None:
                    contents[kind] = data
                if sum(len(data) for data in contents.values()) > 64 << 20:
                    break
            self.kept = contents or None

    def restore(self):
        if self.kept is self.UNSET:
            return
        kept, self.kept = self.kept, self.UNSET
        try:
            if kept is None:
                self.send(self.device, 0, number(0))
                self.own, self.mine, self.offer = 0, False, 0
                self.roundtrip()
            else:
                self.give({**kept, self.MINE: b""})
        finally:
            self.notify(False)
        spare = next((kept[kind] for kind in self.TEXT if kept and kind in kept), None)
        junk, self.junk = {data for data in self.junk if data != spare}, set()
        if junk:
            TIDY.add(junk)

    @contextlib.contextmanager
    def borrow(self):
        """The clipboard is the way into a text field; afterwards it holds what it held."""
        try:
            yield
        finally:
            self.restore()

    def leave(self):
        """Hands what is ours of the clipboard to a process that stays."""
        contents = self.sources.get(self.own) if self.mine else None
        kind = next((kind for kind in contents or {} if kind in self.TEXT), None) or next((kind for kind in contents or {} if kind != self.MINE), None)
        if kind and contents[kind]:
            try:
                subprocess.run(["wl-copy", "--type", kind], input=contents[kind], timeout=2)
            except (OSError, subprocess.SubprocessError):
                pass


class Tidy:
    """Takes what was read out of text fields out of the clipboard history
    (cliphist) again, once nothing has been read for a moment."""

    def __init__(self):
        self.junk: set[bytes] = set()
        self.lock = threading.Lock()
        self.due = 0.0
        self.running = False

    def add(self, junk: set[bytes]):
        with self.lock:
            self.junk |= junk
            self.due = time.monotonic() + 1
            start, self.running = not self.running, True
        if start:
            threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        while True:
            with self.lock:
                left = self.due - time.monotonic()
                if left <= 0:
                    junk, self.junk, self.running = self.junk, set(), False
                    break
            time.sleep(left)
        # a line of the history: its number and how the entry starts, blanks as one space
        starts = {" ".join(data.decode("utf-8", "replace").split())[:48] for data in junk} - {""}
        try:
            listing = subprocess.run(["cliphist", "list"], capture_output=True, timeout=5).stdout.splitlines()
            for line in listing[:min(600, 3 * len(junk) + 20)]:
                shown = line.partition(b"\t")[2].decode("utf-8", "replace")
                if any(shown.startswith(start) for start in starts) and subprocess.run(
                        ["cliphist", "decode"], input=line + b"\n", capture_output=True, timeout=3).stdout in junk:
                    subprocess.run(["cliphist", "delete"], input=line + b"\n", timeout=3)
        except (OSError, subprocess.SubprocessError):
            pass


TIDY = Tidy()


# ── the text field ───────────────────────────────────────────────────────────

class Field:
    """The text field that has the keyboard, as far as keys and the clipboard reach into it."""

    def __init__(self, tap, clipboard, copy: int = 46, paste: int = 47):
        self.tap = tap
        self.clipboard = clipboard
        self.c, self.v = copy, paste
        # this window swallows arrow keys (Firefox stops twice where a line wraps)
        self.slips = False

    def move(self, count: int):
        self.tap(RIGHT if count > 0 else LEFT, (), abs(count))

    def select(self, count: int):
        self.tap(RIGHT if count > 0 else LEFT, (SHIFT,), abs(count))

    def copy(self, sure: float = 0) -> str:
        return self.clipboard.copy(lambda: self.tap(self.c, (CTRL,)), sure)

    def paste(self, text: str):
        self.clipboard.paste(text, lambda: self.tap(self.v, (CTRL,)))

    def left(self, lines: int) -> str:
        """The text from that many lines up to the cursor."""
        self.tap(UP, (SHIFT,), lines)
        self.tap(HOME, (SHIFT,))
        return self.read(RIGHT, LEFT)

    def right(self, lines: int) -> str:
        self.tap(DOWN, (SHIFT,), lines)
        self.tap(END, (SHIFT,))
        return self.read(LEFT, RIGHT)

    def all(self) -> str:
        """Everything in front of the cursor."""
        self.tap(HOME, (CTRL, SHIFT))
        return self.read(RIGHT, LEFT)

    def read(self, back: int, away: int) -> str:
        """Copies what was just selected from the cursor on, and puts the
        cursor back with the arrow key `back`."""
        text = self.copy()
        if text:
            self.tap(back)
        else:
            # nothing to select, the text ends here. Firefox selects something
            # all the same that swallows what is pasted next: a letter the
            # other way and back takes it away
            self.tap(back, (SHIFT,))
            self.tap(away)
        return text

    def gather(self, grab, breaks: int, fits) -> tuple[str, bool] | None:
        known, lines = None, breaks
        while True:
            text = grab(lines)
            if known is not None and not fits(text, known):
                return None
            if text.count("\n") >= breaks:
                return text, False
            if not text or text == known or lines > 64:
                # nothing more to select: the text ends here
                return text, not text or text == known
            known, lines = text, lines * 4

    def before(self, breaks: int) -> tuple[str, bool] | None:
        """The text in front of the cursor back over that many line breaks, and
        whether the text starts there. None when what is read does not hold still."""
        return self.gather(self.left, breaks, str.endswith)

    def after(self, breaks: int) -> tuple[str, bool] | None:
        return self.gather(self.right, breaks, str.startswith)

    def mark(self, count: int, wanted: str) -> bool:
        """Selects that many letters from the cursor on (back, when negative)
        and reads them: they have to be `wanted`. Arrow keys the window
        swallowed are pressed again. The cursor is where it was when they are not."""
        if not count:
            return wanted == ""
        self.select(count)
        pressed = abs(count)
        for _ in range(6):
            # two keys in a row are never both swallowed: from the second on something is selected
            text = self.copy(1 + pressed * 0.003 if pressed > 1 else 0)
            if text == wanted:
                return True
            missing = len(cells(wanted)) - len(cells(text))
            if text or pressed > 1:
                if not text or not 0 < missing <= 8 + abs(count) // 2 or not (wanted.startswith if count > 0 else wanted.endswith)(text):
                    break
            self.slips = True
            self.select(missing if count > 0 else -missing)
            pressed += missing
        self.tap(LEFT if count > 0 else RIGHT)
        return False

    def jump(self, count: int, wanted: str) -> bool:
        """Moves the cursor over `wanted`, and knows that it got there."""
        if not self.mark(count, wanted):
            return False
        if count:
            self.tap(RIGHT if count > 0 else LEFT)
        return True

    def back(self, wanted: str):
        """The cursor back over what stands in front of it: counted, or read where keys get swallowed."""
        if not self.slips or not self.jump(-len(cells(wanted)), wanted):
            self.move(-len(cells(wanted)))


def lines(field: Field, action: str) -> bool | None:
    """Moves or copies the line of the cursor. None when there is no text to
    read at all: whatever has the keyboard is no text field."""
    above = field.before(2 if action == "moveUp" else 1)
    below = field.after(2 if action == "moveDown" else 1) if above else None
    if not above or not below:
        return False
    (front, top), (back, bottom) = above, below
    if not front and not back:
        return None
    rest, started, head = front.rpartition("\n")
    tail, ended, more = back.partition("\n")
    if not (started or top) or not (ended or bottom):
        return False
    line, other, behind = head + tail, "", tail
    if action == "moveDown":
        other, closed, _ = more.partition("\n")
        if not ended:
            return True
        if not (closed or bottom):
            return False
        # to the end of the line below, then both lines the other way round
        behind, old, new, home = f"{tail}\n{other}", f"{line}\n{other}", f"{other}\n{line}", tail
    elif action == "moveUp":
        _, opened, other = rest.rpartition("\n")
        if not started:
            return True
        if not (opened or top):
            return False
        old, new, home = f"{other}\n{line}", f"{line}\n{other}", f"{tail}\n{other}"
    else:
        old, new, home = line, f"{line}\n{line}", tail if action == "copyDown" else f"{tail}\n{line}"
    if not field.jump(len(cells(behind)), behind):
        return False
    if not field.mark(-len(cells(old)), old):
        field.back(behind)
        return False
    field.paste(new)
    field.back(home)
    return True


# ── several cursors ──────────────────────────────────────────────────────────

class Lost(Exception):
    """The text is not what the sheet says."""


class Cursor:
    def __init__(self, pos: int):
        self.pos = pos
        # where its selection started, None without one
        self.anchor: int | None = None

    def span(self) -> tuple[int, int]:
        return (min(self.pos, self.anchor), max(self.pos, self.anchor)) if self.anchor is not None else (self.pos, self.pos)


def wordy(cell: str) -> bool:
    return cell[0].isalnum() or cell[0] == "_"


class Sheet:
    """The text around the cursors as far as it has been read, and the cursors
    in it. The text field has one cursor: it goes from place to place (hop)
    and does at each what was typed. Every change is made here as well, so a
    place is always a number of arrow keys away."""

    def __init__(self, field: Field):
        self.field = field
        self.cells: list[str] = []
        # the text is known from its start, to its end
        self.top = self.bottom = False
        # where the real cursor is, and the selection it shows
        self.at = 0
        self.shown: tuple[int, int] | None = None
        self.cursors: list[Cursor] = []
        self.main: Cursor | None = None
        # places that move along while more is read
        self.marks: list[Cursor] = []

    def open(self) -> bool:
        """Starts with the line of the cursor."""
        front = self.field.before(1)
        back = self.field.after(1) if front else None
        if not front or not back:
            return False
        (before, self.top), (after, self.bottom) = front, back
        self.cells = cells(before) + cells(after)
        self.at = len(cells(before))
        self.main = Cursor(self.at)
        self.cursors = [self.main]
        return bool(self.cells)

    def pin(self):
        """A cursor where the real cursor is, wherever that is: everything in
        front of it is read. The cursors of before stay when it is still their text."""
        text = cells(self.field.all())
        fits = self.top and self.cursors and (text == self.cells[:len(text)] or (not self.bottom and text[:len(self.cells)] == self.cells))
        if not fits:
            self.cursors, self.cells, self.top, self.bottom = [], text, True, False
        elif len(text) > len(self.cells):
            self.cells = text
        self.at, self.shown = len(text), None
        for cursor in self.cursors:
            cursor.anchor = None
        self.main = next((cursor for cursor in self.cursors if cursor.pos == self.at), None)
        if not self.main:
            self.main = Cursor(self.at)
            self.cursors.append(self.main)

    def hop(self, target: int):
        """The real cursor to a place. The way there is read: it only arrives where the text is what is known."""
        if self.shown:
            self.field.tap(LEFT)
            self.at, self.shown = self.shown[0], None
        if not self.field.jump(target - self.at, "".join(self.cells[min(self.at, target):max(self.at, target)])):
            raise Lost
        self.at = target

    def show(self, cursor: Cursor):
        """The selection of a cursor, for real."""
        self.hop(cursor.anchor)
        low, high = cursor.span()
        if not self.field.mark(cursor.pos - cursor.anchor, "".join(self.cells[low:high])):
            raise Lost
        self.at, self.shown = cursor.pos, (low, high)

    def grow(self, direction: int):
        """Reads on at one end of what is known."""
        if direction < 0:
            self.hop(0)
            more = cells(self.field.left(3))
            if not more:
                self.top = True
                return
            self.cells[:0] = more
            self.at += len(more)
            for cursor in self.cursors + self.marks:
                cursor.pos += len(more)
                if cursor.anchor is not None:
                    cursor.anchor += len(more)
        else:
            self.hop(len(self.cells))
            more = cells(self.field.right(3))
            if not more:
                self.bottom = True
                return
            self.cells += more

    def line(self, cursor: Cursor) -> tuple[int, int]:
        """Where the line of a cursor starts and ends."""
        for _ in range(24):
            if self.top or "\n" in self.cells[:cursor.pos]:
                break
            self.grow(-1)
        for _ in range(24):
            if self.bottom or "\n" in self.cells[cursor.pos:]:
                break
            self.grow(1)
        start = end = cursor.pos
        while start > 0 and self.cells[start - 1] != "\n":
            start -= 1
        while end < len(self.cells) and self.cells[end] != "\n":
            end += 1
        if (start == 0 and not self.top) or (end == len(self.cells) and not self.bottom):
            raise Lost
        return start, end

    def beside(self, pos: int) -> tuple[int, int]:
        mark = Cursor(pos)
        self.marks.append(mark)
        try:
            return self.line(mark)
        finally:
            self.marks.remove(mark)

    def add(self, direction: int) -> bool:
        """One more cursor, a line above the highest or below the lowest, in the column of the first."""
        column = self.main.pos - self.line(self.main)[0]
        start, end = self.line((max if direction > 0 else min)(self.cursors, key=lambda cursor: cursor.pos))
        if (end == len(self.cells)) if direction > 0 else (start == 0):
            return False
        first, last = self.beside(end + 1 if direction > 0 else start - 1)
        target = first + min(column, last - first)
        if any(cursor.pos == target for cursor in self.cursors):
            return False
        self.hop(target)
        self.cursors.append(Cursor(target))
        return True

    def reach(self, cursor: Cursor, unit: str, direction: int) -> int:
        """Where a cursor gets to by a letter, a word, to the end of its line or a line up or down."""
        if unit == "char":
            if direction < 0 and cursor.pos == 0 and not self.top:
                self.grow(-1)
            if direction > 0 and cursor.pos == len(self.cells) and not self.bottom:
                self.grow(1)
            return max(0, min(len(self.cells), cursor.pos + direction))
        start, end = self.line(cursor)
        pos = cursor.pos
        if unit == "line":
            return start if direction < 0 else end
        if unit == "row":
            if (start == 0) if direction < 0 else (end == len(self.cells)):
                return start if direction < 0 else end
            first, last = self.beside(start - 1 if direction < 0 else end + 1)
            start, _ = self.line(cursor)
            return first + min(cursor.pos - start, last - first)
        if pos == (start if direction < 0 else end):
            return self.reach(cursor, "char", direction)
        # a word: the blanks in front of it and what is of its kind
        at = (lambda: self.cells[pos - 1]) if direction < 0 else (lambda: self.cells[pos])
        stop = start if direction < 0 else end
        while pos != stop and at().isspace():
            pos += direction
        if pos != stop:
            kind = wordy(at())
            while pos != stop and not at().isspace() and wordy(at()) == kind:
                pos += direction
        return pos

    def walk(self, cursor: Cursor, unit: str, direction: int, extend: bool):
        if cursor.anchor is not None and not extend and unit == "char":
            low, high = cursor.span()
            cursor.pos, cursor.anchor = (low if direction < 0 else high), None
            return
        target = self.reach(cursor, unit, direction)
        if not extend:
            cursor.anchor = None
        elif cursor.anchor is None:
            cursor.anchor = cursor.pos
        cursor.pos = target
        if cursor.anchor == cursor.pos:
            cursor.anchor = None

    def splice(self, low: int, high: int, new: list[str], cursor: Cursor):
        self.cells[low:high] = new
        grown = len(new) - (high - low)
        for other in self.cursors + self.marks:
            if other is cursor:
                continue
            for name in ("pos", "anchor"):
                value = getattr(other, name)
                if value is not None and value > low:
                    setattr(other, name, value + grown if value >= high else low + len(new))
            if other.anchor == other.pos:
                other.anchor = None
        cursor.pos, cursor.anchor = low + len(new), None
        self.at, self.shown = cursor.pos, None

    def put(self, cursor: Cursor, new: list[str], press):
        """`press` types `new` at a cursor, over its selection."""
        low, high = cursor.span()
        if cursor.anchor is None:
            self.hop(cursor.pos)
        else:
            self.show(cursor)
        press()
        self.splice(low, high, new, cursor)

    def erase(self, cursor: Cursor, unit: str, direction: int):
        if cursor.anchor is None:
            target = self.reach(cursor, unit, direction)
            if target == cursor.pos:
                return
            if abs(target - cursor.pos) == 1:
                self.hop(cursor.pos)
                self.field.tap(BACKSPACE if direction < 0 else DELETE)
                low = min(target, cursor.pos)
                self.splice(low, low + 1, [], cursor)
                return
            cursor.anchor, cursor.pos = cursor.pos, target
        self.put(cursor, [], lambda: self.field.tap(BACKSPACE))

    def act(self, cursor: Cursor, step: tuple):
        kind = step[0]
        if kind == "move":
            self.walk(cursor, *step[1:])
        elif kind == "erase":
            self.erase(cursor, *step[1:])
        elif kind == "type":
            self.put(cursor, [step[1]], lambda: self.field.tap(step[2], step[3]))
        elif kind == "paste":
            self.put(cursor, cells(step[1]), lambda: self.field.paste(step[1]))

    def apply(self, steps: list[tuple]):
        """What was typed, at every cursor: the first one first, it is the one looked at."""
        others = [cursor for cursor in self.cursors if cursor is not self.main]
        below = sorted((cursor for cursor in others if cursor.pos > self.main.pos), key=lambda cursor: cursor.pos)
        above = sorted((cursor for cursor in others if cursor.pos <= self.main.pos), key=lambda cursor: -cursor.pos)
        for cursor in [self.main] + below + above:
            for step in steps:
                self.act(cursor, step)
        self.settle()

    def settle(self):
        """Cursors that met are one, selections that overlap as well; the real
        cursor is the first again, with its selection."""
        kept: list[Cursor] = []
        for cursor in sorted(self.cursors, key=lambda cursor: (cursor.span(), cursor is not self.main)):
            low, high = cursor.span()
            last = kept[-1].span() if kept else None
            if last and (low < last[1] or (low, high) == last):
                # the one in front takes in the other
                merged = kept[-1]
                forward = merged.anchor is None or merged.pos >= merged.anchor
                edges = (last[0], max(last[1], high))
                if edges[0] != edges[1]:
                    merged.anchor, merged.pos = edges if forward else edges[::-1]
                if cursor is self.main:
                    self.main = merged
            else:
                kept.append(cursor)
        self.cursors = kept
        if self.main.anchor is None:
            self.hop(self.main.pos)
        elif self.shown != self.main.span() or self.at != self.main.pos:
            self.show(self.main)


def step(code: int, char: str, mods: frozenset, paste: int, clipboard) -> tuple | None:
    """What a key does at every cursor; None for a key that is not typed at several."""
    ctrl, shift = "ctrl" in mods, "shift" in mods
    if "alt" in mods or "mod" in mods:
        return None
    if code in (LEFT, RIGHT):
        return ("move", "word" if ctrl else "char", -1 if code == LEFT else 1, shift)
    if code in (HOME, END) and not ctrl:
        return ("move", "line", -1 if code == HOME else 1, shift)
    if code in (UP, DOWN) and not ctrl:
        return ("move", "row", -1 if code == UP else 1, shift)
    if code in (BACKSPACE, DELETE):
        return ("erase", "word" if ctrl else "char", -1 if code == BACKSPACE else 1)
    if ctrl:
        text = clipboard.text() if code == paste and not shift else ""
        return ("paste", text) if text else None
    if len(char) == 1 and char.isprintable():
        return ("type", char, code, tuple(key for key, name in ((SHIFT, "shift"), (ALTGR, "altgr")) if name in mods))
    return None


# ── trying it ────────────────────────────────────────────────────────────────

class Paper:
    """A text field to try it on: it knows the keys a text field knows, wraps
    its lines after `width` letters and is its own clipboard. `sticky` is
    Firefox: where a line wraps the cursor stops twice."""

    def __init__(self, text: str, width: int = 0, sticky: bool = False):
        self.pos = len(cells(text.split("|")[0]))
        self.cells = cells(text.replace("|", ""))
        self.anchor: int | None = None
        self.width = width
        self.sticky = sticky
        # at a wrap: in front of the lower line, not behind the upper one
        self.late = True
        self.board = ""
        self.copied = False

    def rows(self) -> list[tuple[int, int]]:
        out, start = [], 0
        for end in [index for index, cell in enumerate(self.cells) if cell == "\n"] + [len(self.cells)]:
            edges = list(range(start, end, self.width))[1:] if self.width else []
            out += zip([start] + edges, edges + [end])
            start = end + 1
        return out

    def span(self) -> tuple[int, int]:
        return (min(self.pos, self.anchor), max(self.pos, self.anchor)) if self.anchor is not None else (self.pos, self.pos)

    def write(self, new: list[str]):
        low, high = self.span()
        self.cells[low:high] = new
        self.pos, self.anchor, self.late = low + len(new), None, True

    def tap(self, code: int, mods=(), times: int = 1):
        for _ in range(times):
            self.key(code, set(mods))

    def key(self, code: int, mods: set):
        shift, ctrl = SHIFT in mods, CTRL in mods
        if code in ARROWS:
            if self.anchor is not None and not shift and not ctrl and code in (LEFT, RIGHT):
                self.pos, self.anchor, self.late = self.span()[code == RIGHT], None, True
                return
            rows = self.rows()
            wraps = {start for (start, _), (_, end) in zip(rows[1:], rows) if start == end} if self.sticky else set()
            index = max(index for index, (start, _) in enumerate(rows) if start <= self.pos)
            if self.pos in wraps and not self.late:
                index -= 1
            start, end = rows[index]
            beside = rows[index + (-1 if code == UP else 1)] if 0 <= index + (-1 if code == UP else 1) < len(rows) else None
            late = True
            if code in (LEFT, RIGHT):
                step = -1 if code == LEFT else 1
                if self.pos in wraps and self.late == (code == LEFT):
                    # the other side of the wrap first
                    target, late = self.pos, code == RIGHT
                else:
                    target, late = max(0, min(len(self.cells), self.pos + step)), code == LEFT
            elif code in (HOME, END):
                target, late = ((0 if ctrl else start) if code == HOME else (len(self.cells) if ctrl else end)), code == HOME
            else:
                target = beside[0] + min(self.pos - start, beside[1] - beside[0]) if beside else (0 if code == UP else len(self.cells))
            if not shift:
                self.anchor = None
            elif self.anchor is None:
                self.anchor = self.pos
            self.pos, self.late = target, late
            if self.anchor == self.pos:
                self.anchor = None
        elif ctrl and code == 46:
            if self.anchor is not None:
                self.board, self.copied = "".join(self.cells[slice(*self.span())]), True
        elif ctrl and code == 47:
            self.write(cells(self.board))
        elif code in (BACKSPACE, DELETE):
            if self.anchor is None:
                self.anchor = max(0, self.pos - 1) if code == BACKSPACE else min(len(self.cells), self.pos + 1)
            self.write([])
        elif code >= 1000:
            self.write([chr(code - 1000)])

    # the clipboard of it

    def copy(self, press, sure: float = 0) -> str:
        self.copied = False
        press()
        return self.board if self.copied else ""

    def paste(self, text: str, press):
        self.board = text
        press()

    def text(self) -> str:
        return self.board

    def settle(self):
        pass

    def show(self, sheet: Sheet | None) -> str:
        marks = {self.pos: "|"}
        for cursor in sheet.cursors if sheet else []:
            marks.setdefault(cursor.pos, "¦")
        return "".join(marks.get(index, "") + cell for index, cell in enumerate(self.cells + [""]))


def attempt(text: str, steps: list[str], width: int = 0, sticky: bool = False) -> str:
    """What the steps leave in a text field that holds the text."""
    paper = Paper(text, width, sticky)
    field = Field(paper.tap, paper)
    keys = {"left": LEFT, "right": RIGHT, "up": UP, "down": DOWN, "home": HOME, "end": END, "backspace": BACKSPACE, "delete": DELETE}
    actions = {"move-up": "moveUp", "move-down": "moveDown", "copy-up": "copyUp", "copy-down": "copyDown"}
    sheet: Sheet | None = None

    def live() -> bool:
        return sheet is not None and len(sheet.cursors) > 1

    def press(code: int, char: str, mods: frozenset):
        nonlocal sheet
        todo = step(code, char, mods, 47, paper) if live() else None
        if todo:
            sheet.apply([todo])
            return
        if code not in ARROWS or live():
            sheet = None
        paper.tap(code, [{"shift": SHIFT, "ctrl": CTRL}[mod] for mod in mods])

    for name in steps:
        try:
            if name in actions:
                sheet = None
                lines(field, actions[name])
            elif name in ("cursor-up", "cursor-down"):
                if not live():
                    sheet = Sheet(field)
                    if not sheet.open():
                        sheet = None
                if sheet:
                    sheet.add(-1 if name == "cursor-up" else 1)
                    sheet.settle()
                    if not live():
                        sheet = None
            elif name == "pin":
                sheet = sheet or Sheet(field)
                sheet.pin()
            elif name.startswith("go:"):
                paper.pos, paper.anchor = int(name[3:]), None
            elif name == "esc":
                sheet = None
            elif name.startswith("type:"):
                for char in name[5:]:
                    press(1000 + ord(char), char, frozenset())
            else:
                *held, key = name.split("-")
                press(keys[key], "", frozenset(held))
        except Lost:
            sheet = None
    return paper.show(sheet if live() else None)


# ── the daemon ───────────────────────────────────────────────────────────────

def emit(**message):
    print(json.dumps(message, separators=(",", ":")), flush=True)


def named(keymap) -> dict[str, int]:
    """What niri calls a key (in small letters) → the key."""
    xkb = keymap.xkb
    xkb.xkb_state_key_get_one_sym.restype, xkb.xkb_state_key_get_one_sym.argtypes = ctypes.c_uint32, [ctypes.c_void_p, ctypes.c_uint32]
    xkb.xkb_keysym_get_name.restype, xkb.xkb_keysym_get_name.argtypes = ctypes.c_int, [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t]
    state, names = keymap.fresh(), dict(BUTTONS)
    for code in range(1, 256):
        buffer = ctypes.create_string_buffer(64)
        symbol = xkb.xkb_state_key_get_one_sym(state, code + 8)
        if symbol and xkb.xkb_keysym_get_name(symbol, buffer, len(buffer)) > 0:
            names.setdefault(buffer.value.decode().lower(), code)
    xkb.xkb_state_unref(state)
    return names


class Daemon:
    HELD = (("ctrl", b"Control"), ("alt", b"Mod1"), ("shift", b"Shift"), ("mod", b"Mod4"), ("altgr", b"Mod5"))

    def __init__(self):
        import evdev

        import autocorrect

        self.evdev = evdev
        self.selector = selectors.DefaultSelector()
        self.devices: dict[str, object] = {}
        # the keyboards that can be taken, and the ones that are
        self.keyboards: set[str] = set()
        self.grabs: set[str] = set()
        self.denied = 0
        self.scan()
        if not self.keyboards:
            emit(type="error", reason="permission" if self.denied else "keyboard")
            raise SystemExit(2)
        leds = [led for path in self.keyboards for led in self.devices[path].leds()]
        try:
            self.keymap = autocorrect.Keymap(autocorrect.configured_layout(), autocorrect.active_layout(),
                                             caps=evdev.ecodes.LED_CAPSL in leds, numlock=evdev.ecodes.LED_NUML in leds)
            self.names = named(self.keymap)
        except (OSError, ValueError, AttributeError):
            emit(type="error", reason="layout")
            raise SystemExit(2)
        try:
            # every key a keyboard has, and no button: a keyboard and nothing else
            codes = set(range(1, 256))
            for path in self.keyboards:
                codes |= {code for code in self.devices[path].capabilities().get(evdev.ecodes.EV_KEY, []) if 0x160 <= code < 0x220}
            self.keyboard = evdev.UInput({evdev.ecodes.EV_KEY: sorted(codes), evdev.ecodes.EV_LED: [0, 1, 2]}, name=NAME)
        except (OSError, evdev.UInputError):
            emit(type="error", reason="uinput")
            raise SystemExit(2)
        try:
            self.clipboard = Clipboard(lambda busy: emit(type="clipboard", busy=busy))
        except (OSError, KeyError):
            emit(type="error", reason="clipboard")
            raise SystemExit(2)
        keys = self.keymap.keys
        self.field = Field(self.tap, self.clipboard, keys.get("c", (46,))[0], keys.get("v", (47,))[0])
        self.active = False
        self.window = None
        self.binds: dict[tuple[frozenset, int], str] = {}
        # keys of ours that are down for the compositor
        self.out: set[int] = set()
        # keys that are down on a keyboard
        self.down: set[int] = set()
        self.sheet: Sheet | None = None
        self.steps: list[tuple] = []
        self.count = 0
        # the shortcut a button went down with, when a finger touched down
        self.pressed: dict[int, frozenset] = {}
        self.touched = 0.0
        self.said = b""
        self.queue: deque = deque()
        # since when a key is being answered: a daemon that hangs holds the keyboard
        self.busy = 0.0
        threading.Thread(target=self.watch, daemon=True).start()
        self.selector.register(sys.stdin, selectors.EVENT_READ, "control")
        self.selector.register(self.clipboard.sock, selectors.EVENT_READ, "clipboard")
        self.selector.register(self.keyboard.fd, selectors.EVENT_READ, "leds")
        emit(type="ready", keyboards=len(self.keyboards))

    def watch(self):
        while True:
            time.sleep(1)
            if self.busy and time.monotonic() - self.busy > 8:
                os._exit(3)

    # devices

    def scan(self):
        """Keyboards to take, and whatever clicks: a click moves the cursor."""
        ecodes = self.evdev.ecodes
        self.denied = 0
        for path in self.evdev.list_devices():
            if path in self.devices:
                continue
            try:
                device = self.evdev.InputDevice(path)
            except PermissionError:
                self.denied += 1
                continue
            except OSError:
                continue
            capabilities = device.capabilities()
            keys = capabilities.get(ecodes.EV_KEY, [])
            clicks = ecodes.BTN_LEFT in keys or TOUCH in keys
            types = ecodes.KEY_A in keys and not clicks and ecodes.EV_REL not in capabilities and ecodes.EV_ABS not in capabilities
            if device.name.startswith("pshell ") or not (types or clicks):
                device.close()
                continue
            self.devices[path] = device
            self.selector.register(device, selectors.EVENT_READ, path)
            if types:
                self.keyboards.add(path)

    def drop(self, path: str):
        device = self.devices.pop(path, None)
        self.keyboards.discard(path)
        if path in self.grabs:
            # its keys never come up
            self.grabs.discard(path)
            self.down.clear()
            self.release()
        if device:
            try:
                self.selector.unregister(device)
                device.close()
            except (OSError, KeyError, ValueError):
                pass

    def held(self) -> bool:
        for path in list(self.keyboards):
            try:
                if self.devices[path].active_keys():
                    return True
            except OSError:
                self.drop(path)
        return False

    def regrab(self):
        """Takes the keyboards while a shortcut may come, and only between two keys."""
        wanted = self.keyboards if self.active else set()
        if wanted == self.grabs or self.held():
            return
        for path in list(wanted ^ self.grabs):
            try:
                if path in wanted:
                    self.devices[path].grab()
                    self.grabs.add(path)
                else:
                    self.grabs.discard(path)
                    self.devices[path].ungrab()
            except OSError:
                # another one has it: its keys do not come by here
                self.keyboards.discard(path)
        if not self.grabs:
            self.close()
            self.release()

    def leds(self):
        """Caps Lock lights up on the keyboards that are taken."""
        try:
            events = list(self.keyboard.read())
        except OSError:
            return
        for event in events:
            if event.type != self.evdev.ecodes.EV_LED:
                continue
            for path in self.grabs:
                try:
                    self.devices[path].write(event.type, event.code, event.value)
                    self.devices[path].syn()
                except OSError:
                    pass

    # keys of its own

    def write(self, code: int, value: int):
        self.keyboard.write(self.evdev.ecodes.EV_KEY, code, value)
        self.keyboard.syn()

    def tap(self, code: int, mods=(), times: int = 1):
        if not times:
            return
        for key in mods:
            self.write(key, 1)
        for _ in range(times):
            self.write(code, 1)
            self.write(code, 0)
            time.sleep(STROKE)
        for key in reversed(mods):
            self.write(key, 0)

    def release(self):
        """Lets go of every key for the compositor: what is typed next is typed plain."""
        if (ALT in self.out or 125 in self.out or 126 in self.out) and not self.out & {CTRL, 97}:
            # Alt that comes up with no key in between opens the menu of a window
            self.tap(CTRL)
        for code in list(self.out):
            self.write(code, 0)
        self.out.clear()

    def hold(self):
        """Presses again what is held on a keyboard."""
        for code in self.down & MODIFIERS - self.out:
            self.write(code, 1)
            self.out.add(code)

    def mods(self) -> frozenset:
        return frozenset(name for name, mod in self.HELD if self.keymap.held(mod))

    # what the shell says

    def control(self) -> bool:
        data = os.read(sys.stdin.fileno(), 4096)
        if not data:
            return False
        self.said += data
        *said, self.said = self.said.split(b"\n")
        for line in said:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if not isinstance(message, dict):
                continue
            self.active = message.get("active") is True
            if isinstance(message.get("binds"), dict):
                self.binds = {}
                for action, key in message["binds"].items():
                    bind = self.bind(str(key))
                    if action in ACTIONS and bind:
                        self.binds[bind] = action
            if message.get("window") != self.window or not self.active:
                # another window, another text
                self.window = message.get("window")
                self.flush()
                self.close()
                self.clipboard.patience, self.field.slips = PATIENCE[0], False
        return True

    def bind(self, key: str) -> tuple[frozenset, int] | None:
        *held, name = key.split("+")
        mods = frozenset({"control": "ctrl", "super": "mod", "win": "mod"}.get(mod.lower(), mod.lower()) for mod in held)
        code = self.names.get(ALIASES.get(name.lower(), name.lower()))
        return (mods, code) if code and mods <= {"ctrl", "alt", "shift", "mod"} else None

    def tell(self):
        count = len(self.sheet.cursors) if self.sheet else 0
        if count != self.count:
            self.count = count
            emit(type="cursors", count=count)

    # cursors

    def live(self) -> bool:
        return self.sheet is not None and len(self.sheet.cursors) > 1

    def close(self):
        self.sheet = None
        self.steps = []
        self.tell()

    def lost(self):
        """The text is another one than was read: back to where the cursor was, and no more of it."""
        try:
            with self.clipboard.borrow():
                if self.sheet and self.sheet.main:
                    self.sheet.hop(self.sheet.main.pos)
        except Lost:
            pass
        self.close()

    def flush(self):
        """Types what was typed since at every cursor."""
        if not self.steps or not self.sheet:
            self.steps = []
            return
        steps, self.steps = self.steps, []
        try:
            with self.clipboard.borrow():
                self.sheet.apply(steps)
        except Lost:
            self.lost()
        if not self.live():
            self.close()
        self.tell()

    def run(self, action: str, code: int | None):
        """A shortcut was pressed. `code` is its key, which the window has not seen."""
        self.flush()
        self.release()
        passed = False
        try:
            with self.clipboard.borrow():
                if action == "addCursor":
                    self.sheet = self.sheet or Sheet(self.field)
                    self.sheet.pin()
                elif action in ("cursorUp", "cursorDown"):
                    if not self.live():
                        self.sheet = Sheet(self.field)
                        if not self.sheet.open():
                            self.sheet, passed = None, True
                    if self.sheet:
                        self.sheet.add(-1 if action == "cursorUp" else 1)
                        self.sheet.settle()
                        if not self.live():
                            self.sheet = None
                else:
                    self.sheet = None
                    passed = lines(self.field, action) is None
        except Lost:
            self.lost()
        if passed and code is not None:
            # no text field: the keys are the window's
            self.hold()
            self.tap(code)
        self.tell()

    # keys

    def key(self, code: int, value: int, char: str, stamp: float):
        if value == 0:
            if code in self.out:
                self.write(code, 0)
                self.out.discard(code)
            return
        if code in MODIFIERS:
            if value == 1 and not self.live():
                self.write(code, 1)
                self.out.add(code)
            return
        if code == ESCAPE and self.down >= {SHIFT, 54}:
            emit(type="panic")
            raise SystemExit(0)
        mods = self.mods()
        action = self.binds.get((mods - {"altgr"}, code)) if self.active else None
        if action:
            if value == 1 or time.time() - stamp < STALE:
                self.run(action, code)
            return
        if self.live():
            if code == ESCAPE and not mods:
                self.flush()
                self.close()
                return
            todo = step(code, char, mods, self.field.v, self.clipboard)
            if todo:
                self.steps.append(todo)
                return
            self.flush()
            self.close()
        elif self.sheet and code not in ARROWS:
            # one cursor that was put down, and the text changes
            self.close()
        if value == 1:
            self.hold()
            self.write(code, 1)
            self.out.add(code)

    def click(self, code: int, mods: frozenset):
        if not self.grabs or not self.active:
            return
        action = self.binds.get((mods - {"altgr"}, code))
        if action:
            # the window puts its cursor there first
            time.sleep(CLICK)
            self.run(action, None)
        elif self.live():
            self.flush()
            self.close()

    def handle(self, path: str, event):
        code, value = event.code, event.value
        if code >= 0x100:
            if code == TOUCH:
                # a tap is a click
                if value == 1:
                    self.touched = time.monotonic()
                elif value == 0 and time.monotonic() - self.touched < 0.25:
                    self.click(BUTTONS["mouseleft"], self.mods())
            elif code in BUTTONS.values():
                if value == 1:
                    self.pressed[code] = self.mods()
                elif value == 0 and code in self.pressed:
                    self.click(code, self.pressed.pop(code))
            return
        if path not in self.keyboards:
            return
        if value == 1:
            self.down.add(code)
        elif value == 0:
            self.down.discard(code)
        char = self.keymap.char(self.keymap.state, code) if value == 2 else self.keymap.press(code, value == 1)
        if path in self.grabs:
            self.key(code, value, char, event.timestamp())

    def loop(self):
        rescan = time.monotonic() + 5
        while True:
            self.regrab()
            for key, _ in self.selector.select(max(0.0, rescan - time.monotonic())):
                if key.data == "control":
                    if not self.control():
                        return
                elif key.data == "clipboard":
                    self.clipboard.read()
                    self.clipboard.pump()
                elif key.data == "leds":
                    self.leds()
                else:
                    try:
                        self.queue += [(key.data, event) for event in self.devices[key.data].read() if event.type == self.evdev.ecodes.EV_KEY]
                    except (OSError, KeyError):
                        self.drop(key.data)
            self.busy = time.monotonic()
            while self.queue:
                self.handle(*self.queue.popleft())
            self.flush()
            self.busy = 0.0
            if time.monotonic() >= rescan:
                self.scan()
                rescan = time.monotonic() + 5


def main() -> int:
    if len(sys.argv) > 2 and sys.argv[1] == "try":
        arguments = sys.argv[2:]
        width = sticky = 0
        while arguments[0] in ("--width", "--firefox"):
            if arguments[0] == "--firefox":
                sticky, arguments = True, arguments[1:]
            else:
                width, arguments = int(arguments[1]), arguments[2:]
        print(attempt(arguments[0].replace("\\n", "\n"), arguments[1:], width, sticky))
        return 0
    if len(sys.argv) > 1:
        print(__doc__.strip())
        return 0 if sys.argv[1] in ("-h", "--help") else 1
    daemon = Daemon()
    try:
        daemon.loop()
    except KeyboardInterrupt:
        pass
    finally:
        daemon.clipboard.leave()
    return 0


if __name__ == "__main__":
    sys.exit(main())
