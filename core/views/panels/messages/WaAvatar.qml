import QtQuick
import Quickshell.Widgets
import qs.style.theme
import qs.style.widgets

// Who a WhatsApp chat is with: their picture, else their initials – or the
// sign of a group – on a colour of their own.
Item {
	id: root

	property string name: ""
	// what the colour is made from
	property string key: ""
	property string picture: ""
	property bool group: false
	property real size: 40
	readonly property string initials: {
		const words = String(root.name).replace(/[^\p{L}\p{N}\s]/gu, "").split(/\s+/).filter(word => word !== "");
		if (words.length === 0) return "";
		return (words[0][0] + (words.length > 1 ? words[1][0] : "")).toUpperCase();
	}
	readonly property color tone: {
		let sum = 0;
		const key = root.key || root.name;
		for (let i = 0; i < key.length; i += 1) sum = (sum * 31 + key.charCodeAt(i)) % 360;
		return Qt.hsla(sum / 360, 0.45, Theme.dark ? 0.62 : 0.42, 1);
	}

	implicitWidth: root.size
	implicitHeight: root.size

	ClippingRectangle {
		anchors.fill: parent
		radius: width / 2
		color: Qt.tint(Theme.bg, Qt.alpha(root.tone, 0.28))

		StyledText {
			anchors.centerIn: parent
			visible: root.picture === "" && !root.group && root.initials !== ""
			text: root.initials
			tone: root.tone
			font.pixelSize: Math.round(root.size * 0.38)
			font.weight: Font.Bold
		}

		Glyph {
			anchors.centerIn: parent
			visible: root.picture === "" && (root.group || root.initials === "")
			icon: root.group ? "account_group" : "account"
			size: Math.round(root.size * 0.5)
			color: root.tone
		}

		Image {
			anchors.fill: parent
			visible: root.picture !== ""
			source: root.picture !== "" ? `file://${root.picture}` : ""
			sourceSize.width: root.size * 2
			sourceSize.height: root.size * 2
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
		}
	}
}
