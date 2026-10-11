pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What VirusTotal says about the files checked: a verdict per file, the
// scanners that flag it, and – for files it has never seen – the offer to
// upload them (which shares them with VirusTotal).
DialogFrame {
	id: root

	property var results: []
	readonly property var unknown: root.results.filter(entry => entry.state === "unknown")

	function open(results) {
		root.results = results;
		root.show();
		keys.forceActiveFocus();
		const bad = results.some(entry => entry.state === "malicious");
		Sounds.play(bad ? "error" : "taskDone");
	}

	function tone(state) {
		switch (state) {
		case "malicious": return Theme.danger;
		case "suspicious": return Theme.warning;
		case "clean": return Theme.success;
		default: return Theme.textMuted;
		}
	}

	cardWidth: 560
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
		Keys.onReturnPressed: root.hide()
	}

	ColumnLayout {
		width: parent.width
		spacing: 14

		RowLayout {
			spacing: 12

			Rectangle {
				width: 40
				height: 40
				radius: 13
				readonly property string worst: root.results.some(entry => entry.state === "malicious") ? "malicious" : (root.results.some(entry => entry.state === "suspicious") ? "suspicious" : (root.results.every(entry => entry.state === "clean") ? "clean" : "unknown"))
				color: Qt.tint(Theme.layer2, Qt.alpha(root.tone(worst), 0.2))

				Glyph {
					anchors.centerIn: parent
					icon: parent.worst === "clean" ? "shield_check_outline" : (parent.worst === "unknown" ? "shield_search" : "shield_alert_outline")
					size: 20
					color: root.tone(parent.worst)
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: "VirusTotal"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: root.results.length === 1 ? root.results[0].name : `${root.results.length} files`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}
		}

		Flickable {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(440, list.implicitHeight)
			contentHeight: list.implicitHeight
			clip: true
			boundsBehavior: Flickable.StopAtBounds

			ScrollBar.vertical: ThinScrollBar {}

			ColumnLayout {
				id: list

				width: parent.width
				spacing: 10

				Repeater {
					model: root.results

					delegate: Rectangle {
						id: entryCard

						required property var modelData
						required property int index
						readonly property color tint: root.tone(entryCard.modelData.state)

						Layout.fillWidth: true
						implicitHeight: entryBody.implicitHeight + 24
						radius: Theme.radius.large
						color: Qt.tint(Theme.layer2, Qt.alpha(entryCard.tint, 0.08))
						border.width: 1
						border.color: Qt.alpha(entryCard.tint, 0.35)
						opacity: 0
						scale: 0.96

						Component.onCompleted: appear.start()

						ParallelAnimation {
							id: appear

							SequentialAnimation {
								PauseAnimation {
									duration: entryCard.index * 70
								}
								ParallelAnimation {
									NumberAnimation {
										target: entryCard
										property: "opacity"
										to: 1
										duration: Motion.medium
									}
									NumberAnimation {
										target: entryCard
										property: "scale"
										to: 1
										duration: Motion.long
										easing.type: Easing.BezierSpline
										easing.bezierCurve: Motion.spatial
									}
								}
							}
						}

						ColumnLayout {
							id: entryBody

							x: 14
							y: 12
							width: parent.width - 28
							spacing: 8

							RowLayout {
								Layout.fillWidth: true
								spacing: 10

								// the share of scanners that flag it, as a ring
								Ring {
									width: 42
									height: 42
									visible: entryCard.modelData.total > 0
									value: entryCard.modelData.total > 0 ? (entryCard.modelData.malicious + entryCard.modelData.suspicious) / entryCard.modelData.total : 0
									color: entryCard.tint
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 1

									StyledText {
										Layout.fillWidth: true
										text: entryCard.modelData.name
										font.weight: Font.DemiBold
										elide: Text.ElideMiddle
									}

									StyledText {
										Layout.fillWidth: true
										tone: entryCard.tint
										font.pixelSize: Theme.size.small
										font.weight: Font.DemiBold
										wrapMode: Text.WordWrap
										text: {
											const entry = entryCard.modelData;
											switch (entry.state) {
											case "malicious": return `${entry.malicious} of ${entry.total} scanners call it malicious${entry.label ? " · " + entry.label : ""}`;
											case "suspicious": return `${entry.suspicious} of ${entry.total} scanners find it suspicious`;
											case "clean": return `None of ${entry.total} scanners flags it`;
											case "unknown": return "VirusTotal has never seen this file";
											default: return entry.error || "It could not be checked";
											}
										}
									}
								}

								IconButton {
									visible: !!entryCard.modelData.link
									width: 30
									height: 30
									iconSize: 15
									icon: "open_in_new"
									onClicked: Qt.openUrlExternally(entryCard.modelData.link)
								}
							}

							// the scanners that flag it
							Flow {
								Layout.fillWidth: true
								visible: (entryCard.modelData.engines ?? []).length > 0
								spacing: 4

								Repeater {
									model: (entryCard.modelData.engines ?? []).slice(0, 14)

									delegate: Rectangle {
										required property var modelData

										width: engineLabel.implicitWidth + 14
										height: 22
										radius: 11
										color: Qt.alpha(modelData.category === "malicious" ? Theme.danger : Theme.warning, 0.14)

										Text {
											id: engineLabel

											anchors.centerIn: parent
											text: `${parent.modelData.engine}: ${parent.modelData.result}`
											color: parent.modelData.category === "malicious" ? Theme.danger : Theme.warning
											font.family: Theme.fontFamily
											font.pixelSize: Theme.size.tiny
										}
									}
								}
							}

							StyledText {
								Layout.fillWidth: true
								visible: !!entryCard.modelData.lastAnalysed
								text: `Last looked at ${Files.whenText(entryCard.modelData.lastAnalysed)}${entryCard.modelData.type ? " · " + entryCard.modelData.type : ""}${entryCard.modelData.uploaded ? " · uploaded just now" : ""}`
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
								elide: Text.ElideRight
							}
						}
					}
				}
			}
		}

		// files nobody has seen: only uploaded when asked
		Rectangle {
			Layout.fillWidth: true
			visible: root.unknown.length > 0 && FileLibrary.setting("vtUpload") !== "never"
			implicitHeight: offer.implicitHeight + 20
			radius: Theme.radius.medium
			color: Theme.layer2

			RowLayout {
				id: offer

				x: 12
				y: 10
				width: parent.width - 24
				spacing: 10

				StyledText {
					Layout.fillWidth: true
					text: "Uploading lets VirusTotal scan it. The file is then shared with VirusTotal and its partners – do not upload anything private."
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}

				TextButton {
					text: root.unknown.length === 1 ? "Upload" : `Upload ${root.unknown.length}`
					icon: "cloud_upload_outline"
					variant: "tonal"
					confirm: true
					onActivated: {
						Files.vtScan(root.unknown.map(entry => entry.path), "yes");
						root.hide();
					}
				}
			}
		}

		RowLayout {
			Layout.alignment: Qt.AlignRight

			TextButton {
				text: "Done"
				variant: "filled"
				onClicked: root.hide()
			}
		}
	}
}
