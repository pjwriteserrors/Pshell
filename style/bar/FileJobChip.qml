import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The file manager's jobs that take a while (copies, unpacking, uploads,
// scans) as a live activity: a ring that fills and what runs, also while
// the Files window is closed. A click opens the window with its jobs.
BarButton {
	id: root

	// a job shows once it ran a moment; quick ones never flicker by
	readonly property var jobs: Files.activeJobs.filter(job => Number(job.elapsed) > 1.2 && !["rename", "mkdir", "newfile", "batchrename", "link"].includes(job.kind))
	readonly property bool wanted: Files.enabled && root.jobs.length > 0
	readonly property var first: root.jobs[0] ?? null
	readonly property real ratio: {
		let done = 0;
		let total = 0;
		for (const job of root.jobs) {
			if (job.bytesTotal > 0) {
				done += job.bytes;
				total += job.bytesTotal;
			}
		}
		if (total > 0) return done / total;
		const job = root.first;
		return job && job.filesTotal > 0 ? job.files / job.filesTotal : -1;
	}
	readonly property bool paused: root.jobs.length > 0 && root.jobs.every(job => job.paused)
	readonly property bool asking: root.jobs.some(job => job.state === "conflict")
	readonly property string label: {
		if (!root.first) return "";
		if (root.asking) return "A question";
		const parts = [];
		if (root.ratio >= 0) parts.push(`${Math.floor(root.ratio * 100)}%`);
		if (root.jobs.length > 1) parts.push(`${root.jobs.length} jobs`);
		else if (root.first.eta > 0 && root.first.eta < 360000) parts.push(root.first.eta < 60 ? `${Math.ceil(root.first.eta)} s` : `${Math.ceil(root.first.eta / 60)} min`);
		return parts.join("  ·  ");
	}

	tooltip: root.first ? (root.jobs.length > 1 ? root.jobs.map(job => job.title).join("\n") : String(root.first.title)) : "Files"
	padding: 8
	visible: width > 0.5
	implicitWidth: root.wanted ? content.implicitWidth + root.padding * 2 : 0
	clip: true
	onClicked: Files.show({ paths: [], kind: "folders", newTab: false })

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
				value: Math.max(0, root.ratio)
				thickness: 2.5
				color: root.asking ? Theme.warning : (root.paused ? Theme.textMuted : Theme.primary)
				trackColor: Qt.alpha(Theme.text, 0.16)
			}

			Glyph {
				anchors.centerIn: parent
				icon: root.asking ? "help_circle_outline" : (root.paused ? "pause" : "folder")
				size: 10
				color: root.asking ? Theme.warning : (root.paused ? Theme.textMuted : Theme.primary)
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
