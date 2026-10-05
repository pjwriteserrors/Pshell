"""A mail drawn the way its sender laid it out, in the colours of the shell.

The shell has no browser engine of its own, so a mail whose look matters – a
newsletter, a signature built from tables and pictures – is drawn by a
headless Chromium into a picture, with the places of its links beside it.
The mail's own scripts never run (a content security policy admits only the
one that measures and recolours the page); its pictures are loaded, as a mail
program does when it shows a mail in full.

Mails are made for white paper. Before the picture is taken the page is
recoloured for the shell's palette: white becomes see-through, so the bubble
shows; greys and black become the shades between the shell's background and
its text; blue links wear the accent. What has a colour of its own – a brand
colour, a button, anything on a picture – keeps it, and coloured text is only
pushed as far as it takes to stay readable.
"""

from __future__ import annotations

import hashlib
import html
import json
import os
import re
import secrets
import shutil
import subprocess
import threading
from pathlib import Path

from store import CACHE

BROWSERS = ("chromium", "google-chrome-stable", "google-chrome", "chromium-browser", "brave", "vivaldi-stable")
# a page is as wide as a bubble shows it, pixel for pixel
WIDTH = 600
# the tallest picture a graphics card takes, in its own pixels
MAX_PIXELS = 16000
MARKER = (1, 254, 3)
# pictures an older way of drawing made are drawn again
REVISION = 2

# one browser at a time: they share a profile
BUSY = threading.Lock()

SCALE = [2.0]

# {"bg", "fg", "primary"} as #rrggbb; the shell says what it wears (daemon: theme)
THEME = {}

SCRIPT = r"""
const T = __THEME__, ZOOM = __ZOOM__, MARK = __MARK__, WORDS = __WORDS__;
const rgb = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const BG = rgb(T.bg), FG = rgb(T.fg), AC = rgb(T.primary);
const parse = c => { const m = /rgba?\(([^)]+)\)/.exec(c || ""); if (!m) return null; const p = m[1].split(/[,\s\/]+/).filter(x => x !== "").map(Number); return { c: [p[0], p[1], p[2]], a: p.length > 3 ? p[3] : 1 }; };
const light = c => (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255;
const neutral = c => Math.max(...c) - Math.min(...c) < 30;
const lin = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
const lum = c => 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2]);
const contrast = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
const blend = (a, b, t) => a.map((v, i) => Math.round(v * (1 - t) + b[i] * t));
// white paper is the shell's background, black ink its text
const shade = c => blend(FG, BG, light(c));
const css = (c, a) => a === undefined || a >= 1 ? `rgb(${c.join(",")})` : `rgba(${c.join(",")},${a})`;
const hue = c => { const [r, g, b] = c, mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn; if (!d) return -1; const h = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4; return (h * 60 + 360) % 360; };
const readable = (c, on) => { let out = c; for (let i = 1; i <= 10 && contrast(out, on) < 3.6; i += 1) out = blend(c, FG, i / 10); return out; };

function recolour() {
	const all = [...document.querySelectorAll("*")];
	// first what every element is, then the changes: a change must not colour what is read after it
	const kinds = new Map(), plans = [];
	for (const el of all) {
		const s = getComputedStyle(el), bg = parse(s.backgroundColor);
		let kind = "none";
		const plan = { el, set: [] };
		if (s.backgroundImage !== "none" || el.tagName === "IMG") kind = "kept";
		else if (bg && bg.a > 0.04) {
			if (neutral(bg.c)) {
				kind = "shaded";
				plan.set.push(["background-color", light(bg.c) > 0.965 ? "transparent" : css(shade(bg.c), bg.a)]);
			} else kind = "kept";
		}
		kinds.set(el, kind);
		plan.style = s;
		plans.push(plan);
	}
	const under = el => { for (let at = el; at; at = at.parentElement) { const kind = kinds.get(at); if (kind && kind !== "none") return kind; } return "shaded"; };
	for (const plan of plans) {
		const { el, style } = plan;
		const ground = under(el);
		const ink = parse(style.color);
		if (ink && ground !== "kept") {
			if (neutral(ink.c)) plan.set.push(["color", css(shade(ink.c), ink.a)]);
			else {
				const h = hue(ink.c);
				// the blue of a link that was never given a colour of its own
				plan.set.push(["color", css(el.closest("a") && h >= 195 && h <= 255 ? AC : readable(ink.c, BG), ink.a)]);
			}
		}
		for (const side of ["top", "right", "bottom", "left"]) {
			if (parseFloat(style.getPropertyValue(`border-${side}-width`)) <= 0) continue;
			const line = parse(style.getPropertyValue(`border-${side}-color`));
			if (line && neutral(line.c) && ground !== "kept") plan.set.push([`border-${side}-color`, css(shade(line.c), line.a)]);
		}
	}
	for (const plan of plans) for (const [name, value] of plan.set) plan.el.style.setProperty(name, value, "important");
}

addEventListener("load", () => {
	// a mail wider than the bubble is drawn smaller, by the browser itself, so it stays sharp
	if (ZOOM !== 1) document.body.style.zoom = ZOOM;
	try { recolour(); } catch (error) {}
	const root = document.documentElement;
	// where the mail really ends: the lowest edge of anything in it
	let bottom = document.body.getBoundingClientRect().bottom;
	for (const el of document.body.querySelectorAll("*")) { const r = el.getBoundingClientRect(); if (r.width > 0 && r.height > 0 && r.bottom > bottom) bottom = r.bottom; }
	bottom = Math.ceil(bottom + scrollY);
	if (MARK) {
		// a line the picture is cut at, so nothing depends on a height measured in another run
		const line = document.createElement("div");
		line.style.cssText = `position:absolute;left:0;top:${bottom}px;width:12px;height:6px;background:rgb(1,254,3);z-index:2147483647`;
		root.appendChild(line);
	}
	const links = [...document.querySelectorAll("a[href]")].map(a => { const r = a.getBoundingClientRect(); return { x: r.x + scrollX, y: r.y + scrollY, w: r.width, h: r.height, href: a.href }; }).filter(l => l.w > 0 && l.h > 0 && /^(https?|mailto|tel):/.test(l.href));
	// every word with its place, in reading order, so the picture's text can be marked: [x, y, w, h, word, block]
	const words = [];
	if (WORDS) {
		const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), range = document.createRange(), tenth = v => Math.round(v * 10) / 10;
		const blockOf = n => { for (let e = n.parentElement; e; e = e.parentElement) { const d = getComputedStyle(e).display; if (!d.startsWith("inline") && d !== "contents") return e; } return document.body; };
		let node, block = null, count = 0;
		while ((node = walker.nextNode()) && words.length < 12000) {
			const text = node.nodeValue;
			if (!text.trim() || !node.parentElement) continue;
			const style = getComputedStyle(node.parentElement);
			if (style.visibility === "hidden" || style.display === "none") continue;
			const own = blockOf(node);
			if (own !== block) { block = own; count += 1; }
			const pieces = /\S+/g;
			let found;
			while ((found = pieces.exec(text))) {
				range.setStart(node, found.index);
				range.setEnd(node, found.index + found[0].length);
				const r = range.getClientRects()[0];
				if (r && r.width > 0 && r.height > 0) words.push([tenth(r.x + scrollX), tenth(r.y + scrollY), tenth(r.width), tenth(r.height), found[0], count]);
			}
		}
	}
	root.setAttribute("data-pshell", JSON.stringify({ w: root.scrollWidth, h: bottom, links, words }));
});
"""


