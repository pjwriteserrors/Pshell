pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What is chosen, to set up: a zone – its name, how it looks now, its
// reactions and when it keeps quiet – or, with no zone chosen, the scene.
Rectangle {
	id: root

	property var page: null
	readonly property var zone: root.page.zone
	readonly property var scene: root.page.scene
	readonly property var triggers: Mouse.hudTriggers(root.zone)
	readonly property bool several: root.page.multi.length > 1
	readonly property var mates: root.page.groupOf(root.zone)
	readonly property var chosenZones: root.page.multi.map(id => root.page.allZones.find(z => z.id === id)).filter(z => !!z)
	readonly property var others: root.page.scenes.filter(s => s.id !== (root.zone ? (root.zone.scene ?? "") : root.page.sceneId))

	function focusName() {
		zoneName.forceActiveFocus();
		zoneName.selectAll();
	}

	radius: Theme.radius.huge
	color: Theme.layer1
	clip: true

	// a zone or the scene: the new one slides in
	Item {
		id: holder

		property string shown: root.page.multi.length > 1 ? "several" : (root.zone ? root.zone.id : `scene:${root.page.sceneId}`)

		anchors.fill: parent
		onShownChanged: swap.restart()

		ParallelAnimation {
			id: swap

			NumberAnimation {
				target: slide
				property: "x"
				from: 28
				to: 0
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.emphasized
			}
			NumberAnimation {
				target: holder
				property: "opacity"
				from: 0.2
				to: 1
				duration: Motion.medium
			}
		}

		transform: Translate {
			id: slide
		}

		Flickable {
			id: flick

			anchors.fill: parent
			anchors.margins: 18
			anchors.rightMargin: 12
			contentHeight: column.implicitHeight + 12
			contentWidth: width
			boundsBehavior: Flickable.StopAtBounds
			clip: true

			ColumnLayout {
				id: column

				width: flick.width - 6
				spacing: 14

				// ══ several zones chosen together ═══════════════════════
				ColumnLayout {
					Layout.fillWidth: true
					visible: root.several
					spacing: 12

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 2

						Clickable {
							implicitHeight: 22
							implicitWidth: backRow.implicitWidth + 10
							radius: 6
							onClicked: root.page.select("")

							RowLayout {
								id: backRow

								anchors.verticalCenter: parent.verticalCenter
								x: 2
								spacing: 4

								Glyph {
									icon: "chevron_left"
									size: 14
									color: Theme.textSubtle
								}

								StyledText {
									text: root.page.sceneName(root.zone?.scene ?? root.page.sceneId)
									font.pixelSize: Theme.size.small
									font.weight: Font.Medium
									tone: Theme.textSubtle
								}
							}
						}

						RowLayout {
							Layout.fillWidth: true
							spacing: 6

							StyledText {
								Layout.fillWidth: true
								text: `${root.page.multi.length} zones`
								font.pixelSize: 22
								font.weight: Font.Bold
							}

							// linked for good, or not
							Clickable {
								implicitHeight: 32
								implicitWidth: linkRow.implicitWidth + 22
								radius: 16
								color: root.page.linkedAll ? Theme.secondary : (hovered ? Theme.layer3 : Theme.layer2)
								tint: root.page.linkedAll ? Theme.onPrimary : Theme.text
								onClicked: root.page.link()

								Behavior on color {
									ColorAnim {}
								}

								RowLayout {
									id: linkRow

									anchors.centerIn: parent
									spacing: 6

									Glyph {
										icon: root.page.linkedAll ? "link_variant" : "link_variant_off"
										size: 15
										color: root.page.linkedAll ? Theme.onPrimary : Theme.textMuted
									}

									StyledText {
										text: root.page.linkedAll ? "Linked" : "Link"
										font.pixelSize: Theme.size.label
										font.weight: Font.DemiBold
										tone: root.page.linkedAll ? Theme.onPrimary : Theme.text
									}
								}

								Tip {
									text: root.page.linkedAll ? "A change to one is a change to all – click to unlink" : `Keep them alike for good${root.page.sameReactions ? "" : ` – all take ${root.zone?.name ?? ""}'s reactions`}`
								}
							}

							IconButton {
								Layout.preferredWidth: 32
								Layout.preferredHeight: 32
								icon: "delete_outline"
								onClicked: root.page.zoneAction(root.zone.id, "delete")

								Tip {
									text: "Delete all · Del"
								}
							}
						}
					}

					// the chosen ones: a click picks one alone, × lets one go
					Flow {
						Layout.fillWidth: true
						spacing: 6

						Repeater {
							model: root.chosenZones

							delegate: Rectangle {
								id: pickChip

								required property var modelData

								width: pickRow.implicitWidth + 12
								height: 30
								radius: 15
								color: pickArea.containsMouse ? Theme.layer3 : Theme.layer2

								Behavior on color {
									ColorAnim {}
								}

								RowLayout {
									id: pickRow

									anchors.verticalCenter: parent.verticalCenter
									x: 12
									spacing: 4

									StyledText {
										text: pickChip.modelData.name
										font.pixelSize: Theme.size.label
										font.weight: Font.Medium
									}

									IconButton {
										Layout.preferredWidth: 22
										Layout.preferredHeight: 22
										icon: "close"
										onClicked: root.page.toggle(pickChip.modelData.id)
									}
								}

								MouseArea {
									id: pickArea

									anchors.fill: parent
									anchors.rightMargin: 28
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onEntered: root.page.pointed = pickChip.modelData.id
									onExited: if (root.page.pointed === pickChip.modelData.id) root.page.pointed = ""
									onClicked: root.page.select(pickChip.modelData.id)
								}
							}
						}
					}

					// they differ: whose reactions all take
					ColumnLayout {
						Layout.fillWidth: true
						visible: !root.page.sameReactions
						spacing: 6

						StyledText {
							Layout.topMargin: 6
							text: "They react differently"
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
						}

						Repeater {
							model: root.chosenZones

							delegate: Rectangle {
								id: diffRow

								required property var modelData
								readonly property var triggers: Mouse.hudTriggers(diffRow.modelData)

								Layout.fillWidth: true
								Layout.preferredHeight: 46
								radius: Theme.radius.medium
								color: diffHover.hovered ? Theme.layer3 : Theme.layer2

								Behavior on color {
									ColorAnim {}
								}

								HoverHandler {
									id: diffHover

									onHoveredChanged: root.page.pointed = hovered ? diffRow.modelData.id : (root.page.pointed === diffRow.modelData.id ? "" : root.page.pointed)
								}

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 12
									anchors.rightMargin: 6
									spacing: 8

									StyledText {
										text: diffRow.modelData.name
										font.weight: Font.DemiBold
										elide: Text.ElideRight
										Layout.maximumWidth: 120
									}

									Repeater {
										model: diffRow.triggers

										delegate: Glyph {
											required property var modelData

											icon: root.page.kindOf(modelData.kind).icon
											size: 14
											color: root.page.kindColor(modelData.kind)
											opacity: modelData.on === false ? 0.35 : 1
										}
									}

									StyledText {
										visible: diffRow.triggers.length === 0
										text: "nothing"
										tone: Theme.textFaint
										font.pixelSize: Theme.size.label
									}

									Item {
										Layout.fillWidth: true
									}

									TextButton {
										implicitHeight: 30
										text: "Use for all"
										variant: "ghost"
										opacity: diffHover.hovered ? 1 : 0.5
										onActivated: {
											Mouse.hudSameTriggers(root.page.multi, diffRow.modelData.id);
											root.page.selected = diffRow.modelData.id;
										}
									}
								}
							}
						}
					}
				}

				// ══ a zone ══════════════════════════════════════════════
				ColumnLayout {
					Layout.fillWidth: true
					visible: !!root.zone && (!root.several || root.page.sameReactions)
					spacing: 16

					// scene › zone
					ColumnLayout {
						Layout.fillWidth: true
						visible: !root.several
						spacing: 2

						Clickable {
							implicitHeight: 22
							implicitWidth: crumbRow.implicitWidth + 10
							radius: 6
							onClicked: root.page.select("")

							RowLayout {
								id: crumbRow

								anchors.verticalCenter: parent.verticalCenter
								x: 2
								spacing: 4

								Glyph {
									icon: "chevron_left"
									size: 14
									color: Theme.textSubtle
								}

								StyledText {
									text: root.page.sceneName(root.zone?.scene ?? root.page.sceneId)
									font.pixelSize: Theme.size.small
									font.weight: Font.Medium
									tone: Theme.textSubtle
								}
							}
						}

						RowLayout {
							Layout.fillWidth: true
							spacing: 6

							TextInput {
								id: zoneName

								Layout.fillWidth: true
								text: root.zone?.name ?? ""
								color: Theme.text
								font.family: Theme.fontFamily
								font.pixelSize: 22
								font.weight: Font.Bold
								selectByMouse: true
								selectionColor: Theme.primary
								clip: true
								onEditingFinished: {
									if (root.zone && text.trim() !== "" && text.trim() !== root.zone.name) Mouse.hudChangeZone(root.zone.id, { name: text.trim() });
								}
								Keys.onEscapePressed: {
									text = root.zone?.name ?? "";
									root.page.takeFocus();
								}
								Keys.onReturnPressed: root.page.takeFocus()

								Rectangle {
									anchors.left: parent.left
									anchors.right: parent.right
									anchors.bottom: parent.bottom
									anchors.bottomMargin: -2
									height: 2
									radius: 1
									color: Theme.primary
									opacity: zoneName.activeFocus ? 1 : 0
									scale: zoneName.activeFocus ? 1 : 0.3

									Behavior on opacity {
										Anim {}
									}
									Behavior on scale {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}
							}

							IconButton {
								Layout.preferredWidth: 32
								Layout.preferredHeight: 32
								icon: "content_duplicate"
								onClicked: root.page.zoneAction(root.zone.id, "duplicate")

								Tip {
									text: "Duplicate · Ctrl+D"
								}
							}

							IconButton {
								Layout.preferredWidth: 32
								Layout.preferredHeight: 32
								icon: "delete_outline"
								onClicked: root.page.zoneAction(root.zone.id, "delete")

								Tip {
									text: "Delete · Del"
								}
							}
						}

						// linked with others: a click chooses them all
						Clickable {
							Layout.topMargin: 4
							visible: root.mates.length > 1
							implicitHeight: 26
							implicitWidth: matesRow.implicitWidth + 18
							radius: 13
							color: hovered ? Qt.alpha(Theme.secondary, 0.28) : Qt.alpha(Theme.secondary, 0.16)
							onClicked: root.page.selectMany(root.mates)

							RowLayout {
								id: matesRow

								anchors.centerIn: parent
								spacing: 5

								Glyph {
									icon: "link_variant"
									size: 13
									color: Theme.secondary
								}

								StyledText {
									text: `Linked with ${root.mates.length - 1} more`
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
									tone: Theme.secondary
								}
							}

							Tip {
								text: "Changes here go to all of them · click to choose them"
							}
						}
					}

					// how it looks now: alike to the picture, changing
					RowLayout {
						Layout.fillWidth: true
						visible: root.page.watching && !root.several
						spacing: 12

						Item {
							Layout.preferredWidth: 44
							Layout.preferredHeight: 44

							Ring {
								anchors.fill: parent
								thickness: 4
								value: Number(root.page.alike[root.zone?.id] ?? 0)
								color: Number(root.page.alike[root.zone?.id] ?? 0) >= Number(root.scene?.similar ?? 0.55) ? Theme.primary : Theme.textSubtle
							}

							StyledText {
								anchors.centerIn: parent
								text: `${Math.round(Number(root.page.alike[root.zone?.id] ?? 0) * 100)}`
								font.pixelSize: Theme.size.small
								font.weight: Font.Bold
								tabular: true
							}

							Tip {
								text: "How alike it looks to the picture now"
							}
						}

						Rectangle {
							Layout.fillWidth: true
							Layout.preferredHeight: 44
							radius: Theme.radius.medium
							color: Theme.layer2
							clip: true

							Sparkline {
								anchors.fill: parent
								anchors.topMargin: 8
								values: root.page.activity
								maximum: 1
								color: Theme.primary
							}

							StyledText {
								anchors.left: parent.left
								anchors.top: parent.top
								anchors.margins: 6
								anchors.leftMargin: 9
								text: root.page.zoneAwake(root.zone) ? "live" : "asleep"
								font.pixelSize: Theme.size.tiny
								font.weight: Font.Bold
								font.capitalization: Font.AllUppercase
								font.letterSpacing: 0.8
								tone: root.page.zoneAwake(root.zone) ? Theme.primary : Theme.textFaint
							}
						}
					}

					// ── its reactions ──
					RowLayout {
						Layout.fillWidth: true
						spacing: 6

						StyledText {
							text: "Reactions"
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
						}

						Rectangle {
							visible: root.triggers.length > 0
							Layout.preferredHeight: 20
							Layout.preferredWidth: Math.max(20, countText.implicitWidth + 12)
							radius: 10
							color: Theme.layer3

							StyledText {
								id: countText

								anchors.centerIn: parent
								text: String(root.triggers.length)
								font.pixelSize: Theme.size.small
								font.weight: Font.Bold
							}
						}

						Item {
							Layout.fillWidth: true
						}

						TextButton {
							visible: Mouse.hudClipboard.length > 0
							text: `Paste ${Mouse.hudClipboard.length}`
							icon: "content_paste"
							variant: "ghost"
							onActivated: root.page.zoneAction(root.zone.id, "paste")
						}
					}

					// the cards; something carried goes in between them
					Item {
						id: listBox

						Layout.fillWidth: true
						implicitHeight: Math.max(cards.implicitHeight, root.triggers.length === 0 ? 0 : 1)

						Column {
							id: cards

							width: parent.width
							spacing: 8

							Repeater {
								id: cardRepeater

								model: root.triggers.length

								delegate: ReactionCard {
									width: cards.width
									page: root.page
									zoneId: root.zone?.id ?? ""
									trigger: root.triggers[index] ?? ({})
								}
							}
						}

						DropArea {
							id: listDrop

							property int at: -1

							anchors.fill: parent
							anchors.topMargin: -10
							anchors.bottomMargin: -10
							keys: ["hud"]
							function place(y) {
								let at = root.triggers.length;
								for (let i = 0; i < cardRepeater.count; i += 1) {
									const card = cardRepeater.itemAt(i);
									if (card && y - 10 < card.y + card.height / 2) {
										at = i;
										break;
									}
								}
								listDrop.at = at;
							}
							onEntered: drag => listDrop.place(drag.y)
							onPositionChanged: drag => listDrop.place(drag.y)
							onExited: listDrop.at = -1
							onDropped: {
								root.page.dropOn("list", root.zone.id, listDrop.at);
								listDrop.at = -1;
							}
						}

						// where it would go
						Rectangle {
							readonly property var after: listDrop.at > 0 ? cardRepeater.itemAt(listDrop.at - 1) : null

							visible: listDrop.containsDrag && listDrop.at >= 0 && root.page.carry !== null
							x: 8
							width: parent.width - 16
							height: 3
							radius: 2
							color: Theme.primary
							y: after ? after.y + after.height + 2.5 : -5.5

							Behavior on y {
								SpatialAnim {
									duration: Motion.short
								}
							}
						}
					}

					// ── a reaction more: click, or carry it onto any zone ──
					ColumnLayout {
						Layout.fillWidth: true
						spacing: 8

						StyledText {
							text: root.triggers.length === 0 ? "React when it…" : "Add"
							font.pixelSize: root.triggers.length === 0 ? Theme.size.title : Theme.size.label
							font.weight: Font.Bold
							tone: root.triggers.length === 0 ? Theme.text : Theme.textSubtle
						}

						GridLayout {
							Layout.fillWidth: true
							columns: Math.max(2, Math.floor((column.width + 6) / 120))
							rowSpacing: 6
							columnSpacing: 6

							Repeater {
								model: Mouse.hudKinds

								delegate: Rectangle {
									id: token

									required property var modelData
									required property int index
									readonly property color accent: root.page.kindColor(token.modelData.value)

									Layout.fillWidth: true
									Layout.preferredHeight: root.triggers.length === 0 ? 46 : 36
									radius: Theme.radius.medium
									color: tokenArea.containsMouse ? Qt.alpha(token.accent, 0.2) : Theme.layer2
									scale: tokenArea.pressed ? 0.95 : 1

									Behavior on color {
										ColorAnim {}
									}
									Behavior on scale {
										SpatialAnim {
											duration: Motion.short
										}
									}
									Behavior on Layout.preferredHeight {
										SpatialAnim {
											duration: Motion.medium
										}
									}

									RowLayout {
										anchors.fill: parent
										anchors.leftMargin: 10
										anchors.rightMargin: 8
										spacing: 8

										Glyph {
											icon: token.modelData.icon
											size: 16
											color: token.accent
										}

										StyledText {
											Layout.fillWidth: true
											text: token.modelData.label
											font.pixelSize: Theme.size.label
											font.weight: Font.Medium
											elide: Text.ElideRight
										}

										Glyph {
											icon: "plus"
											size: 14
											color: token.accent
											visible: tokenArea.containsMouse
										}
									}

									CarryArea {
										id: tokenArea

										anchors.fill: parent
										page: root.page
										payload: ({ type: "kind", kind: token.modelData.value, label: token.modelData.label, icon: token.modelData.icon })
										onTapped: Mouse.hudAddTrigger(root.zone.id, token.modelData.value)
									}
								}
							}
						}
					}

					// ── quiet while another scene is up too ──
					ColumnLayout {
						Layout.fillWidth: true
						visible: root.others.length > 0
						spacing: 8

						RowLayout {
							spacing: 6

							Glyph {
								icon: "volume_off"
								size: 15
								color: Theme.textSubtle
							}

							StyledText {
								text: "Quiet while it shows"
								font.pixelSize: Theme.size.label
								font.weight: Font.Bold
								tone: Theme.textSubtle
							}
						}

						Flow {
							Layout.fillWidth: true
							spacing: 6

							Repeater {
								model: root.others

								delegate: SceneChip {
									required property var modelData

									scene: modelData
									on: (Mouse.hudList(root.zone?.unless) ?? []).includes(modelData.id)
									live: root.page.liveScenes.includes(modelData.id)
									onClicked: Mouse.hudToggleUnless(root.zone.id, modelData.id)
								}
							}
						}
					}
				}

				// ══ the scene ═══════════════════════════════════════════
				ColumnLayout {
					Layout.fillWidth: true
					visible: !root.zone && !!root.scene
					spacing: 18

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 2

						StyledText {
							text: "Scene"
							font.pixelSize: Theme.size.small
							font.weight: Font.Medium
							tone: Theme.textSubtle
						}

						RowLayout {
							Layout.fillWidth: true
							spacing: 6

							TextInput {
								id: sceneName

								Layout.fillWidth: true
								text: root.scene?.name ?? ""
								color: Theme.text
								font.family: Theme.fontFamily
								font.pixelSize: 22
								font.weight: Font.Bold
								selectByMouse: true
								selectionColor: Theme.primary
								clip: true
								onEditingFinished: {
									if (root.scene && text.trim() !== "" && text.trim() !== root.scene.name) Mouse.hudChangeScene(root.scene.id, { name: text.trim() });
								}
								Keys.onEscapePressed: {
									text = root.scene?.name ?? "";
									root.page.takeFocus();
								}
								Keys.onReturnPressed: root.page.takeFocus()
							}

							IconButton {
								Layout.preferredWidth: 32
								Layout.preferredHeight: 32
								visible: root.page.window > 0
								icon: "camera_outline"
								onClicked: root.page.shoot()

								Tip {
									text: "New picture"
								}
							}

							IconButton {
								Layout.preferredWidth: 32
								Layout.preferredHeight: 32
								icon: "delete_outline"
								onClicked: root.page.sceneAction(root.scene.id, "remove")

								Tip {
									text: "Remove the scene and its zones"
								}
							}
						}
					}

					// recognised: the likeness now against the bar it has to cross
					Likeness {
						Layout.fillWidth: true
						page: root.page
						scene: root.scene
					}

					// quiet while another shows
					ColumnLayout {
						Layout.fillWidth: true
						visible: root.others.length > 0
						spacing: 8

						RowLayout {
							spacing: 6

							Glyph {
								icon: "volume_off"
								size: 15
								color: Theme.textSubtle
							}

							StyledText {
								text: "All quiet while it shows"
								font.pixelSize: Theme.size.label
								font.weight: Font.Bold
								tone: Theme.textSubtle
							}
						}

						Flow {
							Layout.fillWidth: true
							spacing: 6

							Repeater {
								model: root.others

								delegate: SceneChip {
									required property var modelData

									scene: modelData
									on: (Mouse.hudList(root.scene?.quiet) ?? []).includes(modelData.id)
									live: root.page.liveScenes.includes(modelData.id)
									onClicked: Mouse.hudToggleQuiet(root.scene.id, modelData.id)
								}
							}
						}
					}

					// its zones
					ColumnLayout {
						Layout.fillWidth: true
						spacing: 6

						RowLayout {
							Layout.fillWidth: true
							spacing: 6

							StyledText {
								text: "Zones"
								font.pixelSize: Theme.size.title
								font.weight: Font.Bold
							}

							StyledText {
								text: String(root.page.zones.length)
								font.pixelSize: Theme.size.title
								font.weight: Font.Bold
								tone: Theme.textFaint
							}

							Item {
								Layout.fillWidth: true
							}

							IconButton {
								Layout.preferredWidth: 30
								Layout.preferredHeight: 30
								visible: Mouse.hudClipboard.length > 0 && root.page.zones.length > 0
								icon: "content_paste"
								onClicked: root.page.sceneAction(root.scene.id, "paste")

								Tip {
									text: `Paste ${Mouse.hudClipboard.length} into every zone`
								}
							}

							Pick {
								visible: root.page.zones.length > 0 && Mouse.hudPresets.length > 0
								entries: Mouse.hudPresets.map(p => ({ value: p.id, label: p.name, detail: root.page.presetSummary(p), icon: "playlist_check" }))
								fallback: "Give all…"
								icon: "playlist_plus"
								accent: Theme.textMuted
								listWidth: 300
								onPicked: value => root.page.dropOnScene(root.scene.id, { type: "preset", presetId: String(value), label: Mouse.hudPreset(String(value))?.name ?? "" })
							}
						}

						Repeater {
							model: root.page.zones.length

							delegate: Rectangle {
								id: zrow

								required property int index
								readonly property var modelData: root.page.zones[zrow.index] ?? ({ id: "", name: "" })
								readonly property bool target: zdrop.containsDrag && root.page.carry !== null
								readonly property bool awake: root.page.zoneAwake(zrow.modelData)

								Layout.fillWidth: true
								Layout.preferredHeight: 44
								radius: Theme.radius.medium
								color: zrow.target ? Qt.alpha(Theme.primary, 0.3) : (zrowArea.containsMouse ? Theme.layer3 : Theme.layer2)
								opacity: 0
								Component.onCompleted: zrowIn.start()

								Behavior on color {
									ColorAnim {}
								}

								SequentialAnimation {
									id: zrowIn

									PauseAnimation {
										duration: zrow.index * 30
									}
									NumberAnimation {
										target: zrow
										property: "opacity"
										to: 1
										duration: Motion.medium
									}
								}

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 12
									anchors.rightMargin: 10
									spacing: 8

									Rectangle {
										Layout.preferredWidth: 8
										Layout.preferredHeight: 8
										radius: 4
										color: root.page.fired === zrow.modelData.id ? Theme.primary : (zrow.awake ? Qt.alpha(Theme.primary, 0.6) : Theme.layer3)

										Behavior on color {
											ColorAnim {
												duration: 120
											}
										}
									}

									StyledText {
										Layout.fillWidth: true
										text: zrow.target ? `+ ${root.page.carry?.label ?? ""}` : zrow.modelData.name
										font.weight: Font.DemiBold
										font.pixelSize: Theme.size.body
										elide: Text.ElideRight
									}

									Glyph {
										visible: !!zrow.modelData.group
										icon: "link_variant"
										size: 14
										color: Theme.secondary
									}

									Repeater {
										model: Mouse.hudTriggers(zrow.modelData).filter(t => t.on !== false)

										delegate: Glyph {
											required property var modelData

											icon: root.page.kindOf(modelData.kind).icon
											size: 14
											color: root.page.kindColor(modelData.kind)
										}
									}

									Glyph {
										icon: "chevron_right"
										size: 16
										color: Theme.textFaint
									}
								}

								MouseArea {
									id: zrowArea

									anchors.fill: parent
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onContainsMouseChanged: root.page.pointed = zrowArea.containsMouse ? zrow.modelData.id : (root.page.pointed === zrow.modelData.id ? "" : root.page.pointed)
									onClicked: mouse => {
										if (mouse.modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) root.page.toggle(zrow.modelData.id);
										else root.page.select(zrow.modelData.id);
									}
								}

								DropArea {
									id: zdrop

									anchors.fill: parent
									keys: ["hud"]
									onDropped: root.page.dropOn("zone", zrow.modelData.id, -1)
								}
							}
						}

						// none yet
						Rectangle {
							Layout.fillWidth: true
							Layout.preferredHeight: 64
							visible: root.page.zones.length === 0
							radius: Theme.radius.medium
							color: "transparent"
							border.width: 1.5
							border.color: Theme.outline

							RowLayout {
								anchors.centerIn: parent
								spacing: 8

								Glyph {
									icon: "selection_drag"
									size: 18
									color: Theme.textSubtle
								}

								StyledText {
									text: "Drag on the picture"
									tone: Theme.textSubtle
									font.weight: Font.Medium
								}
							}
						}
					}

					// the picture's own effects, for all scenes
					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: autoRow.implicitHeight + 20
						radius: Theme.radius.medium
						color: Theme.layer2

						RowLayout {
							id: autoRow

							anchors.left: parent.left
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							anchors.leftMargin: 12
							anchors.rightMargin: 10
							spacing: 10

							Glyph {
								icon: "auto_fix"
								size: 18
								color: Mouse.option("eyesAuto", true) !== false ? Theme.primary : Theme.textFaint
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 1

								StyledText {
									text: "Shakes, hits and flashes"
									font.weight: Font.DemiBold
									font.pixelSize: Theme.size.label
								}

								StyledText {
									Layout.fillWidth: true
									text: "felt anywhere in the picture, not only in zones"
									font.pixelSize: Theme.size.small
									tone: Theme.textSubtle
									wrapMode: Text.WordWrap
								}
							}

							Toggle {
								checked: Mouse.option("eyesAuto", true) !== false
								onToggled: on => Mouse.setOption("eyesAuto", on)
							}
						}
					}
				}

				// ══ nothing at all yet ═══════════════════════════════════
				ColumnLayout {
					Layout.fillWidth: true
					Layout.topMargin: 40
					visible: !root.zone && !root.scene
					spacing: 10

					Glyph {
						Layout.alignment: Qt.AlignHCenter
						icon: "crosshairs_gps"
						size: 40
						color: Theme.textFaint
					}

					StyledText {
						Layout.alignment: Qt.AlignHCenter
						text: root.page.game !== "" ? "No scene yet" : "No game running"
						font.pixelSize: Theme.size.title
						font.weight: Font.DemiBold
						tone: Theme.textMuted
					}
				}
			}
		}
	}
}
