pragma Singleton

import QtQuick
import Quickshell

// Pages and searches open in the browser picked in Pshell settings (Default
// apps), else the host profile's (`browser`) or $BROWSER, else in the
// desktop's default (xdg-open). A Firefox kind opens a
// new tab of the one that runs; its own `--search` always opens a new
// window, so searches go by URL.
Singleton {
	id: root

	readonly property string searchUrl: "https://duckduckgo.com/?q="
	readonly property string program: String(DefaultApps.browser || Host.profile.browser || Quickshell.env("BROWSER") || "")
	readonly property bool firefoxKind: /(firefox|floorp|librewolf|waterfox|zen)/.test(root.program)

	function open(url) {
		if (root.program === "") Quickshell.execDetached(["xdg-open", String(url)]);
		else if (root.firefoxKind) Quickshell.execDetached([root.program, "--new-tab", String(url)]);
		else Quickshell.execDetached([root.program, String(url)]);
	}

	// a link from inside the shell (mail, chat): a web page goes to the
	// browser's peek when that is wanted (WebPage.openLink), anything else
	// as the desktop opens it. `source` names where it came from ("Mail").
	function openLink(url, source) {
		const text = String(url || "");
		if (/^https?:\/\//i.test(text) && WebPage.openLink(text, source)) return;
		Qt.openUrlExternally(text);
	}

	function search(query) {
		root.open(root.searchUrl + encodeURIComponent(String(query).trim().replace(/\s+/g, " ")));
	}
}
