import QtQuick

// Two voices, never mixed within a line.
//
// The cut letter is what the instrument has engraved on it: names of things,
// small capitals, widely tracked, permanent. The hand is what somebody wrote on
// the page afterwards: an app's true name, an aside beside a reading, the line
// the oracle gives you. Body text is the cut letter's lowercase, because this
// is a book and a book does not change typeface halfway down the page.
Text {
	id: label

	// display | title | heading | label | body | bodyStrong | caption | mono
	// | reading | hand
	property string role: "body"
	property string tone: "default"   // default | muted | faint | aether | onAether | alert | ward

	readonly property bool engraved: role === "display" || role === "title"
		|| role === "heading" || role === "label" || role === "reading"

	font.family: role === "mono" ? Arc.mono : role === "hand" ? Arc.hand : engraved ? Arc.cut : Arc.book
	font.pixelSize: role === "display" ? Arc.sizeDisplay
		: role === "title" ? Arc.sizeTitle
		: role === "heading" ? Arc.sizeHeading
		: role === "reading" ? Arc.sizeTitle
		: role === "label" ? Arc.sizeRubric
		: role === "caption" ? Arc.sizeCaption
		: role === "mono" ? Arc.sizeMono
		: role === "hand" ? Arc.sizeBody + 2
		: Arc.sizeBody
	font.capitalization: engraved && role !== "reading" ? Font.SmallCaps : Font.MixedCase
	font.italic: role === "hand"
	font.letterSpacing: role === "label" ? Arc.trackingRubric
		: role === "display" || role === "title" ? Arc.trackingTitle
		: role === "heading" ? 0.8
		: 0
	font.weight: role === "bodyStrong" || role === "heading" ? Font.DemiBold : Font.Normal

	color: tone === "muted" ? Arc.inkMuted
		: tone === "faint" ? Arc.inkFaint
		: tone === "aether" ? Arc.aether
		: tone === "onAether" ? Arc.onAether
		: tone === "alert" ? Arc.bane
		: tone === "ward" ? Arc.ward
		: Arc.ink

	renderType: Text.NativeRendering
	textFormat: Text.PlainText
	elide: Text.ElideRight
}
