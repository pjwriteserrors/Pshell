pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell.Widgets
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One window in the switcher: its picture (or its icon until there is one),
// a small app badge and, picked, the effect the settings chose. In the list
// layout it is a row with icon and name instead. Where it sits, its size,
// turn and scale are the layout's (SwitcherWindow), not its own.
Item {
	id: root

	required property var item
	property int number: 0
	property bool selected: false
	property bool row: false
	property string picture: ""
	property real radius: 12
	// glow | lift | spotlight | outline
	property string effect: "glow"
	property bool showTitle: false
	property bool showNumber: true
	// the spotlight leaves the others in the dark
	property bool dimmed: false
	property real yaw: 0
	property bool animate: true

	signal hovered
	signal clicked
	signal closeClicked

	readonly property bool lifted: root.selected && root.effect === "lift"
	readonly property real r: Math.min(root.radius, width / 2, height / 2)
	readonly property bool hasPicture: front.status === Image.Ready || back.status === Image.Ready

	transform: Rotation {
		origin.x: root.width / 2
		origin.y: root.height / 2
		axis {
			x: 0
			y: 1
			z: 0
		}
		angle: root.yaw

		Behavior on angle {
			enabled: root.animate
			SpatialAnim {
				duration: Motion.medium
			}
		}
	}

	// ── around the card ────────────────────────────────────────────────────
	RectangularShadow {
		anchors.fill: clip
		visible: !root.row
		radius: root.r
		blur: root.selected ? (root.effect === "glow" ? 34 : 40) : 22
		spread: root.selected && root.effect === "glow" ? 2 : 0
		offset.y: root.selected && root.effect === "glow" ? 0 : (root.lifted ? 22 : 8)
		color: root.selected && root.effect === "glow" ? Qt.alpha(Theme.primary, 0.75) : Qt.alpha("black", root.lifted ? 0.6 : 0.42)

		Behavior on blur {
			Anim {}
		}
		Behavior on color {
			ColorAnim {}
		}
	}

	// the ring of the outline effect, a little away from the card
	Rectangle {
		anchors.fill: clip
		anchors.margins: root.selected ? -7 : -2
		visible: !root.row && root.effect === "outline"
		radius: root.r + 7
		color: "transparent"
		border.width: 3
		border.color: Theme.primary
		opacity: root.selected ? 1 : 0

		Behavior on anchors.margins {
			SpatialAnim {}
		}
		Behavior on opacity {
			Anim {}
		}
	}

	// ── the card ───────────────────────────────────────────────────────────
	ClippingRectangle {
		id: clip

		anchors.fill: parent
		anchors.topMargin: root.lifted ? -14 : 0
		anchors.bottomMargin: root.lifted ? 14 : 0
		radius: root.r
		color: root.row ? (root.selected ? Theme.primaryContainer : Qt.alpha(Theme.layer2, 0.92)) : Theme.layer2

		Behavior on anchors.topMargin {
			SpatialAnim {}
		}
		Behavior on anchors.bottomMargin {
			SpatialAnim {}
		}
		Behavior on color {
			ColorAnim {}
		}

		// no picture (yet): the app's icon on a wash of its colour
		Item {
			anchors.fill: parent
			visible: !root.row && !root.hasPicture

			Rectangle {
				anchors.fill: parent
				gradient: Gradient {
					GradientStop {
						position: 0
						color: Theme.layer3
					}
					GradientStop {
						position: 1
						color: Theme.layer1
					}
				}
			}

			Image {
				anchors.centerIn: parent
				width: Math.min(parent.width, parent.height) * 0.42
				height: width
				source: AppIcons.forAppId(root.item.appId)
				sourceSize: Qt.size(128, 128)
				fillMode: Image.PreserveAspectFit
				asynchronous: true
				smooth: true
				mipmap: true
			}
		}

		// two pictures taking turns: the next frame loads behind the shown one
		// and only takes over once it is decoded, so a live card never blinks
		Image {
			id: front

			property bool shown: true

			anchors.fill: parent
			visible: !root.row && status === Image.Ready && shown
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			cache: false
			smooth: true
			mipmap: true
			onStatusChanged: if (status === Image.Ready) {
				front.shown = true;
				back.shown = false;
			}
		}

		Image {
			id: back

			property bool shown: false

			anchors.fill: parent
			visible: !root.row && status === Image.Ready && shown
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			cache: false
			smooth: true
			mipmap: true
			onStatusChanged: if (status === Image.Ready) {
				back.shown = true;
				front.shown = false;
			}
		}

		// the spotlight's dark
		Rectangle {
			anchors.fill: parent
			visible: !root.row
			color: "black"
			opacity: root.dimmed ? 0.55 : 0

			Behavior on opacity {
				Anim {
					duration: Motion.medium
				}
			}
		}

		// ── a row (list layout) ────────────────────────────────────────────
		Row {
			visible: root.row
			anchors.fill: parent
			anchors.leftMargin: 14
			anchors.rightMargin: 14
			spacing: 12

			Image {
				anchors.verticalCenter: parent.verticalCenter
				width: 30
				height: 30
				source: root.row ? AppIcons.forAppId(root.item.appId) : ""
				sourceSize: Qt.size(60, 60)
				fillMode: Image.PreserveAspectFit
				asynchronous: true
				smooth: true
				mipmap: true
			}

			Column {
				anchors.verticalCenter: parent.verticalCenter
				width: parent.width - 30 - 12 - (rowNumber.visible ? rowNumber.width + 12 : 0)
				spacing: 2

				StyledText {
					width: parent.width
					text: root.item.title
					elide: Text.ElideRight
					font.weight: root.selected ? Font.DemiBold : Font.Normal
					tone: root.selected ? Theme.text : Theme.textMuted
				}

				StyledText {
					width: parent.width
					text: `${root.item.appId || "window"} · ${root.item.output} · ${root.item.workspaceName || root.item.workspaceIdx}`
					elide: Text.ElideRight
					font.pixelSize: Theme.size.small
					tone: Theme.textSubtle
				}
			}

			StyledText {
				id: rowNumber

				anchors.verticalCenter: parent.verticalCenter
				visible: root.showNumber && root.number > 0 && root.number < 10
				text: root.number
				font.pixelSize: Theme.size.small
				font.weight: Font.Bold
				tone: root.selected ? Theme.primary : Theme.textFaint
			}
		}
	}

	// the edge: faint, the accent when picked
	Rectangle {
		anchors.fill: clip
		radius: root.r
		color: "transparent"
		border.width: root.selected && (root.effect === "glow" || root.effect === "spotlight") ? 2 : 1
		border.color: root.item.urgent ? Theme.danger
			: (root.selected && root.effect !== "outline" ? Theme.primary : Qt.alpha(Theme.fg, root.row ? 0 : 0.12))

		Behavior on border.color {
			ColorAnim {}
		}

		// a window asking for attention breathes
		SequentialAnimation on opacity {
			running: root.item.urgent && !root.selected
			loops: Animation.Infinite
			alwaysRunToEnd: true

			Anim {
				to: 0.35
				duration: 700
			}
			Anim {
				to: 1
				duration: 700
			}
		}
	}

	// ── badges ─────────────────────────────────────────────────────────────
	Rectangle {
		visible: !root.row && root.hasPicture && root.height > 70
		anchors.left: clip.left
		anchors.bottom: clip.bottom
		anchors.margins: Math.max(8, root.r * 0.45)
		width: 30
		height: 30
		radius: 9
		color: Qt.alpha(Theme.bg, 0.72)

		Image {
			anchors.centerIn: parent
			width: 22
			height: 22
			source: parent.visible ? AppIcons.forAppId(root.item.appId) : ""
			sourceSize: Qt.size(44, 44)
			fillMode: Image.PreserveAspectFit
			asynchronous: true
			smooth: true
			mipmap: true
		}
	}

	Rectangle {
		visible: !root.row && root.showNumber && root.number > 0 && root.number < 10 && root.height > 60
		anchors.left: clip.left
		anchors.top: clip.top
		anchors.margins: Math.max(8, root.r * 0.45)
		width: 22
		height: 22
		radius: 11
		color: root.selected ? Theme.primary : Qt.alpha(Theme.bg, 0.72)

		StyledText {
			anchors.centerIn: parent
			text: root.number
			font.pixelSize: Theme.size.small
			font.weight: Font.Bold
			tone: root.selected ? Theme.onPrimary : Theme.textMuted
		}
	}

	// the name under the card
	Rectangle {
		anchors.horizontalCenter: clip.horizontalCenter
		anchors.top: clip.bottom
		anchors.topMargin: 14
		visible: !root.row
		width: Math.min(Math.max(root.width * 1.4, 160), titleText.implicitWidth + 24)
		height: 28
		radius: 14
		color: Qt.alpha(Theme.bg, 0.82)
		opacity: root.showTitle ? 1 : 0
		scale: root.showTitle ? 1 : 0.9

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {}
		}

		StyledText {
			id: titleText

			anchors.centerIn: parent
			width: Math.min(implicitWidth, parent.width - 24)
			text: root.item.title
			elide: Text.ElideRight
			font.pixelSize: Theme.size.label
			font.weight: root.selected ? Font.DemiBold : Font.Normal
		}
	}

	// ── the pointer ────────────────────────────────────────────────────────
	MouseArea {
		id: mouse

		anchors.fill: clip
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.MiddleButton
		cursorShape: Qt.PointingHandCursor
		onPositionChanged: root.hovered()
		onClicked: event => {
			if (event.button === Qt.MiddleButton) root.closeClicked();
			else root.clicked();
		}
	}

	IconButton {
		anchors.right: clip.right
		anchors.top: clip.top
		anchors.margins: Math.max(6, root.r * 0.35)
		visible: !root.row && mouse.containsMouse || hovered
		icon: "close"
		implicitWidth: 26
		implicitHeight: 26
		iconSize: 14
		onClicked: root.closeClicked()
	}

	// a new picture goes to whichever of the two is not shown
	onPictureChanged: {
		if (root.picture === "") return;
		if (front.shown && front.status === Image.Ready) back.source = root.picture;
		else front.source = root.picture;
	}
	Component.onCompleted: if (root.picture !== "") front.source = root.picture
}
