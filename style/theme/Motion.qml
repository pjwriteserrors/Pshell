pragma Singleton

import QtQuick
import Quickshell

// Motion language of the shell.
//
//   spatial   – things that grow, move or morph: an ease-out cubic. Under way
//               in the first frame, never more than a sixth of the way per
//               frame, no overshoot.
//   spatialFast – the same, quicker to arrive: small things, hovers, thumbs.
//   emphasized– decisive accelerate/decelerate for large surfaces.
//   decel     – entrances: the same ease-out as spatial.
//   accel     – exits: under way right away, eases into the end instead of
//               lingering and snapping shut.
//   standard  – plain ease for color, opacity and small value changes.
//
// Enter motion is always a bit longer than exit motion.
Singleton {
	readonly property list<real> spatial: [0.33, 1.0, 0.68, 1.0, 1.0, 1.0]
	readonly property list<real> spatialFast: [0.25, 1.0, 0.5, 1.0, 1.0, 1.0]
	readonly property list<real> emphasized: [0.05, 0, 2 / 15, 0.06, 1 / 6, 0.4, 5 / 24, 0.82, 0.25, 1, 1, 1]
	readonly property list<real> decel: [0.33, 1.0, 0.68, 1.0, 1.0, 1.0]
	readonly property list<real> accel: [0.4, 0.0, 0.2, 1.0, 1.0, 1.0]
	readonly property list<real> standard: [0.2, 0.0, 0.0, 1.0, 1.0, 1.0]

	readonly property int micro: 100
	readonly property int short: 160
	readonly property int medium: 220
	readonly property int long: 300
	readonly property int extraLong: 500
}
