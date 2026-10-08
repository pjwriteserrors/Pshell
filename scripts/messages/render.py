"""A mail drawn the way its sender laid it out, in the colours of the shell.

The shell has no browser engine of its own, so a mail whose look matters – a
newsletter, a signature built from tables and pictures – is drawn by a
headless Chromium into a picture, with the places of its links beside it.
The mail's own scripts never run (its content security policy admits none;
the page is measured and recoloured from outside, over the browser's
DevTools pipe); its pictures are loaded, as a mail program does when it
shows a mail in full, but not waited for longer than a few seconds.

Mails are made for white paper. Before the picture is taken the page is
recoloured for the shell's palette: white becomes see-through, so the bubble
shows; greys and black become the shades between the shell's background and
its text; blue links wear the accent. What has a colour of its own – a brand
colour, a button, anything on a picture – keeps it, and coloured text is only
pushed as far as it takes to stay readable.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import select
import shutil
import signal
import subprocess
import threading
import time
from pathlib import Path

from store import CACHE

BROWSERS = ("chromium", "google-chrome-stable", "google-chrome", "chromium-browser", "brave", "vivaldi-stable")
# a page is as wide as a bubble shows it, pixel for pixel
WIDTH = 600
# a mail laid out wider than that is drawn as wide as it is, up to this: shrunk to fit, its type was too small to read
MAX_WIDTH = 960
# the smallest type a drawn mail shows, in points of the screen
SMALLEST = 12
# the tallest picture a graphics card takes, in its own pixels
MAX_PIXELS = 16000
# pictures an older way of drawing made are drawn again
REVISION = 5

# one mail at a time
BUSY = threading.Lock()

SCALE = [2.0]

# {"bg", "fg", "primary"} as #rrggbb; the shell says what it wears (daemon: theme)
THEME = {}

SCRIPT = r"""
const T = __THEME__, WIDTH = __WIDTH__, PLAIN = __PLAIN__, SMALLEST = __SMALLEST__;
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

