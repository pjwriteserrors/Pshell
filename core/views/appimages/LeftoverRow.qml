import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One thing removing an AppImage takes: the app, its entry, icon and command
// always; settings, caches and data when ticked. The rows come one after the
// other.
Clickable {
	id: root

	property var item: ({})
	property int order: 0
	property bool ticked: true
	signal toggle

	readonly property var kinds: ({
		app: { label: "The app", icon: "package_variant" },
		entry: { label: "Launcher entry", icon: "application_outline" },
		icon: { label: "Icon", icon: "image_outline" },
		command: { label: "Command", icon: "console" },
		settings: { label: "Settings", icon: "cog_outline" },
		cache: { label: "Cache", icon: "cached" },
		data: { label: "Data", icon: "database_outline" },
		state: { label: "State", icon: "history" },
		home: { label: "In your home", icon: "home_outline" }
	})
	readonly property var kind: root.kinds[root.item.kind] ?? { label: "File", icon: "file_outline" }

	implicitHeight: 34
	radius: Theme.radius.small
	interactive: !root.item.fixed
	pressedScale: 0.98
	onClicked: root.toggle()
	opacity: 0
	transform: Translate {
		id: slide

		x: -12
	}

	Component.onCompleted: arrive.start()

	SequentialAnimation {
		id: arrive

		PauseAnimation {
			duration: 40 * root.order
		}
		ParallelAnimation {
			Anim {
				target: root
				property: "opacity"
				to: 1
				duration: Motion.long
			}
			SpatialAnim {
				target: slide
				property: "x"
				to: 0
			}
		}
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 6
		anchors.rightMargin: 6
		spacing: 10

		// ticked: it goes; a lock: it goes in any case
		Rectangle {
			Layout.preferredWidth: 18
			Layout.preferredHeight: 18
			radius: 5
			color: root.ticked ? (root.item.fixed ? Qt.alpha(Theme.danger, 0.5) : Theme.danger) : "transparent"
			border.width: root.ticked ? 0 : 1.5
			border.color: Theme.textSubtle

			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				icon: root.item.fixed ? "lock" : "check"
				size: 12
				color: Theme.bg
				scale: root.ticked ? 1 : 0

				Behavior on scale {
					NumberAnimation {
						duration: Motion.long
						easing.type: Easing.OutBack
						easing.overshoot: 2
					}
				}
			}
		}

		Glyph {
			icon: root.kind.icon
			size: 15
			color: root.ticked ? Theme.text : Theme.textSubtle
		}

		StyledText {
			Layout.preferredWidth: 110
			text: root.kind.label
			font.pixelSize: Theme.size.small
			tone: root.ticked ? Theme.text : Theme.textSubtle
		}

		StyledText {
			Layout.fillWidth: true
			text: String(root.item.path || "").replace(Paths.home, "~")
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.tiny
			font.family: Theme.monoFamily
			elide: Text.ElideMiddle
		}

		StyledText {
			text: AppImages.sizeText(root.item.size)
			tone: root.ticked ? Theme.textMuted : Theme.textFaint
			font.pixelSize: Theme.size.small
		}
	}
}
