pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.overlays.studio
import "../../lib/NiriAnimation.js" as NiriAnimation

// Window animation picker for niri. The stage plays the selected animation
// itself: the shader niri would run, on its real timing (AnimationStage). Arrows
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

	readonly property string applyScriptPath: `${Quickshell.shellDir}/scripts/apply_niri_animation.sh`
	readonly property string shaderAnimationsDir: `${Quickshell.env("HOME")}/.config/niri/animations/shaders`
	readonly property string nirimationAnimationsDir: `${Quickshell.env("HOME")}/.config/niri/animations/nirimation/animations`
	readonly property string animationStatePath: `${Quickshell.env("HOME")}/.local/state/quickshell-theme/current-animation`
	readonly property string shaderCurrentPath: `${root.shaderAnimationsDir}/.current`
	readonly property int gridColumns: Math.max(2, Math.min(6, Math.floor((gridViewport.width + gridGap) / 190)))
	readonly property real gridGap: 12
	readonly property real cardWidth: (gridViewport.width - root.gridGap * (root.gridColumns - 1)) / root.gridColumns
	readonly property real cardHeight: 56
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

	onGridColumnsChanged: Qt.callLater(root.ensureSelectedVisible)

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
		printf 'nirimation:%s\\n' "$(basename "$file" .kdl)"
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

			RowLayout {
				Layout.fillWidth: true
				Layout.fillHeight: true
				spacing: 16

				// The selected animation, played for real (see AnimationStage).
				Rectangle {
					Layout.fillWidth: true
					Layout.fillHeight: true
					Layout.preferredWidth: 1
					radius: Theme.radius.huge
					color: Theme.layer1
					clip: true

					AnimationStage {
						id: motionStage

						anchors.fill: parent
						anchors.topMargin: 44
						anchors.bottomMargin: 92
						anchors.leftMargin: 24
						anchors.rightMargin: 24
						animationId: root.selectedAnimationId
						playing: root.shown
					}

					StyledText {
						x: 24
						y: 20
						text: motionStage.building ? "building…" : motionStage.buildError
						tone: motionStage.buildError !== "" && !motionStage.building ? Theme.danger : Theme.textSubtle
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.tiny
					}

					StyledText {
						x: 24
						width: parent.width - 48
						anchors.bottom: timings.top
						anchors.bottomMargin: 8
						text: root.currentAnimationOption ? String(root.currentAnimationOption.name || "") : ""
						font.pixelSize: Theme.size.display
						font.weight: Font.DemiBold
						elide: Text.ElideRight
					}

					Row {
						id: timings

						x: 24
						anchors.bottom: parent.bottom
						anchors.bottomMargin: 22
						spacing: 28

						Repeater {
							model: [
								{ label: "open", phases: ["opening", "open"], timing: motionStage.openTiming },
								{ label: "close", phases: ["closing", "closed"], timing: motionStage.closeTiming }
							]

							delegate: Column {
								required property var modelData

								opacity: modelData.phases.includes(motionStage.phase) ? 1 : 0.45

								StyledText {
									text: modelData.label
									font.pixelSize: Theme.size.label
									font.weight: Font.DemiBold
								}

								StyledText {
									text: motionStage.timingLabel(modelData.timing)
									tone: Theme.textMuted
									font.family: Theme.monoFamily
									font.pixelSize: Theme.size.tiny
								}

								Behavior on opacity {
									Anim {}
								}
							}
						}
					}
				}

				Item {
					id: gridViewport

					Layout.fillWidth: true
					Layout.preferredWidth: 1
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


										RowLayout {
											anchors.left: parent.left
											anchors.right: parent.right
											anchors.verticalCenter: parent.verticalCenter
											anchors.leftMargin: 14
											anchors.rightMargin: 12
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
