import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A series nobody made yet: its newest picture (the others take turns on hover),
// how sure the finding is, and one click to follow it. A click on the picture
// opens it in the workshop first.
CardFrame {
	id: root

	property string itemKey: ""
	readonly property var item: Streams.discoveries.find(entry => entry.key === root.itemKey) ?? null
	readonly property var pictures: root.item?.pictures ?? []
	property int shown: 0
	property bool following: false
	readonly property bool onlyPlaylist: !!root.item && !Streams.isDetected(root.item)

	source: root.pictures[root.shown % Math.max(1, root.pictures.length)] ?? ""
	colors: root.item?.colors ?? null
	accent: Streams.accent(root.item?.colors)
	onClicked: if (root.item) Streams.adjustDiscovery(root.item)
	onHoveredChanged: if (!root.hovered) root.shown = 0

	Timer {
		interval: 1100
		repeat: true
		running: root.hovered && root.pictures.length > 1
		onTriggered: root.shown += 1
	}

	overlay: [
		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: parent.height * 0.62
			bottomLeftRadius: Theme.radius.large
			bottomRightRadius: Theme.radius.large
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.rgba(0, 0, 0, 0)
				}
				GradientStop {
					position: 1
					color: Qt.rgba(0, 0, 0, 0.88)
				}
			}
		},
		Rectangle {
			x: 10
			y: 10
			visible: root.item?.kind === "playlist" || (root.item?.numbered ?? false)
			implicitWidth: sign.implicitWidth + 14
			implicitHeight: 22
			radius: 6
			color: Qt.rgba(0, 0, 0, 0.62)

			Text {
				id: sign

				anchors.centerIn: parent
				text: root.onlyPlaylist ? "PLAYLIST" : (root.item?.numbered ? "NUMBERED" : "DETECTED")
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.tiny
				font.weight: Font.Bold
				font.letterSpacing: 0.6
			}
		},
		Rectangle {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 8
			width: 30
			height: 30
			radius: 15
			color: Qt.rgba(0, 0, 0, closeArea.containsMouse ? 0.85 : 0.6)
			opacity: root.hovered ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "close"
				size: 16
				color: "white"
				surface: "black"
			}
			MouseArea {
				id: closeArea

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: Streams.call("dismissSuggestion", { key: root.itemKey })
			}
		},
		// more than one series in here: a click shows them
		Clickable {
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 10
			z: 2
			visible: (root.item?.parts?.length ?? 0) > 0
			implicitWidth: insideWord.implicitWidth + 22
			implicitHeight: 28
			radius: 8
			color: root.accent
			pressedScale: 0.94
			onClicked: Streams.open({ parts: { name: root.item.name, parts: root.item.parts, whole: root.item } })

			Text {
				id: insideWord

				anchors.centerIn: parent
				text: `${root.item?.parts?.length ?? 0} series inside`
				color: Theme.contrast(root.accent, "#000000") > 4.5 ? "black" : "white"
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				font.weight: Font.Bold
			}
		},
		ColumnLayout {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 12
			spacing: 0

			Text {
				Layout.fillWidth: true
				text: root.item?.name ?? ""
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.heading + 2
				font.weight: Font.Black
				wrapMode: Text.Wrap
				maximumLineCount: 2
				elide: Text.ElideRight
			}
			Text {
				Layout.fillWidth: true
				text: {
					const parts = [`${root.item?.count ?? 0} episodes`];
					if (root.item?.seconds) parts.push(Streams.span(root.item.seconds));
					return parts.join(" · ");
				}
				color: Qt.rgba(1, 1, 1, 0.82)
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				font.weight: Font.Medium
			}
		}
	]

	RowLayout {
		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 9

		Avatar {
			Layout.preferredWidth: 34
			Layout.preferredHeight: 34
			source: root.item?.avatar ?? ""
			name: root.item?.sourceName ?? ""
			colors: root.item?.colors ?? null
		}
		ColumnLayout {
			Layout.fillWidth: true
			spacing: 0

			StyledText {
				Layout.fillWidth: true
				text: [root.item?.sourceName, root.item?.newest ? `newest ${Streams.ago(root.item.newest)}` : ""].filter(part => !!part).join(" · ")
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
				elide: Text.ElideRight
			}
			StyledText {
				Layout.fillWidth: true
				// what was found by reading comes first, the playlist's own word second
				text: root.item?.parts?.length > 0 ? root.item.parts.slice(0, 3).map(part => part.name).join(", ") : (root.onlyPlaylist || root.item?.kind !== "playlist" ? (root.item?.why?.[0] ?? "") : (root.item?.why?.[1] ?? ""))
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				elide: Text.ElideRight
			}
		}
		BigButton {
			implicitHeight: 34
			text: root.following ? "…" : "Follow"
			icon: root.following ? "" : "plus"
			onClicked: {
				root.following = true;
				Streams.followDiscovery(root.itemKey, () => root.following = false);
			}
		}
	}
}
