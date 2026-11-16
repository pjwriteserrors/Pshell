import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// The Server page's confirm: what is about to happen, why it matters, and
// two buttons – as the NAS page asks before a risky switch. It opens by
// growing in place (`open`), so what it asks about stays in view; only a
// yes sends anything (with X-Pshell-Confirmed, docs/core.md "Identity").
Item {
	id: root

	property bool open: false
	property string title: ""
	property string detail: ""
	property string confirmText: "Go on"
	property string icon: "alert_outline"
	property bool busy: false
	// true: a softer tone for what only ends something small
	property bool mild: false
	signal accepted
	signal cancelled

	Layout.fillWidth: true
	implicitHeight: root.open ? box.implicitHeight : 0
	clip: true
	visible: implicitHeight > 0.5

	Behavior on implicitHeight {
		SpatialAnim {}
	}

	Rectangle {
		id: box

		width: parent.width
		implicitHeight: row.implicitHeight + 22
		radius: Theme.radius.large
		color: root.mild ? Theme.layer2 : Theme.dangerContainer
		opacity: root.open ? 1 : 0
		transform: Translate {
			y: root.open ? 0 : -8

			Behavior on y {
				SpatialAnim {}
			}
		}

		Behavior on opacity {
			Anim {}
		}

		ColumnLayout {
			id: row

			x: 12
			y: 11
			width: parent.width - 24
			spacing: 8

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				Glyph {
					Layout.alignment: Qt.AlignTop
					Layout.topMargin: 1
					icon: root.icon
					size: 17
					color: root.mild ? Theme.textMuted : Theme.danger
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 2

					StyledText {
						Layout.fillWidth: true
						text: root.title
						font.weight: Font.DemiBold
						wrapMode: Text.Wrap
					}

					StyledText {
						Layout.fillWidth: true
						visible: root.detail !== ""
						text: root.detail
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						wrapMode: Text.Wrap
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 6

				Item {
					Layout.fillWidth: true
				}

				TextButton {
					text: "Cancel"
					variant: "ghost"
					implicitHeight: 30
					onActivated: {
						root.open = false;
						root.cancelled();
					}
				}

				TextButton {
					text: root.confirmText
					icon: root.icon
					variant: root.mild ? "filled" : "danger"
					implicitHeight: 30
					busy: root.busy
					onActivated: root.accepted()
				}
			}
		}
	}
}
