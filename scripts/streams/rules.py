"""What belongs to a series: pure functions, no network and no database.

A rule is {title: [..], desc: [..], not: [..], minMinutes, maxMinutes,
noShorts, since, trust}. A word starting with "re:" is a regular expression. The
lines a channel puts under every video are taken out of the descriptions
first, and a word most of a channel's videos have says little: such a hit
is only a "maybe", which waits for the user's answer (unless the rule trusts
its words).
"""
import collections
import json
import re

# a line in this share of a channel's descriptions is its footer
FOOTER_SHARE = 0.6
# a word in more than this share of the videos cannot decide alone; a phrase of
# several words names something and may stand in far more of them
WEAK_SHARE = 0.4
WEAK_SHARE_PHRASE = 0.75
# too few descriptions to tell what a footer is
FOOTER_MIN = 5


def _line_key(line):
    return re.sub(r"\s+", " ", line).strip().lower()


def footer_lines(descriptions):
    """The lines that stand in most of these descriptions."""
    filled = [text for text in descriptions if text]
    if len(filled) < FOOTER_MIN:
        return set()
    counts = collections.Counter()
    for text in filled:
        counts.update({_line_key(line) for line in text.splitlines() if _line_key(line)})
    return {line for line, count in counts.items() if count / len(filled) > FOOTER_SHARE}


def clean(text, footer):
    if not text or not footer:
        return text or ""
    return "\n".join(line for line in text.splitlines() if _line_key(line) not in footer)


def has(text, word):
    if not text or not word:
        return False
    if word.startswith("re:"):
        try:
            return re.search(word[3:], text, re.I) is not None
        except re.error:
            return False
    # whole words: "ep" is no hit in "deep"; quotes do not count, so
    # 'I Play Your Gifts' finds 'I Play Your "Gifts"'
    text, word = QUOTES.sub("", text), QUOTES.sub("", word)
    return bool(word.strip()) and re.search(r"(?<!\w)" + re.escape(word) + r"(?!\w)", text, re.I) is not None


QUOTES = re.compile(r"[\"“”„«»]")


def words_of(rule):
    return list(rule.get("title") or []), list(rule.get("desc") or []), list(rule.get("not") or [])


def shares(videos, rule, footer):
    """How many of the videos have each word, anywhere, as a share of them."""
    title, desc, _ = words_of(rule)
    total = max(1, len(videos))
    return {word: sum(1 for video in videos if has(video.get("title"), word) or has(clean(video.get("description"), footer), word)) / total for word in set(title + desc)}


def passes_limits(video, rule):
    """(passes, why not)"""
    if rule.get("noShorts", True) and video.get("kind") == "short":
        return False, "A short"
    since = rule.get("since") or 0
    if since and (video.get("published") or 0) < since:
        return False, "From before the start date"
    duration = video.get("duration") or 0
    if duration:
        low, high = rule.get("minMinutes") or 0, rule.get("maxMinutes") or 0
        if low and duration < low * 60:
            return False, f"Shorter than {low} min"
        if high and duration > high * 60:
            return False, f"Longer than {high} min"
    return True, ""


def weak_limit(word):
    return WEAK_SHARE_PHRASE if " " in word.strip() else WEAK_SHARE


def classify(video, rule, footer, word_shares, in_playlist=False):
    """{state: "sure" | "maybe" | "none", why}"""
    text = clean(video.get("description"), footer)
    title, desc, exclude = words_of(rule)
    for word in exclude:
        if has(video.get("title"), word) or has(text, word):
            return {"state": "none", "why": f'Left out by "{word}"'}
    good, why = passes_limits(video, rule)
    if not good:
        return {"state": "none", "why": why}
    if in_playlist:
        return {"state": "sure", "why": "In the playlist"}
    if rule.get("match") == "all":
        return classify_all(video, rule, text, title, desc)
    hits = [(word, "title") for word in title if has(video.get("title"), word)]
    wanted_tags = [tag.lower() for tag in rule.get("tags") or []]
    if wanted_tags:
        own = {tag.lower().strip() for tag in tags_of(video)}
        for tag in wanted_tags:
            if tag in own:
                return {"state": "sure", "why": f'Tagged "{tag}"'}
    hits += [(word, "description") for word in desc if has(text, word)]
    if not hits:
        if (video.get("description") is None and desc) or (wanted_tags and not video.get("enriched")):
            return {"state": "none", "why": "Description not loaded yet"}
        return {"state": "none", "why": "No keyword found"}
    if rule.get("trust"):
        return {"state": "sure", "why": f'"{hits[0][0]}" in the {hits[0][1]}'}
    strong = [hit for hit in hits if word_shares.get(hit[0], 0) <= weak_limit(hit[0])]
    if strong:
        return {"state": "sure", "why": f'"{strong[0][0]}" in the {strong[0][1]}'}
    # a word in the title of a series is what the user asked for by name
    in_title = [hit for hit in hits if hit[1] == "title"]
    if in_title:
        return {"state": "sure", "why": f'"{in_title[0][0]}" in the title'}
    word, where = hits[0]
    return {"state": "maybe", "why": f'"{word}" in the {where}, but in {round(word_shares.get(word, 0) * 100)} % of all videos'}


