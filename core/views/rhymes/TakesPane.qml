pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Takes: recorded over the beat from the line the cursor is in (a bar
// counted in before), played with the beat, timing the lines by what was
// sung, and mixed down with it into one file.
Item {
	id: pane

	readonly property var takes: Rhymes.clips
	readonly property real from: Rhymes.recordFrom

	Flickable {
		id: flick

		anchors.fill: parent
		contentHeight: column.implicitHeight + 24
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: column

			x: 16
			y: 8
			width: flick.width - 32
			spacing: 16

			// the big key
			Item {
				width: parent.width
				height: 120
				opacity: Rhymes.hasBeat ? 1 : 0.4

				Rectangle {
					id: pulse

					anchors.centerIn: record
					width: record.width
					height: record.height
					radius: width / 2
					color: Theme.danger
					opacity: 0

					SequentialAnimation {
						running: Rhymes.recording
						loops: Animation.Infinite
						onStopped: {
							pulse.opacity = 0;
							pulse.scale = 1;
						}

						ParallelAnimation {
							NumberAnimation {
								target: pulse
								property: "scale"
								from: 1
								to: 1.6
								duration: 1100
								easing.type: Easing.OutCubic
							}

							NumberAnimation {
								target: pulse
								property: "opacity"
								from: 0.35
								to: 0
								duration: 1100
							}
						}
					}
				}

				Clickable {
					id: record

					anchors.horizontalCenter: parent.horizontalCenter
					y: 8
					width: 76
					height: 76
					radius: Rhymes.recording ? 22 : 38
					color: Theme.danger
					tint: "#ffffff"
					enabled: Rhymes.hasBeat
					sound: ""
					onClicked: Rhymes.record()

					Behavior on radius {
						SpatialAnim {}
					}

					Rectangle {
						anchors.centerIn: parent
						width: Rhymes.recording ? 24 : 28
						height: width
						radius: Rhymes.recording ? 5 : width / 2
						color: "#ffffff"

						Behavior on radius {
							SpatialAnim {}
						}

						Behavior on width {
							SpatialAnim {}
						}
					}
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.top: record.bottom
					anchors.topMargin: 10
					text: Rhymes.recording ? Format.clock(Math.max(0, Rhymes.position - pane.from), 1) : `from ${Format.clock(pane.from, 1)}`
					tabular: true
					tone: Rhymes.recording ? Theme.danger : Theme.textMuted
				}
			}

			Column {
				width: parent.width
				spacing: 4

				SwitchLine {
					width: parent.width
					label: "A bar before"
					checked: Rhymes.setting("countIn", true)
					onToggled: on => Rhymes.setSetting("countIn", on)
				}

				SwitchLine {
					width: parent.width
					label: "Takes with the beat"
					checked: Rhymes.withTakes
					onToggled: on => Rhymes.withTakes = on
				}

				SwitchLine {
					width: parent.width
					label: "Hear the microphone"
					checked: Rhymes.monitorOn
					onToggled: on => Rhymes.setMonitor(on)
				}
			}

			// the track a take goes into
			Flow {
				width: parent.width
				spacing: 6
				visible: Rhymes.tracks.filter(t => t.kind === "audio").length > 1

				Repeater {
					model: Rhymes.tracks.filter(t => t.kind === "audio")

					Chip {
						required property var modelData

						text: modelData.name
						icon: Rhymes.armed === modelData.id ? "record" : ""
						selected: Rhymes.armed === modelData.id
						accent: Theme.danger
						onClicked: Rhymes.armedTrack = modelData.id
					}
				}
			}

			Repeater {
				model: pane.takes.slice().reverse()

				Rectangle {
					id: take

					required property var modelData
					readonly property bool aligning: Rhymes.jobRunning("align")

					width: column.width
					height: takeColumn.implicitHeight + 20
					radius: Theme.radius.large
					color: Theme.layer1

					Column {
						id: takeColumn

						x: 14
						y: 10
						width: parent.width - 28
						spacing: 8

						Row {
							width: parent.width
							spacing: 8

							Toggle {
								anchors.verticalCenter: parent.verticalCenter
								checked: take.modelData.on !== false
								onToggled: checked => Rhymes.editTake(take.modelData.clip, { on: checked })
							}

							Column {
								width: parent.width - 150
								anchors.verticalCenter: parent.verticalCenter

								StyledText {
									width: parent.width
									text: take.modelData.name
									elide: Text.ElideRight
									font.weight: Font.Medium
								}

								StyledText {
									text: `${Format.clock(Math.max(0, take.modelData.start), 1)} · ${Format.clock(take.modelData.length || 0)}` + (Rhymes.tracks.length > 2 ? ` · ${Rhymes.tracks.find(t => t.id === take.modelData.track)?.name ?? ""}` : "")
									tabular: true
									font.pixelSize: Theme.size.small
									tone: Theme.textSubtle
								}
							}

							IconButton {
								width: 30
								height: 30
								icon: "play"
								onClicked: {
									Rhymes.withTakes = true;
									Rhymes.play(Math.max(0, take.modelData.start));
								}
							}

							IconButton {
								width: 30
								height: 30
								icon: "timer_outline"
								enabled: !take.aligning
								onClicked: Rhymes.whisper.installed ? Rhymes.alignTake(take.modelData.file) : whisperAsk.open = true
							}

							IconButton {
								width: 30
								height: 30
								icon: "delete_outline"
								onClicked: Rhymes.dropTake(take.modelData.clip)
							}
						}

						PillSlider {
							wheelEnabled: false
							width: parent.width
							height: 26
							icon: "volume_high"
							value: (take.modelData.gain ?? 1) / 2
							valueText: `${Math.round((take.modelData.gain ?? 1) * 100)}%`
							onMoved: value => Rhymes.editTake(take.modelData.clip, { gain: Math.round(value * 200) / 100 })
						}
					}
				}
			}

			// the lines timed by listening: the speech model is fetched once
			Rectangle {
				id: whisperAsk

				property bool open: false

				width: parent.width
				height: open || Rhymes.jobRunning("install") || Rhymes.jobRunning("align") ? askColumn.implicitHeight + 24 : 0
				radius: Theme.radius.large
				color: Theme.primaryContainer
				clip: true
				visible: height > 0

				Behavior on height {
					SpatialAnim {}
				}

				Column {
					id: askColumn

					x: 14
					y: 12
					width: parent.width - 28
					spacing: 10

					StyledText {
						width: parent.width
						wrapMode: Text.Wrap
						text: Rhymes.jobRunning("align") ? (Rhymes.jobs.align?.text || "Listening") : (Rhymes.jobRunning("install") ? (Rhymes.jobs.install?.text || "Installing") : "Speech recognition (faster-whisper, about 600 MB)")
					}

					Rectangle {
						width: parent.width
						height: 4
						radius: 2
						color: Theme.layer2
						visible: Rhymes.jobRunning("install") || Rhymes.jobRunning("align")

						Rectangle {
							width: parent.width * (Rhymes.jobRunning("align") ? Rhymes.jobs.align.progress : (Rhymes.jobs.install?.progress ?? 0))
							height: parent.height
							radius: 2
							color: Theme.primary

							Behavior on width {
								Anim {}
							}
						}
					}

					Row {
						spacing: 8
						visible: !Rhymes.jobRunning("install") && !Rhymes.jobRunning("align")

						TextButton {
							text: "Install"
							variant: "filled"
							onClicked: {
								whisperAsk.open = false;
								Rhymes.installWhisper();
							}
						}

						TextButton {
							text: "Not now"
							variant: "ghost"
							onClicked: whisperAsk.open = false
						}
					}
				}
			}

			TextButton {
				anchors.horizontalCenter: parent.horizontalCenter
				visible: Rhymes.hasBeat
				icon: "playlist_music"
				text: Rhymes.jobRunning("bounce") ? "Mixing…" : (Rhymes.song?.bounce ? "Mix down again" : "Mix down")
				busy: Rhymes.jobRunning("bounce")
				onClicked: Rhymes.bounce()
			}
		}
	}

	component SwitchLine: Item {
		id: line

		property string label: ""
		property bool checked: false

		signal toggled(bool on)

		height: 36

		StyledText {
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			text: line.label
		}

		Toggle {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			checked: line.checked
			onToggled: on => line.toggled(on)
		}
	}
}
