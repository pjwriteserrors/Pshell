pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../settings/Nodes.js" as Nodes

// What starts at login: niri's own startup commands (the same switches as
// the Pshell settings' System page), the apps of XDG autostart and the
// user's services. Each says whether it runs right now and what it takes.
Item {
	id: root

	property var autostart: []
	property var services: []
	property bool loading: true
	readonly property var niriStartup: Plugins.on("niri-settings") ? NiriSettings.items(["spawn-at-startup", "spawn-sh-at-startup"]) : []

	function reload() {
		TaskManager.autostart(data => {
			root.autostart = data.autostart.filter(item => item.applies);
			root.services = data.services;
			root.loading = false;
		});
	}

	Component.onCompleted: {
		root.reload();
		if (Plugins.on("niri-settings")) NiriSettings.prepare();
	}

	function programOf(command) {
		return String(command ?? "").trim().split(/\s+/)[0].split("/").pop();
	}

	// what of it runs now: the group the daemon knows by that name
	function running(program) {
		const name = String(program ?? "").toLowerCase();
		if (name === "") return null;
		return TaskManager.top.concat(TaskManager.topMem).find(item => item.name.toLowerCase() === name) ?? null;
	}

	function commandOf(node) {
		return node.name === "spawn-sh-at-startup" ? String(node.args[0] ?? "") : (node.args || []).join(" ");
	}

	Flickable {
		anchors.fill: parent
		contentHeight: body.implicitHeight + 40
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: body

			x: 24
			y: 20
			width: parent.width - 48
			spacing: 10

			// ── niri ───────────────────────────────────────────────────────
			Header {
				visible: root.niriStartup.length > 0
				title: "Starts with niri"
				icon: "rocket_launch_outline"
			}

			Repeater {
				model: root.niriStartup

				Item_ {
					required property var modelData
					required property int index

					title: {
						const program = root.programOf(root.commandOf(modelData));
						return DesktopEntries.heuristicLookup(program)?.name ?? program;
					}
					subtitle: root.commandOf(modelData)
					image: AppIcons.forAppId(root.programOf(root.commandOf(modelData)))
					on: !modelData.disabled
					order: index
					onSwitched: on => {
						const list = root.niriStartup.slice();
						const node = Nodes.clone(modelData);
						if (on) delete node.disabled;
						else node.disabled = true;
						list[index] = node;
						NiriSettings.setItems(["spawn-at-startup", "spawn-sh-at-startup"], list, `${title} ${on ? "starts again" : "no longer starts"}`, "");
					}
				}
			}

			// ── apps ───────────────────────────────────────────────────────
			Header {
				Layout.topMargin: 12
				visible: root.autostart.length > 0
				title: "Apps at login"
				icon: "application_outline"
			}

			Repeater {
				model: root.autostart

				Item_ {
					required property var modelData
					required property int index

					title: modelData.name
					subtitle: modelData.comment || modelData.exec
					image: modelData.icon ? AppIcons.app(modelData.icon) : AppIcons.forAppId(root.programOf(modelData.exec))
					on: modelData.enabled
					order: index + root.niriStartup.length
					onSwitched: on => TaskManager.setAutostart(modelData.file, on, () => root.reload())
				}
			}

			// ── services ───────────────────────────────────────────────────
			Header {
				Layout.topMargin: 12
				visible: root.services.length > 0
				title: "Services at login"
				icon: "cog_transfer_outline"
			}

			Repeater {
				model: root.services

				Item_ {
					required property var modelData
					required property int index

					title: modelData.unit.replace(/\.service$/, "")
					subtitle: modelData.description
					glyph: "cog_outline"
					on: modelData.enabled
					active: modelData.active === "active"
					order: index + root.niriStartup.length + root.autostart.length
					onSwitched: on => TaskManager.serviceAction("user", modelData.unit, on ? "enable" : "disable", () => root.reload())
				}
			}

			Spinner {
				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 40
				Layout.preferredWidth: 28
				Layout.preferredHeight: 28
				visible: root.loading
			}
		}
	}

	component Header: RowLayout {
		id: header

		property string title
		property string icon

		Layout.fillWidth: true
		spacing: 8

		Glyph {
			icon: header.icon
			size: 16
			color: Theme.textMuted
		}

		SectionLabel {
			text: header.title
		}
	}

	component Item_: Rectangle {
		id: entry

		property string title
		property string subtitle
		property string image: ""
		property string glyph: ""
		property bool on: true
		property bool active: false
		property int order: 0
		readonly property var live: root.running(entry.title)
		signal switched(bool on)

		Layout.fillWidth: true
		Layout.preferredHeight: 58
		radius: Theme.radius.large
		color: Theme.layer1
		opacity: 0
		Component.onCompleted: appear.start()

		SequentialAnimation {
			id: appear

			PauseAnimation {
				duration: Math.min(400, entry.order * 30)
			}
			NumberAnimation {
				target: entry
				property: "opacity"
				to: entry.on ? 1 : 0.6
				duration: Motion.medium
			}
		}

		onOnChanged: entry.opacity = entry.on ? 1 : 0.6

		Behavior on opacity {
			enabled: !appear.running
			Anim {}
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 14
			anchors.rightMargin: 14
			spacing: 12

			Item {
				Layout.preferredWidth: 30
				Layout.preferredHeight: 30

				Image {
					anchors.fill: parent
					visible: entry.glyph === ""
					source: entry.image
					sourceSize: Qt.size(60, 60)
					asynchronous: true
				}

				Glyph {
					anchors.centerIn: parent
					visible: entry.glyph !== ""
					icon: entry.glyph
					size: 20
					color: Theme.textMuted
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					Layout.fillWidth: true
					text: entry.title
					font.weight: Font.Medium
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					text: entry.subtitle
					visible: text !== ""
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			Rectangle {
				visible: entry.active || !!entry.live
				Layout.preferredHeight: 22
				Layout.preferredWidth: runningRow.implicitWidth + 16
				radius: 11
				color: Qt.alpha(Theme.success, 0.12)

				Row {
					id: runningRow

					anchors.centerIn: parent
					spacing: 5

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: 6
						height: 6
						radius: 3
						color: Theme.success
					}

					StyledText {
						text: entry.live ? `Running · ${Format.bytes(entry.live.m)}` : "Running"
						tone: Theme.success
						font.pixelSize: Theme.size.tiny
						font.weight: Font.Medium
					}
				}
			}

			Toggle {
				checked: entry.on
				onToggled: on => entry.switched(on)
			}
		}
	}
}
