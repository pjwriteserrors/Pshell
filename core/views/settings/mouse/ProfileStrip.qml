pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The mouse's profiles side by side: a click puts one in use (everything
// on this page then belongs to it). Below, the one in use: its name, its
// glyph, and when it comes by itself – with an app, or while a game runs.
ColumnLayout {
	id: root

	spacing: 14

	Flickable {
		Layout.fillWidth: true
		Layout.preferredHeight: 104
		contentWidth: strip.implicitWidth
		flickableDirection: Flickable.HorizontalFlick
		boundsBehavior: Flickable.StopAtBounds
		clip: true

		Row {
			id: strip

			spacing: 10

			Repeater {
				model: Mouse.profiles

				delegate: Clickable {
					id: card

					required property var modelData
					required property int index
					readonly property bool inUse: Mouse.activeProfile === card.modelData.id
					readonly property string when: (card.modelData.apps ?? []).length > 0 ? `With ${card.modelData.apps.join(", ")}` : (card.modelData.games ? "While a game runs" : "By hand")

					width: 168
					height: 104
					radius: Theme.radius.large
					color: card.inUse ? Theme.primaryContainer : (card.hovered ? Theme.layer3 : Theme.layer2)
					border.width: card.inUse ? 1.5 : 0
					border.color: Theme.primary
					onClicked: Mouse.useProfile(card.modelData.id)

					// cards come in one after the other
					opacity: 0
					transform: Translate {
						id: rise

						y: 12
					}
					Component.onCompleted: enter.start()

					ParallelAnimation {
						id: enter

						SequentialAnimation {
							PauseAnimation {
								duration: card.index * 50
							}
							NumberAnimation {
								target: card
								property: "opacity"
								to: 1
								duration: Motion.medium
							}
						}
						SequentialAnimation {
							PauseAnimation {
								duration: card.index * 50
							}
							NumberAnimation {
								target: rise
								property: "y"
								to: 0
								duration: Motion.long
								easing.type: Easing.BezierSpline
								easing.bezierCurve: Motion.spatial
							}
						}
					}

					ColumnLayout {
						anchors.fill: parent
						anchors.margins: 14
						spacing: 4

						Rectangle {
							Layout.preferredWidth: 36
							Layout.preferredHeight: 36
							radius: 18
							color: card.inUse ? Theme.primary : Theme.primarySoft
							scale: card.inUse ? 1.08 : 1

							Behavior on scale {
								SpatialAnim {}
							}
							Behavior on color {
								ColorAnim {}
							}

							Glyph {
								anchors.centerIn: parent
								icon: card.modelData.icon || "mouse_variant"
								size: 18
								color: card.inUse ? Theme.onPrimary : Theme.primary
							}

							// the one in use breathes
							Rectangle {
								anchors.centerIn: parent
								width: parent.width
								height: width
								radius: width / 2
								color: "transparent"
								border.width: 2
								border.color: Theme.primary
								visible: card.inUse
								opacity: 0

								SequentialAnimation on scale {
									running: card.inUse && card.visible
									loops: Animation.Infinite

									NumberAnimation {
										from: 1
										to: 1.7
										duration: 1600
										easing.type: Easing.OutCubic
									}
								}
								SequentialAnimation on opacity {
									running: card.inUse && card.visible
									loops: Animation.Infinite

									NumberAnimation {
										from: 0.5
										to: 0
										duration: 1600
										easing.type: Easing.OutCubic
									}
								}
							}
						}

						Item {
							Layout.fillHeight: true
						}

						StyledText {
							Layout.fillWidth: true
							text: card.modelData.name
							font.weight: Font.DemiBold
							tone: card.inUse ? Theme.primary : Theme.text
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							text: card.inUse ? `In use · ${card.when.toLowerCase()}` : card.when
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
							elide: Text.ElideRight
						}
					}
				}
			}

			Clickable {
				width: 104
				height: 104
				radius: Theme.radius.large
				color: "transparent"
				border.width: 1.5
				border.color: Theme.outline
				onClicked: {
					Mouse.newProfile("", "");
					nameField.text = Mouse.active?.name ?? "";
					nameField.focusInput();
				}

				ColumnLayout {
					anchors.centerIn: parent
					spacing: 6

					Glyph {
						Layout.alignment: Qt.AlignHCenter
						icon: "plus"
						size: 22
						color: Theme.textMuted
					}

					StyledText {
						Layout.alignment: Qt.AlignHCenter
						text: "New"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}
			}
		}
	}

	// ── the one in use ─────────────────────────────────────────────────────
	Rectangle {
		Layout.fillWidth: true
		implicitHeight: editor.implicitHeight + 28
		radius: Theme.radius.large
		color: Theme.layer2
		visible: !!Mouse.active

		ColumnLayout {
			id: editor

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 14
			spacing: 12

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				Field {
					id: nameField

					Layout.fillWidth: true
					icon: "pencil_outline"
					placeholder: "Name of the profile"
					text: Mouse.active?.name ?? ""
					onAccepted: if (nameField.text.trim() !== "") Mouse.editProfile(Mouse.activeProfile, { name: nameField.text.trim() })
					onEdited: rename.restart()

					Timer {
						id: rename

						interval: 600
						onTriggered: if (nameField.text.trim() !== "") Mouse.editProfile(Mouse.activeProfile, { name: nameField.text.trim() })
					}
				}

				TextButton {
					variant: "ghost"
					icon: "delete_outline"
					text: "Remove"
					confirm: true
					confirmText: "Remove it?"
					enabled: Mouse.profiles.length > 1
					onActivated: Mouse.removeProfile(Mouse.activeProfile)
				}
			}

			// its glyph
			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: Mouse.profileIcons

					delegate: Clickable {
						id: iconChoice

						required property string modelData
						readonly property bool picked: (Mouse.active?.icon ?? "") === modelData

						width: 34
						height: 34
						radius: 17
						color: picked ? Theme.primary : Theme.layer3
						onClicked: Mouse.editProfile(Mouse.activeProfile, { icon: modelData })

						Glyph {
							anchors.centerIn: parent
							icon: iconChoice.modelData
							size: 16
							color: iconChoice.picked ? Theme.onPrimary : Theme.textMuted
						}
					}
				}
			}

			// when it comes by itself
			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				StyledText {
					text: "Comes by itself"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}

				Flow {
					Layout.fillWidth: true
					spacing: 6

					Repeater {
						model: Mouse.active?.apps ?? []

						delegate: Chip {
							required property string modelData

							text: modelData
							icon: "close"
							selected: true
							onClicked: Mouse.editProfile(Mouse.activeProfile, { apps: (Mouse.active?.apps ?? []).filter(a => a !== modelData) })
						}
					}

					Chip {
						text: "With an app"
						icon: "plus"
						onClicked: appPick.open()

						PickList {
							id: appPick

							y: parent.height + 6
							searchable: true
							placeholder: "An open window's app"
							entries: {
								const taken = new Set(Mouse.profiles.reduce((all, p) => all.concat(p.apps ?? []), []));
								const out = [];
								for (const w of Niri.windows) {
									const id = String(w.app_id || "");
									if (!id || taken.has(id) || out.some(e => e.value === id)) continue;
									out.push({ value: id, label: id, detail: String(w.title || ""), icon: "application_outline" });
								}
								return out;
							}
							onPicked: value => Mouse.editProfile(Mouse.activeProfile, { apps: (Mouse.active?.apps ?? []).concat([String(value)]) })
						}
					}

					Chip {
						visible: Plugins.on("games")
						text: "While a game runs"
						icon: "gamepad_variant"
						selected: Mouse.active?.games === true
						onClicked: {
							// only one profile can be the game's
							for (const p of Mouse.profiles)
								if (p.games && p.id !== Mouse.activeProfile) Mouse.editProfile(p.id, { games: false });
							Mouse.editProfile(Mouse.activeProfile, { games: !(Mouse.active?.games === true) });
						}
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: "Rules and settings below are this profile's. Rules that switch profiles go along into all of them. >mouse in the launcher switches too."
				tone: Theme.textFaint
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}
	}
}
