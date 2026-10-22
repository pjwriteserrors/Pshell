import QtQuick
import qs.style.theme

// A chat's face: one person, or the two who wrote last for a group.
Item {
	id: root

	property var people: []
	property real size: 40
	property color surface: Theme.base
	readonly property bool group: root.people.length > 1

	implicitWidth: root.size
	implicitHeight: root.size

	Avatar {
		visible: !root.group
		size: root.size
		name: root.people[0]?.name ?? ""
		email: root.people[0]?.email ?? ""
	}

	Avatar {
		visible: root.group
		x: root.size * 0.36
		size: root.size * 0.64
		name: root.people[1]?.name ?? ""
		email: root.people[1]?.email ?? ""
	}

	Rectangle {
		visible: root.group
		y: root.size * 0.3
		width: root.size * 0.7
		height: width
		radius: width / 2
		color: root.surface

		Avatar {
			anchors.centerIn: parent
			size: root.size * 0.64
			name: root.people[0]?.name ?? ""
			email: root.people[0]?.email ?? ""
		}
	}
}
