import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A page of the settings window: its title, then cards in a column that
// scrolls. The cards rise in one after the other each time the page opens;
// reveal(anchor) scrolls to one and lets it glow.
Item {
	id: root

	property string title: ""
	property string description: ""
	property string icon: ""
	property bool active: false
	property bool recording: false
	property real maxWidth: 1060
	default property alias content: column.data
	property alias flickable: flick
	property alias headerTrailing: trailing.data
	// a column on the right that stays while the cards scroll (a preview)
	property alias aside: asideHolder.data
	property real asideWidth: 0

	function cards() {
		const out = [];
		const walk = item => {
			for (const child of item.children) {
				if (typeof child.playEnter === "function" && child.anchor !== undefined) out.push(child);
				else walk(child);
			}
		};
		walk(column);
		return out;
	}

	function reveal(anchor) {
		const card = root.cards().find(item => item.anchor === anchor);
		if (!card) return;
		const y = card.mapToItem(column, 0, 0).y + column.y - 18;
		scroll.to = Math.max(0, Math.min(flick.contentHeight - flick.height, y));
		scroll.restart();
		card.flash();
	}

	onActiveChanged: {
		if (!root.active) return;
		let i = 0;
		for (const card of root.cards()) {
			const top = card.mapToItem(flick, 0, 0).y;
			if (top < flick.height + 40) card.playEnter(Math.min(i, 8) * 45);
			i += 1;
		}
	}

	NumberAnimation {
		id: scroll

		target: flick
		property: "contentY"
		duration: Motion.long
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.emphasized
	}

	Flickable {
		id: flick

		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: parent.width - (root.asideWidth > 0 ? root.asideWidth + 28 : 0)
		contentWidth: width
		contentHeight: body.implicitHeight + 64
		boundsBehavior: Flickable.StopAtBounds
		clip: true
		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: body

			x: root.asideWidth > 0 ? 32 : Math.max(32, (flick.width - root.maxWidth) / 2)
			y: 30
			width: Math.min(root.maxWidth, flick.width - (root.asideWidth > 0 ? 36 : 64))
			spacing: 22

			RowLayout {
				Layout.fillWidth: true
				spacing: 16

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 4

					StyledText {
						Layout.fillWidth: true
						text: root.title
						font.pixelSize: 26
						font.weight: Font.Bold
					}

					StyledText {
						Layout.fillWidth: true
						visible: root.description !== ""
						text: root.description
						tone: Theme.textMuted
						wrapMode: Text.WordWrap
					}
				}

				Row {
					id: trailing

					Layout.alignment: Qt.AlignBottom
					spacing: 8
				}
			}

			ColumnLayout {
				id: column

				Layout.fillWidth: true
				spacing: 16
			}
		}
	}

	Item {
		id: asideHolder

		visible: root.asideWidth > 0
		anchors.right: parent.right
		anchors.rightMargin: 28
		anchors.top: parent.top
		anchors.topMargin: 30
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 28
		width: root.asideWidth
		opacity: root.active ? 1 : 0
		transform: Translate {
			x: root.active ? 0 : 30

			Behavior on x {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}
	}
}
