import QtQuick

// Words in the shell's voice. `tone` picks the ink; `mono` puts a value in
// the numeral face so it never jitters while it changes.
Text {
	id: text

	property string tone: "ink"
	property bool mono: false
	property bool caps: false

	color: tone === "soft" ? Filament.inkSoft
		: tone === "mute" ? Filament.inkMute
		: tone === "faint" ? Filament.inkFaint
		: tone === "charge" ? Filament.charge
		: tone === "alert" ? Filament.alert
		: tone === "onCharge" ? Filament.onCharge
		: Filament.ink
	font.family: mono ? Filament.fontMono : Filament.fontUi
	font.pixelSize: Filament.textMd
	font.capitalization: caps ? Font.AllUppercase : Font.MixedCase
	font.letterSpacing: caps ? 1.2 : 0
	elide: Text.ElideRight
	renderType: Text.NativeRendering
	verticalAlignment: Text.AlignVCenter
}
