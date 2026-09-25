pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.overlays.studio
import "../../lib/NiriAnimation.js" as NiriAnimation

// Window animation picker for niri. Every card plays a looping sketch of its
// animation (or the recorded showcase clip for nirimation presets). Arrows
// move, Enter applies; clicking a selected card applies it.
ModalWindow {
	id: root

	modalId: "animation"
	exclusiveKeyboard: true
	onModalOpened: root.reset()

	property string appliedAnimationId: ""
	property var animationOptions: []
	property string animationStateHint: ""
	property string selectedAnimationId: ""
	property int selectedAnimationIndex: 0
	property real previewProgress: 0

	readonly property string applyScriptPath: `${Quickshell.shellDir}/scripts/apply_niri_animation.sh`
	readonly property string shaderAnimationsDir: `${Quickshell.env("HOME")}/.config/niri/animations/shaders`
	readonly property string nirimationAnimationsDir: `${Quickshell.env("HOME")}/.config/niri/animations/nirimation/animations`
	readonly property string nirimationShowcaseDir: `${root.nirimationAnimationsDir}/showcase`
	readonly property string animationStatePath: `${Quickshell.env("HOME")}/.local/state/quickshell-theme/current-animation`
	readonly property string shaderCurrentPath: `${root.shaderAnimationsDir}/.current`
	readonly property int gridColumns: Math.max(2, Math.min(6, Math.floor((gridViewport.width + gridGap) / 250)))
	readonly property real gridGap: 12
	readonly property real cardWidth: (gridViewport.width - root.gridGap * (root.gridColumns - 1)) / root.gridColumns
	readonly property real cardHeight: 204
	readonly property var currentAnimationOption: {
		for (const option of root.animationOptions) {
			if (String(option.id || "") === root.selectedAnimationId) return option;
		}
		return root.animationOptions.length > 0 ? root.animationOptions[0] : null;
	}


	function setAnimationOptions(raw) {
		root.animationOptions = NiriAnimation.parseOptions(raw);
		root.appliedAnimationId = root.animationStateHint !== "" ? NiriAnimation.chooseSelectedId(root.animationStateHint, root.animationOptions, "") : "";
		root.selectedAnimationId = NiriAnimation.chooseSelectedId(root.animationStateHint, root.animationOptions, "");
		root.syncSelectedIndex();
	}

	function setAnimationState(raw) {
		root.animationStateHint = String(raw || "").trim();
		root.appliedAnimationId = root.animationStateHint !== "" ? NiriAnimation.chooseSelectedId(root.animationStateHint, root.animationOptions, "") : "";
		root.selectedAnimationId = NiriAnimation.chooseSelectedId(root.animationStateHint, root.animationOptions, "");
		root.syncSelectedIndex();
	}

	function syncSelectedIndex() {
		let index = -1;
		for (let i = 0; i < root.animationOptions.length; i += 1) {
			if (String(root.animationOptions[i].id || "") === root.selectedAnimationId) {
				index = i;
				break;
			}
		}
		root.selectedAnimationIndex = Math.max(0, index);
		if (index < 0 && root.animationOptions.length > 0)
			root.selectedAnimationId = String(root.animationOptions[0].id || "");
		Qt.callLater(root.ensureSelectedVisible);
	}

	function selectAnimationIndex(index) {
		if (root.animationOptions.length === 0) return;
		const next = Math.max(0, Math.min(root.animationOptions.length - 1, index));
		root.selectedAnimationIndex = next;
		root.selectedAnimationId = String(root.animationOptions[next].id || "");
		Qt.callLater(root.ensureSelectedVisible);
	}

	function moveSelection(delta) {
		root.selectAnimationIndex(root.selectedAnimationIndex + delta);
	}

	function ensureSelectedVisible() {
		if (root.animationOptions.length === 0 || root.gridColumns <= 0) return;
		const row = Math.floor(root.selectedAnimationIndex / root.gridColumns);
		const itemTop = row * (root.cardHeight + root.gridGap);
		const itemBottom = itemTop + root.cardHeight;
		if (itemTop < gridFlickable.contentY) {
			gridFlickable.contentY = itemTop;
		} else if (itemBottom > gridFlickable.contentY + gridFlickable.height) {
			gridFlickable.contentY = Math.max(0, itemBottom - gridFlickable.height);
		}
	}

	function reloadAnimations() {
		listAnimationOptionsProcess.running = true;
		readAnimationStateProcess.running = true;
	}

	function applyAnimation() {
		if (root.selectedAnimationId === "") return;
		Popups.closeModal();
		Quickshell.execDetached(["bash", root.applyScriptPath, "--animation", root.selectedAnimationId]);
	}

	function reset() {
		root.reloadAnimations();
		Qt.callLater(function() {
			keyTarget.forceActiveFocus();
		});
	}

	function easeOut(value) {
		const v = Math.max(0, Math.min(1, value));
		return 1 - Math.pow(1 - v, 3);
	}

	function oscillate(value) {
		return 0.5 - Math.cos(value * Math.PI * 2) * 0.5;
	}

	function previewStyle(kind, name) {
		const n = String(name || "").toLowerCase();
		if (kind === "nirimation") {
			if (n.includes("fold")) return "fold";
			if (n.includes("roll")) return "roll";
			if (n.includes("pop")) return "pop";
			if (n.includes("swipe")) return "swipe";
			if (n.includes("unravel")) return "unravel";
			if (n.includes("ribbon")) return "ribbons";
			if (n.includes("burn")) return "burn";
		}
		if (n.includes("bounce")) return "bounce";
		if (n.includes("pixel")) return "pixelate";
		if (n.includes("glitch") || n.includes("static") || n.includes("colour") || n.includes("color")) return "glitch";
		if (n.includes("burn") || n.includes("heat")) return "burn";
		if (n.includes("circle") || n.includes("polar")) return "circle";
		if (n.includes("random") || n.includes("square") || n.includes("polka")) return "squares";
		if (n.includes("ripple") || n.includes("wave")) return "ripple";
		if (n.includes("wipe") || n === "directional" || n.includes("directional")) return "wipe";
		if (n.includes("ink") || n.includes("smoke") || n.includes("dissolve") || n.includes("perlin") || n.includes("plasma") || n.includes("voronoi")) return "dissolve";
		if (n.includes("cross") || n.includes("warp") || n.includes("morph") || n.includes("flyeye") || n.includes("crazy")) return "warp";
		if (n.includes("snap")) return "snap";
		if (n.includes("overexposure")) return "flash";
		if (n.includes("fade")) return "fade";
		return "fade";
	}

	onGridColumnsChanged: Qt.callLater(root.ensureSelectedVisible)

	SequentialAnimation on previewProgress {
		running: root.visible
		loops: Animation.Infinite
		NumberAnimation { from: 0; to: 1; duration: 1500; easing.type: Easing.InOutCubic }
		PauseAnimation { duration: 280 }
		ScriptAction { script: root.previewProgress = 0 }
		PauseAnimation { duration: 120 }
	}

	Process {
		id: listAnimationOptionsProcess
		command: ["sh", "-lc", `
{
	for dir in "${root.shaderAnimationsDir}"/*; do
		[ -d "$dir" ] || continue
		[ -f "$dir/open.glsl" ] || continue
		[ -f "$dir/close.glsl" ] || continue
		printf 'shader:%s\\n' "$(basename "$dir")"
	done
	for file in "${root.nirimationAnimationsDir}"/*.kdl; do
		[ -f "$file" ] || continue
		name="$(basename "$file" .kdl)"
		showcase="${root.nirimationShowcaseDir}/$name.mp4"
		if [ -f "$showcase" ]; then
			printf 'nirimation:%s\\tfile://%s\\n' "$name" "$showcase"
		else
			printf 'nirimation:%s\\n' "$name"
		fi
	done
} | sort
`]
		stdout: StdioCollector {
			onStreamFinished: root.setAnimationOptions(text)
		}
	}

	Process {
		id: readAnimationStateProcess
		command: ["sh", "-lc", `
if [ -f "${root.animationStatePath}" ]; then
	cat "${root.animationStatePath}"
elif [ -f "${root.shaderCurrentPath}" ]; then
	printf 'shader:%s\\n' "$(sed -n '1p' "${root.shaderCurrentPath}")"
fi
`]
		stdout: StdioCollector {
			onStreamFinished: root.setAnimationState(text)
		}
	}
	component KeyHint: RowLayout {
		id: hint

		property string keys: ""
		property string label: ""

		spacing: 5

		Rectangle {
			Layout.preferredHeight: 20
			Layout.preferredWidth: Math.max(22, keyText.implicitWidth + 10)
			radius: 6
			color: Theme.layer2

			StyledText {
				id: keyText
				anchors.centerIn: parent
				text: hint.keys
				font.pixelSize: Theme.size.tiny
				font.weight: Font.Bold
			}
		}

		StyledText {
			text: hint.label
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}
	}

	StudioTabs {}

	Rectangle {
		id: panel

		anchors.centerIn: parent
		anchors.verticalCenterOffset: 25
		width: Math.min(1400, root.width - 120)
		height: Math.min(860, root.height - 170)
		radius: Theme.radius.huge + 6
		color: Theme.base

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		Item {
			id: keyTarget

			anchors.fill: parent
			focus: true

			Keys.onEscapePressed: Popups.closeModal()
			Keys.onReturnPressed: root.applyAnimation()
			Keys.onEnterPressed: root.applyAnimation()
			Keys.onLeftPressed: root.moveSelection(-1)
			Keys.onRightPressed: root.moveSelection(1)
			Keys.onUpPressed: root.moveSelection(-root.gridColumns)
			Keys.onDownPressed: root.moveSelection(root.gridColumns)
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 22
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
						icon: "animation_play"
						size: 22
						color: Theme.primary
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					SectionLabel {
						text: "Window animation"
					}

					StyledText {
						Layout.fillWidth: true
						text: root.currentAnimationOption ? root.currentAnimationOption.label : (listAnimationOptionsProcess.running ? "Loading animations…" : "No animations installed")
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}
				}

				StyledText {
					text: `${root.animationOptions.length} presets`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}

				TextButton {
					implicitHeight: 42
					text: root.selectedAnimationId !== "" && root.selectedAnimationId === root.appliedAnimationId ? "Active" : "Apply"
					icon: "check"
					variant: "filled"
					enabled: root.selectedAnimationId !== ""
					onActivated: root.applyAnimation()
				}

				IconButton {
					icon: "close"
					variant: "tonal"
					onClicked: Popups.closeModal()
				}
			}

			Item {
				id: gridViewport

				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true

				EmptyState {
					anchors.centerIn: parent
					visible: root.animationOptions.length === 0
					icon: "animation"
					title: "No animations found"
					subtitle: "Add shaders to ~/.config/niri/animations/shaders or nirimation presets."
				}

				Flickable {
					id: gridFlickable

					anchors.fill: parent
					contentWidth: width
					contentHeight: animationGrid.height + 16
					boundsBehavior: Flickable.StopAtBounds
					clip: true
					ScrollBar.vertical: ThinScrollBar {}

					Behavior on contentY {
						enabled: !gridFlickable.moving
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Grid {
						id: animationGrid

						y: 8
						width: gridFlickable.width
						columns: root.gridColumns
						columnSpacing: root.gridGap
						rowSpacing: root.gridGap

						Repeater {
							model: root.animationOptions

							delegate: Item {
								id: card

								required property int index
								required property var modelData

								readonly property bool selected: card.index === root.selectedAnimationIndex
								readonly property bool applied: String(card.modelData.id || "") === root.appliedAnimationId
								readonly property string styleName: root.previewStyle(String(modelData.kind || ""), String(modelData.name || ""))
								readonly property string videoPreviewSource: String(modelData.preview || "")
								readonly property bool hasVideoPreview: card.videoPreviewSource !== ""
								readonly property bool videoPreviewActive: card.hasVideoPreview && root.shown
									&& card.y + card.height >= gridFlickable.contentY - root.gridGap
									&& card.y <= gridFlickable.contentY + gridFlickable.height + root.gridGap
								readonly property real p: root.easeOut(root.previewProgress)
								readonly property real pulse: root.oscillate(root.previewProgress)
								readonly property color accent: modelData.kind === "shader" ? Theme.primary : Theme.secondary

								width: root.cardWidth
								height: root.cardHeight

								RectangularShadow {
									anchors.fill: surface
									radius: surface.radius
									blur: 26
									spread: -2
									offset.y: 10
									color: Theme.shadow
									opacity: card.selected ? 0.9 : 0
									transform: Translate {
										y: card.selected ? -6 : 0
									}

									Behavior on opacity {
										Anim {}
									}
								}

								Rectangle {
									id: surface

									width: parent.width
									height: parent.height
									radius: Theme.radius.huge
									color: card.selected ? Theme.layer2 : Theme.layer1
									border.width: card.selected ? 2 : 0
									border.color: Theme.primary
									scale: cardMouse.pressed ? 0.97 : (cardMouse.containsMouse && !card.selected ? 1.015 : 1)
									transform: Translate {
										y: card.selected ? -6 : 0

										Behavior on y {
											SpatialAnim {
												duration: Motion.medium
											}
										}
									}

									Behavior on color {
										ColorAnim {}
									}
									Behavior on scale {
										SpatialAnim {
											duration: Motion.short
										}
									}

									Rectangle {
										anchors.left: parent.left
										anchors.right: parent.right
										anchors.top: parent.top
										anchors.margins: 10
										height: parent.height - 58
										radius: Theme.radius.large
										color: Qt.alpha(Theme.bg, 0.8)
										clip: true

										Item {
											id: previewArea
											anchors.fill: parent
											anchors.margins: 8
											clip: true

											VideoOutput {
												id: previewVideo
												anchors.fill: parent
												fillMode: VideoOutput.PreserveAspectCrop
												visible: card.videoPreviewActive
											}

											MediaPlayer {
												source: card.videoPreviewActive ? card.videoPreviewSource : ""
												videoOutput: previewVideo
												autoPlay: card.videoPreviewActive
												loops: MediaPlayer.Infinite
											}

											Rectangle {
												id: shadowWindow
												visible: !card.hasVideoPreview && sampleWindow.opacity > 0.08
												x: sampleWindow.x + 5
												y: sampleWindow.y + 7
												width: sampleWindow.width
												height: sampleWindow.height
												radius: sampleWindow.radius
												color: Qt.rgba(0, 0, 0, 0.25)
												opacity: sampleWindow.opacity
											}

											Item {
												id: revealClip
												visible: !card.hasVideoPreview
												x: sampleWindow.x
												y: sampleWindow.y
												width: card.styleName === "wipe" ? sampleWindow.width * card.p : sampleWindow.width
												height: sampleWindow.height
												clip: card.styleName === "wipe"

												Rectangle {
													id: sampleWindow
													x: card.styleName === "swipe" ? -previewArea.width * (1 - card.p) : 0
													y: card.styleName === "roll" || card.styleName === "pop" ? -18 * (1 - card.p) : (card.styleName === "bounce" ? Math.abs(Math.cos(card.p * Math.PI * 3)) * 26 * (1 - card.p) : 0)
													width: Math.min(previewArea.width - 16, 178)
													height: Math.min(previewArea.height - 14, 94)
													radius: 7
													color: Qt.alpha(Theme.bg, 0.95)
													border.width: 1
													border.color: Qt.alpha(card.accent, 0.5)
													opacity: card.styleName === "fade" ? card.p : (card.styleName === "flash" ? Math.min(1, card.p + 0.25) : 1)
													scale: card.styleName === "pop" ? 0.62 + card.p * 0.38 : (card.styleName === "snap" ? 0.72 + card.p * 0.28 : 1)
													rotation: card.styleName === "roll" ? (1 - card.p) * -18 : (card.styleName === "fold" ? (1 - card.p) * -9 : 0)
													transformOrigin: Item.Center
													clip: true

													Rectangle {
														anchors.left: parent.left
														anchors.right: parent.right
														anchors.top: parent.top
														height: 18
														color: Qt.alpha(card.accent, 0.18)

														Row {
															anchors.left: parent.left
															anchors.leftMargin: 8
															anchors.verticalCenter: parent.verticalCenter
															spacing: 5

															Repeater {
																model: [1, 2, 3]

																delegate: Rectangle {
																	required property int modelData

																	width: 6
																	height: 6
																	radius: 3
																	color: modelData === 1 ? Theme.danger : modelData === 2 ? Theme.warning : card.accent
																}
															}
														}
													}

													Column {
														anchors.left: parent.left
														anchors.right: parent.right
														anchors.top: parent.top
														anchors.topMargin: 28
														anchors.margins: 12
														spacing: 8

														Repeater {
															model: [0.62, 0.86, 0.48, 0.76]

															delegate: Rectangle {
																required property real modelData

																width: parent.width * modelData
																height: 7
																radius: 4
																color: Qt.alpha(Theme.text, 0.35)
															}
														}
													}

													Rectangle {
														visible: card.styleName === "flash"
														anchors.fill: parent
														color: Qt.rgba(255, 247, 210, 0.58 * (1 - card.p))
													}

													Rectangle {
														visible: card.styleName === "fold"
														anchors.right: parent.right
														anchors.top: parent.top
														anchors.bottom: parent.bottom
														width: parent.width * (0.48 * (1 - card.p))
														color: Qt.rgba(0, 0, 0, 0.32)
													}
												}
											}

											Repeater {
												model: !card.hasVideoPreview && card.styleName === "pixelate" ? 72 : 0

												delegate: Rectangle {
													required property int index

													readonly property int cols: 12
													readonly property int rows: 6
													readonly property real cellW: previewArea.width / cols
													readonly property real cellH: previewArea.height / rows

													x: (index % cols) * cellW
													y: Math.floor(index / cols) * cellH
													width: cellW + 1
													height: cellH + 1
													color: Qt.alpha(index % 3 === 0 ? card.accent : Theme.text, 0.36 * (1 - card.p))
													visible: card.p < 0.92
												}
											}

											Repeater {
												model: !card.hasVideoPreview && (card.styleName === "squares" || card.styleName === "snap") ? 48 : 0

												delegate: Rectangle {
													required property int index

													readonly property int cols: 8
													readonly property int rows: 6
													readonly property real threshold: ((index * 37) % 48) / 48

													x: (index % cols) * previewArea.width / cols
													y: Math.floor(index / cols) * previewArea.height / rows
													width: previewArea.width / cols - 2
													height: previewArea.height / rows - 2
													radius: 2
													color: Qt.alpha(card.accent, 0.48)
													visible: card.p < threshold
												}
											}

											Repeater {
												model: !card.hasVideoPreview && card.styleName === "glitch" ? 7 : 0

												delegate: Rectangle {
													required property int index

													x: ((index % 2) ? -1 : 1) * (1 - card.p) * (10 + index * 3)
													y: 12 + index * 12
													width: previewArea.width
													height: 5 + (index % 3)
													color: index % 3 === 0 ? Qt.rgba(1, 0.2, 0.26, 0.45) : index % 3 === 1 ? Qt.rgba(0.2, 0.85, 1, 0.38) : Qt.alpha(Theme.text, 0.28)
													visible: card.p < 0.88
												}
											}

											Repeater {
												model: !card.hasVideoPreview && card.styleName === "ribbons" ? 7 : 0

												delegate: Rectangle {
													required property int index

													x: -previewArea.width * 0.2 + card.p * previewArea.width * 1.15 + index * 12
													y: index * previewArea.height / 8
													width: previewArea.width * 0.55
													height: 7
													radius: 4
													rotation: -18
													color: Qt.alpha(index % 2 ? card.accent : Theme.text, 0.46)
												}
											}

											Repeater {
												model: !card.hasVideoPreview && card.styleName === "unravel" ? 8 : 0

												delegate: Rectangle {
													required property int index

													x: index * previewArea.width / 8
													y: 0
													width: previewArea.width / 8 - 2
													height: previewArea.height * (1 - card.p)
													color: Qt.alpha(Theme.bg, 0.82)
												}
											}

											Rectangle {
												visible: !card.hasVideoPreview && card.styleName === "circle"
												x: previewArea.width / 2 - width / 2
												y: previewArea.height / 2 - height / 2
												width: 24 + card.p * Math.max(previewArea.width, previewArea.height) * 1.6
												height: width
												radius: width / 2
												color: "transparent"
												border.width: Math.max(2, 9 * (1 - card.p))
												border.color: Qt.alpha(card.accent, 0.68)
											}

											Repeater {
												model: !card.hasVideoPreview && (card.styleName === "dissolve" || card.styleName === "burn") ? 30 : 0

												delegate: Rectangle {
													required property int index

													readonly property real seedX: ((index * 29) % 100) / 100
													readonly property real seedY: ((index * 53) % 100) / 100
													readonly property real sizeSeed: 4 + ((index * 17) % 9)

													x: seedX * previewArea.width
													y: seedY * previewArea.height - (card.styleName === "burn" ? card.p * 34 : card.p * 16)
													width: sizeSeed
													height: sizeSeed
													radius: sizeSeed / 2
													color: card.styleName === "burn" ? Qt.rgba(1, 0.42, 0.14, 0.72 * (1 - card.p)) : Qt.alpha(card.accent, 0.5 * (1 - card.p))
													visible: card.p < seedY + 0.26
												}
											}

											Repeater {
												model: !card.hasVideoPreview && (card.styleName === "ripple" || card.styleName === "warp") ? 4 : 0

												delegate: Rectangle {
													required property int index

													x: previewArea.width / 2 - width / 2
													y: previewArea.height / 2 - height / 2
													width: 32 + ((card.p + index * 0.18) % 1) * previewArea.width * 1.25
													height: width * 0.58
													radius: 7
													rotation: card.styleName === "warp" ? 18 + index * 16 : 0
													color: "transparent"
													border.width: 2
													border.color: Qt.alpha(card.accent, 0.45 * (1 - ((card.p + index * 0.18) % 1)))
												}
											}						}

									}

									RowLayout {
										anchors.left: parent.left
										anchors.right: parent.right
										anchors.bottom: parent.bottom
										anchors.leftMargin: 14
										anchors.rightMargin: 12
										anchors.bottomMargin: 12
										spacing: 8

										Rectangle {
											visible: card.applied
											Layout.preferredWidth: 8
											Layout.preferredHeight: 8
											radius: 4
											color: Theme.success
										}

										StyledText {
											Layout.fillWidth: true
											text: String(card.modelData.name || "")
											font.pixelSize: Theme.size.label
											font.weight: card.selected ? Font.Bold : Font.DemiBold
										}

										Rectangle {
											Layout.preferredHeight: 20
											Layout.preferredWidth: kindLabel.implicitWidth + 14
											radius: 10
											color: Qt.alpha(card.accent, 0.18)

											StyledText {
												id: kindLabel

												anchors.centerIn: parent
												text: String(card.modelData.kind || "")
												tone: card.accent
												font.pixelSize: Theme.size.tiny
												font.weight: Font.Bold
											}
										}
									}
								}

								MouseArea {
									id: cardMouse

									anchors.fill: parent
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onClicked: {
										if (card.selected) {
											root.applyAnimation();
											return;
										}
										root.selectAnimationIndex(card.index);
									}
								}
							}
						}
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 14

				KeyHint { keys: "←→↑↓"; label: "choose" }
				KeyHint { keys: "↵"; label: "apply" }
				KeyHint { keys: "click ×2"; label: "apply" }
				KeyHint { keys: "Esc"; label: "close" }

				Item {
					Layout.fillWidth: true
				}

				RowLayout {
					spacing: 6
					Rectangle {
						Layout.preferredWidth: 8
						Layout.preferredHeight: 8
						radius: 4
						color: Theme.success
					}
					StyledText {
						text: "currently active"
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}
			}
		}
	}
}
