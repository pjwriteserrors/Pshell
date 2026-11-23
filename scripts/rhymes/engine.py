"""Rhymes for words and phrases, and what rhymes in a text.

Everything is looked up in tables built once when the helper starts (a
fraction of a second), so an answer takes a few milliseconds:

  by_tail     the rhyming part of a word (last stressed vowel to the end) → words
  by_vowels   the last 1..4 vowels of a word → words (multisyllable rhymes)
  by_whole    all the vowels of a short word → words (the second word of a pair)

Only words that are used (the 50 000 most common) and the user's own words
are offered; the dictionary's names and abbreviations stay out.
"""

from __future__ import annotations

import math
import re
from collections import defaultdict

from phonetics import WORD, Phonetics, base, coda, coda_class, normal, stresses, syllables, tail, vowel, vowels_of

# words that rhyme with everything and carry no rhyme of their own inside a line
STOP = set("""
a an the and or but if of to in on at by for with from as is am are was were be been being it its it's i i'm
me my we us our you your he him his she her they them their this that these those there here so do does did
not no yes up out off just than then too very can can't will won't would should could has have had get got
gonna wanna like what who how when where why which all some any each every one ya yo uh oh ooh ah yeah
""".split())
# sounds rather than words: never the half of a pair
FILLER = set("er uh um ah oh eh hm hmm mm ooh aw ow huh ha oy".split())
# vowels that are said so weakly that they do not make a multi on their own
WEAK = {"AH0", "IH0", "ER0", "IY0", "UH0"}
MAX_VOWELS = 4


def letters(n: int) -> str:
    out = ""
    n += 1
    while n:
        n, r = divmod(n - 1, 26)
        out = chr(65 + r) + out
    return out