def classify_all(video, rule, text, title, desc):
    """Every word asked for has to be there. So many together are specific enough
    that a common word among them makes nothing a "maybe"."""
    for word in title:
        if not has(video.get("title"), word):
            return {"state": "none", "why": f'"{word}" is not in the title'}
    if desc and video.get("description") is None:
        return {"state": "none", "why": "Description not loaded yet"}
    for word in desc:
        if not has(text, word):
            return {"state": "none", "why": f'"{word}" is not in the description'}
    wanted_tags = [tag.lower() for tag in rule.get("tags") or []]
    if wanted_tags:
        if not video.get("enriched"):
            return {"state": "none", "why": "Description not loaded yet"}
        own = {tag.lower().strip() for tag in tags_of(video)}
        for tag in wanted_tags:
            if tag not in own:
                return {"state": "none", "why": f'Not tagged "{tag}"'}
    every = [*title, *desc, *wanted_tags]
    if not every:
        return {"state": "none", "why": "No keyword found"}
    return {"state": "sure", "why": "Has all of " + ", ".join(f'"{word}"' for word in every[:4])}


NUMBER = [
    re.compile(r"\b(?:episode|episodes|folge|ep|teil|part|pt|chapter|kapitel)\.?\s*#?\s*(\d{1,4})\b", re.I),
    re.compile(r"(?:^|\s)#(\d{1,4})\b"),
    re.compile(r"\bs\d{1,2}\s*e(\d{1,4})\b", re.I),
    re.compile(r"[\[(](\d{1,4})[\])]"),
]


def episode_number(title):
    for pattern in NUMBER:
        found = pattern.search(title or "")
        if found:
            return int(found.group(1))
    return None


def order(videos, mode="auto"):
    """Oldest episode first. By the numbers in the titles only when (nearly)
    all have one and they do not repeat; a series whose titles have none, or
    only some, goes by date."""
    by_date = sorted(videos, key=lambda video: (video.get("published") or 0, video.get("id")))
    if mode == "date" or not videos:
        return by_date
    numbers = [episode_number(video.get("title")) for video in videos]
    known = [number for number in numbers if number is not None]
    if len(known) < 0.8 * len(videos) or len(set(known)) != len(known):
        return by_date
    # those without a number stay where their date puts them
    last = {"n": 0}
    keyed = []
    for video in by_date:
        number = episode_number(video.get("title"))
        if number is None:
            number = last["n"] + 0.5
        else:
            last["n"] = number
        keyed.append((number, video.get("published") or 0, video))
    keyed.sort(key=lambda entry: entry[:2])
    return [entry[2] for entry in keyed]


STOP = set("""a an and are as at be but by for from has have i in is it its me my of on or our so that the this to was we were what
when where who why will with you your der die das und oder ein eine einer im in ist mit von zu zum zur auf aus bei den dem des wir ich du er sie es
wie was wer nicht nur noch new video videos part teil episode folge ep official live stream full""".split())
_TOKEN = re.compile(r"[^\W\d_][\w'-]*", re.UNICODE)


def _phrases(text, longest=3):
    tokens = _TOKEN.findall((text or "").lower())
    out = set()
    for size in range(1, longest + 1):
        for i in range(len(tokens) - size + 1):
            chunk = tokens[i:i + size]
            if chunk[0] in STOP or chunk[-1] in STOP or len(" ".join(chunk)) < 4:
                continue
            out.add(" ".join(chunk))
    return out


