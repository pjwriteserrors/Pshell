pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"
import "NiriAnimation.js" as NiriAnimation

// Studio's motion page: what a window does when it opens and when it closes.
//
// The page shows the animation, not a likeness of it. The stage runs the one
// the thread is pointing at - the same shader niri would load, over the same
// duration, on the same curve or the same spring - on a mock window, on a
// loop, until another row is picked. Nothing is applied until Apply.
//
// If you are writing a new style: keep the stage
// (`components/AnimationStage`). Draw the list however your style draws
// lists, but do not go back to pictures of animations. See STUDIO.md.
FocusScope {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	property real reveal: 1

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

	// What the machine is wearing right now, so the thread can mark it.
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
		Qt.callLater(function () { if (root.animationOptions.length > 0) animationList.positionViewAtIndex(root.selectedAnimationIndex, ListView.Center); });
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
	Keys.onLeftPressed: root.moveSelection(-1)
	Keys.onRightPressed: root.moveSelection(1)
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

	readonly property real listWidth: Math.max(300, Math.min(width * 0.32, 400))

	// ------------------------------------------------------ what is picked
	Band {
		id: head
		reveal: root.reveal
		order: 0
		width: parent.width - root.listWidth - 40
		height: 44

		Row {
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			spacing: 12
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: root.currentAnimationOption ? String(root.currentAnimationOption.name || "") : "Motion"
				font.pixelSize: Filament.textDisplay
				font.weight: Font.DemiBold
			}
			Chip {
				anchors.verticalCenter: parent.verticalCenter
				visible: !!root.currentAnimationOption
				text: root.currentAnimationOption?.kind === "shader" ? "shader" : "block"
				lit: false
			}
			Chip {
				anchors.verticalCenter: parent.verticalCenter
				visible: root.selectedAnimationId !== "" && root.liveAnimationId === root.selectedAnimationId
				text: "on now"
				lit: true
				mono: false
			}
		}

		Row {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 10
			FButton {
				anchors.verticalCenter: parent.verticalCenter
				kind: "ghost"
				icon: "view-refresh-symbolic"
				text: stage.building ? "Building…" : (stage.buildError !== "" ? stage.buildError : "Replay")
				enabled: !stage.building
				onClicked: {
					root.forceActiveFocus();
					stage.restart();
				}
			}
			FButton {
				anchors.verticalCenter: parent.verticalCenter
				kind: "charge"
				text: root.liveAnimationId === root.selectedAnimationId ? "Applied" : "Apply"
				enabled: root.selectedAnimationId !== ""
				onClicked: root.applyAnimation()
			}
		}
	}

	// ----------------------------------------------------------- the stage
	Band {
		id: stageBand
		reveal: root.reveal
		order: 1
		anchors.top: head.bottom
		anchors.topMargin: 14
		anchors.bottom: readings.top
		anchors.bottomMargin: 18
		width: parent.width - root.listWidth - 40
		implicitHeight: 0

		Rectangle {
			id: stageSurface
			anchors.fill: parent
			radius: Filament.radius
			color: Filament.well
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

			// The phase, as a small lit mark in the corner of the plane.
			Row {
				anchors.left: parent.left
				anchors.leftMargin: 14
				anchors.top: parent.top
				anchors.topMargin: 12
				spacing: 8
				Spark {
					anchors.verticalCenter: parent.verticalCenter
					size: 5
					intensity: stage.phase === "closed" ? 0.3 : 1
					breathing: stage.phase === "open"
				}
				FText {
					anchors.verticalCenter: parent.verticalCenter
					text: stage.building ? "building" : stage.phase
					mono: true
					tone: "mute"
					font.pixelSize: Filament.textXs
				}
			}

			FText {
				anchors.centerIn: parent
				visible: root.animationOptions.length === 0
				text: "Reading the animations…"
				tone: "faint"
				font.pixelSize: Filament.textSm
			}
		}
	}

	// --------------------------------------------------------- the readings
	Band {
		id: readings
		reveal: root.reveal
		order: 2
		anchors.bottom: parent.bottom
		width: parent.width - root.listWidth - 40
		height: 56

		component Reading: Item {
			id: reading
			property string label: ""
			property string value: ""
			property bool hot: false
			height: 44

			FText { x: 0; y: 0; text: reading.label; caps: true; tone: reading.hot ? "charge" : "mute"; font.pixelSize: Filament.textXs; Behavior on color { ColorAnimation { duration: Filament.quick } } }
			FText { anchors.right: parent.right; y: -2; text: reading.value !== "" ? reading.value : "—"; mono: true; tone: reading.hot ? "ink" : "soft"; font.pixelSize: Filament.textSm }
			Wire {
				x: 0; y: 26
				width: parent.width
				height: 2
				cold: Filament.wireDim
				lit: reading.hot ? 1 : 0
			}
			FText { x: 0; y: 32; text: "Space replays"; visible: reading.label === "opening"; tone: "faint"; font.pixelSize: Filament.textXs }
		}

		Reading {
			x: 0
			width: (parent.width - 32) / 2
			label: "opening"
			value: stage.timingLabel(stage.openTiming)
			hot: stage.phase === "opening" || stage.phase === "open"
		}
		Reading {
			x: (parent.width - 32) / 2 + 32
			width: (parent.width - 32) / 2
			label: "closing"
			value: stage.timingLabel(stage.closeTiming)
			hot: stage.phase === "closing" || stage.phase === "closed"
		}
	}

	// ---------------------------------------------------------- the thread
	Band {
		id: listBand
		reveal: root.reveal
		order: 1
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: root.listWidth
		implicitHeight: 0

		readonly property real rowHeight: 36

		FText {
			x: 20; y: 8
			text: "animations"
			caps: true
			tone: "mute"
			font.pixelSize: Filament.textXs
		}
		FText {
			anchors.right: parent.right
			y: 8
			text: `${root.animationOptions.length}`
			mono: true
			tone: "faint"
			font.pixelSize: Filament.textXs
		}

		ThreadLine {
			id: thread
			x: 8
			y: 34
			height: parent.height - 34
			litY: root.animationOptions.length > 0
				? root.selectedAnimationIndex * listBand.rowHeight + listBand.rowHeight / 2 - animationList.contentY
				: -1
			litLength: listBand.rowHeight
		}

		ListView {
			id: animationList
			x: 9
			y: 34
			width: parent.width - 9
			height: parent.height - 34
			clip: true
			model: root.animationOptions
			currentIndex: root.selectedAnimationIndex
			boundsBehavior: Flickable.StopAtBounds
			reuseItems: true
			cacheBuffer: listBand.rowHeight * 4

			delegate: ThreadRow {
				id: row
				required property var modelData
				required property int index
				readonly property bool live: String(row.modelData?.id ?? "") === root.liveAnimationId
				width: animationList.width
				height: listBand.rowHeight
				selected: root.selectedAnimationIndex === row.index
				onClicked: {
					root.forceActiveFocus();
					root.selectAnimationIndex(row.index);
				}
				onDoubleClicked: root.applyAnimation()

				FText {
					anchors.left: parent.left
					anchors.right: kindChip.left
					anchors.rightMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					text: row.modelData?.name ?? ""
					tone: row.selected ? "ink" : "soft"
					font.pixelSize: Filament.textMd
					font.weight: row.selected ? Font.DemiBold : Font.Medium
				}
				Chip {
					id: kindChip
					anchors.right: liveMark.left
					anchors.rightMargin: 8
					anchors.verticalCenter: parent.verticalCenter
					text: row.modelData?.kind === "shader" ? "shader" : "block"
					lit: row.live
				}
				Spark {
					id: liveMark
					anchors.right: parent.right
					anchors.rightMargin: row.live ? 12 : 0
					anchors.verticalCenter: parent.verticalCenter
					size: 5
					visible: row.live
					breathing: true
					width: row.live ? 5 : 0
				}
			}
		}
	}
}
