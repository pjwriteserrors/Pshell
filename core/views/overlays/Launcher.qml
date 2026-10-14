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
		// the file manager asks about files: a chat with them attached
		else if (Popups.payload?.aiFiles) {
			content.setLauncherSearch(">chat ");
			root.attachQueue = Popups.payload.aiFiles.slice();
			root.attachAsk = String(Popups.payload.aiAsk || "");
			attachTimer.start();
		}
		Qt.callLater(() => content.focusSearch());
	}

	// files are attached one after another: each is read before the next
	property var attachQueue: []
	// asked once they are all read
	property string attachAsk: ""

	Timer {
		id: attachTimer

		interval: 60
		repeat: true
		onTriggered: {
			if (content.aiAttachmentLoadingId !== "") return;
			if (root.attachQueue.length === 0) {
				attachTimer.stop();
				if (root.attachAsk !== "") content.sendChatPrompt(root.attachAsk);
				root.attachAsk = "";
				return;
			}
			content.addPendingAttachment(root.attachQueue.shift());
		}
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
