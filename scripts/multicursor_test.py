#!/usr/bin/python3
"""Multicursor against a text field of its own: no window, no keyboard taken.

  scripts/multicursor_test.py            every test
  scripts/multicursor_test.py -k Keys    some

The text field is multicursor.Paper: it knows the keys a text field knows,
wraps its lines and, as Firefox does, can stop twice where a line wraps. The
daemon gets the keys of a keyboard that does not exist and what it would hand
to the compositor goes into the paper.
"""

import contextlib
import random
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import autocorrect  # noqa: E402
import multicursor as m  # noqa: E402

LINES = ["foo", "bar", "a", "", "hello world", "x_y z", "  indent", "änd ö", "👍🏽 ok", "ét"]


class Random(unittest.TestCase):
    """Steps at random: the paper has to hold what a straight implementation leaves."""

    def paper(self, dice):
        text = "\n".join(dice.choice(LINES) for _ in range(dice.randint(1, 7)))
        cells = m.cells(text)
        pos = dice.randint(0, len(cells))
        paper = m.Paper("".join(cells[:pos]) + "|" + "".join(cells[pos:]), dice.choice([0, 0, 3, 5, 8]), dice.random() < 0.5)
        return text, cells, pos, paper

    def test_lines(self):
        for seed in range(3000):
            dice = random.Random(seed)
            text, cells, pos, paper = self.paper(dice)
            action = dice.choice(m.ACTIONS[:4])
            rows = text.split("\n")
            row = "".join(cells[:pos]).count("\n")
            start = lambda: len(m.cells("\n".join(rows[:row]))) + (1 if row else 0)
            column = pos - start()
            if action == "moveUp" and row > 0:
                rows[row - 1], rows[row] = rows[row], rows[row - 1]
                row -= 1
            elif action == "moveDown" and row < len(rows) - 1:
                rows[row + 1], rows[row] = rows[row], rows[row + 1]
                row += 1
            elif action in ("copyUp", "copyDown"):
                rows.insert(row, rows[row])
                row += action == "copyDown"
            done = m.lines(m.Field(paper.tap, paper), action)
            if not text:
                self.assertIsNone(done, seed)
                continue
            self.assertEqual("".join(paper.cells), "\n".join(rows), (seed, action))
            self.assertEqual((paper.pos, paper.anchor), (start() + column, None), (seed, action))

    def test_cursors(self):
        for seed in range(3000):
            dice = random.Random(seed)
            _, _, _, paper = self.paper(dice)
            sheet = m.Sheet(m.Field(paper.tap, paper))
            if not sheet.open():
                continue
            for _ in range(dice.randint(1, 4)):
                sheet.add(dice.choice([-1, 1]))
                sheet.settle()
            if dice.random() < 0.3:
                # a click somewhere, and a cursor there
                paper.pos, paper.anchor = dice.randint(0, len(paper.cells)), None
                sheet.pin()
            for _ in range(dice.randint(1, 25)):
                if len(sheet.cursors) < 2:
                    break
                kind = dice.random()
                mods = frozenset(mod for mod in ("shift", "ctrl") if dice.random() < 0.25)
                if kind < 0.4:
                    char = dice.choice("abc _.;é")
                    todo = m.step(1000 + ord(char), char, frozenset(), 47, paper)
                elif kind < 0.9:
                    todo = m.step(dice.choice([m.LEFT, m.RIGHT, m.HOME, m.END, m.UP, m.DOWN, m.BACKSPACE, m.DELETE]), "", mods, 47, paper)
                else:
                    paper.board = dice.choice(["P", "two words", "l1\nl2"])
                    todo = m.step(47, "v", frozenset({"ctrl"}), 47, paper)
                if not todo:
                    continue
                sheet.apply([todo])
                # the sheet is a piece of the paper, and the real cursor is its first one
                offset = paper.pos - sheet.at
                self.assertEqual(paper.cells[offset:offset + len(sheet.cells)], sheet.cells, seed)
                self.assertEqual(paper.span() if paper.anchor is not None else None,
                                 tuple(edge + offset for edge in sheet.main.span()) if sheet.main.anchor is not None else None, seed)
                self.assertTrue(not sheet.top or offset == 0, seed)
                self.assertTrue(not sheet.bottom or offset + len(sheet.cells) == len(paper.cells), seed)


