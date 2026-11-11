pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Pshell menu in the browser (plugin `browser-menu`, docs/browser.md):
// which entries it has and what they do. WebLink sends `entries` to the
// extension, which shows them under "Pshell" in the page's context menu; a
// click comes back as run(action, info).
//
// An entry: { id, title, contexts: ["selection" | "link" | "image" | "video" |
//             "audio" | "page" | "tab"], group, targets?, documents? }
//           targets: URL patterns the link or media must match
//           (menus targetUrlPatterns), documents: of the page (documentUrlPatterns)
// info:     { kind, text, link, linkText, src, page, title, tabId, private, source }
//           `private`: it came from a private window – keep nothing of it.
//
// Every entry is there only while what it hands over to is on. A picture, a
// PDF or a video is downloaded into memory ($XDG_RUNTIME_DIR/pshell) first and
// opened from there; the players keep nothing of a file there.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("browser-link") && Plugins.on("browser-menu")

	readonly property string folder: `${Paths.runtime}/browser-menu`
	readonly property var videoTargets: ["mp4", "webm", "mkv", "mov", "m4v", "ogv"].reduce((all, ext) => all.concat([`*://*/*.${ext}`, `*://*/*.${ext}?*`]), [])
	readonly property var pdfTargets: ["*://*/*.pdf", "*://*/*.pdf?*", "file:///*.pdf"]
	readonly property var channelTargets: ["*://*.youtube.com/*", "*://youtube.com/*", "*://youtu.be/*", "*://*.twitch.tv/*", "*://twitch.tv/*"]

	readonly property bool aiOn: Plugins.on("ai-actions") && Plugins.on("chat")
	readonly property bool phoneOn: Plugins.on("phone") && Plugins.on("phone-handoff")

	readonly property var entries: {
		if (!root.enabled) return [];
		const all = [];
		const add = (on, id, title, contexts, group, extra) => {
			if (on) all.push(Object.assign({ id: id, title: title, contexts: contexts, group: group }, extra || {}));
		};
		const sendable = ["selection", "link", "image", "page", "tab"];

		add(Plugins.on("translate"), "translate", "Translate", ["selection"], "text");
		add(Plugins.on("dictionary"), "lookup", "Look up", ["selection"], "text");
		add(root.aiOn, "explain", "Explain", ["selection"], "text");
		add(root.aiOn, "summarize", "Summarize", ["selection"], "text");
		add(Plugins.on("fast-reader") && Plugins.on("drop-commands"), "read", "Read fast", ["selection"], "text");

		add(Plugins.on("shelves"), "shelf", "Put on shelf", sendable, "keep");
		add(Plugins.on("notes"), "note", "Keep as note", ["selection", "link", "page", "tab"], "keep");
		add(Plugins.on("todos"), "task", "Add as task", ["selection", "link", "page", "tab"], "keep");

		add(root.phoneOn, "phone", "Send to phone", sendable, "send");
		for (const pc of Pcs.reachable)
			add(true, `pc:${pc.id}`, `Send to ${pc.name || "other PC"}`, sendable, "send");

		add(Plugins.on("video"), "video", "Open in player", ["video", "link"], "open", { targets: root.videoTargets });
		add(Plugins.on("pdf"), "pdf", "Open in PDF viewer", ["link"], "open", { targets: root.pdfTargets });
		add(Plugins.on("pdf"), "pdf-page", "Open in PDF viewer", ["page"], "open", { documents: root.pdfTargets });
		add(Plugins.on("viewer"), "picture", "Open in viewer", ["image"], "open");
		add(Plugins.on("torrents"), "torrent", "Add torrent", ["link"], "open", { targets: ["magnet:*"] });

		add(Plugins.on("studio-wallpaper") && Plugins.on("studio-wallpaper-online"), "wallpaper", "Set as wallpaper", ["image"], "picture");
		add(Plugins.on("studio-wallpaper"), "palette", "Colours from picture", ["image"], "picture");

		add(Plugins.on("streams"), "follow", "Follow channel", ["link"], "follow", { targets: root.channelTargets });
		add(Plugins.on("streams"), "follow-page", "Follow channel", ["page", "tab"], "follow", { documents: root.channelTargets });

		add(root.aiOn, "page-summary", "Summarize page", ["page", "tab"], "page");
		add(Plugins.on("fast-reader") && Plugins.on("drop-commands"), "page-read", "Read page fast", ["page", "tab"], "page");
		return all;
	}

	function run(action, info) {
		if (!root.enabled) return;
		const entry = root.entries.find(item => item.id === action);
		if (!entry) return;
		const i = info || {};
		const text = String(i.text || "").trim();
		// what the click was on: the link, the picture, else the page
		const url = String(i.link || i.src || i.page || "");
		const title = String(i.linkText || i.title || "").trim();

		switch (action) {
		case "translate":
			return root.launcher(`>t ${root.oneLine(text)}`);
		case "lookup":
			return root.launcher(`>d ${root.oneLine(text)}`);
		case "explain":
		case "summarize":
			return root.askAi(action, text);
		case "read":
			return Reader.read(text);
		case "shelf":
			return root.shelve(i.kind === "selection" ? [{ kind: "text", text: text }] : [{ kind: "link", url: url }]);
		case "note":
			return root.note(i, text, url, title);
		case "task":
			return root.task(i, text, url, title);
		case "phone":
			return Phone.sendText(i.kind === "selection" ? text : url);
		case "video":
			return root.fetchAndOpen(String(i.src || i.link || ""), i.page, 1024, path => Video.open(path));
		case "pdf":
		case "pdf-page":
			return root.fetchAndOpen(action === "pdf" ? String(i.link || "") : String(i.page || ""), i.page, 300, path => Pdf.open(path));
		case "picture":
			return root.fetchAndOpen(String(i.src || ""), i.page, 200, path => Viewer.open(path), `${Viewer.workDir}/browser`);
		case "torrent":
			return Torrents.add(String(i.link || ""));
		case "wallpaper":
			return root.wear(String(i.src || ""), false);
		case "palette":
			return root.wear(String(i.src || ""), true);
		case "follow":
			return Streams.follow(String(i.link || ""));
		case "follow-page":
			return Streams.follow(String(i.page || ""));
		case "page-summary":
			return root.withPage(i, page => root.askAi("summarize", page.text));
		case "page-read":
			return root.withPage(i, page => Reader.read(page.text));
		}
		if (action.startsWith("pc:")) Pcs.sendText(action.slice(3), i.kind === "selection" ? text : url);
	}

	// ── handing over ───────────────────────────────────────────────────────
	function oneLine(text) {
		return String(text || "").replace(/\s+/g, " ").trim();
	}

	function launcher(query) {
		Popups.withFocusedScreen(screen => {
			if (Popups.current === "launcher") Popups.close();
			Popups.open("launcher", screen, "", query);
		});
	}

	// in a temporary chat, like the shelf's and the PDF's
	function askAi(id, text) {
		const action = AiActions.fixed.find(item => item.id === id);
		if (!action || String(text || "").trim() === "") return;
		Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", { aiPrompt: action.prompt, aiText: String(text) }));
	}

	// the page's readable text (the page clicked on, or the tab)
	function withPage(info, then) {
		WebLink.pageText((ok, data) => {
			if (ok && String(data?.text || "").trim() !== "") then(data);
			else root.say("This page has no text to read", "web");
		}, info.tabId !== undefined && info.tabId !== null ? { id: info.tabId, source: info.source } : undefined);
	}

	function shelve(items) {
		if (Shelf.shelves.length === 0) Shelf.create(items);
		else Shelf.keep(items);
	}

	function markdownLink(label, url) {
		const shown = root.oneLine(label || url).replace(/[\[\]]/g, "").slice(0, 120) || url;
		return `[${shown}](${String(url).replace(/[()\s]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0"))})`;
	}

	function note(info, text, url, title) {
		const page = String(info.page || url);
		const source = page ? root.markdownLink(info.title || page, page) : "";
		const isText = info.kind === "selection";
		const body = isText ? `${text}\n\n${source}` : root.markdownLink(title || url, url);
		root.whenReady(() => Notes.loaded, () => {
			Notes.upsert("", isText ? String(info.title || "").trim() : "", body.trim());
			root.say("Note kept", "note");
		});
	}

	function task(info, text, url, title) {
		const page = String(info.page || url);
		const line = info.kind === "selection"
			? `${root.oneLine(text).slice(0, 300)} ${root.markdownLink(info.title || page, page)}`
			: root.markdownLink(title || url, url);
		root.whenReady(() => Todos.tasksLoaded, () => {
			const group = Todos.addPlain("", line);
			if (group !== "") root.say(`Added to ${group}`, "check");
		});
	}

	function say(title, icon) {
		Notifs.pushInternal("info", title, "", { icon: icon });
	}

	// what has to be read before it is written to (notes.json, Tasks.md)
	property var waiting: []

	function whenReady(ready, action) {
		if (ready()) {
			action();
			return;
		}
		root.waiting = root.waiting.concat([{ ready: ready, action: action, tries: 0 }]);
		waitTimer.start();
	}

	Timer {
		id: waitTimer

		interval: 250
		repeat: true
		onTriggered: {
			const left = [];
			for (const item of root.waiting) {
				if (item.ready()) item.action();
				else if (++item.tries < 40) left.push(item);
				else Notifs.pushInternal("error", "Could not save", "", { icon: "alert_circle_outline" });
			}
			root.waiting = left;
			if (left.length === 0) stop();
		}
	}

	// ── downloading ────────────────────────────────────────────────────────
	// into a folder of its own in memory; the newest few stay
	readonly property string fetchScript: `
import os, re, shutil, sys, time, urllib.parse, urllib.request
from pathlib import Path
url, referer, folder, limit = sys.argv[1], sys.argv[2], Path(sys.argv[3]), int(sys.argv[4]) << 20
types = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif", "image/avif": ".avif",
         "image/svg+xml": ".svg", "application/pdf": ".pdf", "video/mp4": ".mp4", "video/webm": ".webm"}
parts = urllib.parse.urlparse(url)
if parts.scheme not in ("http", "https", "data"):
    sys.exit("not a file that can be downloaded")
headers = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"}
if referer.startswith(("http://", "https://")):
    headers["Referer"] = referer
folder.mkdir(parents=True, exist_ok=True, mode=0o700)
target = folder / str(int(time.time() * 1000))
target.mkdir()
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        kind = response.headers.get_content_type()
        name = urllib.parse.unquote(os.path.basename(parts.path)) if parts.scheme != "data" else ""
        name = re.sub(r"[^\\w.\\- ]+", "_", name).strip(" .")[:100] or "download"
        if not Path(name).suffix and kind in types:
            name += types[kind]
        size = 0
        with open(target / name, "wb") as out:
            while chunk := response.read(256 * 1024):
                size += len(chunk)
                if size > limit:
                    raise RuntimeError("too large")
                out.write(chunk)
    if size == 0:
        raise RuntimeError("empty")
except BaseException as error:
    shutil.rmtree(target, ignore_errors=True)
    sys.exit(str(error))
for old in sorted(folder.iterdir(), key=lambda p: p.name)[:-6]:
    shutil.rmtree(old, ignore_errors=True)
print(target / name)
`

	function fetchAndOpen(url, referer, limitMb, open, folder) {
		if (url.startsWith("file://")) {
			open(url);
			return;
		}
		if (!/^(https?|data):/.test(url)) {
			root.say("This cannot be downloaded", "download");
			return;
		}
		const proc = fetcher.createObject(root, { open: open });
		proc.command = ["python3", "-I", "-c", root.fetchScript, url, String(referer || ""), folder || root.folder, String(limitMb)];
		proc.running = true;
	}

	Component {
		id: fetcher

		Process {
			id: proc

			property var open: null

			stdout: StdioCollector {
				id: out
			}
			onExited: code => {
				const path = String(out.text || "").trim();
				if (code === 0 && path !== "") proc.open(path);
				else Notifs.pushInternal("error", "Could not download", "", { icon: "download" });
				proc.destroy();
			}
		}
	}

	// the Online tab's way (wallpaper_search.py): the picture lives in
	// memory only and is forgotten once another wallpaper is worn
	// colours: only the palette is taken from it (apply_theme_selection.sh
	// --colours-from), the picture is forgotten once they are on
	function wear(url, colours) {
		if (!/^(https?|data):/.test(url)) {
			root.say("This cannot be downloaded", "download");
			return;
		}
		wearer.command = ["python3", `${Quickshell.shellDir}/scripts/wallpaper_search.py`, "wear", JSON.stringify({ item: { source: "web", url: url } })];
		wearer.last = "";
		wearer.colours = !!colours;
		wearer.running = true;
	}

	Process {
		id: wearer

		property string last: ""
		property bool colours: false

		command: ["true"]
		stdout: SplitParser {
			onRead: line => {
				if (!String(line).startsWith("progress ")) wearer.last = String(line);
			}
		}
		onExited: Qt.callLater(() => {
			let data = {};
			try {
				data = JSON.parse(wearer.last);
			} catch (error) {}
			if (!data.themePath) {
				Notifs.pushInternal("error", "Could not download the picture", data.error || "", { icon: "download" });
				return;
			}
			if (wearer.colours)
				Quickshell.execDetached(["bash", "-c", 'entry=$(cat "$1" 2>/dev/null) && [ -n "$entry" ] && media=$(ls "$2"/media.* 2>/dev/null | head -n1) && [ -n "$media" ] && exec bash "$3" "$entry" --colours-from "$media"; rm -rf -- "$(dirname -- "$2")"', "_", Colours.currentEntryFile, data.themePath, `${Quickshell.shellDir}/scripts/apply_theme_selection.sh`]);
			else
				Quickshell.execDetached(["bash", `${Quickshell.shellDir}/scripts/apply_theme_selection.sh`, data.themePath]);
		})
	}
}
