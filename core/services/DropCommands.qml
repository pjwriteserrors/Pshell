pragma Singleton

import QtQuick
import Quickshell

// Commands for what is being dragged: shaking the pointer mid-drag brings
// them up around it, dropping on one acts on the dragged things. Keeping
// them on a shelf is one of the commands. Only those that fit what is
// dragged are offered.
//
// A command is { id, label, icon } with `run(items, at)`; `opens` names a
// page of further commands instead. `at` is { output, x, y }, the middle of
// the ring.
Singleton {
	id: root

	property bool active: false
	// the screen that saw the drag first; "" while none has
	property string output: ""
	// "" or the page that was opened ("ai")
	property string page: ""
	// what is dragged, as far as its formats tell before the drop:
	// "file", "link", "text" or "" when they do not
	property string offered: ""
	// dropped on a command that opens a page: the page is finished by click
	property var held: null

	readonly property string kind: !root.held ? root.offered
		: root.held.some(item => item.kind === "file") ? "file"
		: root.held.every(item => item.kind === "link") ? "link" : "text"
	readonly property bool files: root.kind === "" || root.kind === "file"
	readonly property bool words: root.kind !== "file"

	readonly property var main: [
		{ id: "shelf", label: "Shelf", icon: "tray_arrow_down", shown: Plugins.on("shelves"), run: (items, at) => Shelf.keep(items, at) },
		{ id: "copy", label: "Copy", icon: "content_copy", run: items => Shelf.copyItems(items) },
		{ id: "search", label: root.kind === "link" ? "Open" : "Search", icon: root.kind === "link" ? "web" : "magnify", shown: root.words, run: items => Shelf.search(items) },
		{ id: "ai", label: "AI", icon: "creation", shown: root.words && Plugins.on("ai-actions"), opens: "ai" },
		{ id: "path", label: "Copy path", icon: "clipboard_text", shown: root.files, run: items => Shelf.copyPaths(items) },
		{ id: "zip", label: "ZIP", icon: "package_variant", shown: root.files, run: (items, at) => Shelf.zip(Shelf.current(at), items) },
		{ id: "ocr", label: "Text", icon: "text_recognition", shown: root.files && Plugins.on("ocr"), run: items => items.filter(item => Shelf.isImage(item)).forEach(item => Shelf.extractText(item)) },
		{ id: "phone", label: "Phone", icon: "cellphone_arrow_down", shown: KdeConnect.available, run: items => Shelf.sendToPhone(items) }
	].filter(command => command.shown !== false)

	readonly property var ai: AiActions.fixed.map(action => ({
		id: action.id,
		label: action.title.split(" ")[0],
		icon: action.icon,
		run: items => Shelf.askAi(items, action.prompt)
	}))

	readonly property var commands: root.page === "ai" ? root.ai : root.main

	function summon() {
		// off first: the rings start over, also when one is still up
		root.active = false;
		root.output = "";
		root.page = "";
		root.offered = "";
		root.held = null;
		root.active = true;
		unclaimed.restart();
	}

	function dismiss() {
		root.active = false;
		unclaimed.stop();
	}

	// a screen saw the drag: the ring is its
	function claim(output, formats) {
		const has = type => formats.some(format => String(format).startsWith(type));
		const web = has("text/x-moz-url") || has("text/html") || has("chromium/");
		root.offered = has("text/uri-list") ? (web ? "link" : "file") : (has("text/") ? "text" : "");
		root.output = output;
		unclaimed.stop();
	}

	// items are those of the drop, or the held ones when a page is finished by click
	function run(command, items, at) {
		if (!command) return;
		if (command.opens) {
			root.page = command.opens;
			return;
		}
		root.dismiss();
		command.run(items, at);
	}

	// nothing was dragged over any screen: there is nothing to act on
	Timer {
		id: unclaimed

		interval: 1500
		onTriggered: root.dismiss()
	}
}