(() => {
	// a mail still wider than the widest page is drawn a little smaller, by the browser itself, so it stays sharp
	let zoom = 1;
	if (document.documentElement.scrollWidth > WIDTH + 2) document.body.style.zoom = zoom = Math.max(0.8, WIDTH / document.documentElement.scrollWidth);
	// type too small to read is set in the smallest size that is; what a recipient sees keeps its sizes
	if (!PLAIN) for (const el of document.body.querySelectorAll("*")) {
		if (![...el.childNodes].some(node => node.nodeType === 3 && node.nodeValue.trim())) continue;
		const style = getComputedStyle(el), least = SMALLEST / zoom;
		if (!(parseFloat(style.fontSize) < least)) continue;
		const tight = style.lineHeight.endsWith("px") && parseFloat(style.lineHeight) < least * 1.25;
		el.style.setProperty("font-size", `${least}px`, "important");
		if (tight) el.style.setProperty("line-height", "1.3", "important");
	}
	// the paper a recipient sees keeps the colours it was sent in
	if (!PLAIN) try { recolour(); } catch (error) {}
	const root = document.documentElement;
	// where the mail really ends: the lowest edge of anything in it
	let bottom = document.body.getBoundingClientRect().bottom;
	for (const el of document.body.querySelectorAll("*")) { const r = el.getBoundingClientRect(); if (r.width > 0 && r.height > 0 && r.bottom > bottom) bottom = r.bottom; }
	bottom = Math.ceil(bottom + scrollY);
	const links = [...document.querySelectorAll("a[href]")].map(a => { const r = a.getBoundingClientRect(); return { x: r.x + scrollX, y: r.y + scrollY, w: r.width, h: r.height, href: a.href }; }).filter(l => l.w > 0 && l.h > 0 && /^(https?|mailto|tel):/.test(l.href));
	// every word with its place, in reading order, so the picture's text can be marked: [x, y, w, h, word, block]
	const words = [];
	{
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
	// the pictures in it that are worth a closer look: not the small ones, not the ones that are a link
	const images = [...document.querySelectorAll("img")].filter(i => !i.closest("a[href]") && i.naturalWidth > 1).map(i => { const r = i.getBoundingClientRect(); return { x: r.x + scrollX, y: r.y + scrollY, w: r.width, h: r.height, src: i.currentSrc || i.src }; }).filter(i => i.w >= 48 && i.h >= 48 && /^(https?|file):/.test(i.src));
	return JSON.stringify({ h: bottom, links, images, words });
})()
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


def page(body, plain=False):
    """A page of its own, in which no script runs. `plain`: on white paper, as a mail program shows it."""
    return (
        "<!doctype html><meta charset=\"utf-8\">"
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src https: http: file: data:; style-src 'unsafe-inline' https:; font-src https: data:; script-src 'none'\">"
        "<style>html,body{margin:0;background:transparent;color:#000}body{padding:2px;font-family:'Adwaita Sans',sans-serif;font-size:13px;overflow-wrap:anywhere}img{max-width:100%}</style>"
        + ("<style>html,body{background:#fff}body{padding:14px}</style>" if plain else "")
        + body
    )


class Browser:
    """One headless Chromium that stays up while mails are drawn, spoken to over its DevTools pipe.

    Starting a browser per mail took most of the time, and one started for a
    single picture waits for every picture of the mail, however long its
    server takes. This one is told to go on after a few seconds.
    """

    IDLE = 120
    # how long a mail's pictures are waited for
    PATIENCE = 3

    def __init__(self):
        self.process = None
        self.session = None
        self.writer = self.reader = -1
        self.buffer = b""
        self.count = 0
        self.events = []
        self.closer = None

    def start(self):
        program = browser()
        if program is None:
            raise RuntimeError("Chromium is needed to draw this mail")
        command_read, self.writer = os.pipe()
        self.reader, answer_write = os.pipe()
        self.process = subprocess.Popen(
            ["sh", "-c", f'exec "$0" "$@" 3<&{command_read} 4>&{answer_write}', program, "--headless=new", "--remote-debugging-pipe",
             "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--hide-scrollbars",
             f"--user-data-dir={CACHE / 'chromium'}", "about:blank"],
            pass_fds=(command_read, answer_write), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        os.close(command_read)
        os.close(answer_write)
        self.buffer, self.events, self.session = b"", [], None
        target = self.call("Target.createTarget", {"url": "about:blank"}, timeout=20)["targetId"]
        self.session = self.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
        self.call("Page.enable")
        self.call("Emulation.setDefaultBackgroundColorOverride", {"color": {"r": 0, "g": 0, "b": 0, "a": 0}})

    def stop(self):
        process, self.process = self.process, None
        for descriptor in (self.writer, self.reader):
            try:
                os.close(descriptor)
            except OSError:
                pass
        self.writer = self.reader = -1
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass

    def read(self, deadline):
        """The next message, or None when the time is up."""
        while b"\0" not in self.buffer:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([self.reader], [], [], left)[0]:
                return None
            chunk = os.read(self.reader, 1 << 20)
            if not chunk:
                raise RuntimeError("The browser went away")
            self.buffer += chunk
        raw, _, self.buffer = self.buffer.partition(b"\0")
        return json.loads(raw)

    def call(self, method, params=None, timeout=20):
        self.count += 1
        message = {"id": self.count, "method": method, "params": params or {}}
        if self.session:
            message["sessionId"] = self.session
        os.write(self.writer, json.dumps(message).encode() + b"\0")
        deadline = time.monotonic() + timeout
        while True:
            answer = self.read(deadline)
            if answer is None:
                raise RuntimeError("The browser does not answer")
            if answer.get("id") == self.count:
                if "error" in answer:
                    raise RuntimeError(answer["error"].get("message", "The browser refused"))
                return answer.get("result", {})
            if "method" in answer:
                self.events.append(answer["method"])

    def wait(self, event, timeout):
        deadline = time.monotonic() + timeout
        while event not in self.events:
            answer = self.read(deadline)
            if answer is None:
                return False
            if "method" in answer:
                self.events.append(answer["method"])
        return True

    def draw(self, shown, factor, limit, plain=False):
        """The page as PNG bytes, what the script measured, and its height and width."""
        if self.process is None or self.process.poll() is not None:
            self.stop()
            self.start()
        self.call("Emulation.setDeviceMetricsOverride", {"width": WIDTH, "height": 200, "deviceScaleFactor": factor, "mobile": False})
        self.events.clear()
        self.call("Page.navigate", {"url": f"file://{shown}"})
        self.wait("Page.loadEventFired", self.PATIENCE)
        # a mail with a layout wider than the page gets the room it was made for
        needed = int(self.call("Runtime.evaluate", {"expression": "document.documentElement.scrollWidth", "returnByValue": True})["result"].get("value") or WIDTH)
        width = WIDTH if needed <= WIDTH + 2 else min(MAX_WIDTH, needed)
        if width != WIDTH:
            self.call("Emulation.setDeviceMetricsOverride", {"width": width, "height": 200, "deviceScaleFactor": factor, "mobile": False})
        script = (SCRIPT.replace("__THEME__", json.dumps(theme())).replace("__WIDTH__", str(width))
                  .replace("__PLAIN__", "true" if plain else "false").replace("__SMALLEST__", str(SMALLEST)))
        measured = json.loads(self.call("Runtime.evaluate", {"expression": script, "returnByValue": True})["result"]["value"])
        height = max(4, min(limit, int(measured["h"])))
        shot = self.call("Page.captureScreenshot", {
            "format": "png", "captureBeyondViewport": True, "clip": {"x": 0, "y": 0, "width": width, "height": height, "scale": 1},
        }, timeout=40)
        return base64.b64decode(shot["data"]), measured, height, width

    def rest(self):
        """Leaves when nothing was drawn for a while."""
        if self.closer is not None:
            self.closer.cancel()

        def close():
            with BUSY:
                self.stop()

        self.closer = threading.Timer(self.IDLE, close)
        self.closer.daemon = True
        self.closer.start()


BROWSER = Browser()


def trim(target, factor):
    """Takes the empty paper off the picture's right: a short note is as wide as its words."""
    from PIL import Image
    with Image.open(target) as picture:
        picture = picture.convert("RGBA")
        inked = picture.getchannel("A").getbbox()
        right = min(picture.width, max(int(40 * factor), (inked[2] if inked else 0) + int(2 * factor)))
        if right < picture.width:
            picture.crop((0, 0, right, picture.height)).save(target)
        return right / factor


def render(source, target, plain=False):
    """Draws the markup in `source`; returns {"image", "width", "height", "links", "images", "text", "theme"} in points.

    `plain` draws it the way it reaches someone else: on white, in its own colours.
    """
    source = Path(source)
    worn, factor = (f"plain@{scale():g}/{REVISION}" if plain else theme_key()), scale()
    # a picture per palette: one that is replaced must not be shown from a cache
    target = Path(target).with_name(f"{Path(target).stem}-{hashlib.sha1(worn.encode()).hexdigest()[:8]}.png")
    shown = source.with_name("shown.html")
    with BUSY:
        try:
            shown.write_text(page(source.read_text(), plain))
            try:
                data, measured, height, drawn = BROWSER.draw(shown, factor, int(MAX_PIXELS / factor), plain)
            except (RuntimeError, OSError, ValueError, KeyError):
                # a browser that hung or died gets one fresh start
                BROWSER.stop()
                data, measured, height, drawn = BROWSER.draw(shown, factor, int(MAX_PIXELS / factor), plain)
            target.write_bytes(data)
            width = drawn if plain else trim(target, factor)
        except (OSError, ValueError, KeyError) as error:
            BROWSER.stop()
            raise RuntimeError(f"The mail could not be drawn ({type(error).__name__})")
        except RuntimeError:
            BROWSER.stop()
            raise
        finally:
            BROWSER.rest()
    text = target.with_suffix(".json")
    text.write_text(json.dumps([word for word in measured.get("words", []) if word[1] < height], ensure_ascii=False))
    links = [link for link in measured.get("links", [])[:300] if link["y"] < height]
    images = [image for image in measured.get("images", [])[:80] if image["y"] < height]
    return {"image": str(target), "width": width, "height": height, "links": links, "images": images, "text": str(text), "theme": worn}


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
