import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A download the browser is still busy with, on the home page: a ring that
// fills, the speed, pause and cancel.
Item {
	id: root

	property var item: ({})
	readonly property real ratio: root.item.total > 0 ? root.item.received / root.item.total : -1

	width: 232
	height: 232 * 0.62 + 54

	Rectangle {
		width: parent.width
		height: parent.width * 0.62
		radius: Theme.radius.large
		color: Theme.layer1

		Item {
			anchors.centerIn: parent
			width: 64
			height: 64

			Shape {
				anchors.fill: parent
				preferredRendererType: Shape.CurveRenderer

				ShapePath {
					strokeColor: Theme.layer3
					strokeWidth: 5
					fillColor: "transparent"
					capStyle: ShapePath.RoundCap

					PathAngleArc {
						centerX: 32
						centerY: 32
						radiusX: 28
						radiusY: 28
						startAngle: 0
						sweepAngle: 360
					}
				}

				ShapePath {
					strokeColor: root.item.state === "paused" ? Theme.warning : Theme.primary
					strokeWidth: 5
					fillColor: "transparent"
					capStyle: ShapePath.RoundCap

					PathAngleArc {
						centerX: 32
						centerY: 32
						radiusX: 28
						radiusY: 28
						startAngle: -90
						sweepAngle: Math.max(0, root.ratio) * 360

						Behavior on sweepAngle {
							Anim {}
						}
					}
				}
			}

			Spinner {
				visible: root.ratio < 0
				anchors.fill: parent
				anchors.margins: 6
			}

			Glyph {
				anchors.centerIn: parent
				icon: root.item.state === "paused" ? "pause" : "download"
				size: 22
				color: Theme.primary
			}
		}

		Row {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 6
			spacing: 2

			IconButton {
				width: 28
				height: 28
				iconSize: 15
				icon: root.item.state === "paused" ? "play" : "pause"
				onClicked: root.item.state === "paused" ? Downloads.resume(root.item.key) : Downloads.pause(root.item.key)
			}
			IconButton {
				width: 28
				height: 28
				iconSize: 15
				icon: "close"
				onClicked: Downloads.cancel(root.item.key)
			}
		}
	}

	Text {
		id: label

		y: root.width * 0.62 + 8
		width: root.width
		text: String(root.item.name || "")
		color: Theme.text
		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.label
		font.weight: Font.Medium
		elide: Text.ElideMiddle
	}

	Text {
		anchors.top: label.bottom
		anchors.topMargin: 2
		width: root.width
		text: {
			const parts = [];
			if (root.ratio >= 0) parts.push(`${Math.round(root.ratio * 100)} %`);
			if (root.item.speed > 0) parts.push(`${Format.bytes(root.item.speed)}/s`);
			if (root.item.state === "paused") parts.push("Paused");
			return parts.join(" · ");
		}
		color: Theme.textSubtle
		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.small
	}
}