class Tried(unittest.TestCase):
    """`multicursor.py try`, as the steps are written there."""

    def test_steps(self):
        for text, steps, left in (
            ("one\ntw|o\nthree", "move-up", "tw|o\none\nthree"),
            ("one\ntw|o\nthree", "move-down move-down", "one\nthree\ntw|o"),
            ("one\ntw|o", "copy-up", "one\ntw|o\ntwo"),
            ("a\n|", "copy-down", "a\n\n|"),
            ("alpha\nbe|ta\ngamma", "cursor-down cursor-up type:x", "alx¦pha\nbex|ta\ngax¦mma"),
            ("a\nlong|er\nb", "cursor-up cursor-down home type:-", "-¦a\n-|longer\n-¦b"),
            ("foo bar\nfoo| bar", "cursor-up shift-home backspace type:baz", "baz¦ bar\nbaz| bar"),
            ("x|\ny", "cursor-down type:1 esc type:2", "x12|\ny1"),
            ("the quick brown fox|", "go:4 pin go:10 pin type:*", "the *¦quick *|brown fox"),
            ("abc|", "pin type:x go:1 pin type:y", "ay|bcx"),
        ):
            for width, sticky in ((0, False), (3, False), (4, True)):
                self.assertEqual(m.attempt(text, steps.split(), width, sticky), left, (text, steps, width, sticky))


class Event:
    def __init__(self, code, value):
        self.code, self.value = code, value

    def timestamp(self):
        return time.time()


class Board:
    """The paper as the daemon's clipboard."""

    def __init__(self, paper):
        self.paper, self.patience = paper, 0

    def copy(self, press, sure=0):
        return self.paper.copy(press, sure)

    def paste(self, text, press):
        self.paper.paste(text, press)

    def text(self):
        return self.paper.board

    @contextlib.contextmanager
    def borrow(self):
        held = self.paper.board
        try:
            yield
        finally:
            self.paper.board = held


KEYMAP = autocorrect.Keymap({"layout": "de"}, 0)
NAMES = m.named(KEYMAP)
ALT, SHIFT, RIGHT_SHIFT, CTRL, BUTTON = 56, 42, 54, 29, 0x110
UP, DOWN, LEFT, TAB, ESCAPE, BACKSPACE = (NAMES[name] for name in ("up", "down", "left", "tab", "escape", "backspace"))


class Bench(m.Daemon):
    """The daemon without devices. `feed` is the keyboard; `log` what the
    compositor gets, `leaks` the keys that reach it with Alt or Super held."""

    def __init__(self, text, active=True):
        self.keymap = autocorrect.Keymap({"layout": "de"}, 0)
        self.names = NAMES
        self.paper = m.Paper(text)
        self.clipboard = Board(self.paper)
        self.field = m.Field(self.tap, self.clipboard)
        self.active, self.window = active, 1
        self.binds = {self.bind(key): action for action, key in (
            ("moveUp", "Alt+Up"), ("moveDown", "Alt+Down"), ("cursorUp", "Alt+Shift+Up"), ("cursorDown", "Alt+Shift+Down"), ("addCursor", "Alt+MouseLeft"))}
        self.out, self.down = set(), set()
        self.sheet, self.steps, self.count = None, [], 0
        self.pressed, self.touched = {}, 0.0
        self.keyboards = self.grabs = {"keyboard"}
        self.devices = {}
        self.mods_down, self.log, self.leaks = set(), [], []

    def write(self, code, value):
        self.log.append((code, value))
        if code in m.MODIFIERS:
            (self.mods_down.add if value else self.mods_down.discard)(code)
        elif value and self.mods_down & {56, 125, 126}:
            self.leaks.append(code)
        elif value:
            mods = {mod for mod, keys in ((m.CTRL, {29, 97}), (m.SHIFT, {42, 54})) if self.mods_down & keys}
            char = self.keymap.faces.get((code, m.SHIFT in mods))
            if code in m.ARROWS or code in (m.BACKSPACE, m.DELETE) or m.CTRL in mods:
                self.paper.key(code, mods)
            elif char:
                self.paper.key(1000 + ord(char), set())

    def feed(self, *events, mouse=False):
        for code, value in events:
            self.handle("mouse" if mouse else "keyboard", Event(code, value))
        self.flush()

    def press(self, code, *held):
        self.feed(*[(mod, 1) for mod in held], (code, 1), (code, 0), *[(mod, 0) for mod in reversed(held)])

    def type(self, text):
        for char in text:
            code, shift, _ = self.keymap.keys[char]
            self.press(code, *([SHIFT] if shift else []))

    def point(self, at):
        self.paper.pos = at
        self.feed((BUTTON, 1), (BUTTON, 0), mouse=True)

    def text(self):
        return self.paper.show(self.sheet if self.live() else None)


