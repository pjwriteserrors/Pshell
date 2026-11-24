"""A small HTML tree and the CSS selectors the browser's watch picker writes
(docs/core.md "Watches"), with the standard library only (core has aiohttp
and nothing else).

Selectors: tag, `#id`, `.class`, `[attr]`, `[attr="v"]`, `[attr^="v"]`,
`[attr*="v"]`, `[attr$="v"]`, `:nth-of-type(n)`, `:nth-child(n)`,
`:first-of-type`, `:last-of-type`; combinators ` ` and `>`; lists with `,`.

Also what a product page says of itself: schema.org Product/Offer (JSON-LD
and microdata) and the `product:price` meta tags; and prices in text.
"""
import html
import json
import re
from html.parser import HTMLParser

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
# an open one of these ends when the next of its kind (or a sibling kind) starts
CLOSES = {"li": {"li"}, "p": {"p", "div", "ul", "ol", "table", "section", "h1", "h2", "h3", "h4", "h5", "h6"},
          "option": {"option"}, "tr": {"tr"}, "td": {"td", "th", "tr"}, "th": {"td", "th", "tr"},
          "dt": {"dt", "dd"}, "dd": {"dt", "dd"}}
SKIP_TEXT = {"script", "style", "noscript", "template", "head"}
MAX_NODES = 60000


class Node:
    __slots__ = ("tag", "attrs", "children", "parent", "text")

    def __init__(self, tag, attrs=None, parent=None):
        self.tag = tag
        self.attrs = attrs or {}
        self.children = []      # Node or str
        self.parent = parent
        self.text = None

    def elements(self):
        return [c for c in self.children if isinstance(c, Node)]

    def walk(self):
        stack = [self]
        while stack:
            node = stack.pop()
            yield node
            stack.extend(reversed(node.elements()))

    def classes(self):
        return self.attrs.get("class", "").split()

    def inner_text(self, limit=4000):
        out = []
        size = 0
        stack = [self]
        while stack and size < limit:
            node = stack.pop()
            if isinstance(node, str):
                out.append(node)
                size += len(node)
                continue
            if node.tag in SKIP_TEXT and node is not self:
                continue
            if node.tag in ("br", "p", "div", "li", "tr", "td", "th"):
                out.append(" ")
            stack.extend(reversed(node.children))
        return re.sub(r"\s+", " ", "".join(out)).strip()[:limit]


class Builder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root")
        self.stack = [self.root]
        self.count = 0

    def handle_starttag(self, tag, attrs):
        if self.count >= MAX_NODES:
            return
        self.count += 1
        closes = None
        for open_tag, by in CLOSES.items():
            if tag in by:
                closes = closes or set()
                closes.add(open_tag)
        if closes:
            lowest = None
            for i in range(len(self.stack) - 1, 0, -1):
                if self.stack[i].tag in closes:
                    lowest = i
                elif self.stack[i].tag in ("ul", "ol", "table", "tbody", "thead", "select", "dl", "div"):
                    break
            if lowest is not None:
                del self.stack[lowest:]
        parent = self.stack[-1]
        node = Node(tag, {k: (v if v is not None else "") for k, v in attrs}, parent)
        parent.children.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack[-1].tag == tag:
            self.stack.pop()

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        if self.count < MAX_NODES:
            self.stack[-1].children.append(data)


def parse(text):
    builder = Builder()
    try:
        builder.feed(text)
        builder.close()
    except Exception:  # noqa: BLE001 – what was read so far is the page
        pass
    return builder.root


# ── selectors ──────────────────────────────────────────────────────────────
TOKEN = re.compile(r"""
    (?P<space>\s*>\s*|\s+)
  | (?P<tag>[a-zA-Z][a-zA-Z0-9-]*|\*)
  | \#(?P<id>(?:[\w-]|\\.)+)
  | \.(?P<cls>(?:[\w-]|\\.)+)
  | \[\s*(?P<attr>[\w:-]+)\s*(?:(?P<op>[~^$*|]?=)\s*(?:"(?P<dq>[^"]*)"|'(?P<sq>[^']*)'|(?P<bare>[^\]\s]+)))?\s*\]
  | :(?P<pseudo>nth-of-type|nth-child|first-of-type|last-of-type|first-child|last-child)(?:\(\s*(?P<n>\d+)\s*\))?
""", re.X)


class BadSelector(ValueError):
    pass


def unescape(text):
    return re.sub(r"\\(.)", r"\1", text)