# ── finding series nobody asked for ────────────────────────────────────────
NOISE = set("""subscribe patreon discord twitter instagram tiktok twitch merch merchandise sponsor sponsored link links follow
channel thanks thank watching support business email contact website shop store facebook download check
music song credits edited editor thumbnail abonnieren kanal danke like sub main album spotify vod vods https http www com
playlist full episode watch more wanna monday tuesday wednesday thursday friday saturday sunday january february march april june july
august september october november december werbung anzeige""".split())
GENERIC_PLAYLIST = re.compile(r"^(uploads?|popular|shorts?|favou?rites?|liked|live ?streams?|streams?|all videos|videos|new|latest|best of.*|highlights?|clips?|trailers?|music|vods?|archive)$", re.I)
# what names no series by itself: "Spoiler", "Stream Highlights", "Halloween Special"
GENERIC_NAME = set("""spoiler spoilers highlight highlights stream streams streamed vod vods clip clips trailer trailers teaser special specials
review reviews reaction reactions recap recaps livestream livestreams podcast uncut remastered preview announcement bonus edition
compilation compilations montage member members cut early access half baked official video videos update updates finale version
extended full gameplay halloween christmas weihnachten live shorts short reupload upload uploads moments best funny rewind outtakes
bloopers behind scenes faq intro outro teil part parts episode episodes folge folgen ep pt collection channel kanal zweitkanal
andere themen thema mehr start here hier einstieg""".split())
# a playlist named for a kind of video, not for what is in them
COLLECTION = {"trailers", "trailer", "clips", "clip", "highlights", "vods", "vod", "shorts", "moments", "compilations", "edits", "memes", "uploads", "streams", "livestreams"}
HASHTAG = re.compile(r"(?<![\w&])#([^\W\d_][\w]{2,})")
COMMON_TAGS = {"shorts", "short", "youtube", "gaming", "gameplay", "funny", "viral", "fyp", "letsplay", "lets play", "let's play", "live", "live stream", "vod", "stream"}
SEGMENT_SPLIT = re.compile(r"\s+[|｜•·–—-]\s+|\s*[|｜•·]\s*|:\s+|[\[\]()【】]")
# what marks an episode, taken out of a part of a title
EPISODE_MARK = re.compile(r"\b(?:episodes?|ep|eps|folgen?|teil|part|pt|chapter|kapitel|season|staffel|day|tag|s\d{1,2}\s*e\d{1,4})\b\.?\s*#?\s*\d*|#\s*\d+|\b\d+\b", re.I)
# who is along this time: "ft. Pokay", "(with Grizzly)", "w/ Shulk"
GUEST = re.compile(r"(?:^|\s)(?:ft|feat|featuring|w/)\.?\s.*$", re.I)
BRACKETS = re.compile(r"\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)")
BRACKETED = re.compile(r"\[[^\]]*\]|【[^】]*】|\((?:ft|feat|featuring|with|mit|w/)\b[^)]*\)", re.I)
# a number that counts the parts of one thing: "Pt. 2", "Teil 3", "[Part 1]"
RUN_NUMBER = re.compile(r"\b(?:part|pt|teil|ep|episode|folge|chapter|kapitel)\.?\s*#?\s*(\d{1,3})\b", re.I)
# how a title begins that names nothing: "I Tried", "How to", "Wir müssen"
STARTERS = set("""i i'm im i've we we're my our how why what when who can could should would will this that these those the a an is are was
it it's its you you're your if do does did don't every all they he she his her their there here me so just not never no best top most new
one first last some any let's lets wenn würdest würdet würde wäre wärst hättest hast habt kannst könnt sollte warum wie was wer wir ich du er sie es ist sind das der die den dem ein eine einer mein meine
unser unsere euer eure dieser diese dieses mit und""".split())


def tags_of(video):
    raw = video.get("tags")
    if not raw:
        return []
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return []
    return [str(tag) for tag in raw]


def bare_title(title):
    """A title without who is along and without labels in brackets."""
    return re.sub(r"\s+", " ", BRACKETED.sub(" ", title or "")).strip()


def _words(text):
    """All words, hyphens and quotes apart: "Mini-Podcast" is "mini", "podcast"."""
    return [word for word in re.split(r"[\W_]+", (text or "").lower()) if word]


def _generic(name, noise=True):
    return all(word in GENERIC_NAME or word in STOP or (noise and word in NOISE) or ORDINAL.match(word) for word in _words(name))


ORDINAL = re.compile(r"^\d+(?:st|nd|rd|th|\.)?$")


def _beyond_channel(name, channel):
    """What a name says besides the channel's name: "DougDoug Stream Clip" says
    "Stream Clip", which names nothing; "Mini-Podcast Jay & Arya" says "Mini"."""
    return " ".join(word for word in _words(name) if not _channelish(word, channel) and not _is_channel(word, channel))


def title_parts(title):
    """The parts of a title that could name something: (name, has a number)."""
    out = []
    for part in SEGMENT_SPLIT.split(title or ""):
        part = GUEST.sub("", (part or "")).strip(" .,!?-–—\"'“”„")
        if not part or part[0] in "+&":
            continue
        name = re.sub(r"\s+", " ", EPISODE_MARK.sub(" ", part)).strip(" .,!?:#-–—\"'“”„")
        name = QUOTES.sub("", name).strip()
        words = _TOKEN.findall(name.lower())
        # who is along this time names no series
        if words and words[0] in ("ft", "feat", "featuring", "with", "mit", "w"):
            continue
        if not words or len(words) > 6 or len(name) < 3 or all(word in STOP for word in words) or _generic(name):
            continue
        out.append((name, name != part))
    return out


URL = re.compile(r"\S+://\S+|www\.\S+|\S+\.(?:com|gg|tv|de|net|org|io|ly|me)\S*")
# names in running text: "Horror Minecraft", "From the Fog Reimagined"
PROPER = re.compile(r"\b[A-ZÄÖÜ][\w'’-]+(?:[ \t]+(?:(?:the|of|and|in|von|der|die|das|und)[ \t]+)?[A-ZÄÖÜ][\w'’-]+){1,4}")

