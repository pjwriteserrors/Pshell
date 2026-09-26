pragma Singleton

import QtQuick
import Quickshell

// The words of this style. Core views ask for their most important texts –
// titles, section headings, empty states, Studio tabs, power actions – by key,
// and a style renames them here to speak its own language
// ("clipboard.title": "Arcane Library"). A key left out keeps main's text.
// Every key and its default: scripts/check_style.py --contract
Singleton {
	id: root

	readonly property var words: ({})

	function of(key: string, fallback: string): string {
		return root.words[key] ?? fallback;
	}
}
