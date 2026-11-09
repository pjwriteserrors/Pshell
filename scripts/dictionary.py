#!/usr/bin/env python3
"""Looks a word up for the launcher's dictionary (>d).

  dictionary.py WORD [--lang auto|de|en] [--refresh]

The meaning comes from Wiktionary: German words from de.wiktionary (its
wikitext: meanings, syllables, IPA, a spoken recording, examples, synonyms,
origin, the pictures it shows), English ones from dictionaryapi.dev with
en.wiktionary as fallback. Wikipedia adds a sentence or two about the thing
and its lead picture; Wikimedia Commons and Openverse (searched with the
English name of the article) add more pictures. "auto" takes German when
de.wiktionary has a German entry, English otherwise. Pictures are fetched
in parallel into ~/.cache/pshell/dictionary and announced as they arrive;
answers are kept there for a month, misses for a day.

Prints JSON lines:
  {"type": "entry", "word", "lang", "langs": [...], "pos", "gender",
   "syllables", "ipa", "audio", "summary", "senses": [{"n", "text", "tags"}],
   "example", "synonyms": [...], "origin", "url"}
  {"type": "image", "index", "path", "width", "height", "caption", "credit"}
  {"type": "none"}            nothing found
  {"type": "error", "error"}
  {"type": "done"}
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

AGENT = "pshell-dictionary/1.0 (https://github.com/pjwriteserrors/Pshell) python-urllib"
# set when a source could not be asked (not when it simply has no answer)
TROUBLE = []
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "dictionary"
KEEP_DAYS = 30
MISS_HOURS = 24
IMAGES = 6
THUMB = 500  # px wide asked of Wikimedia: a step it keeps ready

# de.wiktionary's labels and abbreviations, as words
LABELS = {
	"ugs.": "umgangssprachlich", "übertr.": "übertragen", "va.": "veraltet", "veraltend": "veraltend",
	"fachspr.": "fachsprachlich", "reg.": "regional", "scherzh.": "scherzhaft", "abw.": "abwertend",
	"geh.": "gehoben", "landsch.": "landschaftlich", "österr.": "österreichisch", "schweiz.": "schweizerisch",
	"süddt.": "süddeutsch", "norddt.": "norddeutsch", "intrans.": "intransitiv", "trans.": "transitiv",
	"refl.": "reflexiv", "Pl.": "Plural", "Sg.": "Singular", "kPl.": "kein Plural", "meist": "meist",
	"selten": "selten", "veraltet": "veraltet", "speziell": "speziell", "fig.": "figurativ",
}
GENDERS = {"m": "maskulin", "f": "feminin", "n": "neutrum"}


def say(**message):
	print(json.dumps(message, ensure_ascii=False), flush=True)


def get(url, timeout=8, raw=False):
	request = urllib.request.Request(url, headers={"User-Agent": AGENT, "Accept": "*/*"})
	with urllib.request.urlopen(request, timeout=timeout) as response:
		data = response.read()
	return data if raw else json.loads(data.decode("utf-8"))


def quiet(fn, *args):
	try:
		return fn(*args)
	except urllib.error.HTTPError as error:
		if error.code != 404:
			TROUBLE.append(f"{error.code} {error.reason}")
		return None
	except (urllib.error.URLError, TimeoutError, OSError) as error:
		TROUBLE.append(str(getattr(error, "reason", error)))
		return None
	except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError, IndexError, TypeError):
		return None


# ── wikitext ────────────────────────────────────────────────────────────

def strip_templates(text):
	# innermost first, so nested ones resolve
	def template(match):
		parts = [p.strip() for p in match.group(1).split("|")]
		name = parts[0]
		if name == "K":
			return "⟨" + ", ".join(LABELS.get(p, p) for p in parts[1:] if "=" not in p) + "⟩ "
		if name in LABELS:
			return "⟨" + LABELS[name] + "⟩ "
		if name in ("L", "W", "Ü", "Wikipedia") and len(parts) > 1:
			return parts[-1] if len(parts) > 2 else parts[1]
		if name in ("Üt", "Üxx4") and len(parts) > 3:
			return parts[3]
		if name in ("Polytonisch", "Lautschrift", "IPA") and len(parts) > 1:
			return parts[1]
		return ""

	previous = None
	while previous != text:
		previous = text
		text = re.sub(r"\{\{([^{}]*)\}\}", template, text)
	return text


def clean(text):
	text = re.sub(r"<ref[^>]*/>", "", text)
	text = re.sub(r"<ref[^>]*>.*?</ref>", "", text, flags=re.S)
	text = re.sub(r"<sup>.*?</sup>", "", text, flags=re.S)
	text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
	text = strip_templates(text)
	text = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", text)
	text = re.sub(r"\[https?://\S+ ([^\]]*)\]", r"\1", text)
	text = re.sub(r"'{2,}", "", text)
	text = re.sub(r"<[^>]+>", "", text)
	text = html.unescape(text)
	return re.sub(r"\s+", " ", text).strip(" ,;:")


def labelled(text):
	"""'⟨Botanik⟩ aus Wurzel…' → ('aus Wurzel…', ['Botanik'])"""
	tags = []
	for match in re.finditer(r"⟨([^⟩]*)⟩", text):
		tags += [t.strip() for t in match.group(1).split(",") if t.strip()]
	text = re.sub(r"⟨[^⟩]*⟩", "", text)
	return re.sub(r"\s+", " ", text).strip(" ,;:"), tags


def shorten(text, limit):
	if len(text) <= limit:
		return text
	cut = max(text.rfind(";", 0, limit), text.rfind(". ", 0, limit), text.rfind(", ", 0, limit))
	return text[:cut].rstrip(" ;.,") + " …" if cut > limit // 2 else text[:limit].rsplit(" ", 1)[0].rstrip(" ,;") + " …"


def section(block, name):
	"""lines of {{Name}} up to the next {{…}} heading line"""
	match = re.search(r"^\{\{" + re.escape(name) + r"\}\}\s*\n((?:[:*].*\n?)*)", block, re.M)
	return [line for line in match.group(1).splitlines() if line.startswith(":")] if match else []


def numbered(line):
	match = re.match(r"^(:+)\s*\[([^\]]*)\]\s*(.*)$", line)
	return (match.group(2), match.group(3), len(match.group(1))) if match else (None, line.lstrip(": "), 1)


def german(word):
	"""the first of the word's spellings that has a German entry; one request for all of them"""
	titles = variants(word)
	query = urllib.parse.urlencode({"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main",
		"titles": "|".join(titles), "redirects": 1, "format": "json", "formatversion": 2})
	data = get(f"https://de.wiktionary.org/w/api.php?{query}")
	found = data.get("query", {})
	names = {item["from"]: item["to"] for item in found.get("normalized", []) + found.get("redirects", [])}
	pages = {page["title"]: page for page in found.get("pages", []) if page.get("revisions")}
	for title in titles:
		name = names.get(names.get(title, title), names.get(title, title))
		page = pages.get(name)
		if not page:
			continue
		entry = german_entry(name, page["revisions"][0]["slots"]["main"]["content"])
		if entry:
			return entry
	return None


