"""What one does in the file chooser before saving, learned and done again
(Files.qml, the chooser's routines).

A save that went somewhere special – folders made on the way, a name
changed – is kept as an example under its site or app. The names are
explained by the name the app suggested: each becomes a template, the same
for every example that was kept, so the next save from there can do it all
by itself.

Templates
    {name}               the suggested name without its ending
    {ext}                its ending with the dot (".pdf")
    {date} {date:%d.%m.%Y}   today
    {app} {site}         who asks
    {n} {n:02}           the first number that makes the name free
  filters after |, on {name}:
    words  words(a:b)    the name in words (split at spaces, _ - . and
                         camelCase), all of them or a slice
    lower upper title sentence   how the words are written
    normal               words, sentence case, spaces ("Normal case")
    sep(x)               joined by x (sep() joins without anything)
    snake kebab          words joined by _ or -, lower case
"""
import datetime
import os
import re
import subprocess

CASES = ("as", "lower", "upper", "title", "sentence")
SEPS = (" ", "_", "-", "", ".")
DATE_FORMATS = ("%Y-%m-%d", "%d.%m.%Y", "%Y%m%d", "%d.%m.%y", "%Y-%m", "%m-%Y", "%Y_%m_%d", "%d-%m-%Y")
FIELD = re.compile(r"\{([a-z]+)(?::([^}|]*))?((?:\|[^}|]+)*)\}")


# ── names ─────────────────────────────────────────────────────────────────
def split_name(name):
    """("Rechnung_2024", ".pdf"); a leading dot is no ending."""
    stem, ext = os.path.splitext(name)
    if not stem:
        return name, ""
    # .tar.gz and the like stay together
    if stem.endswith(".tar"):
        stem, ext = stem[:-4], ".tar" + ext
    return stem, ext


def words_of(text):
    """Words at spaces, _ - . and camelCase; letters and digits stay together (o2, Q3)."""
    out = []
    for part in re.split(r"[\s_.\-]+", text):
        part = re.sub(r"(?<=[a-zäöüß])(?=[A-ZÄÖÜ])", " ", part)
        out += [w for w in part.split(" ") if w]
    return out


def cased(words, case):
    if case == "lower":
        return [w.lower() for w in words]
    if case == "upper":
        return [w.upper() for w in words]
    if case == "title":
        return [w[:1].upper() + w[1:].lower() for w in words]
    if case == "sentence":
        return [w[:1].upper() + w[1:].lower() if i == 0 else w.lower() for i, w in enumerate(words)]
    return list(words)


def run_filters(stem, filters):
    value = stem
    for raw in filters:
        f = raw.strip()
        if not f:
            continue
        m = re.fullmatch(r"words(?:\((-?\d*):(-?\d*)\))?", f)
        if m:
            parts = words_of(value if isinstance(value, str) else " ".join(value))
            a = int(m.group(1)) if m.group(1) else None
            b = int(m.group(2)) if m.group(2) else None
            value = parts[a:b]
            continue
        m = re.fullmatch(r"sep\((.*)\)", f)
        if m:
            value = m.group(1).join(value if isinstance(value, list) else [value])
            continue
        if f == "normal":
            value = " ".join(cased(words_of(value if isinstance(value, str) else " ".join(value)), "sentence"))
        elif f in ("snake", "kebab"):
            value = ("_" if f == "snake" else "-").join(w.lower() for w in words_of(value if isinstance(value, str) else " ".join(value)))
        elif f in CASES:
            if isinstance(value, list):
                value = cased(value, f)
            elif f == "lower":
                value = value.lower()
            elif f == "upper":
                value = value.upper()
            elif f == "title":
                value = re.sub(r"[^\W_]+", lambda w: w.group(0)[:1].upper() + w.group(0)[1:].lower(), value)
            elif f == "sentence":
                value = value[:1].upper() + value[1:].lower()
    return " ".join(value) if isinstance(value, list) else value


