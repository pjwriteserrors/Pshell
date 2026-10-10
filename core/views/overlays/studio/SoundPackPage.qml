pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Studio's sounds: the sound pack, what plays and how loud. Every single
// sound and the quiet hours are on the Sounds page of the settings.
ModalWindow {
	id: root

	modalId: "sounds"
	exclusiveKeyboard: true
	onModalOpened: {
		Sounds.refreshPacks();
		Qt.callLater(() => keyTarget.forceActiveFocus());
	}

	StudioTabs {}

	Rectangle {
		id: panel

		anchors.horizontalCenter: parent.horizontalCenter
		anchors.top: parent.top
		anchors.topMargin: Math.max(85, (parent.height - 900) / 2 + 25)
		width: Math.min(860, root.width - 120)
		height: Math.min(root.height - 170, column.implicitHeight + 44)
		radius: Theme.radius.huge + 6
		color: Theme.base

		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		Item {
			id: keyTarget

			anchors.fill: parent
			focus: true

			Keys.onEscapePressed: event => {
				event.accepted = true;
				Popups.closeModal();
			}
		}

		Flickable {
			anchors.fill: parent
			anchors.margins: 22
			contentHeight: column.implicitHeight
			boundsBehavior: Flickable.StopAtBounds
			clip: true
			ScrollBar.vertical: ThinScrollBar {}

			ColumnLayout {
				id: column

				width: parent.width
				spacing: 18

				RowLayout {
					Layout.fillWidth: true
					spacing: 14

					Rectangle {
						Layout.preferredWidth: 46
						Layout.preferredHeight: 46
						radius: Theme.radius.large
						color: Theme.primaryContainer

						Glyph {
							anchors.centerIn: parent
							icon: Sounds.mode === "off" ? "volume_off" : "volume_high"
							size: 22
							color: Theme.primary
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						SectionLabel {
							text: Words.of("sounds.title", "Sounds")
						}

						StyledText {
							Layout.fillWidth: true
							text: Sounds.current ? Sounds.current.name : "Loading packs…"
							font.pixelSize: Theme.size.heading
							font.weight: Font.Bold
							elide: Text.ElideRight
						}
					}

					TextButton {
						visible: Plugins.on("niri-settings")
						implicitHeight: 42
						variant: "ghost"
						icon: "tune_variant"
						text: "Every sound"
						onActivated: {
							NiriSettings.page = "sounds";
							Popups.openModal("niri", Popups.modalScreen);
						}
					}

					IconButton {
						icon: "close"
						variant: "tonal"
						onClicked: Popups.closeModal()
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 14

					Segmented {
						Layout.preferredWidth: 440
						options: [
							{ value: "all", label: "Everything", icon: "volume_high" },
							{ value: "buttons", label: "Buttons", icon: "cursor_default_click" },
							{ value: "system", label: "Automatic", icon: "bell_ring" },
							{ value: "off", label: "Off", icon: "volume_off" }
						]
						current: Sounds.mode
						onSelected: value => Sounds.setMode(value)
					}

					PillSlider {
						id: loudness

						Layout.fillWidth: true
						implicitHeight: 36
						opacity: Sounds.mode === "off" ? 0.5 : 1
						icon: "volume_medium"
						label: "Volume"
						value: Sounds.volume
						stepSize: 0.01
						onMoved: v => {
							Sounds.setVolume(v);
							hear.restart();
						}
						onDraggingChanged: if (!loudness.dragging) hear.restart()

						Timer {
							id: hear

							interval: 220
							onTriggered: if (!loudness.dragging) Sounds.preview("notification")
						}
					}
				}

				SoundPackGrid {
					Layout.fillWidth: true
				}
			}
		}
	}
}
