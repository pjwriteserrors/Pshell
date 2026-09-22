import QtQuick

// One band of a lantern's contents. Bands surface one after the other as the
// lantern unfolds: each rises a few pixels out of the one above it and comes
// into light. `reveal` is the lantern's own 0..1; `order` is the band's turn.
Item {
	id: band

	property real reveal: 1
	property int order: 0
	default property alias content: inner.data
	readonly property real own: Filament.band(reveal, order)

	implicitWidth: inner.childrenRect.width
	implicitHeight: inner.childrenRect.height

	opacity: own
	transform: Translate { y: (1 - band.own) * -8 }

	Item {
		id: inner
		anchors.fill: parent
	}
}
