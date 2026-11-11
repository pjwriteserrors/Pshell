pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.webcam

// The Logitech Webcam C310 (core/services/Webcam.qml): the live picture,
// every control the camera has – the standard ones and Logitech's own in its
// extension units –, Enhance (by rule or a local AI), the LED, the
// microphone, photos and RAW, and the virtual camera with zoom, pan and a
// face followed.
SettingsPage {
	id: root

	title: "Webcam"
	description: ""

	signal open(string page)

	readonly property bool has: Webcam.online
	readonly property var c: Webcam.controls
	readonly property bool autoExposure: Webcam.shown("v4l2", "auto_exposure", 3) !== 1
	readonly property bool autoWb: Webcam.shown("v4l2", "white_balance_automatic", 1) === 1

	onActiveChanged: Webcam.watching = root.active
	Component.onDestruction: Webcam.watching = false

	component Control: ValueSlider {
		id: slider

		required property string key
		property string kind: "v4l2"
		readonly property var ctl: Webcam.controls[slider.key] ?? null

		visible: !!slider.ctl
		from: slider.ctl?.min ?? 0
		to: slider.ctl?.max ?? 1
		step: Math.max(1, slider.ctl?.step ?? 1)
		value: Webcam.shown("v4l2", slider.key, slider.ctl?.default ?? 0)
		format: v => `${Math.round(v)}`
		onMoved: v => Webcam.setControl(slider.key, v)
	}

	component XuFlag: FlagRow {
		id: flag

		required property string name
		property int onValue: 1

		visible: Webcam.xu[flag.name] !== undefined
		checked: Webcam.shown("xu", flag.name, 0) === flag.onValue
		onToggled: on => Webcam.setXu(flag.name, on ? flag.onValue : 0)
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

	// ── the picture ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "webcam-device"
		title: !Webcam.scanned ? "Looking for the camera …" : (root.has ? "Webcam C310" : "Not connected")
		subtitle: root.has ? [`Firmware ${Webcam.info.firmware ?? Webcam.device.bcd}`, Webcam.device.serial, Webcam.streamState.readers?.length ? `Virtual camera: ${Webcam.streamState.readers.join(", ")}` : ""].filter(s => s).join(" · ") : ""
		icon: root.has ? "video" : "video_off"

		trailing: Toggle {
			visible: root.has
			checked: Webcam.previewOn
			onToggled: on => Webcam.setOption("preview", on)
		}

		WebcamPreview {
			Layout.fillWidth: true
			Layout.maximumWidth: 720
			Layout.alignment: Qt.AlignHCenter
			visible: root.has && Webcam.previewOn
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.has
			spacing: 8

			TextButton {
				icon: "camera"
				text: "Photo"
				onActivated: Webcam.photo(false)
			}

			TextButton {
				visible: Webcam.view.zoom > 1.01 || Webcam.view.mirror
				variant: "ghost"
				icon: "magnify_plus_outline"
				text: "Photo of the view"
				onActivated: Webcam.photo(true)
			}

			TextButton {
				visible: Webcam.xu.tde !== undefined
				variant: "ghost"
				icon: "camera_iris"
				text: "RAW"
				onActivated: Webcam.raw()
			}

			Item {
				Layout.fillWidth: true
			}

			StyledText {
				visible: Webcam.lastShot !== ""
				Layout.maximumWidth: 260
				text: Webcam.lastShot.split("/").pop()
				tone: Theme.textMuted
				elide: Text.ElideMiddle
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: Webcam.error !== ""
			text: Webcam.error
			tone: Theme.danger
			wrapMode: Text.WordWrap
		}
	}

	// ── Enhance ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "webcam-enhance"
		visible: root.has
		title: "Enhance"
		subtitle: Webcam.enhancing.status === "working" ? (Webcam.enhancing.step || "…") : (Webcam.enhancing.status === "failed" ? (Webcam.enhancing.message ?? "") : "")
		icon: "auto_fix"

		trailing: RowLayout {
			spacing: 8

			Spinner {
				visible: Webcam.enhancing.status === "working"
				Layout.preferredWidth: 20
				Layout.preferredHeight: 20
			}

			TextButton {
				visible: Webcam.enhancing.status === "working"
				variant: "ghost"
				icon: "close"
				text: "Cancel"
				onActivated: Webcam.cancelEnhance()
			}

			TextButton {
				visible: Webcam.lastEnhance.length > 0 && Webcam.enhancing.status !== "working"
				variant: "ghost"
				icon: "restore"
				text: "Undo"
				onActivated: Webcam.undoEnhance()
			}

			TextButton {
				visible: Webcam.enhancing.status !== "working"
				enabled: !Webcam.enhanceAi || Webcam.enhanceModel !== ""
				variant: "filled"
				icon: "auto_fix"
				text: "Enhance"
				onActivated: Webcam.enhance()
			}
		}

		FlagRow {
			icon: "robot_outline"
			title: "With a local AI"
			subtitle: Webcam.enhanceAi && Webcam.models.length === 0 ? "No local model that sees pictures" : ""
			checked: Webcam.enhanceAi
			onToggled: on => Webcam.setOption("enhanceAi", on)
		}

		Segmented {
			Layout.fillWidth: true
			visible: Webcam.enhanceAi && Webcam.models.length > 1
			options: Webcam.models.map(m => ({ value: m.name, label: m.name }))
			current: Webcam.enhanceModel
			onSelected: value => Webcam.setOption("enhanceModel", value)
		}

		Repeater {
			model: Webcam.enhancing.status === "done" || Webcam.enhancing.status === "failed" ? (Webcam.enhancing.changes ?? []) : []

			delegate: RowLayout {
				id: change

				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12
				spacing: 12

				StyledText {
					Layout.preferredWidth: 170
					text: (Webcam.controls[change.modelData.key]?.name ?? change.modelData.key)
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
			visible: Webcam.enhancing.status === "done" && (Webcam.enhancing.changes ?? []).length === 0
			text: "Nothing to change"
			tone: Theme.textMuted
		}
	}

	// ── picture controls ───────────────────────────────────────────────────
	SettingCard {
		anchor: "webcam-picture"
		visible: root.has
		title: "Picture"
		icon: "brightness_6"

		Control { key: "brightness"; icon: "brightness_6"; label: "Brightness" }
		Control { key: "contrast"; icon: "contrast_box"; label: "Contrast" }
		Control { key: "saturation"; icon: "image_filter_hdr"; label: "Saturation" }
		Control { key: "sharpness"; icon: "blur_linear"; label: "Sharpness" }
		Control { key: "gain"; icon: "brightness_7"; label: "Gain" }

		FlagRow {
			visible: !!root.c.white_balance_automatic
			icon: "white_balance_sunny"
			title: "Automatic white balance"
			checked: root.autoWb
			onToggled: on => Webcam.setControl("white_balance_automatic", on ? 1 : 0)
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
			checked: Webcam.shown("v4l2", "backlight_compensation", 0) === 1
			onToggled: on => Webcam.setControl("backlight_compensation", on ? 1 : 0)
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
				current: String(Webcam.shown("v4l2", "power_line_frequency", 2))
				onSelected: value => Webcam.setControl("power_line_frequency", Number(value))
			}
		}
	}

	// ── exposure ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "webcam-exposure"
		visible: root.has
		title: "Exposure"
		subtitle: Webcam.xu.integration ? `Now ${(Webcam.xu.integration.value / 10).toFixed(1)} ms` : ""
		icon: "camera_iris"

		FlagRow {
			visible: !!root.c.auto_exposure
			icon: "brightness_auto"
			title: "Automatic exposure"
			checked: root.autoExposure
			onToggled: on => Webcam.setControl("auto_exposure", on ? 3 : 1)
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
			checked: Webcam.shown("v4l2", "exposure_dynamic_framerate", 0) === 1
			onToggled: on => Webcam.setControl("exposure_dynamic_framerate", on ? 1 : 0)
		}

		XuFlag { name: "rightLight"; icon: "lightbulb_on_outline"; title: "RightLight" }
		XuFlag { name: "lowLight"; icon: "weather_night"; title: "Low-light priority" }

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: Webcam.xu.sensorGain !== undefined
			spacing: 12

			Glyph {
				icon: "brightness_7"
				color: Theme.textMuted
			}

			StyledText {
				Layout.fillWidth: true
				text: "Sensor boost"
			}

			Segmented {
				Layout.preferredWidth: 240
				options: [{ value: "0", label: "Off" }, { value: "1", label: "×1.8" }, { value: "2", label: "×3" }, { value: "3", label: "×4.8" }]
				current: String(Webcam.shown("xu", "sensorGain", 0))
				onSelected: value => Webcam.setXu("sensorGain", Number(value))
			}
		}
	}

	// ── Logitech's processing ──────────────────────────────────────────────
	SettingCard {
		anchor: "webcam-processing"
		visible: root.has && Object.keys(Webcam.xu).length > 0
		title: "Processing"
		icon: "chip"

		XuFlag { name: "colorBoost"; icon: "image_filter_hdr"; title: "Color Boost" }
		XuFlag { name: "gamma"; icon: "contrast_box"; title: "Gamma curve" }
		XuFlag { name: "lensShading"; icon: "blur_radial"; title: "Lens shading correction" }
		XuFlag { name: "defectCorrection"; icon: "dots_grid"; title: "Pixel defect correction" }

		ValueSlider {
			visible: Webcam.xu.tde !== undefined
			from: Webcam.xu.tde?.min ?? 0
			to: Webcam.xu.tde?.max ?? 255
			step: 1
			icon: "grain"
			label: "TDE mode"
			format: v => `${Math.round(v)}`
			value: Webcam.shown("xu", "tde", 0)
			onMoved: v => Webcam.setXu("tde", Math.round(v))
		}

		FlagRow {
			visible: Webcam.xu.mjpegResync !== undefined
			icon: "sine_wave"
			title: "MJPEG resync markers"
			checked: (Webcam.shown("xu", "mjpegResync", [1, 10])[0] ?? 0) === 1
			onToggled: on => Webcam.setXu("mjpegResync", [on ? 1 : 0, Webcam.shown("xu", "mjpegResync", [1, 10])[1] ?? 10])
		}

		ValueSlider {
			visible: Webcam.xu.mjpegResync !== undefined && (Webcam.shown("xu", "mjpegResync", [1, 10])[0] ?? 0) === 1
			from: 1
			to: 255
			step: 1
			icon: "sine_wave"
			label: "Marker interval"
			format: v => `${Math.round(v)}`
			value: Webcam.shown("xu", "mjpegResync", [1, 10])[1] ?? 10
			onMoved: v => Webcam.setXu("mjpegResync", [1, Math.round(v)])
		}
	}

	// ── the virtual camera ─────────────────────────────────────────────────
	SettingCard {
		anchor: "webcam-virtual"
		visible: root.has
		title: "Virtual camera"
		subtitle: Webcam.virtual && Webcam.loopback.node ? `${Webcam.loopback.node}${Webcam.streamState.readers?.length ? " · " + Webcam.streamState.readers.join(", ") : ""}` : ""
		icon: "magnify_plus_outline"

		trailing: RowLayout {
			spacing: 8

			TextButton {
				visible: !Webcam.loopback.installed
				variant: "filled"
				icon: "download"
				text: "Install v4l2loopback"
				onActivated: Webcam.system(["loopback", "install"])
			}

			Toggle {
				visible: Webcam.loopback.installed === true
				checked: Webcam.virtual
				onToggled: on => {
					Webcam.setVirtual(on);
					if (!on && Webcam.loopback.node) Webcam.system(["loopback", "off"]);
				}
			}
		}

		ValueSlider {
			from: 1
			to: 4
			step: 0.05
			icon: "magnify_plus_outline"
			label: "Zoom"
			format: v => `${v.toFixed(2)}×`
			value: Webcam.view.zoom
			onMoved: v => Webcam.setView({ zoom: v })
		}

		FlagRow {
			icon: "face_recognition"
			title: "Follow the face"
			checked: Webcam.view.follow
			onToggled: on => Webcam.setView({ follow: on })
		}

		FlagRow {
			visible: Webcam.view.follow
			icon: "face_recognition"
			title: "Frame the face"
			checked: Webcam.view.frameFace
			onToggled: on => Webcam.setView({ frameFace: on })
		}

		FlagRow {
			icon: "flip_horizontal"
			title: "Mirror"
			checked: Webcam.view.mirror
			onToggled: on => Webcam.setView({ mirror: on })
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
				current: `${Webcam.size[0]}x${Webcam.size[1]}`
				onSelected: value => Webcam.setOutput(value.split("x").map(Number), null)
			}

			Segmented {
				Layout.preferredWidth: 140
				options: [{ value: "30", label: "30 fps" }, { value: "15", label: "15 fps" }]
				current: String(Webcam.fps)
				onSelected: value => Webcam.setOutput(null, Number(value))
			}
		}
	}

	// ── the LED ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "webcam-led"
		visible: root.has && Webcam.led.state !== "missing"
		title: "Light"
		icon: Webcam.led.state === "ok" && Webcam.led.mode === 0 ? "lightbulb_off" : "lightbulb_on_outline"

		trailing: TextButton {
			visible: Webcam.led.state === "locked"
			variant: "filled"
			icon: "lock_open_variant_outline"
			text: "Unlock"
			onActivated: Webcam.system(["led", "on"])
		}

		Segmented {
			Layout.fillWidth: true
			visible: Webcam.led.state === "ok"
			options: [{ value: "3", label: "Auto" }, { value: "1", label: "On" }, { value: "2", label: "Blink" }, { value: "0", label: "Off" }]
			current: String(Webcam.saved.led?.mode ?? Webcam.led.mode ?? 3)
			onSelected: value => Webcam.setLed(Number(value), null)
		}

		ValueSlider {
			visible: Webcam.led.state === "ok" && (Webcam.saved.led?.mode ?? Webcam.led.mode) === 2
			from: 1
			to: 255
			step: 1
			icon: "sine_wave"
			label: "Blink speed"
			format: v => `${Math.round(v)}`
			value: Webcam.saved.led?.frequency ?? Webcam.led.frequency ?? 10
			onMoved: v => Webcam.setLed(null, Math.round(v))
		}

		StyledText {
			Layout.leftMargin: 12
			visible: Webcam.led.state === "error"
			text: Webcam.led.message ?? ""
			tone: Theme.danger
		}

		TextButton {
			visible: Webcam.led.state === "ok"
			variant: "ghost"
			icon: "lock_outline"
			text: "Lock again"
			onActivated: Webcam.system(["led", "off"])
		}
	}

	// ── the microphone ─────────────────────────────────────────────────────
	SettingCard {
		anchor: "webcam-mic"
		visible: root.has && !!Webcam.mic
		title: "Microphone"
		subtitle: Webcam.mic?.isDefault ? "In use as the microphone" : ""
		icon: Webcam.shown("mic", "muted", Webcam.mic?.muted ?? false) ? "microphone_off" : "microphone"

		trailing: RowLayout {
			spacing: 8

			TextButton {
				visible: !(Webcam.mic?.isDefault ?? true)
				variant: "ghost"
				text: "Use as microphone"
				onActivated: Webcam.useAsMicrophone()
			}

			TextButton {
				variant: Webcam.levelOn ? "filled" : "ghost"
				icon: "sine_wave"
				text: "Level"
				onActivated: Webcam.setLevel(!Webcam.levelOn)
			}
		}

		Item {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			visible: Webcam.levelOn
			implicitHeight: 10

			Rectangle {
				anchors.fill: parent
				radius: height / 2
				color: Theme.layer2
			}

			Rectangle {
				height: parent.height
				radius: height / 2
				width: parent.width * Math.max(0, Math.min(1, (Webcam.level + 70) / 70))
				color: Theme.primary

				Behavior on width {
					Anim {
						duration: 80
					}
				}
			}

			Rectangle {
				x: parent.width * Math.max(0, Math.min(1, (Webcam.peak + 70) / 70)) - 1
				width: 2
				height: parent.height
				color: Theme.text
				opacity: 0.5
			}
		}

		ValueSlider {
			from: Webcam.mic?.min ?? 0
			to: Webcam.mic?.max ?? 16
			step: 1
			icon: "microphone"
			label: "Gain"
			format: v => {
				const m = Webcam.mic;
				if (!m || m.dbMin === null || m.max === m.min) return `${Math.round(v)}`;
				return `+${(m.dbMin + (m.dbMax - m.dbMin) * (v - m.min) / (m.max - m.min)).toFixed(1)} dB`;
			}
			value: Webcam.shown("mic", "gain", Webcam.mic?.gain ?? 0) ?? Webcam.mic?.gain ?? 0
			onMoved: v => Webcam.setMic("gain", Math.round(v))
		}

		FlagRow {
			icon: "microphone_off"
			title: "Mute"
			checked: Webcam.saved.mic?.muted ?? Webcam.mic?.muted ?? false
			onToggled: on => Webcam.setMic("muted", on)
		}
	}

	// ── the camera ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "webcam-about"
		visible: root.has
		title: "Camera"
		icon: "information_outline"

		Info { label: "Firmware"; text: Webcam.info.firmware ? `${Webcam.info.firmware} · CRC ${Webcam.info.crc ?? "?"} · EEPROM ${Webcam.info.eeprom ?? "?"}` : "" }
		Info { label: "Sensor"; text: Webcam.info.sensorSize ? `${Webcam.info.sensorSize[0]}×${Webcam.info.sensorSize[1]} · id ${Webcam.info.sensor ?? "?"} · processor ${Webcam.info.processor ?? "?"}` : "" }
		Info { label: "Lens"; text: Webcam.info.fov ? `${Webcam.info.fov[0]}° × ${Webcam.info.fov[1]}°` : "" }
		Info {
			label: "Formats"
			text: (Webcam.device.formats ?? []).map(f => {
				const big = f.sizes.reduce((a, s) => s.w * s.h > a.w * a.h ? s : a, { w: 0, h: 0, fps: [] });
				return `${f.fourcc} ${f.sizes.length} sizes, up to ${big.w}×${big.h} at ${Math.max(...(big.fps.length ? big.fps : [0]))} fps`;
			}).join(" · ")
		}
		Info { label: "USB"; text: `${Webcam.device.model ?? ""} · port ${Webcam.device.port ?? ""} · ${Webcam.device.speed ?? ""} Mb/s` }
		Info { label: "Power"; text: Webcam.device.autosuspend ? `Sleeps after ${(Webcam.device.suspendDelay ?? 0) / 1000} s${Webcam.device.sleeping ? " · asleep" : ""}` : "Always on" }
		Info { label: "Photos"; text: Webcam.photoDir }

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
				onActivated: Webcam.resetAll()
			}
		}
	}
}