def render(template, context, n=None):
    """The template with this context; {n} as given (None: 1)."""
    stem, ext = split_name(context.get("source", "") or "")
    when = context.get("date") or datetime.date.today()
    if isinstance(when, (int, float)):
        when = datetime.date.fromtimestamp(when)

    def field(match):
        key, arg, filters = match.group(1), match.group(2), match.group(3)
        if key == "name":
            return run_filters(stem, filters.split("|")[1:])
        if key == "ext":
            return ext
        if key == "date":
            return when.strftime(arg or "%Y-%m-%d")
        if key in ("app", "site"):
            return run_filters(str(context.get(key, "") or ""), filters.split("|")[1:])
        if key == "n":
            number = 1 if n is None else n
            width = int(arg) if arg and arg.isdigit() else 0
            return str(number).zfill(width)
        return match.group(0)

    text = template.replace("{{", "\x01").replace("}}", "\x02")
    return FIELD.sub(field, text).replace("\x01", "{").replace("\x02", "}")


def has_fields(text):
    return bool(FIELD.search(text or ""))


def render_free(template, context, folder):
    """A file name from the template that is free in the folder ({n} counts up)."""
    if "{n" not in template:
        return render(template, context)
    for n in range(1, 10000):
        name = render(template, context, n)
        if not os.path.lexists(os.path.join(folder, name)):
            return name
    return render(template, context, 10000)


# ── learning ──────────────────────────────────────────────────────────────
def escape(text):
    return text.replace("{", "{{").replace("}", "}}")


def unescape(text):
    return text.replace("{{", "{").replace("}}", "}")


def literal_with_dates(text, when):
    """A literal piece of a name, a date in it made a field."""
    out = escape(text)
    for fmt in DATE_FORMATS:
        shown = when.strftime(fmt)
        if shown in text:
            return escape(text).replace(escape(shown), "{date:%s}" % fmt)
    return out


def transforms(stem):
    """(filters, text) a name can become, longest first."""
    parts = words_of(stem)
    seen = {}
    if stem:
        seen[stem] = ""
    count = len(parts)
    for a in range(count):
        for b in range(count, a, -1):
            piece = parts[a:b]
            slice_ = "words" if (a, b) == (0, count) else f"words({a}:{b if b < count else ''})"
            for case in CASES:
                written = cased(piece, case)
                for sep in SEPS:
                    if len(piece) == 1 and sep != " ":
                        continue
                    text = sep.join(written)
                    if len(text) < 2 or text in seen:
                        continue
                    filters = [slice_] + ([case] if case != "as" else []) + ([f"sep({sep})"] if sep != " " else [])
                    seen[text] = "|" + "|".join(filters)
    return sorted(((f, t) for t, f in seen.items()), key=lambda pair: -len(pair[1]))


def candidates(target, source, when, keep_ext):
    """Templates that make `target` out of `source`, best first."""
    stem, ext = split_name(source)
    t_stem, t_ext = split_name(target)
    tail = "{ext}" if keep_ext and t_ext.lower() == ext.lower() and ext else literal_with_dates(t_ext, when)
    body = t_stem if keep_ext else target
    if not keep_ext:
        tail = ""
    found = []
    for filters, text in transforms(stem):
        start = body.find(text)
        while start >= 0:
            before, after = body[:start], body[start + len(text):]
            template = literal_with_dates(before, when) + "{name" + filters + "}" + literal_with_dates(after, when) + tail
            # little literal, much taken from the name
            found.append((len(before) + len(after) - len(text) * 0.5, template))
            start = body.find(text, start + 1)
    found.sort(key=lambda pair: pair[0])
    out = [template for _, template in found]
    out.append(literal_with_dates(body, when) + tail)
    return list(dict.fromkeys(out))


def explain(target, examples, keep_ext=True):
    """The template that makes every example's name (examples: [{source,
    name, date}], the newest last, `target` its name)."""
    newest = examples[-1]
    when = datetime.date.fromtimestamp(newest.get("date") or 0) if newest.get("date") else datetime.date.today()
    for template in candidates(target, newest["source"], when, keep_ext):
        ok = True
        for example in examples[:-1]:
            context = {"source": example["source"], "date": example.get("date")}
            if render(template, context) != example["name"]:
                ok = False
                break
        if ok:
            return template
    return literal_with_dates(target, when)


def born(path):
    """When a folder was made (0 when the file system does not say)."""
    try:
        out = subprocess.run(["stat", "-c", "%W", path], capture_output=True, text=True, timeout=3).stdout.strip()
        return float(out or 0)
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0.0


