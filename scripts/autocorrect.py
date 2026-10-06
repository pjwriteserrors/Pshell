#!/usr/bin/env python3
"""Corrects what is typed, the way a phone keyboard does, in German and English.

  autocorrect.py               the daemon, run by core/services/Autocorrect.qml
  autocorrect.py try "text"    what typing the text would leave on the screen
                               (\\n is Enter, \\b is Backspace)

The daemon reads the keyboards (evdev), follows the text in front of the
cursor and, when a word is ended by a space, takes back what was wrong and
types it right through a keyboard of its own (uinput):

  typos and spelling       teh → the, vieleicht → vielleicht, strasse → Straße
  capitals                 the start of a sentence, German nouns, I, HAllo
  punctuation              two spaces end the sentence, no space before , . ! ?,
                           the comma in front of dass, weil, ob, wenn …

Backspace right after a correction brings back what was typed, and a word
whose spelling was brought back is left alone from then on (autocorrect.json
in the shell's state). Nothing else that is typed is ever stored or sent
anywhere.

A correction can be animated: other letters stand in place of the word for a
moment (scramble, decode), or it is taken back and typed letter by letter
(typewriter). It is all typed, a text field shows nothing else, and what is
typed on in the meantime ends the animation and is put behind the word again.

It cannot see the text field, only the keys. So it only touches the word that
was just typed, forgets everything on a click, a shortcut or a cursor key, and
never changes a word that is not followed by a space (a password, a command).
The shell tells it on stdin where typing may be corrected and how:
{"active": bool, "animations": [name, …]} (one of several is picked each time).
"""

from __future__ import annotations

import ctypes
import ctypes.util
import json
import math
import os
import random
import re
import selectors
import subprocess
import sys
import threading
import time
import urllib.request
from collections import deque
from pathlib import Path

NAME = "pshell autocorrect"
LANGUAGES = {"de": ("de_DE", "de_AT", "de_CH"), "en": ("en_US", "en_GB")}
# how often words are used (a word and its count per line), to tell the likely word from the close one
USAGE = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/{language}/{language}_50k.txt"
# seconds between two typed keys of a correction; none, so that no key of the
# real keyboard gets in between
KEY_DELAY = 0.0
# the animations of a correction, and the seconds one picture of each stands
ANIMATIONS = {"scramble": 0.04, "decode": 0.035, "typewriter": 0.03}
# pictures of an animation at most: it is over before the next word is
PICTURES = 8
# how much of the text in front of the cursor is followed
MEMORY = 240

# typed on purpose: never a typo
KEEP = set("""
ok okay lol btw thx omg wtf imo imho afaik asap fyi brb idk irl tbh np pls plz ty
mfg lg vg zb bzw usw evtl ggf vllt vlt bzgl inkl ca etc eig iwie iwas ka kp hdl
gehts gibts wars wirds ists hats gings stimmts kanns machts hab habs wär wärs
nen nem ner ne nix nö nee jo joa jap jup yep yup nope hi hey hm hmm hä haha hehe
moin servus tschau ciao sry sorry yeah yay wow oha naja achso aha ah oh uff puh
qwertz qwerty asdf wasd
api apis app apps async auth backend frontend cli config repo repos dev prod sdk ui ux
json yaml toml html css sql regex http https ssh url urls localhost admin sudo
docker nginx postgres mysql redis kubectl kubernetes golang typescript javascript
github gitlab linux wayland niri quickshell
cpu gpu ssd hdd usb pdf vpn dns ram rom lan wlan wifi kfz lkw pkw tv pc
""".split())

CONTRACTIONS = {
    "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "isnt": "isn't", "arent": "aren't",
    "wasnt": "wasn't", "werent": "weren't", "havent": "haven't", "hasnt": "hasn't", "hadnt": "hadn't",
    "wouldnt": "wouldn't", "couldnt": "couldn't", "shouldnt": "shouldn't", "cant": "can't",
    "thats": "that's", "whats": "what's", "theres": "there's", "heres": "here's",
    "youre": "you're", "theyre": "they're", "youve": "you've", "theyve": "they've", "weve": "we've",
    "alot": "a lot", "ive": "I've", "im": "I'm", "ill": "I'll", "id": "I'd", "youll": "you'll", "theyll": "they'll",
}
# those of them that are words of their own: only inside English text
CONTRACTIONS_ENGLISH_ONLY = {"cant", "im", "ill", "id", "ive", "weve"}

# a noun follows these
DETERMINERS = set("""
der die das den dem des ein eine einen einem einer eines kein keine keinen keinem keiner keines
mein meine meinen meinem meiner meines dein deine deinen deinem deiner deines
sein seine seinen seinem seiner seines ihr ihre ihren ihrem ihrer ihres
unser unsere unseren unserem unserer eure euren eurem eurer
dieser diese dieses diesem diesen jeder jede jedes jedem jeden welche welcher welches welchen
im am zum zur vom beim ins ans aufs fürs ums viel viele vielen wenig wenige einige mehrere alle allen beide
""".split())
# and nothing but a noun these: ein treffen, beim essen
SINGULAR = set("ein einem einen eines kein keinem keinen mein meinem meinen dein deinem deinen unserem dem im am zum beim vom ins".split())
# a verb follows these
SUBJECTS = {"ich", "du", "er", "sie", "es", "wir", "man", "zu", "nicht"}
# a subordinate clause starts with these: a comma in front
COMMA = set("""
dass weil obwohl ob sodass falls wenn bevor nachdem sobald solange obgleich indem wohingegen
wieso weshalb weswegen warum
""".split())
# unless one of these stands in front: the comma belongs before it (nur weil,
# als ob, kurz bevor) or nowhere (und dass)
NO_COMMA = COMMA | set("""
und oder aber sondern denn doch nur auch als so erst selbst sogar besonders insbesondere außer ausser
sowie bzw kurz lange noch gleich immer allem je gerade eben schon zumal zwar ohne statt anstatt wie
einfach bloß allein eher genau ja na
""".split())
# rows of the keyboard: a finger lands on the key next to the one it was meant for
ROWS = ("qwertzuiopü", "asdfghjklöä", "yxcvbnm")