class Engine:
    def __init__(self, phonetics: Phonetics):
        self.ph = phonetics
        self.by_tail: dict[tuple, list[str]] = defaultdict(list)
        self.by_vowels: dict[tuple, list[str]] = defaultdict(list)
        self.by_whole: dict[tuple, list[str]] = defaultdict(list)
        self.own: dict[tuple, list[dict]] = defaultdict(list)
        self.vocab: set[str] = set()
        self.cache: dict = {}

    # ── the tables ───────────────────────────────────────────────────────
    def build(self, extra=()):
        ph = self.ph
        words = [w for w in ph.rank if w in ph.words and re.fullmatch(r"[a-z][a-z']*", w)]
        words += [normal(w) for w in extra if normal(w) not in ph.rank]
        seen = set()
        for word in words:
            if word in seen:
                continue
            seen.add(word)
            pron = ph.pron(word)
            if not pron or len(word) < 2 and word not in ("a", "i"):
                continue
            self.vocab.add(word)
            self.by_tail[tail(pron)].append(word)
            vs = tuple(base(v) for v in vowels_of(pron))
            for k in range(1, min(MAX_VOWELS, len(vs)) + 1):
                self.by_vowels[vs[-k:]].append(word)
            if 1 <= len(vs) <= MAX_VOWELS - 1:
                self.by_whole[vs].append(word)
        self.cache.clear()

    def learn(self, lines):
        """Phrases of the user's own songs and ideas, by their vowels: offered as "Yours"."""
        self.own = defaultdict(list)
        known = set()
        for line in lines:
            tokens = WORD.findall(line.get("text", ""))
            for end in range(len(tokens)):
                for start in range(max(0, end - 3), end + 1):
                    phrase = tokens[start:end + 1]
                    pron = self.phrase_pron(phrase)
                    if not pron:
                        continue
                    vs = tuple(base(v) for v in vowels_of(pron))
                    if not 1 <= len(vs) <= MAX_VOWELS:
                        continue
                    text = " ".join(phrase).lower()
                    if (text, vs) in known:
                        continue
                    known.add((text, vs))
                    self.own[vs].append({"text": text, "coda": coda(pron), "song": line.get("song", ""), "tail": tail(pron)})
        self.cache.clear()

    def phrase_pron(self, words) -> tuple:
        out = ()
        for word in words:
            pron = self.ph.pron(word)
            if not pron:
                return ()
            out += pron
        return out

    # ── rhymes for what is in front of the cursor ─────────────────────────
    def around(self, words, limit=48):
        """The last three words: every way of cutting them, each piece with its rhymes."""
        words = [w for w in words if WORD.fullmatch(w)][-3:]
        if not words:
            return {"words": [], "splits": []}
        self.ph.guess(words)
        n = len(words)
        cuts = []
        for mask in range(1 << (n - 1)):
            pieces, start = [], 0
            for i in range(n - 1):
                if mask & (1 << i):
                    pieces.append((start, i + 1))
                    start = i + 1
            pieces.append((start, n))
            cuts.append(pieces)
        # the whole phrase first, then fewer pieces before more
        cuts.sort(key=lambda pieces: (len(pieces), [-(b - a) for a, b in pieces]))
        spans = {}
        splits = []
        for pieces in cuts:
            split = []
            for a, b in pieces:
                if (a, b) not in spans:
                    spans[(a, b)] = self.rhymes(words[a:b], limit)
                split.append({"from": a, "to": b, "text": " ".join(words[a:b])})
            splits.append(split)
        return {"words": words, "splits": splits,
                "spans": [{"from": a, "to": b, **found} for (a, b), found in spans.items()]}

    def rhymes(self, words, limit=48):
        key = (tuple(normal(w) for w in words), limit)
        if key in self.cache:
            return self.cache[key]
        found = self.find(words, limit)
        if len(self.cache) > 600:
            self.cache.clear()
        self.cache[key] = found
        return found

    def find(self, words, limit):
        ph = self.ph
        pron = self.phrase_pron(words)
        if not pron:
            return {"syllables": 0, "known": False, "groups": []}
        own = {normal(w) for w in words}
        last = normal(words[-1])
        vs = tuple(base(v) for v in vowels_of(pron))
        n = len(vs)
        end = coda(pron)
        target_tail = tail(pron)
        groups = []

        def rank(word):
            return ph.usage(word)

        def fits(word):
            return word not in own and not word.endswith(last) or (word not in own and len(last) <= 2)

        # perfect: the same from the last stressed vowel on
        perfect = [w for w in self.by_tail.get(target_tail, []) if fits(w)]
        perfect.sort(key=lambda w: (abs(syllables(ph.pron(w)) - n) if len(words) > 1 else 0, rank(w)))
        perfect = perfect[:limit]
        if len(words) == 1:
            groups.append({"kind": "perfect", "items": [self.item(w) for w in perfect]})

        # multi: every vowel of the phrase, one word or two
        if n >= 2:
            multi = []
            taken = set()
            for word in self.by_vowels.get(vs[-MAX_VOWELS:], [])[:1500]:
                p = ph.pron(word)
                if not fits(word) or len(vowels_of(p)) > n + 1:
                    continue
                multi.append((self.score(p, pron) + rank(word) / 9000, word))
                taken.add(word)
            pairs = []
            for cut in range(1, n):
                first = [w for w in self.by_vowels.get(vs[:cut], [])[:80] if w not in own and w not in FILLER and rank(w) < 12000]
                second = [w for w in self.by_whole.get(vs[cut:], []) if w not in own and w not in FILLER and rank(w) < 15000]
                second = sorted(second[:400], key=lambda w: (coda(ph.pron(w)) != end, coda_class(coda(ph.pron(w))) != coda_class(end), w in STOP, rank(w)))[:16]
                first.sort(key=lambda w: (w in STOP, rank(w)))
                for a in first[:18]:
                    pa = ph.pron(a)
                    # the first word's last vowel stressed where the phrase's is
                    if stresses(pa)[-1:] == [0] and stresses(pron)[cut - 1] != 0:
                        continue
                    for b in second:
                        p = pa + ph.pron(b)
                        if a in STOP and b in STOP:
                            continue
                        pairs.append((self.score(p, pron) + (rank(a) + rank(b)) / 5000 + 0.6 + 0.45 * ((a in STOP) + (b in STOP)), f"{a} {b}"))
            # word for word: each word of the phrase swapped for one with its vowels and a like end
            if 2 <= len(words) <= 3:
                options = []
                for i, word in enumerate(words):
                    p = ph.pron(word)
                    if normal(word) in STOP:
                        options.append([normal(word)])
                        continue
                    last_word = i == len(words) - 1
                    wv = tuple(base(v) for v in vowels_of(p))
                    found = [w for w in self.by_whole.get(wv, [])[:3000] if w not in FILLER and w not in STOP and rank(w) < 20000 and w != normal(word)]
                    found.sort(key=lambda w: (last_word and tail(ph.pron(w)) != tail(p), coda(ph.pron(w)) != coda(p), coda_class(coda(ph.pron(w))) != coda_class(coda(p)), rank(w)))
                    options.append(found[:5] or [normal(word)])
                combos = [[]]
                for choice in options:
                    combos = [c + [w] for c in combos for w in choice]
                for combo in combos:
                    if [normal(w) for w in words] == combo or sum(a == normal(b) for a, b in zip(combo, words)) == len(words) - 0:
                        continue
                    p = self.phrase_pron(combo)
                    pairs.append((self.score(p, pron) + sum(rank(w) for w in combo) / 9000 + 0.1, " ".join(combo)))
            pairs.sort()
            used = defaultdict(int)
            for score, phrase in pairs:
                parts = phrase.split(" ")
                if any(used[w] >= 3 for w in parts if w not in STOP):
                    continue
                for w in parts:
                    used[w] += 1
                multi.append((score, phrase))
            multi.sort()
            seen = set()
            items = []
            for _, text in multi:
                if text in seen:
                    continue
                seen.add(text)
                items.append(self.item(text))
                if len(items) >= limit:
                    break
            if len(words) == 1:
                same = set(perfect)
                items = [i for i in items if i["text"] not in same]
            groups.insert(0, {"kind": "multi", "items": items})

        # near: the same stressed vowel, an end that sounds alike
        if len(words) == 1 or n <= 2:
            near = self.near(pron, own, perfect, limit)
            groups.append({"kind": "near", "items": [self.item(w) for w in near]})

        # yours: from the user's songs and ideas
        mine = []
        for entry in self.own.get(vs[-MAX_VOWELS:], []) if n else []:
            if entry["text"] in {" ".join(normal(w) for w in words)}:
                continue
            closeness = (entry["coda"] != end) + (coda_class(entry["coda"]) != coda_class(end))
            mine.append((closeness, entry["text"], entry["song"]))
        mine.sort()
        if mine:
            groups.append({"kind": "yours", "items": [{"text": t, "syllables": n, "song": s} for _, t, s in mine[:limit]]})
        return {"syllables": n, "known": all(ph.prons(w) for w in words), "vowels": list(vs), "groups": [g for g in groups if g["items"]]}

    def near(self, pron, own, perfect, limit):
        ph = self.ph
        t = tail(pron)
        if not t:
            return []
        stressed = t[0]
        rest = t[1:]
        rest_vowels = tuple(p for p in rest if p in ("AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"))
        shape = coda_class(tuple(p for p in rest if p not in rest_vowels))
        found = []
        skip = set(perfect)
        for word in self.by_vowels.get((stressed,) + rest_vowels, [])[:4000]:
            if word in skip or word in own:
                continue
            p = ph.pron(word)
            wt = tail(p)
            if not wt or wt[0] != stressed or wt == t:
                continue
            w_rest = wt[1:]
            w_vowels = tuple(x for x in w_rest if x in rest_vowels or vowel(x + "0") and x in ("AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"))
            if w_vowels != rest_vowels:
                continue
            w_shape = coda_class(tuple(x for x in w_rest if x not in w_vowels))
            distance = 0 if w_shape == shape else 1 if len(w_shape) == len(shape) or abs(len(w_shape) - len(shape)) == 1 and (set(w_shape) <= set(shape) or set(shape) <= set(w_shape)) else 3
            if distance > 1:
                continue
            found.append((distance, ph.usage(word), word))
        found.sort()
        return [w for _, _, w in found[:limit]]

    def score(self, candidate, target) -> float:
        """How alike two phrases with the same vowels sound: 0 is the same, more is further."""
        def cuts(pron):
            out, current = [], []
            for p in pron:
                if vowel(p):
                    out.append(tuple(current))
                    current = []
                else:
                    current.append(p)
            out.append(tuple(current))
            return out
        a, b = cuts(candidate), cuts(target)
        # line them up from the end
        a, b = a[-len(b):] if len(a) >= len(b) else [()] * (len(b) - len(a)) + a, b
        total = 0.0
        for i, (x, y) in enumerate(zip(a, b)):
            weight = 2.2 if i == len(b) - 1 else 0.5 if i == 0 else 0.8
            if x == y:
                continue
            if coda_class(x) == coda_class(y):
                total += 0.35 * weight
            elif set(x) & set(y):
                total += 0.6 * weight
            else:
                total += 1.0 * weight
        # stress where the phrase has it
        if stresses(candidate)[-len(stresses(target)):] != stresses(target):
            total += 0.3
        return total

    def item(self, text):
        words = text.split(" ")
        pron = self.phrase_pron(words)
        return {"text": text, "syllables": syllables(pron) if pron else 0}

    # ── the text ─────────────────────────────────────────────────────────
    def analyze(self, text: str, window: int = 4) -> dict:
        """Syllables, stresses, the rhyme scheme and which words rhyme, line by line.

        Words are given by their place in the line (start, end in characters),
        with the group they rhyme in; a group of a multi covers several words."""
        lines = text.split("\n")
        tokens = [[(m.start(), m.end(), m.group(0)) for m in WORD.finditer(line)] for line in lines]
        self.ph.guess({t[2] for row in tokens for t in row})
        sections = []
        out_lines = []
        heads = {}
        section_of = []
        current = -1
        for i, line in enumerate(lines):
            head = re.fullmatch(r"\s*\[([^\]]+)\]\s*", line)
            if head:
                name = head.group(1).strip()
                key = re.sub(r"\s*\d+$", "", name).lower()
                body_empty = all(not l.strip() or re.fullmatch(r"\s*\[[^\]]+\]\s*", l) for l in lines[i + 1:next((j for j in range(i + 1, len(lines)) if re.fullmatch(r"\s*\[[^\]]+\]\s*", lines[j])), len(lines))])
                ref = heads.get(name.lower()) if body_empty else None
                if not body_empty and name.lower() not in heads:
                    heads[name.lower()] = i
                current = len(sections)
                sections.append({"line": i, "name": name, "kind": key, "ref": ref})
            section_of.append(current)

        # every word: how it sounds
        info = []
        for i, row in enumerate(tokens):
            header = bool(re.fullmatch(r"\s*\[([^\]]+)\]\s*", lines[i]))
            items = []
            for start, end, word in ([] if header else row):
                pron = self.ph.pron(word)
                items.append({"s": start, "e": end, "w": normal(word).strip("'"), "pron": pron})
            info.append(items)

        # single words: the same rhyming part, a few lines apart, not the same word
        parent = {}

        def find(x):
            while parent.setdefault(x, x) != x:
                parent[x] = parent[parent[x]]
                x = parent[x]
            return x

        def join(a, b):
            ra, rb = find(a), find(b)
            if ra != rb:
                parent[max(ra, rb)] = min(ra, rb)

        by_key = defaultdict(list)
        for i, items in enumerate(info):
            for j, item in enumerate(items):
                if not item["pron"]:
                    continue
                at_end = j == len(items) - 1
                if item["w"] in STOP and not at_end:
                    continue
                by_key[tail(item["pron"])].append((i, j))
        for key, places in by_key.items():
            for x in range(len(places)):
                for y in range(x + 1, len(places)):
                    (i1, j1), (i2, j2) = places[x], places[y]
                    if i2 - i1 > window:
                        break
                    if info[i1][j1]["w"] != info[i2][j2]["w"] and section_of[i1] == section_of[i2]:
                        join(("w", i1, j1), ("w", i2, j2))

        # multis: the same vowels over two or more syllables, ending on a stressed one
        multi = {}
        grams = defaultdict(list)
        for i, items in enumerate(info):
            stream = []
            for j, item in enumerate(items):
                for p in item["pron"]:
                    if vowel(p):
                        stream.append((p, j))
                if not item["pron"] or not stream or stream[-1][1] != j:
                    continue
                # the vowels before the end of word j
                for k in range(2, MAX_VOWELS + 1):
                    if len(stream) < k:
                        break
                    piece = stream[-k:]
                    strong = [p for p, _ in piece if p not in WEAK]
                    if len(strong) < 2 or piece[-1][0].endswith("0") and len(piece) == 2:
                        continue
                    grams[tuple(base(p) for p, _ in piece)].append((i, piece[0][1], j, k))
        spans = []
        for gram, places in grams.items():
            if len(places) < 2:
                continue
            for x in range(len(places)):
                for y in range(x + 1, len(places)):
                    a, b = places[x], places[y]
                    if b[0] - a[0] > window or section_of[a[0]] != section_of[b[0]]:
                        continue
                    if a[0] == b[0] and not (a[2] < b[1] or b[2] < a[1]):
                        continue
                    ta = " ".join(info[a[0]][m]["w"] for m in range(a[1], a[2] + 1))
                    tb = " ".join(info[b[0]][m]["w"] for m in range(b[1], b[2] + 1))
                    if ta == tb:
                        continue
                    spans.append((len(gram), a, b, gram))
        spans.sort(key=lambda s: -s[0])
        covered = {}
        for k, a, b, gram in spans:
            for place in (a, b):
                words = [(place[0], m) for m in range(place[1], place[2] + 1)]
                if any(w in covered and covered[w][0] > k for w in words):
                    continue
                for w in words:
                    covered[w] = (k, ("g", gram, place[0], place[1]))
            join(("m", gram), ("m", gram))
            multi[(a[0], a[1], a[2])] = gram
            multi[(b[0], b[1], b[2])] = gram
        # the multis of one vowel sequence are one group; their words join it
        for (i, j1, j2), gram in multi.items():
            for m in range(j1, j2 + 1):
                if covered.get((i, m), (0, None))[1] is not None and covered[(i, m)][0] == len(gram):
                    join(("m", gram), ("w", i, m))

        spelled = defaultdict(set)
        for node in list(parent):
            if node[0] == "w":
                spelled[find(node)].add(info[node[1]][node[2]]["w"])
        groups = {}
        order = []
        for i, items in enumerate(info):
            for j in range(len(items)):
                node = ("w", i, j)
                if node not in parent:
                    continue
                root = find(node)
                if root not in groups:
                    if len(spelled[root]) < 2:
                        groups[root] = -1
                    else:
                        groups[root] = len(order)
                        order.append(root)

        # how often a word that means something comes back
        counts = defaultdict(int)
        for i, items in enumerate(info):
            if sections and section_of[i] >= 0 and sections[section_of[i]]["ref"] is not None:
                continue
            for item in items:
                if item["w"] not in STOP and len(item["w"]) > 2:
                    counts[item["w"]] += 1

        letter_of = {}
        for i, items in enumerate(info):
            syllable_count = 0
            stress = []
            words_out = []
            for j, item in enumerate(items):
                pron = item["pron"]
                n = syllables(pron) if pron else 1
                syllable_count += n
                marks = stresses(pron) if pron else [1]
                if n == 1 and item["w"] in STOP:
                    marks = [0]
                stress += marks
                node = ("w", i, j)
                group = groups.get(find(node), -1) if node in parent else -1
                entry = {"s": item["s"], "e": item["e"], "n": n}
                if group >= 0:
                    entry["g"] = group
                    if (i, j) in covered:
                        k, span = covered[(i, j)]
                        entry["m"] = f"{span[2]}:{span[3]}"
                if counts.get(item["w"], 0) >= 3:
                    entry["r"] = counts[item["w"]]
                if not pron:
                    entry["u"] = 1
                words_out.append(entry)
            scheme = ""
            if items:
                last = ("w", i, len(items) - 1)
                group = groups.get(find(last), -1) if last in parent else -1
                section = section_of[i]
                key = (section, group if group >= 0 else ("solo", i))
                if key not in letter_of:
                    letter_of[key] = letters(sum(1 for k in letter_of if k[0] == section))
                scheme = letter_of[key]
            out_lines.append({"t": lines[i], "syl": syllable_count if items else 0, "stress": "".join(str(min(s, 1)) for s in stress), "scheme": scheme, "words": words_out})
        # the same word at the end of two lines of one section rhymes with itself
        ends = defaultdict(list)
        for i, items in enumerate(info):
            if items:
                ends[(section_of[i], items[-1]["w"])].append(i)
        for (section, word), rows in ends.items():
            if len(rows) > 1 and word not in STOP:
                for i in rows:
                    out_lines[i]["self"] = 1
        return {"lines": out_lines, "sections": sections, "groups": len(order)}
