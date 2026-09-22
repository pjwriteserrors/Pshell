pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"
import "NiriAnimation.js" as NiriAnimation

// Studio's motion page: what a window does when it opens and when it closes.
//
// The page shows the animation, not a likeness of it. The stage runs the one
// the grid is pointing at - the same shader niri would load, over the same
// duration, on the same curve or the same spring - on a mock window, on a
// loop, until another card is picked. Nothing is applied until Apply.
//
// It used to be a wall of cards, each drawing a hand-made impression of what
// its animation might look like. Those impressions were guesses, and wrong
// often enough that the only way to know was to apply one and live with it.
//
// If you are writing a new style: keep the stage
// (`components/AnimationStage`). Draw the list however your style draws
// lists, but do not go back to pictures of animations. See STUDIO.md.
Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor

	property var animationOptions: []
	property string animationStateHint: ""
	property string selectedAnimationId: ""
	property int selectedAnimationIndex: 0

	readonly property string applyScriptPath: `${Quickshell.shellDir}/scripts/apply_niri_animation.sh`
	readonly property string shaderAnimationsDir: "/home/lu/.config/niri/animations/shaders"
	readonly property string nirimationAnimationsDir: "/home/lu/.config/niri/animations/nirimation/animations"
	readonly property string animationStatePath: "/home/lu/.local/state/quickshell-theme/current-animation"
	readonly property string shaderCurrentPath: "/home/lu/.config/niri/animations/shaders/.current"

	readonly property int gridColumns: Math.max(2, Math.min(5, Math.floor((gridViewport.width + root.gridGap) / 190)))
	readonly property real gridGap: 10
	readonly property real cardHeight: 54

	readonly property var currentAnimationOption: {
		for (const option of root.animationOptions) {
			if (String(option.id || "") === root.selectedAnimationId) return option;
		}
		return root.animationOptions.length > 0 ? root.animationOptions[0] : null;
	}

	// What the machine is wearing right now, so the grid can mark it.
	readonly property string liveAnimationId: String(root.animationStateHint || "").trim()

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
		root.selectedAnimationIndex = next;
		root.selectedAnimationId = String(root.animationOptions[next].id || "");
		Qt.callLater(root.ensureSelectedVisible);
	}

	function moveSelection(delta) {
		root.selectAnimationIndex(root.selectedAnimationIndex + delta);
	}

	function ensureSelectedVisible() {
		if (root.animationOptions.length === 0) return;
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
		Qt.callLater(function () {
			root.forceActiveFocus();
		});
	}

	Component.onCompleted: root.reset()
	Keys.onEscapePressed: root.closeRequested()
	Keys.onReturnPressed: root.applyAnimation()
	Keys.onEnterPressed: root.applyAnimation()
	Keys.onLeftPressed: root.moveSelection(-1)
	Keys.onRightPressed: root.moveSelection(1)
	Keys.onUpPressed: root.moveSelection(-root.gridColumns)
	Keys.onDownPressed: root.moveSelection(root.gridColumns)
	Keys.onSpacePressed: event => {
		stage.restart();
		event.accepted = true;
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

	Column {
		anchors.fill: parent
		anchors.margins: 6
		spacing: 12

		// ------------------------------------------------------ what is picked
		Row {
			id: headingRow
			width: parent.width
			height: 40
			spacing: 12

			Text {
				width: parent.width - kindPill.width - applyButton.width - 24
				height: parent.height
				color: root.foreground
				font.family: "C059"
				font.pixelSize: 30
				verticalAlignment: Text.AlignVCenter
				elide: Text.ElideRight
				text: root.currentAnimationOption ? String(root.currentAnimationOption.name || "") : "Motion"
			}

			ThemedRectangle {
				id: kindPill
				anchors.verticalCenter: parent.verticalCenter
				width: 66
				height: 20
				radius: ThemeEngine.radiusMedium
				color: Qt.alpha(root.barColor, 0.24)
				border.width: 1
				border.color: Qt.alpha(root.barColor, 0.34)

				Text {
					anchors.centerIn: parent
					color: root.foreground
					font.family: "Adwaita Mono"
					font.pixelSize: 9
					text: root.currentAnimationOption
						? (String(root.currentAnimationOption.kind || "") === "shader" ? "SHADER" : "BLOCK")
						: ""
				}
			}

			ThemedRectangle {
				id: applyButton
				anchors.verticalCenter: parent.verticalCenter
				width: 104
				height: 38
				radius: ThemeEngine.radiusMedium
				color: root.selectedAnimationId === "" ? Qt.alpha(root.secondaryBoxColor, 0.42) : Qt.alpha(root.barColor, 0.28)
				border.width: 1
				border.color: Qt.alpha(root.barColor, 0.52)

				Behavior on color {
					CAnim {}
				}

				Text {
					anchors.centerIn: parent
					color: root.foreground
					font.pixelSize: 12
					font.weight: Font.DemiBold
					text: root.liveAnimationId === root.selectedAnimationId ? "Applied" : "Apply"
				}

				MouseArea {
					anchors.fill: parent
					enabled: root.selectedAnimationId !== ""
					hoverEnabled: true
					cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
					onClicked: root.applyAnimation()
				}
			}
		}

		// ------------------------------------------------------------ the stage
		ThemedRectangle {
			id: stageSurface

			width: parent.width
			height: Math.max(180, (parent.height - headingRow.height - readings.height - 24) * 0.58)
			radius: ThemeEngine.radiusLarge
			color: Qt.alpha(root.background, 0.72)
			border.width: 1
			border.color: Qt.alpha(root.foreground, 0.10)
			clip: true

			AnimationStage {
				id: stage

				anchors.fill: parent
				anchors.margins: 14
				animationId: root.selectedAnimationId
				playing: root.visible

				surfaceColor: root.secondaryBoxColor
				chromeColor: root.secondaryBoxStrongColor
				panelColor: root.secondaryInsetColor
				accentColor: root.barColor
				inkColor: root.foreground
			}
		}

		// What is happening, in words, under the thing happening.
		Item {
			id: readings
			width: parent.width
			height: 34

			Row {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				spacing: 22

				Column {
					spacing: -1

					Text {
						color: root.foreground
						opacity: stage.phase === "opening" || stage.phase === "open" ? 1 : 0.45
						font.pixelSize: 11
						font.weight: Font.DemiBold
						text: "Opening"
					}

					Text {
						color: root.foreground
						opacity: 0.6
						font.family: "Adwaita Mono"
						font.pixelSize: 10
						text: stage.timingLabel(stage.openTiming)
					}
				}

				Column {
					spacing: -1

					Text {
						color: root.foreground
						opacity: stage.phase === "closing" || stage.phase === "closed" ? 1 : 0.45
						font.pixelSize: 11
						font.weight: Font.DemiBold
						text: "Closing"
					}

					Text {
						color: root.foreground
						opacity: 0.6
						font.family: "Adwaita Mono"
						font.pixelSize: 10
						text: stage.timingLabel(stage.closeTiming)
					}
				}
			}

			Text {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				color: root.foreground
				opacity: replayMouse.containsMouse ? 1 : 0.6
				font.pixelSize: 11
				text: stage.building ? "Building…" : (stage.buildError !== "" ? stage.buildError : "Replay")

				MouseArea {
					id: replayMouse
					anchors.fill: parent
					anchors.margins: -8
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: stage.restart()
				}
			}
		}

		// ------------------------------------------------------------- the grid
		Item {
			id: gridViewport
			width: parent.width
			height: parent.height - headingRow.height - stageSurface.height - readings.height - 36
			clip: true

			GridView {
				id: animationGridView
				anchors.fill: parent
				cellWidth: (width + root.gridGap) / root.gridColumns
				cellHeight: root.cardHeight + root.gridGap
				model: root.animationOptions
				currentIndex: root.selectedAnimationIndex
				cacheBuffer: cellHeight * 2
				reuseItems: true
				boundsBehavior: Flickable.StopAtBounds
				clip: true

				delegate: Item {
					id: cardSlot

					required property int index
					required property var modelData

					readonly property bool selected: cardSlot.index === root.selectedAnimationIndex
					readonly property bool live: String(cardSlot.modelData.id || "") === root.liveAnimationId

					width: animationGridView.cellWidth
					height: animationGridView.cellHeight

					ThemedRectangle {
						anchors.fill: parent
						anchors.rightMargin: root.gridGap
						anchors.bottomMargin: root.gridGap
						radius: ThemeEngine.radiusMedium
						color: cardSlot.selected
							? root.secondaryBoxStrongColor
							: cardMouse.containsMouse ? root.secondaryBoxColor : Qt.alpha(root.secondaryBoxColor, 0.45)
						border.width: cardSlot.selected ? 1 : 0
						border.color: root.barColor

						Behavior on color {
							CAnim {}
						}

						Text {
							id: cardName
							anchors.left: parent.left
							anchors.leftMargin: 12
							anchors.right: liveDot.visible ? liveDot.left : parent.right
							anchors.rightMargin: 10
							anchors.top: parent.top
							anchors.topMargin: 9
							color: root.foreground
							opacity: cardSlot.selected ? 1 : 0.78
							font.pixelSize: 12
							font.weight: cardSlot.selected ? Font.DemiBold : Font.Medium
							elide: Text.ElideRight
							text: String(cardSlot.modelData.name || "")
						}

						Text {
							anchors.left: parent.left
							anchors.leftMargin: 12
							anchors.top: cardName.bottom
							anchors.topMargin: 2
							color: root.foreground
							opacity: 0.45
							font.family: "Adwaita Mono"
							font.pixelSize: 9
							text: String(cardSlot.modelData.kind || "")
						}

						// The one the machine is actually wearing.
						Rectangle {
							id: liveDot
							visible: cardSlot.live
							anchors.right: parent.right
							anchors.rightMargin: 11
							anchors.top: parent.top
							anchors.topMargin: 13
							width: 6
							height: 6
							radius: 3
							color: root.barColor
						}

						MouseArea {
							id: cardMouse
							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: {
								root.forceActiveFocus();
								root.selectAnimationIndex(cardSlot.index);
							}
							onDoubleClicked: root.applyAnimation()
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
