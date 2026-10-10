import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The launcher drops from the centre of the bar and resizes to what it shows:
// compact for the calculator, tall for a conversation.
Drawer {
	id: root

	panelId: "launcher"
	centered: true
	panelWidth: 780
	contentHeight: {
		switch (content.mode) {
		case "calc":
			return 300;
		case "translate":
			return 400;
		case "phone":
			return 380;
		case "chat":
			return 660;
		// the dock and shelves, or a spotlight as tall as the results
		case "apps":
			return content.appsHeight;
		// as tall as its tiles
		case "commands":
			return Math.max(360, content.paletteHeight + 124);
		default:
			return 560;
		}
	}

	// lets IPC / other surfaces open the launcher on a given query (">chat ", ">file " …)
	function setSearch(text) {
		content.setLauncherSearch(text);
	}

	onPanelOpened: {
		content.reset();
		// Popups.open("launcher", screen, "", ">file ") opens on a preset query
		if (typeof Popups.payload === "string" && Popups.payload !== "")
			content.setLauncherSearch(Popups.payload);
		// a shelf hands over an AI action on its text
		else if (Popups.payload?.aiPrompt)
			content.runClipboardAction(Popups.payload.aiPrompt, Popups.payload.aiText);
		Qt.callLater(() => content.focusSearch());
	}

	// a file pick for the phone ends with the launcher
	onPanelClosed: Phone.pickingFile = false

	LauncherContent {
		id: content

		anchors.fill: parent
		onCloseRequested: Popups.close()
		onOpenStudioRequested: page => Popups.openStudio(page, root.targetScreen)
		onOpenRpgRequested: Popups.rpgWindowRequested()
		onOpenUpdatesRequested: Popups.open("updates", root.targetScreen)
		onOpenPluginsRequested: Popups.openModal("plugins", root.targetScreen)
	}
}
