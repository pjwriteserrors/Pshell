import QtQuick

// A row hung from a thread: a knot on the left where it attaches, then the
// row's own contents. Hover warms the knot, selection lights it; the row
// itself never gets a filled highlight.
Item {
	id: row

	default property alias content: slot.data
	property bool selected: false
	property bool dim: false
	property real knotSize: 6
	property real inset: 14
	property int acceptedButtons: Qt.LeftButton
	readonly property bool hovered: touch.containsMouse

	signal clicked(var mouse)
	signal doubleClicked(var mouse)
	signal entered()

	implicitHeight: 36

	MouseArea {
		id: touch
		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: row.acceptedButtons
		cursorShape: Qt.PointingHandCursor
		onClicked: mouse => row.clicked(mouse)
		onDoubleClicked: mouse => row.doubleClicked(mouse)
		onEntered: row.entered()
	}

	Rectangle {
		anchors.fill: parent
		anchors.leftMargin: row.inset - 6
		radius: Filament.radiusSmall
		color: Qt.alpha(Filament.charge, 0.07)
		opacity: row.hovered && !row.selected ? 1 : 0
		Behavior on opacity { NumberAnimation { duration: Filament.quick } }
	}

	Rectangle {
		id: knot
		x: -row.knotSize / 2 + 1
		anchors.verticalCenter: parent.verticalCenter
		width: row.knotSize
		height: row.knotSize
		radius: width / 2
		color: row.selected ? Filament.charge : (row.hovered ? Filament.wireBright : Filament.wire)
		scale: row.selected ? 1.35 : (row.hovered ? 1.15 : 1)
		Behavior on scale { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.01 } }
		Behavior on color { ColorAnimation { duration: Filament.quick } }
		Rectangle {
			anchors.centerIn: parent
			width: parent.width * 2.6; height: width; radius: width / 2
			color: Qt.alpha(Filament.charge, 0.22)
			visible: row.selected
			z: -1
		}
	}

	Item {
		id: slot
		anchors.fill: parent
		anchors.leftMargin: row.inset
		opacity: row.dim ? 0.45 : 1
	}
}