# a full stop after these does not end a sentence
ABBREVIATIONS = set("""
z.b d.h u.a o.ä u.ä z.t i.d.r s.o s.u v.a bzw ca evtl ggf inkl nr str tel vgl bzgl
e.g i.e vs dr mr mrs ms prof st no approx
""".split())

OPENING = "([{\"'„“«‚‘"
CLOSING = ".,!?;:)]}\"'“”»’…"
WORD = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)*")
TOKEN = re.compile(rf"([{re.escape(OPENING)}]*)(.*?)([{re.escape(CLOSING)}]*)")


def state_file() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "pshell" / "autocorrect.json"


# ── dictionaries ─────────────────────────────────────────────────────────────

def dictionary_dirs() -> list[Path]:
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return [data / "hunspell", Path("/usr/share/hunspell"), Path("/usr/share/myspell/dicts"), Path("/usr/share/myspell")]


def dictionary_path(language: str) -> Path | None:
    """The .aff of the language's dictionary, wherever hunspell dictionaries are."""
    for directory in dictionary_dirs():
        for name in LANGUAGES[language]:
            aff = directory / f"{name}.aff"
            if aff.exists() and aff.with_suffix(".dic").exists():
                return aff
    return None


class Dictionary:
    """A hunspell dictionary."""

    lib = None

    def __init__(self, aff: Path):
        if Dictionary.lib is None:
            lib = ctypes.CDLL(ctypes.util.find_library("hunspell") or "libhunspell-1.7.so.0")
            lib.Hunspell_create.restype = ctypes.c_void_p
            lib.Hunspell_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
            lib.Hunspell_get_dic_encoding.restype = ctypes.c_char_p
            lib.Hunspell_get_dic_encoding.argtypes = [ctypes.c_void_p]
            lib.Hunspell_spell.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
            lib.Hunspell_suggest.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p)), ctypes.c_char_p]
            lib.Hunspell_free_list.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p)), ctypes.c_int]
            Dictionary.lib = lib
        self.handle = Dictionary.lib.Hunspell_create(str(aff).encode(), str(aff.with_suffix(".dic")).encode())
        self.encoding = Dictionary.lib.Hunspell_get_dic_encoding(self.handle).decode()
        self.known: dict[str, bool] = {}

    def spell(self, word: str) -> bool:
        if word not in self.known:
            try:
                self.known[word] = bool(Dictionary.lib.Hunspell_spell(self.handle, word.encode(self.encoding)))
            except UnicodeEncodeError:
                self.known[word] = False
        return self.known[word]

    def suggest(self, word: str) -> list[str]:
        try:
            raw = word.encode(self.encoding)
        except UnicodeEncodeError:
            return []
        found = ctypes.POINTER(ctypes.c_char_p)()
        count = Dictionary.lib.Hunspell_suggest(self.handle, ctypes.byref(found), raw)
        words = [found[i].decode(self.encoding, "replace") for i in range(count)]
        Dictionary.lib.Hunspell_free_list(self.handle, ctypes.byref(found), count)
        return words


def dictionaries() -> dict[str, Dictionary]:
    found = {}
    for language in LANGUAGES:
        aff = dictionary_path(language)
        if aff:
            found[language] = Dictionary(aff)
    return found


def usage_file(language: str) -> Path:
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "autocorrect" / f"{language}.txt"


def load_usage(usage: dict[str, dict[str, int]], fetch: bool = False):
    """Fills in how often words are used; fetches the lists that are missing."""
    for language in LANGUAGES:
        file = usage_file(language)
        if fetch and not file.exists():
            try:
                with urllib.request.urlopen(USAGE.format(language=language), timeout=30) as answer:
                    text = answer.read()
                file.parent.mkdir(parents=True, exist_ok=True)
                file.with_suffix(".part").write_bytes(text)
                file.with_suffix(".part").replace(file)
            except (OSError, ValueError):
                continue
        words = {}
        try:
            for line in file.read_text(encoding="utf-8", errors="replace").splitlines():
                word, _, count = line.partition(" ")
                if count.isdigit():
                    words[word] = int(count)
        except OSError:
            continue
        usage[language] = words


# ── words ────────────────────────────────────────────────────────────────────

def distance(a: str, b: str) -> int:
    """Edits between two words; two neighbouring letters swapped count as one."""
    previous2: list[int] = []
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        row = [i]
        for j, cb in enumerate(b, 1):
            cost = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (ca != cb))
            if i > 1 and j > 1 and ca == b[j - 2] and a[i - 2] == cb:
                cost = min(cost, previous2[j - 2] + 1)
            row.append(cost)
        previous2, previous = previous, row
    return previous[-1]


def swapped(a: str, b: str) -> bool:
    """b is a with two neighbouring letters swapped."""
    if len(a) != len(b) or a == b:
        return False
    differ = [i for i in range(len(a)) if a[i] != b[i]]
    return len(differ) == 2 and differ[1] == differ[0] + 1 and a[differ[0]] == b[differ[1]] and a[differ[1]] == b[differ[0]]


def beside(a: str, b: str) -> bool:
    """Two keys next to each other."""
    for index, row in enumerate(ROWS):
        at = row.find(a)
        if at < 0:
            continue
        near = row[max(0, at - 1):at + 2]
        for other, shift in ((index - 1, 1), (index + 1, 0)):
            if 0 <= other < len(ROWS):
                near += ROWS[other][max(0, at - 1 + shift):at + 1 + shift]
        return b in near
    return False


def slipped(a: str, b: str) -> bool:
    """b is a with one letter missing, one too many, or the key beside the right one."""
    if len(a) != len(b):
        return abs(len(a) - len(b)) == 1
    differ = [i for i in range(len(a)) if a[i] != b[i]]
    return len(differ) == 1 and beside(a[differ[0]], b[differ[0]])


