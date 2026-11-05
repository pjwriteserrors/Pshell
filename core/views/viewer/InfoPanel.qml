pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What the picture is: its size, file, when and with what it was taken,
// where (with a map), how its tones are spread, and whether it was made
// here from another one.
Item {
	id: root

	property var histogram: null
	property string description: ""
	property bool describing: false
	signal describeAsked
	// the picture's main colours (the helper's palette), asked when it changes
	property var palette: []

	Connections {
		target: Viewer

		function onShownPathChanged() {
			root.palette = [];
			if (Viewer.shownPath && !Viewer.info?.animated) paletteTimer.restart();
		}
	}

	Timer {
		id: paletteTimer

		interval: 300
		onTriggered: {
			const path = Viewer.shownPath;
			Viewer.request("palette", { path: path, count: 6 }, data => {
				if (data && Viewer.shownPath === path) root.palette = data.colors ?? [];
			});
		}
	}
	readonly property var info: Viewer.info ?? ({})
	readonly property var file: Viewer.current ?? ({})

	function megapixels() {
		const mp = (root.info.width ?? 0) * (root.info.height ?? 0) / 1e6;
		return mp >= 0.1 ? ` · ${mp.toFixed(1)} MP` : "";
	}

	component Fact: Row {
		id: fact

		property string icon: ""
		property string label: ""
		property string value: ""

		visible: fact.value !== ""
		width: parent.width
		spacing: 12

		Glyph {
			icon: fact.icon
			size: 17
			color: Theme.textSubtle
			anchors.verticalCenter: parent.verticalCenter
		}

		Column {
			width: fact.width - 30
			spacing: 1

			StyledText {
				text: fact.label
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
			}

			StyledText {
				width: parent.width
				text: fact.value
				wrapMode: Text.Wrap
				font.pixelSize: Theme.size.body
			}
		}
	}

	Flickable {
		id: flick

		anchors.fill: parent
		contentHeight: column.implicitHeight + 24
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: column

			x: 18
			y: 14
			width: flick.width - 36
			spacing: 14

			StyledText {
				width: parent.width
				text: root.file.name ?? ""
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
				wrapMode: Text.WrapAnywhere
			}

			Histogram {
				width: parent.width
				values: root.histogram
			}

			// its colours: a click copies one
			Row {
				spacing: 6
				visible: root.palette.length > 0

				Repeater {
					model: root.palette

					delegate: Rectangle {
						required property string modelData

						width: 34
						height: 34
						radius: 10
						color: modelData
						border.width: 1
						border.color: Theme.outline
						scale: swatch.containsMouse ? 1.1 : 1

						Behavior on scale {
							SpatialAnim {}
						}

						MouseArea {
							id: swatch

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: {
								Quickshell.execDetached(["wl-copy", parent.modelData]);
								Viewer.say(`${parent.modelData} copied`, "eyedropper_variant");
							}
						}
					}
				}
			}

			// in words, for alt text
			Column {
				width: parent.width
				spacing: 6

				Row {
					spacing: 8

					TextButton {
						text: root.describing ? "Looking at it…" : (root.description ? "Describe again" : "Describe it")
						icon: "creation"
						variant: "tonal"
						busy: root.describing
						onActivated: root.describeAsked()
					}

					TextButton {
						visible: root.description !== ""
						text: "Copy"
						icon: "content_copy"
						variant: "ghost"
						onActivated: {
							Quickshell.execDetached(["wl-copy", root.description]);
							Viewer.say("The description is in the clipboard", "content_copy");
						}
					}
				}

				StyledText {
					width: parent.width
					visible: root.description !== ""
					text: root.description
					wrapMode: Text.Wrap
					tone: Theme.textMuted
				}
			}

			Fact {
				icon: "image_size_select_large"
				label: "Size"
				value: root.info.width ? `${root.info.width} × ${root.info.height} px${root.megapixels()}` : ""
			}

			Fact {
				icon: "file_outline"
				label: "File"
				value: root.info.bytes ? [String(root.info.format ?? "").toUpperCase(), Format.bytes(root.info.bytes), root.info.alpha ? "transparent" : "", root.info.animated ? `${root.info.frames} frames` : ""].filter(v => v).join(" · ") : ""
			}

			Fact {
				icon: "calendar_clock"
				label: "Taken"
				value: String(root.info.taken ?? "")
			}

			Fact {
				icon: "camera_outline"
				label: "Camera"
				value: [root.info.camera, root.info.lens].filter(v => v).join("\n")
			}

			Fact {
				icon: "camera_iris"
				label: "Exposure"
				value: [root.info.exposure, root.info.fnumber, root.info.iso ? `ISO ${root.info.iso}` : "", root.info.focal].filter(v => v).join("  ·  ")
			}

			Fact {
				icon: "map_marker_outline"
				label: "Where"
				value: root.info.gps ? `${Number(root.info.gps.lat).toFixed(5)}, ${Number(root.info.gps.lon).toFixed(5)}` : ""
			}

			Row {
				visible: !!root.info.gps
				spacing: 8

				TextButton {
					text: "On the map"
					icon: "map_outline"
					variant: "tonal"
					onActivated: Qt.openUrlExternally(`https://www.openstreetmap.org/?mlat=${root.info.gps.lat}&mlon=${root.info.gps.lon}#map=16/${root.info.gps.lat}/${root.info.gps.lon}`)
				}

				TextButton {
					text: "Copy without it"
					icon: "map_marker_off_outline"
					variant: "ghost"
					onActivated: Viewer.saveCopy({ location: false })
				}
			}

			Fact {
				icon: "folder_outline"
				label: "Folder"
				value: Viewer.folder
			}

			Fact {
				icon: "image_edit_outline"
				label: "Made here from"
				value: Viewer.madeFrom ? Viewer.madeFrom.slice(Viewer.madeFrom.lastIndexOf("/") + 1) : ""
			}

			TextButton {
				visible: Viewer.madeFrom !== ""
				text: "Change it again from the original"
				icon: "history"
				variant: "tonal"
				onActivated: Viewer.editOriginal()
			}

			Fact {
				icon: "content_save_check_outline"
				label: "Its copy"
				value: Viewer.sidecar.copy ? Viewer.sidecar.copy.slice(Viewer.sidecar.copy.lastIndexOf("/") + 1) + (Viewer.saved ? "" : " (before the latest changes)") : ""
			}
		}
	}
}
