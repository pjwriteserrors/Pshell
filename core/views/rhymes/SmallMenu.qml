pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets

// A few things to do, where the pointer is: [{ text, icon, danger, enabled, action }].
Popup {
	id: menu

	property var entries: []

	function show(item, x, y) {
		const p = item.mapToItem(menu.parent, x, y);
		menu.x = Math.min(p.x, (menu.parent?.width ?? 1e6) - menu.width - 8);
		menu.y = Math.min(p.y, (menu.parent?.height ?? 1e6) - menu.implicitHeight - 8);
		menu.open();
	}

	width: 220
	padding: 6
	modal: false
	dim: false
	closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

	enter: Transition {
		ParallelAnimation {
			Anim {
				property: "opacity"
				from: 0
				to: 1
				duration: Motion.short
			}

			SpatialAnim {
				property: "scale"
				from: 0.9
				to: 1
			}
		}
	}

	exit: Transition {
		Anim {
			property: "opacity"
			to: 0
			duration: Motion.micro
		}
	}

	background: Rectangle {
		radius: Theme.radius.large
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
	}

	contentItem: Column {
		spacing: 2

		Repeater {
			model: menu.entries

			Clickable {
				id: entry

				required property var modelData

				width: menu.width - 12
				height: 36
				radius: Theme.radius.medium
				color: "transparent"
				enabled: entry.modelData.enabled !== false
				opacity: enabled ? 1 : 0.4
				onClicked: {
					menu.close();
					entry.modelData.action();
				}

				Row {
					x: 10
					anchors.verticalCenter: parent.verticalCenter
					spacing: 10

					Glyph {
						anchors.verticalCenter: parent.verticalCenter
						icon: entry.modelData.icon || ""
						size: 16
						color: entry.modelData.danger ? Theme.danger : Theme.textMuted
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: entry.modelData.text
						tone: entry.modelData.danger ? Theme.danger : Theme.text
					}
				}
			}
		}
	}
}
