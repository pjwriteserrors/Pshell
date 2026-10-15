import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../../../lib/GameText.js" as GameText

// A game's cover as a card: it leans towards the pointer like something
// held in the hand, the one picked stands out with a glow in the accent,
// a game that runs says so. Shared by the shelf and the grid.
Item {
	id: root

	property var game: null
	property bool current: false
	property real currentScale: 1.0
	property real radius: Theme.radius.large
	// the entrance: waits this long, -1 for none
	property int appearDelay: -1
	property bool showName: false

	readonly property bool running: !!root.game && Games.isRunning(root.game.id)
	readonly property bool missing: !!root.game?.missing
	readonly property bool hovered: mouse.containsMouse

	property real tiltX: 0
	property real tiltY: 0
	property real appear: root.appearDelay < 0 ? 1 : 0

	signal picked
	signal activated
	signal menuAsked(real x, real y)

	Behavior on tiltX {
		SpringAnimation {
			spring: 3
			damping: 0.3
		}
	}
	Behavior on tiltY {
		SpringAnimation {
			spring: 3
			damping: 0.3
		}
	}

	Component.onCompleted: if (root.appearDelay >= 0) appearing.start()

	SequentialAnimation {
		id: appearing

		PauseAnimation {
			duration: Math.max(0, root.appearDelay)
		}
		NumberAnimation {
			target: root
			property: "appear"
			to: 1
			duration: Motion.extraLong
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}
	}

	Item {
		id: body

		readonly property real lift: root.current ? 1 : (root.hovered ? 0.4 : 0)

		width: root.width
		height: root.showName ? root.width * 1.5 : root.height
		opacity: root.appear
		scale: (mouse.pressed ? 0.96 : 1) * (root.current ? root.currentScale : (root.hovered ? 1.04 : 1)) * (0.85 + 0.15 * root.appear)
		transformOrigin: Item.Bottom
		transform: [
			Translate {
				y: 40 * (1 - root.appear)
			},
			Rotation {
				origin.x: body.width / 2
				origin.y: body.height / 2
				axis {
					x: 0
					y: 1
					z: 0
				}
				angle: root.tiltX * 9
			},
			Rotation {
				origin.x: body.width / 2
				origin.y: body.height / 2
				axis {
					x: 1
					y: 0
					z: 0
				}
				angle: -root.tiltY * 7
			}
		]

		Behavior on scale {
			SpatialAnim {
				duration: Motion.long
			}
		}

		// the glow of the one picked, a shadow for the rest
		RectangularShadow {
			anchors.fill: art
			radius: root.radius
			offset.y: root.current ? 18 : 10
			blur: root.current ? 46 : 22
			spread: root.current ? 2 : -4
			color: root.current ? Qt.alpha(Theme.primary, 0.55) : Qt.rgba(0, 0, 0, 0.55)

			Behavior on color {
				ColorAnim {
					duration: Motion.long
				}
			}
			Behavior on blur {
				Anim {
					duration: Motion.long
				}
			}
		}

		CoverArt {
			id: art

			anchors.fill: parent
			game: root.game
			radius: root.radius
			light: Qt.point(root.tiltX, root.tiltY)
			sheen: root.hovered ? 0.8 : (root.current ? 0.25 : 0)
			layer.enabled: root.missing
			layer.effect: MultiEffect {
				saturation: -1
				brightness: -0.25
			}

			Behavior on sheen {
				Anim {
					duration: Motion.long
				}
			}
		}

		// a ring around the one picked
		Rectangle {
			anchors.fill: art
			anchors.margins: -5
			radius: root.radius + 5
			color: "transparent"
			border.width: 2.5
			border.color: Theme.primary
			opacity: root.current ? 0.9 : 0
			scale: root.current ? 1 : 1.04

			Behavior on opacity {
				Anim {
					duration: Motion.medium
				}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		// ── marks on the cover ─────────────────────────────────────────────
		Rectangle {
			id: playing

			anchors.top: parent.top
			anchors.left: parent.left
			anchors.margins: 10
			visible: root.running
			width: playingRow.implicitWidth + 16
			height: 24
			radius: 12
			color: Qt.rgba(0, 0, 0, 0.62)
			border.width: 1
			border.color: Qt.alpha(Theme.success, 0.6)

			RowLayout {
				id: playingRow

				anchors.centerIn: parent
				spacing: 6

				Rectangle {
					id: dot

					Layout.preferredWidth: 7
					Layout.preferredHeight: 7
					radius: 3.5
					color: Theme.success

					SequentialAnimation on opacity {
						running: playing.visible
						loops: Animation.Infinite

						NumberAnimation {
							to: 0.3
							duration: 800
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							to: 1
							duration: 800
							easing.type: Easing.InOutSine
						}
					}
				}

				StyledText {
					text: "Playing"
					tone: "white"
					surface: "transparent"
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
				}
			}
		}

		Rectangle {
			anchors.top: parent.top
			anchors.right: parent.right
			anchors.margins: 10
			width: 26
			height: 26
			radius: 13
			color: Qt.rgba(0, 0, 0, 0.55)
			visible: !!root.game?.favorite || root.missing
			scale: visible ? 1 : 0.4

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Glyph {
				anchors.centerIn: parent
				icon: root.missing ? "alert" : "heart"
				size: 14
				color: root.missing ? Theme.warning : "#ff5d7a"
				surface: "transparent"
			}
		}

		// how it starts, while pointed at
		Rectangle {
			anchors.bottom: parent.bottom
			anchors.left: parent.left
			anchors.margins: 10
			width: 28
			height: 28
			radius: 14
			color: Qt.rgba(0, 0, 0, 0.6)
			opacity: root.hovered && !root.showName ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			Glyph {
				anchors.centerIn: parent
				icon: GameText.kindIcon(root.game)
				size: 15
				color: "white"
				surface: "transparent"
			}
		}

		// a play button comes up on the cover in the grid
		Rectangle {
			anchors.centerIn: art
			width: 58
			height: 58
			radius: 29
			color: Theme.primary
			visible: root.showName
			opacity: root.hovered ? 1 : 0
			scale: root.hovered ? 1 : 0.6

			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Glyph {
				anchors.centerIn: parent
				anchors.horizontalCenterOffset: 2
				icon: root.running ? "open_in_new" : "play"
				size: 30
				color: Theme.onPrimary
				surface: Theme.primary
			}

			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onClicked: {
					root.picked();
					root.activated();
				}
			}
		}
	}

	StyledText {
		anchors.top: body.bottom
		anchors.topMargin: 12
		anchors.left: parent.left
		anchors.right: parent.right
		visible: root.showName
		horizontalAlignment: Text.AlignHCenter
		text: root.game?.name ?? ""
		tone: root.current ? "white" : Qt.rgba(1, 1, 1, 0.7)
		surface: "transparent"
		elide: Text.ElideRight
		opacity: root.appear
		font.pixelSize: Theme.size.body
		font.weight: root.current ? Font.Bold : Font.Medium
	}

	MouseArea {
		id: mouse

		anchors.fill: body
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.RightButton
		cursorShape: Qt.PointingHandCursor
		z: -1
		onPositionChanged: event => {
			root.tiltX = Math.max(-1, Math.min(1, (event.x - width / 2) / (width / 2)));
			root.tiltY = Math.max(-1, Math.min(1, (event.y - height / 2) / (height / 2)));
		}
		onExited: {
			root.tiltX = 0;
			root.tiltY = 0;
		}
		onClicked: event => {
			if (event.button === Qt.RightButton) {
				root.picked();
				const at = mapToItem(null, event.x, event.y);
				root.menuAsked(at.x, at.y);
				return;
			}
			// a click on the one picked plays it
			if (root.current) root.activated();
			else root.picked();
		}
		onDoubleClicked: event => {
			if (event.button === Qt.LeftButton) {
				root.picked();
				root.activated();
			}
		}
	}
}
