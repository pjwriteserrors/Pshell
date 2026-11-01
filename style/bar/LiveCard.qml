import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The card under a live status of the bar while the pointer rests on it
// (LiveCardBody), placed under the item when it comes.
PopupWindow {
	id: root

	required property var bar
	required property Item target
	required property string key
	property bool shown: false

	// where the item is, taken when the card comes (a mapping does not follow moves)
	property real at: 0
	onShownChanged: {
		if (!root.shown || !root.target) return;
		const p = root.target.mapToItem(null, root.target.width / 2, 0);
		root.at = Math.round(p.x - root.implicitWidth / 2);
	}
	anchor.window: root.bar
	anchor.rect.x: root.at
	anchor.rect.y: Theme.barHeight + 4
	anchor.adjustment: PopupAdjustment.SlideX
	implicitWidth: 284
	implicitHeight: card.implicitHeight + 8
	color: "transparent"
	visible: root.shown || card.opacity > 0.01

	LiveCardBody {
		id: card

		anchors.fill: parent
		anchors.margins: 4
		key: root.key
		shown: root.shown
	}
}