def shape_of(path, since, source):
    """What a save did: the folder it started from that was there before,
    the folders below it (made during the choosing, or named after the
    file), and the name."""
    folder = os.path.dirname(path)
    chain = []
    while folder not in ("/", "") and since > 0:
        when = born(folder)
        if when and when >= int(since):
            chain.insert(0, {"name": os.path.basename(folder), "made": True})
            folder = os.path.dirname(folder)
        else:
            break
    # an existing folder named after the file counts too (one per customer, …)
    if not chain and source:
        name = os.path.basename(folder)
        stem, _ = split_name(source)
        words = [w.lower() for w in words_of(stem)]
        mine = [w.lower() for w in words_of(name)]
        if mine and len(mine) <= len(words) and all(w in words for w in mine) and sum(len(w) for w in mine) >= 3 and name.lower() not in ("downloads", "documents", "pictures", "desktop"):
            chain.insert(0, {"name": name, "made": False})
            folder = os.path.dirname(folder)
    return {"base": folder, "chain": chain, "name": os.path.basename(path)}


def learn(routine, path, source, since, when=None):
    """The routine after this save (None: nothing worth keeping)."""
    when = when or datetime.datetime.now().timestamp()
    shape = shape_of(path, since, source)
    example = {"source": source, "name": shape["name"], "folders": [step["name"] for step in shape["chain"]], "made": [step["made"] for step in shape["chain"]], "date": when, "base": shape["base"]}
    examples = [e for e in (routine or {}).get("examples", []) if len(e.get("folders", [])) == len(example["folders"])]
    examples = (examples + [example])[-6:]
    name = explain(example["name"], [{"source": e["source"], "name": e["name"], "date": e["date"]} for e in examples], keep_ext=True)
    folders = []
    for depth in range(len(example["folders"])):
        folders.append(explain(example["folders"][depth], [{"source": e["source"], "name": e["folders"][depth], "date": e["date"]} for e in examples], keep_ext=False))
    plain_name = name in ("{name}{ext}", "{name|words}{ext}")
    if not folders and plain_name:
        return None
    return {
        "base": shape["base"],
        "folders": folders,
        "make": example["made"],
        "name": name,
        "examples": examples,
        "count": len(examples),
        "learned": when,
    }


def plan(routine, source, context):
    """What the routine does for this name: { folder, path, make: [folders], steps: [text] }."""
    context = dict(context, source=source)
    folder = routine["base"]
    make = []
    steps = []
    for template in routine.get("folders", []):
        name = render(template, context).strip().replace("/", "-") or "Folder"
        folder = os.path.join(folder, name)
        if not os.path.isdir(folder):
            make.append(folder)
            steps.append(f"make the folder {name}")
        else:
            steps.append(f"go into {name}")
    name = render_free(routine["name"], context, folder).replace("/", "-")
    steps.append(f"save as {name}")
    return {"folder": folder, "path": os.path.join(folder, name), "make": make, "steps": steps}


def like_last(folder, source):
    """A name like the newest file's in the folder: its number one up, its
    date today, the rest kept. None when nothing is there."""
    try:
        names = [(os.stat(os.path.join(folder, n)).st_mtime, n) for n in os.listdir(folder) if not n.startswith(".") and os.path.isfile(os.path.join(folder, n))]
    except OSError:
        return None
    if not names:
        return None
    newest = max(names)[1]
    stem, ext = split_name(newest)
    _, source_ext = split_name(source or "")
    today = datetime.date.today()
    for fmt in DATE_FORMATS:
        for match in re.finditer(r"\d[\d.\-_]{3,9}\d", stem):
            try:
                datetime.datetime.strptime(match.group(0), fmt)
            except ValueError:
                continue
            stem = stem[:match.start()] + today.strftime(fmt) + stem[match.end():]
            return stem + (source_ext or ext)
    numbers = list(re.finditer(r"\d+", stem))
    if numbers:
        last = numbers[-1]
        bumped = str(int(last.group(0)) + 1).zfill(len(last.group(0)))
        stem = stem[:last.start()] + bumped + stem[last.end():]
        candidate = stem + (source_ext or ext)
        # one up again while taken
        while os.path.lexists(os.path.join(folder, candidate)):
            numbers = list(re.finditer(r"\d+", stem))
            last = numbers[-1]
            stem = stem[:last.start()] + str(int(last.group(0)) + 1).zfill(len(last.group(0))) + stem[last.end():]
            candidate = stem + (source_ext or ext)
        return candidate
    return stem + " 2" + (source_ext or ext)


def describe(template, source, context):
    """The template shown as what it makes now."""
    return render(template, dict(context, source=source))
