pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A link held under the pointer shows where it goes before it is followed:
// for a page of the file a live window onto the spot it leads to (a
// footnote, a reference, a figure), for an address the address. It grows
// from the link and goes when the pointer leaves.
Item {
	id: root

	property var reader: null
	property bool live: false
	property int index: -1
	property point location: Qt.point(0, 0)
	property string url: ""
	property real atX: 0
	property real atY: 0
	property real linkTop: 0

	function show(index, location, url, x, y, top) {
		if (!Pdf.setting("hoverLinks", true)) return;
		root.index = index;
		root.location = location;
		root.url = url;
		root.atX = x;
		root.atY = y;
		root.linkTop = top;
		root.live = index >= 0 || url !== "";
	}

	function hide() {
		root.live = false;
	}

	readonly property bool isPage: root.index >= 0 && root.url === ""
	readonly property var target: root.isPage ? (Pdf.pages[root.index] ?? null) : null
	readonly property real cardW: root.isPage ? 380 : Math.min(420, urlText.implicitWidth + 56)
	readonly property real cardH: root.isPage ? 180 : 40
	// below the link if there is room, else above it
	readonly property bool above: root.atY + root.cardH + 12 > (parent?.height ?? 800)

	x: Math.max(8, Math.min((parent?.width ?? 800) - root.cardW - 8, root.atX - root.cardW / 2))
	y: root.above ? root.linkTop - root.cardH - 8 : root.atY + 8
	width: root.cardW
	height: root.cardH
	visible: card.opacity > 0.01

	Rectangle {
		id: card

		anchors.fill: parent
		radius: Theme.radius.medium
		color: Theme.bg
		border.color: Theme.outline
		clip: true
		opacity: root.live ? 1 : 0
		scale: root.live ? 1 : 0.9
		transformOrigin: root.above ? Item.Bottom : Item.Top

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		// the page it leads to, its spot at the top
		Item {
			anchors.fill: parent
			anchors.margins: 1
			visible: root.isPage
			clip: true

			PdfPage {
				id: target

				readonly property real fitK: (parent.width) / Math.max(1, Pdf.sizeOf(root.target).width)

				pageId: root.target?.id ?? ""
				reader: root.reader
				k: target.fitK
				renderK: target.fitK
				interactive: false
				shadow: false
				active: root.live
				y: -Math.max(0, root.location.y * target.fitK - 24)
			}

			// which page, in the corner
			Rectangle {
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 6
				width: pageText.implicitWidth + 14
				height: 22
				radius: 11
				color: Qt.rgba(0, 0, 0, 0.6)

				StyledText {
					id: pageText

					anchors.centerIn: parent
					text: `Page ${root.index + 1}`
					tone: "white"
					surface: "transparent"
					font.pixelSize: Theme.size.small
				}
			}
		}

		Row {
			anchors.centerIn: parent
			spacing: 8
			visible: !root.isPage

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: "web"
				size: 16
				color: Theme.primary
			}
			StyledText {
				id: urlText

				anchors.verticalCenter: parent.verticalCenter
				width: Math.min(implicitWidth, 360)
				text: root.url
				elide: Text.ElideMiddle
			}
		}
	}
}
