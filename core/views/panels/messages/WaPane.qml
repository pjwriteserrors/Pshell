pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The right side of Messages while WhatsApp is looked at: the chat that is
// open, who it is with, a new chat, or the account – which is all there is
// until a phone has linked this device.
Item {
	id: root

	// "chat" | "info" | "new" | "account"
	property string view: "chat"
	property bool narrow: false
	// on the screen at all
	property bool active: false
	readonly property string shown: WhatsApp.linked ? root.view : "account"

	signal back
	signal picked(string id)

	function show(view) {
		root.view = view;
		if (view === "info") info.entered();
		else if (view === "new") fresh.entered();
	}

	function write() {
		if (root.shown === "chat" && WhatsApp.openChat !== null) pane.write();
	}

	component Faded: Item {
		id: faded

		property bool active: false

		anchors.fill: parent
		enabled: active
		opacity: active ? 1 : 0
		visible: opacity > 0.01
		transform: Translate {
			y: faded.active ? 0 : 12

			Behavior on y {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: faded.active ? Motion.medium : Motion.short
			}
		}
	}

	Connections {
		target: WhatsApp
		function onOpenIdChanged() {
			if (root.view === "info" || (WhatsApp.openId !== "" && root.view !== "account")) root.view = "chat";
		}
	}

	Faded {
		active: root.shown === "chat" && WhatsApp.openChat !== null

		WaChatPane {
			id: pane

			anchors.fill: parent
			narrow: root.narrow
			onBack: root.back()
			onDetails: root.show("info")
		}
	}

	Faded {
		active: root.shown === "chat" && WhatsApp.openChat === null

		IdleStage {
			anchors.fill: parent
			live: root.active
		}
	}

	Faded {
		active: root.shown === "info"

		WaInfo {
			id: info

			anchors.fill: parent
			onDone: root.view = "chat"
			onOpen: id => root.picked(id)
		}
	}

	Faded {
		active: root.shown === "new"

		WaNew {
			id: fresh

			anchors.fill: parent
			onDone: root.view = "chat"
			onOpen: id => root.picked(id)
		}
	}

	Faded {
		active: root.shown === "account"

		WaAccount {
			anchors.fill: parent
			active: root.active && root.shown === "account"
			onDone: root.view = "chat"
		}
	}
}
