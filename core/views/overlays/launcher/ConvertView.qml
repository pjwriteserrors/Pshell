pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets
import "../../../lib/Convert.js" as Convert

// Launcher >conv: converts the argument while typing (core/lib/Convert.js):
// `5 kg in lb`, `100 usd eur`, `72 f`, `255 in hex`. Without a target every
// unit of the kind is listed. ↑↓ pick a row, Enter copies its number.
ColumnLayout {
	id: root

	property string argument: ""
	property bool active: false
	signal closeRequested
	// replaces the text after ">conv "
	signal argumentRequested(string text)

	readonly property var result: Convert.convert(root.argument, Converter.rates)
	readonly property var rows: root.result.ok ? root.result.rows : []
	// rates are fetched only when a currency is asked for
	readonly property bool money: root.active && root.result.money === true
	readonly property var examples: ["5 kg in lb", "100 usd in eur", "72 f in c", "1/2 cup in ml", "3 h in min", "500 mb in gib", "8 l/100km in mpg", "255 in hex"]

	spacing: 12

	onRowsChanged: list.currentIndex = 0
	onMoneyChanged: if (root.money) Converter.refresh()

	function move(delta) {
		if (root.rows.length > 0) list.currentIndex = Math.max(0, Math.min(root.rows.length - 1, list.currentIndex + delta));
	}

	function handleKey(event) {
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		root.copy(root.rows[list.currentIndex]);
	}

	function copy(row) {
		if (!row) return;
		Quickshell.execDetached(["wl-copy", "--", row.plain]);
		Haptics.play("copied");
		root.closeRequested();
	}

	// what is converted
	Rectangle {
		Layout.fillWidth: true
		implicitHeight: 84
		visible: root.result.ok
		radius: Theme.radius.huge
		color: Theme.layer1

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 20
			anchors.rightMargin: 20
			spacing: 12

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				SectionLabel {
					text: root.result.ok ? `${root.result.kind}  ·  ${root.result.from.name}` : ""
				}

				StyledText {
					Layout.fillWidth: true
					text: root.result.ok ? `${root.result.input} ${root.result.from.symbol}` : ""
					font.pixelSize: 26
					font.weight: Font.Bold
				}
			}

			ColumnLayout {
				spacing: 2

				StyledText {
					Layout.alignment: Qt.AlignRight
					visible: text !== ""
					text: root.result.ok ? root.result.note : ""
					tabular: true
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
				}

				StyledText {
					Layout.alignment: Qt.AlignRight
					visible: root.result.money === true && Converter.date !== ""
					text: Converter.date
					tabular: true
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}
		}
	}

	ListView {
		id: list

		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: root.result.ok
		clip: true
		model: root.rows
		spacing: 4
		boundsBehavior: Flickable.StopAtBounds
		highlightMoveDuration: Motion.short
		ScrollBar.vertical: ThinScrollBar {}

		delegate: Clickable {
			id: row

			required property var modelData
			required property int index
			readonly property bool picked: list.currentIndex === row.index
			// the target that was asked for
			readonly property bool wanted: row.index === 0 && root.result.exact === true

			width: list.width
			implicitHeight: row.wanted ? 76 : 52
			radius: Theme.radius.large
			pressedScale: 0.98
			showHover: false
			color: row.picked ? Theme.primaryContainer : (row.hovered ? Theme.layer1 : "transparent")
			onPointed: list.currentIndex = row.index
			onClicked: root.copy(row.modelData)

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 20
				anchors.rightMargin: 20
				spacing: 8

				StyledText {
					text: row.modelData.text
					tabular: true
					tone: row.wanted ? Theme.primary : Theme.text
					font.pixelSize: row.wanted ? 30 : Theme.size.heading
					font.weight: row.wanted ? Font.Bold : Font.DemiBold
				}

				StyledText {
					Layout.alignment: Qt.AlignBaseline
					text: row.modelData.symbol
					tone: row.wanted ? Theme.primary : Theme.textMuted
					font.pixelSize: row.wanted ? Theme.size.heading : Theme.size.body
					font.weight: Font.DemiBold
				}

				Item {
					Layout.fillWidth: true
				}

				StyledText {
					text: row.modelData.name
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
				}
			}
		}
	}

	// nothing to show yet
	Item {
		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: !root.result.ok

		Flow {
			anchors.left: parent.left
			anchors.right: parent.right
			visible: root.argument.trim() === ""
			spacing: 6

			Repeater {
				model: root.examples

				delegate: Chip {
					required property string modelData
					text: modelData
					onClicked: root.argumentRequested(modelData)
				}
			}
		}

		Glyph {
			anchors.centerIn: parent
			visible: root.argument.trim() === ""
			icon: "swap_horizontal"
			size: 40
			color: Theme.textFaint
		}

		Spinner {
			anchors.centerIn: parent
			width: 22
			height: 22
			visible: root.result.money === true && Converter.loading
		}

		StyledText {
			anchors.centerIn: parent
			visible: text !== ""
			text: {
				if (root.result.money === true) return Converter.failed && !Converter.loading ? "No exchange rates" : "";
				return root.result.message || "";
			}
			tone: Theme.textMuted
		}
	}
}
