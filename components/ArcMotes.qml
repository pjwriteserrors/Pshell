pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Particles

// Motes: the drifting lights the sanctum is full of.
//
// This is the one place in the shell that uses a real particle system, because
// what motes do — wander, fade, be emitted in a burst when something happens —
// is not something a Canvas repaint can do without costing a repaint per frame.
// The GPU does it for nothing.
//
// Two modes. `drifting` is the idle life: a slow fall of fireflies through the
// item, used sparingly and only near the great circle and inside a conjuring.
// Calling `burst()` throws a handful outward from a point, which is what every
// keystroke in the codex and every press of a sigil does.
Item {
	id: field

	property color color: Arc.aether
	property bool drifting: false
	property int density: 14
	property real drift: 8          // how fast the idle motes fall
	property real span: 3.0         // mote size

	function burst(x, y, count) {
		spark.x = x === undefined ? width / 2 : x;
		spark.y = y === undefined ? height / 2 : y;
		spark.burst(count === undefined ? 12 : count);
	}

	ParticleSystem {
		id: system
		anchors.fill: parent
		running: field.visible
	}

	ImageParticle {
		system: system
		groups: ["mote"]
		// A point of light with no image behind it: the renderer's own round
		// sprite, tinted, is exactly a mote and costs nothing.
		color: field.color
		colorVariation: 0.22
		alpha: 0.85
		alphaVariation: 0.45
		entryEffect: ImageParticle.Fade
	}

	// The idle fall. Slow, sparse, and never in the way of reading.
	Emitter {
		system: system
		group: "mote"
		enabled: field.drifting
		anchors.fill: parent
		emitRate: field.density
		lifeSpan: 5200
		lifeSpanVariation: 2400
		size: field.span
		sizeVariation: field.span * 0.7
		endSize: 0
		velocity: AngleDirection {
			angle: 270
			angleVariation: 32
			magnitude: field.drift
			magnitudeVariation: field.drift * 0.7
		}
	}

	// The burst: what a conjuring throws off when it is touched.
	Emitter {
		id: spark
		system: system
		group: "mote"
		enabled: false
		width: 1
		height: 1
		emitRate: 0
		lifeSpan: 900
		lifeSpanVariation: 400
		size: field.span * 1.6
		sizeVariation: field.span
		endSize: 0
		velocity: AngleDirection {
			angle: 0
			angleVariation: 360
			magnitude: 42
			magnitudeVariation: 30
		}
		acceleration: AngleDirection {
			angle: 270
			magnitude: 26
		}
	}
}
