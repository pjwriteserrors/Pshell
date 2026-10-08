pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What a bind does, picked from four shelves: the shell's own calls, an app,
// a command line, or one of niri's actions. Typing filters, ↑↓ move, Enter
// takes the highlighted one.
Rectangle {
	id: root

	// the bind being edited: the shelf it comes from is opened first
	property var bind: null
	property string tab: "shell"

	// { action, args, aprops }
	signal picked(var change)
	signal closed

	function open() {
		const kind = Keybinds.kind(root.bind);
		root.tab = kind !== "" ? kind : "shell";
		search.text = "";
		command.text = root.bind?.action === "spawn-sh" ? String(root.bind.args?.[0] ?? "") : "";
		list.currentIndex = 0;
		Qt.callLater(() => root.tab === "command" ? command.focusInput() : search.focusInput());
	}

	readonly property string query: search.text.trim().toLowerCase()

	function matches(text) {
		const hay = String(text).toLowerCase();
		return root.query.split(/\s+/).every(word => hay.includes(word));
	}

	// [{ title, detail, icon, image, change, current, shelf }] of one shelf
	function shelf(tab) {
		const out = [];
		if (tab === "shell") {
			for (const call of Keybinds.shellActions) {
				if (call.plugin && !Plugins.on(call.plugin)) continue;
				const args = ["qs", "-c", "shell", "ipc", "call", call.target, call.function].concat(call.params.map(() => ""));
				const fake = { action: "spawn", args: args };
				out.push({
					title: Keybinds.actionTitle(fake),
					detail: call.description || `${call.target} ${call.function}${call.params.length ? " · needs " + call.params.map(p => p.name).join(", ") : ""}`,
					icon: "shimmer",
					change: { action: "spawn", args: args, aprops: {} },
					current: Keybinds.isShell(root.bind) && Keybinds.shellCall(root.bind).target === call.target && Keybinds.shellCall(root.bind).fn === call.function,
					shelf: tab
				});
			}
		} else if (tab === "app") {
			const apps = DesktopEntries.applications.values.filter(entry => entry && !entry.noDisplay && !entry.hidden);
			apps.sort((a, b) => String(a.name).localeCompare(String(b.name)));
			const current = Keybinds.app(root.bind);
			for (const entry of apps) {
				out.push({
					title: entry.name,
					detail: entry.genericName || entry.comment || entry.id,
					icon: "application_outline",
					image: AppIcons.app(entry.icon, [entry.id]),
					change: { action: "spawn", args: ["app2unit", "--", `${entry.id}.desktop`], aprops: {} },
					current: !!current && current.id === entry.id,
					shelf: tab
				});
			}
		} else if (tab === "niri") {
			for (const action of Keybinds.niriActions) {
				if (action.name === "spawn" || action.name === "spawn-sh") continue;
				out.push({
					title: Keybinds.words(action.name),
					detail: action.description,
					icon: Keybinds.categoryIcon(Keybinds.category({ action: action.name })),
					change: { action: action.name, args: action.args.filter(arg => !arg.rest).map(() => ""), aprops: {} },
					current: root.bind?.action === action.name,
					shelf: tab
				});
			}
		}
		return out;
	}

	readonly property var shelfNames: ({ shell: "Shell", app: "App", niri: "niri" })

	// a search looks on every shelf, this one's hits first
	readonly property var entries: {
		if (root.query === "") return root.shelf(root.tab);
		const order = [root.tab].concat(["shell", "app", "niri"].filter(tab => tab !== root.tab));
		return order.reduce((all, tab) => all.concat(root.shelf(tab).filter(entry => root.matches(`${entry.title} ${entry.detail}`))), []);
	}

	readonly property var examples: [
		"playerctl play-pause",
		"wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+",
		"wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-",
		"notify-send \"Hello\"",
		"xdg-open ~/Downloads"
	]

	function take(index) {
		const entry = root.entries[index];
		if (entry) root.picked(entry.change);
	}

	function useCommand() {
		if (command.text.trim() === "") return;
		root.picked({ action: "spawn-sh", args: [command.text.trim()], aprops: {} });
	}

	radius: Theme.radius.large
	color: Theme.base
	border.width: 1
	border.color: Theme.outline

	onTabChanged: {
		list.currentIndex = 0;
		swap.restart();
	}

	// one Escape closes the picker, not the window
	Keys.onEscapePressed: event => {
		event.accepted = true;
		root.closed();
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 16
		spacing: 12

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			IconButton {
				icon: "arrow_left"
				onClicked: root.closed()
			}

			StyledText {
				Layout.fillWidth: true
				text: "What should it do?"
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}
		}

		Segmented {
			Layout.fillWidth: true
			options: [
				{ value: "shell", label: "Shell", icon: "shimmer" },
				{ value: "app", label: "App", icon: "apps" },
				{ value: "command", label: "Command", icon: "console" },
				{ value: "niri", label: "niri", icon: "window_maximize" }
			]
			current: root.tab
			onSelected: value => {
				root.tab = value;
				Qt.callLater(() => value === "command" ? command.focusInput() : search.focusInput());
			}
		}

		Field {
			id: search

			Layout.fillWidth: true
			visible: root.tab !== "command"
			icon: "magnify"
			placeholder: root.tab === "shell" ? "Search the shell's actions" : root.tab === "app" ? "Search apps" : "Search niri's actions"
			onEdited: list.currentIndex = 0
			onUpPressed: list.currentIndex = Math.max(0, list.currentIndex - 1)
			onDownPressed: list.currentIndex = Math.min(root.entries.length - 1, list.currentIndex + 1)
			onAccepted: root.take(list.currentIndex)
		}

		Item {
			id: stage

			Layout.fillWidth: true
			Layout.fillHeight: true

			ParallelAnimation {
				id: swap

				NumberAnimation {
					target: stage
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.medium
					easing.type: Easing.OutCubic
				}
				NumberAnimation {
					target: shift
					property: "y"
					from: 10
					to: 0
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}

			transform: Translate {
				id: shift
			}

			ListView {
				id: list

				anchors.fill: parent
				visible: root.tab !== "command"
				clip: true
				model: root.entries
				spacing: 2
				boundsBehavior: Flickable.StopAtBounds
				highlightMoveDuration: Motion.short
				ScrollBar.vertical: ThinScrollBar {}

				delegate: Clickable {
					id: entry

					required property var modelData
					required property int index

					width: list.width - 10
					implicitHeight: 50
					radius: Theme.radius.medium
					pressedScale: 0.985
					color: entry.index === list.currentIndex ? Theme.layer3 : "transparent"
					onClicked: root.take(entry.index)
					onPointed: list.currentIndex = entry.index

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 8
						anchors.rightMargin: 10
						spacing: 12

						Rectangle {
							Layout.preferredWidth: 34
							Layout.preferredHeight: 34
							radius: Theme.radius.medium
							color: entry.modelData.current ? Theme.primary : Theme.layer2

							Image {
								id: picture

								anchors.centerIn: parent
								width: 24
								height: 24
								visible: status === Image.Ready
								source: entry.modelData.image ?? ""
								sourceSize: Qt.size(48, 48)
								asynchronous: true
								smooth: true
								mipmap: true
							}

							Glyph {
								anchors.centerIn: parent
								visible: !picture.visible
								icon: entry.modelData.icon
								size: 17
								color: entry.modelData.current ? Theme.onPrimary : Theme.textMuted
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 1

							StyledText {
								Layout.fillWidth: true
								text: entry.modelData.title
								font.weight: Font.DemiBold
							}

							StyledText {
								Layout.fillWidth: true
								visible: text !== ""
								text: entry.modelData.detail
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
							}
						}

						// a hit from another shelf says where it is from
						Rectangle {
							visible: entry.modelData.shelf !== root.tab
							implicitWidth: shelfLabel.implicitWidth + 14
							implicitHeight: 20
							radius: 10
							color: Theme.layer2

							StyledText {
								id: shelfLabel

								anchors.centerIn: parent
								text: root.shelfNames[entry.modelData.shelf] ?? ""
								tone: Theme.textMuted
								font.pixelSize: Theme.size.tiny
								font.weight: Font.DemiBold
							}
						}

						Glyph {
							visible: entry.modelData.current
							icon: "check"
							size: 16
							color: Theme.primary
						}
					}
				}

				EmptyState {
					anchors.centerIn: parent
					visible: list.count === 0
					icon: root.tab === "niri" && Keybinds.niriActions.length === 0 ? "progress_clock" : "magnify"
					title: root.tab === "niri" && Keybinds.niriActions.length === 0 ? "Asking niri…" : "Nothing found"
				}
			}

			// a command line, run through the shell
			ColumnLayout {
				anchors.fill: parent
				visible: root.tab === "command"
				spacing: 12

				Field {
					id: command

					Layout.fillWidth: true
					icon: "console"
					placeholder: "A command, as in a terminal"
					fontSize: Theme.size.body
					input.font.family: Theme.monoFamily
					onAccepted: root.useCommand()
				}

				StyledText {
					Layout.fillWidth: true
					text: "Runs with sh -c, so ~, pipes and && work."
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}

				SectionLabel {
					Layout.topMargin: 6
					text: "Examples"
				}

				Flow {
					Layout.fillWidth: true
					spacing: 6

					Repeater {
						model: root.examples

						delegate: Chip {
							required property string modelData

							text: modelData
							icon: "console"
							onClicked: {
								command.text = modelData;
								command.focusInput();
							}
						}
					}
				}

				Item {
					Layout.fillHeight: true
				}

				TextButton {
					Layout.alignment: Qt.AlignRight
					variant: "filled"
					icon: "check"
					text: "Use this command"
					enabled: command.text.trim() !== ""
					onActivated: root.useCommand()
				}
			}
		}
	}
}
