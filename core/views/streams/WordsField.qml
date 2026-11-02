pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// Words as chips and a place to type more: Enter or a comma makes a chip,
// Backspace in the empty field takes the last one away.
Rectangle {
	id: root

	property var words: []
	property string placeholder: ""
	signal changedWords(var words)

	function addTyped() {
		const word = input.text.replace(/,\s*$/, "").trim();
		input.text = "";
		if (word && !root.words.includes(word)) root.changedWords(root.words.concat([word]));
	}

	implicitHeight: Math.max(38, flow.implicitHeight + 12)
	radius: Theme.radius.medium
	color: Theme.layer1
	border.width: input.activeFocus ? 2 : 1
	border.color: input.activeFocus ? Theme.primary : Theme.outline

	Behavior on implicitHeight {
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on border.color {
		ColorAnim {}
	}

	MouseArea {
		anchors.fill: parent
		cursorShape: Qt.IBeamCursor
		onClicked: input.forceActiveFocus()
	}

	Flow {
		id: flow

		anchors.fill: parent
		anchors.margins: 6
		spacing: 5

		move: Transition {
			SpatialAnim {
				properties: "x,y"
				duration: Motion.medium
			}
		}

		Repeater {
			model: root.words

			Rectangle {
				id: chip

				required property string modelData
				required property int index

				width: label.implicitWidth + cross.width + 20
				height: 26
				radius: 8
				color: Theme.layer3
				scale: 0.5
				opacity: 0

				Component.onCompleted: {
					scale = 1;
					opacity = 1;
				}

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				StyledText {
					id: label

					anchors.left: parent.left
					anchors.leftMargin: 9
					anchors.verticalCenter: parent.verticalCenter
					text: chip.modelData
					font.pixelSize: Theme.size.label
				}

				Item {
					id: cross

					anchors.right: parent.right
					anchors.rightMargin: 3
					anchors.verticalCenter: parent.verticalCenter
					width: 18
					height: 18

					Glyph {
						anchors.centerIn: parent
						icon: "close"
						size: 12
						color: crossArea.containsMouse ? Theme.text : Theme.textSubtle
					}

					MouseArea {
						id: crossArea

						anchors.fill: parent
						hoverEnabled: true
						onClicked: root.changedWords(root.words.filter((_, i) => i !== chip.index))
					}
				}
			}
		}

		TextInput {
			id: input

			width: Math.max(100, Math.min(flow.width - 4, contentWidth + 24))
			height: 26
			verticalAlignment: TextInput.AlignVCenter
			color: Theme.text
			selectionColor: Theme.primary
			selectedTextColor: Theme.onPrimary
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.label
			clip: true
			onTextEdited: if (text.endsWith(",")) root.addTyped()
			onAccepted: root.addTyped()
			onActiveFocusChanged: if (!activeFocus && text.trim() !== "") root.addTyped()
			Keys.onPressed: event => {
				if (event.key === Qt.Key_Backspace && text === "" && root.words.length > 0) {
					root.changedWords(root.words.slice(0, -1));
					event.accepted = true;
				}
			}

			StyledText {
				anchors.fill: parent
				verticalAlignment: Text.AlignVCenter
				visible: input.text === "" && root.words.length === 0
				text: root.placeholder
				font.pixelSize: Theme.size.label
				tone: Theme.textSubtle
				elide: Text.ElideRight
			}
		}
	}
}
