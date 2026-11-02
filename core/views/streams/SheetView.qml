pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.games

// One character. What the sheet holds depends on the series' kind: a tabletop hero
// has abilities and hit points, somebody in Minecraft has gear and deaths. What is
// proved stands plainly; what only may be so is marked and waits for a word. A click
// on anything shows where it was said.
Flickable {
	id: root

	property var sheet: null
	property var sections: []
	property color accent: Theme.primary
	property string seriesId: ""
	// the fact whose source is open
	property var opened: null
	property string editing: ""
	// fields opened by hand that have nothing in them yet
	property var opening: []
	readonly property var byField: {
		const out = {};
		for (const fact of root.sheet?.facts ?? []) (out[fact.field] = out[fact.field] ?? []).push(fact);
		return out;
	}
	readonly property int toCheck: (root.sheet?.facts ?? []).filter(fact => fact.state === "maybe").length

	signal changed(var data)

	// the one value of a field: the user's word, then what is proved, then what may be
	function best(field) {
		const facts = root.byField[field] ?? [];
		return facts.find(fact => fact.state === "mine") ?? facts.find(fact => fact.state === "sure") ?? facts[0] ?? null;
	}

	function act(what, args) {
		Streams.call("sheet", Object.assign({ what: what, series: root.seriesId }, args), data => {
			if (data) root.changed(data);
		});
	}

	function setValue(field, value, isList) {
		root.editing = "";
		if (value.trim() !== "") root.act("set", { sheet: root.sheet.id, field: field, value: value.trim(), list: !!isList });
	}

	contentHeight: column.implicitHeight + 40
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}

	onSheetChanged: if (root.sheet?.id !== root.lastSheet) {
		root.lastSheet = root.sheet?.id ?? -1;
		root.opened = null;
		root.opening = [];
	}

	property int lastSheet: -1

	ColumnLayout {
		id: column

		width: root.width - 12
		spacing: 18

		// ── who ─────────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			Rectangle {
				Layout.preferredWidth: 92
				Layout.preferredHeight: 92
				radius: 46
				gradient: Gradient {
					GradientStop {
						position: 0
						color: root.accent
					}
					GradientStop {
						position: 1
						color: Qt.darker(root.accent, 2.4)
					}
				}

				Text {
					anchors.centerIn: parent
					text: (root.sheet?.name ?? "").slice(0, 1).toUpperCase()
					color: "white"
					font.family: Theme.fontFamily
					font.pixelSize: 44
					font.weight: Font.Black
				}
			}
			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				Text {
					Layout.fillWidth: true
					text: root.sheet?.name ?? ""
					color: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: 38
					font.weight: Font.Black
					elide: Text.ElideRight
				}
				StyledText {
					Layout.fillWidth: true
					text: {
						const parts = [];
						if (root.sheet?.player) parts.push(`played by ${root.sheet.player}`);
						const known = (root.sheet?.facts ?? []).filter(fact => fact.state !== "maybe").length;
						parts.push(`${known} ${known === 1 ? "fact" : "facts"}`);
						if (root.toCheck > 0) parts.push(`${root.toCheck} to check`);
						return parts.join(" · ");
					}
					tone: Theme.textMuted
					font.pixelSize: Theme.size.title
				}
			}
			TextButton {
				text: "Remove"
				icon: "delete_outline"
				variant: "ghost"
				confirm: true
				confirmText: "Remove?"
				onActivated: root.act("remove", { id: root.sheet.id })
			}
		}

		// ── the sections of this kind of sheet ──────────────────────────
		Repeater {
			model: root.sections

			ColumnLayout {
				id: section

				required property var modelData
				readonly property var known: section.modelData.fields.filter(field => (root.byField[field.id]?.length ?? 0) > 0 || root.opening.includes(field.id))
				readonly property var unknown: section.modelData.fields.filter(field => !section.known.includes(field))

				Layout.fillWidth: true
				spacing: 10

				Text {
					text: section.modelData.title.toUpperCase()
					color: root.accent
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					font.weight: Font.Black
					font.letterSpacing: 1.4
				}

				Flow {
					Layout.fillWidth: true
					spacing: 10
					visible: section.known.length > 0

					Repeater {
						model: section.known

						Loader {
							id: holder

							required property var modelData

							width: section.modelData.kind === "lists" ? column.width : (section.modelData.kind === "stats" ? 112 : Math.min(column.width, 250))
							sourceComponent: section.modelData.kind === "lists" || modelData.kind === "list" ? listField : (section.modelData.kind === "stats" ? statField : textField)
							onLoaded: item.field = modelData
						}
					}
				}

				// what nobody has said yet takes no room: one click to fill it in
				Flow {
					Layout.fillWidth: true
					spacing: 5
					visible: section.unknown.length > 0

					Repeater {
						model: section.unknown

						Rectangle {
							id: blank

							required property var modelData

							width: blankWord.implicitWidth + 20
							height: 26
							radius: 8
							color: "transparent"
							border.width: 1
							border.color: blankArea.containsMouse ? root.accent : Theme.outline

							Text {
								id: blankWord

								anchors.centerIn: parent
								text: `+ ${blank.modelData.label}`
								color: blankArea.containsMouse ? Theme.text : Theme.textSubtle
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.small
							}
							MouseArea {
								id: blankArea

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: {
									root.opening = root.opening.concat([blank.modelData.id]);
									root.editing = blank.modelData.id;
								}
							}
						}
					}
				}
			}
		}

		// fields made for this one character
		ColumnLayout {
			Layout.fillWidth: true
			spacing: 10

			Text {
				text: "MORE"
				color: root.accent
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				font.weight: Font.Black
				font.letterSpacing: 1.4
			}
			Flow {
				Layout.fillWidth: true
				spacing: 10

				Repeater {
					model: root.sheet?.extra ?? []

					Loader {
						required property var modelData

						width: Math.min(column.width, 250)
						sourceComponent: textField
						onLoaded: item.field = modelData
					}
				}
			}
			Field {
				Layout.preferredWidth: 340
				icon: "plus"
				placeholder: "A field of your own, like Ship or Patron"
				onAccepted: {
					if (text.trim() !== "") root.act("addField", { sheet: root.sheet.id, label: text });
					text = "";
				}
			}
		}

		// ── what the user wrote about them ──────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			visible: (root.sheet?.notes ?? []).length > 0
			spacing: 8

			Text {
				text: "YOUR NOTES"
				color: root.accent
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				font.weight: Font.Black
				font.letterSpacing: 1.4
			}
			Repeater {
				model: root.sheet?.notes ?? []

				StyledText {
					required property var modelData

					Layout.fillWidth: true
					text: modelData.text
					textFormat: Text.MarkdownText
					wrapMode: Text.Wrap
					font.pixelSize: Theme.size.body
				}
			}
		}

		// ── where it was said ───────────────────────────────────────────
		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: sourceColumn.implicitHeight + 28
			visible: !!root.opened
			radius: Theme.radius.large
			color: Theme.layer2

			ColumnLayout {
				id: sourceColumn

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 14
				spacing: 8

				StyledText {
					Layout.fillWidth: true
					text: root.opened?.quote ? `“${root.opened.quote}”` : "You wrote this."
					font.pixelSize: Theme.size.title
					font.italic: !!root.opened?.quote
					wrapMode: Text.Wrap
				}
				StyledText {
					Layout.fillWidth: true
					visible: !!root.opened?.video
					text: `${root.opened?.title ?? ""} · ${Streams.clock(root.opened?.at)}`
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
					elide: Text.ElideRight
				}
				StyledText {
					Layout.fillWidth: true
					visible: root.opened?.state === "maybe"
					text: "This was said, but the name was not in the same breath, so it may be about someone else."
					font.pixelSize: Theme.size.small
					color: Theme.warning
					wrapMode: Text.Wrap
				}
				Flow {
					Layout.fillWidth: true
					spacing: 6

					TextButton {
						visible: !!root.opened?.video
						text: "Go to the moment"
						icon: "play"
						variant: "tonal"
						onActivated: Streams.call("play", { video: root.opened.video, player: "app", at: Math.max(0, root.opened.at - 3) })
					}
					TextButton {
						visible: root.opened?.state === "maybe"
						text: "It's right"
						icon: "check"
						variant: "tonal"
						onActivated: {
							root.act("confirm", { id: root.opened.id });
							root.opened = null;
						}
					}
					TextButton {
						text: "It's wrong"
						icon: "close"
						variant: "ghost"
						onActivated: {
							root.act("reject", { id: root.opened.id });
							root.opened = null;
						}
					}
				}
			}
		}
	}

	// a single value in a line of its own
	Component {
		id: textField

		Rectangle {
			id: cell

			property var field: null
			readonly property var fact: root.best(cell.field?.id ?? "")

			implicitHeight: 68
			height: 68
			radius: Theme.radius.large
			color: cellHover.hovered ? Theme.layer3 : Theme.layer2

			HoverHandler {
				id: cellHover
			}

			ColumnLayout {
				anchors.fill: parent
				anchors.margins: 11
				spacing: 1

				StyledText {
					text: cell.field?.label ?? ""
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
				}
				Loader {
					Layout.fillWidth: true
					active: root.editing === (cell.field?.id ?? "-")
					visible: active
					sourceComponent: TextInput {
						color: Theme.text
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
						Component.onCompleted: forceActiveFocus()
						onAccepted: root.setValue(cell.field.id, text)
						Keys.onEscapePressed: root.editing = ""
					}
				}
				Text {
					Layout.fillWidth: true
					visible: root.editing !== (cell.field?.id ?? "-")
					text: cell.fact?.value ?? "Not said yet"
					color: !cell.fact ? Theme.textFaint : (cell.fact.state === "maybe" ? Theme.warning : Theme.text)
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.title
					font.weight: cell.fact ? Font.Bold : Font.Normal
					elide: Text.ElideRight
				}
			}
			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onClicked: cell.fact ? root.opened = cell.fact : root.editing = cell.field.id
				onDoubleClicked: root.editing = cell.field.id
			}
		}
	}

	// a number, large
	Component {
		id: statField

		Rectangle {
			id: tile

			property var field: null
			readonly property var fact: root.best(tile.field?.id ?? "")

			height: 92
			radius: Theme.radius.large
			color: tileHover.hovered ? Theme.layer3 : Theme.layer2
			scale: tileHover.hovered ? 1.04 : 1

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			HoverHandler {
				id: tileHover
			}

			ColumnLayout {
				anchors.centerIn: parent
				spacing: 0

				Text {
					Layout.alignment: Qt.AlignHCenter
					text: tile.fact?.value ?? "–"
					color: !tile.fact ? Theme.textFaint : (tile.fact.state === "maybe" ? Theme.warning : Theme.text)
					font.family: Theme.fontFamily
					font.pixelSize: 32
					font.weight: Font.Black
				}
				Text {
					Layout.alignment: Qt.AlignHCenter
					Layout.maximumWidth: 100
					text: tile.field?.label ?? ""
					color: Theme.textMuted
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					font.weight: Font.Bold
					elide: Text.ElideRight
				}
			}
			Loader {
				anchors.fill: parent
				active: root.editing === (tile.field?.id ?? "-")
				sourceComponent: Rectangle {
					radius: Theme.radius.large
					color: Theme.layer3

					TextInput {
						anchors.centerIn: parent
						width: parent.width - 12
						horizontalAlignment: TextInput.AlignHCenter
						color: Theme.text
						font.family: Theme.fontFamily
						font.pixelSize: 28
						font.weight: Font.Black
						Component.onCompleted: forceActiveFocus()
						onAccepted: root.setValue(tile.field.id, text)
						Keys.onEscapePressed: root.editing = ""
					}
				}
			}
			MouseArea {
				anchors.fill: parent
				enabled: root.editing !== (tile.field?.id ?? "-")
				cursorShape: Qt.PointingHandCursor
				onClicked: tile.fact ? root.opened = tile.fact : root.editing = tile.field.id
				onDoubleClicked: root.editing = tile.field.id
			}
		}
	}

	// several things
	Component {
		id: listField

		ColumnLayout {
			id: group

			property var field: null
			readonly property var facts: (root.byField[group.field?.id ?? ""] ?? []).slice().sort((a, b) => (a.state === "maybe") - (b.state === "maybe"))

			spacing: 6

			StyledText {
				text: group.field?.label ?? ""
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}
			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: group.facts

					Rectangle {
						id: pill

						required property var modelData
						readonly property bool unsure: modelData.state === "maybe"

						width: pillWord.implicitWidth + 24
						height: 32
						radius: 10
						color: pill.unsure ? "transparent" : Qt.alpha(root.accent, pillArea.containsMouse ? 0.42 : 0.26)
						border.width: pill.unsure ? 1.5 : 0
						border.color: Theme.warning
						scale: 0.6
						opacity: 0

						Component.onCompleted: {
							scale = 1;
							opacity = 1;
						}

						Behavior on scale {
							SpatialAnim {
								duration: Motion.long
							}
						}
						Behavior on opacity {
							Anim {}
						}

						Text {
							id: pillWord

							anchors.centerIn: parent
							text: pill.modelData.value
							color: pill.unsure ? Theme.warning : Theme.text
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.body
							font.weight: Font.DemiBold
						}
						MouseArea {
							id: pillArea

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: root.opened = pill.modelData
						}
					}
				}
				TextInput {
					width: 150
					height: 32
					verticalAlignment: TextInput.AlignVCenter
					color: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.body
					onAccepted: {
						root.setValue(group.field.id, text, true);
						text = "";
					}

					Text {
						anchors.fill: parent
						verticalAlignment: Text.AlignVCenter
						visible: parent.text === ""
						text: group.facts.length === 0 ? "Not said yet, add one" : "Add one"
						color: Theme.textFaint
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.body
					}
				}
			}
		}
	}
}
