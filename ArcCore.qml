pragma ComponentBehavior: Bound

import QtQuick
import "components"
import "components/ArcInk.js" as Ink

// THE ARCANE CORE.
//
// The machine's load is not four numbers with icons next to them. It is a core
// with four bodies in orbit around it, and what the reading does is change the
// *state of the system*, exactly as the reference asks:
//
//   at rest   the bodies sit far out on a slow, wide orbit, the core is dim
//             and everything is still
//   at load   they are drawn in towards the core, they turn faster, they swell,
//             and the core burns — at the top of the scale it goes to the
//             alert colour and the whole thing shakes
//
// So you never read this. You glance at it and know, from how tight and how
// fast it is, what the machine is doing. The names are on the panel it opens.
Item {
	id: core

	signal clicked

	required property var resources
	property bool lit: false

	implicitWidth: 104
	implicitHeight: Arc.horizon

	readonly property real mana: core.resources ? core.resources.cpuUsage : 0
	readonly property real aether: core.resources ? core.resources.memoryUsage : 0
	readonly property real vault: core.resources ? core.resources.storageUsage : 0
	readonly property real essence: core.resources && core.resources.mouseBatteryAvailable
		? 1 - core.resources.mouseBatteryUsage : 0

	// One number for the whole machine: how hard it is working.
	readonly property real strain: Math.max(core.mana, core.aether)
	readonly property bool burning: core.strain > 0.86

	readonly property real centreX: width / 2
	readonly property real centreY: Arc.horizon * 0.44

	// The orbit turns of its own accord, and faster the harder the machine is
	// working. This is the only place in the shell where something moves
	// continuously because of what the machine is doing rather than because
	// somebody touched it.
	property real turn: 0

	NumberAnimation on turn {
		running: true
		loops: Animation.Infinite
		from: 0
		to: Math.PI * 2
		duration: 30000
	}

	// The shake at the top of the scale: integrated, so it is a real tremor
	// that settles rather than a looping wobble.
	property real tremor: 0

	Timer {
		running: core.burning
		repeat: true
		interval: 16
		onTriggered: core.tremor = (Math.random() - 0.5) * 2.2 * (core.strain - 0.86) / 0.14
		onRunningChanged: if (!running) core.tremor = 0
	}

	ArcHalo {
		anchors.centerIn: orb
		width: 118
		height: 118
		color: core.burning ? Arc.bane : Arc.aether
		strength: 0.16 + core.strain * 0.34
		spread: 0.34
		flicker: true
	}

	Item {
		id: orb
		x: core.centreX
		y: core.centreY
		width: 1
		height: 1
	}

	Canvas {
		id: orrery
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		readonly property real mana: core.mana
		readonly property real aether: core.aether
		readonly property real vault: core.vault
		readonly property real essence: core.essence
		readonly property real spin: core.turn * (1 + core.strain * 5)
		readonly property real shake: core.tremor

		onManaChanged: requestPaint()
		onAetherChanged: requestPaint()
		onVaultChanged: requestPaint()
		onEssenceChanged: requestPaint()
		onSpinChanged: requestPaint()
		onShakeChanged: requestPaint()

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width < 20) return;
			const cx = core.centreX + core.tremor, cy = core.centreY + core.tremor * 0.6;
			const hot = core.burning;
			const live = hot ? Arc.bane : Arc.aether;

			// the ring the bodies run on: it closes in as the load rises
			const orbit = 44 - core.strain * 16;
			Ink.ring(ctx, cx, cy, orbit, Arc.ruleThin, Qt.alpha(Arc.gold, 0.16), 1);

			// the core itself
			Ink.mote(ctx, cx, cy, 4 + core.strain * 4, live);
			Ink.ring(ctx, cx, cy, 9 + core.strain * 3, Arc.ruleThin,
				Qt.alpha(live, 0.3 + core.strain * 0.5), 1);

			// the four bodies
			const bodies = [
				{ value: orrery.mana, tint: live },
				{ value: orrery.aether, tint: hot ? Arc.bane : Arc.aetherAlt },
				{ value: orrery.vault, tint: Arc.aetherThird },
				{ value: orrery.essence, tint: orrery.essence > 0.8 ? Arc.bane : Arc.gold }
			];

			for (let index = 0; index < bodies.length; index++) {
				const body = bodies[index];
				const angle = orrery.spin + index * Math.PI / 2;
				// drawn in towards the core as its own reading rises
				const at = orbit * (1 - body.value * 0.42);
				const x = cx + Math.cos(angle) * at;
				const y = cy + Math.sin(angle) * at * 0.62;
				Ink.ley(ctx, cx, cy, x, y, Arc.ruleThin,
					Qt.alpha(body.tint, 0.13 + body.value * 0.22), null, -1);
				Ink.mote(ctx, x, y, 2.0 + body.value * 3.4, body.tint);
			}
		}
	}

	ArcTouch {
		id: touch
		onClicked: core.clicked()
	}

	ArcText {
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 2
		role: "label"
		tone: core.burning ? "alert" : (touch.containsMouse || core.lit ? "aether" : "faint")
		font.pixelSize: 9
		text: core.burning ? "Straining" : "Core"
		opacity: touch.containsMouse || core.lit || core.burning ? 1 : 0.5

		Behavior on opacity {
			NumberAnimation { duration: Arc.tick }
		}
	}
}