def theme():
    """What the shell wears; until it said so, what wallust wrote."""
    if THEME:
        return THEME
    try:
        cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "wal" / "colors.json"
        wal = json.loads(cache.read_text())
        return {"bg": wal["special"]["background"][:7].lower(), "fg": wal["special"]["foreground"][:7].lower(), "primary": wal["colors"]["color4"][:7].lower()}
    except (OSError, ValueError, KeyError):
        return {"bg": "#141414", "fg": "#e6e6e6", "primary": "#6f9fd8"}


def scale():
    """Pixels per point of the screen the pictures are shown on."""
    return SCALE[0]


def theme_key():
    worn = theme()
    return f"{worn['bg']}{worn['fg']}{worn['primary']}@{scale():g}/{REVISION}"


def set_theme(colours):
    """Returns whether the palette changed."""
    worn = {key: str(colours.get(key, ""))[:7].lower() for key in ("bg", "fg", "primary")}
    try:
        wanted = min(4.0, max(1.0, float(colours.get("scale") or scale())))
    except (TypeError, ValueError):
        wanted = scale()
    if not all(re.fullmatch(r"#[0-9a-f]{6}", value) for value in worn.values()) or (worn == THEME and wanted == scale()):
        return False
    THEME.clear()
    THEME.update(worn)
    SCALE[0] = wanted
    return True


def browser():
    return next((path for name in BROWSERS if (path := shutil.which(name))), None)


def page_source(body, images=None):
    """The mail's own markup with its inner pictures by file; render() makes the page of it."""

    def picture(match):
        path = (images or {}).get(match.group(1))
        return f"file://{path}" if path else match.group(0)

    return re.sub(r"""cid:([^"'\s>)]+)""", picture, str(body or ""))


def page(body, zoom=1.0, mark=False, words=False):
    """A page of its own: no script but the measuring and recolouring one."""
    nonce = secrets.token_hex(12)
    script = SCRIPT.replace("__THEME__", json.dumps(theme())).replace("__ZOOM__", f"{zoom:.4f}").replace("__MARK__", "true" if mark else "false").replace("__WORDS__", "true" if words else "false")
    return (
        "<!doctype html><meta charset=\"utf-8\">"
        f"<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src https: http: file: data:; style-src 'unsafe-inline' https:; font-src https: data:; script-src 'nonce-{nonce}'\">"
        "<style>html,body{margin:0;background:transparent;color:#000}body{padding:2px;font-family:'Adwaita Sans',sans-serif;font-size:13px;overflow-wrap:anywhere}img{max-width:100%}</style>"
        f"<script nonce=\"{nonce}\">{script}</script>" + body
    )