# ── what a description says about its video ───────────────────────────────
SEPARATOR = re.compile(r"^[\W_]{3,}$")
# what is sold: a section or a paragraph that starts like this is an ad
SPONSOR = re.compile(r"(?:\b(?:werbung|anzeige|sponsor\w*|gesponsert|affiliate|rabatt|gutschein\w*|coupon|promo\w*|kickstarter|merch\w*|präsentiert|presented by|brought to you|free trial|kostenlos testen|use code|mit dem code)\b|\b\d+\s?%\s*(?:off|rabatt|auf)\b|\$\d)", re.I)
# who made it, not what it is about: "Slimecicle as Troy", "Thanks to Nick for editing", "Outro by:"
CREDIT = re.compile(r"""^\W*(?:@?[\w.'’-]+(?:\s+[\w.'’-]+){0,3}\s+as\s+\S
    |(?:thanks?|thank\s+you|shout\s?-?outs?|danke)\b.*\b(?:for|to|an|für)\b
    |(?:edited|editor|editing|thumbnail|music|song|art|artwork|animation|animated|co-?writer|written|writer|producer|produced|director|directed
       |camera|kamera|schnitt|mix|mixed|mastering|cover|character|intro|outro|composer|composed|theme|cast|crew)\b[^.!?]{0,40}[:\-–—]
    |.*\bby:)""", re.I | re.X)


def prose(text, footer=(), most=3):
    """The first lines of a description that talk about the video: without its
    footer, links, ads and credits. A name standing there was written for this
    video; one in the paragraph of a sponsor or in the cast list was not."""
    sections = [[]]
    for line in clean(text, footer).splitlines():
        line = line.strip()
        if line and SEPARATOR.match(line):
            sections.append([])
        else:
            sections[-1].append(line)
    for section in sections:
        paragraphs = [[]]
        for line in section:
            if line:
                paragraphs[-1].append(line)
            elif paragraphs[-1]:
                paragraphs.append([])
        paragraphs = [paragraph for paragraph in paragraphs if paragraph]
        # "*Werbung" over a section is the ad, however many paragraphs follow
        if not paragraphs or SPONSOR.search(paragraphs[0][0]):
            continue
        for paragraph in paragraphs:
            if SPONSOR.search(paragraph[0]):
                continue
            out = []
            for line in paragraph:
                if URL.search(line) or SPONSOR.search(line) or CREDIT.match(line) or line.endswith(":") or "►" in line or line.startswith("#"):
                    break
                out.append(line)
                if len(out) >= most:
                    break
            if out:
                return out
    return []


def _is_noise(phrase):
    return any(word in NOISE for word in phrase.lower().split())


def _compact(text):
    return re.sub(r"[\W_]+", "", (text or "").lower())


def _is_channel(phrase, channel):
    phrase, channel = phrase.lower().strip(), (channel or "").lower().strip()
    return bool(channel) and (phrase == channel or phrase in channel or channel in phrase)


def _channelish(word, channel):
    """A word of the channel's name, also inside one written together:
    "doug" in "DougDougDoug"."""
    compact = _compact(channel)
    return bool(compact) and len(word) >= 4 and word not in STOP and word in compact


def clean_playlist_name(title, channel):
    """Without the channel's name in front or behind: "Yumi: Roblox", "Stream Highlights | DougDoug"."""
    title = title or ""
    pattern = r"^\s*" + re.escape(channel or "") + r"\s*[:|\-–—]\s*"
    name = re.sub(pattern, "", title, flags=re.I).strip() or title
    pieces = re.split(r"\s*[|｜:–—]\s*|\s+-\s+", name)
    if len(pieces) > 1 and channel:
        named = [piece for piece in pieces if piece and not (_compact(piece) and (_compact(piece) in _compact(channel) or _compact(channel) in _compact(piece)))]
        if named and len(named) < len([piece for piece in pieces if piece]):
            name = " - ".join(named)
    return name.strip() or title


def _one_upload(videos):
    """The same video more than once: a member cut, early access, a re-upload.
    Recurring ones a year apart ("the words of the year") are a series."""
    titles = {" ".join(_words(re.sub(r"\[[^\]]*\]|\([^)]*\)", " ", video.get("title") or ""))) for video in videos}
    dates = [video.get("published") or 0 for video in videos if video.get("published")]
    return len(titles) < 3 and (not dates or max(dates) - min(dates) < 180 * 86400)


def _common_phrase(titles):
    """The longest run of words all these titles share, as the first spells it."""
    first = _TOKEN.findall(bare_title(titles[0]))
    others = [" " + " ".join(_TOKEN.findall(bare_title(title).lower())) + " " for title in titles[1:]]
    for size in range(min(6, len(first)), 0, -1):
        for start in range(len(first) - size + 1):
            chunk = first[start:start + size]
            lower = [word.lower() for word in chunk]
            if lower[0] in STOP or lower[-1] in STOP or not any(word not in STOP and word not in GENERIC_NAME and len(word) >= 4 for word in lower):
                continue
            if all(" " + " ".join(lower) + " " in other for other in others):
                return " ".join(chunk)
    return ""