def compile_one(selector):
    """→ [(combinator, [tests])], combinator of the first part is None"""
    parts = []
    tests = []
    comb = None
    pos = 0
    selector = selector.strip()
    if not selector:
        raise BadSelector("empty selector")
    while pos < len(selector):
        m = TOKEN.match(selector, pos)
        if not m or m.end() == pos:
            raise BadSelector(f"cannot read the selector at {selector[pos:pos + 20]!r}")
        pos = m.end()
        if m.group("space") is not None:
            if not tests:
                raise BadSelector("a combinator needs something before it")
            parts.append((comb, tests))
            tests = []
            comb = ">" if ">" in m.group("space") else " "
        elif m.group("tag"):
            if m.group("tag") != "*":
                tests.append(("tag", m.group("tag").lower()))
        elif m.group("id"):
            tests.append(("attr", "id", "=", unescape(m.group("id"))))
        elif m.group("cls"):
            tests.append(("class", unescape(m.group("cls"))))
        elif m.group("attr"):
            value = next((v for v in (m.group("dq"), m.group("sq"), m.group("bare")) if v is not None), None)
            tests.append(("attr", m.group("attr").lower(), m.group("op"), value))
        else:
            tests.append(("pseudo", m.group("pseudo"), int(m.group("n") or 0)))
    if not tests:
        raise BadSelector("the selector ends in a combinator")
    parts.append((comb, tests))
    return parts


def compile_selector(selector):
    if len(selector) > 2000:
        raise BadSelector("selector too long")
    parts = split_list(selector)
    if not parts:
        raise BadSelector("empty selector")
    return [compile_one(part) for part in parts]


def split_list(selector):
    out, depth, quote, current = [], 0, "", []
    for ch in selector:
        if quote:
            quote = "" if ch == quote else quote
        elif ch in "\"'":
            quote = ch
        elif ch in "[(":
            depth += 1
        elif ch in "])":
            depth -= 1
        elif ch == "," and depth == 0:
            out.append("".join(current))
            current = []
            continue
        current.append(ch)
    out.append("".join(current))
    return [part for part in out if part.strip()]


def test(node, t):
    kind = t[0]
    if kind == "tag":
        return node.tag == t[1]
    if kind == "class":
        return t[1] in node.classes()
    if kind == "attr":
        _, name, op, value = t
        if name not in node.attrs:
            return False
        have = node.attrs[name]
        if op is None:
            return True
        if op == "=":
            return have == value
        if op == "~=":
            return value in have.split()
        if op == "^=":
            return bool(value) and have.startswith(value)
        if op == "$=":
            return bool(value) and have.endswith(value)
        if op == "*=":
            return bool(value) and value in have
        if op == "|=":
            return have == value or have.startswith(value + "-")
        return False
    _, pseudo, n = t
    parent = node.parent
    siblings = parent.elements() if parent else [node]
    if "of-type" in pseudo:
        siblings = [s for s in siblings if s.tag == node.tag]
    index = siblings.index(node) + 1
    if pseudo.startswith("nth"):
        return index == n
    if pseudo.startswith("first"):
        return index == 1
    return index == len(siblings)


def matches(node, parts, i=None):
    i = len(parts) - 1 if i is None else i
    comb, tests = parts[i]
    if node.tag == "#root" or not all(test(node, t) for t in tests):
        return False
    if i == 0:
        return True
    if comb == ">":
        return node.parent is not None and matches(node.parent, parts, i - 1)
    up = node.parent
    while up is not None:
        if matches(up, parts, i - 1):
            return True
        up = up.parent
    return False


def select(root, selector, limit=50):
    compiled = compile_selector(selector)
    out = []
    for node in root.walk():
        if any(matches(node, parts) for parts in compiled):
            out.append(node)
            if len(out) >= limit:
                break
    return out


def value_of(node, attr=""):
    if attr:
        return re.sub(r"\s+", " ", node.attrs.get(attr, "")).strip()[:4000]
    if node.tag == "meta":
        return node.attrs.get("content", "").strip()
    if node.tag in ("input", "data"):
        return node.attrs.get("value", "").strip()
    return node.inner_text()


# ── prices ─────────────────────────────────────────────────────────────────
CURRENCIES = {"€": "EUR", "eur": "EUR", "euro": "EUR", "$": "USD", "usd": "USD", "£": "GBP", "gbp": "GBP",
              "chf": "CHF", "fr.": "CHF", "kr": "SEK", "zł": "PLN", "pln": "PLN"}
NUMBER = re.compile(r"(?<![\d.,])(\d{1,3}(?:[.,'   ]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?:[.,]-{1,2})?(?![\d])")


def number_of(text):
    """'1.299,00' 1299.0, '1,299.00' 1299.0, '12,99' 12.99, '1.299' 1299.0"""
    raw = re.sub(r"[  ' ]", "", str(text).strip())
    if not raw:
        return None
    if "," in raw and "." in raw:
        dec = "," if raw.rfind(",") > raw.rfind(".") else "."
        raw = raw.replace("." if dec == "," else ",", "").replace(dec, ".")
    elif "," in raw or "." in raw:
        sep = "," if "," in raw else "."
        head, _, tail = raw.rpartition(sep)
        if len(tail) == 3 and (raw.count(sep) > 1 or head.strip("0") != ""):
            raw = raw.replace(sep, "")
        else:
            raw = head.replace(sep, "") + "." + tail
    try:
        return float(raw)
    except ValueError:
        return None


