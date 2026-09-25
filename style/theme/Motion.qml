pragma Singleton

import QtQuick
import Quickshell

// Motion language of the shell.
//
//   spatial   – things that grow, move or morph. Expressive bezier with a
//               gentle overshoot; reads as "alive" without looking bouncy.
//   emphasized– decisive accelerate/decelerate, used for exits and for
//               large surfaces that should feel solid.
//   standard  – plain ease for color, opacity and small value changes.
//
// Enter motion is always a bit longer than exit motion: panels bloom open
// and snap shut.
Singleton {
	readonly property list<real> spatial: [0.38, 1.21, 0.22, 1.0, 1.0, 1.0]
	readonly property list<real> spatialFast: [0.42, 1.67, 0.21, 0.9, 1.0, 1.0]
	readonly property list<real> emphasized: [0.05, 0, 2 / 15, 0.06, 1 / 6, 0.4, 5 / 24, 0.82, 0.25, 1, 1, 1]
	readonly property list<real> decel: [0.05, 0.7, 0.1, 1.0, 1.0, 1.0]
	readonly property list<real> accel: [0.3, 0.0, 0.8, 0.15, 1.0, 1.0]
	readonly property list<real> standard: [0.2, 0.0, 0.0, 1.0, 1.0, 1.0]

	readonly property int micro: 100
	readonly property int short: 160
	readonly property int medium: 250
	readonly property int long: 360
	readonly property int extraLong: 500
}