def numbered_runs(videos, channel=""):
    """Things in parts: "Pt. 1", "Pt. 2", "Pt. 3" coming one after the other, often
    under titles that share nothing else. Named by what they do share: words of
    the title, else a tag or hashtag all of them carry (and few others).
    [{name, ids, rule}]"""
    dated = sorted((video for video in videos if video.get("published")), key=lambda video: video["published"])
    numbers = {}
    for video in dated:
        found = RUN_NUMBER.search(video.get("title") or "")
        if found:
            numbers[video["id"]] = int(found.group(1))
    tag_count = collections.Counter(tag.lower().strip() for video in videos for tag in tags_of(video))
    used, out = set(), []
    for index, video in enumerate(dated):
        if numbers.get(video["id"]) != 1 or video["id"] in used:
            continue
        run = [video]
        for later in dated[index + 1:]:
            if later["published"] - run[-1]["published"] > 45 * 86400:
                break
            if numbers.get(later["id"]) == len(run) + 1 and later["id"] not in used:
                run.append(later)
        if len(run) < 3:
            continue
        titles = [member.get("title") or "" for member in run]
        name, rule = _common_phrase(titles), {}
        if name and not _is_channel(name, channel) and not _generic(_beyond_channel(name, channel)):
            rule = {"title": [name]}
        else:
            shared = set.intersection(*({tag.lower().strip() for tag in tags_of(member)} for member in run))
            shared = sorted((tag for tag in shared if tag not in COMMON_TAGS and not _is_noise(tag) and not _is_channel(tag, channel) and tag_count[tag] <= 2 * len(run)), key=lambda tag: (-tag.count(" "), tag_count[tag]))
            hashtags = set.intersection(*({tag.lower() for tag in HASHTAG.findall(f"{member.get('title') or ''} {member.get('description') or ''}")} for member in run))
            hashtags = sorted(tag for tag in hashtags if tag not in COMMON_TAGS and not _is_channel(tag, channel.replace(" ", "")))
            # named as its first part is: a tag on all of them says what they are
            # about ("guy fieri"), not what they are called
            name = QUOTES.sub("", re.sub(r"\s*[(\[]?\s*" + RUN_NUMBER.pattern + r"\s*[)\]]?", " ", bare_title(titles[0]), flags=re.I))
            name = re.sub(r"\s+", " ", name).strip(" .,:;!?-–—|")
            if shared:
                rule = {"tags": [shared[0]]}
            elif hashtags:
                rule = {"title": [f"#{hashtags[0]}"], "desc": [f"#{hashtags[0]}"]}
        if not rule:
            continue
        used.update(member["id"] for member in run)
        out.append({"name": name, "ids": [member["id"] for member in run], "rule": rule})
    return out


def title_starts(videos, channel=""):
    """How many titles begin: "Gaming on a …", "Inside the Mind of …". A start
    whose name goes on in different ways ("Super Mario Maker", "Super Mario 64")
    is several things. {start: (name, ids)}"""
    starts = collections.defaultdict(lambda: {"forms": collections.Counter(), "ids": set(), "next": []})
    for video in videos:
        title = bare_title(video.get("title"))
        spelled = title.split()
        lower = [" ".join(_TOKEN.findall(word.lower())) for word in spelled]
        for size in range(2, min(4, len(spelled) - 1) + 1):
            words = lower[:size]
            if not all(words) or any(" " in word for word in words) or words[0] in STARTERS:
                continue
            if any(_channelish(word, channel) for word in words) or not any(word not in STOP and word not in GENERIC_NAME and len(word) >= 4 for word in words):
                continue
            key = " ".join(words)
            starts[key]["forms"][" ".join(spelled[:size]).strip(" ,.:;!?-–—")] += 1
            starts[key]["ids"].add(video["id"])
            following = spelled[size].strip(" ,.:;!?-–—\"'") if not re.search(r"[,:;!?|]$", spelled[size - 1]) else ""
            starts[key]["next"].append(following.lower() if following and (following[0].isupper() or following[0].isdigit()) and following.lower() not in STOP and not title.isupper() else "")
    out = {}
    for key, entry in starts.items():
        named = [word for word in entry["next"] if word]
        if len(named) >= 0.5 * len(entry["next"]) and len(set(named)) > 1:
            continue
        out[key] = (entry["forms"].most_common(1)[0][0], entry["ids"])
    return out


