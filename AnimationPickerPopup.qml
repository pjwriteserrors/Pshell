pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtMultimedia
import Quickshell
import Quickshell.Io
import "components"
import "NiriAnimation.js" as NiriAnimation

Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	// speed-tier indicator dots (fast / medium / accent)
	readonly property color speedHotColor: "#f07f86"
	readonly property color speedWarmColor: "#d7c477"

	property var animationOptions: []
	property string animationStateHint: ""
	property string selectedAnimationId: ""
	property int selectedAnimationIndex: 0
	property real previewProgress: 0

	readonly property string applyScriptPath: `${Quickshell.shellDir}/scripts/apply_niri_animation.sh`
	readonly property string shaderAnimationsDir: "/home/lu/.config/niri/animations/shaders"
	readonly property string nirimationAnimationsDir: "/home/lu/.config/niri/animations/nirimation/animations"
	readonly property string nirimationShowcaseDir: "/home/lu/.config/niri/animations/nirimation/animations/showcase"
	readonly property string animationStatePath: "/home/lu/.local/state/quickshell-theme/current-animation"
	readonly property string shaderCurrentPath: "/home/lu/.config/niri/animations/shaders/.current"
	readonly property color headingColor: Qt.lighter(root.barColor, 1.12)
	readonly property int gridColumns: Math.max(2, Math.min(4, Math.floor((gridViewport.width + gridGap) / 270)))
	readonly property real gridGap: 14
	readonly property real cardWidth: (gridViewport.width - root.gridGap * (root.gridColumns - 1)) / root.gridColumns
	readonly property real cardHeight: 208
	readonly property var currentAnimationOption: {
		for (const option of root.animationOptions) {
			if (String(option.id || "") === root.selectedAnimationId) return option;
		}
		return root.animationOptions.length > 0 ? root.animationOptions[0] : null;
	}

	focus: true

	function setAnimationOptions(raw) {
		root.animationOptions = NiriAnimation.parseOptions(raw);
		root.selectedAnimationId = NiriAnimation.chooseSelectedId(root.animationStateHint, root.animationOptions, "");
		root.syncSelectedIndex();
	}

	function setAnimationState(raw) {
		root.animationStateHint = String(raw || "").trim();
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
		if (next === root.selectedAnimationIndex && root.selectedAnimationId === String(root.animationOptions[next].id || "")) return;
		root.selectedAnimationIndex = next;
		root.selectedAnimationId = String(root.animationOptions[next].id || "");
		previewCycle.restart();
		Qt.callLater(root.ensureSelectedVisible);
	}

	function moveSelection(delta) {
		root.selectAnimationIndex(root.selectedAnimationIndex + delta);
	}

	function ensureSelectedVisible() {
		if (root.animationOptions.length === 0 || root.gridColumns <= 0) return;
		animationGridView.positionViewAtIndex(root.selectedAnimationIndex, GridView.Contain);
	}

	function reloadAnimations() {
		listAnimationOptionsProcess.running = true;
		readAnimationStateProcess.running = true;
	}

	function applyAnimation() {
		if (root.selectedAnimationId === "") return;
		root.closeRequested();
		Quickshell.execDetached(["bash", root.applyScriptPath, "--animation", root.selectedAnimationId]);
	}

	function reset() {
		root.reloadAnimations();
		Qt.callLater(function() {
			root.forceActiveFocus();
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
		const key = `${String(kind || "").toLowerCase()}:${String(name || "").toLowerCase()}`;
		const styles = ({
			"nirimation:bloom": "pop",
			"nirimation:burn-ashes": "burn",
			"nirimation:burn-multicolor": "burn",
			"nirimation:burn": "burn",
			"nirimation:fold-window": "fold",
			"nirimation:glitch": "glitch",
			"nirimation:pixelate": "pixelate",
			"nirimation:pop-drop": "pop",
			"nirimation:ribbons": "ribbons",
			"nirimation:roll-drop": "roll",
			"nirimation:swipe-window": "swipe",
			"nirimation:unravel": "unravel",
			"shader:bounce": "bounce",
			"shader:circle": "circle",
			"shader:colour-distance": "dissolve",
			"shader:crazy-parametric": "warp",
			"shader:crosshatch": "dissolve",
			"shader:crosswarp": "warp",
			"shader:directional-wipe": "wipe",
			"shader:directional": "wipe",
			"shader:dissolve": "dissolve",
			"shader:fade": "fade",
			"shader:fadecolor": "fade",
			"shader:flyeye": "warp",
			"shader:glitch": "glitch",
			"shader:heat-melt": "burn",
			"shader:ink-splash": "dissolve",
			"shader:inkwell-drop": "dissolve",
			"shader:morph": "warp",
			"shader:overexposure": "flash",
			"shader:perlin": "dissolve",
			"shader:pixelate": "pixelate",
			"shader:pixelfade-wave": "pixelate",
			"shader:plasma-flow": "warp",
			"shader:polar-function": "circle",
			"shader:polka-dots-curtain": "squares",
			"shader:randomsquares": "squares",
			"shader:ripple": "ripple",
			"shader:smoke": "dissolve",
			"shader:snap": "snap",
			"shader:soft-warp-fade": "warp",
			"shader:static-fade": "glitch",
			"shader:voronoi-shatter": "dissolve",
			"shader:wave-warp": "warp"
		});
		return styles[key] || "fade";
	}

	Component.onCompleted: root.reset()
	onGridColumnsChanged: Qt.callLater(root.ensureSelectedVisible)
	Keys.onEscapePressed: closeRequested()
	Keys.onReturnPressed: applyAnimation()
	Keys.onEnterPressed: applyAnimation()
	Keys.onLeftPressed: moveSelection(-1)
	Keys.onRightPressed: moveSelection(1)
	Keys.onUpPressed: moveSelection(-root.gridColumns)
	Keys.onDownPressed: moveSelection(root.gridColumns)

	SequentialAnimation on previewProgress {
		id: previewCycle
		running: root.visible
		loops: Animation.Infinite
		NumberAnimation { from: 0; to: 1; duration: ThemeEngine.duration(1500); easing.type: Easing.InOutCubic }
		PauseAnimation { duration: ThemeEngine.duration(280) }
		ScriptAction { script: root.previewProgress = 0 }
		PauseAnimation { duration: ThemeEngine.duration(120) }
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

	ThemedRectangle {
		id: panel
		anchors.centerIn: parent
		width: Math.min(parent.width - 28, 1260)
		height: Math.min(parent.height - 28, 800)
		radius: ThemeEngine.radiusMedium
		color: Qt.alpha(root.secondaryInsetColor, 0.94)
		border.width: 1
		border.color: Qt.alpha(root.barColor, 0.34)

		Column {
			anchors.fill: parent
			anchors.margins: 18
			spacing: 14

			Row {
				width: parent.width
				height: 40
				spacing: 12

				Text {
					width: parent.width - applyButton.width - 12
					height: parent.height
					color: root.headingColor
					font.pixelSize: 22
					font.weight: Font.DemiBold
					verticalAlignment: Text.AlignVCenter
					elide: Text.ElideRight
					text: root.currentAnimationOption ? root.currentAnimationOption.label : "Animation"
				}

				ThemedRectangle {
					id: applyButton
					width: 104
					height: 38
					radius: ThemeEngine.radiusMedium
					color: root.selectedAnimationId === "" ? Qt.alpha(root.secondaryBoxColor, 0.42) : Qt.alpha(root.barColor, 0.28)
					border.width: 1
					border.color: Qt.alpha(root.barColor, 0.52)

					MouseArea {
						anchors.fill: parent
						enabled: root.selectedAnimationId !== ""
						cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
						onClicked: root.applyAnimation()
					}

					Text {
						anchors.centerIn: parent
						color: root.foreground
						font.pixelSize: 12
						font.weight: Font.DemiBold
						text: "Apply"
					}
				}
			}

			Item {
				id: gridViewport
				width: parent.width
				height: parent.height - 54
				clip: true

				GridView {
					id: animationGridView
					anchors.fill: parent
					cellWidth: (width + root.gridGap) / root.gridColumns
					cellHeight: root.cardHeight + root.gridGap
					model: root.animationOptions
					currentIndex: root.selectedAnimationIndex
					cacheBuffer: cellHeight
					reuseItems: true
					boundsBehavior: Flickable.StopAtBounds
					clip: true

					delegate: ThemedRectangle {
								id: card
								required property int index
								required property var modelData

								readonly property bool selected: card.index === root.selectedAnimationIndex
								readonly property string styleName: root.previewStyle(String(modelData.kind || ""), String(modelData.name || ""))
								readonly property string videoPreviewSource: String(modelData.preview || "")
								readonly property bool hasVideoPreview: card.videoPreviewSource !== ""
								readonly property bool inViewport: card.y + card.height >= animationGridView.contentY
									&& card.y <= animationGridView.contentY + animationGridView.height
								readonly property bool previewActive: card.selected && card.inViewport
								readonly property bool videoPreviewActive: card.hasVideoPreview && card.previewActive
								readonly property real p: root.easeOut(card.previewActive ? root.previewProgress : 0.72)
								readonly property real pulse: root.oscillate(card.previewActive ? root.previewProgress : 0.72)
								readonly property color accent: modelData.kind === "shader" ? root.barColor : Qt.lighter(root.barColor, 1.32)

								width: root.cardWidth
								height: root.cardHeight
								radius: ThemeEngine.radiusLarge
								color: Qt.alpha(root.secondaryBoxColor, selected ? 0.78 : 0.5)
								border.width: selected ? 2 : 1
								border.color: Qt.alpha(selected ? root.barColor : root.foreground, selected ? 0.82 : 0.12)
								clip: true

								Behavior on border.color { ColorAnimation { duration: ThemeEngine.duration(140) } }
								Behavior on color { ColorAnimation { duration: ThemeEngine.duration(140) } }

									MouseArea {
										anchors.fill: parent
										hoverEnabled: true
										cursorShape: Qt.PointingHandCursor
										onClicked: {
											root.selectAnimationIndex(card.index);
										}
										onDoubleClicked: root.applyAnimation()
									}

								ThemedRectangle {
									anchors.left: parent.left
									anchors.right: parent.right
									anchors.top: parent.top
									anchors.margins: 10
									height: parent.height - 42
									radius: ThemeEngine.radiusMedium
									color: Qt.alpha(root.background, 0.72)
									border.width: 1
									border.color: Qt.alpha(card.accent, 0.22)
									clip: true

									Item {
										id: previewArea
										anchors.fill: parent
										anchors.margins: 8
										clip: true

										Loader {
											anchors.fill: parent
											active: card.videoPreviewActive
											sourceComponent: Component {
												Item {
													VideoOutput {
														id: previewVideo
														anchors.fill: parent
														fillMode: VideoOutput.PreserveAspectCrop
													}
													MediaPlayer {
														source: card.videoPreviewSource
														videoOutput: previewVideo
														autoPlay: true
														loops: MediaPlayer.Infinite
													}
												}
											}
										}

										Text {
											visible: card.hasVideoPreview && !card.videoPreviewActive
											anchors.centerIn: parent
											color: Qt.alpha(root.foreground, 0.58)
											font.pixelSize: 11
											text: "Select to play real preview"
										}

										ThemedRectangle {
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

											ThemedRectangle {
												id: sampleWindow
												x: card.styleName === "swipe" ? -previewArea.width * (1 - card.p) : 0
												y: card.styleName === "roll" || card.styleName === "pop" ? -18 * (1 - card.p) : (card.styleName === "bounce" ? Math.abs(Math.cos(card.p * Math.PI * 3)) * 26 * (1 - card.p) : 0)
												width: Math.min(previewArea.width - 16, 178)
												height: Math.min(previewArea.height - 14, 94)
												radius: ThemeEngine.radiusMedium
												color: Qt.alpha(root.background, 0.95)
												border.width: 1
												border.color: Qt.alpha(card.accent, 0.5)
												opacity: card.styleName === "fade" ? card.p : (card.styleName === "flash" ? Math.min(1, card.p + 0.25) : 1)
												scale: card.styleName === "pop" ? 0.62 + card.p * 0.38 : (card.styleName === "snap" ? 0.72 + card.p * 0.28 : 1)
												rotation: card.styleName === "roll" ? (1 - card.p) * -18 : (card.styleName === "fold" ? (1 - card.p) * -9 : 0)
												transformOrigin: Item.Center
												clip: true

												ThemedRectangle {
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

															delegate: ThemedRectangle {
																required property int modelData

																width: 6
																height: 6
																radius: ThemeEngine.radiusTiny
																color: modelData === 1 ? root.speedHotColor : modelData === 2 ? root.speedWarmColor : card.accent
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

														delegate: ThemedRectangle {
															required property real modelData

															width: parent.width * modelData
															height: 7
															radius: ThemeEngine.radiusSmall
															color: Qt.alpha(root.foreground, 0.35)
														}
													}
												}

											ThemedRectangle {
												visible: card.previewActive && card.styleName === "flash"
													anchors.fill: parent
													color: Qt.rgba(255, 247, 210, 0.58 * (1 - card.p))
												}

											ThemedRectangle {
												visible: card.previewActive && card.styleName === "fold"
													anchors.right: parent.right
													anchors.top: parent.top
													anchors.bottom: parent.bottom
													width: parent.width * (0.48 * (1 - card.p))
													color: Qt.rgba(0, 0, 0, 0.32)
												}
											}
										}

										Repeater {
											model: card.previewActive && !card.hasVideoPreview && card.styleName === "pixelate" ? 72 : 0

											delegate: ThemedRectangle {
												required property int index

												readonly property int cols: 12
												readonly property int rows: 6
												readonly property real cellW: previewArea.width / cols
												readonly property real cellH: previewArea.height / rows

												x: (index % cols) * cellW
												y: Math.floor(index / cols) * cellH
												width: cellW + 1
												height: cellH + 1
												color: Qt.alpha(index % 3 === 0 ? card.accent : root.foreground, 0.36 * (1 - card.p))
												visible: card.p < 0.92
											}
										}

										Repeater {
											model: card.previewActive && !card.hasVideoPreview && (card.styleName === "squares" || card.styleName === "snap") ? 48 : 0

											delegate: ThemedRectangle {
												required property int index

												readonly property int cols: 8
												readonly property int rows: 6
												readonly property real threshold: ((index * 37) % 48) / 48

												x: (index % cols) * previewArea.width / cols
												y: Math.floor(index / cols) * previewArea.height / rows
												width: previewArea.width / cols - 2
												height: previewArea.height / rows - 2
												radius: ThemeEngine.radiusTiny
												color: Qt.alpha(card.accent, 0.48)
												visible: card.p < threshold
											}
										}

										Repeater {
											model: card.previewActive && !card.hasVideoPreview && card.styleName === "glitch" ? 7 : 0

											delegate: ThemedRectangle {
												required property int index

												x: ((index % 2) ? -1 : 1) * (1 - card.p) * (10 + index * 3)
												y: 12 + index * 12
												width: previewArea.width
												height: 5 + (index % 3)
												color: index % 3 === 0 ? Qt.rgba(1, 0.2, 0.26, 0.45) : index % 3 === 1 ? Qt.rgba(0.2, 0.85, 1, 0.38) : Qt.alpha(root.foreground, 0.28)
												visible: card.p < 0.88
											}
										}

										Repeater {
											model: card.previewActive && !card.hasVideoPreview && card.styleName === "ribbons" ? 7 : 0

											delegate: ThemedRectangle {
												required property int index

												x: -previewArea.width * 0.2 + card.p * previewArea.width * 1.15 + index * 12
												y: index * previewArea.height / 8
												width: previewArea.width * 0.55
												height: 7
												radius: ThemeEngine.radiusSmall
												rotation: -18
												color: Qt.alpha(index % 2 ? card.accent : root.foreground, 0.46)
											}
										}

										Repeater {
											model: card.previewActive && !card.hasVideoPreview && card.styleName === "unravel" ? 8 : 0

											delegate: ThemedRectangle {
												required property int index

												x: index * previewArea.width / 8
												y: 0
												width: previewArea.width / 8 - 2
												height: previewArea.height * (1 - card.p)
												color: Qt.alpha(root.background, 0.82)
											}
										}

									ThemedRectangle {
										visible: card.previewActive && !card.hasVideoPreview && card.styleName === "circle"
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
											model: card.previewActive && !card.hasVideoPreview && (card.styleName === "dissolve" || card.styleName === "burn") ? 30 : 0

											delegate: ThemedRectangle {
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
											model: card.previewActive && !card.hasVideoPreview && (card.styleName === "ripple" || card.styleName === "warp") ? 4 : 0

											delegate: ThemedRectangle {
												required property int index

												x: previewArea.width / 2 - width / 2
												y: previewArea.height / 2 - height / 2
												width: 32 + ((card.p + index * 0.18) % 1) * previewArea.width * 1.25
												height: width * 0.58
												radius: ThemeEngine.radiusMedium
												rotation: card.styleName === "warp" ? 18 + index * 16 : 0
												color: "transparent"
												border.width: 2
												border.color: Qt.alpha(card.accent, 0.45 * (1 - ((card.p + index * 0.18) % 1)))
											}
										}
									}
								}

								ThemedRectangle {
									anchors.left: parent.left
									anchors.right: parent.right
									anchors.bottom: parent.bottom
									height: 34
									color: Qt.alpha(root.background, 0.46)

									Text {
										anchors.left: parent.left
										anchors.right: kindPill.left
										anchors.leftMargin: 10
										anchors.rightMargin: 8
										anchors.verticalCenter: parent.verticalCenter
										color: root.foreground
										font.pixelSize: 12
										font.weight: card.selected ? Font.DemiBold : Font.Medium
										elide: Text.ElideRight
										text: String(card.modelData.name || "")
									}

									ThemedRectangle {
										id: kindPill
										anchors.right: parent.right
										anchors.rightMargin: 9
										anchors.verticalCenter: parent.verticalCenter
										width: 58
										height: 20
										radius: ThemeEngine.radiusMedium
										color: Qt.alpha(card.accent, 0.24)
										border.width: 1
										border.color: Qt.alpha(card.accent, 0.34)

										Text {
											anchors.centerIn: parent
											color: root.foreground
											font.pixelSize: 9
											font.weight: Font.DemiBold
											text: String(card.modelData.kind || "")
										}
									}
								}
							}

					ScrollBar.vertical: ScrollBar {
						policy: ScrollBar.AsNeeded
					}
				}
			}
		}
	}
}
