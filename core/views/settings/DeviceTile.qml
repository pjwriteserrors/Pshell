pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One device on the Devices page: what it is and where it sits, and its
// settings when the shell knows it – or a Claude session that teaches it.
Rectangle {
	id: tile

	required property var device
	property string line: ""
	property bool busy: false
	// hide (found devices) or remove (own devices)
	property string dropIcon: "eye_off_outline"

	signal open(string page)
	signal teach
	signal drop

	readonly property var handler: tile.device.handler
	readonly property bool isKnown: !!tile.handler?.page
	readonly property bool pluginOn: !tile.handler?.plugin || Plugins.on(tile.handler.plugin)

	function icon(kind) {
		return ({ keyboard: "keyboard", mouse: "mouse_variant", trackball: "mouse_variant", touchpad: "gesture_tap", gamepad: "gamepad_variant", tablet: "draw", touchscreen: "gesture_tap", "media keys": "play_pause", numpad: "dialpad", presenter: "devices", headset: "headset", headphones: "headphones", speaker: "speaker", phone: "cellphone", computer: "monitor", camera: "camera", printer: "printer", display: "television", network: "lan", router: "web", wifi: "wifi", tv: "television" })[kind] ?? "devices";
	}

	Layout.fillWidth: true
	implicitHeight: 64
	radius: Theme.radius.large
	color: Theme.layer2
	opacity: tile.device.online === false ? 0.6 : 1

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 16
		anchors.rightMargin: 12
		spacing: 14

		Rectangle {
			Layout.preferredWidth: 38
			Layout.preferredHeight: 38
			radius: 19
			color: tile.isKnown && !tile.handler.partial ? Theme.primaryContainer : Theme.layer3

			Glyph {
				anchors.centerIn: parent
				icon: tile.icon(tile.device.kind)
				size: 19
				color: tile.isKnown && !tile.handler.partial ? Theme.primary : Theme.textMuted
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: tile.device.name || `${tile.device.vendor}:${tile.device.product}`
				font.weight: Font.DemiBold
				elide: Text.ElideRight
			}

			StyledText {
				Layout.fillWidth: true
				text: tile.line
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
			}
		}

		TextButton {
			visible: tile.isKnown && !tile.pluginOn
			variant: "tonal"
			icon: "power"
			text: "Switch on"
			onActivated: Plugins.set(tile.handler.plugin, true)
		}

		TextButton {
			visible: tile.isKnown && tile.pluginOn
			variant: tile.handler?.partial ? "tonal" : "filled"
			icon: "tune_variant"
			text: "Settings"
			onActivated: tile.open(tile.handler.page)
		}

		TextButton {
			visible: !tile.isKnown || tile.handler?.partial === true
			variant: tile.isKnown ? "ghost" : "filled"
			icon: "robot"
			text: tile.isKnown ? "Complete with Claude" : "Teach with Claude"
			enabled: !tile.busy
			onActivated: tile.teach()
		}

		IconButton {
			visible: !tile.isKnown || tile.device.source === "custom"
			implicitWidth: 30
			implicitHeight: 30
			icon: tile.dropIcon
			variant: "ghost"
			onClicked: tile.drop()
		}
	}
}
