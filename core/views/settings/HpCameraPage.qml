pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.hpcamera

// The HP HD Camera built into the ProBook (core/services/HpCamera.qml): the
// colour picture with every control – the standard ones, the spot the
// exposure aims at, the Sunplus unit's three values –, Enhance, the virtual
// camera, the IR camera with its emitter, and unlocking with the face.
SettingsPage {
	id: root

	title: "HP camera"
	description: ""

	signal open(string page)

	readonly property bool has: HpCamera.online
	readonly property var c: HpCamera.controls
	readonly property bool autoExposure: HpCamera.shown("v4l2", "auto_exposure", 3) !== 1
	readonly property bool autoWb: HpCamera.shown("v4l2", "white_balance_automatic", 1) === 1
	property bool aiming: false
	property string faceName: ""

	onActiveChanged: HpCamera.watching = root.active
	Component.onDestruction: HpCamera.watching = false

	component Control: ValueSlider {
		id: slider

		required property string key
		readonly property var ctl: HpCamera.controls[slider.key] ?? null

		visible: !!slider.ctl
		from: slider.ctl?.min ?? 0
		to: slider.ctl?.max ?? 1
		step: Math.max(1, slider.ctl?.step ?? 1)
		value: HpCamera.shown("v4l2", slider.key, slider.ctl?.default ?? 0)
		format: v => `${Math.round(v)}`
		onMoved: v => HpCamera.setControl(slider.key, v)
	}

	component Vendor: ValueSlider {
		id: vendor

		required property string name
		readonly property var xu: HpCamera.xu[vendor.name] ?? null

		visible: !!vendor.xu
		from: vendor.xu?.min ?? 0
		to: vendor.xu?.max ?? 1
		step: vendor.xu?.step ?? 1
		icon: "chip"
		format: v => `${Math.round(v)}`
		value: HpCamera.shown("xu", vendor.name, vendor.xu?.default ?? 0)
		onMoved: v => HpCamera.setXu(vendor.name, v)
	}

	component Info: RowLayout {
		id: line

		required property string label
		required property string text

		visible: line.text !== ""
		Layout.fillWidth: true
		Layout.leftMargin: 12
		spacing: 18

		StyledText {
			Layout.preferredWidth: 120
			text: line.label
			tone: Theme.textMuted
		}

		StyledText {
			Layout.fillWidth: true
			text: line.text
			elide: Text.ElideRight
		}
	}

	function faceText(f) {
		switch (f.result) {
		case "progress": return f.hint ? `${f.samples}/${f.needed} · ${f.hint}` : `${f.samples}/${f.needed}`;
		case "enrolled": return "Added";
		case "timeout": return `Not added · ${f.hint ?? "No face"}`;
		case "working": return "Looking …";
		case "match": return `Recognised · ${(f.score * 100).toFixed(0)} %`;
		case "nomatch": return `Not recognised · ${Math.max(0, f.score * 100).toFixed(0)} %`;
		case "notlive": return "Not lit by the IR light";
		case "noface": return "No face";
		case "nofaces": return "No face added";
		case "busy": return `In use by ${(f.busyBy ?? []).join(", ") || "another program"}`;
		case "cancelled": return "";
		case "error": return f.message ?? "Error";
		}
		return "";
	}

	// ── the picture ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "hpcamera-device"
		title: !HpCamera.scanned ? "Looking for the camera …" : (root.has ? "HP HD Camera" : "Not connected")
		subtitle: root.has ? [HpCamera.info.chip ? `${HpCamera.info.chip}` : "", `Firmware ${HpCamera.device.bcd}`, HpCamera.streamState.readers?.length ? `Virtual camera: ${HpCamera.streamState.readers.join(", ")}` : ""].filter(s => s).join(" · ") : ""
		icon: root.has ? "video" : "video_off"

		trailing: Toggle {
			visible: root.has
			checked: HpCamera.previewOn
			onToggled: on => HpCamera.setOption("preview", on)
		}

		HpCameraPreview {
			Layout.fillWidth: true
			Layout.maximumWidth: 720
			Layout.alignment: Qt.AlignHCenter
			visible: root.has && HpCamera.previewOn
			aiming: root.aiming
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.has
			spacing: 8

			TextButton {
				icon: "camera"
				text: "Photo"
				onActivated: HpCamera.photo(false)
			}

			TextButton {
				visible: HpCamera.view.zoom > 1.01 || HpCamera.view.mirror
				variant: "ghost"
				icon: "magnify_plus_outline"
				text: "Photo of the view"
				onActivated: HpCamera.photo(true)
			}

			Item {
				Layout.fillWidth: true
			}

			StyledText {
				visible: HpCamera.lastShot !== ""
				Layout.maximumWidth: 260
				text: HpCamera.lastShot.split("/").pop()
				tone: Theme.textMuted
				elide: Text.ElideMiddle
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: HpCamera.error !== ""
			text: HpCamera.error
			tone: Theme.danger
			wrapMode: Text.WordWrap
		}
	}

	// ── Enhance ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "hpcamera-enhance"
		visible: root.has
		title: "Enhance"
		subtitle: HpCamera.enhancing.status === "working" ? (HpCamera.enhancing.step || "…") : (HpCamera.enhancing.status === "failed" ? (HpCamera.enhancing.message ?? "") : "")
		icon: "auto_fix"

		trailing: RowLayout {
			spacing: 8

			Spinner {
				visible: HpCamera.enhancing.status === "working"
				Layout.preferredWidth: 20
				Layout.preferredHeight: 20
			}

			TextButton {
				visible: HpCamera.enhancing.status === "working"
				variant: "ghost"
				icon: "close"
				text: "Cancel"
				onActivated: HpCamera.cancelEnhance()
			}

			TextButton {
				visible: HpCamera.lastEnhance.length > 0 && HpCamera.enhancing.status !== "working"
				variant: "ghost"
				icon: "restore"
				text: "Undo"
				onActivated: HpCamera.undoEnhance()
			}

			TextButton {
				visible: HpCamera.enhancing.status !== "working"
				enabled: !HpCamera.enhanceAi || HpCamera.enhanceModel !== ""
				variant: "filled"
				icon: "auto_fix"
				text: "Enhance"
				onActivated: HpCamera.enhance()
			}
		}

		FlagRow {
			icon: "robot_outline"
			title: "With a local AI"
			subtitle: HpCamera.enhanceAi && HpCamera.models.length === 0 ? "No local model that sees pictures" : ""
			checked: HpCamera.enhanceAi
			onToggled: on => HpCamera.setOption("enhanceAi", on)
		}

		Segmented {
			Layout.fillWidth: true
			visible: HpCamera.enhanceAi && HpCamera.models.length > 1
			options: HpCamera.models.map(m => ({ value: m.name, label: m.name }))
			current: HpCamera.enhanceModel
			onSelected: value => HpCamera.setOption("enhanceModel", value)
		}

		Repeater {
			model: HpCamera.enhancing.status === "done" || HpCamera.enhancing.status === "failed" ? (HpCamera.enhancing.changes ?? []) : []

			delegate: RowLayout {
				id: change

				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12
				spacing: 12

				StyledText {
					Layout.preferredWidth: 170
					text: (HpCamera.controls[change.modelData.key]?.name ?? change.modelData.key)
				}

				StyledText {
					Layout.preferredWidth: 90
					text: `${change.modelData.from} → ${change.modelData.to}`
					tabular: true
				}

				StyledText {
					Layout.fillWidth: true
					text: change.modelData.why ?? ""
					tone: Theme.textMuted
					elide: Text.ElideRight
				}
			}
		}

		StyledText {
			Layout.leftMargin: 12
			visible: HpCamera.enhancing.status === "done" && (HpCamera.enhancing.changes ?? []).length === 0
			text: "Nothing to change"
			tone: Theme.textMuted
		}
	}

	// ── picture controls ───────────────────────────────────────────────────
	SettingCard {
		anchor: "hpcamera-picture"
		visible: root.has
		title: "Picture"
		icon: "brightness_6"

		Control { key: "brightness"; icon: "brightness_6"; label: "Brightness" }
		Control { key: "contrast"; icon: "contrast_box"; label: "Contrast" }
		Control { key: "saturation"; icon: "image_filter_hdr"; label: "Saturation" }
		Control { key: "hue"; icon: "palette_outline"; label: "Hue" }
		Control {
			key: "gamma"
			icon: "chart_bell_curve_cumulative"
			label: "Gamma"
			format: v => (v / 100).toFixed(2)
		}
		Control { key: "sharpness"; icon: "blur_linear"; label: "Sharpness" }
		Control { key: "gain"; icon: "brightness_7"; label: "Gain" }

		FlagRow {
			visible: !!root.c.white_balance_automatic
			icon: "white_balance_sunny"
			title: "Automatic white balance"
			checked: root.autoWb
			onToggled: on => HpCamera.setControl("white_balance_automatic", on ? 1 : 0)
		}

		Control {
			key: "white_balance_temperature"
			visible: !!ctl && !root.autoWb
			icon: "white_balance_sunny"
			label: "Colour temperature"
			format: v => `${Math.round(v)} K`
		}

		FlagRow {
			visible: !!root.c.backlight_compensation
			icon: "brightness_auto"
			title: "Backlight compensation"
			checked: HpCamera.shown("v4l2", "backlight_compensation", 0) === 1
			onToggled: on => HpCamera.setControl("backlight_compensation", on ? 1 : 0)
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: !!root.c.power_line_frequency
			spacing: 12

			Glyph {
				icon: "sine_wave"
				color: Theme.textMuted
			}

			StyledText {
				Layout.fillWidth: true
				text: "Anti-flicker"
			}

			Segmented {
				Layout.preferredWidth: 240
				options: (root.c.power_line_frequency?.menu ?? []).map(m => ({ value: String(m.value), label: m.value === 0 ? "Off" : m.name }))
				current: String(HpCamera.shown("v4l2", "power_line_frequency", 2))
				onSelected: value => HpCamera.setControl("power_line_frequency", Number(value))
			}
		}
	}

	// ── exposure ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "hpcamera-exposure"
		visible: root.has
		title: "Exposure"
		icon: "camera_iris"

		FlagRow {
			visible: !!root.c.auto_exposure
			icon: "brightness_auto"
			title: "Automatic exposure"
			checked: root.autoExposure
			onToggled: on => HpCamera.setControl("auto_exposure", on ? 3 : 1)
		}

		Control {
			key: "exposure_time_absolute"
			visible: !!ctl && !root.autoExposure
			icon: "camera_iris"
			label: "Exposure time"
			format: v => v >= 10 ? `${(v / 10).toFixed(v >= 100 ? 0 : 1)} ms` : `${v * 100} µs`
		}

		FlagRow {
			visible: !!root.c.exposure_dynamic_framerate
			icon: "weather_night"
			title: "Low light: slower frame rate"
			checked: HpCamera.shown("v4l2", "exposure_dynamic_framerate", 0) === 1
			onToggled: on => HpCamera.setControl("exposure_dynamic_framerate", on ? 1 : 0)
		}

		FlagRow {
			visible: !!HpCamera.roi && root.autoExposure
			icon: "crosshairs"
			title: "Aim at the spot"
			checked: (HpCamera.shown("roi", "auto", 1) & 1) === 1
			onToggled: on => HpCamera.setSpotAuto(on)
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: !!HpCamera.roi && root.autoExposure && (HpCamera.shown("roi", "auto", 1) & 1) === 1
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: {
					const r = HpCamera.shown("roi", "rect", null);
					const m = HpCamera.roi?.max;
					if (!r || !m || (r[2] >= m[2] && r[3] >= m[3])) return "The whole picture";
					return `${r[2]}×${r[3]} at ${r[0]}, ${r[1]}`;
				}
				tone: Theme.textMuted
			}

			TextButton {
				variant: root.aiming ? "filled" : "ghost"
				icon: "cursor_default_click_outline"
				text: "Place"
				onActivated: root.aiming = !root.aiming
			}

			TextButton {
				variant: "ghost"
				icon: "fullscreen"
				text: "Whole picture"
				onActivated: {
					HpCamera.setSpot(null);
					root.aiming = false;
				}
			}
		}
	}

	// ── Sunplus' own unit ──────────────────────────────────────────────────
	SettingCard {
		anchor: "hpcamera-vendor"
		visible: root.has && Object.keys(HpCamera.xu).length > 0
		title: "Sunplus"
		icon: "chip"

		Vendor { name: "sunplus2"; label: "Selector 2" }
		Vendor { name: "sunplus3"; label: "Selector 3" }
		Vendor { name: "sunplus4"; label: "Selector 4" }
	}

	// ── the IR camera ──────────────────────────────────────────────────────
	SettingCard {
		anchor: "hpcamera-ir"
		visible: root.has && HpCamera.device.ir !== ""
		title: "IR camera"
		subtitle: (HpCamera.info.faceAuth ?? []).map(f => f.mode).filter(s => s).map(s => s.charAt(0).toUpperCase() + s.slice(1)).join(" · ")
		icon: "eye_outline"

		trailing: Toggle {
			checked: HpCamera.irPreviewOn
			onToggled: on => HpCamera.setOption("irPreview", on)
		}

		Segmented {
			Layout.fillWidth: true
			visible: HpCamera.irPreviewOn
			options: [{ value: "lit", label: "Lit" }, { value: "dark", label: "Dark" }, { value: "difference", label: "Lit − dark" }]
			current: HpCamera.irMode
			onSelected: value => HpCamera.setOption("irMode", value)
		}

		HpIrPreview {
			Layout.fillWidth: true
			Layout.maximumWidth: 720
			Layout.alignment: Qt.AlignHCenter
			visible: HpCamera.irPreviewOn
		}

		RowLayout {
			Layout.fillWidth: true
			visible: HpCamera.irPreviewOn
			spacing: 8

			TextButton {
				icon: "camera"
				text: "IR photo"
				onActivated: HpCamera.irPhoto()
			}

			Item {
				Layout.fillWidth: true
			}
		}

		FlagRow {
			visible: (HpCamera.irControls?.metadataMax ?? 0) > 0
			icon: "tag_outline"
			title: "Frame metadata"
			checked: HpCamera.shown("ir", "metadata", 0) > 0
			onToggled: on => HpCamera.setIr("metadata", on ? (HpCamera.irControls?.metadataMax ?? 1) : 0)
		}
	}

	// ── the face ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "hpcamera-face"
		visible: root.has || HpCamera.faces.length > 0
		title: "Unlock with the face"
		subtitle: HpCamera.irState.modelError ?? ""
		icon: "face_recognition"

		Repeater {
			model: HpCamera.faces

			delegate: RowLayout {
				id: faceRow

				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12
				spacing: 12

				Glyph {
					icon: "face_recognition"
					color: Theme.textMuted
				}

				StyledText {
					Layout.fillWidth: true
					text: faceRow.modelData.name
				}

				StyledText {
					text: faceRow.modelData.added
					tone: Theme.textMuted
				}

				TextButton {
					variant: "danger"
					icon: "delete_outline"
					text: "Delete"
					confirm: true
					onActivated: HpCamera.deleteFace(faceRow.modelData.id)
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.has
			spacing: 8

			Field {
				Layout.fillWidth: true
				visible: !HpCamera.enrolling
				icon: "face_recognition"
				placeholder: "Name"
				text: root.faceName
				onEdited: text => root.faceName = text
				onAccepted: HpCamera.enroll(root.faceName.trim() || "Face")
			}

			StyledText {
				Layout.fillWidth: true
				Layout.leftMargin: 12
				visible: HpCamera.enrolling || HpCamera.irState.task === "test" || (HpCamera.face.kind ?? "") !== ""
				text: root.faceText(HpCamera.face)
				tone: ["timeout", "nomatch", "notlive", "noface", "error", "busy"].includes(HpCamera.face.result) ? Theme.danger : Theme.textMuted
				elide: Text.ElideRight
			}

			Spinner {
				visible: HpCamera.enrolling || HpCamera.irState.task === "test"
				Layout.preferredWidth: 20
				Layout.preferredHeight: 20
			}

			TextButton {
				visible: HpCamera.enrolling || HpCamera.irState.task === "test"
				variant: "ghost"
				icon: "close"
				text: "Cancel"
				onActivated: HpCamera.stopFace()
			}

			TextButton {
				visible: !HpCamera.enrolling && HpCamera.irState.task !== "test" && HpCamera.faces.length > 0
				variant: "ghost"
				icon: "play"
				text: "Test"
				onActivated: {
					if (!HpCamera.irPreviewOn) HpCamera.setOption("irPreview", true);
					HpCamera.testFace();
				}
			}

			TextButton {
				visible: !HpCamera.enrolling && HpCamera.irState.task !== "test"
				variant: "filled"
				icon: "plus"
				text: "Add face"
				onActivated: {
					if (!HpCamera.irPreviewOn) HpCamera.setOption("irPreview", true);
					HpCamera.enroll(root.faceName.trim() || "Face");
					root.faceName = "";
				}
			}
		}

		FlagRow {
			icon: "lock"
			title: "Lock screen"
			subtitle: HpCamera.faceUnlock && !Plugins.on("lock-screen") ? "The lock screen is off" : ""
			enabled: HpCamera.faces.length > 0
			checked: HpCamera.faceUnlock
			onToggled: on => HpCamera.setOption("faceUnlock", on)
		}

		ValueSlider {
			visible: HpCamera.faceUnlock
			from: 1
			to: 10
			step: 1
			icon: "restart"
			label: "Tries on the lock screen"
			format: v => `${Math.round(v)}`
			value: HpCamera.faceTries
			onMoved: v => HpCamera.setOption("faceTries", Math.round(v))
		}

		Repeater {
			model: HpCamera.faceUnlock ? [["lock", "lock_outline", "When locked"], ["sleep", "power_sleep", "After standby"], ["wake", "monitor", "Screens back on"]] : []

			delegate: RowLayout {
				id: startRow

				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12
				Layout.rightMargin: 12
				spacing: 14

				Glyph {
					icon: startRow.modelData[1]
					size: 18
					color: Theme.textMuted
				}

				StyledText {
					Layout.fillWidth: true
					text: startRow.modelData[2]
					font.weight: Font.Medium
				}

				Segmented {
					Layout.preferredWidth: 380
					options: [
						{ value: "auto", label: "Auto" },
						{ value: "Control", label: "Ctrl" },
						{ value: "Shift", label: "Shift" },
						{ value: "Alt", label: "Alt" },
						{ value: "Meta", label: "Super" },
						{ value: "off", label: "Off" }
					]
					current: HpCamera.faceStart[startRow.modelData[0]] ?? "auto"
					onSelected: value => HpCamera.setFaceStart(startRow.modelData[0], value)
				}
			}
		}
	}

	// ── the virtual camera ─────────────────────────────────────────────────
	SettingCard {
		anchor: "hpcamera-virtual"
		visible: root.has
		title: "Virtual camera"
		subtitle: HpCamera.virtual && HpCamera.loopback.node ? `${HpCamera.loopback.node}${HpCamera.streamState.readers?.length ? " · " + HpCamera.streamState.readers.join(", ") : ""}` : ""
		icon: "magnify_plus_outline"

		trailing: RowLayout {
			spacing: 8

			TextButton {
				visible: !HpCamera.loopback.installed
				variant: "filled"
				icon: "download"
				text: "Install v4l2loopback"
				onActivated: HpCamera.system(["loopback", "install"])
			}

			Toggle {
				visible: HpCamera.loopback.installed === true
				checked: HpCamera.virtual
				onToggled: on => HpCamera.setVirtual(on)
			}
		}

		ValueSlider {
			from: 1
			to: 4
			step: 0.05
			icon: "magnify_plus_outline"
			label: "Zoom"
			format: v => `${v.toFixed(2)}×`
			value: HpCamera.view.zoom
			onMoved: v => HpCamera.setView({ zoom: v })
		}

		FlagRow {
			icon: "face_recognition"
			title: "Follow the face"
			checked: HpCamera.view.follow
			onToggled: on => HpCamera.setView({ follow: on })
		}

		FlagRow {
			visible: HpCamera.view.follow
			icon: "face_recognition"
			title: "Frame the face"
			checked: HpCamera.view.frameFace
			onToggled: on => HpCamera.setView({ frameFace: on })
		}

		FlagRow {
			icon: "flip_horizontal"
			title: "Mirror"
			checked: HpCamera.view.mirror
			onToggled: on => HpCamera.setView({ mirror: on })
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 12

			Glyph {
				icon: "video"
				color: Theme.textMuted
			}

			StyledText {
				Layout.fillWidth: true
				text: "Output"
			}

			Segmented {
				Layout.preferredWidth: 300
				options: [{ value: "1280x720", label: "720p" }, { value: "960x540", label: "540p" }, { value: "640x360", label: "360p" }, { value: "640x480", label: "4:3" }]
				current: `${HpCamera.size[0]}x${HpCamera.size[1]}`
				onSelected: value => HpCamera.setOutput(value.split("x").map(Number), null)
			}

			Segmented {
				Layout.preferredWidth: 140
				options: [{ value: "30", label: "30 fps" }, { value: "15", label: "15 fps" }]
				current: String(HpCamera.fps)
				onSelected: value => HpCamera.setOutput(null, Number(value))
			}
		}
	}

	// ── the camera ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "hpcamera-about"
		visible: root.has
		title: "Camera"
		icon: "information_outline"

		Info { label: "Chip"; text: [HpCamera.info.chip, HpCamera.info.maker].filter(s => s).join(" · ") }
		Info { label: "Firmware"; text: `${HpCamera.device.bcd ?? ""} · ${HpCamera.device.serial ?? ""}` }
		Info {
			label: "Formats"
			text: (HpCamera.device.formats?.rgb ?? []).map(f => {
				const big = f.sizes.reduce((a, s) => s.w * s.h > a.w * a.h ? s : a, { w: 0, h: 0, fps: [] });
				return `${f.fourcc} ${f.sizes.length} sizes, up to ${big.w}×${big.h} at ${Math.max(...(big.fps.length ? big.fps : [0]))} fps`;
			}).join(" · ")
		}
		Info {
			label: "IR"
			text: (HpCamera.device.formats?.ir ?? []).map(f => f.sizes.map(s => `${f.fourcc} ${s.w}×${s.h} at ${Math.max(...(s.fps.length ? s.fps : [0]))} fps`).join(", ")).join(" · ")
		}
		Info { label: "Nodes"; text: [HpCamera.device.rgb, HpCamera.device.ir].filter(s => s).join(" · ") }
		Info { label: "USB"; text: `${HpCamera.device.model ?? ""} · port ${HpCamera.device.port ?? ""} · ${HpCamera.device.speed ?? ""} Mb/s · built in` }
		Info { label: "Power"; text: HpCamera.device.autosuspend ? `Sleeps after ${(HpCamera.device.suspendDelay ?? 0) / 1000} s${HpCamera.device.sleeping ? " · asleep" : ""}` : "Always on" }
		Info { label: "Photos"; text: HpCamera.photoDir }

		RowLayout {
			Layout.fillWidth: true
			Layout.topMargin: 6

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				variant: "danger"
				icon: "restore"
				text: "Reset all"
				confirm: true
				onActivated: {
					HpCamera.resetAll();
					root.aiming = false;
				}
			}
		}
	}
}
