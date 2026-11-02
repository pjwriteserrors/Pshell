"""Character sheets: what is known about the people of a series, and only what can
be proved. No state and no network in here.

A weak model cannot be handed a whole show. So the work is cut into small questions:
the names come from the descriptions without any model where possible, and each
field of each character is one question over a few lines found by search. No lines,
no question. Every answer has to bring its quote, the quote has to stand in those
lines, and the answer has to stand in the quote. What fails this is thrown away: an
empty field is better than an invented one.
"""
import difflib
import re

_HANDLE = r"@[\w.-]+"
CAST_LINE = re.compile(rf"^\s*(?P<name>[^\n:@|]{{2,40}}?)\s*(?:[-–—:|]|\bas\b|\bplayed by\b)\s*(?P<player>{_HANDLE})\s*$", re.I | re.M)
NOT_A_CHARACTER = re.compile(r"assets|battlemap|\bmap\b|dungeon master|game master|\bdm\b|\bgm\b|producer|edited|editor|sound|camera|art|music|logo|host|crew|cast|thumbnail|manager|director|design|writer|animat", re.I)


def _field(name, label, kind="text", words=(), ask=""):
    # being named next to somebody says nothing about being their friend or enemy
    careful = name in ("allies", "enemies", "goals", "traits")
    return {"id": name, "label": label, "kind": kind, "words": list(words), "ask": ask or f"What is {{name}}'s {label.lower()}?", "careful": careful}


TEMPLATES = {
    "dnd": {
        "label": "Tabletop character",
        "sections": [
            {"title": "Who", "kind": "facts", "fields": [
                _field("race", "Race", words=("race", "half", "elf", "dwarf", "human", "orc", "goblin", "triton", "tiefling", "genasi", "gnome", "halfling", "dragonborn")),
                _field("class", "Class", words=("class", "barbarian", "bard", "cleric", "druid", "fighter", "monk", "paladin", "ranger", "rogue", "sorcerer", "warlock", "wizard", "artificer")),
                {**_field("level", "Level", "number", ("level", "leveled", "levelled")), "most": 20},
                _field("role", "Role", words=("captain", "first mate", "crew", "quartermaster", "navigator", "cook")),
            ]},
            {"title": "Numbers", "kind": "stats", "fields": [
                {**_field("hp", "Hit points", "number", ("hit points", "hp", "health"), "How many hit points does {name} have?"), "most": 500},
                {**_field("ac", "Armor class", "number", ("armor class", "ac"), "What is {name}'s armor class?"), "most": 40},
                {**_field("str", "STR", "number", ("strength",), "What is {name}'s strength score or modifier?"), "most": 30},
                {**_field("dex", "DEX", "number", ("dexterity",), "What is {name}'s dexterity score or modifier?"), "most": 30},
                {**_field("con", "CON", "number", ("constitution",), "What is {name}'s constitution score or modifier?"), "most": 30},
                {**_field("int", "INT", "number", ("intelligence",), "What is {name}'s intelligence score or modifier?"), "most": 30},
                {**_field("wis", "WIS", "number", ("wisdom",), "What is {name}'s wisdom score or modifier?"), "most": 30},
                {**_field("cha", "CHA", "number", ("charisma",), "What is {name}'s charisma score or modifier?"), "most": 30},
            ]},
            {"title": "Can do", "kind": "lists", "fields": [
                _field("abilities", "Abilities", "list", ("ability", "feature", "feat", "rage", "sneak attack", "action surge"), "Which abilities or features does {name} use?"),
                _field("spells", "Spells", "list", ("spell", "cast", "cantrip"), "Which spells does {name} cast?"),
                _field("items", "Items", "list", ("sword", "axe", "bow", "staff", "armor", "ring", "potion", "item", "weapon"), "Which items or weapons does {name} have?"),
            ]},
            {"title": "Around them", "kind": "lists", "fields": [
                _field("allies", "Allies", "list", ("friend", "ally", "brother", "sister", "father", "mother", "crew"), "Who are {name}'s friends or family?"),
                _field("goals", "Goals", "list", ("want", "goal", "promise", "revenge", "looking for", "need to"), "What does {name} want to achieve?"),
            ]},
        ],
    },
    "minecraft": {
        "label": "Minecraft",
        "sections": [
            {"title": "Who", "kind": "facts", "fields": [
                _field("role", "Role", words=("player", "friend", "mob", "boss", "villager")),
                _field("mod", "Mod or modpack", words=("mod", "modpack", "pack"), ask="Which mod or modpack is {name} playing?"),
                _field("base", "Base", words=("base", "house", "home", "bunker"), ask="Where is {name}'s base?"),
            ]},
            {"title": "Numbers", "kind": "stats", "fields": [
                _field("deaths", "Deaths", "number", ("died", "death", "deaths"), "How many times has {name} died?"),
                _field("days", "Days", "number", ("day", "days"), "How many days has {name} survived?"),
                _field("xp", "Level", "number", ("level", "levels", "xp"), "What experience level is {name}?"),
            ]},
            {"title": "Has", "kind": "lists", "fields": [
                _field("gear", "Gear", "list", ("diamond", "netherite", "iron", "sword", "armor", "pickaxe", "shield", "elytra", "bow"), "What gear does {name} have?"),
                _field("found", "Found", "list", ("found", "portal", "dimension", "nether", "end", "structure"), "Which important places or things has {name} found?"),
                _field("enemies", "Enemies", "list", ("stalk", "chase", "kill", "monster", "entity", "boss"), "Which monsters or enemies hunt {name}?"),
            ]},
        ],
    },
    "game": {
        "label": "Game character",
        "sections": [
            {"title": "Who", "kind": "facts", "fields": [
                _field("game", "Game", words=("game", "playing")),
                _field("role", "Role", words=("role", "class", "player")),
                _field("rank", "Level or rank", words=("level", "rank")),
            ]},
            {"title": "Has", "kind": "lists", "fields": [
                _field("gear", "Gear", "list", ("weapon", "gun", "armor", "item", "upgrade"), "What gear or items does {name} use?"),
                _field("skills", "Skills", "list", ("ability", "skill", "power"), "Which abilities does {name} use?"),
                _field("enemies", "Enemies", "list", ("enemy", "boss", "kill", "fight"), "Who does {name} fight?"),
            ]},
        ],
    },
    "story": {
        "label": "Person",
        "sections": [
            {"title": "Who", "kind": "facts", "fields": [
                _field("role", "Role", words=("is a", "works", "job", "leader", "captain")),
                _field("from", "From", words=("from", "born", "home")),
            ]},
            {"title": "Around them", "kind": "lists", "fields": [
                _field("traits", "Traits", "list", ("always", "never", "loves", "hates", "afraid"), "What is {name} like?"),
                _field("allies", "People", "list", ("friend", "brother", "sister", "father", "mother", "wife", "husband"), "Who is close to {name}?"),
                _field("goals", "Goals", "list", ("want", "goal", "promise", "looking for"), "What does {name} want?"),
            ]},
        ],
    },
}

