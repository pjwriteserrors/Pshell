pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// switch-events: what runs when the laptop lid closes or opens, or the
// laptop folds into a tablet and back. Only commands (`spawn`) – and they
// run even on the lock screen. Each event plays itself on hover.
GridLayout {
	id: root

	property bool active: false

	columns: width > 900 ? 2 : 1
	columnSpacing: 16
	rowSpacing: 16

	readonly property var events: [
		{ id: "lid-close", title: "Lid closes", icon: "laptop_off" },
		{ id: "lid-open", title: "Lid opens", icon: "laptop" },
		{ id: "tablet-mode-on", title: "Folded into a tablet", icon: "tablet" },
		{ id: "tablet-mode-off", title: "Back to a laptop", icon: "laptop_account" }
	]
	readonly property var quick: [
		{ label: "Lock the screen", args: ["qs", "-c", "shell", "ipc", "call", "lock", "lock"] },
		{ label: "Sleep", args: ["systemctl", "suspend"] },
		{ label: "Pause the music", args: ["playerctl", "pause"] },
		{ label: "Screen keyboard on", args: ["sh", "-c", "gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true"] },
		{ label: "Screen keyboard off", args: ["sh", "-c", "gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled false"] }
	]

	function argsOf(id) {
		const node = NiriSettings.node(["switch-events", id]);
		const spawn = (node?.children || []).find(c => c.name === "spawn" || c.name === "spawn-sh");
		if (!spawn) return null;
		return spawn.name === "spawn-sh" ? ["sh", "-c"].concat(spawn.args.map(String)) : spawn.args.map(String);
	}

	function shown(args) {
		if (!args) return "";
		if ((args[0] === "sh" || args[0] === "bash") && args[1] === "-c") return args.slice(2).join(" ");
		return args.map(a => /\s/.test(a) ? `"${a}"` : a).join(" ");
	}

	function write(id, args, note) {
		if (!args || args.length === 0) {
			NiriSettings.reset(["switch-events", id], note);
			return;
		}
		NiriSettings.setChildren(["switch-events", id], [NiriSettings.leaf("spawn", args)], note, "");
	}

	Repeater {
		model: root.events

		delegate: Rectangle {
			id: event

			required property var modelData
			readonly property var args: root.argsOf(event.modelData.id)
			readonly property bool set: !!event.args

			Layout.fillWidth: true
			implicitHeight: content.implicitHeight + 36
			radius: Theme.radius.huge
			color: Theme.layer1
			border.width: event.set ? 1.5 : 0
			border.color: Qt.alpha(Theme.primary, 0.5)

			HoverHandler {
				id: hover
			}

			ColumnLayout {
				id: content

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 18
				spacing: 12

				RowLayout {
					Layout.fillWidth: true
					spacing: 14

					// the lid closing, or the screen folding back
					Item {
						id: scene

						Layout.preferredWidth: 70
						Layout.preferredHeight: 52

						property real fold: hover.hovered && root.active ? 1 : 0

						Behavior on fold {
							SpatialAnim {
								duration: Motion.extraLong
							}
						}

						Rectangle {
							id: base

							x: 5
							y: 40
							width: 60
							height: 6
							radius: 3
							color: Theme.textMuted
						}

						Rectangle {
							x: 8
							y: 6
							width: 54
							height: 36
							radius: 4
							color: event.set ? Theme.primary : Theme.layer3
							transform: Rotation {
								origin.x: 27
								origin.y: 36
								axis.x: 1
								axis.y: 0
								axis.z: 0
								readonly property bool closing: event.modelData.id === "lid-close" || event.modelData.id === "tablet-mode-on"
								angle: event.modelData.id.startsWith("lid") ? (closing ? scene.fold * 82 : (1 - scene.fold) * 82) : (closing ? -scene.fold * 170 : -(1 - scene.fold) * 170)
							}
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 2

						StyledText {
							text: event.modelData.title
							font.pixelSize: Theme.size.title
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.fillWidth: true
							text: event.set ? `Runs: ${root.shown(event.args)}` : "Nothing runs"
							tone: event.set ? Theme.primary : Theme.textSubtle
							font.family: event.set ? Theme.monoFamily : Theme.fontFamily
							font.pixelSize: Theme.size.small
							elide: Text.ElideMiddle
						}
					}

					ResetPill {
						shown: event.set
						text: "Nothing"
						onClicked: root.write(event.modelData.id, null, `${event.modelData.title}: nothing`)
					}
				}

				Flow {
					Layout.fillWidth: true
					spacing: 6

					Repeater {
						model: root.quick

						delegate: Chip {
							required property var modelData

							text: modelData.label
							selected: JSON.stringify(modelData.args) === JSON.stringify(event.args)
							onClicked: root.write(event.modelData.id, modelData.args, `${event.modelData.title}: ${modelData.label.toLowerCase()}`)
						}
					}
				}

				Field {
					id: command

					Layout.fillWidth: true
					icon: "console"
					placeholder: "Or a command, run with sh -c"
					text: event.set ? root.shown(event.args) : ""
					onAccepted: root.write(event.modelData.id, command.text.trim() === "" ? null : ["sh", "-c", command.text.trim()], `${event.modelData.title}: command set`)
				}
			}
		}
	}

	StyledText {
		Layout.fillWidth: true
		Layout.columnSpan: root.columns
		text: "These run even while the screen is locked. niri already turns the laptop's own screen off and on with the lid."
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}
}
