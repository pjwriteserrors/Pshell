pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Saving with choices: the format, its quality, a smaller size, a
// watermark, what the camera wrote, and where. The size the file will
// have is worked out while the choices change (the result is rendered
// once when the dialog opens).
Item {
	id: root

	property bool open: false
	property string src: ""
	property bool rendering: false
	property int estimate: -1
	property int estimateId: 0

	property string format: "same"
	property real quality: 92
	property string sizeMode: "full"
	property int longest: 2560
	property int percent: 50
	property bool marked: false
	property string markText: ""
	property string markWhere: "bottomright"
	property real markOpacity: 0.5
	property bool metadata: true
	property bool location: true
	property string target: ""

	readonly property string effectiveFormat: root.format === "same" ? Viewer.extensionFor("same", Viewer.path).replace("jpg", "jpeg").replace("tif", "tiff") : root.format
	readonly property bool lossy: ["jpeg", "webp", "avif"].includes(root.effectiveFormat)

	function show() {
		root.format = Viewer.setting("format", "same");
		root.quality = Viewer.setting("quality", 92);
		const resize = Viewer.setting("resize", null);
		root.sizeMode = resize?.longest ? "longest" : (resize?.percent ? "percent" : "full");
		if (resize?.longest) root.longest = resize.longest;
		if (resize?.percent) root.percent = resize.percent;
		const mark = Viewer.setting("watermark", null);
		root.marked = !!mark;
		if (mark) {
			root.markText = mark.text ?? "";
			root.markWhere = mark.position ?? "bottomright";
			root.markOpacity = mark.opacity ?? 0.5;
		}
		root.metadata = Viewer.setting("metadata", true);
		root.location = Viewer.setting("location", true);
		root.target = "";
		root.estimate = -1;
		root.open = true;
		root.rendering = true;
		const out = `${Viewer.workDir}/estimate-${Date.now()}.tiff`;
		Viewer.renderer.render(out, ok => {
			root.rendering = false;
			if (!ok) return;
			root.src = out;
			root.measure();
		});
	}

	function close() {
		root.open = false;
		if (root.src) Qt.callLater(() => Quickshell.execDetached(["rm", "-f", root.src]));
		root.src = "";
	}

	function resize() {
		if (root.sizeMode === "longest") return { longest: root.longest };
		if (root.sizeMode === "percent") return { percent: root.percent };
		if (root.sizeMode === "larger") return { percent: root.larger * 100, upscale: true };
		return null;
	}

	// larger than it is: Real-ESRGAN when it is set up, otherwise smoothly
	property int larger: 2
	property var upscaler: null



	function watermark() {
		return root.marked && root.markText.trim() ? { text: root.markText.trim(), position: root.markWhere, opacity: root.markOpacity, size: 0.05 } : null;
	}

	function options() {
		return { format: root.format, quality: Math.round(root.quality), resize: root.sizeMode === "larger" ? null : root.resize(), upscale: root.sizeMode === "larger" ? root.larger : 0, watermark: root.watermark(), metadata: root.metadata, location: root.location };
	}

	function measure() {
		if (!root.src) return;
		measureTimer.restart();
	}

	Timer {
		id: measureTimer

		interval: 140
		onTriggered: {
			const id = Viewer.request("estimate", { src: root.src, format: root.effectiveFormat, quality: Math.round(root.quality), resize: root.resize() }, (data, error) => {
				if (!data || data.skipped || id !== root.estimateId) return;
				root.estimate = data.bytes ?? -1;
			});
			root.estimateId = id;
		}
	}

	onFormatChanged: root.measure()
	onQualityChanged: root.measure()
	onSizeModeChanged: {
		root.measure();
		if (root.sizeMode === "larger" && !root.upscaler) Viewer.request("upscalestatus", {}, data => root.upscaler = data);
	}
	onLongestChanged: root.measure()
	onPercentChanged: root.measure()

	function save() {
		const o = root.options();
		Viewer.setSetting("format", o.format);
		Viewer.setSetting("quality", o.quality);
		Viewer.setSetting("resize", o.resize);
		Viewer.setSetting("watermark", o.watermark);
		Viewer.setSetting("metadata", o.metadata);
		Viewer.setSetting("location", o.location);
		if (root.target) o.target = root.target;
		root.close();
		Viewer.saveCopy(o);
	}

	function chooseTarget() {
		const ext = Viewer.extensionFor(root.format, Viewer.path);
		const stem = (Viewer.current?.name ?? "Picture").replace(/\.[^.]+$/, "");
		Files.pick({ title: "Save the picture as", folder: Viewer.folder || `${Paths.home}/Pictures`, save: `${stem} (edited).${ext}` }, paths => {
			if (paths && paths.length > 0) root.target = String(paths[0]).replace(/^file:\/\//, "");
		});
	}

	visible: root.open || card.opacity > 0

	Rectangle {
		anchors.fill: parent
		color: Theme.scrim
		opacity: root.open ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: root.close()
			onWheel: wheel => wheel.accepted = true
		}
	}

	Rectangle {
		id: card

		anchors.centerIn: parent
		width: 460
		height: form.implicitHeight + 40
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		opacity: root.open ? 1 : 0
		scale: root.open ? 1 : 0.94

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {}
		}

		MouseArea {
			anchors.fill: parent
		}

		Column {
			id: form

			x: 20
			y: 20
			width: parent.width - 40
			spacing: 14

			Row {
				width: parent.width
				spacing: 10

				StyledText {
					text: "Save a copy"
					font.pixelSize: Theme.size.heading
					font.weight: Font.DemiBold
				}

				Item {
					width: parent.width - x - sizeLabel.width
					height: 1
				}

				StyledText {
					id: sizeLabel

					anchors.verticalCenter: parent.verticalCenter
					text: root.rendering ? "Rendering…" : (root.estimate >= 0 ? `about ${Format.bytes(root.estimate)}` : "…")
					tabular: true
					tone: Theme.textMuted
				}
			}

			Segmented {
				width: parent.width
				height: 36
				options: [{ value: "same", label: "As it was" }, { value: "jpeg", label: "JPEG" }, { value: "png", label: "PNG" }, { value: "webp", label: "WebP" }, { value: "avif", label: "AVIF" }]
				current: root.format
				onSelected: value => root.format = value
			}

			TuneSlider {
				width: parent.width
				visible: root.lossy
				label: "Quality"
				icon: "tune_variant"
				from: 0
				to: 1
				value: root.quality / 100
				onMoved: value => root.quality = Math.max(10, Math.round(value * 100))
				onCommitted: value => root.quality = Math.max(10, Math.round(value * 100))
			}

			Segmented {
				width: parent.width
				height: 34
				options: [{ value: "full", label: "Full size" }, { value: "longest", label: `${root.longest} px` }, { value: "percent", label: `${root.percent} %` }, { value: "larger", label: `${root.larger}× larger` }]
				current: root.sizeMode
				onSelected: value => root.sizeMode = value
			}

			Row {
				visible: root.sizeMode === "larger"
				spacing: 8

				Chip {
					text: "2×"
					selected: root.larger === 2
					onClicked: root.larger = 2
				}

				Chip {
					text: "4×"
					selected: root.larger === 4
					onClicked: root.larger = 4
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: root.upscaler?.installed ? "with Real-ESRGAN" : "smoothly enlarged"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}

				TextButton {
					visible: !!root.upscaler && !root.upscaler.installed
					text: "Sharper (set up Real-ESRGAN, ~45 MB)"
					variant: "ghost"
					onActivated: Viewer.request("upscaleinstall", {}, (data, error) => {
						if (error) return Viewer.fail(error);
						root.upscaler = { installed: true, engine: "realesrgan" };
						Viewer.say("Real-ESRGAN is set up", "check");
					})
				}
			}

			Row {
				visible: root.sizeMode === "longest" || root.sizeMode === "percent"
				spacing: 6

				Repeater {
					model: root.sizeMode === "longest" ? [1280, 1920, 2560, 3840] : [25, 50, 75]

					delegate: Chip {
						required property int modelData

						text: root.sizeMode === "longest" ? `${modelData} px` : `${modelData} %`
						selected: root.sizeMode === "longest" ? root.longest === modelData : root.percent === modelData
						onClicked: root.sizeMode === "longest" ? root.longest = modelData : root.percent = modelData
					}
				}
			}

			Row {
				spacing: 10

				Toggle {
					checked: root.marked
					onToggled: checked => root.marked = checked
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: "Watermark"
				}
			}

			Column {
				visible: root.marked
				width: parent.width
				spacing: 8

				Field {
					width: parent.width
					placeholder: "© Your name"
					icon: "water_outline"
					text: root.markText
					onEdited: text => root.markText = text
				}

				Segmented {
					width: parent.width
					height: 32
					options: [{ value: "bottomright", label: "Corner" }, { value: "bottomleft", label: "Left" }, { value: "center", label: "Middle" }, { value: "tile", label: "All over" }]
					current: root.markWhere
					onSelected: value => root.markWhere = value
				}

				TuneSlider {
					width: parent.width
					label: "How visible"
					icon: "opacity"
					from: 0
					to: 1
					value: root.markOpacity
					onMoved: value => root.markOpacity = Math.max(0.05, value)
					onCommitted: value => root.markOpacity = Math.max(0.05, value)
				}
			}

			Row {
				spacing: 10

				Toggle {
					checked: root.metadata
					onToggled: checked => root.metadata = checked
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: "Keep what the camera wrote"
				}
			}

			Row {
				visible: root.metadata
				spacing: 10

				Toggle {
					checked: root.location
					onToggled: checked => root.location = checked
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: "Keep where it was taken"
				}
			}

			Clickable {
				width: parent.width
				height: 44
				onClicked: root.chooseTarget()

				Rectangle {
					anchors.fill: parent
					radius: Theme.radius.medium
					color: Theme.layer2
				}

				Row {
					anchors.verticalCenter: parent.verticalCenter
					x: 12
					spacing: 10

					Glyph {
						icon: "folder_outline"
						size: 18
						color: Theme.textMuted
					}

					StyledText {
						width: form.width - 60
						elide: Text.ElideMiddle
						text: root.target ? root.target : (Viewer.pasted ? "In Pictures" : "Beside the picture, as “(edited)”")
						tone: Theme.textMuted
					}
				}
			}

			Row {
				anchors.right: parent.right
				spacing: 8

				TextButton {
					text: "Cancel"
					variant: "ghost"
					onActivated: root.close()
				}

				TextButton {
					text: "Save"
					icon: "content_save_outline"
					variant: "filled"
					enabled: !root.rendering
					onActivated: root.save()
				}
			}
		}
	}
}
