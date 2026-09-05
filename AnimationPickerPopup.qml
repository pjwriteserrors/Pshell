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


    Item {
        id: panel; anchors.fill: parent; anchors.margins: 14
        Rectangle {
            id: stage
            width: parent.width * 0.5; height: parent.height - 62; radius: 28; color: Atelier.ink; clip: true
            FolioArtwork { anchors.fill: parent; anchors.margins: 20; tint: Atelier.sage }
            VideoOutput { id: selectedVideo; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectCrop; visible: selectedPlayer.source.toString() !== "" }
            MediaPlayer {
                id: selectedPlayer
                source: root.currentAnimationOption ? root.currentAnimationOption.preview || "" : ""
                videoOutput: selectedVideo; loops: MediaPlayer.Infinite; autoPlay: true
            }
            Item {
                anchors.fill: parent; visible: !selectedVideo.visible
                Repeater {
                    model: 5
                    delegate: Rectangle {
                        required property int index
                        width: 58 + index * 12; height: width; radius: width / 2
                        x: stage.width / 2 - width / 2 + Math.cos(root.previewProgress * Math.PI * 2 + index * 0.8) * stage.width * 0.24
                        y: stage.height / 2 - height / 2 + Math.sin(root.previewProgress * Math.PI * 2 + index * 0.8) * stage.height * 0.24
                        color: [Atelier.sage,Atelier.gold,Atelier.accent,Atelier.surface,Atelier.paper][index]
                        opacity: 0.8
                    }
                }
            }
            AtelierText { x: 24; y: 24; text: selectedVideo.visible ? "MOTION FILM" : "MOTION SKETCH · NOT A SHADER RENDER"; color: Atelier.paper; font.family: Atelier.mono; font.pixelSize: 9 }
            AtelierText { x: 24; anchors.bottom: parent.bottom; anchors.bottomMargin: 26; width: parent.width - 48; text: root.currentAnimationOption ? root.currentAnimationOption.label : "Movement"; color: Atelier.paper; display: true; font.pixelSize: 30; wrapMode: Text.WordWrap }
        }
        Rectangle {
            y: stage.height + 16; width: stage.width; height: 44; radius: 22; color: Atelier.accent
            AtelierText { anchors.centerIn: parent; text: "Set this movement  ↗"; color: Atelier.onAccent; font.pixelSize: 12 }
            MouseArea { anchors.fill: parent; enabled: root.selectedAnimationId !== ""; onClicked: root.applyAnimation() }
        }
        Item {
            id: gridViewport
            x: stage.width + 24; width: parent.width - x; height: parent.height
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
