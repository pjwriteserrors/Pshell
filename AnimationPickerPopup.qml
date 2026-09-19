pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"
import "NiriAnimation.js" as NiriAnimation

// Studio's motion page: what a window does when it opens and when it closes.
//
// This page shows the animation, not a likeness of it. The list on the left is
// every animation niri can be given; the stage on the right runs the one the
// list is pointing at — the same shader, the same duration, the same curve or
// spring — on a mock window, over and over, until you pick another. Nothing is
// applied until you graft it, so you can walk the whole list and watch.
//
// It used to be a wall of cards: a recorded clip for the few that had one, and
// for the rest a hand-drawn impression of what the animation might look like.
// Those impressions were guesses, and wrong often enough that the only way to
// know was to apply one and live with it.
//
// If you are writing a new style: keep the stage (`components/AnimationStage`).
// Draw the list however your style draws lists, but do not go back to pictures
// of animations.
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

	readonly property var currentAnimationOption: {
		for (const option of root.animationOptions) {
			if (String(option.id || "") === root.selectedAnimationId) return option;
		}
		return root.animationOptions.length > 0 ? root.animationOptions[0] : null;
	}

	// What is on the machine right now, so the list can mark it.
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
		animationList.positionViewAtIndex(root.selectedAnimationIndex, ListView.Contain);
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
	Keys.onUpPressed: root.moveSelection(-1)
	Keys.onDownPressed: root.moveSelection(1)
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

	// ------------------------------------------------------------- the index
	ListView {
		id: animationList

		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: Math.round(Math.min(parent.width * 0.32, 300))
		clip: true
		model: root.animationOptions
		currentIndex: root.selectedAnimationIndex
		boundsBehavior: Flickable.StopAtBounds
		spacing: 0

		delegate: Item {
			id: optionRow

			required property var modelData
			required property int index

			readonly property bool selected: root.selectedAnimationIndex === optionRow.index
			readonly property bool live: String(optionRow.modelData.id || "") === root.liveAnimationId

			width: animationList.width
			height: 32

			Rectangle {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				width: Bio.rib * 1.6
				height: parent.height * (optionRow.selected ? 0.66 : 0)
				radius: width / 2
				color: Bio.organ
				opacity: optionRow.selected ? 1 : 0

				Behavior on opacity {
					NumberAnimation { duration: Bio.twitch }
				}
				Behavior on height {
					NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
				}
			}

			BioText {
				id: optionKind
				anchors.left: parent.left
				anchors.leftMargin: Bio.s4
				anchors.verticalCenter: parent.verticalCenter
				role: "mono"
				tone: optionRow.selected ? "organ" : "faint"
				font.pixelSize: 9
				text: String(optionRow.modelData.kind || "") === "shader" ? "sh" : "bl"
			}

			BioText {
				anchors.left: optionKind.right
				anchors.leftMargin: Bio.s3
				anchors.right: liveMark.visible ? liveMark.left : parent.right
				anchors.rightMargin: Bio.s3
				anchors.verticalCenter: parent.verticalCenter
				role: "heading"
				font.pixelSize: 13
				tone: optionRow.selected ? "default" : "muted"
				text: String(optionRow.modelData.name || "")
			}

			// The one the machine is actually wearing.
			Rectangle {
				id: liveMark
				visible: optionRow.live
				anchors.right: parent.right
				anchors.rightMargin: Bio.s4
				anchors.verticalCenter: parent.verticalCenter
				width: Bio.nodule * 2
				height: Bio.nodule * 2
				radius: width / 2
				color: Bio.vital
			}

			BioTouch {
				onEntered: root.selectAnimationIndex(optionRow.index)
				onClicked: root.selectAnimationIndex(optionRow.index)
				onDoubleClicked: root.applyAnimation()
			}
		}
	}

	Rectangle {
		id: motionBone
		anchors.left: animationList.right
		anchors.leftMargin: Bio.s6
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.topMargin: Bio.s3
		anchors.bottomMargin: Bio.s3
		width: Bio.ribThin
		color: Bio.boneGhost
	}

	// ------------------------------------------------------------- the stage
	Item {
		id: stageColumn

		anchors.left: motionBone.right
		anchors.leftMargin: Bio.s7
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom

		BioText {
			id: stageName
			anchors.left: parent.left
			anchors.top: parent.top
			role: "specimen"
			font.pixelSize: 26
			text: root.currentAnimationOption ? String(root.currentAnimationOption.name || "") : ""
		}

		BioText {
			id: stageKind
			anchors.left: stageName.right
			anchors.leftMargin: Bio.s3
			anchors.baseline: stageName.baseline
			role: "label"
			tone: "faint"
			text: root.currentAnimationOption
				? (String(root.currentAnimationOption.kind || "") === "shader" ? "shader" : "block")
				: ""
		}

		AnimationStage {
			id: stage

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: stageName.bottom
			anchors.topMargin: Bio.s5
			anchors.bottom: readings.top
			anchors.bottomMargin: Bio.s5
			animationId: root.selectedAnimationId
			playing: root.visible
		}

		// What is happening, in words, under the thing happening.
		Column {
			id: readings

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.bottomMargin: Bio.s3
			spacing: Bio.s3

			BioTendon {
				width: parent.width
				height: 12
				facing: Qt.LeftToRight
				lineColor: Bio.boneFaint
			}

			Item {
				width: parent.width
				height: 34

				Column {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					spacing: -1

					BioText {
						role: "label"
						tone: stage.phase === "opening" || stage.phase === "open" ? "organ" : "faint"
						text: "Opening"
					}

					BioText {
						role: "caption"
						tone: "muted"
						text: stage.timingLabel(stage.openTiming)
					}
				}

				Column {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.verticalCenter: parent.verticalCenter
					spacing: -1

					BioText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "label"
						tone: stage.phase === "closing" || stage.phase === "closed" ? "organ" : "faint"
						text: "Closing"
					}

					BioText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "caption"
						tone: "muted"
						text: stage.timingLabel(stage.closeTiming)
					}
				}

				BioText {
					id: replayLabel
					anchors.right: graftLabel.left
					anchors.rightMargin: Bio.s5
					anchors.verticalCenter: parent.verticalCenter
					role: "label"
					tone: replayTouch.containsMouse ? "organ" : "faint"
					text: stage.building ? "Building…" : (stage.buildError !== "" ? stage.buildError : "Replay")

					BioTouch {
						id: replayTouch
						anchors.margins: -Bio.s2
						onClicked: stage.restart()
					}
				}

				BioText {
					id: graftLabel
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					role: "label"
					tone: graftTouch.containsMouse ? "organ" : "muted"
					text: root.liveAnimationId === root.selectedAnimationId ? "Grafted" : "Graft"

					BioTouch {
						id: graftTouch
						anchors.margins: -Bio.s2
						onClicked: root.applyAnimation()
					}
				}
			}
		}
	}
}
