pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Pictures from the browser (Pshell menu, docs/browser.md "The Pshell menu"):
//
// - Open pictures in viewer: every picture of the page (WebLink `pictures`,
//   background/pictures.js), downloaded into memory ($XDG_RUNTIME_DIR/pshell/
//   viewer/gallery) and walked in the viewer over the whole screen; the first
//   one shows as soon as it is there, the others join in the page's order.
//   The folder goes when the viewer closes or the next page's pictures come.
// - Save to NAS: a picture, a video or all pictures of the page go straight
//   into a NAS folder (Nas.send), through memory, not Downloads. The folder is
//   asked once per kind (Files.pick on the NAS's mount) and kept in
//   browser-nas.json; "Save to NAS in…" asks again.
Singleton {
	id: root

	readonly property bool viewerOn: Plugins.on("viewer")
	readonly property bool nasOn: Plugins.on("nas") && Nas.configured
	readonly property string script: `${Paths.scripts}/web_pictures.py`
	readonly property string galleryDir: `${Viewer.workDir}/gallery`
	readonly property string nasDir: `${Paths.runtime}/browser-nas`

	// ── the page's pictures in the viewer ──────────────────────────────────
	property int serial: 0
	// [{ i, path }] that landed, of the gallery shown
	property var landed: []
	property string startKey: ""
	property bool galleryShown: false

	function keyOf(url) {
		return String(url || "").replace(/[?#].*$/, "");
	}

	// the pictures of the page clicked on (`info` of a menu click); on a
	// picture the walk starts there
	function gallery(info) {
		if (!root.viewerOn) return;
		const i = info || {};
		root.picturesOf(i, (pictures, page) => {
			root.serial += 1;
			const serial = root.serial;
			root.landed = [];
			root.galleryShown = false;
			const start = root.keyOf(i.src);
			root.startKey = start;
			const urls = pictures.map(item => item.src);
			// the picture clicked on may be a preview: it counts by its place too
			if (start !== "" && !urls.some(url => root.keyOf(url) === start)) urls.unshift(String(i.src));
			root.download(urls, page, root.galleryDir, 200, true, (item, all) => {
				if (serial !== root.serial) return;
				root.landed = root.landed.concat([item]).sort((a, b) => a.i - b.i);
				// the one clicked on, else the page's first
				const startAt = Math.max(0, urls.findIndex(url => root.keyOf(url) === start));
				const paths = root.landed.map(entry => entry.path);
				if (!root.galleryShown) {
					if (item.i !== startAt && !all) return;
					root.galleryShown = true;
					const first = root.landed.find(entry => entry.i === startAt)?.path ?? paths[0];
					Viewer.open(first, { list: paths });
					fullscreenSoon.tries = 0;
					fullscreenSoon.restart();
				} else if (Viewer.windowOpen && Viewer.path.startsWith(root.galleryDir)) {
					Viewer.setFiles(paths.map(path => Viewer.entryFor(path)), Viewer.path);
				}
			}, done => {
				if (serial !== root.serial) return;
				if (done === 0) return root.say("The pictures could not be downloaded", "image_off_outline", "error");
				// the one clicked on never came: from the first that did
				if (!root.galleryShown && root.landed.length > 0) {
					root.galleryShown = true;
					Viewer.open(root.landed[0].path, { list: root.landed.map(entry => entry.path) });
					fullscreenSoon.tries = 0;
					fullscreenSoon.restart();
				}
			});
		});
	}

	// the viewer's window comes a moment after open(): then over the whole screen
	Timer {
		id: fullscreenSoon

		property int tries: 0

		interval: 120
		onTriggered: {
			const window = Niri.windows.find(window => String(window.title) === Viewer.windowTitle && /quickshell/i.test(String(window.app_id)));
			if (window) {
				Viewer.isFullscreen = !!window.is_fullscreen;
				Viewer.fullscreen(true);
			} else if (++tries < 25) restart();
		}
	}

	Connections {
		target: Viewer

		function onWindowOpenChanged() {
			if (Viewer.windowOpen || !root.galleryShown) return;
			// the window is gone and its fullscreen with it; nothing is kept
			root.galleryShown = false;
			root.serial += 1;
			Viewer.isFullscreen = false;
			Quickshell.execDetached(["rm", "-rf", "--", root.galleryDir]);
		}
	}

	// ── to the NAS ─────────────────────────────────────────────────────────
	// { picture, video, gallery } → NAS folder
	property var folders: ({})
	readonly property var defaults: ({ picture: "/Pictures/Browser", video: "/Videos/Browser", gallery: "/Pictures/Browser" })
	readonly property var kindTitles: ({ picture: "Pictures", video: "Videos", gallery: "Galleries" })
	// job id → local folder to remove once it is sent
	property var sending: ({})

	function kindOf(info) {
		const kind = String(info?.kind || "");
		if (kind === "video" || /\.(mp4|webm|mkv|mov|m4v|ogv)(\?|$)/i.test(String(info?.link || ""))) return "video";
		if (kind === "image") return "picture";
		return "gallery";
	}

	// `ask`: choose the folder again
	function save(info, ask) {
		if (!root.nasOn) return root.say("The NAS is not set up", "server_network", "error");
		const i = info || {};
		const kind = root.kindOf(i);
		root.folderFor(kind, !!ask, folder => {
			if (kind === "gallery") {
				root.picturesOf(i, (pictures, page, title) => {
					const name = root.folderName(title || page);
					root.sendAll(pictures.map(item => item.src), page, `${root.nasDir}/${Date.now()}/${name}`, folder, 200);
				});
				return;
			}
			const url = String(kind === "video" ? (i.src || i.link) : i.src);
			if (!/^(https?|data):/.test(url)) return root.say("This cannot be downloaded", "download", "error");
			root.sendAll([url], String(i.page || ""), `${root.nasDir}/${Date.now()}`, folder, kind === "video" ? 4096 : 200);
		});
	}

	function folderName(text) {
		const name = String(text || "").replace(/^https?:\/\//, "").replace(/[\/\\:*?"<>|\u0000-\u001f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 80);
		return name.replace(/^\.+/, "") || "Pictures";
	}

	function folderFor(kind, ask, then) {
		const kept = String(root.folders[kind] || "");
		if (kept !== "" && !ask) return then(kept);
		if (!Nas.mounted) {
			// nothing to choose from: the usual place, until one is chosen
			if (ask) return root.say("The NAS is not mounted", "server_network", "error");
			return then(root.defaults[kind]);
		}
		const start = Nas.localPath(kept || "/");
		Files.pick({ directory: true, folder: start, title: `NAS folder for ${root.kindTitles[kind].toLowerCase()}` }, paths => {
			const picked = (paths ?? [])[0];
			if (!picked) return;
			const nasPath = Nas.nasPathOf(decodeURIComponent(String(picked).replace(/^file:\/\//, "")));
			if (nasPath === "") return root.say("That folder is not on the NAS", "server_network", "error");
			root.folders = Object.assign({}, root.folders, { [kind]: nasPath });
			foldersFile.setText(JSON.stringify(root.folders, null, 2) + "\n");
			then(nasPath);
		});
	}

	function sendAll(urls, page, local, folder, limitMb) {
		if (urls.length === 0) return root.say("No pictures on this page", "image_off_outline");
		const paths = [];
		root.download(urls, page, local, limitMb, false, item => paths.push(item.path), done => {
			if (done === 0) {
				Quickshell.execDetached(["rm", "-rf", "--", local]);
				return root.say("Could not download", "download", "error");
			}
			// a gallery goes as its folder (named after the page), one file as itself
			const what = urls.length > 1 ? [local] : paths;
			Nas.send(what, folder, (data, error) => {
				const top = urls.length > 1 ? local.slice(0, local.lastIndexOf("/")) : local;
				if (error || data?.id === undefined) Quickshell.execDetached(["rm", "-rf", "--", top]);
				else root.sending = Object.assign({}, root.sending, { [data.id]: top });
			});
		});
	}

	Connections {
		target: Nas

		function onJobsChanged() {
			const left = Object.assign({}, root.sending);
			let changed = false;
			for (const id of Object.keys(left)) {
				const job = Nas.jobs[id];
				if (!job?.done) continue;
				Quickshell.execDetached(["rm", "-rf", "--", left[id]]);
				delete left[id];
				changed = true;
			}
			if (changed) root.sending = left;
		}
	}

	// a send that never reports back still leaves memory: an hour at most
	Timer {
		interval: 10 * 60 * 1000
		repeat: true
		running: Object.keys(root.sending).length > 0
		onTriggered: Quickshell.execDetached(["find", root.nasDir, "-mindepth", "1", "-maxdepth", "1", "-mmin", "+60", "-exec", "rm", "-rf", "--", "{}", "+"])
	}

	FileView {
		id: foldersFile

		path: Paths.stateFile("browser-nas.json")
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(foldersFile.text() || "{}"));
				root.folders = data && typeof data === "object" ? data : {};
			} catch (error) {}
		}
	}

	// ── shared ─────────────────────────────────────────────────────────────
	// then(pictures, page, title) for the tab of a menu click
	function picturesOf(info, then) {
		const tabId = info.tabId !== undefined && info.tabId !== null ? Number(info.tabId) : -1;
		WebLink.command("pictures", { tabId: tabId }, (ok, data) => {
			const pictures = ok ? (data?.pictures ?? []) : [];
			if (pictures.length === 0 && !info.src) return root.say("No pictures on this page", "image_off_outline");
			then(pictures, String(data?.url || info.page || ""), String(data?.title || info.title || ""));
		}, info.source);
	}

	// each(item {i, path}, all) as files land, done(count) at the end
	function download(urls, referer, folder, limitMb, replace, each, done) {
		const proc = loader.createObject(root, { input: JSON.stringify(urls), each: each, done: done, total: urls.length });
		proc.command = replace
			? ["sh", "-c", 'rm -rf -- "$1" && exec python3 "$2" fetch "$1" "$3" "$4"', "_", folder, root.script, String(referer || ""), String(limitMb)]
			: ["python3", root.script, "fetch", folder, String(referer || ""), String(limitMb)];
		proc.running = true;
	}

	Component {
		id: loader

		Process {
			id: proc

			property string input: ""
			property var each: null
			property var done: null
			property int total: 0
			property int seen: 0
			property int count: 0

			stdinEnabled: true
			onStarted: {
				proc.write(proc.input);
				proc.stdinEnabled = false;
			}
			stdout: SplitParser {
				onRead: line => {
					let data = {};
					try {
						data = JSON.parse(line);
					} catch (error) {
						return;
					}
					if (data.done !== undefined) {
						proc.count = data.done;
						return;
					}
					proc.seen += 1;
					if (data.path && proc.each) proc.each({ i: data.i, path: data.path }, proc.seen >= proc.total);
				}
			}
			onExited: {
				if (proc.done) proc.done(proc.count);
				proc.destroy();
			}
		}
	}

	function say(text, icon, status) {
		Notifs.pushInternal(status || "info", text, "", { icon: icon || "image_multiple_outline" });
	}
}
