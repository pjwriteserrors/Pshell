pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Exchange rates for the launcher's converter (>conv): one table of every
// currency against the euro (fawazahmed0/currency-api, updated daily), kept
// in ~/.cache/pshell/rates.json. It is fetched only while the converter is
// used, and no more than once an hour; what is converted never leaves.
Singleton {
	id: root

	// { code: units per euro }, null until there is a table
	property var rates: null
	// the day the table is of
	property string date: ""
	property bool failed: false
	readonly property bool loading: fetcher.running
	property real asked: 0

	readonly property string folder: Paths.cache
	readonly property var sources: [
		"https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/eur.min.json",
		"https://latest.currency-api.pages.dev/v1/currencies/eur.min.json"
	]

	// the converter is on the screen
	function refresh() {
		if (!Plugins.on("converter") || fetcher.running) return;
		const today = new Date().toISOString().slice(0, 10);
		if (root.rates && (root.date === today || Date.now() - root.asked < 3600 * 1000)) return;
		root.asked = Date.now();
		fetcher.running = true;
	}

	function load(text) {
		try {
			const data = JSON.parse(String(text || ""));
			if (!data || typeof data.eur !== "object" || !(data.eur.usd > 0)) return false;
			data.eur.eur = 1;
			root.rates = data.eur;
			root.date = String(data.date || "");
			return true;
		} catch (error) {
			return false;
		}
	}

	Process {
		id: fetcher

		command: ["sh", "-c", 'mkdir -p "$1" && { curl -fsS -m 8 "$2" || curl -fsS -m 8 "$3"; } > "$1/rates.new" && mv "$1/rates.new" "$1/rates.json"',
			"rates", root.folder].concat(root.sources)
		onExited: code => {
			root.failed = code !== 0;
			if (code === 0) file.reload();
		}
	}

	FileView {
		id: file

		path: `${root.folder}/rates.json`
		blockLoading: true
		printErrors: false
		onLoaded: if (!root.load(text())) root.failed = root.rates === null
	}
}
