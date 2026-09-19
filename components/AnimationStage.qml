pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// A window opening and closing, for real.
//
// The motion page used to show a recorded clip for a handful of animations and
// a hand-drawn impression for the rest — a picture of the animation, drawn by
// someone guessing. This runs the animation itself: the same GLSL niri would
// load into its compositor, over the same duration, on the same curve, driving
// a mock window instead of a real one.
//
// How that works: `scripts/build_animation_preview.py` rewrites the shader for
// Qt's pipeline and compiles it with `qsb`, and writes the timing next to it.
// This item asks for that build, waits for it, and plays the result on a loop:
//   open → hold → close → hold → again.
//
// If you are writing a new style: keep this. It is the only thing that lets a
// person pick an animation without applying it first and living with whatever
// it turned out to be.
Item {
	id: stage

	// `shader:<name>` or `nirimation:<name>`
	property string animationId: ""
	property bool playing: true

	// What the animation is made of, once the build has answered.
	property var meta: null
	property string phase: "opening"      // opening | open | closing | closed
	property real progress: 0
	property bool building: false
	property string buildError: ""

	readonly property var openTiming: stage.meta?.open ?? null
	readonly property var closeTiming: stage.meta?.close ?? null
	readonly property var activeTiming: stage.phase === "closing" || stage.phase === "closed"
		? stage.closeTiming
		: stage.openTiming

	readonly property string builderPath: `${Quickshell.shellDir}/scripts/build_animation_preview.py`
	// Where the animations live and where their compiled previews are kept.
	// Passed explicitly rather than left to the environment: the shell knows
	// these paths, and the builder should not have to guess them from $HOME.
	property string animationsRoot: "/home/lu/.config/niri/animations"
	property string previewRoot: "/home/lu/.local/state/quickshell-theme/animation-previews"

	// How long a phase is on screen, and how long the window is left alone
	// between phases so you can see what it settled into.
	readonly property int holdOpen: 900
	readonly property int holdClosed: 520

	function timingLabel(timing) {
		if (!timing) return "";
		if (timing.off) return "off";
		if (timing.spring)
			return `spring ${timing.spring.stiffness} · damping ${timing.spring.dampingRatio}`;
		const curve = String(timing.curve || "ease-out-cubic");
		return `${timing.durationMs || 0} ms · ${curve}`;
	}

	function shaderUrl(timing) {
		const path = timing?.shader ?? "";
		return path === "" ? "" : `file://${path}`;
	}

	// niri hands every run a fresh seed; the shaders that use it look wrong
	// when it never changes.
	property real seed: Math.random()

	function restart() {
		stage.phase = "opening";
		stage.progress = 0;
		stage.seed = Math.random();
		driver.start();
	}

	onAnimationIdChanged: stage.rebuild()
	Component.onCompleted: stage.rebuild()

	function rebuild() {
		driver.stop();
		stage.meta = null;
		stage.progress = 1;
		stage.phase = "open";
		stage.buildError = "";
		if (stage.animationId === "") return;
		stage.building = true;
		buildProcess.command = [
			"python3", stage.builderPath, stage.animationId,
			"--animations-root", stage.animationsRoot,
			"--out-dir", stage.previewRoot
		];
		buildProcess.running = true;
	}

	Process {
		id: buildProcess

		stdout: StdioCollector {
			onStreamFinished: {
				const path = String(text || "").trim();
				if (path === "") {
					stage.building = false;
					stage.buildError = "could not build a preview";
					return;
				}
				metaFile.path = path;
				metaFile.reload();
			}
		}

		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") stage.buildError = message.split("\n").pop();
			}
		}

		onExited: function (code) {
			if (code !== 0) stage.building = false;
		}
	}

	FileView {
		id: metaFile

		onLoaded: {
			try {
				stage.meta = JSON.parse(metaFile.text());
				stage.buildError = "";
			} catch (error) {
				stage.meta = null;
				stage.buildError = "preview metadata unreadable";
			}
			stage.building = false;
			if (stage.playing) stage.restart();
		}

		onLoadFailed: {
			stage.building = false;
			stage.buildError = "preview metadata missing";
		}
	}

	onPlayingChanged: {
		if (stage.playing && stage.meta) stage.restart();
		else if (!stage.playing) driver.stop();
	}

	// ------------------------------------------------------------ the driver
	// Two ways an animation can be timed in niri, and both are honoured here:
	// a duration with a named curve, or a spring. The spring is integrated
	// frame by frame from the same constants niri would use, because an
	// approximation with an easing curve is exactly the kind of "close enough"
	// this page exists to get rid of.
	QtObject {
		id: driver

		property bool running: false

		function curveType(name) {
			switch (String(name || "")) {
			case "linear": return Easing.Linear;
			case "ease-out-quad": return Easing.OutQuad;
			case "ease-out-cubic": return Easing.OutCubic;
			case "ease-out-expo": return Easing.OutExpo;
			case "ease-in-quad": return Easing.InQuad;
			case "ease-in-cubic": return Easing.InCubic;
			case "ease-in-out-cubic": return Easing.InOutCubic;
			case "ease-in-out-quad": return Easing.InOutQuad;
			default: return Easing.OutCubic;
			}
		}

		function start() {
			driver.running = true;
			driver.runPhase();
		}

		function stop() {
			driver.running = false;
			curveAnimation.stop();
			springClock.running = false;
			holdTimer.stop();
		}

		function runPhase() {
			const timing = stage.activeTiming;
			stage.progress = 0;

			if (!timing || timing.off) {
				stage.progress = 1;
				driver.finishPhase();
				return;
			}

			if (timing.spring) {
				springState.position = 0;
				springState.velocity = 0;
				springState.stiffness = timing.spring.stiffness;
				springState.damping = timing.spring.dampingRatio;
				springState.epsilon = timing.spring.epsilon;
				springClock.running = true;
				return;
			}

			curveAnimation.duration = Math.max(1, timing.durationMs || 250);
			curveAnimation.easing.type = driver.curveType(timing.curve);
			curveAnimation.start();
		}

		function finishPhase() {
			if (!driver.running) return;
			if (stage.phase === "opening") {
				stage.phase = "open";
				holdTimer.interval = stage.holdOpen;
			} else {
				stage.phase = "closed";
				holdTimer.interval = stage.holdClosed;
			}
			holdTimer.restart();
		}
	}

	QtObject {
		id: springState
		property real position: 0
		property real velocity: 0
		property real stiffness: 800
		property real damping: 0.85
		property real epsilon: 0.0001
	}

	NumberAnimation {
		id: curveAnimation
		target: stage
		property: "progress"
		from: 0
		to: 1
		onFinished: driver.finishPhase()
	}

	FrameAnimation {
		id: springClock
		running: false

		onTriggered: {
			// A damped harmonic oscillator pulled towards 1, stepped at most a
			// sixtieth of a second at a time so a dropped frame cannot make it
			// explode.
			const step = Math.min(frameTime, 1 / 60);
			const c = 2 * springState.damping * Math.sqrt(springState.stiffness);
			const acceleration = springState.stiffness * (1 - springState.position) - c * springState.velocity;
			springState.velocity += acceleration * step;
			springState.position += springState.velocity * step;
			stage.progress = springState.position;

			if (Math.abs(1 - springState.position) < springState.epsilon
				&& Math.abs(springState.velocity) < springState.epsilon * 60) {
				stage.progress = 1;
				springClock.running = false;
				driver.finishPhase();
			}
		}
	}

	Timer {
		id: holdTimer
		repeat: false
		onTriggered: {
			if (!driver.running) return;
			if (stage.phase === "open") {
				stage.phase = "closing";
				stage.seed = Math.random();
				driver.runPhase();
			} else {
				stage.phase = "opening";
				stage.seed = Math.random();
				driver.runPhase();
			}
		}
	}

	// ------------------------------------------------------- the mock window
	// Something with structure in it: a shader that warps, wipes or dissolves
	// has nothing to show on a flat rectangle.
	Item {
		id: mockWindow

		width: Math.round(Math.min(stage.width * 0.78, 460))
		height: Math.round(Math.min(stage.height * 0.68, 300))
		visible: false
		layer.enabled: true

		Rectangle {
			anchors.fill: parent
			color: Bio.tissue1

			Rectangle {
				id: mockBar
				width: parent.width
				height: 26
				color: Bio.tissue3

				Row {
					anchors.left: parent.left
					anchors.leftMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					spacing: 6

					Repeater {
						model: 3

						delegate: Rectangle {
							required property int index
							width: 8
							height: 8
							radius: 4
							color: index === 0 ? Bio.necrosis : index === 1 ? Bio.enzyme : Bio.vital
						}
					}
				}

				BioText {
					anchors.centerIn: parent
					role: "label"
					tone: "muted"
					font.pixelSize: 9
					text: "specimen"
				}
			}

			Rectangle {
				id: mockSide
				anchors.left: parent.left
				anchors.top: mockBar.bottom
				anchors.bottom: parent.bottom
				width: 52
				color: Bio.tissue2

				Column {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.top: parent.top
					anchors.topMargin: 14
					spacing: 12

					Repeater {
						model: 4

						delegate: Rectangle {
							required property int index
							width: 22
							height: 22
							radius: 11
							color: index === 1 ? Qt.alpha(Bio.organ, 0.8) : Bio.tissue3
						}
					}
				}
			}

			Column {
				anchors.left: mockSide.right
				anchors.leftMargin: 16
				anchors.top: mockBar.bottom
				anchors.topMargin: 18
				anchors.right: parent.right
				anchors.rightMargin: 16
				spacing: 11

				Rectangle {
					width: Math.round(parent.width * 0.5)
					height: 12
					radius: 2
					color: Qt.alpha(Bio.organ, 0.75)
				}

				Repeater {
					model: 5

					delegate: Rectangle {
						required property int index
						width: Math.round(parent.width * (0.92 - index * 0.13))
						height: 7
						radius: 3
						color: Qt.alpha(Bio.bone, 0.24 - index * 0.025)
					}
				}
			}
		}
	}

	ShaderEffectSource {
		id: mockTexture
		sourceItem: mockWindow
		hideSource: true
		live: true
		width: mockWindow.width
		height: mockWindow.height
		visible: false
	}

	// The window as niri would draw it mid-animation. Without a compiled
	// shader this is the plain texture, which is what niri does for an
	// animation block that sets no custom shader.
	ShaderEffect {
		id: playback

		anchors.centerIn: parent
		width: mockWindow.width
		height: mockWindow.height

		property variant niri_tex: mockTexture
		property real niri_clamped_progress: Math.max(0, Math.min(1, stage.progress))
		property real niri_progress: stage.progress
		property real niri_random_seed: stage.seed

		fragmentShader: stage.shaderUrl(stage.activeTiming)

		// While the window is "closed" there is nothing on screen — which is
		// the truthful state, and the pause that makes the loop readable.
		opacity: stage.phase === "closed" ? 0 : 1
	}
}
