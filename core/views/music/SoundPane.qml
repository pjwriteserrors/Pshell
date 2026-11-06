pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// How it sounds and how the player behaves: ten bands of an equalizer
// (presets, or dragged by hand along a curve through them), the pitch, the
// speed keeping its pitch or not, songs fading into each other; then what
// the window shows and how the player gets on with the rest of the shell.
Item {
	id: root

	property color accent: Theme.primary

	StyledText {
		id: heading

		x: 4
		text: "Sound"
		font.pixelSize: Theme.size.heading
		font.weight: Font.Bold
	}

	StyledText {
		anchors.left: heading.right
		anchors.leftMargin: 10
		anchors.baseline: heading.baseline
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
		text: Music.eqOn ? Music.setting("eqPreset", "Custom") : "Equalizer off"
	}

	Flickable {
		id: flick

		anchors.fill: parent
		anchors.topMargin: heading.height + 14
		contentHeight: body.implicitHeight + 12
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: body

			width: flick.width - 12
			x: 4
			spacing: 14

			// the presets
			Flow {
				width: parent.width
				spacing: 6

				Repeater {
					model: Music.eqPresets

					delegate: Chip {
						required property var modelData

						text: modelData.name
						selected: Music.setting("eqPreset", "Flat") === modelData.name
						accent: root.accent
						onClicked: Music.setEq(modelData.gains, modelData.name)
					}
				}
			}

			// the bands: a knob each, a soft line through them
			Item {
				id: bands

				readonly property real slot: bands.width / Music.eqBands.length
				readonly property real track: bands.height - 26

				width: parent.width
				height: 170

				function yOf(gain) {
					return 8 + (1 - (gain + 12) / 24) * (bands.track - 16);
				}

				// 0 dB
				Rectangle {
					x: 0
					width: parent.width
					y: bands.yOf(0)
					height: 1
					color: Theme.outline
					opacity: 0.5
				}

				Canvas {
					id: curve

					anchors.fill: parent
					opacity: Music.eqOn ? 0.9 : 0.35

					property var gains: Music.eq

					onGainsChanged: requestPaint()
					onWidthChanged: requestPaint()

					Behavior on opacity {
						Anim {}
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const g = curve.gains;
						const points = g.map((gain, i) => ({ x: bands.slot * (i + 0.5), y: bands.yOf(gain) }));
						// a curve through the knobs, filled faintly below
						ctx.beginPath();
						ctx.moveTo(0, points[0].y);
						ctx.lineTo(points[0].x, points[0].y);
						for (let i = 0; i < points.length - 1; i += 1) {
							const a = points[i], b = points[i + 1];
							const mx = (a.x + b.x) / 2;
							ctx.bezierCurveTo(mx, a.y, mx, b.y, b.x, b.y);
						}
						ctx.lineTo(curve.width, points[points.length - 1].y);
						ctx.lineWidth = 2.5;
						ctx.strokeStyle = root.accent;
						ctx.stroke();
						ctx.lineTo(curve.width, bands.yOf(-12) + 8);
						ctx.lineTo(0, bands.yOf(-12) + 8);
						ctx.closePath();
						ctx.fillStyle = Qt.alpha(root.accent, 0.12);
						ctx.fill();
					}

					Connections {
						target: root

						function onAccentChanged() {
							curve.requestPaint();
						}
					}
				}

				Repeater {
					model: Music.eqBands

					delegate: Item {
						id: band

						required property string modelData
						required property int index
						readonly property real gain: Music.eq[band.index] ?? 0

						x: bands.slot * band.index
						width: bands.slot
						height: bands.height

						Rectangle {
							anchors.horizontalCenter: parent.horizontalCenter
							y: 8
							width: 3
							height: bands.track - 16
							radius: 1.5
							color: Theme.layer3
							opacity: 0.8
						}

						Rectangle {
							id: knob

							anchors.horizontalCenter: parent.horizontalCenter
							y: bands.yOf(band.gain) - height / 2
							width: drag.pressed || drag.containsMouse ? 18 : 14
							height: width
							radius: width / 2
							color: Math.abs(band.gain) > 0.05 ? root.accent : Theme.layer3
							border.width: 2
							border.color: Theme.base

							Behavior on y {
								enabled: !drag.pressed
								SpatialAnim {}
							}
							Behavior on width {
								SpatialAnim {
									duration: Motion.medium
								}
							}
						}

						StyledText {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.bottom: knob.top
							anchors.bottomMargin: 4
							visible: drag.pressed
							text: `${band.gain > 0 ? "+" : ""}${band.gain}`
							tabular: true
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Bold
							tone: root.accent
						}

						StyledText {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.bottom: parent.bottom
							text: band.modelData
							tone: Theme.textMuted
							tabular: true
							font.pixelSize: Theme.size.tiny
						}

						MouseArea {
							id: drag

							anchors.fill: parent
							anchors.bottomMargin: 18
							hoverEnabled: true
							preventStealing: true
							cursorShape: Qt.SizeVerCursor
							function set(y) {
								const t = Math.max(0, Math.min(1, (y - 8) / (bands.track - 16)));
								Music.setBand(band.index, Math.round((12 - t * 24) * 2) / 2);
							}
							onPressed: mouse => drag.set(mouse.y)
							onPositionChanged: mouse => {
								if (drag.pressed) drag.set(mouse.y);
							}
							onDoubleClicked: Music.setBand(band.index, 0)
						}
					}
				}
			}

			Rule {}

			Line {
				label: "Pitch"
				detail: Music.setting("pitch", 0) === 0 ? "as it was recorded" : `${Music.setting("pitch", 0) > 0 ? "+" : ""}${Music.setting("pitch", 0)} semitones`

				Row {
					spacing: 4

					IconButton {
						width: 32
						height: 32
						icon: "minus"
						onClicked: Music.setPitch(Music.setting("pitch", 0) - 1)
					}

					IconButton {
						width: 32
						height: 32
						icon: "restore"
						enabled: Music.setting("pitch", 0) !== 0
						onClicked: Music.setPitch(0)
					}

					IconButton {
						width: 32
						height: 32
						icon: "plus"
						onClicked: Music.setPitch(Music.setting("pitch", 0) + 1)
					}
				}
			}

			Line {
				label: "Keep the pitch when faster"
				detail: "Off: faster is higher, like a record"

				Toggle {
					checked: Music.setting("correction", true)
					onToggled: checked => Music.setCorrection(checked)
				}
			}

			Line {
				label: "Fade between songs"
				detail: "Out at the end, in at the start"

				Segmented {
					options: [{ value: "0", label: "Off" }, { value: "2", label: "2 s" }, { value: "4", label: "4 s" }, { value: "8", label: "8 s" }]
					current: String(Music.setting("fade", 0))
					onSelected: value => Music.setFade(Number(value))
				}
			}

			Line {
				label: "Voice messages"
				detail: "The speed they play at"

				Segmented {
					options: [{ value: "1", label: "1×" }, { value: "1.5", label: "1.5×" }, { value: "2", label: "2×" }]
					current: String(Music.setting("voiceSpeed", 1.5))
					onSelected: value => Music.setSetting("voiceSpeed", Number(value))
				}
			}

			Rule {}

			Line {
				label: "The sound in the window"

				Segmented {
					options: [{ value: "bars", label: "Bars" }, { value: "ring", label: "Ring" }, { value: "off", label: "Off" }]
					current: Music.visualizer
					onSelected: value => Music.setSetting("visualizer", value)
				}
			}

			Switch {
				label: "The cover behind everything"
				key: "ambient"
				fallback: true
			}

			Switch {
				label: "The cover's colour for the whole shell"
				detail: "While music plays"
				key: "shellAccent"
				fallback: false
			}

			Switch {
				label: "A word when the song changes"
				detail: "While the window is away"
				key: "notify"
				fallback: true
			}

			Rule {}

			Switch {
				label: "Quieter while a game plays"
				key: "duckGames"
				fallback: true
			}

			Switch {
				label: "Pause during a break"
				detail: "Stretching and resting the eyes"
				key: "breaks"
				fallback: true
			}

			Switch {
				label: "Go on when the headphones come back"
				key: "headphones"
				fallback: true
			}

			Switch {
				visible: Plugins.on("lighting")
				label: "The lights take the cover"
				detail: "Back to the theme when the music stops"
				key: "lighting"
				fallback: false
			}
		}
	}

	component Rule: Rectangle {
		width: body.width
		height: 1
		color: Theme.outline
		opacity: 0.4
	}

	// a setting: its words on the left, its control on the right
	component Line: Item {
		id: line

		property string label: ""
		property string detail: ""
		default property alias control: holder.data

		width: body.width
		implicitHeight: Math.max(words.implicitHeight, holder.childrenRect.height)

		Column {
			id: words

			anchors.left: parent.left
			anchors.right: holder.left
			anchors.rightMargin: 12
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			StyledText {
				width: parent.width
				text: line.label
				elide: Text.ElideRight
				font.weight: Font.DemiBold
			}

			StyledText {
				width: parent.width
				visible: line.detail !== ""
				text: line.detail
				elide: Text.ElideRight
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}

		Item {
			id: holder

			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			width: childrenRect.width
			height: childrenRect.height
		}
	}

	component Switch: Line {
		id: toggleLine

		property string key: ""
		property bool fallback: false

		Toggle {
			checked: Music.setting(toggleLine.key, toggleLine.fallback)
			onToggled: checked => Music.setSetting(toggleLine.key, checked)
		}
	}
}
