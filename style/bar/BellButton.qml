import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Notification center entry. The bell swings when something arrives and
// sleeps while do-not-disturb is on. Middle click toggles do-not-disturb.
BarButton {
	id: root

	property int lastCount: Notifs.count

	panelId: "today"
	primaryAnchor: false
	tooltip: (Notifs.dnd ? `Do not disturb · ${Notifs.dndReason.toLowerCase()}\n` : "") + (Notifs.count > 0 ? `${Notifs.count} notification groups` : "No notifications")
	padding: 9
	onClicked: toggle()
	onMiddleClicked: Notifs.toggleDnd()

	Connections {
		target: Notifs
		function onCountChanged() {
			if (Notifs.count > root.lastCount && !Notifs.dnd) swing.restart();
			root.lastCount = Notifs.count;
		}
	}

	Item {
		anchors.verticalCenter: parent.verticalCenter
		width: 20
		height: 20

		Glyph {
			id: bell

			anchors.centerIn: parent
			icon: Notifs.dnd ? "bell_sleep_outline" : (Notifs.count > 0 ? "bell_badge_outline" : "bell_outline")
			size: 18
			color: root.active ? Theme.primary : (Notifs.dnd ? Theme.textMuted : Theme.text)
			transformOrigin: Item.Top
		}

		Badge {
			x: 11
			y: -3
			count: Notifs.count
		}
	}

	SequentialAnimation {
		id: swing

		NumberAnimation { target: bell; property: "rotation"; to: 18; duration: 90; easing.type: Easing.OutQuad }
		NumberAnimation { target: bell; property: "rotation"; to: -15; duration: 140; easing.type: Easing.InOutQuad }
		NumberAnimation { target: bell; property: "rotation"; to: 10; duration: 130; easing.type: Easing.InOutQuad }
		NumberAnimation { target: bell; property: "rotation"; to: -6; duration: 120; easing.type: Easing.InOutQuad }
		NumberAnimation { target: bell; property: "rotation"; to: 0; duration: 160; easing.type: Easing.OutQuad }
	}
}
