pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"
import "NiriAnimation.js" as NiriAnimation

Item {
	id: root

	property bool embedded: false
	signal studioApplyRequested
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

	readonly property string applyScriptPath: `${Quickshell.shellDir}/scripts/apply_niri_animation.sh`
	readonly property string shaderAnimationsDir: "/home/lu/.config/niri/animations/shaders"
	readonly property string nirimationAnimationsDir: "/home/lu/.config/niri/animations/nirimation/animations"
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
        if (root.embedded) { root.studioApplyRequested(); return; }
		if (root.selectedAnimationId === "") return;
		if (!root.embedded) root.closeRequested();
		Quickshell.execDetached(["bash", root.applyScriptPath, "--animation", root.selectedAnimationId]);
	}

	function reset() {
		root.reloadAnimations();
		Qt.callLater(function() {
			root.forceActiveFocus();
		});
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
	Keys.onSpacePressed: event => {
		motionStage.restart();
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


    Item {
        id: panel; anchors.fill: parent; anchors.margins: 14
        // The animation itself, not a sketch of it: the same shader niri would
        // load, over the same duration, on the same curve or spring, playing on
        // a mock window until another card is picked. See STUDIO.md.
        Rectangle {
            id: stagePanel
            width: parent.width * 0.5; height: parent.height - 62; radius: 28; color: Atelier.ink; clip: true

            AnimationStage {
                id: motionStage
                anchors.fill: parent
                anchors.topMargin: 44
                anchors.bottomMargin: 96
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                animationId: root.selectedAnimationId
                playing: root.visible
            }

            AtelierText {
                x: 24; y: 24
                text: motionStage.building
                    ? "WIRD GEBAUT"
                    : motionStage.buildError !== "" ? motionStage.buildError.toUpperCase() : "ECHTE BEWEGUNG"
                color: Atelier.paper; font.family: Atelier.mono; font.pixelSize: 9
            }

            AtelierText {
                x: 24; anchors.bottom: timings.top; anchors.bottomMargin: 10
                width: parent.width - 48
                text: root.currentAnimationOption ? root.currentAnimationOption.label : "Bewegung"
                color: Atelier.paper; display: true; font.pixelSize: 30; wrapMode: Text.WordWrap
                maximumLineCount: 1; elide: Text.ElideRight
            }

            // What is happening, in words, under the thing happening.
            Row {
                id: timings
                x: 24; anchors.bottom: parent.bottom; anchors.bottomMargin: 24
                width: parent.width - 48; spacing: 24

                Column {
                    spacing: 0
                    AtelierText { text: "Öffnen"; font.pixelSize: 11; color: Atelier.paper; opacity: motionStage.phase === "opening" || motionStage.phase === "open" ? 1 : 0.5 }
                    AtelierText { text: motionStage.timingLabel(motionStage.openTiming); font.family: Atelier.mono; font.pixelSize: 9; color: Atelier.paper; opacity: 0.6 }
                }

                Column {
                    spacing: 0
                    AtelierText { text: "Schließen"; font.pixelSize: 11; color: Atelier.paper; opacity: motionStage.phase === "closing" || motionStage.phase === "closed" ? 1 : 0.5 }
                    AtelierText { text: motionStage.timingLabel(motionStage.closeTiming); font.family: Atelier.mono; font.pixelSize: 9; color: Atelier.paper; opacity: 0.6 }
                }

                Column {
                    spacing: 0
                    AtelierText {
                        text: "Nochmal"; font.pixelSize: 11; color: Atelier.paper
                        opacity: replayHover.containsMouse ? 1 : 0.5
                        MouseArea { id: replayHover; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: motionStage.restart() }
                    }
                    AtelierText { text: "Leertaste"; font.family: Atelier.mono; font.pixelSize: 9; color: Atelier.paper; opacity: 0.6 }
                }
            }
        }
        Rectangle {
            visible: !root.embedded; y: stagePanel.height + 16; width: stagePanel.width; height: 44; radius: 22; color: Atelier.accent
            AtelierText { anchors.centerIn: parent; text: "Set this movement  ↗"; color: Atelier.onAccent; font.pixelSize: 12 }
            MouseArea { anchors.fill: parent; enabled: root.selectedAnimationId !== ""; onClicked: root.applyAnimation() }
        }
        Item {
            id: gridViewport
            x: stagePanel.width + 24; width: parent.width - x; height: parent.height
            AtelierText { text: "A library of movement"; display: true; font.pixelSize: 28; width: parent.width; wrapMode: Text.WordWrap }
            GridView {
                id: animationGridView
                y: 72; width: parent.width; height: parent.height - y; clip: true
                cellWidth: width / 2; cellHeight: 148; model: root.animationOptions
                currentIndex: root.selectedAnimationIndex
                delegate: Item {
                    required property int index
                    required property var modelData
                    width: animationGridView.cellWidth; height: animationGridView.cellHeight
                    Rectangle {
                        width: parent.width - 10; height: parent.height - 10; radius: 20
                        color: parent.index === root.selectedAnimationIndex ? Atelier.selectedSurface : Atelier.surface
                        FolioArtwork { x: 10; y: 2; width: parent.width - 20; height: 82; motif: parent.parent.index % 2 ? "signal" : "orbit"; tint: Atelier.sage }
                        AtelierText { x: 14; y: 86; width: parent.width - 28; text: parent.parent.modelData.label; font.pixelSize: 12; maximumLineCount: 2; wrapMode: Text.WordWrap; elide: Text.ElideRight }
                        AtelierText { x: 14; y: 121; text: parent.parent.modelData.kind || "motion"; font.family: Atelier.mono; color: Atelier.muted; font.pixelSize: 8 }
                        MouseArea { anchors.fill: parent; onClicked: root.selectAnimationIndex(parent.parent.index); onDoubleClicked: root.applyAnimation() }
                    }
                }
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }
}