_HINTS = {
    "dnd": re.compile(r"\b(d&d|dnd|dungeons? (and|&) dragons|tabletop|pathfinder|campaign|dungeon master|one[- ]?shot|critical role|just roll with it)\b", re.I),
    "minecraft": re.compile(r"\b(minecraft|modpack|hardcore smp|smp)\b", re.I),
    "game": re.compile(r"\b(gameplay|let'?s play|playthrough|walkthrough|resident evil|roblox|fortnite|siege|elden ring)\b", re.I),
}


def choose_template(texts):
    """Which kind of sheet a series needs, by how it talks about itself."""
    text = "\n".join(text or "" for text in texts)
    scores = {name: len(pattern.findall(text)) for name, pattern in _HINTS.items()}
    best = max(scores, key=scores.get)
    return best if scores[best] > 0 else "story"


def cast_from(descriptions):
    """Names and who plays them, from lists in the descriptions. {name: player}"""
    counts, players = {}, {}
    for text in descriptions:
        for found in CAST_LINE.finditer(text or ""):
            name = found.group("name").strip(" -–—:*•")
            if NOT_A_CHARACTER.search(name) or len(name.split()) > 5:
                continue
            counts[name] = counts.get(name, 0) + 1
            players[name] = found.group("player")
    return {name: players[name] for name, _ in sorted(counts.items(), key=lambda item: -item[1])}


def field_of(template, field_id):
    for section in TEMPLATES[template]["sections"]:
        for field in section["fields"]:
            if field["id"] == field_id:
                return field
    return None


def short_names(name):
    """A character is rarely called by the whole name: "Gillion Tidestrider", "Gillion"."""
    parts = [part for part in re.findall(r"[^\W\d_]{3,}", name)]
    return [name, *parts] if len(parts) > 1 else [name]