def nouns() -> dict[str, int]:
    """Words written small and with a capital: how often (in %) they are the noun."""
    found = {}
    try:
        for line in Path(__file__).with_name("autocorrect_nouns.txt").read_text(encoding="utf-8").splitlines():
            word, _, share = line.partition(" ")
            if share.isdigit():
                found[word] = int(share)
    except OSError:
        pass
    return found


def capitalised(word: str) -> str:
    return word[:1].upper() + word[1:]


def spellings(word: str) -> list[str]:
    """What the word may be with the ß and the umlauts it was typed without."""
    found = []
    for pattern, letter in (("ss", "ß"), ("ae", "ä"), ("oe", "ö"), ("ue", "ü")):
        for known in [word] + found:
            start = known.find(pattern)
            while start >= 0:
                variant = known[:start] + letter + known[start + len(pattern):]
                if variant not in found:
                    found.append(variant)
                start = known.find(pattern, start + 1)
            if len(found) > 12:
                return found
    for plain, letter in (("a", "ä"), ("o", "ö"), ("u", "ü")):
        for index, char in enumerate(word):
            if char == plain:
                found.append(word[:index] + letter + word[index + 1:])
    return found


class Corrector:
    """Decides what a typed word should have been."""

    def __init__(self, found: dict[str, Dictionary], keep: set[str] | None = None, usage: dict[str, dict[str, int]] | None = None):
        self.dictionaries = found
        self.keep = set(keep or ())
        # how often a word is used, per language; empty until the lists are there
        self.usage = usage if usage is not None else {}
        # which language is being written: recent words that belong to one only
        self.score = {language: 0.0 for language in LANGUAGES}
        self.cache: dict[tuple[str, str], tuple[str, str] | None] = {}
        self.nouns = nouns()

    def valid(self, language: str, word: str) -> bool:
        dictionary = self.dictionaries.get(language)
        return bool(dictionary) and dictionary.spell(word)

    def used(self, word: str, language: str | None = None) -> int:
        if " " in word:
            return min(self.used(part, language) for part in word.split(" "))
        word = word.lower()
        return max((words.get(word, 0) for name, words in self.usage.items() if language in (None, name)), default=0)

    def other(self, language: str) -> str:
        return "en" if language == "de" else "de"

    def primary(self) -> str:
        return "en" if self.score["en"] > self.score["de"] else "de"

    def writing(self, language: str) -> bool:
        """The text is clearly in this language right now."""
        return self.score[language] - self.score[self.other(language)] >= 1

    def heard(self, language: str):
        for name in self.score:
            self.score[name] = self.score[name] * 0.7 + (1 if name == language else 0)

    def suggestions(self, low: str, language: str) -> list[str]:
        dictionary = self.dictionaries.get(language)
        if not dictionary:
            return []
        words = dictionary.suggest(low)
        if language == "de":
            # nouns are only found with their capital; everything else loses it again
            for word in dictionary.suggest(capitalised(low)):
                words.append(word.lower() if dictionary.spell(word.lower()) else word)
        return list(dict.fromkeys(words))

    def candidates(self, low: str, language: str) -> list[tuple[float, str]]:
        """What the dictionary offers that is close enough to be meant."""
        limit = 1 if len(low) < 5 else 2
        found = []
        for word in self.suggestions(low, language):
            first, _, second = word.partition(" ")
            if second and WORD.fullmatch(first) and WORD.fullmatch(second):
                # garnicht: two common words without their space
                if min(self.used(first, language), self.used(second, language)) >= 5000:
                    found.append((1.0, word))
                continue
            if not WORD.fullmatch(word) or (word.isupper() and len(word) > 1):
                continue
            other = word.lower()
            edits = distance(low, other)
            if (len(low) <= 3 or low[0] != other[0]) and not swapped(low, other):
                # short words and first letters: two letters swapped, or a slip to a word everybody uses
                near = slipped(low, other) and (len(low) == len(other) or low[0] == other[0])
                if not (edits == 1 and near and self.used(word, language) >= 100000):
                    continue
            if edits <= limit:
                found.append((float(edits), word))
        return found

    def spelled(self, low: str) -> tuple[str, str] | None:
        """The word a misspelled one stands for, and its language."""
        key = (low, self.primary() if self.writing(self.primary()) else "")
        if key not in self.cache:
            self.cache[key] = self.lookup(low)
        return self.cache[key]

    def variants(self, low: str) -> list[str]:
        """German words the typed one is with its ß and umlauts: strasse, muessen, konnen."""
        found = []
        for variant in spellings(low):
            for form in (variant, capitalised(variant)):
                if self.valid("de", form):
                    found.append(form)
                    break
        return sorted(found, key=lambda form: -self.used(form, "de"))

    def lookup(self, low: str) -> tuple[str, str] | None:
        if low in CONTRACTIONS and low not in CONTRACTIONS_ENGLISH_ONLY and "en" in self.dictionaries:
            return CONTRACTIONS[low], "en"
        typed = self.used(low)
        variants = self.variants(low)
        # a noun without its capital, unless it is a far more common word without its ß: weiss
        if self.valid("de", capitalised(low)) and not (variants and self.used(variants[0], "de") > typed):
            return capitalised(low), "de"
        if variants:
            return variants[0], "de"
        # gehts, habs, wärs: a common word with the s of "es"
        if low.endswith("s") and self.valid("de", low[:-1]) and self.used(low[:-1], "de") >= 5000:
            return None
        pool: list[tuple[tuple, str, str]] = []
        for language in (self.primary(), self.other(self.primary())):
            close = self.candidates(low, language)
            for position, (edits, word) in enumerate(close):
                used = self.used(word, language)
                # a rare word: only when nothing else comes close
                if edits and self.usage and not used and len(close) > 1:
                    continue
                # a word that is in use itself gives way only to a far more common one
                if edits and typed and used < typed * 20:
                    continue
                # short words and words two edits away: only to words everybody uses
                if edits and self.usage and not used and (len(low) < 6 or edits > 1):
                    continue
                rank = 1 if self.writing(self.other(language)) else 0
                pool.append(((edits, rank, -used, position), word, language))
        if not pool:
            return None
        _, word, language = min(pool)
        return word, language

    def noun(self, low: str, context: list[str]) -> bool:
        """A word that is a noun and something else is the noun here: das spiel, die zeit, eine gute frage."""
        share = self.nouns.get(low, 0)
        if not share or self.writing("en") or (context and context[-1] in SUBJECTS):
            return False
        if share < 60:
            # mostly a verb: only where nothing but a noun can stand
            return bool(context) and context[-1] in SINGULAR
        if context and context[-1] in DETERMINERS:
            return True
        if len(context) > 1 and context[-2] in DETERMINERS and context[-1].endswith(("e", "en", "er", "es", "em")):
            return True
        # verbs look like this as well: ich frage, wir rennen
        return share >= 98 or (share >= 90 and not low.endswith(("e", "en", "t")))

    def joins(self, first: str, second: str) -> bool:
        """Two typed pieces are one word with a space that slipped in: i ch."""
        def word(part: str) -> bool:
            if len(part) == 1:
                return part.lower() == "a"
            if part.lower() in KEEP or part.lower() in self.keep or self.used(part) >= 100:
                return True
            return any(self.valid(language, part) for language in LANGUAGES)

        joined = first + second
        if word(first) and word(second):
            return False
        if not any(self.valid(language, form) for language in LANGUAGES for form in (joined, joined.lower())):
            return False
        return not self.usage or self.used(joined) >= 1000

    def word(self, typed: str, start: bool, context: list[str] | None = None) -> str | None:
        """What the typed word becomes; None when it stays as it is."""
        word = typed
        # HAllo
        if len(word) > 3 and word[:2].isupper() and word[2:].islower():
            word = word[0] + word[1:].lower()
        if not (word.islower() or (word[0].isupper() and word[1:].islower())):
            return None
        low = word.lower()
        known = low in self.keep or low in KEEP

        if low == "i":
            known = True
            if self.writing("en"):
                word = "I"
        elif not known and len(low) > 1:
            known = any(self.valid(language, word) for language in LANGUAGES)
            if not known and len(low) > 2:
                found = self.spelled(low)
                if found:
                    fixed = found[0]
                    word = capitalised(fixed) if word[0].isupper() else fixed
                    known = True
            if known:
                # Hand, Kind, Problem are German and English at once
                german = self.valid("de", word) or (word.islower() and self.valid("de", capitalised(word)))
                english = self.valid("en", word)
                if english and not german and self.writing("de"):
                    # an English word, but far more likely a German one without its umlaut: fur
                    variants = self.variants(low)
                    if variants and self.used(variants[0], "de") >= 20 * max(1, self.used(low, "de")):
                        word = capitalised(variants[0]) if word[0].isupper() else variants[0]
                        german, english = True, False
                if german != english:
                    self.heard("de" if german else "en")
                if word.islower():
                    if low in CONTRACTIONS_ENGLISH_ONLY and self.writing("en"):
                        word = CONTRACTIONS[low]
                    elif self.writing("de") and not self.valid("de", word) and self.valid("de", capitalised(word)):
                        word = capitalised(word)
                    elif self.noun(low, context or []):
                        word = capitalised(word)

        if start and known and word.islower():
            word = capitalised(word)
        return None if word == typed else word