def discover(videos, playlists=(), channel="", limit=12, footer=None):
    """What on a channel looks like a series. Its playlists first, then what the
    titles say: a name in a part of the title (stronger with an episode number),
    parts counted "Pt. 1, 2, 3", a way titles begin. Hashtags, tags and names in
    descriptions only back those up: creators put the same ones on everything,
    and a description is full of ads and credits. Signals that mean the same
    videos become one suggestion.
    [{word, name, kind, rule, ids, why, numbered, score, playlist}]"""
    videos = [video for video in videos if video.get("kind") not in ("short", "upcoming", "live")]
    total = len(videos)
    if total < 3:
        return []
    known = {video["id"] for video in videos}
    by_id = {video["id"]: video for video in videos}
    footer = footer_lines([video.get("description") for video in videos]) if footer is None else footer
    found = []

    def add(kind, word, name, ids, score, rule, why, **more):
        found.append({"kind": kind, "word": word, "name": name, "ids": sorted(ids), "score": score + min(20, len(ids)), "rule": rule, "why": [why], **more})

    # playlists: the channel said so itself
    for entry in playlists:
        ids = [one for one in entry.get("ids", []) if one in known]
        title = entry.get("title") or ""
        name = clean_playlist_name(title, channel)
        words = _words(_beyond_channel(name, channel))
        if len(ids) < 3 or GENERIC_PLAYLIST.match(name.strip()) or not words or _generic(" ".join(words), noise=False) or words[-1] in COLLECTION or _is_channel(name, channel) or (total >= 10 and len(ids) > 0.9 * total):
            continue
        add("playlist", f"playlist:{entry['id']}", name, ids, 100, {}, "The channel's own playlist", playlist=entry["id"])

    # parts of titles; "Mini-Podcast Jay & Arya" and "Jay & Arya Mini Podcast" are one
    parts = collections.defaultdict(lambda: {"forms": collections.Counter(), "numbered": 0, "bracketed": 0})
    for video in videos:
        labels = {name.lower() for groups in BRACKETS.findall(video.get("title") or "") for name, _ in title_parts("".join(groups))}
        for name, numbered in {*title_parts(video.get("title"))}:
            entry = parts[" ".join(sorted(set(_words(name)) - STOP)) or name.lower()]
            entry["forms"][name] += 1
            entry["numbered"] += int(numbered)
            entry["bracketed"] += int(name.lower() in labels)
    for key, entry in parts.items():
        forms = [form for form, _ in entry["forms"].most_common()]
        name, seen = forms[0], sum(entry["forms"].values())
        if seen < 3 or _is_channel(name, channel) or _is_noise(name) or _generic(_beyond_channel(name, channel)):
            continue
        ids = [video["id"] for video in videos if any(has(video.get("title"), form) for form in forms)]
        words = len(_TOKEN.findall(name.lower()))
        numbered = entry["numbered"] >= 0.6 * seen
        if len(ids) < 3 or len(ids) / total > (0.8 if numbered or words > 1 else WEAK_SHARE) or _one_upload([by_id[one] for one in ids]):
            continue
        rule = {"title": forms[:3]}
        if numbered:
            add("title", f"title:{name.lower()}", name, ids, 85, rule, f'Numbered, "{name}" in {len(ids)} titles', numbered=True)
        elif words > 1:
            add("title", f"title:{name.lower()}", name, ids, 50 if entry["bracketed"] >= 0.5 * seen else 62, rule, f'"{name}" in {len(ids)} titles')
        elif len(ids) >= 4:
            add("title", f"title:{name.lower()}", name, ids, 42, rule, f'"{name}" in {len(ids)} titles')

    # parts counted in titles that share little else
    for run in numbered_runs(videos, channel):
        add("title", f"run:{run['name'].lower()}", run["name"], run["ids"], 80, run["rule"], f"Parts 1 to {len(run['ids'])}, one after the other", numbered=True)

    # how titles begin; one word of substance needs many ("Gaming on" yes, "Making a" no)
    for key, (name, ids) in title_starts(videos, channel).items():
        weight = sum(1 for word in key.split() if word not in STOP and word not in GENERIC_NAME and len(word) >= 4)
        if len(ids) >= (4 if weight > 1 else 8) and len(ids) / total <= 0.3 and not _is_channel(name, channel) and not _is_noise(name) and not _one_upload([by_id[one] for one in ids]):
            add("title", f"start:{key}", name, ids, 48, {"title": [name]}, f'{len(ids)} titles begin "{name}"')

    # hashtags, tags and descriptions: only what backs up the above
    hashtags, tags, phrases = collections.defaultdict(set), collections.defaultdict(set), collections.defaultdict(set)
    for video in videos:
        top = " ".join(prose(video.get("description"), footer))
        for tag in HASHTAG.findall(f"{video.get('title') or ''} {top}"):
            hashtags[tag.lower()].add(video["id"])
        for tag in tags_of(video):
            tags[tag.lower().strip()].add(video["id"])
        for phrase in set(PROPER.findall(URL.sub(" ", top))):
            phrases[phrase.lower()].add(video["id"])
    for tag, ids in hashtags.items():
        if len(ids) >= 3 and tag not in COMMON_TAGS and not _is_channel(tag, channel.replace(" ", "")) and not _is_noise(tag):
            add("hashtag", f"hashtag:{tag}", tag.title(), ids, 0, {}, f"#{tag} on {len(ids)} videos", support=True)
    for tag, ids in tags.items():
        if len(ids) >= 3 and tag not in COMMON_TAGS and not _is_channel(tag, channel) and not _is_noise(tag) and not any(_channelish(word, channel) for word in _words(tag)):
            add("tag", f"tag:{tag}", tag.title(), ids, 0, {}, f'Tagged "{tag}" on {len(ids)} videos', support=True)
    for phrase, ids in phrases.items():
        if len(ids) >= 3 and not _is_channel(phrase, channel) and not _is_noise(phrase) and not any(_channelish(word, channel) for word in _words(phrase)):
            add("description", f"description:{phrase}", phrase.title(), ids, 0, {}, f'"{phrase}" in {len(ids)} descriptions', support=True)

    # the same videos under another name are one series, told by its strongest sign
    chosen = []
    for entry in sorted(found, key=lambda item: (-item["score"], -len(item["word"]))):
        ids = set(entry["ids"])
        twin = next((other for other in chosen if len(ids & set(other["ids"])) >= 0.6 * min(len(ids), len(other["ids"]))), None)
        if twin:
            # it backs the other up only when it means about the same videos,
            # not a tag on half the channel that happens to cover a playlist
            same = len(ids & set(twin["ids"])) >= 0.6 * max(len(ids), len(twin["ids"]))
            if same and len(twin["why"]) < 3 and entry["why"][0] not in twin["why"] and entry["kind"] != twin["kind"]:
                twin["why"].append(entry["why"][0])
            # a playlist that reading finds as well: most of it, not a few videos
            if same and not entry.get("support"):
                twin["detected"] = True
            twin["numbered"] = twin.get("numbered") or entry.get("numbered")
            continue
        if entry.get("support"):
            continue
        chosen.append(entry)
        if len(chosen) >= limit * 3:
            break
    for entry in chosen:
        entry.pop("support", None)
    return chosen[:limit]


