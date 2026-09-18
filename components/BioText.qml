import QtQuick

// Two voices, never mixed within one line. Anything that *names* something —
// a title, a label, a reading's unit — is engraved: serif, small capitals,
// widely tracked. Anything a person reads word by word is plain sans.
Text {
	id: label

	// specimen | title | heading | label | body | bodyStrong | caption | mono | reading
	property string role: "body"
	property string tone: "default"   // default | muted | faint | organ | onOrgan | alert | vital

	readonly property bool engraved: role === "specimen" || role === "title"
		|| role === "heading" || role === "label" || role === "reading"

	font.family: role === "mono" ? Bio.mono : engraved ? Bio.serif : Bio.sans
	font.pixelSize: role === "specimen" ? Bio.sizeSpecimen
		: role === "title" ? Bio.sizeTitle
		: role === "heading" ? Bio.sizeHeading
		: role === "reading" ? Bio.sizeTitle
		: role === "label" ? Bio.sizeEyebrow
		: role === "caption" ? Bio.sizeCaption
		: role === "mono" ? Bio.sizeMono
		: Bio.sizeBody
	font.capitalization: engraved && role !== "reading" ? Font.SmallCaps : Font.MixedCase
	font.letterSpacing: role === "label" ? Bio.trackingEyebrow
		: role === "specimen" || role === "title" ? Bio.trackingTitle
		: role === "heading" ? 1.1
		: 0
	font.weight: role === "bodyStrong" || role === "heading" ? Font.DemiBold : Font.Normal

	color: tone === "muted" ? Bio.textMuted
		: tone === "faint" ? Bio.textFaint
		: tone === "organ" ? Bio.organ
		: tone === "onOrgan" ? Bio.onOrgan
		: tone === "alert" ? Bio.necrosis
		: tone === "vital" ? Bio.vital
		: Bio.text

	renderType: Text.NativeRendering
	textFormat: Text.PlainText
	elide: Text.ElideRight
}
