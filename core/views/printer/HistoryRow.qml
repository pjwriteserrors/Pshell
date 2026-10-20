import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One print that ended: how it ended, its name, when, how long, how much.
RowLayout {
	id: root

	property var item: null
	readonly property string result: root.item?.result ?? ""
	readonly property color tone: root.result === "finished" ? Theme.success : (root.result === "failed" ? Theme.danger : Theme.warning)

	spacing: 10

	Rectangle {
		Layout.preferredWidth: 30
		Layout.preferredHeight: 30
		radius: 15
		color: Qt.alpha(root.tone, 0.15)

		Glyph {
			anchors.centerIn: parent
			icon: root.result === "finished" ? "check" : (root.result === "failed" ? "alert_circle_outline" : "stop")
			size: 15
			color: root.tone
		}
	}

	ColumnLayout {
		Layout.fillWidth: true
		spacing: 0

		StyledText {
			Layout.fillWidth: true
			text: Printer.nameOf(root.item?.name)
			elide: Text.ElideRight
			font.pixelSize: Theme.size.body
			font.weight: Font.DemiBold
		}

		StyledText {
			Layout.fillWidth: true
			text: {
				const item = root.item;
				if (!item) return "";
				const parts = [];
				if (item.ended > 0) parts.push(Qt.formatDateTime(new Date(item.ended), "d MMM, HH:mm"));
				parts.push(Format.duration(Number(item.minutes) * 60));
				if (item.grams > 0) parts.push(`${Math.round(item.grams)} g`);
				if (item.result !== "finished") parts.push(`${item.result} at ${item.progress} %`);
				return parts.join(" · ");
			}
			elide: Text.ElideRight
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
		}
	}

	Row {
		spacing: -6

		Repeater {
			model: root.item?.filaments ?? []

			delegate: Rectangle {
				required property var modelData

				width: 16
				height: 16
				radius: 8
				color: Printer.rgb(modelData.color)
				border.width: 2
				border.color: Theme.bg
			}
		}
	}
}