def playlist_order(videos):
    """A playlist in its own order, turned around when it lists the newest first.
    One whose dates jump back and forth (a collection sorted by hand, or by
    nobody) goes by its numbers or dates instead."""
    if len(videos) < 3:
        return list(videos)
    numbers = [number for number in (episode_number(video.get("title")) for video in videos) if number is not None]
    if len(numbers) >= 0.8 * len(videos) and len(set(numbers)) == len(numbers):
        steps = [later - earlier for earlier, later in zip(numbers, numbers[1:])]
        if all(step > 0 for step in steps):
            return list(videos)
        if all(step < 0 for step in steps):
            return list(reversed(videos))
    dated = [video.get("published") for video in videos if video.get("published") and not video.get("guessed")]
    if len(dated) < 3:
        return list(videos)
    pairs = list(zip(dated, dated[1:]))
    up = sum(1 for earlier, later in pairs if later >= earlier)
    if up >= 0.85 * len(pairs):
        return list(videos)
    if len(pairs) - up >= 0.85 * len(pairs):
        return list(reversed(videos))
    return order(videos)


# ── series inside a series ─────────────────────────────────────────────────
QUOTED = re.compile(r"[\"“„]([^\"”“\n]{3,40})[\"”“]")
CAPS = re.compile(r"\b[A-ZÄÖÜ]{2,}(?:[ \t]+[A-ZÄÖÜ]{2,}){1,3}\b")
NEW_START = re.compile(r"\b(new series|new adventure|starting a new|brand new|first episode|neue serie|neues abenteuer|beginning of a new)\b", re.I)
GENERIC_WORDS = set("""mod mods modded modpack series game games part parts episode finale final video new the a an play plays playing
let lets today back more spiel spiele serie""".split())
# in a description, a name has to be said to be what is played: "playing the
# Cave Horror Project mod", "the "From the Fog" modpack", "Bizly's Super Hero
# One Shot". Characters, crews and places ("La Alma", "The Riptide Pirates")
# are named on their own and make no part.
SERIES_AFTER = re.compile(r"^[\"'”“]?\s*(?:minecraft\s+)?(?:mod|mods|modpack|map|series|serie|campaign|kampagne|dlc|update|one[- ]?shot|saga|arc|season|staffel|playthrough|server|smp|gaming|gameplay)\b", re.I)
SERIES_BEFORE = re.compile(r"\b(?:playing|plays|play|spielt|spielen|zockt|zocken)\s+(?:the\s+|das\s+|den\s+|die\s+)?[\"'“„]?$", re.I)
SERIES_END = {"mod", "modpack", "map", "series", "campaign", "dlc", "shot", "oneshot", "saga", "arc", "smp"}


def _runs(found):
    words = found.strip(" .,!?:").split()
    for size in range(2, min(5, len(words) + 1)):
        for start in range(len(words) - size + 1):
            yield " ".join(words[start:start + size]).strip(" .,!?:'’")


def _names_in(text, said=False):
    """Names a text may hold: quoted, in capitals, in title case, and the shorter
    runs inside those, since a name is rarely spelled the same way twice. With
    `said`, only names the text says are played (see SERIES_AFTER)."""
    out = set()
    text = text or ""
    for pattern in (QUOTED, CAPS, PROPER):
        for match in pattern.finditer(text):
            found = match.group(1) if pattern is QUOTED else match.group(0)
            if said and pattern is not QUOTED:
                last = found.lower().split()[-1] if found.split() else ""
                if not (SERIES_AFTER.match(text[match.end():]) or SERIES_BEFORE.search(text[:match.start()]) or last in SERIES_END):
                    continue
            out.update(_runs(found))
    return out


