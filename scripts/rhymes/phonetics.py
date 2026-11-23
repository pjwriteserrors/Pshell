"""How English words sound: the CMU Pronouncing Dictionary, espeak-ng for the
words it does not know (slang, names, made-up words), and how often words
are used.

A pronunciation is a tuple of ARPAbet phones, vowels carrying their stress
(0 none, 1 primary, 2 secondary): "trucks" → ("T", "R", "AH1", "K", "S").

The dictionary and the list of how often words are used are fetched once
and kept (`~/.local/share/pshell/rhymes/`); after that nothing goes online.
"""

from __future__ import annotations

import json
import os
import pickle
import re
import subprocess
import threading
import urllib.request
from pathlib import Path

DATA = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "pshell" / "rhymes"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "rhymes"
CMUDICT_URL = "https://raw.githubusercontent.com/cmusphinx/cmudict/master/cmudict.dict"
USAGE_URL = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt"
# autocorrect keeps the same list
AUTOCORRECT_USAGE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "autocorrect" / "en.txt"

VOWELS = {"AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"}
# sounds that are near each other at the end of a word: a slant rhyme
CLASSES = {
    "P": "stop", "B": "stop", "T": "stop", "D": "stop", "K": "stop", "G": "stop",
    "M": "nasal", "N": "nasal", "NG": "nasal",
    "F": "fric", "V": "fric", "TH": "fric", "DH": "fric", "S": "sib", "Z": "sib", "SH": "sib", "ZH": "sib",
    "CH": "aff", "JH": "aff", "HH": "h", "L": "liq", "R": "liq", "W": "glide", "Y": "glide",
}
WORD = re.compile(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)*['’]?|['’][A-Za-z]+")

# espeak-ng's IPA (en-us, --ipa=1: phones split by "_") to ARPAbet
IPA = {
    "ɑːɹ": ["AA", "R"], "ɔːɹ": ["AO", "R"], "ɛɹ": ["EH", "R"], "ɪɹ": ["IH", "R"], "ʊɹ": ["UH", "R"], "oːɹ": ["AO", "R"],
    "aɪɚ": ["AY", "ER"], "aɪə": ["AY", "AH"], "aʊɚ": ["AW", "ER"], "iə": ["IY", "AH"],
    "ɑː": ["AA"], "ɑ": ["AA"], "a": ["AA"], "æ": ["AE"], "ʌ": ["AH"], "ə": ["AH"], "ɐ": ["AH"], "ɚ": ["ER"], "ɜː": ["ER"], "ɝ": ["ER"],
    "ɔː": ["AO"], "ɔ": ["AO"], "oː": ["OW"], "aʊ": ["AW"], "aɪ": ["AY"], "ɛ": ["EH"], "e": ["EH"], "eɪ": ["EY"], "ɪ": ["IH"], "ᵻ": ["IH"],
    "i": ["IY"], "iː": ["IY"], "oʊ": ["OW"], "ɔɪ": ["OY"], "ʊ": ["UH"], "uː": ["UW"], "u": ["UW"],
    "b": ["B"], "tʃ": ["CH"], "d": ["D"], "ð": ["DH"], "f": ["F"], "ɡ": ["G"], "g": ["G"], "h": ["HH"], "dʒ": ["JH"], "k": ["K"],
    "l": ["L"], "m": ["M"], "n": ["N"], "ŋ": ["NG"], "p": ["P"], "ɹ": ["R"], "r": ["R"], "s": ["S"], "ʃ": ["SH"], "t": ["T"],
    "θ": ["TH"], "v": ["V"], "w": ["W"], "j": ["Y"], "z": ["Z"], "ʒ": ["ZH"], "ɾ": ["T"], "ʔ": ["T"], "x": ["K"],
    "n̩": ["AH", "N"], "l̩": ["AH", "L"], "m̩": ["AH", "M"],
}


def fetch(url: str, out: Path) -> bool:
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "Pshell-Rhymes/1.0"})
        with urllib.request.urlopen(request, timeout=60) as answer:
            data = answer.read()
        out.parent.mkdir(parents=True, exist_ok=True)
        part = out.with_suffix(out.suffix + ".part")
        part.write_bytes(data)
        part.replace(out)
        return True
    except (OSError, ValueError):
        return False


def normal(word: str) -> str:
    return word.lower().replace("’", "'")


def vowel(phone: str) -> bool:
    return phone[-1:].isdigit()


def base(phone: str) -> str:
    return phone.rstrip("012")


def vowels_of(pron) -> list[str]:
    return [p for p in pron if vowel(p)]


def syllables(pron) -> int:
    return sum(1 for p in pron if vowel(p))


def stresses(pron) -> list[int]:
    return [int(p[-1]) for p in pron if vowel(p)]


def tail(pron) -> tuple:
    """The rhyming part: from the last stressed vowel to the end, stress left out."""
    marks = [i for i, p in enumerate(pron) if vowel(p)]
    if not marks:
        return tuple(pron[-2:])
    start = next((i for i in reversed(marks) if pron[i].endswith("1")), None)
    if start is None:
        start = next((i for i in reversed(marks) if pron[i].endswith("2")), marks[-1])
    return tuple(base(p) for p in pron[start:])


def coda(pron) -> tuple:
    """The sounds after the last vowel."""
    out = []
    for p in reversed(pron):
        if vowel(p):
            break
        out.append(p)
    return tuple(reversed(out))


def coda_class(phones) -> tuple:
    return tuple(CLASSES.get(p, p) for p in phones)