# ── the text in front of the cursor ──────────────────────────────────────────

class Edit:
    """Take back `delete` characters, then type `text`. `kept` stands in
    front and stays, `gone` is what is taken back."""

    def __init__(self, delete: int, text: str, kept: str = "", gone: str = ""):
        self.delete = delete
        self.text = text
        self.kept = kept
        self.gone = gone

    def __repr__(self):
        return f"Edit({self.delete}, {self.text!r})"


def replace(before: str, after: str) -> Edit:
    """The edit that turns what is on the screen into what should be."""
    same = 0
    while same < min(len(before), len(after)) and before[same] == after[same]:
        same += 1
    return Edit(len(before) - same, after[same:], after[:same], before[same:])


# ── animations ───────────────────────────────────────────────────────────────

def pictures(name: str, old: str, word: str, letters: str, rng=random) -> list[str]:
    """What stands in place of `old` before `word` does, one picture after the other."""

    def noise(start: int) -> str:
        return "".join(rng.choice(letters).upper() if char.isupper() else rng.choice(letters) for char in word[start:])

    if name == "typewriter":
        shown = [old[:length] for length in range(len(old) - 1, -1, -1)] + [word[:length] for length in range(1, len(word))]
    elif name == "decode":
        shown = [word[:length] + noise(length) for length in range(len(word))]
    else:
        shown = [noise(0) for _ in range(5)]
    return shown[::math.ceil(len(shown) / PICTURES)]


class Stand:
    """Where an animation stands (see landed)."""

    def __init__(self, screen: str, wanted: str, more: str, cut: bool, shift: bool):
        # what stands there, from the start of what the edit keeps
        self.screen = screen
        # what should stand there in the end
        self.wanted = wanted
        # what was typed behind it since
        self.more = more
        # Backspace took something of the correction itself
        self.cut = cut
        # Shift is held
        self.shift = shift


def landed(edit: Edit, typed: list[tuple[float, Edit]], keys: list, faces: dict[tuple[int, bool], str]) -> Stand | None:
    """Where an animation stands with the keys of the real keyboard that got into it.

    `typed` is what the animation typed and when, `keys` what was pressed
    since it began. None when a key did more than type or take back a
    character: what is on the screen is unknown then.
    """
    steps = sorted([(when, 0, step) for when, step in typed] + [(key.timestamp(), 1, key) for key in keys], key=lambda step: step[:2])
    screen = list(edit.kept + edit.gone)
    wanted = list(edit.kept + edit.text)
    more: list[str] = []
    cut = False
    shift = 0
    for _, real, step in steps:
        if not real:
            if step.delete > len(screen):
                return None
            screen[len(screen) - step.delete:] = step.text
        elif step.code in (42, 54):
            shift = max(0, shift + {0: -1, 1: 1}.get(step.value, 0))
        elif step.code in MODIFIERS or step.code >= 0x100 or step.value == 2:
            return None
        elif step.value == 0:
            continue
        elif step.code == BACKSPACE:
            # with nothing there it is the start of the field, as far as anyone knows
            if screen:
                screen.pop()
            if wanted:
                wanted.pop()
            if more:
                more.pop()
            else:
                cut = True
        else:
            char = faces.get((step.code, shift > 0))
            if not char:
                return None
            screen.append(char)
            wanted.append(char)
            more.append(char)
    return Stand("".join(screen), "".join(wanted), "".join(more), cut, shift > 0)


