pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Debug: niri's switches for driver trouble and testing. They can change
// or go with any niri release.
SettingsPage {
	id: root

	title: "Debug"
	description: "Switches for driver trouble and testing. niri may change or drop them with any release – leave them off unless something is wrong."

	readonly property var flags: [
		{ name: "enable-overlay-planes", text: "Overlay planes", detail: "Direct scanout into overlay planes; can drop frames" },
		{ name: "disable-cursor-plane", text: "No cursor plane", detail: "Draws the cursor with the frame – helps a slow cursor with VRR" },
		{ name: "disable-direct-scanout", text: "No direct scanout", detail: "Always composites" },
		{ name: "restrict-primary-scanout-to-matching-format", text: "Scanout only with matching format", detail: "" },
		{ name: "force-disable-connectors-on-resume", text: "Reset monitors on resume", detail: "Forces a modeset after sleep" },
		{ name: "force-pipewire-invalid-modifier", text: "PipeWire invalid modifier", detail: "Screencast workaround" },
		{ name: "disable-pipewire-dmabuf", text: "No dmabuf for PipeWire", detail: "Screencast workaround" },
		{ name: "dbus-interfaces-in-non-session-instances", text: "D-Bus in nested niri", detail: "" },
		{ name: "wait-for-frame-completion-before-queueing", text: "Wait for frames", detail: "Driver workaround" },
		{ name: "emulate-zero-presentation-time", text: "Zero presentation time", detail: "" },
		{ name: "disable-resize-throttling", text: "No resize throttling", detail: "" },
		{ name: "disable-transactions", text: "No transactions", detail: "Windows resize independently" },
		{ name: "keep-laptop-panel-on-when-lid-is-closed", text: "Laptop screen stays on with the lid closed", detail: "" },
		{ name: "disable-monitor-names", text: "No monitor names", detail: "Matches outputs by connector only" },
		{ name: "strict-new-window-focus-policy", text: "Strict focus for new windows", detail: "Only activation tokens give focus" },
		{ name: "honor-xdg-activation-with-invalid-serial", text: "Honor activation with invalid serial", detail: "" },
		{ name: "skip-cursor-only-updates-during-vrr", text: "Skip cursor-only frames with VRR", detail: "" },
		{ name: "deactivate-unfocused-windows", text: "Deactivate unfocused windows", detail: "For apps that misbehave otherwise" },
		{ name: "disable-10bit-output", text: "No 10-bit output", detail: "" }
	]

	SettingCard {
		anchor: "debug"
		title: "Preview a recording"
		subtitle: "Draws the screens the way a screencast sees them – to check what block-out rules hide"
		icon: "record_rec"
		modified: NiriSettings.has(["debug", "preview-render"])
		onReset: NiriSettings.reset(["debug", "preview-render"])

		Segmented {
			Layout.preferredWidth: 420
			options: [{ value: "", label: "Normal" }, { value: "screencast", label: "As a screencast" }, { value: "screen-capture", label: "As a capture" }]
			current: String(NiriSettings.arg(["debug", "preview-render"], ""))
			onSelected: value => value === "" ? NiriSettings.reset(["debug", "preview-render"]) : NiriSettings.set(["debug", "preview-render"], value, "Preview render changed", "")
		}
	}

	SettingCard {
		title: "Switches"
		icon: "bug_outline"

		Repeater {
			model: root.flags

			delegate: FlagRow {
				required property var modelData

				title: modelData.text
				subtitle: modelData.detail !== "" ? `${modelData.name} – ${modelData.detail}` : modelData.name
				checked: NiriSettings.flag(["debug", modelData.name])
				onToggled: on => NiriSettings.setFlag(["debug", modelData.name], on, `${modelData.text} ${on ? "on" : "off"}`)
			}
		}
	}

	SettingCard {
		title: "Graphics card"
		subtitle: "Which GPU renders (render-drm-device)"
		icon: "expansion_card"
		modified: NiriSettings.has(["debug", "render-drm-device"])
		onReset: NiriSettings.reset(["debug", "render-drm-device"])

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: NiriSettings.drm

				delegate: Chip {
					required property var modelData

					text: `${modelData.path} · ${modelData.driver}`
					icon: "expansion_card"
					selected: String(NiriSettings.arg(["debug", "render-drm-device"], "")) === modelData.path
					onClicked: NiriSettings.set(["debug", "render-drm-device"], modelData.path, "Render device set", "")
				}
			}
		}
	}
}