class Keys(unittest.TestCase):
    def setUp(self):
        self.said = []
        emit, m.emit = m.emit, lambda **message: self.said.append(message)
        self.addCleanup(setattr, m, "emit", emit)

    def clean(self, bench):
        self.assertEqual((bench.mods_down, bench.out), (set(), set()))

    def test_typing_passes(self):
        bench = Bench("one|\ntwo")
        bench.type("ab A")
        self.assertEqual(bench.text(), "oneab A|\ntwo")
        self.clean(bench)

    def test_shortcut(self):
        bench = Bench("one\ntw|o\nthree")
        bench.press(UP, ALT)
        self.assertEqual(bench.text(), "tw|o\none\nthree")
        # Alt comes up before anything is typed, behind a Ctrl that keeps the menu of the window shut
        self.assertEqual(bench.log[:4], [(ALT, 1), (CTRL, 1), (CTRL, 0), (ALT, 0)])
        self.assertEqual(bench.leaks, [])
        self.clean(bench)

    def test_alt_held(self):
        bench = Bench("one|\ntwo\nthree")
        bench.feed((ALT, 1), (DOWN, 1), (DOWN, 0), (DOWN, 1), (DOWN, 0))
        self.assertEqual(bench.text(), "two\nthree\none|")
        seen = len(bench.log)
        bench.feed((TAB, 1), (TAB, 0), (ALT, 0))
        # a key that is no shortcut gets its Alt back
        self.assertEqual(bench.log[seen:], [(ALT, 1), (TAB, 1), (TAB, 0), (ALT, 0)])
        self.clean(bench)

    def test_cursors(self):
        bench = Bench("alpha\nbe|ta\ngamma")
        bench.feed((ALT, 1), (SHIFT, 1), (DOWN, 1), (DOWN, 0), (UP, 1), (UP, 0), (SHIFT, 0), (ALT, 0))
        self.assertEqual(self.said[-1], {"type": "cursors", "count": 3})
        bench.type("xA")
        bench.press(BACKSPACE)
        bench.press(LEFT)
        bench.type("b")
        self.assertEqual(bench.text(), "alb¦xpha\nbeb|xta\ngab¦xmma")
        seen = len(bench.log)
        bench.press(ESCAPE)
        self.assertEqual(bench.log[seen:], [])
        bench.type("z")
        self.assertEqual(bench.text(), "albxpha\nbebz|xta\ngabxmma")
        self.assertEqual(self.said[-1], {"type": "cursors", "count": 0})
        self.clean(bench)

    def test_held_keys(self):
        bench = Bench("a|\nb")
        bench.press(DOWN, ALT, SHIFT)
        bench.feed((SHIFT, 1), (NAMES["x"], 1), (NAMES["x"], 2), (NAMES["x"], 2), (NAMES["x"], 0), (SHIFT, 0))
        self.assertEqual(bench.text(), "aXXX|\nbXXX¦")
        self.clean(bench)

    def test_other_shortcut_ends_it(self):
        bench = Bench("a|\nb")
        bench.press(DOWN, ALT, SHIFT)
        bench.type("x")
        seen = len(bench.log)
        bench.press(NAMES["s"], CTRL)
        self.assertEqual(bench.log[seen:], [(CTRL, 1), (NAMES["s"], 1), (NAMES["s"], 0), (CTRL, 0)])
        self.assertEqual((bench.text(), bench.sheet), ("ax|\nbx", None))

    def test_paste(self):
        bench = Bench("a|\nb")
        bench.paper.board = "PASTE"
        bench.press(DOWN, ALT, SHIFT)
        bench.press(NAMES["v"], CTRL)
        self.assertEqual((bench.text(), bench.paper.board), ("aPASTE|\nbPASTE¦", "PASTE"))

    def test_clicks(self):
        bench = Bench("the quick brown fox|")
        bench.feed((ALT, 1))
        bench.point(4)
        self.assertEqual(self.said[-1], {"type": "cursors", "count": 1})
        bench.point(10)
        bench.feed((ALT, 0))
        bench.type("*")
        self.assertEqual(bench.text(), "the *¦quick *|brown fox")
        self.assertEqual(bench.leaks, [])
        # a click without the keys ends it
        bench.point(0)
        bench.type("-")
        self.assertEqual(bench.text(), "-|the *quick *brown fox")

    def test_one_cursor_put_down(self):
        bench = Bench("abc|")
        bench.feed((ALT, 1))
        bench.point(1)
        bench.feed((ALT, 0))
        bench.press(NAMES["right"])
        self.assertIsNotNone(bench.sheet)
        bench.type("x")
        self.assertEqual((bench.sheet, bench.text()), (None, "abx|c"))

    def test_not_active(self):
        bench = Bench("one\ntw|o", active=False)
        bench.press(UP, ALT)
        self.assertEqual((bench.text(), bench.log), ("one\ntw|o", [(ALT, 1), (UP, 1), (UP, 0), (ALT, 0)]))

    def test_no_text(self):
        bench = Bench("|")
        bench.press(UP, ALT)
        # the keys are the window's after all
        self.assertEqual(bench.leaks, [UP])
        self.clean(bench)

    def test_panic(self):
        bench = Bench("a|")
        with self.assertRaises(SystemExit):
            bench.feed((SHIFT, 1), (RIGHT_SHIFT, 1), (ESCAPE, 1))
        self.assertEqual(self.said[-1], {"type": "panic"})


if __name__ == "__main__":
    unittest.main()
