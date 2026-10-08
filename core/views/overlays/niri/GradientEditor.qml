pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A niri gradient: two colors, the angle on a dial, the color space they are
// mixed in, and whether each window gets its own or they share one across
// the view. `gradient` is { from, to, angle, relativeTo, space }.
RowLayout {
	id: root

	property var gradient: ({ from: "#80c8ff", to: "#c7ff7f", angle: 180, relativeTo: "", space: "srgb" })

	signal edited(var gradient)

	function change(key, value) {
		const next = Object.assign({}, root.gradient);
		next[key] = value;
		root.edited(next);
	}

	readonly property string spaceBase: String(root.gradient.space || "srgb").split(" ")[0]
	readonly property string hueMode: String(root.gradient.space || "").startsWith("oklch") ? (String(root.gradient.space).replace(/^oklch\s*/, "") || "shorter hue") : "shorter hue"

	spacing: 20

	AngleDial {
		Layout.alignment: Qt.AlignTop
		angle: Number(root.gradient.angle ?? 180)
		from: root.gradient.from
		to: root.gradient.to
		space: root.gradient.space || "srgb"
		onMoved: a => root.change("angle", a)
	}

	ColumnLayout {
		Layout.fillWidth: true
		spacing: 10

		RowLayout {
			spacing: 4

			ColorWell {
				label: "From"
				value: root.gradient.from
				onPicked: css => root.change("from", css)
			}

			IconButton {
				id: swap

				icon: "swap_horizontal"
				implicitWidth: 30
				implicitHeight: 30
				onClicked: {
					spin.restart();
					const next = Object.assign({}, root.gradient, { from: root.gradient.to, to: root.gradient.from });
					root.edited(next);
				}

				RotationAnimation on rotation {
					id: spin

					running: false
					from: 0
					to: 180
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}

			ColorWell {
				label: "To"
				value: root.gradient.to
				onPicked: css => root.change("to", css)
			}
		}

		Segmented {
			Layout.preferredWidth: 340
			implicitHeight: 32
			options: [
				{ value: "srgb", label: "sRGB" },
				{ value: "srgb-linear", label: "Linear" },
				{ value: "oklab", label: "Oklab" },
				{ value: "oklch", label: "Oklch" }
			]
			current: root.spaceBase
			onSelected: value => root.change("space", value === "oklch" ? `oklch ${root.hueMode}` : value)
		}

		// the way round the color wheel, for oklch
		Flow {
			Layout.fillWidth: true
			spacing: 6
			visible: root.spaceBase === "oklch"

			Repeater {
				model: [
					{ value: "shorter hue", label: "Shorter way", icon: "arrow_right_thin" },
					{ value: "longer hue", label: "Longer way", icon: "rotate_right" },
					{ value: "increasing hue", label: "Increasing", icon: "arrow_top_right" },
					{ value: "decreasing hue", label: "Decreasing", icon: "arrow_bottom_right" }
				]

				delegate: Chip {
					required property var modelData

					text: modelData.label
					icon: modelData.icon
					selected: root.hueMode === modelData.value
					onClicked: root.change("space", `oklch ${modelData.value}`)
				}
			}
		}

		// each window, or one gradient across the view
		RowLayout {
			spacing: 8

			Repeater {
				model: [
					{ value: "", label: "Each window" },
					{ value: "workspace-view", label: "Across the view" }
				]

				delegate: Clickable {
					id: mode

					required property var modelData
					readonly property bool picked: (root.gradient.relativeTo || "") === mode.modelData.value

					implicitWidth: 150
					implicitHeight: 64
					radius: Theme.radius.large
					color: mode.picked ? Theme.primaryContainer : Theme.layer2
					border.width: mode.picked ? 1.5 : 0
					border.color: Theme.primary
					onClicked: root.change("relativeTo", mode.modelData.value)

					Row {
						id: minis

						anchors.horizontalCenter: parent.horizontalCenter
						y: 10
						spacing: 4

						Repeater {
							model: 3

							delegate: Item {
								id: mini

								required property int index

								width: 26
								height: 24

								RoundClip {
									anchors.fill: parent
									radius: 5

									// one gradient spread over all three, or one each
									GradientFill {
										x: mode.modelData.value === "" ? 0 : -mini.index * 30
										width: mode.modelData.value === "" ? parent.width : 86
										height: parent.height
										from: root.gradient.from
										to: root.gradient.to
										angle: Number(root.gradient.angle ?? 180)
										space: root.gradient.space || "srgb"
									}
								}

								Rectangle {
									anchors.fill: parent
									anchors.margins: 3
									radius: 3
									color: Theme.layer1
								}
							}
						}
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: parent.bottom
						anchors.bottomMargin: 6
						text: mode.modelData.label
						tone: mode.picked ? Theme.primary : Theme.textMuted
						font.pixelSize: Theme.size.small
						font.weight: Font.Medium
					}
				}
			}
		}
	}
}