class Typist:
    """Follows what is typed and answers every key with the edit it calls for."""

    def __init__(self, corrector: Corrector, learn=None):
        self.corrector = corrector
        self.learn = learn
        self.text = ""
        # the text starts in the middle of a word nobody saw
        self.partial = False
        # the text starts a sentence (None: unknown)
        self.opening: bool | None = None
        # the last correction, as long as Backspace can take it back
        self.undo: tuple[str, str, str | None] | None = None
        # the word before the cursor as it was typed and as it stands there
        self.last: tuple[str, str] | None = None

    def reset(self, partial: bool = False, opening: bool | None = None):
        self.text = ""
        self.partial = partial
        self.opening = opening
        self.undo = None
        self.last = None

    def enter(self):
        self.reset(opening=True)

    def backspace(self) -> Edit | None:
        if self.undo:
            typed, shown, word = self.undo
            self.undo = None
            # the Backspace itself took the last character
            edit = replace(shown[:-1], typed)
            self.text = self.text[:len(self.text) - len(shown)] + typed
            if word and self.learn:
                self.learn(word)
            return edit
        if self.text:
            self.text = self.text[:-1]
        else:
            self.partial = True
            self.opening = None
        return None

    def key(self, char: str) -> Edit | None:
        self.undo = None
        if char != " ":
            self.text += char
            return None
        last, self.last = self.last, None
        edit = self.space(last)
        if len(self.text) > MEMORY:
            self.text = self.text[-MEMORY:]
            self.partial = True
            self.opening = None
        return edit

    def starts_sentence(self, before: str) -> bool | None:
        """Whether a word after this text opens a sentence."""
        before = before.rstrip(" ")
        if not before:
            return None if self.partial else self.opening
        last = before.split(" ")[-1].rstrip("\"')]}“”»’")
        if not last or last[-1] not in ".!?" or last.endswith(".."):
            return False
        if last[-1] == ".":
            stem = last[:-1].lstrip(OPENING).lower()
            if stem in ABBREVIATIONS or stem.isdigit() or (len(stem) == 1 and stem.isalpha()):
                return False
        return True

    def context(self, before: str) -> list[str]:
        """The two words in front, as far as they belong to the same part of the sentence."""
        words: list[str] = []
        for token in reversed(before.split(" ")[-3:]):
            if not token:
                continue
            if not WORD.fullmatch(token):
                break
            words.insert(0, token.lower())
        return words[-2:]

    def space(self, last: tuple[str, str] | None = None) -> Edit | None:
        start = self.text.rfind(" ") + 1
        token = self.text[start:]
        before = self.text[:start]
        self.text += " "

        if not token:
            # two spaces after a word end the sentence
            if len(before) > 1 and before[-2].isalnum():
                return self.apply(before[-1:] + " ", ". ", None)
            return None
        if start == 0 and self.partial:
            return None
        # no space before a punctuation mark
        if token in (",", ".", "!", "?") and len(before) > 1 and before[-2].isalpha():
            return self.apply(" " + token + " ", token + " ", None)

        lead, core, trail = TOKEN.fullmatch(token).groups()
        if not WORD.fullmatch(core):
            return None
        # a space that slipped into a word
        if last and not lead and before.endswith(last[1] + " ") and self.corrector.joins(last[0], core):
            ahead = before[:len(before) - len(last[1]) - 1]
            if not ahead or ahead.endswith(" "):
                joined = last[0] + core
                opens = self.starts_sentence(ahead) is True
                fixed = self.corrector.word(joined, opens, self.context(ahead)) or joined
                return self.apply(last[1] + " " + token + " ", fixed + trail + " ", None)
        opens = self.starts_sentence(before + lead) is True and not lead.strip(OPENING)
        fixed = self.corrector.word(core, opens, self.context(before))
        if not lead and not trail:
            self.last = (core, fixed or core)
        comma = not lead and self.comma(before, fixed or core)
        if fixed is None and not comma:
            return None
        learned = core.lower() if fixed and fixed.lower() != core.lower() else None
        if comma:
            return self.apply(before[-1:] + token + " ", ", " + (fixed or core) + trail + " ", learned)
        return self.apply(token + " ", lead + fixed + trail + " ", learned)

    def comma(self, before: str, word: str) -> bool:
        """Whether a comma belongs in front of the word: it opens a subordinate clause."""
        if word not in COMMA or not before.endswith(" ") or self.corrector.writing("en"):
            return False
        previous = before[:-1].split(" ")[-1]
        return bool(WORD.fullmatch(previous)) and previous.lower() not in NO_COMMA

    def apply(self, typed: str, shown: str, word: str | None) -> Edit:
        self.text = self.text[:len(self.text) - len(typed)] + shown
        self.undo = (typed, shown, word)
        return replace(typed, shown)


# ── keyboard layout ──────────────────────────────────────────────────────────

class RuleNames(ctypes.Structure):
    _fields_ = [(name, ctypes.c_char_p) for name in ("rules", "model", "layout", "variant", "options")]


