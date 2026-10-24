pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.mouse
import "mouse/Waves.js" as Waves

// HUD haptics: the game's HUD by hand (gamefeel.Eyes; the model lives in
// Mouse.qml – hudScenes, hudZones). Scenes are pictures of the game as its
// HUD looks in a fight, a dialog, exploring; the daemon tells which one is
// up by how alike the frame is to each picture inside its zones, and only
// that scene's zones fire. Zones are drawn on the picture here (the boxes
// found on it are offered under the cursor; "Suggest" marks the HUD-like
// ones), or on the real screen like a screenshot (Screenshot.hud). A zone
// reacts in several ways at once, each with its own pattern: it changes,
// it changes after a press, it is clicked, the pointer comes in, it turns
// red, brightens, darkens.
SettingsPage {
	id: root

	title: "HUD haptics"
	description: Mouse.gameKey !== "" ? `${Mouse.gameKey} – draw where the HUD is, say what each zone reacts to and how it feels. The game's picture is watched at 20 fps; a zone fires exactly when its condition holds.` : "Zones on the game's HUD that the mouse feels. Start a game, then come back: its window is pictured here."
	asideWidth: Math.min(400, Math.max(320, root.width * 0.3))

	readonly property string game: Mouse.gameKey
	readonly property int window: Mouse.gameWindow
	readonly property var scenes: Mouse.hudScenes
	readonly property var scene: Mouse.hudScene
	readonly property string sceneId: root.scene?.id ?? ""
	readonly property var allZones: Mouse.hudZones
	readonly property var zones: root.allZones.filter(z => (z.scene ?? "") === root.sceneId || (!z.scene && root.scenes.length <= 1))
	readonly property var live: Mouse.eyes?.latest?.zones ?? ({})
	readonly property bool watching: Mouse.eyes?.on === true
	readonly property string liveScene: Mouse.hudLiveScene
	readonly property var scores: Mouse.hudScores
	// every pattern the mouse has, named as the haptics card names them
	readonly property var feels: Mouse.waveforms.map(w => ({ value: w, label: Waves.names[w] ?? w.toLowerCase() }))
	readonly property string shotDir: `${Paths.runtime}/hud`
	readonly property string picture: String(root.scene?.picture ?? "")
	property bool shooting: false
	// the zone being edited (its id), the key recorder (trigger index, -1 none)
	property string selected: ""
	property int recording: -1
	// which zone fired last, for a flash
	property string fired: ""
	// the boxes found on the picture (fractions) and the suggested ones
	property var boxes: []
	property var suggested: []
	property bool suggesting: false
	property bool guessing: false
	property string guessedFor: ""

	readonly property var zone: root.allZones.find(z => z.id === root.selected) ?? null
	readonly property var triggers: Mouse.hudTriggers(root.zone)

	onActiveChanged: {
		Mouse.watching = root.active;
		if (root.active && root.picture === "" && root.scenes.length === 0 && root.window > 0) root.shoot();
	}
	Component.onDestruction: Mouse.watching = false

	function feelLabel(value) {
		return root.feels.find(f => f.value === value)?.label ?? String(value).toLowerCase();
	}

	function kindOf(kind) {
		return Mouse.hudKinds.find(k => k.value === kind) ?? Mouse.hudKinds[0];
	}

	function keyLabel(trigger) {
		const key = trigger?.key ?? "";
		if (key === "" || key === null) return trigger?.kind === "click" ? "Any button" : "Any press";
		if (trigger.keyName) return trigger.keyName;
		const names = { BTN_LEFT: "Left click", BTN_RIGHT: "Right click", BTN_MIDDLE: "Middle click", BTN_SIDE: "Back button", BTN_EXTRA: "Forward button" };
		return names[key] ?? String(key).replace(/^KEY_/, "");
	}

	function describe(zone) {
		return Mouse.hudTriggers(zone).filter(t => t.on !== false).map(t => root.kindOf(t.kind).label.toLowerCase()).join(", ") || "reacts to nothing";
	}

	function add(rect, values) {
		root.selected = Mouse.hudAddZone(rect, values);
	}

	// the smallest found box under a point of the picture (fractions)
	function boxAt(fx, fy) {
		let best = null;
		for (const b of root.boxes) {
			if (fx >= b[0] && fx <= b[0] + b[2] && fy >= b[1] && fy <= b[1] + b[3]) {
				if (!best || b[2] * b[3] < best[2] * best[3]) best = b;
			}
		}
		return best;
	}

	// a picture of the game's window into the scene, once
	function shoot() {
		if (root.window <= 0 || root.shooting) return;
		Mouse.hudSceneForDrawing();
		root.shooting = true;
		shots.running = false;
		shots.running = true;
		giveUp.restart();
	}

	// the boxes on the scene's picture
	function guess() {
		if (root.picture === "" || root.guessing) return;
		root.guessing = true;
		guesser.running = false;
		guesser.command = ["python3", `${Paths.scripts}/mouse/hud_guess.py`, root.picture, JSON.stringify({ grid: Mouse.eyes?.grid ?? [], yours: Mouse.eyes?.hud?.yours ?? [] })];
		guesser.running = true;
	}

	function reload() {
		pictureImage.source = "";
		pictureImage.source = root.picture ? `file://${root.picture}?${Mouse.hudPictureRev}` : "";
	}

	function recordKey(event) {
		if (root.recording < 0 || !root.zone) return;
		if (event.key === Qt.Key_Escape) {
			root.recording = -1;
			return;
		}
		const code = event.nativeScanCode - 8;
		if (code <= 0) return;
		let name = event.text && event.text.trim().length === 1 ? event.text.toUpperCase() : "";
		if (!name) name = { [Qt.Key_Space]: "Space", [Qt.Key_Shift]: "Shift", [Qt.Key_Control]: "Ctrl", [Qt.Key_Alt]: "Alt", [Qt.Key_Tab]: "Tab" }[event.key] ?? `Key ${code}`;
		Mouse.hudChangeTrigger(root.zone.id, root.recording, { key: code, keyName: name });
		root.recording = -1;
	}

	Timer {
		id: giveUp

		interval: 8000
		onTriggered: {
			root.shooting = false;
			shots.running = false;
		}
	}

	onPictureChanged: {
		root.boxes = [];
		root.suggested = [];
		root.suggesting = false;
		root.reload();
	}
	Component.onCompleted: root.reload()

	Connections {
		target: Mouse

		function onHudPictureRevChanged() {
			root.guessedFor = "";
			root.reload();
		}

		function onFelt(source, kind, strength, wave, label, cluster) {
			if (source !== "eyes" || kind !== "zone") return;
			const hit = root.allZones.find(z => z.name === label);
			if (!hit) return;
			root.fired = hit.id;
			firedOff.restart();
		}
	}

	Timer {
		id: firedOff

		interval: 380
		onTriggered: root.fired = ""
	}

	Process {
		id: shots

		command: ["python3", `${Paths.scripts}/window_shots.py`, root.shotDir, "1280", "0"]
		stdinEnabled: true
		onStarted: {
			const raw = Niri.windowMap?.[String(root.window)] ?? Niri.windowMap?.[root.window];
			const size = raw?.layout?.window_size ?? [1920, 1080];
			shots.write(`${root.window}:${Math.round(Number(size[0]) || 1920)}:${Math.round(Number(size[1]) || 1080)}\n`);
		}
		onExited: root.shooting = false
		stdout: SplitParser {
			onRead: line => {
				let data = null;
				try {
					data = JSON.parse(line);
				} catch (error) {
					return;
				}
				if (Number(data.id) !== root.window) return;
				const scene = Mouse.hudSceneForDrawing();
				if (scene?.picture) {
					copier.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && cp -f "$1" "$2"', "sh", String(data.file), String(scene.picture)];
					copier.running = true;
				}
				root.shooting = false;
				shots.running = false;
			}
		}
	}

	Process {
		id: copier

		onExited: Mouse.hudPictureRev += 1
	}

	Process {
		id: guesser

		stdout: StdioCollector {
			onStreamFinished: {
				root.guessing = false;
				let data = null;
				try {
					data = JSON.parse(this.text);
				} catch (error) {
					return;
				}
				root.guessedFor = root.picture;
				root.boxes = Array.isArray(data?.boxes) ? data.boxes : [];
				root.suggested = Array.isArray(data?.suggested) ? data.suggested : [];
			}
		}
		onExited: root.guessing = false
	}

	// takes the key while a trigger records one
	Item {
		id: catcher

		focus: root.recording >= 0
		Keys.onPressed: event => {
			root.recordKey(event);
			event.accepted = true;
		}
		onFocusChanged: if (root.recording >= 0) catcher.forceActiveFocus()
	}

	// ── the aside: the zone, or the state of things ──────────────────────
	aside: Rectangle {
		anchors.fill: parent
		radius: Theme.radius.huge
		color: Theme.layer1
		clip: true

		// the panel slides as the zone changes
		Item {
			id: asideBody

			property string shown: root.selected

			anchors.fill: parent
			anchors.margins: 18
			opacity: 1
			transform: Translate {
				id: asideSlide

				x: 0
			}

			onShownChanged: slideIn.restart()

			SequentialAnimation {
				id: slideIn

				NumberAnimation {
					target: asideSlide
					property: "x"
					from: 26
					to: 0
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.emphasized
				}
			}

			Flickable {
				anchors.fill: parent
				contentHeight: asideColumn.implicitHeight
				contentWidth: width
				boundsBehavior: Flickable.StopAtBounds
				clip: true

				ColumnLayout {
					id: asideColumn

					width: parent.width
					spacing: 12

					// ── nothing picked: what is live ───────────────────
					ColumnLayout {
						Layout.fillWidth: true
						visible: !root.zone
						spacing: 12

						RowLayout {
							spacing: 10

							Rectangle {
								Layout.preferredWidth: 36
								Layout.preferredHeight: 36
								radius: Theme.radius.medium
								color: root.watching ? Theme.primary : Theme.primarySoft

								Behavior on color {
									ColorAnim {}
								}

								Glyph {
									anchors.centerIn: parent
									icon: "eye_outline"
									size: 18
									color: root.watching ? Theme.onPrimary : Theme.primary
								}
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 1

								StyledText {
									text: root.watching ? "Watching the game" : "Not watching"
									font.weight: Font.DemiBold
								}

								StyledText {
									Layout.fillWidth: true
									text: root.watching ? `${Mouse.eyes?.frames ?? 0} frames · ${Mouse.eyes?.seen?.zone ?? 0} zone pulses${Mouse.eyes?.pointer === false ? " · no pointer (a Wayland game): clicks and hovers stay quiet" : ""}` : (root.game !== "" ? "Give the game the focus and the picture is watched" : "No game runs")
									tone: Theme.textSubtle
									font.pixelSize: Theme.size.small
									wrapMode: Text.WordWrap
								}
							}
						}

						// the scene that is up
						Rectangle {
							Layout.fillWidth: true
							implicitHeight: sceneUp.implicitHeight + 24
							radius: Theme.radius.large
							color: root.liveScene !== "" ? Theme.primaryContainer : Theme.layer2

							Behavior on color {
								ColorAnim {}
							}

							ColumnLayout {
								id: sceneUp

								anchors.left: parent.left
								anchors.right: parent.right
								anchors.top: parent.top
								anchors.margins: 12
								spacing: 6

								StyledText {
									text: root.liveScene !== "" ? `"${root.scenes.find(s => s.id === root.liveScene)?.name ?? "?"}" is up` : (root.watching && root.scenes.length > 1 ? "No scene recognised – every zone is live" : "Scene")
									font.weight: Font.DemiBold
									font.pixelSize: Theme.size.small
								}

								Repeater {
									model: root.scenes

									delegate: RowLayout {
										id: scoreRow

										required property var modelData

										readonly property real score: Number(root.scores[scoreRow.modelData.id] ?? 0)

										Layout.fillWidth: true
										spacing: 8

										StyledText {
											Layout.preferredWidth: 110
											text: scoreRow.modelData.name
											font.pixelSize: Theme.size.small
											tone: root.liveScene === scoreRow.modelData.id ? Theme.text : Theme.textSubtle
											elide: Text.ElideRight
										}

										Rectangle {
											Layout.fillWidth: true
											Layout.preferredHeight: 6
											radius: 3
											color: Qt.alpha(Theme.primary, 0.18)

											Rectangle {
												width: parent.width * Math.max(0, Math.min(1, scoreRow.score))
												height: parent.height
												radius: 3
												color: Theme.primary

												Behavior on width {
													Anim {
														duration: Motion.medium
													}
												}
											}

											// the bar it has to cross
											Rectangle {
												x: parent.width * Number(scoreRow.modelData.similar ?? 0.45)
												width: 2
												height: 10
												y: -2
												radius: 1
												color: Theme.text
												opacity: 0.5
											}
										}

										StyledText {
											Layout.preferredWidth: 36
											text: `${Math.round(scoreRow.score * 100)} %`
											font.pixelSize: Theme.size.small
											tone: Theme.textFaint
											horizontalAlignment: Text.AlignRight
										}
									}
								}
							}
						}

						StyledText {
							Layout.fillWidth: true
							text: root.allZones.length > 0 ? `${root.allZones.length} zone${root.allZones.length === 1 ? "" : "s"} in ${root.scenes.length} scene${root.scenes.length === 1 ? "" : "s"}. Click a zone on the picture to set what it reacts to and how it feels; drag it to move it, pull a corner to resize it. Delete removes it.` : "Nothing drawn yet. Drag a box on the picture, click a box it found, or draw on the real screen."
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
							wrapMode: Text.WordWrap
						}

						StyledText {
							Layout.fillWidth: true
							text: "A zone only has to look alike, not the same: a scene is recognised when the picture inside its zones correlates with the scene's picture above its own bar – brighter, noisier, slightly moved is still the same HUD."
							tone: Theme.textFaint
							font.pixelSize: Theme.size.small
							wrapMode: Text.WordWrap
						}
					}

					// ── the zone ───────────────────────────────────────
					ColumnLayout {
						Layout.fillWidth: true
						visible: !!root.zone
						spacing: 12

						RowLayout {
							Layout.fillWidth: true
							spacing: 8

							Field {
								Layout.fillWidth: true
								placeholder: "Name"
								icon: "tag_outline"
								text: root.zone?.name ?? ""
								onEdited: text => {
									if (root.zone && text.trim() !== "") Mouse.hudChangeZone(root.zone.id, { name: text.trim() });
								}
							}

							IconButton {
								Layout.preferredWidth: 34
								Layout.preferredHeight: 34
								icon: "delete_outline"
								onClicked: {
									const id = root.zone.id;
									root.selected = "";
									Mouse.hudRemoveZone(id);
								}
							}
						}

						// where it is, live
						Flow {
							Layout.fillWidth: true
							spacing: 6

							Repeater {
								model: root.zone ? [
									{ label: "x", value: `${Math.round(root.zone.x * 1000) / 10} %` },
									{ label: "y", value: `${Math.round(root.zone.y * 1000) / 10} %` },
									{ label: "w", value: `${Math.round(root.zone.w * 1000) / 10} %` },
									{ label: "h", value: `${Math.round(root.zone.h * 1000) / 10} %` },
									{ label: "change", value: root.live[root.zone.id] ? String(root.live[root.zone.id][0]) : "–" },
									{ label: "red", value: root.live[root.zone.id] ? `${root.live[root.zone.id][1] > 0 ? "+" : ""}${root.live[root.zone.id][1]}` : "–" },
									{ label: "bright", value: root.live[root.zone.id] ? `${root.live[root.zone.id][2] > 0 ? "+" : ""}${root.live[root.zone.id][2]}` : "–" }
								] : []

								delegate: Rectangle {
									id: fact

									required property var modelData

									width: factRow.implicitWidth + 16
									height: 24
									radius: 12
									color: Theme.layer2

									RowLayout {
										id: factRow

										anchors.centerIn: parent
										spacing: 5

										StyledText {
											text: fact.modelData.label
											font.pixelSize: Theme.size.small
											tone: Theme.textFaint
										}

										StyledText {
											text: fact.modelData.value
											font.pixelSize: Theme.size.small
											font.weight: Font.DemiBold
										}
									}
								}
							}
						}

						RowLayout {
							Layout.fillWidth: true
							spacing: 6

							StyledText {
								text: "Reacts to"
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
								tone: Theme.textSubtle
							}

							Item {
								Layout.fillWidth: true
							}

							TextButton {
								visible: root.triggers.length > 0
								text: "Copy all"
								icon: "content_copy"
								variant: "text"
								onActivated: Mouse.hudCopyTriggers(root.zone.id, -1)
							}

							TextButton {
								visible: Mouse.hudClipboard.length > 0
								text: `Paste ${Mouse.hudClipboard.length}`
								icon: "content_paste"
								variant: "tonal"
								onActivated: Mouse.hudPasteTriggers(root.zone.id, false)
							}
						}

						StyledText {
							Layout.fillWidth: true
							visible: Mouse.hudClipboard.length > 0
							text: `${Mouse.hudClipboard.length} reaction${Mouse.hudClipboard.length === 1 ? "" : "s"} copied from "${Mouse.hudClipboardFrom}" – paste adds them here; the scene's card pastes them into every zone of the scene.`
							tone: Theme.textFaint
							font.pixelSize: Theme.size.small
							wrapMode: Text.WordWrap
						}

						// every reaction, with its own pattern
						Repeater {
							model: root.triggers.length

							delegate: Rectangle {
								id: trow

								required property int index

								readonly property var trigger: root.triggers[trow.index] ?? ({})
								readonly property var kind: root.kindOf(trow.trigger.kind)
								readonly property bool on: trow.trigger.on !== false
								readonly property bool withKey: trow.trigger.kind === "press" || trow.trigger.kind === "click"
								readonly property bool withLevel: trow.trigger.kind === "change" || trow.trigger.kind === "press" || trow.trigger.kind === "red" || trow.trigger.kind === "bright" || trow.trigger.kind === "dark"

								Layout.fillWidth: true
								implicitHeight: tcol.implicitHeight + 20
								radius: Theme.radius.large
								color: trow.on ? Theme.layer2 : Theme.layer1
								border.width: 1
								border.color: trow.on ? "transparent" : Theme.outline
								opacity: 0
								scale: 0.96
								Component.onCompleted: appear.start()

								Behavior on color {
									ColorAnim {}
								}

								ParallelAnimation {
									id: appear

									NumberAnimation {
										target: trow
										property: "opacity"
										to: 1
										duration: Motion.medium
									}
									NumberAnimation {
										target: trow
										property: "scale"
										to: 1
										duration: Motion.long
										easing.type: Easing.BezierSpline
										easing.bezierCurve: Motion.spatial
									}
								}

								ColumnLayout {
									id: tcol

									anchors.left: parent.left
									anchors.right: parent.right
									anchors.top: parent.top
									anchors.margins: 10
									spacing: 8

									RowLayout {
										Layout.fillWidth: true
										spacing: 8

										Glyph {
											icon: trow.kind.icon
											size: 16
											color: trow.on ? Theme.primary : Theme.textFaint
										}

										StyledText {
											Layout.fillWidth: true
											text: trow.kind.label
											font.weight: Font.DemiBold
											font.pixelSize: Theme.size.small
											tone: trow.on ? Theme.text : Theme.textFaint
										}

										IconButton {
											Layout.preferredWidth: 26
											Layout.preferredHeight: 26
											icon: "play"
											onClicked: Mouse.play(trow.trigger.feel)
										}

										IconButton {
											Layout.preferredWidth: 26
											Layout.preferredHeight: 26
											icon: "content_copy"
											onClicked: Mouse.hudCopyTriggers(root.zone.id, trow.index)
										}

										Toggle {
											checked: trow.on
											onToggled: on => Mouse.hudChangeTrigger(root.zone.id, trow.index, { on })
										}

										IconButton {
											Layout.preferredWidth: 26
											Layout.preferredHeight: 26
											icon: "close"
											onClicked: Mouse.hudRemoveTrigger(root.zone.id, trow.index)
										}
									}

									// the pattern
									Flow {
										Layout.fillWidth: true
										spacing: 5

										Repeater {
											model: root.feels

											delegate: Chip {
												required property var modelData

												text: modelData.label
												selected: trow.trigger.feel === modelData.value
												onClicked: {
													Mouse.hudChangeTrigger(root.zone.id, trow.index, { feel: modelData.value });
													Mouse.play(modelData.value);
												}
											}
										}
									}

									// which press or button
									Flow {
										Layout.fillWidth: true
										visible: trow.withKey
										spacing: 5

										Repeater {
											model: trow.trigger.kind === "click" ? [{ key: "", label: "Any button" }, { key: "BTN_LEFT", label: "Left" }, { key: "BTN_RIGHT", label: "Right" }, { key: "BTN_MIDDLE", label: "Middle" }] : [{ key: "", label: "Any press" }, { key: "BTN_LEFT", label: "Left click" }, { key: "BTN_RIGHT", label: "Right click" }]

											delegate: Chip {
												required property var modelData

												text: modelData.label
												selected: root.recording !== trow.index && String(trow.trigger.key ?? "") === modelData.key
												onClicked: {
													root.recording = -1;
													Mouse.hudChangeTrigger(root.zone.id, trow.index, { key: modelData.key, keyName: "" });
												}
											}
										}

										Chip {
											visible: trow.trigger.kind === "press"
											text: root.recording === trow.index ? "Press a key…" : (typeof trow.trigger.key === "number" ? `Key ${root.keyLabel(trow.trigger)}` : "A key…")
											icon: "keyboard_outline"
											selected: root.recording === trow.index || typeof trow.trigger.key === "number"
											onClicked: {
												root.recording = root.recording === trow.index ? -1 : trow.index;
												if (root.recording >= 0) catcher.forceActiveFocus();
											}
										}
									}

									ValueSlider {
										visible: trow.withLevel
										from: 0
										to: 60
										step: 1
										icon: "tune_variant"
										label: "Needs"
										value: Number(trow.trigger.level ?? 0)
										format: v => v <= 0 ? "by itself" : `${Math.round(v)}`
										onMoved: v => Mouse.hudChangeTrigger(root.zone.id, trow.index, { level: Math.round(v) })
									}

									ValueSlider {
										from: 30
										to: 1000
										step: 10
										unit: " ms"
										icon: "timer_outline"
										label: "Every"
										value: Number(trow.trigger.every ?? 150)
										onMoved: v => Mouse.hudChangeTrigger(root.zone.id, trow.index, { every: Math.round(v) })
									}

									// what follows: step by step, each waited for within its time
									Repeater {
										model: Mouse.hudStepsOf(trow.trigger).length

										delegate: Rectangle {
											id: srow

											required property int index

											readonly property var step: Mouse.hudStepsOf(trow.trigger)[srow.index] ?? ({})
											readonly property var when: Mouse.hudSteps.find(k => k.value === srow.step.when) ?? Mouse.hudSteps[0]
											readonly property bool withKey: srow.step.when === "clickAnywhere" || srow.step.when === "clickOutside" || srow.step.when === "clickHere" || srow.step.when === "press"

											Layout.fillWidth: true
											Layout.leftMargin: 10
											implicitHeight: scol.implicitHeight + 16
											radius: Theme.radius.medium
											color: Theme.layer1
											border.width: 1
											border.color: Theme.outline
											opacity: 0
											Component.onCompleted: stepIn.start()

											NumberAnimation {
												id: stepIn

												target: srow
												property: "opacity"
												to: 1
												duration: Motion.medium
											}

											ColumnLayout {
												id: scol

												anchors.left: parent.left
												anchors.right: parent.right
												anchors.top: parent.top
												anchors.margins: 8
												spacing: 6

												RowLayout {
													Layout.fillWidth: true
													spacing: 6

													StyledText {
														text: `then ${srow.index + 1}`
														font.pixelSize: Theme.size.small
														font.weight: Font.DemiBold
														tone: Theme.primary
													}

													Item {
														Layout.fillWidth: true
													}

													IconButton {
														Layout.preferredWidth: 24
														Layout.preferredHeight: 24
														icon: "play"
														onClicked: Mouse.play(srow.step.feel)
													}

													IconButton {
														Layout.preferredWidth: 24
														Layout.preferredHeight: 24
														icon: "close"
														onClicked: Mouse.hudRemoveStep(root.zone.id, trow.index, srow.index)
													}
												}

												Flow {
													Layout.fillWidth: true
													spacing: 4

													Repeater {
														model: Mouse.hudSteps

														delegate: Chip {
															required property var modelData

															text: modelData.label
															selected: srow.step.when === modelData.value
															onClicked: Mouse.hudChangeStep(root.zone.id, trow.index, srow.index, { when: modelData.value })
														}
													}
												}

												Flow {
													Layout.fillWidth: true
													spacing: 4

													Repeater {
														model: root.feels

														delegate: Chip {
															required property var modelData

															text: modelData.label
															selected: srow.step.feel === modelData.value
															onClicked: {
																Mouse.hudChangeStep(root.zone.id, trow.index, srow.index, { feel: modelData.value });
																Mouse.play(modelData.value);
															}
														}
													}
												}

												Flow {
													Layout.fillWidth: true
													visible: srow.withKey
													spacing: 4

													Repeater {
														model: srow.step.when === "press" ? [{ key: "", label: "Any press" }, { key: "BTN_LEFT", label: "Left click" }, { key: "BTN_RIGHT", label: "Right click" }] : [{ key: "", label: "Any button" }, { key: "BTN_LEFT", label: "Left" }, { key: "BTN_RIGHT", label: "Right" }, { key: "BTN_MIDDLE", label: "Middle" }]

														delegate: Chip {
															required property var modelData

															text: modelData.label
															selected: String(srow.step.key ?? "") === modelData.key
															onClicked: Mouse.hudChangeStep(root.zone.id, trow.index, srow.index, { key: modelData.key })
														}
													}
												}

												ValueSlider {
													visible: srow.step.when !== "delay"
													from: 500
													to: 15000
													step: 500
													icon: "timer_outline"
													label: "Within"
													value: Number(srow.step.within ?? 5000)
													format: v => `${(v / 1000).toFixed(1)} s`
													onMoved: v => Mouse.hudChangeStep(root.zone.id, trow.index, srow.index, { within: Math.round(v) })
												}

												ValueSlider {
													visible: srow.step.when === "delay"
													from: 50
													to: 5000
													step: 50
													unit: " ms"
													icon: "timer_outline"
													label: "After"
													value: Number(srow.step.delay ?? 500)
													onMoved: v => Mouse.hudChangeStep(root.zone.id, trow.index, srow.index, { delay: Math.round(v) })
												}
											}
										}
									}

									RowLayout {
										Layout.fillWidth: true
										Layout.leftMargin: 10
										spacing: 6

										Glyph {
											icon: "link_variant"
											size: 13
											color: Theme.textFaint
										}

										StyledText {
											Layout.fillWidth: true
											text: Mouse.hudStepsOf(trow.trigger).length > 0 ? "Then…" : "Then… – a follow-up with a pattern of its own: a click elsewhere, the pointer leaving, a moment later"
											font.pixelSize: Theme.size.small
											tone: Theme.textFaint
											elide: Text.ElideRight
										}

										TextButton {
											text: "Add a step"
											icon: "plus"
											variant: "text"
											onActivated: Mouse.hudAddStep(root.zone.id, trow.index, "clickAnywhere")
										}
									}

									StyledText {
										Layout.fillWidth: true
										text: {
											switch (trow.trigger.kind) {
											case "press": return "The zone changes while a press of yours is fresh – the ammo counter after a shot, the cast bar after a spell.";
											case "click": return "A mouse button goes down while the pointer is in the zone – a spell slot, a button of the HUD. X11 games only (Proton is).";
											case "hover": return "The pointer comes into the zone – once, until it leaves. X11 games only.";
											case "red": return "The zone suddenly reddens – a hit marker, blood, a health bar dropping.";
											case "bright": return "The zone suddenly brightens – a muzzle flash, an icon lighting up.";
											case "dark": return "The zone suddenly darkens – an icon greying out, a charge spent.";
											default: return "The zone changes, whoever caused it – not while the whole picture moves.";
											}
										}
										tone: Theme.textFaint
										font.pixelSize: Theme.size.small
										wrapMode: Text.WordWrap
									}
								}
							}
						}

						StyledText {
							text: "Add a reaction"
							font.pixelSize: Theme.size.small
							tone: Theme.textFaint
						}

						Flow {
							Layout.fillWidth: true
							spacing: 5

							Repeater {
								model: Mouse.hudKinds

								delegate: Chip {
									required property var modelData

									text: modelData.label
									icon: modelData.icon
									onClicked: Mouse.hudAddTrigger(root.zone.id, modelData.value)
								}
							}
						}
					}
				}
			}
		}
	}

	// ── scenes ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "hud-scenes"
		icon: "image_multiple_outline"
		title: "Scenes"
		subtitle: root.scenes.length > 0 ? "A picture of the game for each look of its HUD – a fight, a dialog, exploring. The one that looks like the picture now lights up; only its zones fire." : "A picture of the game for each look of its HUD. Take one, or draw on the screen – a scene is made as you go."

		trailing: RowLayout {
			spacing: 6

			TextButton {
				visible: root.window > 0 && Plugins.on("screenshot")
				text: "Draw on the screen"
				icon: "selection_drag"
				variant: "tonal"
				onActivated: Mouse.hudDraw()
			}

			TextButton {
				visible: root.window > 0
				text: root.shooting ? "Taking…" : (root.picture !== "" ? "New picture" : "Take a picture")
				icon: "camera_outline"
				variant: "text"
				busy: root.shooting
				onActivated: root.shoot()
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: root.scenes

				delegate: Rectangle {
					id: card

					required property var modelData

					readonly property bool chosen: root.sceneId === card.modelData.id
					readonly property bool up: root.liveScene === card.modelData.id
					readonly property real score: Number(root.scores[card.modelData.id] ?? 0)
					readonly property int count: root.allZones.filter(z => z.scene === card.modelData.id).length

					width: 212
					height: 150
					radius: Theme.radius.large
					color: card.chosen ? Theme.primaryContainer : Theme.layer2
					border.width: card.up ? 2 : (card.chosen ? 1.5 : 0)
					border.color: card.up ? Theme.primary : Qt.alpha(Theme.primary, 0.5)
					clip: true
					scale: 1
					Component.onCompleted: cardPop.start()

					Behavior on color {
						ColorAnim {}
					}
					Behavior on border.color {
						ColorAnim {}
					}

					NumberAnimation {
						id: cardPop

						target: card
						property: "scale"
						from: 0.85
						to: 1
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}

					// a breath while it is the scene that is up
					Rectangle {
						anchors.fill: parent
						radius: parent.radius
						color: Theme.primary
						opacity: 0

						SequentialAnimation on opacity {
							running: card.up
							loops: Animation.Infinite
							alwaysRunToEnd: true

							NumberAnimation {
								to: 0.16
								duration: 900
								easing.type: Easing.InOutSine
							}
							NumberAnimation {
								to: 0.04
								duration: 900
								easing.type: Easing.InOutSine
							}
						}
					}

					Clickable {
						anchors.fill: parent
						onClicked: {
							Mouse.hudSceneId = card.modelData.id;
							root.selected = "";
						}

						ColumnLayout {
							anchors.fill: parent
							anchors.margins: 8
							spacing: 6

							Rectangle {
								Layout.fillWidth: true
								Layout.preferredHeight: 86
								radius: Theme.radius.medium
								color: Theme.layer1
								clip: true

								Image {
									anchors.fill: parent
									source: card.modelData.picture ? `file://${card.modelData.picture}?${Mouse.hudPictureRev}` : ""
									fillMode: Image.PreserveAspectCrop
									asynchronous: true
									cache: false
									sourceSize.width: 424
								}

								// how alike the game looks right now
								Rectangle {
									anchors.left: parent.left
									anchors.right: parent.right
									anchors.bottom: parent.bottom
									height: 4
									color: Qt.alpha(Theme.base, 0.5)
									visible: root.watching

									Rectangle {
										width: parent.width * Math.max(0, Math.min(1, card.score))
										height: parent.height
										color: card.up ? Theme.primary : Qt.alpha(Theme.text, 0.6)

										Behavior on width {
											Anim {
												duration: Motion.medium
											}
										}
									}
								}

								Rectangle {
									anchors.right: parent.right
									anchors.top: parent.top
									anchors.margins: 6
									visible: card.up
									width: upText.implicitWidth + 12
									height: 18
									radius: 9
									color: Theme.primary

									StyledText {
										id: upText

										anchors.centerIn: parent
										text: "Up now"
										font.pixelSize: Theme.size.small
										font.weight: Font.DemiBold
										color: Theme.onPrimary
									}
								}
							}

							RowLayout {
								Layout.fillWidth: true
								spacing: 6

								StyledText {
									Layout.fillWidth: true
									text: card.modelData.name
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
									elide: Text.ElideRight
								}

								StyledText {
									text: `${card.count} zone${card.count === 1 ? "" : "s"}${root.watching ? ` · ${Math.round(card.score * 100)} %` : ""}`
									font.pixelSize: Theme.size.small
									tone: Theme.textFaint
								}
							}
						}
					}
				}
			}

			// a new scene
			Rectangle {
				width: 212
				height: 150
				radius: Theme.radius.large
				color: newHover.hovered ? Theme.layer2 : "transparent"
				border.width: 1.5
				border.color: Theme.outline

				Behavior on color {
					ColorAnim {}
				}

				HoverHandler {
					id: newHover
				}

				Clickable {
					anchors.fill: parent
					onClicked: {
						Mouse.hudAddScene("");
						root.selected = "";
					}

					ColumnLayout {
						anchors.centerIn: parent
						spacing: 6

						Glyph {
							Layout.alignment: Qt.AlignHCenter
							icon: "plus"
							size: 22
							color: Theme.textSubtle
						}

						StyledText {
							Layout.alignment: Qt.AlignHCenter
							text: "New scene"
							font.pixelSize: Theme.size.small
							tone: Theme.textSubtle
						}
					}
				}
			}
		}

		// the chosen scene
		RowLayout {
			Layout.fillWidth: true
			visible: !!root.scene
			spacing: 10

			Field {
				Layout.preferredWidth: 260
				placeholder: "Scene name – fight, dialog, exploring"
				icon: "pencil_outline"
				text: root.scene?.name ?? ""
				onEdited: text => {
					if (root.scene && text.trim() !== "") Mouse.hudChangeScene(root.scene.id, { name: text.trim() });
				}
			}

			ValueSlider {
				Layout.fillWidth: true
				from: 20
				to: 90
				step: 5
				unit: " %"
				icon: "fit_to_screen_outline"
				label: "Has to look alike"
				value: Math.round(Number(root.scene?.similar ?? 0.45) * 100)
				onMoved: v => Mouse.hudChangeScene(root.scene.id, { similar: Math.round(v) / 100 })
			}

			TextButton {
				visible: Mouse.hudClipboard.length > 0
				text: "Paste into every zone"
				icon: "content_paste"
				variant: "text"
				onActivated: Mouse.hudPasteIntoScene(root.sceneId, false)
			}

			TextButton {
				text: "Remove scene"
				icon: "delete_outline"
				variant: "text"
				confirm: true
				onActivated: {
					Mouse.hudRemoveScene(root.sceneId);
					root.selected = "";
				}
			}
		}
	}

	// ── the picture ───────────────────────────────────────────────────────
	SettingCard {
		anchor: "hud-picture"
		icon: "crosshairs_gps"
		title: root.scene ? `${root.scene.name} – the zones` : "The zones"
		subtitle: root.boxes.length > 0 ? `${root.boxes.length} boxes found on the picture: one lights up under the cursor, a click takes it. Or drag your own. Drag a zone to move it, pull a corner to resize it.` : "Drag a box over the ammo counter, the health bar, the cast bar, the hit marker. Drag a zone to move it, pull a corner to resize it."

		trailing: RowLayout {
			spacing: 6

			TextButton {
				text: root.guessing ? "Looking…" : (root.suggesting ? "Hide suggestions" : "Suggest zones")
				icon: "auto_fix"
				variant: "text"
				busy: root.guessing
				enabled: root.picture !== ""
				onActivated: {
					if (root.suggesting) {
						root.suggesting = false;
						return;
					}
					root.suggesting = true;
					if (root.guessedFor !== root.picture) root.guess();
				}
			}

			TextButton {
				visible: root.suggesting && root.suggested.length > 0
				text: `Add all ${root.suggested.length}`
				icon: "plus"
				variant: "tonal"
				onActivated: {
					for (const s of root.suggested) Mouse.hudAddZone({ x: s.x, y: s.y, w: s.w, h: s.h }, { name: s.name, when: s.when });
					root.suggesting = false;
				}
			}
		}

		FocusScope {
			id: boardFocus

			Layout.fillWidth: true
			implicitHeight: board.implicitHeight

			Keys.onPressed: event => {
				if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
					if (root.zone) {
						const id = root.zone.id;
						root.selected = "";
						Mouse.hudRemoveZone(id);
					}
					event.accepted = true;
				} else if (event.key === Qt.Key_Escape) {
					root.selected = "";
					event.accepted = true;
				}
			}

			Rectangle {
				id: board

				anchors.left: parent.left
				anchors.right: parent.right
				implicitHeight: Math.round(width * (pictureImage.implicitHeight > 0 && pictureImage.implicitWidth > 0 ? pictureImage.implicitHeight / pictureImage.implicitWidth : 9 / 16))
				radius: Theme.radius.large
				color: Theme.layer2
				clip: true

				Image {
					id: pictureImage

					anchors.fill: parent
					fillMode: Image.PreserveAspectFit
					cache: false
					asynchronous: true
					smooth: true
					onStatusChanged: if (status === Image.Ready && root.guessedFor !== root.picture && root.picture !== "") root.guess()
				}

				ColumnLayout {
					anchors.centerIn: parent
					visible: pictureImage.status !== Image.Ready
					spacing: 8

					Glyph {
						Layout.alignment: Qt.AlignHCenter
						icon: root.shooting ? "camera_outline" : "image_multiple_outline"
						size: 28
						color: Theme.textFaint
					}

					StyledText {
						Layout.alignment: Qt.AlignHCenter
						text: root.window > 0 ? (root.shooting ? "Taking a picture of the game's window…" : "No picture yet – zones can be drawn all the same") : "The game's picture appears here while it runs"
						tone: Theme.textFaint
						font.pixelSize: Theme.size.small
					}
				}

				// live: the picture is watched
				Rectangle {
					anchors.left: parent.left
					anchors.top: parent.top
					anchors.margins: 10
					visible: root.watching
					width: liveRow.implicitWidth + 16
					height: 24
					radius: 12
					color: Qt.alpha(Theme.base, 0.75)
					z: 5

					RowLayout {
						id: liveRow

						anchors.centerIn: parent
						spacing: 6

						Rectangle {
							width: 8
							height: 8
							radius: 4
							color: Theme.primary

							SequentialAnimation on opacity {
								loops: Animation.Infinite
								running: root.watching

								NumberAnimation {
									to: 0.3
									duration: 700
								}
								NumberAnimation {
									to: 1
									duration: 700
								}
							}
						}

						StyledText {
							text: "Live"
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}
					}
				}

				// where the picture actually is
				Item {
					id: canvas

					readonly property real pw: pictureImage.status === Image.Ready ? pictureImage.paintedWidth : board.width
					readonly property real ph: pictureImage.status === Image.Ready ? pictureImage.paintedHeight : board.height

					x: (board.width - canvas.pw) / 2
					y: (board.height - canvas.ph) / 2
					width: canvas.pw
					height: canvas.ph

					MouseArea {
						id: drawer

						property real sx: 0
						property real sy: 0
						property real ex: 0
						property real ey: 0
						readonly property bool drawing: pressed && (Math.abs(ex - sx) >= 4 || Math.abs(ey - sy) >= 4)
						// smart select: the smallest found box under the cursor
						readonly property var snap: containsMouse && !pressed ? root.boxAt(mouseX / Math.max(1, width), mouseY / Math.max(1, height)) : null

						anchors.fill: parent
						cursorShape: Qt.CrossCursor
						hoverEnabled: true
						onPressed: mouse => {
							boardFocus.forceActiveFocus();
							drawer.sx = drawer.ex = Math.max(0, Math.min(width, mouse.x));
							drawer.sy = drawer.ey = Math.max(0, Math.min(height, mouse.y));
						}
						onPositionChanged: mouse => {
							if (!drawer.pressed) return;
							drawer.ex = Math.max(0, Math.min(width, mouse.x));
							drawer.ey = Math.max(0, Math.min(height, mouse.y));
						}
						onReleased: {
							const x0 = Math.min(drawer.sx, drawer.ex), x1 = Math.max(drawer.sx, drawer.ex);
							const y0 = Math.min(drawer.sy, drawer.ey), y1 = Math.max(drawer.sy, drawer.ey);
							if (x1 - x0 < 6 || y1 - y0 < 6) {
								const best = root.boxAt(x0 / Math.max(1, width), y0 / Math.max(1, height));
								if (!best) {
									root.selected = "";
									return;
								}
								root.add({ x: best[0], y: best[1], w: best[2], h: best[3] });
								return;
							}
							root.add({ x: x0 / width, y: y0 / height, w: (x1 - x0) / width, h: (y1 - y0) / height });
						}
					}

					// the found box under the cursor
					Rectangle {
						visible: !!drawer.snap && !drawer.drawing
						x: (drawer.snap?.[0] ?? 0) * canvas.width
						y: (drawer.snap?.[1] ?? 0) * canvas.height
						width: (drawer.snap?.[2] ?? 0) * canvas.width
						height: (drawer.snap?.[3] ?? 0) * canvas.height
						color: Qt.alpha(Theme.primary, 0.14)
						border.width: 1.5
						border.color: Theme.primary
						radius: 3

						Behavior on x {
							Anim {
								duration: Motion.micro
							}
						}
						Behavior on y {
							Anim {
								duration: Motion.micro
							}
						}
						Behavior on width {
							Anim {
								duration: Motion.micro
							}
						}
						Behavior on height {
							Anim {
								duration: Motion.micro
							}
						}
					}

					// the box being drawn
					Rectangle {
						visible: drawer.drawing
						x: Math.min(drawer.sx, drawer.ex)
						y: Math.min(drawer.sy, drawer.ey)
						width: Math.abs(drawer.ex - drawer.sx)
						height: Math.abs(drawer.ey - drawer.sy)
						color: Qt.alpha(Theme.primary, 0.2)
						border.width: 1.5
						border.color: Theme.primary
						radius: 3
					}

					// suggested zones, a click takes one
					Repeater {
						model: root.suggesting ? root.suggested : []

						delegate: Rectangle {
							id: hint

							required property var modelData

							x: hint.modelData.x * canvas.width
							y: hint.modelData.y * canvas.height
							width: Math.max(4, hint.modelData.w * canvas.width)
							height: Math.max(4, hint.modelData.h * canvas.height)
							color: Qt.alpha(Theme.tertiary, hintHover.hovered ? 0.25 : 0.1)
							border.width: 1.5
							border.color: Theme.tertiary
							radius: 3
							opacity: 0
							Component.onCompleted: hintIn.start()

							Behavior on color {
								ColorAnim {}
							}

							NumberAnimation {
								id: hintIn

								target: hint
								property: "opacity"
								to: 1
								duration: Motion.medium
							}

							HoverHandler {
								id: hintHover
							}

							MouseArea {
								anchors.fill: parent
								cursorShape: Qt.PointingHandCursor
								onClicked: {
									root.add({ x: hint.modelData.x, y: hint.modelData.y, w: hint.modelData.w, h: hint.modelData.h }, { name: hint.modelData.name, when: hint.modelData.when });
									root.suggested = root.suggested.filter(s => s !== hint.modelData);
								}
							}

							Rectangle {
								anchors.left: parent.left
								anchors.top: parent.bottom
								anchors.topMargin: 2
								width: hintTag.implicitWidth + 10
								height: 16
								radius: 4
								color: Theme.tertiary

								StyledText {
									id: hintTag

									anchors.centerIn: parent
									text: `${hint.modelData.when === "press" ? "after a press" : "changes"} – take?`
									font.pixelSize: Theme.size.small
									color: Theme.onPrimary
								}
							}
						}
					}

					// the zones: movable, resizable, glowing with what is measured
					Repeater {
						model: root.zones

						delegate: Item {
							id: box

							required property var modelData

							readonly property bool chosen: root.selected === box.modelData.id
							readonly property var values: root.live[box.modelData.id] ?? null
							// how much it is changing now, 0..1
							readonly property real heat: box.values ? Math.max(0, Math.min(1, Math.max(box.values[0], Math.abs(box.values[1]), Math.abs(box.values[2])) / 40)) : 0
							// while moved or resized: the box as it is dragged (fractions)
							property var drag: null
							readonly property real fx: box.drag ? box.drag.x : box.modelData.x
							readonly property real fy: box.drag ? box.drag.y : box.modelData.y
							readonly property real fw: box.drag ? box.drag.w : box.modelData.w
							readonly property real fh: box.drag ? box.drag.h : box.modelData.h

							x: box.fx * canvas.width
							y: box.fy * canvas.height
							width: Math.max(6, box.fw * canvas.width)
							height: Math.max(6, box.fh * canvas.height)
							z: box.chosen ? 3 : 2
							scale: 1
							Component.onCompleted: boxPop.start()

							function commit() {
								if (!box.drag) return;
								const d = box.drag;
								box.drag = null;
								Mouse.hudChangeZone(box.modelData.id, { x: Math.round(d.x * 10000) / 10000, y: Math.round(d.y * 10000) / 10000, w: Math.round(d.w * 10000) / 10000, h: Math.round(d.h * 10000) / 10000 });
							}

							Behavior on x {
								enabled: !box.drag
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on y {
								enabled: !box.drag
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on width {
								enabled: !box.drag
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on height {
								enabled: !box.drag
								SpatialAnim {
									duration: Motion.medium
								}
							}

							NumberAnimation {
								id: boxPop

								target: box
								property: "scale"
								from: 0.7
								to: 1
								duration: Motion.long
								easing.type: Easing.BezierSpline
								easing.bezierCurve: Motion.spatialFast
							}

							Rectangle {
								id: face

								anchors.fill: parent
								radius: 3
								color: root.fired === box.modelData.id ? Qt.alpha(Theme.primary, 0.65) : Qt.alpha(box.chosen ? Theme.primary : Theme.text, (boxHover.hovered ? 0.2 : 0.1) + box.heat * 0.5)
								border.width: box.chosen ? 2 : 1
								border.color: box.chosen ? Theme.primary : Qt.alpha(Theme.text, boxHover.hovered ? 0.95 : 0.7)

								Behavior on color {
									ColorAnim {
										duration: 120
									}
								}

								HoverHandler {
									id: boxHover
								}

								// a pulse ring when it fires
								Rectangle {
									id: ring

									anchors.fill: parent
									radius: 3
									color: "transparent"
									border.width: 2
									border.color: Theme.primary
									opacity: 0
									scale: 1

									Connections {
										target: root

										function onFiredChanged() {
											if (root.fired === box.modelData.id) ringAnim.restart();
										}
									}

									ParallelAnimation {
										id: ringAnim

										NumberAnimation {
											target: ring
											property: "scale"
											from: 1
											to: 1.35
											duration: Motion.extraLong
											easing.type: Easing.OutCubic
										}
										NumberAnimation {
											target: ring
											property: "opacity"
											from: 0.9
											to: 0
											duration: Motion.extraLong
											easing.type: Easing.OutCubic
										}
									}
								}
							}

							// move it
							MouseArea {
								id: mover

								property real px: 0
								property real py: 0
								property bool moved: false

								anchors.fill: parent
								anchors.margins: 6
								cursorShape: box.chosen ? Qt.SizeAllCursor : Qt.PointingHandCursor
								onPressed: mouse => {
									boardFocus.forceActiveFocus();
									mover.px = mouse.x;
									mover.py = mouse.y;
									mover.moved = false;
									root.selected = box.modelData.id;
								}
								onPositionChanged: mouse => {
									if (!mover.pressed) return;
									const dx = (mouse.x - mover.px) / canvas.width, dy = (mouse.y - mover.py) / canvas.height;
									if (!mover.moved && Math.abs(dx) * canvas.width < 3 && Math.abs(dy) * canvas.height < 3) return;
									mover.moved = true;
									const w = box.modelData.w, h = box.modelData.h;
									box.drag = { x: Math.max(0, Math.min(1 - w, box.modelData.x + dx)), y: Math.max(0, Math.min(1 - h, box.modelData.y + dy)), w, h };
								}
								onReleased: box.commit()
							}

							// resize it by a corner
							Repeater {
								model: box.chosen ? [{ h: "l", v: "t" }, { h: "r", v: "t" }, { h: "l", v: "b" }, { h: "r", v: "b" }] : []

								delegate: Rectangle {
									id: handle

									required property var modelData

									width: 12
									height: 12
									radius: 6
									x: (handle.modelData.h === "l" ? 0 : box.width) - 6
									y: (handle.modelData.v === "t" ? 0 : box.height) - 6
									color: Theme.primary
									border.width: 2
									border.color: Theme.base
									scale: handleArea.pressed ? 1.3 : (handleArea.containsMouse ? 1.15 : 1)

									Behavior on scale {
										Anim {
											duration: Motion.micro
										}
									}

									MouseArea {
										id: handleArea

										property real ox: 0
										property real oy: 0

										anchors.fill: parent
										anchors.margins: -6
										hoverEnabled: true
										cursorShape: (handle.modelData.h === "l") === (handle.modelData.v === "t") ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
										onPressed: mouse => {
											const p = handleArea.mapToItem(canvas, mouse.x, mouse.y);
											handleArea.ox = p.x;
											handleArea.oy = p.y;
										}
										onPositionChanged: mouse => {
											if (!handleArea.pressed) return;
											const p = handleArea.mapToItem(canvas, mouse.x, mouse.y);
											const dx = (p.x - handleArea.ox) / canvas.width, dy = (p.y - handleArea.oy) / canvas.height;
											let x0 = box.modelData.x, y0 = box.modelData.y, x1 = x0 + box.modelData.w, y1 = y0 + box.modelData.h;
											if (handle.modelData.h === "l") x0 = Math.max(0, Math.min(x1 - 0.005, x0 + dx));
											else x1 = Math.min(1, Math.max(x0 + 0.005, x1 + dx));
											if (handle.modelData.v === "t") y0 = Math.max(0, Math.min(y1 - 0.005, y0 + dy));
											else y1 = Math.min(1, Math.max(y0 + 0.005, y1 + dy));
											box.drag = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
										}
										onReleased: box.commit()
									}
								}
							}

							// its name, and what it reacts to while chosen
							Rectangle {
								anchors.left: parent.left
								anchors.bottom: parent.top
								anchors.bottomMargin: 3
								width: tagRow.implicitWidth + 12
								height: 20
								radius: 5
								color: box.chosen ? Theme.primary : Qt.alpha(Theme.base, 0.8)

								Behavior on color {
									ColorAnim {}
								}

								RowLayout {
									id: tagRow

									anchors.centerIn: parent
									spacing: 5

									StyledText {
										text: box.modelData.name
										font.pixelSize: Theme.size.small
										font.weight: Font.DemiBold
										color: box.chosen ? Theme.onPrimary : Theme.text
									}

									StyledText {
										visible: box.chosen || boxHover.hovered
										text: root.describe(box.modelData)
										font.pixelSize: Theme.size.small
										color: box.chosen ? Theme.onPrimary : Theme.textSubtle
									}
								}
							}
						}
					}
				}
			}
		}

		// the zones of the scene in a line, a click picks one
		Flow {
			Layout.fillWidth: true
			visible: root.zones.length > 0
			spacing: 6

			Repeater {
				model: root.zones

				delegate: Chip {
					id: zoneChip

					required property var modelData

					text: `${zoneChip.modelData.name} · ${root.describe(zoneChip.modelData)}`
					selected: root.selected === zoneChip.modelData.id
					accent: root.fired === zoneChip.modelData.id ? Theme.tertiary : Theme.primary
					onClicked: root.selected = root.selected === zoneChip.modelData.id ? "" : zoneChip.modelData.id
				}
			}
		}
	}
}
