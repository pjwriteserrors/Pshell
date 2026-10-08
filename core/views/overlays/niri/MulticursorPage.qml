pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.overlays.keybinds

// Multicursor (core/services/Multicursor.qml): the keys that move and copy
// lines and add cursors, and the apps they are not for. A row opens to
// record its keys the way a key bind does.
SettingsPage {
	id: root

	title: "Multicursor"
	recording: root.recorder !== null && root.recorder.recording

	// the action whose keys are being set, and its recorder
	property string editing: ""
	property Item recorder: null

	// apps with a window that could be left alone
	readonly property var open: {
		const ids = [];
		for (const window of Niri.windows) {
			const id = String(window.app_id || "");
			if (id !== "" && !ids.includes(id) && !Multicursor.skips(id)) ids.push(id);
		}
		return ids.sort();
	}

	SettingCard {
		anchor: "multicursor"
		title: "Shortcuts"
		icon: "keyboard"
		trailing: [
			Toggle {
				checked: Multicursor.on
				onToggled: on => Multicursor.setOn(on)
			}
		]

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 2
			opacity: Multicursor.on ? 1 : 0.5

			Repeater {
				model: Multicursor.actions

				delegate: ColumnLayout {
					id: entry

					required property var modelData
					readonly property string key: Multicursor.binds[entry.modelData.id]
					readonly property bool open: root.editing === entry.modelData.id
					// the same keys as a bind of niri: in a text field they are these
					readonly property var taken: entry.key !== "" ? Keybinds.conflict(entry.key, 0) : null

					Layout.fillWidth: true
					spacing: 8

					Clickable {
						Layout.fillWidth: true
						implicitHeight: 52
						radius: Theme.radius.large
						pressedScale: 0.985
						color: entry.open ? Theme.layer2 : (hovered ? Theme.layer2 : "transparent")
						onClicked: root.editing = entry.open ? "" : entry.modelData.id

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 12
							anchors.rightMargin: 12
							spacing: 14

							Glyph {
								icon: entry.modelData.icon
								size: 18
								color: entry.open ? Theme.primary : Theme.textMuted
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 1

								StyledText {
									Layout.fillWidth: true
									text: entry.modelData.title
									font.weight: Font.Medium
								}

								StyledText {
									Layout.fillWidth: true
									visible: entry.taken !== null
									text: entry.taken ? `Also in niri: ${Keybinds.title(entry.taken)}` : ""
									tone: Theme.warning
									font.pixelSize: Theme.size.small
									elide: Text.ElideRight
								}
							}

							ResetPill {
								shown: entry.key !== entry.modelData.key
								onClicked: Multicursor.resetBind(entry.modelData.id)
							}

							KeyCombo {
								visible: entry.key !== ""
								key: entry.key
								size: 26
							}

							StyledText {
								visible: entry.key === ""
								text: "None"
								tone: Theme.textSubtle
							}
						}
					}

					Loader {
						Layout.fillWidth: true
						Layout.leftMargin: 12
						Layout.rightMargin: 12
						Layout.bottomMargin: 8
						active: entry.open
						visible: active
						onLoaded: {
							root.recorder = item;
							item.start();
						}

						sourceComponent: ColumnLayout {
							readonly property alias recording: keys.recording

							function start() {
								keys.start();
							}

							spacing: 8

							KeyRecorder {
								id: keys

								Layout.fillWidth: true
								key: entry.key
								onRecorded: key => {
									Multicursor.setBind(entry.modelData.id, key);
									root.editing = "";
								}
							}

							TextButton {
								Layout.alignment: Qt.AlignRight
								implicitHeight: 28
								visible: entry.key !== ""
								variant: "ghost"
								icon: "close"
								text: "No keys"
								onActivated: {
									Multicursor.setBind(entry.modelData.id, "");
									root.editing = "";
								}
							}
						}
					}
				}
			}
		}
	}

	SettingCard {
		anchor: "multicursor-apps"
		title: "Excluded apps"
		subtitle: "Besides terminals, code editors and games"
		icon: "application_cog_outline"

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: Multicursor.excluded

				delegate: Chip {
					required property var modelData

					text: String(modelData)
					icon: "close"
					selected: true
					onClicked: Multicursor.setExcluded(modelData, false)
				}
			}

			Repeater {
				model: root.open

				delegate: Chip {
					required property var modelData

					text: String(modelData)
					icon: "plus"
					onClicked: Multicursor.setExcluded(modelData, true)
				}
			}
		}
	}
}
