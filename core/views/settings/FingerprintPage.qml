pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.fingerprint

// The fingerprint reader (core/services/Fingerprint.qml): the enrolled
// fingers on two drawn hands – enroll, test, delete –, where the finger is
// taken (the lock screen, sudo, admin prompts, …) and waking the PC by touch.
SettingsPage {
	id: root

	title: "Fingerprint"
	description: ""

	signal open(string page)

	property string finger: ""
	readonly property string shown: root.finger || (Fingerprint.fingers[0] ?? "right-index-finger")
	readonly property bool has: Fingerprint.online
	readonly property var usb: Fingerprint.usb
	readonly property bool enrolling: Fingerprint.busy === "enroll"
	readonly property bool testing: Fingerprint.busy === "verify"
	readonly property bool isEnrolled: Fingerprint.fingers.includes(root.shown)

	onActiveChanged: Fingerprint.watching = root.active
	Component.onDestruction: Fingerprint.watching = false

	Connections {
		target: Fingerprint

		function onMatched(finger, ok) {
			figure.flash(finger, ok);
		}

		function onEnrolled(finger) {
			figure.flash(finger, true);
		}
	}

	// what the reader says now, for the line under the hands
	readonly property string line: {
		if (root.enrolling) return Fingerprint.says(Fingerprint.enrollment.status === "waiting" ? "" : Fingerprint.enrollment.status);
		if (root.testing) return Fingerprint.says(Fingerprint.test.status === "waiting" ? "" : Fingerprint.test.status);
		if (Fingerprint.enrollment.done && Fingerprint.enrollment.finger === root.shown && Fingerprint.enrollment.status !== "stopped")
			return Fingerprint.says(Fingerprint.enrollment.status);
		if (Fingerprint.test.done && Fingerprint.test.status !== "stopped")
			return `${Fingerprint.nameOf(Fingerprint.test.finger)}: ${Fingerprint.says(Fingerprint.test.status)}`;
		return "";
	}

	// ── the hands, live ────────────────────────────────────────────────────
	SettingCard {
		anchor: "fingerprint-device"
		title: !Fingerprint.scanned ? "Looking for the reader …" : (root.has ? (root.usb?.product || Fingerprint.device.name || "Fingerprint reader") : (Fingerprint.present ? "fprintd does not answer" : "No reader"))
		subtitle: root.has ? [Fingerprint.device.name, root.usb ? `Firmware ${root.usb.firmware}` : "", `${Fingerprint.fingers.length} ${Fingerprint.fingers.length === 1 ? "finger" : "fingers"}`].filter(s => s).join(" · ") : ""
		icon: root.has ? "fingerprint" : "fingerprint_off"

		trailing: TextButton {
			visible: root.has && !Fingerprint.busy && Fingerprint.fingers.length > 1
			variant: "ghost"
			icon: "play"
			text: "Test any"
			onActivated: Fingerprint.verify("any")
		}

		HandsFigure {
			id: figure

			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(290, Math.max(190, width * 0.36))
			online: root.has
			enrolled: Fingerprint.fingers
			selected: root.shown
			active: Fingerprint.busy === "enroll" ? (Fingerprint.enrollment.finger ?? "") : (Fingerprint.busy === "verify" ? (Fingerprint.test.finger ?? "") : "")
			progress: root.enrolling && Fingerprint.stages > 0 && Fingerprint.enrollment.status !== "waiting" ? (Fingerprint.enrollment.stage ?? 0) / Fingerprint.stages : -1
			fingerPresent: Fingerprint.fingerPresent
			fingerNeeded: Fingerprint.fingerNeeded
			onPicked: finger => {
				if (!Fingerprint.busy) root.finger = finger;
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 10
			visible: root.has

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					text: Fingerprint.nameOf(root.shown)
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: root.line || (root.isEnrolled ? "Enrolled" : "Not enrolled")
					tone: /no-match|failed|full|duplicate|error|disconnected/.test(root.enrolling ? Fingerprint.enrollment.status : (Fingerprint.test.status ?? "")) && root.line ? Theme.danger : Theme.textMuted
					wrapMode: Text.WordWrap
				}
			}

			StyledText {
				visible: root.enrolling && Fingerprint.stages > 0
				text: `${Fingerprint.enrollment.stage ?? 0} / ${Fingerprint.stages}`
				tabular: true
				tone: Theme.textMuted
			}

			TextButton {
				visible: !Fingerprint.busy && root.isEnrolled
				variant: "ghost"
				icon: "play"
				text: "Test"
				onActivated: Fingerprint.verify(root.shown)
			}

			TextButton {
				visible: !Fingerprint.busy
				variant: root.isEnrolled ? "ghost" : "filled"
				icon: "fingerprint"
				text: root.isEnrolled ? "Enroll again" : "Enroll"
				onActivated: Fingerprint.enroll(root.shown)
			}

			TextButton {
				visible: !Fingerprint.busy && root.isEnrolled
				variant: "danger"
				icon: "delete_outline"
				text: "Delete"
				confirm: true
				onActivated: Fingerprint.remove(root.shown)
			}

			TextButton {
				visible: root.enrolling || root.testing
				variant: "ghost"
				icon: "close"
				text: "Cancel"
				onActivated: Fingerprint.stop()
			}

			Spinner {
				visible: Fingerprint.busy === "delete"
				Layout.preferredWidth: 22
				Layout.preferredHeight: 22
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: Fingerprint.error !== ""
			text: Fingerprint.error
			tone: Theme.danger
			wrapMode: Text.WordWrap
		}
	}

	// ── where the finger is taken ──────────────────────────────────────────
	SettingCard {
		anchor: "fingerprint-use"
		visible: Fingerprint.scanned
		title: "Unlock with the finger"
		icon: "lock_outline"

		FlagRow {
			icon: "lock"
			title: "Lock screen"
			checked: Fingerprint.lockScreen
			onToggled: on => Fingerprint.setOption("lockScreen", on)
		}

		FlagRow {
			icon: "lock_open_variant"
			title: "Animation on unlock"
			checked: Fingerprint.unlockAnimation
			onToggled: on => {
				Fingerprint.setOption("unlockAnimation", on);
				if (on) Fingerprint.playUnlock();
			}
		}

		ValueSlider {
			visible: Fingerprint.lockScreen
			from: 1
			to: 10
			step: 1
			icon: "restart"
			label: "Tries on the lock screen"
			format: v => `${Math.round(v)}`
			value: Fingerprint.lockTries
			onMoved: v => Fingerprint.setOption("lockTries", Math.round(v))
		}

		Repeater {
			model: Fingerprint.pam.filter(s => s.id !== "lock" && s.state !== "missing")

			FlagRow {
				required property var modelData

				icon: ({ sddm: "login", sudo: "console", "polkit-1": "shield_key", swaylock: "lock_outline", su: "console", login: "console" })[modelData.id] ?? "key_outline"
				title: modelData.label
				subtitle: modelData.state === "custom" ? "Set up by hand" : ""
				checked: modelData.state === "on" || modelData.state === "custom"
				enabled: modelData.state !== "custom" && modelData.state !== "unreadable"
				opacity: enabled ? 1 : 0.6
				onToggled: on => Fingerprint.setPam(modelData.id, on)
			}
		}

		ValueSlider {
			from: 1
			to: 10
			step: 1
			icon: "restart"
			label: "Tries"
			format: v => `${Math.round(v)}`
			value: Fingerprint.pamTries
			onMoved: v => {
				Fingerprint.setOption("pamTries", Math.round(v));
				pamLater.restart();
			}
		}

		ValueSlider {
			from: 5
			to: 120
			step: 5
			icon: "timer_outline"
			label: "Waits for the finger"
			format: v => `${Math.round(v)} s`
			value: Fingerprint.pamTimeout
			onMoved: v => {
				Fingerprint.setOption("pamTimeout", Math.round(v));
				pamLater.restart();
			}
		}

		Timer {
			id: pamLater

			interval: 1500
			onTriggered: Fingerprint.applyPamOptions()
		}
	}

	// ── the reader ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "fingerprint-reader"
		visible: root.has
		title: "Reader"
		icon: "chip"

		FlagRow {
			icon: "power_sleep"
			title: "Wake the PC by touch"
			checked: Fingerprint.wake
			onToggled: on => Fingerprint.setWake(on)
		}

		GridLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			columns: 2
			columnSpacing: 18
			rowSpacing: 6

			Repeater {
				model: [
					["Driver", Fingerprint.device.name ?? ""],
					["Sensor", Fingerprint.device.scanType === "press" ? "Press, match on chip" : (Fingerprint.device.scanType ?? "")],
					["Enroll", `${Fingerprint.stages} touches`],
					["USB", root.usb ? `${root.usb.id} · port ${root.usb.port}${root.usb.builtIn ? " · built in" : ""}` : ""],
					["Power", root.usb ? (root.usb.autosuspend ? `Sleeps after ${root.usb.suspendDelay / 1000} s${root.usb.sleeping ? " · asleep" : ""}` : "Always on") : ""]
				].filter(r => r[1])

				delegate: Item {
					id: cell

					required property var modelData
					required property int index

					Layout.columnSpan: 2
					Layout.fillWidth: true
					implicitHeight: info.implicitHeight

					RowLayout {
						id: info

						anchors.left: parent.left
						anchors.right: parent.right
						spacing: 18

						StyledText {
							Layout.preferredWidth: 80
							text: cell.modelData[0]
							tone: Theme.textMuted
						}

						StyledText {
							Layout.fillWidth: true
							text: cell.modelData[1]
							elide: Text.ElideRight
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.topMargin: 6

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				visible: Fingerprint.fingers.length > 0
				enabled: !Fingerprint.busy
				variant: "danger"
				icon: "delete_sweep_outline"
				text: "Delete all fingers"
				confirm: true
				onActivated: Fingerprint.removeAll()
			}
		}
	}
}
