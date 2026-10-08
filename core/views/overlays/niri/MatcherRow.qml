pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import "RuleSchema.js" as RuleSchema

// One `match` or `exclude` line: its conditions, all of which must hold.
// Text ones are regexes (with a nudge to make them exact), the others say
// yes or no. A line that takes away (`exclude`) is shown in red.
Rectangle {
	id: root

	property string kind: "window"
	property var node: ({ name: "match", args: [], props: {} })
	readonly property bool excluding: root.node.name === "exclude"
	readonly property var keys: Object.keys(root.node.props || {})

	signal changed(var node)
	signal removed

	function withProps(props) {
		return Object.assign({}, root.node, { props: props });
	}

	function setProp(name, value) {
		const props = Object.assign({}, root.node.props || {});
		if (value === undefined) delete props[name];
		else props[name] = value;
		root.changed(root.withProps(props));
	}

	function quoteRegex(text) {
		return String(text).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	}

	Layout.fillWidth: true
	implicitHeight: flow.implicitHeight + 20
	radius: Theme.radius.large
	color: root.excluding ? Qt.alpha(Theme.danger, 0.08) : Theme.layer2
	border.width: 1
	border.color: root.excluding ? Qt.alpha(Theme.danger, 0.3) : Theme.outline

	Flow {
		id: flow

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 10
		anchors.rightMargin: 40
		spacing: 6

		// match ⇄ except
		Clickable {
			implicitWidth: kindLabel.implicitWidth + 20
			implicitHeight: 32
			radius: 16
			color: root.excluding ? Theme.danger : Theme.primary
			onClicked: root.changed(Object.assign({}, root.node, { name: root.excluding ? "match" : "exclude" }))

			StyledText {
				id: kindLabel

				anchors.centerIn: parent
				text: root.excluding ? "Except" : "Match"
				tone: Theme.onPrimary
				font.weight: Font.Bold
				font.pixelSize: Theme.size.label
			}
		}

		Repeater {
			model: root.keys

			delegate: Item {
				id: cond

				required property string modelData
				readonly property var meta: RuleSchema.matchers(root.kind).find(m => m.name === cond.modelData) ?? { name: cond.modelData, label: cond.modelData, type: "regex" }
				readonly property var value: root.node.props[cond.modelData]

				implicitWidth: cond.meta.type === "regex" ? regexBox.implicitWidth : flagBox.implicitWidth
				implicitHeight: 32

				// a regex: label, field, "exact" nudge
				Rectangle {
					id: regexBox

					visible: cond.meta.type === "regex"
					implicitWidth: regexRow.implicitWidth + 16
					height: 32
					radius: 16
					color: Theme.layer3

					RowLayout {
						id: regexRow

						anchors.verticalCenter: parent.verticalCenter
						x: 10
						spacing: 6

						StyledText {
							text: cond.meta.label
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}

						TextInput {
							id: regexInput

							Layout.preferredWidth: Math.max(60, Math.min(260, contentWidth + 6))
							text: String(cond.value ?? "")
							color: RuleSchema.regex(text) ? Theme.text : Theme.danger
							font.family: Theme.monoFamily
							font.pixelSize: Theme.size.label
							selectByMouse: true
							onEditingFinished: if (text !== String(cond.value ?? "")) root.setProp(cond.modelData, text)
						}

						Clickable {
							implicitWidth: 22
							implicitHeight: 22
							radius: 11
							visible: !/^\^.*\$$/.test(String(cond.value ?? ""))
							onClicked: root.setProp(cond.modelData, `^${root.quoteRegex(cond.value)}$`)

							Glyph {
								anchors.centerIn: parent
								icon: "format_letter_matches"
								size: 13
								color: Theme.textMuted
							}
						}

						Clickable {
							implicitWidth: 22
							implicitHeight: 22
							radius: 11
							onClicked: root.setProp(cond.modelData, undefined)

							Glyph {
								anchors.centerIn: parent
								icon: "close"
								size: 12
								color: Theme.textMuted
							}
						}
					}
				}

				// yes / no
				Clickable {
					id: flagBox

					visible: cond.meta.type !== "regex"
					implicitWidth: flagRow.implicitWidth + 20
					height: 32
					radius: 16
					color: cond.value === false ? Theme.layer3 : Theme.primaryContainer
					onClicked: {
						if (cond.meta.type === "layer") {
							const layers = ["background", "bottom", "top", "overlay"];
							root.setProp(cond.modelData, layers[(layers.indexOf(String(cond.value)) + 1) % layers.length]);
						} else {
							root.setProp(cond.modelData, cond.value === false ? true : false);
						}
					}
					onRightClicked: root.setProp(cond.modelData, undefined)
					onMiddleClicked: root.setProp(cond.modelData, undefined)

					RowLayout {
						id: flagRow

						anchors.centerIn: parent
						spacing: 5

						Glyph {
							visible: cond.meta.type !== "layer"
							icon: cond.value === false ? "close" : "check"
							size: 13
							color: cond.value === false ? Theme.textMuted : Theme.primary
						}

						StyledText {
							text: cond.meta.type === "layer" ? `Layer: ${cond.value}` : (cond.value === false ? `not ${cond.meta.label.toLowerCase()}` : cond.meta.label)
							font.pixelSize: Theme.size.label
							font.weight: Font.Medium
						}
					}
				}
			}
		}

		// add a condition
		Clickable {
			implicitWidth: 32
			implicitHeight: 32
			radius: 16
			color: Theme.layer3
			onClicked: adder.open()

			Glyph {
				anchors.centerIn: parent
				icon: "plus"
				size: 15
				color: Theme.primary
			}

			PickList {
				id: adder

				y: parent.height + 4
				entries: RuleSchema.matchers(root.kind).filter(m => !root.keys.includes(m.name)).map(m => ({ value: m.name, label: m.label, detail: m.type === "regex" ? "a regex" : (m.type === "layer" ? "background, bottom, top, overlay" : "yes or no") }))
				onPicked: value => {
					const meta = RuleSchema.matchers(root.kind).find(m => m.name === value);
					root.setProp(String(value), meta?.type === "regex" ? "" : (meta?.type === "layer" ? "top" : true));
				}
			}
		}
	}

	IconButton {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 8
		implicitWidth: 28
		implicitHeight: 28
		iconSize: 14
		icon: "delete_outline"
		iconColor: Theme.danger
		onClicked: root.removed()
	}
}
