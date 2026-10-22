pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import "NiriColor.js" as NiriColor

// The color popover: saturation/brightness field, hue and alpha bars, the hex
// and the wallpaper's palette one click away. Every move is picked at once,
// so the preview behind follows the pointer.
Popup {
	id: root

	property string value: "#000000"
	property bool alpha: true
	property bool allowTransparent: false
	property real h: 0
	property real s: 0
	property real v: 0
	property real a: 1
	property string before: ""
	readonly property var rgba: NiriColor.fromHsv(root.h, root.s, root.v, root.a)
	readonly property string css: NiriColor.format(root.rgba)

	signal picked(string css)

	function load(css) {
		const c = NiriColor.parse(css) || [0, 0, 0, 1];
		const hsv = NiriColor.toHsv(c);
		// a grey keeps the hue it had
		if (hsv[1] > 0.001 && hsv[2] > 0.001) root.h = hsv[0];
		root.s = hsv[1];
		root.v = hsv[2];
		root.a = root.alpha ? hsv[3] : 1;
		hex.text = NiriColor.format(c);
	}

	function emit() {
		hex.text = root.css;
		root.picked(root.css);
	}

	onAboutToShow: {
		root.before = root.value;
		root.load(root.value);
	}

	width: 300
	padding: 16
	modal: true
	dim: false
	closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

	enter: Transition {
		ParallelAnimation {
			NumberAnimation {
				property: "opacity"
				from: 0
				to: 1
				duration: Motion.short
			}
			NumberAnimation {
				property: "scale"
				from: 0.9
				to: 1
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatialFast
			}
		}
	}
	exit: Transition {
		ParallelAnimation {
			NumberAnimation {
				property: "opacity"
				to: 0
				duration: Motion.short
			}
			NumberAnimation {
				property: "scale"
				to: 0.95
				duration: Motion.short
			}
		}
	}

	background: Rectangle {
		radius: Theme.radius.huge
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline

		Rectangle {
			anchors.fill: parent
			anchors.topMargin: 6
			z: -1
			radius: parent.radius
			color: Theme.shadow
			opacity: 0.5
		}
	}

	contentItem: ColumnLayout {
		spacing: 12

		// saturation → right, brightness → up
		Item {
			id: field

			Layout.fillWidth: true
			Layout.preferredHeight: 150

			Rectangle {
				id: fieldFill

				anchors.fill: parent
				radius: Theme.radius.medium
				color: Qt.hsva(root.h, 1, 1, 1)

				Rectangle {
					anchors.fill: parent
					radius: parent.radius
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop {
							position: 0
							color: "white"
						}
						GradientStop {
							position: 1
							color: "#00ffffff"
						}
					}
				}

				Rectangle {
					anchors.fill: parent
					radius: parent.radius
					gradient: Gradient {
						GradientStop {
							position: 0
							color: "#00000000"
						}
						GradientStop {
							position: 1
							color: "black"
						}
					}
				}
			}

			Rectangle {
				x: root.s * field.width - width / 2
				y: (1 - root.v) * field.height - height / 2
				width: fieldMouse.pressed ? 22 : 18
				height: width
				radius: width / 2
				color: Qt.rgba(root.rgba[0], root.rgba[1], root.rgba[2], 1)
				border.width: 3
				border.color: "white"

				Behavior on width {
					SpatialAnim {
						duration: Motion.short
					}
				}
			}

			MouseArea {
				id: fieldMouse

				anchors.fill: parent
				preventStealing: true
				cursorShape: Qt.CrossCursor
				function pick(mouse) {
					root.s = Math.max(0, Math.min(1, mouse.x / field.width));
					root.v = 1 - Math.max(0, Math.min(1, mouse.y / field.height));
					root.emit();
				}
				onPressed: mouse => pick(mouse)
				onPositionChanged: mouse => pick(mouse)
			}
		}

		// hue
		ColorBar {
			Layout.fillWidth: true
			position: root.h
			knob: Qt.hsva(root.h, 1, 1, 1)
			stops: [0, 1 / 6, 2 / 6, 3 / 6, 4 / 6, 5 / 6, 1].map(p => ({ position: p, color: Qt.hsva(p % 1, 1, 1, 1) }))
			onMoved: p => {
				root.h = Math.min(0.9999, p);
				root.emit();
			}
		}

		// alpha
		ColorBar {
			Layout.fillWidth: true
			visible: root.alpha
			checkered: true
			position: root.a
			knob: Qt.rgba(root.rgba[0], root.rgba[1], root.rgba[2], root.a)
			stops: [{ position: 0, color: Qt.rgba(root.rgba[0], root.rgba[1], root.rgba[2], 0) }, { position: 1, color: Qt.rgba(root.rgba[0], root.rgba[1], root.rgba[2], 1) }]
			onMoved: p => {
				root.a = Math.round(p * 100) / 100;
				root.emit();
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			// before | now
			Item {
				Layout.preferredWidth: 46
				Layout.preferredHeight: 32

				Checker {
					anchors.fill: parent
					cell: 5
					layer.enabled: true
					layer.effect: null
				}

				Row {
					anchors.fill: parent

					Rectangle {
						width: parent.width / 2
						height: parent.height
						color: NiriColor.qt(root.before)

						MouseArea {
							anchors.fill: parent
							cursorShape: Qt.PointingHandCursor
							onClicked: {
								root.load(root.before);
								root.picked(root.before);
							}
						}
					}

					Rectangle {
						width: parent.width / 2
						height: parent.height
						color: Qt.rgba(root.rgba[0], root.rgba[1], root.rgba[2], root.a)
					}
				}

				Rectangle {
					anchors.fill: parent
					color: "transparent"
					radius: 6
					border.width: 3
					border.color: Theme.layer2
				}
			}

			Field {
				id: hex

				Layout.fillWidth: true
				implicitHeight: 34
				icon: "pound"
				clearable: false
				fontSize: Theme.size.label
				input.font.family: Theme.monoFamily
				onAccepted: {
					const text = hex.text.trim();
					const normal = NiriColor.valid(text) ? text : (NiriColor.valid(`#${text}`) ? `#${text}` : "");
					if (normal === "") return;
					root.load(normal);
					root.picked(NiriColor.format(NiriColor.parse(normal)));
				}
			}
		}

		// the wallpaper's colors, and niri's own defaults
		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: Theme.palette.map(c => NiriColor.fromQt(c)).concat([NiriColor.fromQt(Theme.primary), NiriColor.fromQt(Theme.secondary), NiriColor.fromQt(Theme.tertiary)]).concat(root.allowTransparent ? ["transparent"] : [])

				delegate: Rectangle {
					id: swatch

					required property string modelData

					width: 22
					height: 22
					radius: 11
					color: NiriColor.qt(swatch.modelData)
					border.width: 1
					border.color: Theme.outline
					scale: swatchMouse.containsMouse ? 1.18 : 1

					Behavior on scale {
						SpatialAnim {
							duration: Motion.short
						}
					}

					Glyph {
						anchors.centerIn: parent
						visible: swatch.modelData === "transparent"
						icon: "water_off"
						size: 13
						color: Theme.textMuted
					}

					MouseArea {
						id: swatchMouse

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							if (swatch.modelData === "transparent") {
								root.picked("transparent");
								root.close();
								return;
							}
							const c = NiriColor.parse(swatch.modelData);
							c[3] = root.alpha ? root.a : 1;
							root.load(NiriColor.format(c));
							root.picked(NiriColor.format(c));
						}
					}
				}
			}
		}
	}
}