def subdivide(ordered, parent="", channel="", footer=(), limit=12):
    """Series inside a series. `ordered` runs from the oldest video to the newest.
    A name most of a run of neighbouring videos share makes a part, holding the
    videos that carry the name. A video without it joins only when its title is
    plainly about the whole (the finale of "Horror Minecraft" in "Horror
    Minecraft"), or when it says something new starts with the next part; never
    because it happens to sit between two parts.
    Fewer than two parts: []. [{name, ids, why, named}]"""
    if len(ordered) < 4:
        return []
    ignored = {word for word in _TOKEN.findall(f"{parent} {channel}".lower())}
    # "House Flipping" in "House Flipper" says nothing new either
    stems = {word[:5] for word in ignored if len(word) >= 5}

    def plain(word):
        return word in ignored or (len(word) >= 5 and word[:5] in stems) or word in GENERIC_WORDS or word in STOP

    forms = collections.defaultdict(collections.Counter)
    seen = collections.defaultdict(set)
    said = set()
    titles = [bare_title(GUEST.sub("", video.get("title") or "")) for video in ordered]
    for index, video in enumerate(ordered):
        top = URL.sub(" ", " ".join(prose(video.get("description"), footer)))
        named = _names_in(top, said=True) | _names_in(titles[index], said=True)
        said.update(" ".join(_TOKEN.findall(name.lower())) for name in named)
        for name in _names_in(titles[index]) | named:
            words = _TOKEN.findall(name.lower())
            useful = [word for word in words if not plain(word)]
            if not useful or any(_channelish(word, channel) for word in words) or _is_noise(name) or words[-1] in GENERIC_WORDS or words[-1] in STOP or words[0] in STOP - {"the", "from"}:
                continue
            key = " ".join(words)
            forms[key][name] += 1
            seen[key].add(index)
        # a game's name is often one word, and only the titles have it
        for word in _TOKEN.findall(titles[index].lower()):
            if len(word) >= 5 and not plain(word) and not _channelish(word, channel) and not _is_noise(word):
                forms[word][word.title()] += 1
                seen[word].add(index)
    candidates = []
    for key, indexes in seen.items():
        words = key.count(" ") + 1
        low, high = min(indexes), max(indexes)
        span = high - low + 1
        needed = 2 if words > 1 else 3
        # a name that runs through everything or is scattered around names no part
        if len(indexes) < needed or len(indexes) / span < 0.5 or len(indexes) > 0.9 * len(ordered):
            continue
        candidates.append((len(indexes) * (1 + 0.5 * (words - 1)) * (1 if words > 1 else 0.6), key, low, high))
    chosen = []
    for score, key, low, high in sorted(candidates, reverse=True):
        # a word alone has to be a rare, long one
        if " " not in key and (len(key) < 7 or len(seen[key]) / (high - low + 1) < 0.7):
            continue
        # "THE SHIFT" twice in shouted titles is no name; "LIMINAL HORROR MOD" is
        if len(seen[key]) < 3 and key not in said:
            continue
        if any(low <= other["high"] and high >= other["low"] for other in chosen):
            continue
        if any(set(key.split()) - STOP == set(other["key"].split()) - STOP for other in chosen):
            continue
        chosen.append({"key": key, "low": low, "high": high, "name": forms[key].most_common(1)[0][0]})
    chosen.sort(key=lambda part: part["low"])
    if not chosen:
        return []
    owner = [None] * len(ordered)
    for number, part in enumerate(chosen):
        for index in seen[part["key"]]:
            owner[index] = number
    about = [bool(parent) and has(title, parent) for title in titles]
    # one that says something new starts belongs to the next part
    for index in range(len(ordered) - 1, -1, -1):
        if owner[index] is None and index + 1 < len(ordered) and owner[index + 1] is not None and NEW_START.search(ordered[index].get("description") or ""):
            owner[index] = owner[index + 1]
    # one about the whole goes with its neighbour, the one before first
    for index in range(len(ordered)):
        if owner[index] is None and about[index] and index > 0 and owner[index - 1] is not None:
            owner[index] = owner[index - 1]
    for index in range(len(ordered) - 1, -1, -1):
        if owner[index] is None and about[index] and index + 1 < len(ordered) and owner[index + 1] is not None:
            owner[index] = owner[index + 1]
    parts = []
    for number, part in enumerate(chosen):
        ids = [ordered[index]["id"] for index in range(len(ordered)) if owner[index] == number]
        hits = len(seen[part["key"]])
        # a guest in a few episodes names no part: the name has to carry most of it
        if len(ids) >= 2 and hits / len(ids) >= 0.5:
            # "Cave Horror Project Minecraft" in "Horror Minecraft": the end says nothing new
            words = part["name"].split()
            while len(words) > 2 and words[-1].lower() in ignored:
                words.pop()
            part["name"] = " ".join(words)
            parts.append({"name": part["name"].title() if part["name"].isupper() else part["name"], "ids": ids, "word": part["name"], "why": f'"{part["name"]}" in {hits} of {len(ids)} videos', "named": True})
    if len(parts) < 2:
        return []
    return sorted(parts, key=lambda part: -len(part["ids"]))[:limit]


def pattern_of(starts):
    """Recurring live times from local (weekday, minute of day) pairs: slots
    seen at least three times within 45 minutes. [{weekday, minute, count}]"""
    slots = []
    for day in range(7):
        minutes = sorted(minute for weekday, minute in starts if weekday == day)
        i = 0
        while i < len(minutes):
            group = [minutes[i]]
            j = i + 1
            while j < len(minutes) and minutes[j] - group[0] <= 90:
                group.append(minutes[j])
                j += 1
            if len(group) >= 3:
                slots.append({"weekday": day, "minute": sorted(group)[len(group) // 2], "count": len(group)})
            i = j
    return slots
