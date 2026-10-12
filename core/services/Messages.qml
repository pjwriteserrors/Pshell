pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// What Messages can show, and where it is shown. Each provider is a plugin
// of its own, with a second one for its notifications. Messages hangs under
// the bar like every panel, or – popped out – lives in a window of its own;
// which of the two is remembered (messages-window.json), with what the
// chats are drawn on.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("messages")

	// [{ id, name, icon, notifications, unread, usable }]
	readonly property var providers: [
		{ id: "mail", name: "Mail", icon: "email_outline", notifications: "mail-notifications", unread: Mail.unread, usable: true },
		{ id: "whatsapp", name: "WhatsApp", icon: "whatsapp", notifications: "whatsapp-notifications", unread: WhatsApp.unread, usable: true },
		{ id: "mail-unsubscribe", name: "Newsletters", icon: "newspaper_variant_outline", notifications: "", unread: 0, usable: Newsletters.accounts.length > 0 }
	].filter(provider => provider.usable && Plugins.on(provider.id))
	readonly property int unread: root.enabled ? root.providers.reduce((sum, provider) => sum + provider.unread, 0) : 0

	property string current: "mail"
	readonly property var provider: root.providers.find(provider => provider.id === root.current) ?? root.providers[0] ?? null

	// a window of its own instead of the panel, and whether that window is up
	property bool windowed: false
	property bool windowOpen: false
	// what was last asked for: "", "chat" (the one that is open), "new", "new:<address>", "settings", "newsletters", "whatsapp"
	property string page: ""
	property int asked: 0
	readonly property bool shown: root.windowed ? root.windowOpen : Popups.current === "messages"

	function open(page) {
		if (!root.enabled) return;
		root.page = page ?? "";
		root.asked += 1;
		if (root.windowed) root.windowOpen = true;
		else Popups.withFocusedScreen(screen => Popups.open("messages", screen, root.page));
	}

	function close() {
		if (root.windowed) root.windowOpen = false;
		else if (Popups.current === "messages") Popups.close();
	}

	function toggle() {
		if (root.shown) root.close();
		else root.open("");
	}

	function popOut() {
		if (Popups.current === "messages") Popups.close();
		root.page = "";
		root.setWindowed(true);
		root.windowOpen = true;
	}

	function dock() {
		root.windowOpen = false;
		root.setWindowed(false);
		root.open("");
	}

	// what the chats are drawn on. `kind`: "none", light, lines or dots made of the palette ("aurora",
	// "waves", "dots"), the desktop's wallpaper ("wallpaper") or a picture of one's own ("image", `image`
	// is its path). blur, dim and tint are 0 … 1; `motion` lets it drift and follow the scrolling
	property var backdrop: root.backdropDefault
	readonly property var backdropDefault: ({ kind: "aurora", image: "", blur: 0.25, dim: 0.2, tint: 0, motion: true })

	function setBackdrop(change) {
		root.backdrop = Object.assign({}, root.backdrop, change);
		root.save();
	}

	// how the messages themselves look. `shape`: "round" | "soft" | "sharp" (their corners); `accent`: which of
	// the palette's colours one's own wear ("primary" | "secondary" | "tertiary"); `gradient`: they run from
	// that colour into the next; `colour`: 0 … 1, how much of the palette all of them carry – one's own of
	// their colour, the others' of the one beside it; `glass`: 0 … 1, how far the others' let the backdrop through; `size`:
	// "small" | "medium" | "large" (the words); `arrival`: "pop" | "slide" | "fade" | "none" (how a new one
	// comes up); `effects`: a message of nothing but emoji throws them into the air
	property var style: root.styleDefault
	readonly property var styleDefault: ({ shape: "round", accent: "primary", gradient: false, colour: 0.45, glass: 0, size: "medium", arrival: "pop", effects: true })

	function setStyle(change) {
		root.style = Object.assign({}, root.style, change);
		root.save();
	}

	// what the bubbles read of it
	readonly property real bubbleRadius: ({ round: Theme.radius.large, soft: 10, sharp: 4 })[root.style.shape] ?? Theme.radius.large
	readonly property real bubbleJoint: Math.min(6, root.bubbleRadius)
	readonly property int textSize: ({ small: Theme.size.label, medium: Theme.size.body, large: Theme.size.title })[root.style.size] ?? Theme.size.body
	readonly property color accent: root.style.accent === "secondary" ? Theme.secondary : (root.style.accent === "tertiary" ? Theme.tertiary : Theme.primary)
	readonly property color accentNext: root.style.accent === "secondary" ? Theme.tertiary : (root.style.accent === "tertiary" ? Theme.primary : Theme.secondary)
	readonly property real colour: Math.max(0, Math.min(1, Number(root.style.colour ?? 0.45)))
	readonly property color mine: Qt.tint(Theme.bg, Qt.alpha(root.accent, 0.12 + 0.34 * root.colour))
	readonly property color mineEnd: root.style.gradient ? Qt.tint(Theme.bg, Qt.alpha(root.accentNext, 0.14 + 0.36 * root.colour)) : root.mine
	readonly property color theirs: Qt.alpha(Qt.tint(Theme.layer2, Qt.alpha(root.accentNext, 0.2 * root.colour)), 1 - 0.55 * Math.max(0, Math.min(1, Number(root.style.glass) || 0)))

	function setWindowed(on) {
		root.windowed = on;
		root.save();
	}

	function save() {
		file.setText(JSON.stringify({ windowed: root.windowed, backdrop: root.backdrop, style: root.style }, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("messages-window.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const kept = JSON.parse(String(text() || "{}"));
				root.windowed = kept.windowed === true;
				if (kept.backdrop) root.backdrop = Object.assign({}, root.backdropDefault, kept.backdrop);
				if (kept.style) root.style = Object.assign({}, root.styleDefault, kept.style);
			} catch (error) {}
		}
	}
}
