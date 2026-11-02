pragma Singleton

import QtQuick
import Quickshell
import qs.style.theme

// The world in the shell's colours. What has an obvious colour (grass is green)
// takes the shell colour nearest to it; when none is near enough, the natural
// colour is mixed with the shell's own, so it is still recognisably grass.
Singleton {
	id: root

	readonly property var shell: Theme.ranked.map(item => item.color)
	// how close in hue a shell colour must be to stand in for a natural one
	readonly property real threshold: 0.5

	function closeness(color, target) {
		let apart = Math.abs(color.hslHue - target.hslHue);
		if (apart > 0.5) apart = 1 - apart;
		return (1 - Math.min(1, apart / 0.14)) * Math.min(1, color.hslSaturation / 0.28);
	}

	// a natural colour by way of the shell's palette
	function natural(value, mix) {
		const target = Qt.color(value);
		let best = null, bestScore = 0;
		for (const color of root.shell) {
			const score = root.closeness(color, target);
			if (score > bestScore) {
				best = color;
				bestScore = score;
			}
		}
		if (best !== null && bestScore >= root.threshold) {
			const delta = ((best.hslHue - target.hslHue + 1.5) % 1) - 0.5;
			return Qt.hsla((target.hslHue + delta * 0.18 + 1) % 1, target.hslSaturation * 0.94, target.hslLightness, 1);
		}
		return Qt.tint(target, Qt.alpha(Theme.primary, mix === undefined ? 0.045 : mix));
	}

	readonly property color deep: root.natural("#244e60")
	readonly property color shallow: root.natural("#69a79e")
	readonly property color grass: root.natural("#81966a")
	readonly property color roof: root.natural("#a5553f")
}
