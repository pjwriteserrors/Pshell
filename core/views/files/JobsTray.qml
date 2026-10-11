pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What runs: a card per job that slides up from the corner, with its
// progress, speed and what is left, and a way to stop it. Finished jobs
// tick and leave; failed ones stay a little longer.
Item {
	id: root

	readonly property var jobs: Files.jobList.filter(job => job.kind !== "rename" && job.kind !== "mkdir" && job.kind !== "newfile" && job.kind !== "batchrename" && job.kind !== "link" && !(job.state === "done" && Number(job.elapsed) < 0.6))

	height: column.implicitHeight

	ListModel {
		id: model
	}

	// the model follows the jobs: cards come and go one by one
	onJobsChanged: {
		const ids = root.jobs.map(job => job.id);
		for (let i = model.count - 1; i >= 0; i -= 1)
			if (!ids.includes(model.get(i).jobId)) model.remove(i, 1);
		for (const id of ids) {
			let found = false;
			for (let i = 0; i < model.count; i += 1) if (model.get(i).jobId === id) found = true;
			if (!found) model.append({ jobId: id });
		}
	}

	Column {
		id: column

		anchors.bottom: parent.bottom
		width: parent.width
		spacing: 8

		add: Transition {
			ParallelAnimation {
				NumberAnimation {
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.medium
				}
				NumberAnimation {
					property: "scale"
					from: 0.9
					to: 1
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}
		}
		move: Transition {
			NumberAnimation {
				property: "y"
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}

		Repeater {
			model: model

			delegate: Rectangle {
				id: card

				required property string jobId
				readonly property var job: Files.jobs[card.jobId] ?? ({})
				readonly property bool done: card.job.state === "done"
				readonly property bool failed: card.job.state === "failed" || card.job.state === "cancelled"
				readonly property real ratio: card.job.bytesTotal > 0 ? card.job.bytes / card.job.bytesTotal : (card.job.filesTotal > 0 ? card.job.files / card.job.filesTotal : -1)

				width: column.width
				height: body.implicitHeight + 24
				radius: Theme.radius.large
				color: Theme.layer2
				border.width: 1
				border.color: card.failed ? Qt.alpha(Theme.danger, 0.5) : Theme.outline

				Rectangle {
					z: -1
					anchors.fill: parent
					anchors.topMargin: 6
					anchors.bottomMargin: -10
					radius: parent.radius
					color: Theme.shadow
					opacity: 0.35
				}

				ColumnLayout {
					id: body

					x: 14
					y: 12
					width: parent.width - 28
					spacing: 8

					RowLayout {
						Layout.fillWidth: true
						spacing: 10

						Rectangle {
							width: 30
							height: 30
							radius: 10
							color: card.done ? Qt.tint(Theme.layer3, Qt.alpha(Theme.success, 0.3)) : card.failed ? Qt.tint(Theme.layer3, Qt.alpha(Theme.danger, 0.25)) : Theme.primarySoft

							Behavior on color {
								ColorAnim {}
							}

							Glyph {
								anchors.centerIn: parent
								size: 16
								color: card.done ? Theme.success : card.failed ? Theme.danger : Theme.primary
								icon: card.done ? "check" : card.failed ? "alert_circle_outline" : ({ copy: "content_copy", move: "folder_move_outline", auto: "folder_move_outline", trash: "trash_can_outline", delete: "delete_outline", compress: "zip_box_outline", extract: "package_variant", download: "download", paste: "content_paste", undo: "undo", restore: "restore", emptytrash: "delete_sweep_outline" })[card.job.kind] ?? "cog_outline"
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 1

							StyledText {
								Layout.fillWidth: true
								text: String(card.job.title || "")
								font.weight: Font.DemiBold
								elide: Text.ElideMiddle
							}

							StyledText {
								Layout.fillWidth: true
								tone: card.failed ? Theme.danger : Theme.textSubtle
								font.pixelSize: Theme.size.small
								elide: Text.ElideMiddle
								text: {
									const job = card.job;
									if (job.state === "failed") return job.error || "Failed";
									if (job.state === "cancelled") return "Stopped";
									if (job.state === "done") return job.skipped > 0 ? `Done, ${job.skipped} skipped` : "Done";
									if (job.state === "preparing") return "Counting…";
									if (job.state === "conflict") return "Waits for an answer";
									const parts = [];
									if (job.bytesTotal > 0) parts.push(`${Files.sizeText(job.bytes)} of ${Files.sizeText(job.bytesTotal)}`);
									else if (job.filesTotal > 1) parts.push(`${job.files} of ${job.filesTotal}`);
									if (job.speed > 0 && job.bytesTotal > 0) parts.push(`${Files.sizeText(job.speed)}/s`);
									if (job.eta > 2) parts.push(job.eta > 90 ? `${Math.round(job.eta / 60)} min left` : `${Math.round(job.eta)} s left`);
									return parts.join(" · ") || String(job.current || "");
								}
							}
						}

						IconButton {
							visible: !card.done && !card.failed
							width: 28
							height: 28
							iconSize: 15
							icon: "close"
							onClicked: Files.cancel(card.jobId)
						}
					}

					// the bar: exact where the size is known, running otherwise
					Rectangle {
						visible: !card.done && !card.failed
						Layout.fillWidth: true
						height: 5
						radius: 3
						color: Theme.layer3
						clip: true

						Rectangle {
							visible: card.ratio >= 0
							width: parent.width * Math.max(0.02, card.ratio)
							height: parent.height
							radius: 3
							color: card.job.state === "conflict" ? Theme.warning : Theme.primary

							Behavior on width {
								Anim {
									duration: Motion.medium
								}
							}
						}

						Rectangle {
							visible: card.ratio < 0
							width: parent.width * 0.3
							height: parent.height
							radius: 3
							color: Theme.primary

							SequentialAnimation on x {
								loops: Animation.Infinite
								running: card.ratio < 0 && card.visible

								NumberAnimation {
									from: -card.width * 0.3
									to: card.width
									duration: 1100
									easing.type: Easing.InOutQuad
								}
							}
						}
					}
				}
			}
		}
	}
}
