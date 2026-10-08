pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A mail or an SMS. A mail opens to its whole text with a click; a code a
// message is about stands beside it, to be copied.
Clickable {
	id: root

	property string from: ""
	property string subject: ""
	property string text: ""
	property string body: ""
	property real at: 0
	property real now: 0
	property bool unseen: false
	property bool expandable: false
	property bool expanded: false
	// its whole text is being fetched
	property bool loading: false
	property bool copied: false

	readonly property string code: Identities.code(`${root.subject} ${root.text}`)

	// the text with its links as links
	function marked(text) {
		const escaped = String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
		return escaped.replace(/(https?:\/\/[^\s<>"')\]]+)/g, '<a href="$1">$1</a>').replace(/\n/g, "<br>");
	}

	implicitHeight: column.implicitHeight + 20
	radius: Theme.radius.medium
	pressedScale: 0.985
	bloom: false
	interactive: root.expandable
	color: root.expanded ? Theme.layer1 : (root.hovered && root.expandable ? Theme.layer1 : "transparent")
	clip: true

	Behavior on implicitHeight {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	Timer {
		id: forget

		interval: 1300
		onTriggered: root.copied = false
	}

	ColumnLayout {
		id: column

		x: 12
		y: 10
		width: parent.width - 24
		spacing: 3

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Rectangle {
				Layout.preferredWidth: root.unseen ? 7 : 0
				Layout.preferredHeight: 7
				radius: 3.5
				color: Theme.primary
				scale: root.unseen ? 1 : 0

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on Layout.preferredWidth {
					Anim {}
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: root.from
				font.weight: root.unseen ? Font.Bold : Font.DemiBold
			}

			StyledText {
				text: Identities.ago(root.at, root.now)
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				tabular: true
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 3

				StyledText {
					Layout.fillWidth: true
					visible: root.subject !== ""
					text: root.subject
					wrapMode: root.expanded ? Text.Wrap : Text.NoWrap
				}

				StyledText {
					Layout.fillWidth: true
					visible: !root.expanded || root.body === ""
					text: root.text
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
					wrapMode: Text.Wrap
					maximumLineCount: root.expandable ? 2 : 5
				}
			}

			// the code it is about
			Clickable {
				visible: root.code !== ""
				Layout.alignment: Qt.AlignVCenter
				implicitHeight: 28
				implicitWidth: chip.implicitWidth + 20
				radius: height / 2
				color: Theme.primarySoft
				tint: Theme.primary
				onClicked: {
					Identities.copy(root.code);
					root.copied = true;
					forget.restart();
				}

				RowLayout {
					id: chip

					anchors.centerIn: parent
					spacing: 6

					StyledText {
						text: root.code
						tone: Theme.primary
						font.family: Theme.monoFamily
						font.weight: Font.Bold
					}

					Glyph {
						icon: root.copied ? "check" : "content_copy"
						size: 13
						color: Theme.primary
					}
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.topMargin: 4
			visible: root.expanded && root.body !== ""
			text: root.marked(root.body)
			textFormat: Text.StyledText
			linkColor: Theme.primary
			tone: Theme.textMuted
			font.pixelSize: Theme.size.label
			wrapMode: Text.Wrap
			elide: Text.ElideNone
			maximumLineCount: 400
			onLinkActivated: link => Qt.openUrlExternally(link)

			HoverHandler {
				cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
			}
		}

		Spinner {
			Layout.alignment: Qt.AlignHCenter
			Layout.topMargin: 4
			Layout.preferredWidth: 16
			Layout.preferredHeight: 16
			visible: root.expanded && root.body === "" && root.loading
		}
	}
}
