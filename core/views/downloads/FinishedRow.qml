import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A download that is through (or failed): what it was, how big, how long it
// took and how fast it came on average; accelerated ones say how much
// faster than one connection. A click opens the file; on the right the
// folder and dismiss, for a failed one *Try again*.
Clickable {
	id: root

	required property string key
	readonly property var item: Downloads.table[root.key] ?? null
	readonly property bool failed: root.item?.state === "failed"
	readonly property bool boosted: root.item?.source === "boost" && root.item?.mode === "boost"
	readonly property real seconds: {
		const item = root.item;
		if (!item) return 0;
		return item.activeTime > 0 ? item.activeTime : Math.max(0.5, ((item.finished || Date.now()) - item.started) / 1000);
	}
	readonly property real bytes: root.item ? Math.max(root.item.total, root.item.received) : 0
	readonly property real speedup: root.boosted && (root.item?.bestSingle ?? 0) > 0 ? root.bytes / root.seconds / root.item.bestSingle : 0

	implicitHeight: 58
	radius: Theme.radius.large
	color: root.hovered ? Theme.layer2 : Theme.layer1
	pressedScale: 0.985
	onClicked: if (!root.failed) Downloads.open(root.key)

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 10
		anchors.rightMargin: 8
		spacing: 10

		Rectangle {
			Layout.preferredWidth: 38
			Layout.preferredHeight: 38
			radius: Theme.radius.medium
			color: Qt.alpha(root.failed ? Theme.danger : (root.boosted ? Theme.primary : Theme.success), 0.14)

			Glyph {
				anchors.centerIn: parent
				icon: root.failed ? "alert_circle_outline" : Downloads.glyphOf(root.item)
				size: 18
				color: root.failed ? Theme.danger : (root.boosted ? Theme.primary : Theme.success)
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 2

			StyledText {
				Layout.fillWidth: true
				text: root.item?.name ?? ""
				elide: Text.ElideMiddle
				font.pixelSize: Theme.size.body
				font.weight: Font.Medium
			}

			StyledText {
				Layout.fillWidth: true
				text: {
					const item = root.item;
					if (!item) return "";
					if (root.failed) return item.error || "Failed";
					const parts = [Format.bytes(root.bytes)];
					if (item.source !== "torrent") {
						parts.push(Format.duration(root.seconds, true));
						parts.push(`Ø ${Format.rate(root.bytes / root.seconds)}`);
					}
					return parts.join("  ·  ");
				}
				font.pixelSize: Theme.size.small
				tone: root.failed ? Theme.danger : Theme.textSubtle
				tabular: true
				elide: Text.ElideRight
			}
		}

		ModeBadge {
			visible: !root.failed && !root.hovered
			mode: root.boosted ? "boost" : (root.item?.source === "torrent" ? "torrent" : "normal")
			text: root.boosted ? (root.speedup > 1.05 ? `×${root.speedup.toFixed(1)}` : "Accelerated") : (root.item?.source === "torrent" ? "Torrent" : "Normal")
		}

		StyledText {
			visible: !root.hovered
			text: root.item?.finished ? Format.ago(root.item.finished) : ""
			font.pixelSize: Theme.size.tiny
			tone: Theme.textFaint
			tabular: true
		}

		Row {
			visible: root.hovered
			spacing: 2

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				iconSize: 16
				visible: root.failed
				icon: "refresh"
				onClicked: Downloads.retry(root.key)
			}

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				iconSize: 16
				visible: !root.failed && (root.item?.path ?? "") !== ""
				icon: "folder_open"
				onClicked: Downloads.reveal(root.key)
			}

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				iconSize: 16
				visible: (root.item?.url ?? "") !== ""
				icon: "content_copy"
				onClicked: Downloads.copyLink(root.key)
			}

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				iconSize: 16
				icon: "close"
				onClicked: Downloads.dismiss(root.key)
			}
		}
	}
}
