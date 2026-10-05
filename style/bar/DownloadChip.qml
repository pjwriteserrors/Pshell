import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The browsers' downloads as a live activity: a ring that fills, with
// percentage, speed and the time left; a green check once everything is
// through, until the panel was looked at. Clicking opens the downloads in
// the network panel.
BarButton {
	id: root

	readonly property string phase: Downloads.phase
	readonly property bool busy: root.phase === "running" || root.phase === "paused"
	readonly property bool wanted: Plugins.on("downloads") && (root.phase !== "idle" || !Downloads.hideWhenIdle)
	readonly property string label: {
		if (!root.busy) return "";
		const parts = [];
		if (Downloads.showPercent && Downloads.ratio >= 0) parts.push(`${Math.floor(Downloads.ratio * 100)}%`);
		if (root.phase === "paused") return parts.join("");
		if (Downloads.showSpeed) parts.push(Network.formatSpeed(Downloads.speed));
		if (Downloads.eta >= 0) parts.push(Downloads.formatEta(Downloads.eta));
		return parts.join("  ·  ");
	}

	panelId: "control"
	primaryAnchor: false
	tooltip: "Downloads"
	padding: 8
	visible: width > 0.5
	implicitWidth: root.wanted ? content.implicitWidth + root.padding * 2 : 0
	clip: true
	onClicked: toggle("network")

	Behavior on implicitWidth {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	Row {
		id: content

		anchors.verticalCenter: parent.verticalCenter
		spacing: 7
		opacity: root.wanted ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		Item {
			anchors.verticalCenter: parent.verticalCenter
			width: 18
			height: 18

			Ring {
				anchors.fill: parent
				visible: root.busy
				value: Math.max(0, Downloads.ratio)
				thickness: 2.5
				color: root.phase === "paused" ? Theme.textMuted : Theme.primary
				trackColor: Qt.alpha(Theme.text, 0.16)
			}

			// falls through the ring while bytes come in
			Glyph {
				id: arrow

				property real drop: 0

				anchors.horizontalCenter: parent.horizontalCenter
				y: (parent.height - height) / 2 + arrow.drop
				icon: root.phase === "done" ? "check_circle" : (root.phase === "paused" ? "pause" : (root.busy ? "arrow_down_bold" : "download"))
				size: root.busy ? 10 : 17
				color: root.phase === "done" ? Theme.success : (root.phase === "running" ? Theme.primary : Theme.textMuted)

				SequentialAnimation on drop {
					running: root.phase === "running" && root.width > 0.5
					loops: Animation.Infinite
					onRunningChanged: if (!running) arrow.drop = 0
					NumberAnimation {
						from: -2
						to: 2
						duration: 800
						easing.type: Easing.InOutSine
					}
					NumberAnimation {
						from: 2
						to: -2
						duration: 0
					}
				}
			}
		}

		StyledText {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.label !== ""
			text: root.label
			tabular: true
			font.pixelSize: Theme.size.body
			font.weight: Font.DemiBold
		}
	}
}
