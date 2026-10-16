pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.overlays.mouse
import "../mouse/Controls.js" as Controls

// The Logitech mouse (core/services/Mouse.qml): what its buttons do – by
// app, by gesture – and how it points, scrolls and feels. The drawing on the
// right is the mouse itself, live: press a button and it lights up there.
SettingsPage {
	id: root

	title: Mouse.device ? Mouse.device.name : "Mouse"
	description: Mouse.device ? "What every button does – also per app and by swipe – and how it points, scrolls and feels. Changes reach the mouse at once." : "Logitech mice on a Bolt or Unifying receiver, or on Bluetooth."
	asideWidth: Math.min(380, Math.max(300, root.width * 0.3))
	recording: studio.picker.recording || rulesList.recording

	property string control: "gesture"
	property string app: ""

	onActiveChanged: {
		Mouse.watching = root.active;
		if (root.active) Mouse.refresh();
	}
	Component.onDestruction: Mouse.watching = false

	readonly property var st: Mouse.state
	readonly property bool has: Mouse.online

	// Solaar's line in niri's startup
	readonly property var solaarStartup: NiriSettings.items(["spawn-at-startup", "spawn-sh-at-startup"]).filter(node => JSON.stringify(node.args ?? []).includes("solaar"))

	function setSolaarStartup(on) {
		const list = NiriSettings.items(["spawn-at-startup", "spawn-sh-at-startup"]).map(node => JSON.stringify(node.args ?? []).includes("solaar") ? Object.assign({}, node, { disabled: !on }) : node);
		NiriSettings.setItems(["spawn-at-startup", "spawn-sh-at-startup"], list, on ? "Solaar starts with niri again" : "Solaar no longer starts with niri", "");
	}

	function pick(control) {
		root.control = control;
		root.reveal("mouse-buttons");
	}

	function fmtLeft(hours) {
		if (hours >= 48) return `${Math.round(hours / 24)} days`;
		if (hours >= 2) return `${Math.round(hours)} hours`;
		return `${Math.round(hours * 60)} minutes`;
	}

	function fmtDistance(m) {
		if (!m) return "0 m";
		return m >= 1000 ? `${(m / 1000).toFixed(2)} km` : `${m.toFixed(m < 10 ? 1 : 0)} m`;
	}

	// ── the mouse, live ────────────────────────────────────────────────────
	aside: ColumnLayout {
		anchors.fill: parent
		spacing: 14

		Rectangle {
			Layout.fillWidth: true
			Layout.fillHeight: true
			radius: Theme.radius.huge
			color: Theme.layer1
			clip: true

			// a glow that breathes behind the mouse
			Rectangle {
				anchors.centerIn: figure
				width: parent.width * 0.9
				height: width
				radius: width / 2
				color: Theme.primary
				opacity: 0.06

				SequentialAnimation on scale {
					running: root.active
					loops: Animation.Infinite

					NumberAnimation {
						from: 0.92
						to: 1.04
						duration: 3200
						easing.type: Easing.InOutSine
					}
					NumberAnimation {
						from: 1.04
						to: 0.92
						duration: 3200
						easing.type: Easing.InOutSine
					}
				}
			}

			MouseFigure {
				id: figure

				anchors.fill: parent
				anchors.margins: 36
				anchors.bottomMargin: 92
				selected: root.control
				pressed: Mouse.pressed
				ratchet: root.st.smartshift?.ratchet ?? true
				moving: Mouse.moveControl
				moveX: Mouse.moveX / Mouse.option("swipeDistance", 70)
				moveY: Mouse.moveY / Mouse.option("swipeDistance", 70)
				opacity: root.has ? 1 : 0.4
				onPicked: control => root.pick(control)

				Behavior on opacity {
					Anim {
						duration: Motion.long
					}
				}

				Connections {
					target: Mouse

					function onWheeled(wheel, delta) {
						if (wheel === "main") figure.turnWheel(delta);
						else figure.turnThumb(delta);
					}
				}
			}

			// name, battery, what it is set to
			ColumnLayout {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 18
				spacing: 10

				RowLayout {
					Layout.fillWidth: true
					spacing: 10

					Item {
						Layout.preferredWidth: 40
						Layout.preferredHeight: 40

						Ring {
							anchors.fill: parent
							value: (root.st.battery?.percent ?? 0) / 100
							thickness: 4
							color: (root.st.battery?.percent ?? 100) <= 15 ? Theme.danger : ((root.st.battery?.status ?? "").startsWith("charging") ? Theme.success : Theme.primary)
						}

						Glyph {
							anchors.centerIn: parent
							icon: (root.st.battery?.status ?? "").startsWith("charging") ? "lightning_bolt" : "battery"
							size: 15
							color: Theme.textMuted

							SequentialAnimation on opacity {
								running: (root.st.battery?.status ?? "").startsWith("charging") && root.active
								loops: Animation.Infinite

								Anim {
									to: 0.3
									duration: 900
								}
								Anim {
									to: 1
									duration: 900
								}
							}
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: Mouse.device ? `${root.st.battery?.percent ?? "–"} %` : "No mouse"
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
							tabular: true
						}

						StyledText {
							Layout.fillWidth: true
							text: !Mouse.device ? (Mouse.scanned ? "None found" : "Looking …") : (!Mouse.online ? "Asleep – move it to wake it" : (root.st.battery?.hoursLeft ? `about ${root.fmtLeft(root.st.battery.hoursLeft)} left` : `${root.st.battery?.status ?? ""} · ${Mouse.device.connection === "receiver" ? "Bolt receiver" : Mouse.device.connection}`))
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
							elide: Text.ElideRight
						}
					}

					Column {
						spacing: 2

						StyledText {
							anchors.right: parent.right
							text: `${root.st.dpi?.value ?? "–"}`
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
							tabular: true
						}

						StyledText {
							anchors.right: parent.right
							text: "DPI"
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.tiny
							font.weight: Font.DemiBold
						}
					}
				}
			}

			// what is picked, over the drawing
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 14
				width: pickedRow.implicitWidth + 24
				height: 32
				radius: 16
				color: Theme.layer2

				Behavior on width {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				Row {
					id: pickedRow

					anchors.centerIn: parent
					spacing: 8

					Glyph {
						anchors.verticalCenter: parent.verticalCenter
						icon: Controls.byId(root.control)?.icon ?? "mouse"
						size: 15
						color: Theme.primary
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: Controls.byId(root.control)?.label ?? ""
						font.weight: Font.DemiBold
					}
				}
			}
		}
	}

	// ── nothing to show ────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-none"
		visible: !Mouse.device
		title: Mouse.scanned ? "No Logitech mouse found" : "Looking for the mouse …"
		subtitle: "A Bolt or Unifying receiver plugged in, or the mouse paired over Bluetooth, and it shows up here by itself."
		icon: "mouse"
	}

	// ── Solaar ─────────────────────────────────────────────────────────────
	SettingCard {
		id: solaarCard

		property bool done: false
		property string result: ""

		anchor: "mouse-solaar"
		visible: Mouse.solaar || solaarCard.done
		title: solaarCard.done ? "The shell has the mouse now" : "Solaar is looking after this mouse"
		subtitle: solaarCard.done ? solaarCard.result : "While Solaar runs, it answers the buttons and puts its own settings back each time the mouse wakes up – so the rules here wait. Taking over brings Solaar's settings and rules along."
		icon: solaarCard.done ? "check_circle" : "swap_horizontal"

		Connections {
			target: Mouse

			function onImported(rules, skipped) {
				solaarCard.done = true;
				solaarCard.result = `${rules} ${rules === 1 ? "rule" : "rules"} and Solaar's settings came along${skipped > 0 ? ` (${skipped} it could not read)` : ""}. Solaar no longer starts with niri.`;
				root.setSolaarStartup(false);
				Mouse.play("COMPLETED");
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				visible: solaarCard.done
				variant: "ghost"
				icon: "undo"
				text: "Give it back to Solaar"
				onActivated: {
					root.setSolaarStartup(true);
					Mouse.giveBack();
					solaarCard.done = false;
				}
			}

			TextButton {
				visible: !solaarCard.done
				variant: "filled"
				icon: "swap_horizontal"
				text: "Take over from Solaar"
				onActivated: Mouse.takeOver()
			}
		}
	}

	// ── profiles ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-profiles"
		visible: !!Mouse.device
		title: "Profiles"
		subtitle: Mouse.profiles.length > 1 ? `${Mouse.active?.name ?? ""} is in use${Mouse.automatic ? " (by itself, for what has the focus)" : ""}` : "Whole sets of buttons and settings – for games, for drawing, per app. Make a second one to switch."
		icon: "account_switch_outline"

		ProfileStrip {
			Layout.fillWidth: true
		}
	}

	// ── buttons ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-buttons"
		visible: !!Mouse.device
		title: "Buttons & gestures"
		subtitle: "Pick a control on the mouse, a place and a way to use it. Swipe = hold the button and move the mouse."
		icon: "gesture_tap_button"

		ButtonStudio {
			id: studio

			Layout.fillWidth: true
			control: root.control
			app: root.app
			active: root.active
			onControlPicked: control => root.control = control
			onAppPicked: app => root.app = app
		}

		FlagRow {
			icon: "gesture_swipe"
			title: "Show the gestures while holding"
			subtitle: "Hold a button that has swipes for a moment: what each way does appears in the middle of the screen, and follows the mouse"
			checked: Mouse.option("hud", true)
			onToggled: on => Mouse.setOption("hud", on)
		}
	}

	// ── rules ──────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-rules"
		visible: !!Mouse.device
		title: "Every rule"
		subtitle: Mouse.rules.length === 0 ? "None yet" : `${Mouse.rules.length} ${Mouse.rules.length === 1 ? "rule" : "rules"} · the lit one just happened`
		icon: "format_list_checkbox"

		RuleList {
			id: rulesList

			Layout.fillWidth: true
			picker: studio.picker
			onOpened: (control, app) => {
				root.control = control;
				root.app = app;
			}
		}

		ValueSlider {
			from: 200
			to: 800
			step: 20
			unit: " ms"
			icon: "gesture_tap_hold"
			label: "Hold after"
			value: Mouse.option("holdMs", 420)
			onMoved: v => Mouse.setOption("holdMs", v)
		}

		ValueSlider {
			from: 150
			to: 500
			step: 10
			unit: " ms"
			icon: "gesture_double_tap"
			label: "Double click within"
			value: Mouse.option("doubleMs", 260)
			onMoved: v => Mouse.setOption("doubleMs", v)
		}

		ValueSlider {
			from: 30
			to: 200
			step: 5
			icon: "gesture_swipe"
			label: "Swipe distance"
			value: Mouse.option("swipeDistance", 70)
			onMoved: v => Mouse.setOption("swipeDistance", v)
		}
	}

	// ── pointer ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-pointer"
		visible: root.has && !!root.st.dpi
		title: "Pointer speed"
		subtitle: "In DPI: how far the pointer goes for an inch of the mouse. niri's own acceleration (Input) comes on top."
		icon: "speedometer"
		modified: (root.st.dpi?.value ?? 0) !== (root.st.dpi?.default ?? 0)
		onReset: Mouse.set("dpi", root.st.dpi.default)

		RowLayout {
			Layout.fillWidth: true
			spacing: 20

			// the number, rolling
			Item {
				Layout.preferredWidth: 150
				Layout.preferredHeight: 70

				StyledText {
					id: dpiNumber

					property real shown: root.st.dpi?.value ?? 0

					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					text: Math.round(dpiNumber.shown)
					font.pixelSize: Theme.size.display + 12
					font.weight: Font.Bold
					tabular: true

					Behavior on shown {
						NumberAnimation {
							duration: Motion.long
							easing.type: Easing.OutCubic
						}
					}
				}

				StyledText {
					anchors.left: dpiNumber.right
					anchors.leftMargin: 6
					anchors.baseline: dpiNumber.baseline
					text: "DPI"
					tone: Theme.textSubtle
					font.weight: Font.DemiBold
				}
			}

			ValueSlider {
				Layout.fillWidth: true
				from: root.st.dpiRange?.min ?? 200
				to: root.st.dpiRange?.max ?? 8000
				step: root.st.dpiRange?.step ?? 50
				icon: "speedometer"
				value: root.st.dpi?.value ?? 1000
				onMoved: v => Mouse.set("dpi", Math.round(v))
			}
		}

		// the stops "Next DPI stop" goes through
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					text: "Stops"
					font.weight: Font.Medium
				}

				StyledText {
					Layout.fillWidth: true
					text: "What a button set to “Next DPI stop” goes through. Click one to use it now, right click to take it away."
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			Repeater {
				model: Mouse.value("dpiPresets", [800, 1200, 1600, 2400])

				delegate: Chip {
					required property int modelData

					text: String(modelData)
					selected: (root.st.dpi?.value ?? 0) === modelData
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					onClicked: Mouse.set("dpi", modelData)
					onRightClicked: Mouse.set("dpiPresets", Mouse.value("dpiPresets", [800, 1200, 1600, 2400]).filter(v => v !== modelData))
				}
			}

			IconButton {
				implicitWidth: 32
				implicitHeight: 32
				icon: "plus"
				variant: "tonal"
				enabled: !Mouse.value("dpiPresets", [800, 1200, 1600, 2400]).includes(root.st.dpi?.value ?? 0)
				onClicked: Mouse.set("dpiPresets", Mouse.value("dpiPresets", [800, 1200, 1600, 2400]).concat([root.st.dpi.value]).sort((a, b) => a - b))
			}
		}

		ValueSlider {
			from: root.st.dpiRange?.min ?? 200
			to: 1600
			step: 50
			icon: "crosshairs"
			label: "Precision"
			value: Mouse.value("shiftDpi", 400)
			onMoved: v => Mouse.set("shiftDpi", Math.round(v))
		}

		StyledText {
			Layout.fillWidth: true
			text: "Precision is the speed while a button set to “Precision while held” is down."
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}
	}

	// ── scrolling ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-scroll"
		visible: root.has && (!!root.st.smartshift || !!root.st.wheel)
		title: "Scrolling"
		subtitle: "The wheel's click, when it spins free, how hard it holds – and the thumb wheel."
		icon: "pan_vertical"

		RowLayout {
			Layout.fillWidth: true
			visible: !!root.st.smartshift
			spacing: 18

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					text: "Wheel"
					font.weight: Font.Medium
				}

				StyledText {
					Layout.fillWidth: true
					text: (root.st.smartshift?.ratchet ?? true) ? "Clicks from line to line" : "Spins freely – a flick goes far"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}

			Segmented {
				Layout.preferredWidth: 280
				options: [{ value: "ratchet", label: "Ratchet", icon: "cog_outline" }, { value: "free", label: "Free spin", icon: "rotate_right" }]
				current: (root.st.smartshift?.ratchet ?? true) ? "ratchet" : "free"
				onSelected: value => Mouse.set("ratchet", value === "ratchet")
			}
		}

		FlagRow {
			visible: !!root.st.smartshift
			icon: "cog_transfer"
			title: "SmartShift"
			subtitle: "A fast flick lets the wheel spin free by itself; it catches again when it slows"
			checked: (root.st.smartshift?.threshold ?? 255) < 255
			onToggled: on => Mouse.setMany({ smartshift: on, threshold: Mouse.value("threshold", 12) })
		}

		ValueSlider {
			visible: !!root.st.smartshift && (root.st.smartshift?.threshold ?? 255) < 255
			from: 1
			to: 49
			step: 1
			icon: "speedometer"
			label: "Spins free from"
			format: v => v <= 8 ? `${v} · a light flick` : (v >= 30 ? `${v} · only a hard flick` : String(v))
			value: Math.min(49, root.st.smartshift?.threshold ?? 12)
			onMoved: v => Mouse.setMany({ smartshift: true, threshold: Math.round(v) })
		}

		ValueSlider {
			visible: root.st.smartshift?.torqueTunable === true
			from: 1
			to: 100
			step: 1
			unit: " %"
			icon: "weight"
			label: "Ratchet force"
			value: root.st.smartshift?.torque ?? 75
			onMoved: v => Mouse.set("torque", Math.round(v))
		}

		FlagRow {
			visible: root.st.wheel?.hasInvert === true
			icon: "swap_vertical"
			title: "Natural scrolling"
			subtitle: "The content follows the finger, as on a touchpad"
			checked: root.st.wheel?.invert === true
			onToggled: on => Mouse.set("wheelInvert", on)
		}

		FlagRow {
			visible: !!root.st.wheel
			icon: "blur_linear"
			title: "High resolution"
			subtitle: `${root.st.wheel?.multiplier ?? 15} steps a notch: smoother in apps that know it, too fast in some that do not`
			checked: root.st.wheel?.hires === true
			onToggled: on => Mouse.set("wheelHires", on)
		}

		FlagRow {
			visible: !!root.st.thumbwheel
			icon: "pan_horizontal"
			title: "Thumb wheel the other way"
			checked: root.st.thumbwheel?.invert === true
			onToggled: on => Mouse.set("thumbInvert", on)
		}

		ValueSlider {
			visible: !!root.st.thumbwheel
			from: 6
			to: 60
			step: 2
			icon: "pan_horizontal"
			label: "Thumb wheel step"
			format: v => v <= 12 ? `${v} · nimble` : (v >= 40 ? `${v} · deliberate` : String(v))
			value: Mouse.option("thumbStep", 18)
			onMoved: v => Mouse.setOption("thumbStep", v)
		}

		StyledText {
			Layout.fillWidth: true
			visible: !!root.st.thumbwheel
			text: "The step is how far the thumb wheel turns for one go of a rule on it (a tab, the volume)."
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}
	}

	// ── haptics ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-haptics"
		visible: root.has && !!root.st.haptic
		title: "Haptics"
		subtitle: "The mouse can knock, tick and buzz under the thumb. Click a pattern to feel it."
		icon: "vibrate"

		FlagRow {
			icon: "vibrate"
			title: "Haptic feedback"
			subtitle: "The mouse's own (the panel, the wheel) and the shell's"
			checked: root.st.haptic?.enabled === true
			onToggled: on => Mouse.setMany({ hapticOn: on, hapticLevel: Math.max(1, root.st.haptic?.level ?? 50) })
		}

		ValueSlider {
			visible: root.st.haptic?.enabled === true
			from: 1
			to: 100
			step: root.st.haptic?.steps ? 25 : 1
			unit: " %"
			icon: "vibrate"
			label: "Strength"
			value: root.st.haptic?.level ?? 50
			onMoved: v => {
				Mouse.setMany({ hapticOn: true, hapticLevel: Math.round(v) });
				feelAgain.restart();
			}

			// once it rests, a tick at the new strength
			Timer {
				id: feelAgain

				interval: 350
				onTriggered: Mouse.play("SHARP COLLISION")
			}
		}

		GridLayout {
			Layout.fillWidth: true
			visible: root.st.haptic?.enabled === true
			columns: 4
			rowSpacing: 8
			columnSpacing: 8

			Repeater {
				model: Mouse.waveforms

				delegate: WaveTile {
					required property string modelData

					Layout.fillWidth: true
					Layout.preferredWidth: 1
					waveform: modelData
					chosen: Mouse.option("feedbackWave", "SUBTLE COLLISION") === modelData
				}
			}
		}

		FlagRow {
			icon: "gesture_swipe"
			title: "Feel gestures"
			subtitle: "A pulse when a swipe, a hold or a double click is recognised"
			checked: Mouse.option("feedback", true)
			onToggled: on => Mouse.setOption("feedback", on)
		}

		RowLayout {
			Layout.fillWidth: true
			visible: Mouse.option("feedback", true)
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "Which pulse"
				font.weight: Font.Medium
			}

			Segmented {
				Layout.preferredWidth: 360
				options: [
					{ value: "WHISPER COLLISION", label: "Whisper" },
					{ value: "SUBTLE COLLISION", label: "Tick" },
					{ value: "SHARP STATE CHANGE", label: "Click" },
					{ value: "DAMP COLLISION", label: "Bump" }
				]
				current: Mouse.option("feedbackWave", "SUBTLE COLLISION")
				onSelected: value => {
					Mouse.setOption("feedbackWave", value);
					Mouse.play(value);
				}
			}
		}
	}

	// ── games and the desktop, felt ────────────────────────────────────────
	SettingCard {
		anchor: "mouse-feel"
		visible: root.has && !!root.st.haptic
		title: "Haptics beyond clicks"
		subtitle: "The mouse as a little rumble motor: games, music, and the desktop itself."
		icon: "vibrate"

		GameFeel {
			Layout.fillWidth: true
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 1
			color: Theme.outline
		}

		DesktopFeel {
			Layout.fillWidth: true
		}
	}

	// ── force panel ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-force"
		visible: root.has && (root.st.force ?? []).length > 0
		title: "Haptic sense panel"
		subtitle: "How hard the thumb has to press the panel before it counts as a press."
		icon: "fingerprint"
		modified: (root.st.force?.[0]?.value ?? 0) !== (root.st.force?.[0]?.default ?? 0)
		onReset: Mouse.set("force", root.st.force[0].default)

		RowLayout {
			Layout.fillWidth: true
			spacing: 14

			StyledText {
				text: "Light"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			ValueSlider {
				Layout.fillWidth: true
				from: root.st.force?.[0]?.min ?? 0
				to: root.st.force?.[0]?.max ?? 100
				step: 10
				icon: "fingerprint"
				label: "Press"
				format: v => `${Math.round((v - (root.st.force?.[0]?.min ?? 0)) / Math.max(1, (root.st.force?.[0]?.max ?? 1) - (root.st.force?.[0]?.min ?? 0)) * 100)} %`
				value: root.st.force?.[0]?.value ?? 0
				onMoved: v => Mouse.set("force", Math.round(v))
			}

			StyledText {
				text: "Firm"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}

		// a press on the panel, here as it happens
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Rectangle {
				Layout.preferredWidth: 12
				Layout.preferredHeight: 12
				radius: 6
				color: Mouse.pressed.haptic ? Theme.primary : Theme.layer3
				scale: Mouse.pressed.haptic ? 1.3 : 1

				Behavior on scale {
					SpatialAnim {}
				}
				Behavior on color {
					ColorAnim {}
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: Mouse.pressed.haptic ? "Pressed" : (Mouse.inCharge ? "Press the panel to try it" : "Press the panel to try it (it shows while the shell has the mouse)")
				tone: Mouse.pressed.haptic ? Theme.primary : Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}
	}

	// ── easy-switch ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-hosts"
		visible: root.has && !!root.st.hosts
		title: "Easy-Switch"
		subtitle: "The computers the mouse is paired with. Switching sends it away from this one."
		icon: "monitor_multiple"

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: root.st.hosts?.hosts ?? []

				delegate: Clickable {
					id: host

					required property var modelData
					readonly property bool here: (root.st.hosts?.current ?? -1) === host.modelData.index
					property bool armed: false

					Layout.fillWidth: true
					implicitHeight: 92
					radius: Theme.radius.large
					color: host.here ? Theme.primaryContainer : (host.armed ? Theme.dangerContainer : Theme.layer2)
					border.width: host.here ? 1.5 : 0
					border.color: Theme.primary
					interactive: !host.here && host.modelData.paired
					onClicked: {
						if (!host.armed) {
							host.armed = true;
							disarm.restart();
							return;
						}
						Mouse.switchHost(host.modelData.index);
						host.armed = false;
					}

					Timer {
						id: disarm

						interval: 3000
						onTriggered: host.armed = false
					}

					ColumnLayout {
						anchors.centerIn: parent
						spacing: 4

						Rectangle {
							Layout.alignment: Qt.AlignHCenter
							width: 30
							height: 30
							radius: 15
							color: host.here ? Theme.primary : Theme.layer3

							StyledText {
								anchors.centerIn: parent
								text: host.modelData.index + 1
								tone: host.here ? Theme.onPrimary : Theme.text
								font.weight: Font.Bold
							}
						}

						StyledText {
							Layout.alignment: Qt.AlignHCenter
							text: host.modelData.name || (host.modelData.paired ? "Paired" : "Free")
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.alignment: Qt.AlignHCenter
							text: host.here ? "This computer" : (host.armed ? "Click again to switch" : (host.modelData.paired ? "Switch to it" : "Not paired"))
							tone: host.here ? Theme.primary : (host.armed ? Theme.danger : Theme.textSubtle)
							font.pixelSize: Theme.size.small
						}
					}
				}
			}
		}
	}

	// ── statistics ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-stats"
		visible: !!Mouse.device
		title: "On the move"
		subtitle: Mouse.option("stats", true) ? `All together ${root.fmtDistance(Mouse.stats.total?.distance ?? 0)}, ${(Mouse.stats.total?.clicks ?? 0).toLocaleString()} clicks since the shell counts` : "Not counted – switch it on to see how far the mouse goes"
		icon: "map_marker_distance"

		trailing: Toggle {
			checked: Mouse.option("stats", true)
			onToggled: on => Mouse.setOption("stats", on)
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Repeater {
				model: [
					{ label: "Today", value: root.fmtDistance(Mouse.stats.today?.distance ?? 0), icon: "map_marker_distance" },
					{ label: "Clicks", value: String(Mouse.stats.today?.clicks ?? 0), icon: "cursor_default_click_outline" },
					{ label: "Notches scrolled", value: String(Mouse.stats.today?.scroll ?? 0), icon: "pan_vertical" }
				]

				delegate: Rectangle {
					required property var modelData

					Layout.fillWidth: true
					implicitHeight: 76
					radius: Theme.radius.large
					color: Theme.layer2

					ColumnLayout {
						anchors.left: parent.left
						anchors.verticalCenter: parent.verticalCenter
						anchors.leftMargin: 16
						spacing: 2

						RowLayout {
							spacing: 6

							Glyph {
								icon: modelData.icon
								size: 13
								color: Theme.textSubtle
							}

							StyledText {
								text: modelData.label
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
							}
						}

						StyledText {
							text: modelData.value
							font.pixelSize: Theme.size.heading + 2
							font.weight: Font.Bold
							tabular: true
						}
					}
				}
			}
		}

		// the last two weeks, a bar a day
		Item {
			id: chart

			readonly property var days: Mouse.stats.days ?? []
			readonly property real peak: Math.max(1, ...chart.days.map(d => d.distance ?? 0))

			Layout.fillWidth: true
			Layout.preferredHeight: 110
			visible: chart.days.length > 0

			Row {
				anchors.fill: parent
				anchors.bottomMargin: 18
				spacing: 6

				Repeater {
					model: chart.days

					delegate: Item {
						id: bar

						required property var modelData
						required property int index
						readonly property bool today: bar.index === chart.days.length - 1

						width: (chart.width - 6 * 13) / 14
						height: parent.height

						Rectangle {
							anchors.bottom: parent.bottom
							width: parent.width
							height: Math.max(4, (bar.modelData.distance ?? 0) / chart.peak * parent.height) * (root.active ? 1 : 0)
							radius: Math.min(6, width / 2)
							color: bar.today ? Theme.primary : Qt.alpha(Theme.primary, 0.35)

							Behavior on height {
								SpatialAnim {
									duration: Motion.long + bar.index * 25
								}
							}
						}

						StyledText {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.top: parent.bottom
							anchors.topMargin: 3
							text: String(bar.modelData.day ?? "").slice(8)
							tone: bar.today ? Theme.primary : Theme.textFaint
							font.pixelSize: Theme.size.tiny
						}
					}
				}
			}
		}
	}

	// ── battery ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-battery"
		visible: root.has && !!root.st.battery
		title: "Battery"
		subtitle: root.st.battery?.hoursLeft ? `${root.st.battery.percent} % – at the pace since the last charge, about ${root.fmtLeft(root.st.battery.hoursLeft)} left` : `${root.st.battery?.percent ?? 0} %, ${root.st.battery?.status ?? ""} – how long it lasts shows once it has run a few hours`
		icon: (root.st.battery?.status ?? "").startsWith("charging") ? "battery_charging" : "battery"

		BatteryChart {
			Layout.fillWidth: true
			Layout.preferredHeight: 120
			log: Mouse.batteryLog
		}

		StyledText {
			Layout.fillWidth: true
			text: "A knock and a notification at 15 %, an angry buzz at 5 %, a note when it is full."
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}
	}

	// ── the device ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mouse-device"
		visible: !!Mouse.device
		title: "This mouse"
		subtitle: Mouse.device ? `${Mouse.device.name}${Mouse.device.slot ? ` · slot ${Mouse.device.slot} of the receiver` : ""}` : ""
		icon: "information_outline"

		GridLayout {
			Layout.fillWidth: true
			columns: width > 720 ? 2 : 1
			rowSpacing: 6
			columnSpacing: 18

			Repeater {
				model: Mouse.device ? [
					["Serial", Mouse.device.serial || "–"],
					["Firmware", (Mouse.device.firmware ?? []).join(", ") || "–"],
					["Connection", Mouse.device.connection === "receiver" ? `${Mouse.device.receiver}, slot ${Mouse.device.slot}` : Mouse.device.connection],
					["Wheel", root.st.wheel ? `${root.st.wheel.multiplier} steps a notch${root.st.wheel.hasSwitch ? ", ratchet switch" : ""}` : "–"],
					["Haptic patterns", root.st.haptic ? `${Mouse.waveforms.length}` : "–"],
					["Who answers the buttons", Mouse.inCharge ? "The shell" : "Solaar"]
				] : []

				delegate: RowLayout {
					required property var modelData

					Layout.columnSpan: 1
					Layout.fillWidth: true
					spacing: 8

					StyledText {
						Layout.preferredWidth: 160
						text: modelData[0]
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					StyledText {
						Layout.fillWidth: true
						text: modelData[1]
						font.pixelSize: Theme.size.small
						font.family: modelData[0] === "Serial" ? Theme.monoFamily : Theme.fontFamily
						elide: Text.ElideRight
					}
				}
			}
		}

		// what it speaks (HID++ 2.0 features): the curious can look
		Flow {
			Layout.fillWidth: true
			spacing: 4
			visible: (Mouse.device?.features ?? []).length > 0

			Repeater {
				model: Mouse.device?.features ?? []

				delegate: Rectangle {
					required property string modelData

					width: featureText.implicitWidth + 12
					height: 22
					radius: 6
					color: Theme.layer2

					StyledText {
						id: featureText

						anchors.centerIn: parent
						text: modelData
						tone: Theme.textSubtle
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.tiny
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true

			StyledText {
				Layout.fillWidth: true
				text: `${(Mouse.device?.features ?? []).length} HID++ features. Talked to directly – no Solaar needed.`
				tone: Theme.textFaint
				font.pixelSize: Theme.size.small
			}

			TextButton {
				implicitHeight: 30
				variant: "ghost"
				icon: "refresh"
				text: "Read again"
				onActivated: Mouse.refresh()
			}
		}
	}
}
