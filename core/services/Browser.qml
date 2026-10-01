pragma Singleton

import QtQuick
import Quickshell

// Pages and searches open as a new tab of the running Floorp. Its own
// `--search` always opens a new window, so searches go by URL.
Singleton {
	id: root

	readonly property string searchUrl: "https://duckduckgo.com/?q="

	function open(url) {
		Quickshell.execDetached(["floorp", "--new-tab", String(url)]);
	}

	function search(query) {
		root.open(root.searchUrl + encodeURIComponent(String(query).trim().replace(/\s+/g, " ")));
	}
}
