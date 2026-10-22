pragma ComponentBehavior: Bound

import QtQuick
import qs.core.services

// A visualizer's share of the one cava (core/services/Cava.qml): `bars`
// values of 0 … 1 while `active`, zeros else.
Item {
	id: root

	property int bars: 32
	property int framerate: 60
	property bool active: false
	readonly property var values: root.active && Cava.values.length > 0 ? Cava.grouped(root.bars) : root.zeros
	readonly property var zeros: Array(Math.max(0, root.bars)).fill(0)
	readonly property string key: `cava-${Math.random().toString(36).slice(2)}`

	visible: false

	function sync() {
		if (root.active) Cava.want(root.key, root.bars, root.framerate);
		else Cava.release(root.key);
	}

	onActiveChanged: root.sync()
	onBarsChanged: if (root.active) root.sync()
	onFramerateChanged: if (root.active) root.sync()
	Component.onCompleted: root.sync()
	Component.onDestruction: Cava.release(root.key)
}
