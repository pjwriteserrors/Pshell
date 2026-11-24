pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Widgets
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A wish as a card: the product's picture, name and shop, the price now and
// how far it moved since it was added, its prices over time (lowest and
// highest marked). A click opens the page; the gift picks whom it is for.
Clickable {
	id: root

	required property var wish
	readonly property var drop: Watches.dropOf(root.wish)
	readonly property bool hasPrice: root.wish.price !== null && root.wish.price !== undefined
	readonly property bool trouble: ["missing", "blocked", "error"].includes(root.wish.status)

	signal pickPerson(var wish)

	implicitHeight: body.implicitHeight + 24
	radius: Theme.radius.large
	color: root.hovered ? Theme.layer2 : Theme.layer1
	pressedScale: 0.985
	onClicked: Watches.open(root.wish)

	ColumnLayout {
		id: body

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 12
		anchors.rightMargin: 8
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			ClippingRectangle {
				Layout.preferredWidth: 52
				Layout.preferredHeight: 52
				radius: Theme.radius.medium
				color: Theme.layer2

				Glyph {
					anchors.centerIn: parent
					visible: picture.status !== Image.Ready
					icon: "tag_outline"
					size: 20
					color: Theme.textSubtle
				}

				Image {
					id: picture

					anchors.fill: parent
					source: /^https?:\/\//.test(String(root.wish.image || "")) ? root.wish.image : ""
					sourceSize.width: 104
					sourceSize.height: 104
					fillMode: Image.PreserveAspectCrop
					asynchronous: true
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					Layout.fillWidth: true
					text: Watches.title(root.wish)
					elide: Text.ElideRight
					maximumLineCount: 2
					wrapMode: Text.Wrap
					font.pixelSize: Theme.size.body
					font.weight: Font.Medium
				}

				StyledText {
					Layout.fillWidth: true
					text: root.trouble ? (Watches.statusNames[root.wish.status] ?? "") : Watches.shopOf(root.wish.url)
					font.pixelSize: Theme.size.small
					tone: root.trouble ? Theme.warning : Theme.textSubtle
					elide: Text.ElideRight
				}
			}

			ColumnLayout {
				visible: root.hasPrice
				spacing: 0

				StyledText {
					Layout.alignment: Qt.AlignRight
					text: Watches.money(root.wish.price, root.wish.currency)
					font.pixelSize: Theme.size.title
					font.weight: Font.Bold
					tabular: true
					tone: root.drop < 0 ? Theme.success : Theme.text
				}

				StyledText {
					Layout.alignment: Qt.AlignRight
					visible: Math.abs(root.drop) >= 0.5
					text: `${root.drop < 0 ? "−" : "+"}${Math.round(Math.abs(root.drop))} %`
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
					tabular: true
					tone: root.drop < 0 ? Theme.success : Theme.danger
				}
			}

			ColumnLayout {
				spacing: 0

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: root.wish.for ? "gift" : "gift_outline"
					onClicked: root.pickPerson(root.wish)
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "delete_outline"
					onClicked: Watches.remove(root.wish.id)
				}
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			visible: (root.wish.prices ?? []).length > 0
			spacing: 2

			PriceChart {
				Layout.fillWidth: true
				points: root.wish.prices ?? []
				color: root.drop < 0 ? Theme.success : Theme.primary
				low: Theme.success
				high: Theme.danger
			}

			RowLayout {
				Layout.fillWidth: true
				visible: root.wish.low !== root.wish.high && root.wish.low !== null && root.wish.low !== undefined
				spacing: 12

				Row {
					spacing: 4

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: 6
						height: 6
						radius: 3
						color: Theme.success
					}

					StyledText {
						text: Watches.money(root.wish.low, root.wish.currency)
						font.pixelSize: Theme.size.tiny
						tone: Theme.textMuted
						tabular: true
					}
				}

				Row {
					spacing: 4

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: 6
						height: 6
						radius: 3
						color: Theme.danger
					}

					StyledText {
						text: Watches.money(root.wish.high, root.wish.currency)
						font.pixelSize: Theme.size.tiny
						tone: Theme.textMuted
						tabular: true
					}
				}

				Item {
					Layout.fillWidth: true
				}

				StyledText {
					text: Watches.sinceText(root.wish)
					font.pixelSize: Theme.size.tiny
					tone: Theme.textSubtle
				}
			}
		}
	}
}