def question(name, field, lines):
    """As short as it can be: a weak model gets lost in long prompts."""
    text = "\n".join(line["text"] for line in lines)
    ask = field["ask"].replace("{name}", name)
    if field["kind"] == "list":
        shape = '{"items":[{"value":"short name","quote":"exact words copied from the text"}]} (at most 4 items, or {"items":[]} if the text does not say)'
    else:
        shape = '{"value":"short answer","quote":"exact words copied from the text"} (or {"value":null,"quote":null} if the text does not say)'
    return (f"Subtitles from a show:\n---\n{text}\n---\nQuestion: {ask}\n"
            f"Use only the subtitles, never your own knowledge. Most of the time they do not say: then answer with null.\nReply with JSON only: {shape}")


SCHEMA_ONE = {"type": "object", "properties": {"value": {"type": ["string", "null"]}, "quote": {"type": ["string", "null"]}}, "required": ["value", "quote"]}
SCHEMA_LIST = {"type": "object", "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {"value": {"type": "string"}, "quote": {"type": "string"}}, "required": ["value", "quote"]}}}, "required": ["items"]}


def _words(text):
    return re.findall(r"[^\W_]+", (text or "").lower())


def find_quote(quote, lines):
    """The line a quote comes from, or None: nearly word for word, since subtitles
    and models both drop a word here and there."""
    wanted = _words(quote)
    if len(wanted) < 3:
        return None
    for line in lines:
        have = _words(line["text"])
        matcher = difflib.SequenceMatcher(None, wanted, have, autojunk=False)
        size = sum(block.size for block in matcher.get_matching_blocks())
        if size / len(wanted) >= 0.85:
            return line
    return None


def aliases(name, vocabulary):
    """How subtitles spell a name: automatic ones write "Gillian" for "Gillion". From
    the words that really occur, close to the name and with the same first letter.
    vocabulary: {word: how often}"""
    out = {part.lower() for part in short_names(name) if " " not in part}
    if " " not in name:
        out.add(name.lower())
    for part in list(out):
        for word in difflib.get_close_matches(part, vocabulary, 5, 0.8):
            if word[0] == part[0] and vocabulary[word] >= 3 and word not in COMMON_WORDS:
                out.add(word)
    # a first name that is also just a word needs the whole name's other part to be sure
    return sorted(word for word in out if vocabulary.get(word, 0) > 0)


COMMON_WORDS = set("""million billion friend friends ship shop chop clip chips hips whip""".split())


def judge(value, quote, kind, lines, names, field=None):
    """(line, state) of an answer or None. Standing in the text makes it worth keeping
    ("maybe"); naming the character in the same breath makes it "sure". "You get another
    13 health" is said, but not about anyone in particular."""
    line = checked(value, quote, kind, lines)
    if not line:
        return None
    if field and field.get("most") and kind == "number":
        number = abs(int(re.findall(r"\d+", str(value))[0]))
        if number > field["most"]:
            return None
    named = {word.lower() for word in names}
    words = set(_words(value))
    # nobody is their own friend
    if words and words <= named:
        return None
    # "a natural 20" is a die, not intelligence: a number has to come with what it counts
    if field and kind == "number" and field.get("words"):
        spoken = " ".join(_words(quote))
        if not any(word.lower() in spoken for word in field["words"]):
            return None
    # an answer is a name or a few words; a whole clause was not understood
    if kind != "number" and len(_words(value)) > 5:
        return None
    # "you'd look great as a Triton Chip": a name inside the answer is mostly talk
    if words & named:
        return line, "maybe"
    if field and field.get("careful"):
        return line, "maybe"
    return line, "sure" if named & set(_words(quote)) else "maybe"


def checked(value, quote, kind, lines, name=""):
    """Whether an answer holds. A number has to stand in its quote as a number, any
    other answer word for word. Returns the line it came from, or None."""
    if not value or not quote or str(value).strip().lower() in ("null", "none", "unknown", "n/a"):
        return None
    line = find_quote(quote, lines)
    if not line:
        return None
    said = set(_words(quote))
    if kind == "number":
        numbers = re.findall(r"[+-]?\d+", str(value))
        if not numbers or numbers[0].lstrip("+-") not in said:
            return None
        return line
    answer = [word for word in _words(value) if len(word) > 2 and word not in ("the", "and", "with")]
    if not answer or not all(word in said for word in answer):
        return None
    # "Gillion is a bard" says it; a quote that is about nobody in particular does not
    if name and not set(_words(" ".join(short_names(name)))) & said and len(said) > 14:
        return None
    return line
