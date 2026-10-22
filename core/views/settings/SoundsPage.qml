pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.studio

// Sounds (core/services/Sounds.qml): which kind plays – what is pressed,
// what the system does on its own, both or none –, how loud, and below,
// folded away, every sound on its own with a way to hear it.
SettingsPage {
	id: root

	title: "Sounds"
	description: "Quiet sounds for what you press and for what the system does on its own – one at a time, never a pile."

	property bool listOpen: false

	readonly property var modes: [
		{ value: "all", title: "Everything", subtitle: "Buttons and the system", icons: ["cursor_default_click", "bell_ring"], sample: "notification" },
		{ value: "buttons", title: "Buttons only", subtitle: "What you press", icons: ["cursor_default_click"], sample: "toggleOn" },
		{ value: "system", title: "Automatic only", subtitle: "Notifications, devices", icons: ["bell_ring"], sample: "notification" },
		{ value: "off", title: "Off", subtitle: "Not a sound", icons: ["volume_off"], sample: "" }
	]

	readonly property var buttonMoments: Sounds.moments.filter(moment => moment.kind === "buttons")
	readonly property var systemMoments: Sounds.moments.filter(moment => moment.kind === "system")
	readonly property int onCount: Sounds.moments.filter(moment => Sounds.audible(moment.id)).length

	function modeNote(kind) {
		if (Sounds.mode === "off") return "Sounds are off";
		if (!Sounds.kindOn(kind)) return kind === "buttons" ? "Off – only automatic sounds play" : "Off – only buttons play";
		return "";
	}

	// ── the pack ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "sound-pack"
		title: "Sound pack"
		subtitle: "What every sound sounds like; Studio has the same choice"
		icon: "music_note"

		SoundPackGrid {
			Layout.fillWidth: true
		}
	}

	// ── what plays ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "sounds"
		title: "What plays"
		subtitle: "Each choice plays what it sounds like"
		icon: "volume_high"

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: root.modes

				delegate: OptionTile {
					id: tile

					required property var modelData

					title: tile.modelData.title
					subtitle: tile.modelData.subtitle
					selected: Sounds.mode === tile.modelData.value
					sound: ""
					onClicked: {
						Sounds.setMode(tile.modelData.value);
						Sounds.preview(tile.modelData.sample || "toggleOff");
					}

					SoundScene {
						anchors.fill: parent
						icons: tile.modelData.icons
						muted: tile.modelData.value === "off"
						playing: tile.playing && root.active
					}
				}
			}
		}

		ValueSlider {
			id: loudness

			opacity: Sounds.mode === "off" ? 0.5 : 1
			from: 0
			to: 100
			step: 1
			unit: " %"
			icon: Sounds.volume < 0.01 ? "volume_off" : (Sounds.volume < 0.5 ? "volume_medium" : "volume_high")
			label: "Volume"
			value: Math.round(Sounds.volume * 100)
			onMoved: v => {
				Sounds.setVolume(v / 100);
				hear.restart();
			}
			onDraggingChanged: if (!loudness.dragging) hear.restart()

			// what the new volume sounds like, once the slider rests
			Timer {
				id: hear

				interval: 220
				onTriggered: if (!loudness.dragging) Sounds.preview("notification")
			}
		}

		FlagRow {
			title: "Quiet during do not disturb"
			subtitle: "The system then only speaks up for errors, questions and urgent notifications"
			icon: "bell_off"
			checked: Sounds.quietDnd
			onToggled: on => Sounds.setQuietDnd(on)
		}
	}

	// ── every sound ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "sounds-list"
		title: "Every sound"
		subtitle: `${root.onCount} of ${Sounds.moments.length} play right now`
		icon: "tune_variant"
		modified: Sounds.modified
		onReset: Sounds.resetSwitches()

		Clickable {
			Layout.fillWidth: true
			implicitHeight: 44
			radius: Theme.radius.large
			pressedScale: 0.985
			color: hovered ? Theme.layer3 : Theme.layer2
			sound: ""
			onClicked: root.listOpen = !root.listOpen

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 14
				anchors.rightMargin: 10
				spacing: 10

				StyledText {
					Layout.fillWidth: true
					text: root.listOpen ? "Hide the list" : "Switch single sounds on and off"
					font.weight: Font.Medium
				}

				Glyph {
					icon: "chevron_down"
					size: 18
					color: Theme.textMuted
					rotation: root.listOpen ? 180 : 0

					Behavior on rotation {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			visible: root.listOpen
			spacing: 4

			Repeater {
				model: [
					{ kind: "buttons", label: "Buttons and shortcuts", moments: root.buttonMoments },
					{ kind: "system", label: "Automatic", moments: root.systemMoments }
				]

				delegate: ColumnLayout {
					id: group

					required property var modelData
					readonly property string note: root.modeNote(group.modelData.kind)

					Layout.fillWidth: true
					Layout.topMargin: 8
					spacing: 2

					RowLayout {
						Layout.fillWidth: true
						Layout.leftMargin: 12
						Layout.bottomMargin: 4
						spacing: 10

						SectionLabel {
							text: group.modelData.label
						}

						StyledText {
							Layout.fillWidth: true
							visible: group.note !== ""
							text: group.note
							tone: Theme.warning
							font.pixelSize: Theme.size.small
						}
					}

					Repeater {
						model: group.modelData.moments

						delegate: SoundRow {
							required property var modelData

							Layout.fillWidth: true
							moment: modelData
							dimmed: !Sounds.kindOn(modelData.kind)
						}
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				Layout.topMargin: 10
				Layout.leftMargin: 12
				text: Sounds.current ? `Sounds of ${Sounds.current.name} by ${Sounds.current.author} (${Sounds.current.url.replace(/^https?:\/\//, "")}), ${Sounds.current.license} – cut and softened for the shell.` : ""
				tone: Theme.textFaint
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}
	}

	// one sound: a click hears it, the switch turns it on and off
	component SoundRow: Clickable {
		id: row

		property var moment: ({})
		property bool dimmed: false
		readonly property bool picked: Sounds.enabled(row.moment.id)

		implicitHeight: Math.max(texts.implicitHeight + 18, 50)
		radius: Theme.radius.large
		pressedScale: 0.985
		color: row.hovered ? Theme.layer2 : "transparent"
		sound: ""
		onClicked: Sounds.preview(row.moment.id)

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 12
			anchors.rightMargin: 12
			spacing: 14
			opacity: row.dimmed || !row.picked ? 0.5 : 1

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			Glyph {
				icon: row.moment.icon
				size: 18
				color: row.picked ? Theme.primary : Theme.textMuted
			}

			ColumnLayout {
				id: texts

				Layout.fillWidth: true
				spacing: 1

				StyledText {
					Layout.fillWidth: true
					text: row.moment.title
					font.weight: Font.Medium
				}

				StyledText {
					Layout.fillWidth: true
					text: row.moment.subtitle
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			IconButton {
				icon: "play"
				implicitWidth: 30
				implicitHeight: 30
				opacity: row.hovered ? 1 : 0.6
				sound: ""
				onClicked: Sounds.preview(row.moment.id)
			}

			Toggle {
				checked: row.picked
				onToggled: on => {
					Sounds.setEnabled(row.moment.id, on);
					if (on) Sounds.preview(row.moment.id);
				}
			}
		}
	}

	// what a choice sounds like: its glyphs, rippling while it is picked or
	// pointed at
	component SoundScene: Item {
		id: scene

		property var icons: []
		property bool muted: false
		property bool playing: false

		Row {
			anchors.centerIn: parent
			spacing: 22

			Repeater {
				model: scene.icons

				delegate: Item {
					id: voice

					required property string modelData
					required property int index

					width: 40
					height: 40

					Repeater {
						model: scene.muted ? 0 : 2

						delegate: Rectangle {
							id: ring

							required property int index

							anchors.centerIn: parent
							width: 40
							height: 40
							radius: 20
							color: "transparent"
							border.width: 1.5
							border.color: Theme.primary
							opacity: 0
							scale: 1

							SequentialAnimation {
								running: scene.playing
								loops: Animation.Infinite
								onRunningChanged: if (!running) {
									ring.opacity = 0;
									ring.scale = 1;
								}

								PauseAnimation {
									duration: ring.index * 600 + voice.index * 300
								}
								ParallelAnimation {
									NumberAnimation {
										target: ring
										property: "scale"
										from: 1
										to: 1.9
										duration: 1200
										easing.type: Easing.OutCubic
									}
									NumberAnimation {
										target: ring
										property: "opacity"
										from: 0.6
										to: 0
										duration: 1200
										easing.type: Easing.OutCubic
									}
								}
								PauseAnimation {
									duration: (1 - ring.index) * 600 + (1 - voice.index) * 300
								}
							}
						}
					}

					Rectangle {
						anchors.fill: parent
						radius: 20
						color: scene.muted ? Theme.layer3 : Theme.primarySoft

						Glyph {
							anchors.centerIn: parent
							icon: voice.modelData
							size: 20
							color: scene.muted ? Theme.textMuted : Theme.primary
						}
					}
				}
			}
		}
	}
}
