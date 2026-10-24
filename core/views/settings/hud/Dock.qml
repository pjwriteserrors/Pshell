pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The shelf of sequences – reactions kept by name for any zone of any game.
// Drag one onto a zone or a scene (or click it for the chosen zone); drop a
// reaction here to keep it; drag a sequence to the bin to let it go.
Rectangle {
	id: root

	property var page: null
	readonly property bool carryingPreset: root.page.carry?.type === "preset"
	readonly property bool keepTarget: shelfDrop.containsDrag && root.page.carry?.type === "reaction"

	implicitHeight: 64
	radius: Theme.radius.huge
	color: root.keepTarget ? Qt.alpha(Theme.primary, 0.22) : Theme.layer1

	Behavior on color {
		ColorAnim {}
	}

	DropArea {
		id: shelfDrop

		anchors.fill: parent
		keys: ["hud"]
		onDropped: root.page.dropOn("shelf", "", -1)
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 16
		anchors.rightMargin: 12
		spacing: 12

		Glyph {
			icon: root.keepTarget ? "bookmark_plus_outline" : "playlist_check"
			size: 20
			color: root.keepTarget ? Theme.primary : Theme.textSubtle
		}

		StyledText {
			text: root.keepTarget ? "Keep it" : "Sequences"
			font.weight: Font.Bold
			tone: root.keepTarget ? Theme.primary : Theme.textMuted
		}

		Flickable {
			id: flick

			Layout.fillWidth: true
			Layout.fillHeight: true
			contentWidth: shelf.implicitWidth
			contentHeight: height
			flickableDirection: Flickable.HorizontalFlick
			boundsBehavior: Flickable.StopAtBounds
			interactive: !root.page.carry
			clip: true

			Row {
				id: shelf

				anchors.verticalCenter: parent.verticalCenter
				spacing: 8

				Repeater {
					model: Mouse.hudPresets

					delegate: Rectangle {
						id: token

						required property var modelData
						required property int index

						readonly property string presetId: String(token.modelData.id ?? "")
						readonly property bool flashed: root.page.presetFlash === token.presetId
						readonly property bool renaming: root.page.renamingPreset === token.presetId
						readonly property bool carried: root.page.carry?.type === "preset" && root.page.carry?.presetId === token.presetId
						readonly property var triggers: Mouse.hudList(token.modelData.triggers) ?? []
						property real shake: 0

						width: tokenRow.implicitWidth + 22
						height: 42
						radius: 21
						color: token.flashed ? Theme.primary : (tokenArea.containsMouse ? Theme.layer3 : Theme.layer2)
						opacity: token.carried ? 0.3 : 1
						scale: 0.6
						Component.onCompleted: tokenIn.start()
						transform: Translate {
							x: token.shake
						}

						Behavior on color {
							ColorAnim {}
						}
						Behavior on opacity {
							Anim {}
						}
						Behavior on width {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						NumberAnimation {
							id: tokenIn

							target: token
							property: "scale"
							to: 1
							duration: Motion.long
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatialFast
						}

						// no zone chosen: a shake says so
						SequentialAnimation {
							id: shakeAnim

							NumberAnimation {
								target: token
								property: "shake"
								to: -6
								duration: 50
							}
							NumberAnimation {
								target: token
								property: "shake"
								to: 6
								duration: 70
							}
							NumberAnimation {
								target: token
								property: "shake"
								to: -3
								duration: 60
							}
							NumberAnimation {
								target: token
								property: "shake"
								to: 0
								duration: 50
							}
						}

						Timer {
							running: token.flashed
							interval: 1500
							onTriggered: root.page.presetFlash = ""
						}

						RowLayout {
							id: tokenRow

							anchors.verticalCenter: parent.verticalCenter
							x: 7
							spacing: 8

							// its reactions, as their icons in a little stack
							Rectangle {
								Layout.preferredWidth: 28
								Layout.preferredHeight: 28
								radius: 14
								color: token.flashed ? Qt.alpha(Theme.onPrimary, 0.2) : Theme.layer1

								Glyph {
									anchors.centerIn: parent
									icon: token.flashed ? "check" : root.page.kindOf(token.triggers[0]?.kind).icon
									size: 15
									color: token.flashed ? Theme.onPrimary : root.page.kindColor(token.triggers[0]?.kind)
								}

								Rectangle {
									visible: token.triggers.length > 1 && !token.flashed
									anchors.right: parent.right
									anchors.bottom: parent.bottom
									anchors.margins: -3
									width: 15
									height: 15
									radius: 8
									color: Theme.primary

									StyledText {
										anchors.centerIn: parent
										text: String(token.triggers.length)
										font.pixelSize: 9
										font.weight: Font.Bold
										color: Theme.onPrimary
									}
								}
							}

							StyledText {
								Layout.rightMargin: 6
								visible: !token.renaming
								text: String(token.modelData.name ?? "")
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
								tone: token.flashed ? Theme.onPrimary : Theme.text
							}

							TextInput {
								id: nameInput

								Layout.preferredWidth: Math.max(80, contentWidth + 4)
								Layout.rightMargin: 6
								visible: token.renaming
								color: Theme.text
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
								selectByMouse: true
								selectionColor: Theme.primary
								onVisibleChanged: if (visible) {
									text = String(token.modelData.name ?? "");
									forceActiveFocus();
									selectAll();
								}
								onAccepted: {
									Mouse.hudRenamePreset(token.presetId, text);
									root.page.renamingPreset = "";
								}
								onActiveFocusChanged: if (!activeFocus && token.renaming) accepted()
								Keys.onEscapePressed: root.page.renamingPreset = ""
							}
						}

						CarryArea {
							id: tokenArea

							anchors.fill: parent
							enabled: !token.renaming
							page: root.page
							cursorShape: Qt.OpenHandCursor
							payload: ({ type: "preset", presetId: token.presetId, label: String(token.modelData.name ?? ""), icon: "playlist_check" })
							onTapped: {
								if (!root.page.zone) {
									shakeAnim.restart();
									return;
								}
								root.page.dropOnZone(root.page.zone.id, { type: "preset", presetId: token.presetId, label: String(token.modelData.name ?? "") });
							}
							onDoubleTapped: root.page.renamingPreset = token.presetId
							onMenu: menu.open()
						}

						Tip {
							text: root.page.presetSummary(token.modelData) + (token.modelData.from && token.modelData.from !== root.page.game ? ` · from ${token.modelData.from}` : "")
						}

						PickList {
							id: menu

							y: -height - 6
							width: 250
							current: ""
							entries: {
								const list = [{ value: "rename", label: "Rename", icon: "pencil_outline" }];
								if (root.page.zone) list.push({ value: "replace", label: `Instead of ${root.page.zone.name}'s own`, icon: "swap_horizontal" });
								list.push({ value: "remove", label: "Remove", icon: "delete_outline" });
								return list;
							}
							onPicked: value => {
								if (value === "rename") root.page.renamingPreset = token.presetId;
								else if (value === "replace") root.page.replaceWithPreset(token.presetId);
								else root.page.removePreset(token.presetId);
							}
						}
					}
				}

				StyledText {
					visible: Mouse.hudPresets.length === 0
					height: 42
					verticalAlignment: Text.AlignVCenter
					text: "Kept reactions land here"
					tone: Theme.textFaint
					font.pixelSize: Theme.size.label
				}
			}
		}

		// keep the chosen zone's reactions
		TextButton {
			visible: !!root.page.zone && Mouse.hudTriggers(root.page.zone).length > 0 && !root.carryingPreset
			text: `Keep ${root.page.zone?.name ?? ""}`
			icon: "bookmark_plus_outline"
			variant: "tonal"
			onActivated: root.page.keepZone(root.page.zone.id, -1)
		}

		// the bin, while a sequence is carried
		Rectangle {
			id: bin

			readonly property bool hot: binDrop.containsDrag

			Layout.preferredWidth: root.carryingPreset ? 110 : 0
			Layout.preferredHeight: 42
			radius: 21
			color: bin.hot ? Theme.danger : Theme.dangerContainer
			opacity: root.carryingPreset ? 1 : 0
			visible: Layout.preferredWidth > 1
			scale: bin.hot ? 1.08 : 1
			clip: true

			Behavior on Layout.preferredWidth {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on opacity {
				Anim {}
			}
			Behavior on color {
				ColorAnim {}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.short
				}
			}

			RowLayout {
				anchors.centerIn: parent
				spacing: 6

				Glyph {
					icon: bin.hot ? "delete_forever_outline" : "delete_outline"
					size: 17
					color: bin.hot ? Theme.onPrimary : Theme.danger
					rotation: bin.hot ? -12 : 0

					Behavior on rotation {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}

				StyledText {
					text: "Remove"
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
					tone: bin.hot ? Theme.onPrimary : Theme.danger
				}
			}

			DropArea {
				id: binDrop

				anchors.fill: parent
				keys: ["hud"]
				onDropped: root.page.dropOn("bin", "", -1)
			}
		}
	}
}
