pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A popover list to pick one entry from, with a search field when it is
// long. Entries: [{ value, label, detail, icon }]; ↑↓ and Enter work.
Popup {
	id: root

	property var entries: []
	property string current: ""
	property string placeholder: "Search"
	property bool searchable: root.entries.length > 8
	property int at: 0
	readonly property var shown: {
		const q = search.text.trim().toLowerCase();
		if (q === "") return root.entries;
		return root.entries.filter(e => `${e.value} ${e.label} ${e.detail || ""}`.toLowerCase().includes(q));
	}

	signal picked(var value)

	onAboutToShow: {
		search.text = "";
		root.at = Math.max(0, root.entries.findIndex(e => String(e.value) === String(root.current)));
		if (root.searchable) Qt.callLater(() => search.focusInput());
		Qt.callLater(() => list.positionViewAtIndex(root.at, ListView.Center));
	}
	onShownChanged: root.at = 0

	width: 320
	height: Math.min(420, (root.searchable ? 56 : 0) + Math.max(1, root.shown.length) * 44 + 24)
	padding: 10
	modal: true
	dim: false
	closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

	enter: Transition {
		ParallelAnimation {
			NumberAnimation {
				property: "opacity"
				from: 0
				to: 1
				duration: Motion.short
			}
			NumberAnimation {
				property: "scale"
				from: 0.92
				to: 1
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatialFast
			}
		}
	}
	exit: Transition {
		NumberAnimation {
			property: "opacity"
			to: 0
			duration: Motion.short
		}
	}

	background: Rectangle {
		radius: Theme.radius.huge
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
	}

	contentItem: ColumnLayout {
		spacing: 8

		Field {
			id: search

			Layout.fillWidth: true
			visible: root.searchable
			icon: "magnify"
			placeholder: root.placeholder
			onUpPressed: root.at = Math.max(0, root.at - 1)
			onDownPressed: root.at = Math.min(root.shown.length - 1, root.at + 1)
			onAccepted: if (root.shown[root.at]) {
				root.picked(root.shown[root.at].value);
				root.close();
			}
		}

		ListView {
			id: list

			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true
			spacing: 2
			model: root.shown
			currentIndex: root.at
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			delegate: Clickable {
				id: entry

				required property var modelData
				required property int index
				readonly property bool isCurrent: String(entry.modelData.value) === String(root.current)

				width: list.width - 8
				height: 42
				radius: Theme.radius.medium
				color: entry.index === root.at ? Theme.layer3 : "transparent"
				onPointed: root.at = entry.index
				onClicked: {
					root.picked(entry.modelData.value);
					root.close();
				}

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 10
					anchors.rightMargin: 10
					spacing: 10

					Glyph {
						visible: !!entry.modelData.icon
						icon: entry.modelData.icon || ""
						size: 16
						color: entry.isCurrent ? Theme.primary : Theme.textMuted
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: entry.modelData.label
							tone: entry.isCurrent ? Theme.primary : Theme.text
							font.weight: entry.isCurrent ? Font.DemiBold : Font.Normal
						}

						StyledText {
							Layout.fillWidth: true
							visible: !!entry.modelData.detail
							text: entry.modelData.detail || ""
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}

					Glyph {
						visible: entry.isCurrent
						icon: "check"
						size: 15
						color: Theme.primary
					}
				}
			}
		}
	}
}