def german_entry(title, text):
	match = re.search(r"^== .*?\(\{\{Sprache\|Deutsch\}\}\) ==\s*$(.*?)(?=^== |\Z)", text, re.M | re.S)
	if not match:
		return None
	block = match.group(1)
	# the first part of speech only
	parts = re.split(r"^=== ", block, flags=re.M)
	head = parts[1] if len(parts) > 1 else block
	heading = head.splitlines()[0]
	pos = [p for p in re.findall(r"\{\{Wortart\|([^|}]*)", heading)]
	gender = next((GENDERS[g] for g in re.findall(r"\{\{([mfn])\}\}", heading) if g in GENDERS), "")

	senses = []
	for line in section(head, "Bedeutungen"):
		number, body, depth = numbered(line)
		value, tags = labelled(clean(body))
		value = shorten(value, 200)
		if value:
			senses.append({"n": number or "", "text": value, "tags": tags, "sub": depth > 1})
	if not senses:
		return None

	syllables = ""
	lines = section(head, "Worttrennung")
	if lines:
		syllables = clean(lines[0].lstrip(": ")).split(",")[0].strip()
	ipa = ""
	audio = ""
	for line in section(head, "Aussprache"):
		if not ipa:
			found = re.search(r"\{\{Lautschrift\|([^}|]+)", line)
			ipa = f"[{found.group(1)}]" if found else ""
		if not audio:
			found = re.search(r"\{\{Audio\|([^}|]+)", line)
			audio = found.group(1).strip() if found else ""
	example = ""
	for line in section(head, "Beispiele"):
		value = clean(numbered(line)[1])
		if 12 < len(value) < 180:
			example = value
			break
	synonyms = []
	for line in section(head, "Synonyme") + section(head, "Sinnverwandte Wörter"):
		for word in re.findall(r"\[\[([^\]|#]+)", line):
			if word not in synonyms and word != title:
				synonyms.append(word)
	origin = ""
	lines = section(head, "Herkunft")
	if lines:
		origin = clean(lines[0].lstrip(": "))
	# the pictures it shows, by the meaning they show (|Bild 1=File|mini|1|caption)
	pictures = []
	for value in re.findall(r"^\|Bild[^=]*=(.*)$", head, re.M):
		fields = [f.strip() for f in re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", value).split("|")]
		if not re.search(r"\.(jpe?g|png|webp|tiff?)$", fields[0], re.I):
			continue
		sense = next((int(m.group(1)) for f in fields[1:-1] for m in [re.fullmatch(r"(\d+)\w?", f)] if m), 99)
		caption = fields[-1] if len(fields) > 1 and not re.fullmatch(r"\d+\w?|mini|links|rechts|hochkant", fields[-1]) else ""
		pictures.append({"file": fields[0], "caption": clean(caption), "sense": sense})
	pictures.sort(key=lambda p: p["sense"])
	return {
		"word": title, "lang": "de", "pos": ", ".join(pos), "gender": gender,
		"syllables": syllables, "ipa": ipa, "audio": audio, "senses": senses[:8], "example": example,
		"synonyms": synonyms[:8], "origin": origin[:260], "pictures": pictures,
		"url": "https://de.wiktionary.org/wiki/" + urllib.parse.quote(title),
	}


def english(word):
	data = quiet(get, "https://api.dictionaryapi.dev/api/v2/entries/en/" + urllib.parse.quote(word.lower()))
	if isinstance(data, list) and data:
		entry = data[0]
		phonetics = entry.get("phonetics") or []
		audio = next((p.get("audio") for p in phonetics if p.get("audio")), "")
		ipa = entry.get("phonetic") or next((p.get("text") for p in phonetics if p.get("text")), "")
		senses, synonyms, example, pos = [], [], "", []
		for meaning in entry.get("meanings") or []:
			pos.append(meaning.get("partOfSpeech", ""))
			for number, definition in enumerate(meaning.get("definitions") or [], 1):
				if len(senses) < 8:
					senses.append({"n": str(len(senses) + 1), "text": definition.get("definition", ""), "tags": [meaning.get("partOfSpeech", "")] if len(pos) > 1 or number == 1 else [], "sub": False})
				if not example and 12 < len(definition.get("example") or "") < 180:
					example = definition["example"]
			for synonym in (meaning.get("synonyms") or []):
				if synonym not in synonyms:
					synonyms.append(synonym)
		if senses:
			return {
				"word": entry.get("word", word), "lang": "en", "pos": ", ".join(dict.fromkeys(p for p in pos if p)),
				"gender": "", "syllables": "", "ipa": ipa, "audio": audio, "senses": senses, "example": example,
				"synonyms": synonyms[:8], "origin": entry.get("origin", ""), "pictures": [],
				"url": "https://en.wiktionary.org/wiki/" + urllib.parse.quote(entry.get("word", word)),
			}
	# en.wiktionary, its English section
	data = quiet(get, "https://en.wiktionary.org/api/rest_v1/page/definition/" + urllib.parse.quote(word))
	for entry in (data or {}).get("en") or []:
		if entry.get("language") != "English":
			continue
		senses = []
		for definition in entry.get("definitions") or []:
			value = clean(definition.get("definition", ""))
			if value:
				senses.append({"n": str(len(senses) + 1), "text": value, "tags": [], "sub": False})
		if senses:
			return {
				"word": word, "lang": "en", "pos": entry.get("partOfSpeech", "").lower(), "gender": "", "syllables": "",
				"ipa": "", "audio": "", "senses": senses[:8], "example": "", "synonyms": [], "origin": "", "pictures": [],
				"url": "https://en.wiktionary.org/wiki/" + urllib.parse.quote(word),
			}
	return None


def variants(word):
	out = [word, word[:1].upper() + word[1:], word.lower()]
	return list(dict.fromkeys(w for w in out if w))


def article(lang, title):
	data = quiet(get, f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(title.replace(" ", "_")))
	return data if data and data.get("type") == "standard" else None


def wikipedia(lang, title):
	data = article(lang, title)
	if not data:
		# a word whose page lists its meanings: the article search puts first, when it is about the word
		query = urllib.parse.urlencode({"action": "query", "list": "search", "srsearch": title, "srlimit": 3, "format": "json", "formatversion": 2})
		hits = (quiet(get, f"https://{lang}.wikipedia.org/w/api.php?{query}") or {}).get("query", {}).get("search", [])
		stem = title.lower()[:max(4, len(title) - 2)]
		for hit in hits:
			if hit["title"].lower().startswith(stem):
				data = article(lang, hit["title"])
				if data:
					break
	if not data:
		return None
	extract = data.get("extract") or ""
	# two sentences at most
	sentences = re.split(r"(?<=[.!?])\s+(?=[A-ZÄÖÜ])", extract)
	summary = ""
	for sentence in sentences:
		if len(summary) + len(sentence) > 200 and summary:
			break
		summary = (summary + " " + sentence).strip()
	summary = shorten(summary, 210)
	# a size Wikimedia keeps ready, never the original of many megapixels
	original = data.get("originalimage") or {}
	image = original.get("source", "")
	thumb = (data.get("thumbnail") or {}).get("source", "")
	if thumb and original.get("width", 0) > 960 and re.search(r"/\d+px-", thumb):
		image = re.sub(r"/\d+px-", "/960px-", thumb)
	english_title = title if lang == "en" else ""
	if lang != "en":
		query = urllib.parse.urlencode({"action": "query", "titles": data.get("title", title), "prop": "langlinks", "lllang": "en", "format": "json", "formatversion": 2})
		links = quiet(get, f"https://{lang}.wikipedia.org/w/api.php?{query}")
		pages = (links or {}).get("query", {}).get("pages") or [{}]
		english_title = ((pages[0].get("langlinks") or [{}])[0]).get("title", "")
	return {"summary": summary, "description": data.get("description", ""), "image": image, "english": english_title,
		"url": ((data.get("content_urls") or {}).get("desktop") or {}).get("page", "")}


# ── pictures ────────────────────────────────────────────────────────────

def commons_files(names):
	if not names:
		return []
	query = urllib.parse.urlencode({"action": "query", "titles": "|".join("File:" + n for n in names), "prop": "imageinfo",
		"iiprop": "url|size|extmetadata", "iiurlwidth": THUMB, "format": "json", "formatversion": 2})
	data = quiet(get, f"https://commons.wikimedia.org/w/api.php?{query}") or {}
	return [picture(page) for page in data.get("query", {}).get("pages", []) if page.get("imageinfo")]


def commons_search(term, count):
	query = urllib.parse.urlencode({"action": "query", "generator": "search", "gsrsearch": f"{term} filetype:bitmap",
		"gsrnamespace": 6, "gsrlimit": count, "prop": "imageinfo", "iiprop": "url|size|extmetadata", "iiurlwidth": THUMB,
		"format": "json", "formatversion": 2})
	data = quiet(get, f"https://commons.wikimedia.org/w/api.php?{query}") or {}
	pages = sorted(data.get("query", {}).get("pages", []), key=lambda p: p.get("index", 0))
	return [picture(page) for page in pages if page.get("imageinfo")]


def picture(page):
	info = page["imageinfo"][0]
	meta = info.get("extmetadata") or {}
	artist = clean(((meta.get("Artist") or {}).get("value")) or "")
	# "Name This file was uploaded with…" → "Name"
	artist = re.split(r"\s+(?:This|Dieses?|Uploaded|Own work)\b", artist)[0].strip(" ,.;")
	return {"url": info.get("thumburl") or info.get("url"), "title": page.get("title", ""), "caption": "", "credit": (artist[:60] + " · Wikimedia Commons").strip(" ·"),
		"width": info.get("thumbwidth") or info.get("width") or 0, "height": info.get("thumbheight") or info.get("height") or 0}


def openverse(term, count):
	query = urllib.parse.urlencode({"q": term, "page_size": count, "mature": "false"})
	data = quiet(get, f"https://api.openverse.org/v1/images/?{query}") or {}
	out = []
	for item in data.get("results") or []:
		url = item.get("thumbnail") or item.get("url")
		if url:
			out.append({"url": url, "caption": "", "credit": f"{item.get('creator') or 'unknown'} · {item.get('source', 'openverse')}",
				"width": item.get("width") or 0, "height": item.get("height") or 0})
	return out


def fetch_picture(folder, index, candidate):
	name = hashlib.sha1(candidate["url"].encode()).hexdigest()[:16]
	known = next((p for p in folder.glob(name + ".*") if p.suffix != ".part"), None)
	if known:
		path = known
	else:
		data = get(candidate["url"], timeout=10, raw=True)
		if len(data) < 2048:
			raise ValueError("too small")
		# named by what it is, so the picture viewer takes it
		kind = {b"\x89PNG": "png", b"GIF8": "gif", b"RIFF": "webp"}.get(data[:4], "jpg")
		path = folder / f"{name}.{kind}"
		# whole or not at all: a lookup stopped by the next word leaves no half picture
		part = path.with_suffix(".part")
		part.write_bytes(data)
		part.replace(path)
	width, height = candidate.get("width") or 0, candidate.get("height") or 0
	try:
		from PIL import Image
		with Image.open(path) as image:
			width, height = image.size
	except Exception:  # noqa: BLE001 – a size from the source then
		pass
	if width and height and (width < 160 or height < 120 or width / height > 3.2 or height / width > 3.2):
		raise ValueError("odd shape")
	return {"type": "image", "index": index, "path": str(path), "width": width, "height": height,
		"caption": candidate.get("caption", ""), "credit": candidate.get("credit", "")}


def audio_url(entry):
	audio = entry.get("audio") or ""
	if not audio or audio.startswith("http"):
		return audio
	query = urllib.parse.urlencode({"action": "query", "titles": "File:" + audio, "prop": "imageinfo", "iiprop": "url", "format": "json", "formatversion": 2})
	data = quiet(get, f"https://commons.wikimedia.org/w/api.php?{query}") or {}
	pages = data.get("query", {}).get("pages") or [{}]
	return ((pages[0].get("imageinfo") or [{}])[0]).get("url", "")


# ── the lookup ──────────────────────────────────────────────────────────

def lookup(word, lang):
	found = {}
	with concurrent.futures.ThreadPoolExecutor(4) as pool:
		jobs = {}
		if lang in ("auto", "de"):
			jobs["de"] = pool.submit(quiet, german, word)
		if lang in ("auto", "en"):
			jobs["en"] = pool.submit(lambda: english(word))
		for key, job in jobs.items():
			found[key] = job.result()
	langs = [key for key in ("de", "en") if found.get(key)]
	if not langs:
		return None
	entry = found[langs[0]]
	entry["langs"] = langs
	with concurrent.futures.ThreadPoolExecutor(3) as pool:
		# an article only for things: Wikipedia's "Laufen" is a town, not running
		thing = re.search(r"substantiv|eigenname|noun", entry["pos"], re.I)
		wiki = pool.submit(wikipedia, entry["lang"], entry["word"]) if thing else None
		sound = pool.submit(audio_url, entry)
		wiki = (wiki.result() if wiki else None) or {}
		entry["audio"] = sound.result() or ""
	entry["summary"] = wiki.get("summary", "")
	entry["description"] = wiki.get("description", "")
	entry["wiki"] = wiki.get("url", "")
	entry["image"] = wiki.get("image", "")
	entry["english"] = wiki.get("english", "") or (entry["word"] if entry["lang"] == "en" else "")
	return entry


def english_term(entry):
	"""what to search Openverse for: the English article, else a quick translation"""
	if entry.get("english"):
		return entry["english"]
	query = urllib.parse.urlencode({"client": "dict-chrome-ex", "sl": entry["lang"], "tl": "en", "dt": "t", "q": entry["word"]})
	data = quiet(get, f"https://translate.googleapis.com/translate_a/single?{query}")
	try:
		return "".join(part[0] for part in data[0]) or entry["word"]
	except (TypeError, IndexError):
		return entry["word"]


def candidate_groups(entry, pool):
	"""futures of picture lists, in the order they are worth showing"""
	first = []
	if entry.get("image"):
		first.append({"url": entry["image"], "caption": entry.get("description", ""), "credit": "Wikipedia"})
	done = concurrent.futures.Future()
	done.set_result(first)
	own = entry.get("pictures", [])[:4]

	def own_files():
		# Commons answers in its own order; Wiktionary's (by meaning) is kept
		def norm(name):
			name = name.replace("_", " ").strip()
			return (name[:1].upper() + name[1:]).removeprefix("File:")
		items = {norm(item["title"]): item for item in commons_files([p["file"] for p in own])}
		out = []
		for source in own:
			item = items.get(norm(source["file"]))
			if item:
				item["caption"] = source["caption"]
				out.append(item)
		return out

	commons = pool.submit(lambda: commons_search(entry["word"], 6)[:4])
	free = pool.submit(lambda: openverse(english_term(entry), 8))
	if entry.get("image"):
		return [done, pool.submit(own_files), commons, free]
	# what is not a thing shows better as photographs of the English word,
	# unless Wiktionary pictures its first meaning
	first = [p for p in own if p.get("sense") == 1]
	if first:
		return [done, pool.submit(own_files), free, commons]
	return [done, free, pool.submit(own_files), commons]


def pictures(entry, folder):
	"""fetches the pictures, says them in order as soon as those before are settled"""
	searches = concurrent.futures.ThreadPoolExecutor(4)
	downloads = concurrent.futures.ThreadPoolExecutor(6)
	jobs, seen, images, authors = [], set(), [], {}
	said = 0

	def flush(wait):
		nonlocal said
		while said < len(jobs) and len(images) < IMAGES and (wait or jobs[said].done()):
			try:
				image = jobs[said].result()
				image["index"] = len(images)
				images.append(image)
				say(**image)
			except Exception:  # noqa: BLE001 – a picture that does not come is left out
				pass
			said += 1

	for group in candidate_groups(entry, searches):
		for item in group.result() or []:
			key = re.sub(r"/\d+px-[^/]*$", "", item["url"].split("?")[0])
			# one file of Wikimedia, whether its original or a thumbnail
			if "wikimedia.org/" in key:
				key = urllib.parse.unquote(key.rsplit("/", 1)[-1])
			author = item.get("credit", "")
			if key in seen or key.lower().endswith(".svg") or len(jobs) >= IMAGES + 4 or (author and authors.get(author, 0) >= 2 and author != "Wikipedia"):
				continue
			seen.add(key)
			authors[author] = authors.get(author, 0) + 1
			jobs.append(downloads.submit(fetch_picture, folder, len(jobs), item))
		flush(False)
	flush(True)
	searches.shutdown(wait=False, cancel_futures=True)
	downloads.shutdown(wait=False, cancel_futures=True)
	return images


def main():
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	parser.add_argument("word")
	parser.add_argument("--lang", default="auto", choices=["auto", "de", "en"])
	parser.add_argument("--refresh", action="store_true")
	args = parser.parse_args()
	word = re.sub(r"\s+", " ", args.word).strip()
	if not word:
		say(type="none")
		return

	key = hashlib.sha1(f"{args.lang}\n{word}".encode()).hexdigest()[:20]
	folder = CACHE / key
	saved = folder / "entry.json"
	if saved.exists() and not args.refresh:
		try:
			cached = json.loads(saved.read_text())
			age = time.time() - saved.stat().st_mtime
			if cached.get("type") == "none" and age < MISS_HOURS * 3600:
				say(type="none")
				say(type="done")
				return
			if cached.get("type") == "entry" and age < KEEP_DAYS * 86400:
				say(**cached["entry"])
				for image in cached.get("images", []):
					if Path(image["path"]).exists():
						say(**image)
				say(type="done")
				return
		except (OSError, ValueError, KeyError):
			pass

	folder.mkdir(parents=True, exist_ok=True)
	try:
		entry = lookup(word, args.lang)
	except Exception as error:  # noqa: BLE001 – the launcher shows it
		say(type="error", error=str(error))
		return
	if not entry and TROUBLE:
		say(type="error", error="Wiktionary did not answer (" + TROUBLE[0] + ")")
		return
	if not entry:
		saved.write_text(json.dumps({"type": "none"}))
		say(type="none")
		say(type="done")
		return
	shown = {k: v for k, v in entry.items() if k not in ("pictures", "image")}
	shown["type"] = "entry"
	say(**shown)

	images = pictures(entry, folder)
	saved.write_text(json.dumps({"type": "entry", "entry": shown, "images": images}, ensure_ascii=False))
	say(type="done")


if __name__ == "__main__":
	sys.exit(main())