class Phonetics:
    def __init__(self, fetch_missing: bool = True):
        self.words: dict[str, list[tuple]] = {}
        self.rank: dict[str, int] = {}
        self.guessed: dict[str, tuple] = {}
        self.lock = threading.Lock()
        self.ready = False
        self.missing = False
        self.fetch_missing = fetch_missing
        self.guess_file = CACHE / "guessed.json"

    # ── loading ──────────────────────────────────────────────────────────
    def load(self):
        source = DATA / "cmudict.dict"
        if not source.exists() and not (self.fetch_missing and fetch(CMUDICT_URL, source)):
            self.missing = True
            return
        pickled = CACHE / "cmudict.pickle"
        try:
            if pickled.stat().st_mtime >= source.stat().st_mtime:
                with pickled.open("rb") as handle:
                    self.words = pickle.load(handle)
        except (OSError, pickle.PickleError, EOFError, ValueError):
            self.words = {}
        if not self.words:
            self.words = self.parse(source)
            try:
                CACHE.mkdir(parents=True, exist_ok=True)
                with pickled.open("wb") as handle:
                    pickle.dump(self.words, handle, protocol=pickle.HIGHEST_PROTOCOL)
            except OSError:
                pass
        self.load_usage()
        try:
            self.guessed = {k: tuple(v) for k, v in json.loads(self.guess_file.read_text()).items()}
        except (OSError, ValueError):
            self.guessed = {}
        self.ready = True

    @staticmethod
    def parse(source: Path) -> dict[str, list[tuple]]:
        words: dict[str, list[tuple]] = {}
        for line in source.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            head, _, phones = line.partition(" ")
            word = re.sub(r"\(\d+\)$", "", head)
            words.setdefault(word, []).append(tuple(phones.split()))
        return words

    def load_usage(self):
        own = DATA / "en_50k.txt"
        source = own if own.exists() else AUTOCORRECT_USAGE
        if not source.exists() and self.fetch_missing and fetch(USAGE_URL, own):
            source = own
        try:
            for i, line in enumerate(source.read_text(encoding="utf-8", errors="replace").splitlines()):
                word = line.partition(" ")[0]
                if word and word not in self.rank:
                    self.rank[word] = i
        except OSError:
            pass

    # ── looking up ───────────────────────────────────────────────────────
    def known(self, word: str) -> bool:
        return normal(word) in self.words

    def prons(self, word: str) -> list[tuple]:
        w = normal(word)
        if not w:
            return []
        found = self.words.get(w) or self.words.get(w.strip("'"))
        if found:
            return found
        # goin' → going, said with an N
        if w.endswith("in'"):
            full = self.words.get(w.rstrip("'") + "g")
            if full:
                return [tuple(p if p != "NG" or i < len(pron) - 1 else "N" for i, p in enumerate(pron)) for pron in full]
        if w.endswith("'s") and w[:-2] in self.words:
            return [pron + (("Z",) if pron[-1] not in ("S", "Z", "SH", "CH") else ("AH0", "Z")) for pron in self.words[w[:-2]]]
        if w.endswith("s'") and w[:-1] in self.words:
            return self.words[w[:-1]]
        if w.strip("'") in self.guessed:
            return [self.guessed[w.strip("'")]]
        if w.isdigit():
            return []
        return []

    def pron(self, word: str) -> tuple:
        found = self.prons(word)
        return found[0] if found else ()

    def guess(self, words) -> None:
        """Asks espeak-ng how the unknown words sound, all at once; kept for next time."""
        todo = sorted({normal(w).strip("'") for w in words if normal(w).strip("'") and not self.prons(w) and not normal(w).isdigit()})
        if not todo:
            return
        try:
            out = subprocess.run(["espeak-ng", "-v", "en-us", "-q", "--ipa=1"], input="\n".join(todo) + "\n",
                                 capture_output=True, text=True, timeout=10).stdout.splitlines()
        except (OSError, subprocess.SubprocessError):
            return
        out = [line.strip() for line in out if line.strip()]
        if len(out) != len(todo):
            # espeak joined or split lines: one at a time, the slow way
            out = []
            for word in todo:
                try:
                    out.append(subprocess.run(["espeak-ng", "-v", "en-us", "-q", "--ipa=1", word], capture_output=True, text=True, timeout=5).stdout.strip())
                except (OSError, subprocess.SubprocessError):
                    out.append("")
        with self.lock:
            for word, ipa in zip(todo, out):
                pron = self.from_ipa(ipa)
                if pron:
                    self.guessed[word] = pron
            try:
                CACHE.mkdir(parents=True, exist_ok=True)
                self.guess_file.write_text(json.dumps(self.guessed))
            except OSError:
                pass

    @staticmethod
    def from_ipa(ipa: str) -> tuple:
        phones = []
        for chunk in re.split(r"[_ ]+", ipa.replace("‍", "")):
            if not chunk:
                continue
            stress = "1" if "ˈ" in chunk else "2" if "ˌ" in chunk else "0"
            chunk = chunk.replace("ˈ", "").replace("ˌ", "")
            mapped = IPA.get(chunk) or IPA.get(chunk.replace("ː", ""))
            if mapped is None:
                # unknown pieces: try them sound by sound
                mapped = []
                for char in chunk:
                    mapped += IPA.get(char, [])
            for i, phone in enumerate(mapped):
                if phone in VOWELS:
                    # one stress per vowel group, on its first vowel
                    phones.append(phone + (stress if i == 0 or not any(p in VOWELS for p in mapped[:i]) else "0"))
                else:
                    phones.append(phone)
        # a word with vowels but no stress: the first one carries it
        if phones and not any(p.endswith(("1", "2")) for p in phones):
            for i, p in enumerate(phones):
                if vowel(p):
                    phones[i] = base(p) + "1"
                    break
        return tuple(phones)

    def usage(self, word: str) -> int:
        return self.rank.get(normal(word), 99999)