def run(arguments, timeout=40):
    program = browser()
    if program is None:
        raise RuntimeError("Chromium is needed to draw this mail")
    command = [
        program, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-extensions",
        "--hide-scrollbars", "--virtual-time-budget=5000", "--default-background-color=00000000", f"--user-data-dir={CACHE / 'chromium'}", *arguments,
    ]
    with BUSY:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout, errors="replace")


def measure(shown):
    # a low window: the page's height is its own, not the window's
    done = run([f"--window-size={WIDTH},100", "--dump-dom", f"file://{shown}"])
    found = re.search(r'data-pshell="([^"]*)"', done.stdout)
    if not found:
        raise RuntimeError("The mail could not be drawn")
    return json.loads(html.unescape(found.group(1)))


def cut(target, factor):
    """Cuts the picture at the line the page drew under itself and takes the empty paper off its right.

    Returns (width, height) in points, or None when the line is not on it.
    """
    from PIL import Image
    with Image.open(target) as picture:
        picture = picture.convert("RGBA")
        column = picture.crop((int(3 * factor), 0, int(3 * factor) + 1, picture.height)).getdata()
        row = next((index for index, pixel in enumerate(column) if pixel[:3] == MARKER and pixel[3] == 255), None)
        if row is None:
            return None
        picture = picture.crop((0, 0, picture.width, max(1, row)))
        # a short note is as wide as its words, not as the page
        inked = picture.getchannel("A").getbbox()
        right = min(picture.width, max(int(40 * factor), (inked[2] if inked else 0) + int(2 * factor)))
        picture = picture.crop((0, 0, right, picture.height))
        picture.save(target)
    return picture.width / factor, picture.height / factor


def render(source, target):
    """Draws the markup in `source`; returns {"image", "width", "height", "links", "theme"} in points."""
    source = Path(source)
    worn, factor = theme_key(), scale()
    # a picture per palette: one that is replaced must not be shown from a cache
    target = Path(target).with_name(f"{Path(target).stem}-{hashlib.sha1(worn.encode()).hexdigest()[:8]}.png")
    shown = source.with_name("shown.html")
    limit = int(MAX_PIXELS / factor)
    try:
        body = source.read_text()
        shown.write_text(page(body))
        measured = measure(shown)
        zoom = 1.0
        if measured["w"] > WIDTH + 2:
            zoom = max(0.4, WIDTH / measured["w"])
            shown.write_text(page(body, zoom))
            measured = measure(shown)
        size = None
        # pictures of the mail may arrive between two runs and move its end: room to spare, then the cut
        for window in dict.fromkeys([min(limit, int(measured["h"]) + 1200), limit]):
            shown.write_text(page(body, zoom, mark=True))
            run([f"--window-size={WIDTH},{window}", f"--force-device-scale-factor={factor:g}", f"--screenshot={target}", f"file://{shown}"])
            if not target.exists() or target.stat().st_size == 0:
                raise RuntimeError("The mail could not be drawn")
            size = cut(target, factor)
            if size is not None:
                break
        # longer than a picture can be: what fits is shown
        width, height = size if size is not None else (WIDTH, limit)
        # links and words as the picture has them: its pictures are loaded by now
        shown.write_text(page(body, zoom, words=True))
        measured = measure(shown)
        text = target.with_suffix(".json")
        text.write_text(json.dumps([word for word in measured.get("words", []) if word[1] < height], ensure_ascii=False))
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        raise RuntimeError(f"The mail could not be drawn ({type(error).__name__})")
    links = [{"x": link["x"], "y": link["y"], "w": link["w"], "h": link["h"], "href": link["href"]} for link in measured.get("links", [])[:300] if link["y"] < height]
    return {"image": str(target), "width": width, "height": height, "links": links, "text": str(text), "theme": worn}


def current(drawn):
    """Whether a picture made earlier still wears what the shell wears."""
    return bool(drawn) and drawn.get("theme") == theme_key() and os.path.isfile(drawn.get("image", ""))


def fragment(piece):
    """A piece of a mail – a signature – drawn on its own. The same piece is drawn once per palette.

    `piece` is markup as page_source() returns it. Returns what render()
    returns, or None when it cannot be drawn.
    """
    if not str(piece or "").strip():
        return None
    key = hashlib.sha1((theme_key() + piece).encode()).hexdigest()[:24]
    folder = CACHE / "pieces" / key
    kept = folder / "page.json"
    try:
        drawn = json.loads(kept.read_text())
        if current(drawn):
            return drawn
    except (OSError, ValueError):
        pass
    try:
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "page.html").write_text(piece)
        drawn = render(folder / "page.html", folder / "page.png")
        kept.write_text(json.dumps(drawn))
        return drawn
    except (RuntimeError, OSError):
        return None