def price_of(text):
    """→ (amount, currency or "") from text such as '€ 1.299,00', 'EUR 12,99', '12.-', or (None, "")"""
    text = html.unescape(str(text or ""))[:400]
    m = NUMBER.search(text)
    if not m:
        return None, ""
    amount = number_of(m.group(1))
    low = text.lower()
    currency = ""
    best = 10 ** 6
    for sign, code in CURRENCIES.items():
        at = low.find(sign)
        if at >= 0 and abs(at - m.start()) < best:
            best, currency = abs(at - m.start()), code
    return amount, currency


def json_blocks(root):
    for node in root.walk():
        if node.tag == "script" and "ld+json" in node.attrs.get("type", "").lower():
            text = "".join(c for c in node.children if isinstance(c, str)).strip()
            text = re.sub(r"^\s*<!--|-->\s*$", "", text)
            try:
                yield json.loads(text)
            except ValueError:
                try:
                    yield json.loads(re.sub(r"[\x00-\x1f]", " ", text))
                except ValueError:
                    continue


def things(data, depth=0):
    if depth > 8:
        return
    if isinstance(data, list):
        for item in data:
            yield from things(item, depth + 1)
    elif isinstance(data, dict):
        yield data
        for key in ("@graph", "mainEntity", "itemListElement", "item", "hasVariant"):
            if key in data:
                yield from things(data[key], depth + 1)


def is_a(thing, kind):
    types = thing.get("@type")
    types = types if isinstance(types, list) else [types]
    return any(str(t).split("/")[-1] == kind for t in types)


def offer_price(offers):
    for offer in offers if isinstance(offers, list) else [offers]:
        if not isinstance(offer, dict):
            continue
        for key in ("price", "lowPrice"):
            value = offer.get(key)
            if value not in (None, ""):
                amount = value if isinstance(value, (int, float)) else number_of(value)
                if amount is not None:
                    return float(amount), str(offer.get("priceCurrency") or "")
        spec = offer.get("priceSpecification")
        if spec:
            found = offer_price(spec)
            if found[0] is not None:
                return found
        if offer.get("offers"):
            found = offer_price(offer["offers"])
            if found[0] is not None:
                return found
    return None, ""


def first_text(value):
    if isinstance(value, list):
        value = value[0] if value else ""
    if isinstance(value, dict):
        value = value.get("url") or value.get("contentUrl") or value.get("name") or ""
    return str(value or "").strip()


def product_of(root):
    """→ {title, price, currency, image, how} of a product page; price None when it says none"""
    out = {"title": "", "price": None, "currency": "", "image": "", "how": ""}
    for block in json_blocks(root):
        for thing in things(block):
            if not (is_a(thing, "Product") or is_a(thing, "ProductGroup")):
                continue
            out["title"] = out["title"] or first_text(thing.get("name"))[:200]
            out["image"] = out["image"] or first_text(thing.get("image"))[:1000]
            amount, currency = offer_price(thing.get("offers") or [])
            if amount is not None and out["price"] is None:
                out.update(price=amount, currency=currency, how="schema")
    metas = {}
    for node in root.walk():
        if node.tag == "meta":
            key = (node.attrs.get("property") or node.attrs.get("name") or node.attrs.get("itemprop") or "").lower()
            if key and key not in metas:
                metas[key] = node.attrs.get("content", "")
    if out["price"] is None:
        for node in root.walk():
            if node.attrs.get("itemprop") == "price":
                amount = number_of(node.attrs.get("content") or "") if node.attrs.get("content") else price_of(node.inner_text(200))[0]
                if amount is not None:
                    currency = next((n.attrs.get("content", "") for n in root.walk() if n.attrs.get("itemprop") == "priceCurrency"), "")
                    out.update(price=amount, currency=currency, how="microdata")
                    break
    if out["price"] is None:
        for key in ("product:price:amount", "og:price:amount"):
            if metas.get(key):
                amount = number_of(metas[key])
                if amount is not None:
                    out.update(price=amount, currency=metas.get(key.replace("amount", "currency"), ""), how="meta")
                    break
    if not out["title"]:
        out["title"] = metas.get("og:title", "").strip()[:200]
    if not out["title"]:
        title = next((n for n in root.walk() if n.tag == "title"), None)
        out["title"] = title.inner_text(200) if title else ""
    out["image"] = out["image"] or metas.get("og:image", "")[:1000]
    return out
