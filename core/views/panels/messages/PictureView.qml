pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A picture of a mail, large, over all of Messages: as big as it is or as
// there is room for. From here it goes to the clipboard, into the downloads
// or to the program that shows pictures. A click beside it or Escape closes.
Rectangle {
	id: root

	readonly property string source: Mail.picture
	readonly property bool open: root.source !== ""
	// the picture that is shown stays while the view fades out
	property string shown: ""
	property bool copied: false

	onSourceChanged: {
		if (root.source !== "") root.shown = root.source;
		root.copied = false;
	}

	color: Qt.rgba(0, 0, 0, 0.88)
	opacity: root.open ? 1 : 0
	visible: opacity > 0.01

	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}

	Connections {
		target: Mail
		function onPictureCopied() {
			root.copied = true;
			uncopy.restart();
		}
	}

	Timer {
		id: uncopy

		interval: 1600
		onTriggered: root.copied = false
	}

	// beside the picture: back to the chat
	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		hoverEnabled: true
		onClicked: Mail.picture = ""
		onWheel: wheel => wheel.accepted = true
	}

	Image {
		id: picture

		readonly property real room: Math.min(1, (root.width - 48) / Math.max(1, implicitWidth), (root.height - 120) / Math.max(1, implicitHeight))

		anchors.centerIn: parent
		anchors.verticalCenterOffset: 22
		width: implicitWidth * room
		height: implicitHeight * room
		source: root.shown === "" ? "" : (root.shown.startsWith("/") ? `file://${root.shown}` : root.shown)
		asynchronous: true
		cache: false
		smooth: true
		mipmap: true
		scale: root.open ? 1 : 0.96

		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		// a click on the picture is none beside it
		MouseArea {
			anchors.fill: parent
		}
	}

	Spinner {
		anchors.centerIn: parent
		visible: root.open && picture.status === Image.Loading
		width: 26
		height: 26
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.open && picture.status === Image.Error
		icon: "image_outline"
		title: "The picture cannot be shown"
	}

	Row {
		anchors.top: parent.top
		anchors.right: parent.right
		anchors.margins: 12
		spacing: 6

		IconButton {
			icon: root.copied ? "check" : "content_copy"
			variant: "tonal"
			onClicked: Mail.withPicture("copy", root.shown)
		}

		IconButton {
			icon: "download"
			variant: "tonal"
			onClicked: Mail.withPicture("save", root.shown)
		}

		IconButton {
			icon: "open_in_new"
			variant: "tonal"
			onClicked: Qt.openUrlExternally(root.shown.startsWith("/") ? `file://${root.shown}` : root.shown)
		}

		IconButton {
			icon: "close"
			variant: "tonal"
			onClicked: Mail.picture = ""
		}
	}

	Shortcut {
		sequence: "Escape"
		enabled: root.open && root.visible
		onActivated: Mail.picture = ""
	}

	Shortcut {
		sequence: "Ctrl+C"
		enabled: root.open && root.visible
		onActivated: Mail.withPicture("copy", root.shown)
	}
}
