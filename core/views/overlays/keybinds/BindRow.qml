import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A bind in the list: its keycaps, what it does, and its switch.
Clickable {
	id: root

	property var bind: null
	property bool selected: false
	readonly property bool off: !!root.bind?.disabled

	signal toggled(bool on)

	implicitHeight: 54
	radius: Theme.radius.medium
	pressedScale: 0.99
	color: root.selected ? Theme.primaryContainer : (root.hovered ? Theme.layer1 : "transparent")

	// the accent edge of the selected row
	Rectangle {
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		width: 3
		height: root.selected ? parent.height - 18 : 0
		radius: 2
		color: Theme.primary

		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 14
		anchors.rightMargin: 12
		spacing: 14

		Item {
			Layout.preferredWidth: Math.round(Math.min(210, root.width * 0.36))
			Layout.fillHeight: true
			clip: true

			KeyCombo {
				anchors.verticalCenter: parent.verticalCenter
				key: String(root.bind?.key ?? "")
				size: 24
				faint: root.off
			}
		}

		Rectangle {
			Layout.preferredWidth: 30
			Layout.preferredHeight: 30
			radius: Theme.radius.small
			color: root.selected ? Qt.alpha(Theme.primary, 0.18) : Theme.layer2
			opacity: root.off ? 0.5 : 1

			Image {
				id: icon

				readonly property var app: Keybinds.app(root.bind)

				anchors.centerIn: parent
				width: 20
				height: 20
				visible: status === Image.Ready
				source: icon.app ? AppIcons.app(icon.app.icon, [icon.app.id]) : ""
				sourceSize: Qt.size(40, 40)
				asynchronous: true
				mipmap: true
			}

			Glyph {
				anchors.centerIn: parent
				visible: !icon.visible
				icon: root.bind?.action === "spawn-sh" ? "console" : Keybinds.categoryIcon(Keybinds.category(root.bind))
				size: 15
				color: root.selected ? Theme.primary : Theme.textMuted
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1
			opacity: root.off ? 0.5 : 1

			Behavior on opacity {
				Anim {}
			}

			StyledText {
				Layout.fillWidth: true
				text: Keybinds.title(root.bind)
				font.weight: Font.DemiBold
				font.strikeout: root.off
			}

			StyledText {
				Layout.fillWidth: true
				text: Keybinds.detail(root.bind)
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				font.family: root.bind?.action === "spawn" || root.bind?.action === "spawn-sh" ? Theme.monoFamily : Theme.fontFamily
			}
		}

		Toggle {
			checked: !root.off
			onToggled: on => root.toggled(on)
		}
	}
}