def configured_layout() -> dict[str, str]:
    """The xkb settings niri gives every keyboard."""
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "niri"
    files = [Path(os.environ["NIRI_CONFIG"])] if os.environ.get("NIRI_CONFIG") else []
    files += [config / "config.kdl"] + sorted(config.glob("**/*.kdl"))
    for file in files:
        try:
            text = re.sub(r"^\s*//.*$", "", file.read_text(), flags=re.M)
        except OSError:
            continue
        block = re.search(r"\bxkb\s*\{(.*?)\}", text, re.S)
        if block:
            return {key: value for key, value in re.findall(r"\b(rules|model|layout|variant|options)\s+\"([^\"]*)\"", block.group(1))}
    try:
        status = subprocess.run(["localectl", "status"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    names = {"Layout": "layout", "Model": "model", "Variant": "variant", "Options": "options"}
    return {names[key]: value.strip() for key, value in re.findall(r"X11 (Layout|Model|Variant|Options):(.*)", status)}


def active_layout() -> int:
    try:
        answer = subprocess.run(["niri", "msg", "-j", "keyboard-layouts"], capture_output=True, text=True, timeout=3).stdout
        return int(json.loads(answer).get("current_idx", 0))
    except (OSError, ValueError, subprocess.SubprocessError, AttributeError):
        return 0


class Keymap:
    """Keys to characters and back, in the layout the compositor uses."""

    SHIFT, ALTGR, CAPS = 42, 100, 58
    DOWN, UP = 1, 0
    EFFECTIVE, LOCKED = 8, 4

    def __init__(self, names: dict[str, str], layout: int = 0, caps: bool = False, numlock: bool = False):
        xkb = ctypes.CDLL(ctypes.util.find_library("xkbcommon") or "libxkbcommon.so.0")
        pointer = ctypes.c_void_p
        for name, result, arguments in (
            ("xkb_context_new", pointer, [ctypes.c_int]),
            ("xkb_keymap_new_from_names", pointer, [pointer, ctypes.POINTER(RuleNames), ctypes.c_int]),
            ("xkb_keymap_mod_get_index", ctypes.c_uint32, [pointer, ctypes.c_char_p]),
            ("xkb_state_new", pointer, [pointer]),
            ("xkb_state_unref", None, [pointer]),
            ("xkb_state_update_key", ctypes.c_int, [pointer, ctypes.c_uint32, ctypes.c_int]),
            ("xkb_state_update_mask", ctypes.c_int, [pointer] + [ctypes.c_uint32] * 6),
            ("xkb_state_key_get_utf8", ctypes.c_int, [pointer, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t]),
            ("xkb_state_mod_name_is_active", ctypes.c_int, [pointer, ctypes.c_char_p, ctypes.c_int]),
        ):
            function = getattr(xkb, name)
            function.restype, function.argtypes = result, arguments
        self.xkb = xkb
        rules = RuleNames(**{key: value.encode() for key, value in names.items() if value})
        self.keymap = xkb.xkb_keymap_new_from_names(xkb.xkb_context_new(0), ctypes.byref(rules), 0)
        if not self.keymap:
            raise ValueError(f"no keymap for {names}")
        self.layout = layout
        self.state = self.fresh(caps, numlock)
        # (key, with Shift) → character
        self.faces: dict[tuple[int, bool], str] = {}
        self.keys = self.table()
        # what an animation shows in place of a letter
        self.letters = "".join(sorted(char for char, (_, shift, altgr) in self.keys.items()
                                      if char.islower() and not shift and not altgr and char.upper() in self.keys))

    def fresh(self, caps: bool = False, numlock: bool = False):
        state = self.xkb.xkb_state_new(self.keymap)
        locked = 0
        for name, on in ((b"Lock", caps), (b"Mod2", numlock)):
            index = self.xkb.xkb_keymap_mod_get_index(self.keymap, name)
            if on and index < 32:
                locked |= 1 << index
        self.xkb.xkb_state_update_mask(state, 0, 0, locked, 0, 0, self.layout)
        return state

    def char(self, state, code: int) -> str:
        buffer = ctypes.create_string_buffer(16)
        self.xkb.xkb_state_key_get_utf8(state, code + 8, buffer, len(buffer))
        return buffer.value.decode("utf-8", "replace")

    def table(self) -> dict[str, tuple[int, bool, bool]]:
        """character → (key, with Shift, with AltGr), the plainest way to type it"""
        keys: dict[str, tuple[int, bool, bool]] = {}
        for shift, altgr in ((False, False), (True, False), (False, True), (True, True)):
            state = self.fresh()
            if shift:
                self.xkb.xkb_state_update_key(state, self.SHIFT + 8, self.DOWN)
            if altgr:
                self.xkb.xkb_state_update_key(state, self.ALTGR + 8, self.DOWN)
            # the typing keys, not the numpad
            for code in list(range(2, 14)) + list(range(16, 28)) + list(range(30, 42)) + list(range(43, 54)) + [57, 86]:
                char = self.char(state, code)
                if len(char) == 1 and char.isprintable():
                    keys.setdefault(char, (code, shift, altgr))
                    if not altgr:
                        self.faces[(code, shift)] = char
            self.xkb.xkb_state_unref(state)
        return keys

    def press(self, code: int, down: bool) -> str:
        """Follows a key; the character a key that went down types."""
        char = self.char(self.state, code) if down else ""
        self.xkb.xkb_state_update_key(self.state, code + 8, self.DOWN if down else self.UP)
        return char

    def held(self, *names: bytes) -> bool:
        return any(self.xkb.xkb_state_mod_name_is_active(self.state, name, self.EFFECTIVE) > 0 for name in names)

    def caps(self) -> bool:
        return self.xkb.xkb_state_mod_name_is_active(self.state, b"Lock", self.LOCKED) > 0

    def strokes(self, edit: Edit) -> list[tuple[int, int]] | None:
        """The key events of an edit: (key, 1 down / 0 up). None when a character has no key."""
        events: list[tuple[int, int]] = []
        for _ in range(edit.delete):
            events += [(14, 1), (14, 0)]
        for char in edit.text:
            if char not in self.keys:
                return None
            code, shift, altgr = self.keys[char]
            held = ([self.SHIFT] if shift else []) + ([self.ALTGR] if altgr else [])
            events += [(key, 1) for key in held] + [(code, 1), (code, 0)] + [(key, 0) for key in reversed(held)]
        return events


# ── the daemon ───────────────────────────────────────────────────────────────

MODIFIERS = {29, 42, 54, 56, 58, 69, 70, 97, 100, 125, 126}
# keys that neither type nor move the cursor: sound, music, brightness, print
SILENT = {99, 113, 114, 115, 163, 164, 165, 166, 224, 225, 248} | set(range(183, 195))
BACKSPACE, TAB, ENTER, KEYPAD_ENTER, SPACE = 14, 15, 28, 96, 57
BUTTONS = range(0x110, 0x120)
TOUCH = 0x14a


def emit(**message):
    print(json.dumps(message, separators=(",", ":")), flush=True)


def learned() -> set[str]:
    try:
        return {str(word) for word in json.loads(state_file().read_text()).get("keep", [])}
    except (OSError, ValueError, AttributeError):
        return set()


class Daemon:
    def __init__(self):
        import evdev

        self.evdev = evdev
        self.found = dictionaries()
        if not self.found:
            emit(type="error", reason="dictionaries")
            raise SystemExit(2)
        self.corrector = Corrector(self.found, learned())
        threading.Thread(target=load_usage, args=(self.corrector.usage, True), daemon=True).start()
        self.typist = Typist(self.corrector, self.learn)
        self.selector = selectors.DefaultSelector()
        self.devices: dict[str, object] = {}
        self.denied = 0
        self.scan()
        if not any(self.typing(device) for device in self.devices.values()):
            emit(type="error", reason="permission" if self.denied else "keyboard")
            raise SystemExit(2)
        leds = [led for device in self.devices.values() if self.typing(device) for led in device.leds()]
        try:
            self.keymap = Keymap(configured_layout(), active_layout(), caps=evdev.ecodes.LED_CAPSL in leds, numlock=evdev.ecodes.LED_NUML in leds)
        except (OSError, ValueError):
            emit(type="error", reason="layout")
            raise SystemExit(2)
        try:
            codes = sorted({14, Keymap.SHIFT, Keymap.ALTGR} | {code for code, _, _ in self.keymap.keys.values()})
            self.keyboard = evdev.UInput({evdev.ecodes.EV_KEY: codes}, name=NAME)
        except (OSError, evdev.UInputError):
            emit(type="error", reason="uinput")
            raise SystemExit(2)
        self.active = False
        # the animations a correction is typed with; one of them each time
        self.animations: list[str] = []
        self.said = b""
        # an edit waiting for Shift to be let go
        self.waiting: Edit | None = None
        self.queue: deque = deque()
        self.selector.register(sys.stdin, selectors.EVENT_READ, "control")
        emit(type="ready", languages=sorted(self.found), devices=len(self.devices))

    def typing(self, device) -> bool:
        return self.evdev.ecodes.KEY_A in device.capabilities().get(self.evdev.ecodes.EV_KEY, [])

    def scan(self):
        """Keyboards to follow, and whatever clicks: a click moves the cursor."""
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
            keys = device.capabilities().get(ecodes.EV_KEY, [])
            if device.name == NAME or not (ecodes.KEY_A in keys or ecodes.BTN_LEFT in keys or TOUCH in keys):
                device.close()
                continue
            self.devices[path] = device
            self.selector.register(device, selectors.EVENT_READ, path)

    def drop(self, path: str):
        device = self.devices.pop(path, None)
        if device:
            try:
                self.selector.unregister(device)
                device.close()
            except (OSError, KeyError, ValueError):
                pass

    def learn(self, word: str):
        self.corrector.keep.add(word)
        self.corrector.cache.clear()
        file = state_file()
        try:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(json.dumps({"keep": sorted(self.corrector.keep)}, ensure_ascii=False, indent="\t") + "\n")
        except OSError:
            pass

    def control(self) -> bool:
        """What the shell says; False when the shell is gone."""
        data = os.read(sys.stdin.fileno(), 4096)
        if not data:
            return False
        self.said += data
        *lines, self.said = self.said.split(b"\n")
        for line in lines:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if isinstance(message, dict):
                self.active = message.get("active") is True
                if isinstance(message.get("animations"), list):
                    self.animations = [name for name in message["animations"] if name in ANIMATIONS]
                # another window, another text
                self.typist.reset(opening=True)
                self.waiting = None
        return True

    def pending(self) -> bool:
        """Reads what was typed in the meantime; True when a key went down."""
        pressed = False
        for key, _ in self.selector.select(0):
            if key.data == "control":
                continue
            try:
                for event in self.devices[key.data].read():
                    if event.type == self.evdev.ecodes.EV_KEY:
                        self.queue.append(event)
                        pressed = pressed or event.value != 0
            except OSError:
                self.drop(key.data)
        return pressed

    def strike(self, edit: Edit) -> bool:
        """Types an edit; False when a character of it has no key."""
        strokes = self.keymap.strokes(edit)
        if strokes is None:
            return False
        ecodes = self.evdev.ecodes
        for code, value in strokes:
            self.keyboard.write(ecodes.EV_KEY, code, value)
            self.keyboard.syn()
            if value == 0 and KEY_DELAY:
                time.sleep(KEY_DELAY)
        return True

    def wait(self, seconds: float | None, released: bool = False) -> str:
        """Reads the keyboards for that long. Ends early with "control" when
        the shell says something and with "key" when a key goes down, or
        comes up as well when `released` is asked for."""
        until = None if seconds is None else time.monotonic() + seconds
        while True:
            left = None if until is None else until - time.monotonic()
            if left is not None and left <= 0:
                return ""
            came = False
            for ready, _ in self.selector.select(left):
                if ready.data == "control":
                    # another window, most likely: read by run()
                    return "control"
                try:
                    for event in self.devices[ready.data].read():
                        if event.type == self.evdev.ecodes.EV_KEY:
                            self.queue.append(event)
                            came = came or released or event.value != 0
                except (OSError, KeyError):
                    self.drop(ready.data)
            if came:
                return "key"

    def shots(self, edit: Edit, name: str) -> tuple[Edit, list[str], str]:
        """An edit as an animation: the edit it is the pictures of, the
        pictures, and what stands behind its word. No pictures without a word."""
        wide = edit
        if name != "typewriter":
            # the whole word, not only the letters that change
            stays = re.search(r"[^\W\d_]*$", edit.kept).group()
            wide = Edit(edit.delete + len(stays), stays + edit.text, edit.kept[:len(edit.kept) - len(stays)], stays + edit.gone)
        word = WORD.match(wide.text)
        if not word or len(word.group()) < 2 or self.keymap.strokes(wide) is None:
            return edit, [], ""
        rest = wide.text[word.end():]
        old = wide.gone[:len(wide.gone) - len(rest)] if rest and wide.gone.endswith(rest) else wide.gone
        return wide, pictures(name, old, word.group(), self.keymap.letters), rest

    def type(self, edit: Edit, animated: bool = True):
        """Types an edit, and sees to it that the text is right afterwards
        whatever was typed meanwhile: every key since the one that called for
        the edit is followed (landed), what it typed is put behind the word
        again, and what stands there is compared with what should."""
        if self.keymap.strokes(edit) is None or self.keymap.caps():
            self.typist.reset(partial=True)
            return
        # the text in front, as far as it was followed: Backspace reaches into it
        shown = edit.kept + edit.text
        front = self.typist.text[:len(self.typist.text) - len(shown)] if animated and self.typist.text.endswith(shown) else ""
        name = random.choice(self.animations) if animated and self.animations else ""
        edit, shots, rest = self.shots(edit, name) if name else (edit, [], "")
        edit = Edit(edit.delete, edit.text, front + edit.kept, edit.gone)
        typed: list[tuple[float, Edit]] = []
        shot = settled = 0
        while True:
            self.pending()
            # the keys in the queue came after the one that is being answered
            stand = landed(edit, typed, list(self.queue), self.keymap.faces)
            if stand is None or (stand.cut and not typed):
                # a click, a shortcut, Enter: what is on the screen is unknown.
                # Or Backspace before anything was typed: the word is being changed
                break
            # typed on: the word comes at once, with what was typed behind it
            last = stand.cut or stand.more != "" or shot >= len(shots)
            if last:
                target = stand.wanted
                if stand.screen == target:
                    return
            else:
                # the space comes with the word, unless something stands behind it already
                target = edit.kept + shots[shot] + (rest if rest.strip() else "")
            if stand.shift:
                # typed now it would come out in capitals
                if self.wait(None, released=True) == "control":
                    break
                continue
            step = replace(stand.screen, target)
            if step.delete or step.text:
                typed.append((time.time(), step))
                if not self.strike(step):
                    break
            if last:
                # a key got into the last strokes: once more
                settled += 1
                if settled > 3:
                    break
            else:
                shot += 1
                if self.wait(ANIMATIONS[name]) == "control":
                    break
        self.typist.reset(partial=True)

    def handle(self, event):
        code, value = event.code, event.value
        if code >= 0x100:
            # a click puts the cursor somewhere else
            if value == 1 and (code in BUTTONS or code == TOUCH):
                self.typist.reset(opening=True)
                self.waiting = None
            return
        if code in MODIFIERS:
            if value == 2:
                return
            self.keymap.press(code, value != 0)
            if self.waiting and value == 0 and not self.keymap.held(b"Shift", b"Mod5"):
                edit, self.waiting = self.waiting, None
                self.type(edit)
            return
        if value == 0:
            self.keymap.press(code, False)
            return
        char = self.keymap.press(code, True) if value == 1 else self.keymap.char(self.keymap.state, code)
        if not self.active or code in SILENT:
            return
        if self.waiting:
            # typed on before Shift was let go
            self.waiting = None
            self.typist.reset(partial=True)
        if self.keymap.held(b"Control", b"Mod1", b"Mod4"):
            self.typist.reset(partial=True)
            return
        edit = None
        # what Backspace brings back is not animated
        animated = code != BACKSPACE
        if code == BACKSPACE:
            edit = self.typist.backspace()
        elif code in (ENTER, KEYPAD_ENTER):
            self.typist.enter()
        elif code == TAB:
            self.typist.reset(opening=True)
        elif len(char) != 1 or not char.isprintable() or (value == 2 and code != SPACE):
            # a cursor key, a dead key, a key held down
            self.typist.reset(partial=True)
        elif value == 2:
            self.typist.reset()
        else:
            edit = self.typist.key(char)
        if not edit:
            return
        if self.keymap.held(b"Shift", b"Mod5"):
            self.waiting = edit
        else:
            self.type(edit, animated)

    def run(self):
        rescan = time.monotonic() + 5
        while True:
            while self.queue:
                self.handle(self.queue.popleft())
            for key, _ in self.selector.select(max(0.0, rescan - time.monotonic())):
                if key.data == "control":
                    if not self.control():
                        return
                    continue
                try:
                    events = list(self.devices[key.data].read())
                except (OSError, KeyError):
                    self.drop(key.data)
                    continue
                for event in events:
                    if event.type == self.evdev.ecodes.EV_KEY:
                        self.queue.append(event)
                while self.queue:
                    self.handle(self.queue.popleft())
            if time.monotonic() >= rescan:
                self.scan()
                rescan = time.monotonic() + 5


def attempt(text: str) -> str:
    """What typing the text leaves on the screen."""
    corrector = Corrector(dictionaries())
    load_usage(corrector.usage)
    typist = Typist(corrector)
    typist.enter()
    screen = ""
    for char in text.replace("\\n", "\n").replace("\\b", "\b"):
        if char == "\b":
            screen = screen[:-1]
            edit = typist.backspace()
        elif char == "\n":
            screen += char
            typist.enter()
            edit = None
        else:
            screen += char
            edit = typist.key(char)
        if edit:
            screen = screen[:len(screen) - edit.delete] + edit.text
    return screen


def main() -> int:
    if len(sys.argv) > 2 and sys.argv[1] == "try":
        print(attempt(" ".join(sys.argv[2:])))
        return 0
    if len(sys.argv) > 1:
        print(__doc__.strip())
        return 0 if sys.argv[1] in ("-h", "--help") else 1
    try:
        Daemon().run()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
