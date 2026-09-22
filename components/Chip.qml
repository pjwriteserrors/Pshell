import QtQuick

// A small label on its own bead: counts, badges, kinds.
Rectangle {
	id: chip

	property string text: ""
	property bool lit: false
	property bool alarm: false
	property bool mono: true

	implicitWidth: label.implicitWidth + 12
	implicitHeight: 18
	radius: height / 2
	color: alarm ? Qt.alpha(Filament.alert, 0.18) : (lit ? Qt.alpha(Filament.charge, 0.18) : Filament.well)
	border.width: 1
	border.color: alarm ? Filament.alert : (lit ? Filament.charge : "transparent")

	FText {
		id: label
		anchors.centerIn: parent
		text: chip.text
		mono: chip.mono
		font.pixelSize: Filament.textXs
		color: chip.alarm ? Filament.alert : (chip.lit ? Filament.charge : Filament.inkSoft)
	}
}
