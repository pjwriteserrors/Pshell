pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Session menu. Lock fires on click; logout, reboot and shutdown must be
// held until the ring closes (Enter on the keyboard confirms instantly).
// "After" under reboot and shutdown picks what to wait for: a process, a
// busy agent or a download (Session.after).
ModalWindow {
	id: root

	property int selection: 0
	property string userName: ""
	property string kernel: ""
	property string uptime: ""
	// the keyboard is on "After" of the selected action
	property bool lower: false
	// the action a process is picked for, and whether the picker shows
	property string kind: "shutdown"
	property bool picking: false
	property real pickReveal: root.picking ? 1 : 0
	// rows that appear with the picker come in one after the other
	property bool fresh: false
	property var processes: []
	// the downloads under way, as they were when the list was last read
	property var loading: []
	property int row: 0
	readonly property var entries: {
		const q = search.text.trim().toLowerCase();
		const agents = Plugins.on("agents") ? Object.keys(Agents.busy).map(id => {
			const window = Niri.windows.find(w => Number(w.id) === Number(id));
			if (!window) return null;
			return {
				what: "agent",
				window: Number(id),
				name: Agents.busy[id].agent,
				detail: Agents.topic(window.title) || window.app_id || "",
				seconds: Math.round((Date.now() - Agents.busy[id].since) / 1000),
			};
		}).filter(entry => entry) : [];
		const loading = root.loading;
		const byPid = {};
		for (const p of root.processes) byPid[p.pid] = p;
		// the programs that own a window, each once
		const apps = [];
		const seen = {};
		for (const window of Niri.windows) {
			const p = byPid[window.pid];
			if (!p || seen[p.pid]) continue;
			seen[p.pid] = true;
			apps.push({ what: "process", app: true, pid: p.pid, start: p.start, name: window.app_id || p.name, detail: window.title || p.args, seconds: p.seconds });
		}
		const jobs = root.processes.filter(p => p.front).map(p => ({ what: "process", pid: p.pid, start: p.start, name: p.name, detail: p.args, seconds: p.seconds }));
		const shown = agents.concat(loading, jobs, apps);
		if (q === "") return shown;
		// typing reaches every process that runs
		const rest = root.processes.filter(p => !p.front && !seen[p.pid]).map(p => ({ what: "process", pid: p.pid, start: p.start, name: p.name, detail: p.args, seconds: p.seconds }));
		return shown.concat(rest).filter(entry => `${entry.name} ${entry.detail} ${entry.pid ?? ""}`.toLowerCase().includes(q));
	}

	readonly property var actions: [
		{ id: "lock", label: Words.of("power.lock", "Lock"), icon: "lock", hold: false, shown: Plugins.on("lock-screen") },
		{ id: "logout", label: Words.of("power.logout", "Log out"), icon: "logout", hold: true },
		{ id: "reboot", label: Words.of("power.reboot", "Restart"), icon: "restart", hold: true, after: true },
		{ id: "shutdown", label: Words.of("power.shutdown", "Shut down"), icon: "power", hold: true, after: true }
	].filter(action => action.shown !== false)

	function label(kind) {
		return root.actions.find(action => action.id === kind)?.label ?? "";
	}

	function age(seconds) {
		if (seconds < 60) return `${seconds} s`;
		if (seconds < 3600) return `${Math.floor(seconds / 60)} min`;
		return `${Math.floor(seconds / 3600)} h`;
	}

	function gather() {
		const loading = Downloads.enabled ? Downloads.active.map(item => ({
			what: "download",
			key: item.key,
			name: item.name,
			detail: [item.total > 0 ? `${Math.round(100 * item.received / item.total)} %` : "", item.state === "paused" ? "Paused" : (item.eta >= 0 ? Downloads.formatEta(item.eta) : "")].filter(part => part !== "").join("  ·  "),
			seconds: Math.max(0, Math.round((Date.now() - item.started) / 1000))
		})) : [];
		if (loading.length > 1) loading.unshift({ what: "downloads", name: "All downloads", detail: `${loading.length} files`, seconds: Math.max(...loading.map(entry => entry.seconds)) });
		if (JSON.stringify(loading) === JSON.stringify(root.loading)) return;
		const at = list.contentY;
		root.loading = loading;
		root.row = Math.max(0, Math.min(root.row, root.entries.length - 1));
		if (!root.fresh) list.contentY = Math.max(0, Math.min(at, list.contentHeight - list.height));
	}

	function pick(kind) {
		root.kind = kind;
		root.row = 0;
		search.text = "";
		root.fresh = true;
		settle.restart();
		root.gather();
		lister.running = true;
		root.picking = true;
		search.focusInput();
	}

	function leave() {
		root.picking = false;
		keys.forceActiveFocus();
	}

	function choose(entry) {
		if (!entry) return;
		// the pill reads "… after all downloads"
		Session.after(root.kind, entry.what === "downloads" ? Object.assign({}, entry, { name: "all downloads" }) : entry);
		root.leave();
	}

	Behavior on pickReveal {
		NumberAnimation {
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}
	}

	// what ended while the picker is open leaves the list
	Timer {
		interval: 2000
		repeat: true
		running: root.picking
		onTriggered: {
			root.gather();
			lister.running = true;
		}
	}

	Timer {
		id: settle
		interval: 600
		onTriggered: root.fresh = false
	}

	modalId: "power"
	scrimColor: Qt.rgba(0, 0, 0, 0.62)

	onModalOpened: {
		root.selection = 0;
		root.lower = false;
		root.picking = false;
		info.running = true;
	}

	Process {
		id: lister
		command: ["python3", `${Paths.scripts}/power_after.py`, "list"]
		stdout: StdioCollector {
			onStreamFinished: {
				let found = [];
				try {
					found = JSON.parse(String(text || "[]"));
				} catch (error) {}
				// the same processes as before: the list stays as it is
				const key = list => list.map(p => `${p.pid}${p.front ? "f" : ""}`).join(" ");
				if (key(found) === key(root.processes)) return;
				const chosen = root.entries[root.row];
				const at = list.contentY;
				root.processes = found;
				const row = chosen ? root.entries.findIndex(entry => entry.what === chosen.what && entry.pid === chosen.pid && entry.window === chosen.window && entry.key === chosen.key) : -1;
				root.row = Math.max(0, row >= 0 ? row : Math.min(root.row, root.entries.length - 1));
				if (!root.fresh) list.contentY = Math.max(0, Math.min(at, list.contentHeight - list.height));
			}
		}
	}

	Process {
		id: info
		command: ["sh", "-lc", `printf '%s|%s|%s' "$USER" "$(uname -r)" "$(uptime -p | sed 's/^up //')"`]
		stdout: StdioCollector {
			onStreamFinished: {
				const parts = String(text || "").split("|");
				root.userName = parts[0] || "";
				root.kernel = parts[1] || "";
				root.uptime = parts[2] || "";
			}
		}
	}

	Item {
		id: keys

		function move(step) {
			root.selection = (root.selection + root.actions.length + step) % root.actions.length;
			root.lower = false;
		}

		function confirm() {
			const action = root.actions[root.selection];
			if (root.lower) root.pick(action.id);
			else Session.run(action.id);
		}

		anchors.fill: parent
		focus: true
		enabled: !root.picking
		visible: root.pickReveal < 0.99
		opacity: 1 - root.pickReveal
		scale: 1 - 0.08 * root.pickReveal

		Keys.onLeftPressed: keys.move(-1)
		Keys.onRightPressed: keys.move(1)
		Keys.onTabPressed: keys.move(1)
		Keys.onDownPressed: root.lower = !!root.actions[root.selection].after
		Keys.onUpPressed: root.lower = false
		Keys.onReturnPressed: keys.confirm()
		Keys.onEnterPressed: keys.confirm()

		ColumnLayout {
			anchors.centerIn: parent
			spacing: 36

			ColumnLayout {
				Layout.alignment: Qt.AlignHCenter
				spacing: 4

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: root.userName !== "" ? `See you, ${root.userName}` : "Session"
					font.pixelSize: 34
					font.weight: Font.Bold
					tone: "white"
					surface: "transparent"
				}

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: [root.uptime !== "" ? `up ${root.uptime}` : "", root.kernel].filter(v => v !== "").join("  ·  ")
					tone: Qt.rgba(1, 1, 1, 0.7)
					surface: "transparent"
					font.pixelSize: Theme.size.body
				}
			}

			// what the machine waits for; it grows in and out of the column
			Item {
				id: waiting

				readonly property bool shown: Session.pending !== null
				// the words stay while the pill leaves
				property string words: ""
				readonly property string current: {
					const pending = Session.pending;
					if (!pending) return "";
					if (Session.due) return `${pending.kind === "reboot" ? "Restarting" : "Shutting down"} in ${Session.left} s`;
					return `${root.label(pending.kind)} after ${pending.name}`;
				}

				onCurrentChanged: if (waiting.current !== "") waiting.words = waiting.current
				Component.onCompleted: waiting.words = waiting.current

				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: pill.width
				Layout.preferredHeight: waiting.shown ? 44 : 0
				Layout.topMargin: waiting.shown ? 0 : -36
				opacity: waiting.shown ? 1 : 0
				scale: waiting.shown ? 1 : 0.8
				visible: opacity > 0.01

				Behavior on Layout.preferredHeight {
					SpatialAnim {}
				}
				Behavior on Layout.topMargin {
					SpatialAnim {}
				}
				Behavior on opacity {
					Anim {}
				}
				Behavior on scale {
					SpatialAnim {}
				}

				Rectangle {
					id: pill

					anchors.centerIn: parent
					width: pillRow.implicitWidth + 22
					height: 44
					radius: height / 2
					color: Session.due ? Theme.danger : Qt.rgba(1, 1, 1, 0.1)

					Behavior on color {
						ColorAnim {
							duration: Motion.medium
						}
					}
					Behavior on width {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					RowLayout {
						id: pillRow

						anchors.centerIn: parent
						spacing: 10

						Glyph {
							id: sand

							Layout.leftMargin: 6
							icon: "timer_sand"
							size: 18
							color: Session.due ? Theme.bg : "white"
							surface: "transparent"

							// the hourglass turns over now and then
							SequentialAnimation on spin {
								running: waiting.shown && root.shown
								loops: Animation.Infinite

								PauseAnimation {
									duration: 1800
								}
								SpatialAnim {
									from: 0
									to: 180
									duration: Motion.extraLong
								}
							}
						}

						StyledText {
							Layout.maximumWidth: 420
							text: waiting.words
							tone: Session.due ? Theme.bg : "white"
							surface: "transparent"
							tabular: true
							font.pixelSize: Theme.size.title
							font.weight: Font.DemiBold
						}

						IconButton {
							implicitWidth: 30
							implicitHeight: 30
							icon: "close"
							iconColor: Session.due ? Theme.bg : "white"
							onClicked: Session.cancelAfter()
						}
					}
				}
			}

			Row {
				Layout.alignment: Qt.AlignHCenter
				spacing: 22

				Repeater {
					model: root.actions

					delegate: Item {
						id: action

						required property var modelData
						required property int index
						readonly property bool selected: root.selection === action.index
						property real hold: 0

						function point() {
							root.selection = action.index;
							root.lower = false;
						}

						width: 128
						height: 196

						NumberAnimation {
							id: holdAnim

							target: action
							property: "hold"
							to: 1
							duration: 750 * (1 - action.hold)
							onFinished: if (action.hold >= 1) Session.run(action.modelData.id)
						}

						NumberAnimation {
							id: releaseAnim

							target: action
							property: "hold"
							to: 0
							duration: Motion.medium
							easing.type: Easing.OutCubic
						}

						Item {
							id: disc

							width: 116
							height: 116
							anchors.horizontalCenter: parent.horizontalCenter
							y: action.selected ? -6 : 0

							Behavior on y {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Rectangle {
								anchors.fill: parent
								anchors.margins: 8
								radius: action.selected ? 30 : width / 2
								color: action.selected ? (action.modelData.id === "lock" ? Theme.primary : Theme.danger) : Theme.base
								scale: mouse.pressed ? 0.9 : 1

								Behavior on radius {
									SpatialAnim {
										duration: Motion.medium
									}
								}
								Behavior on color {
									ColorAnim {
										duration: Motion.medium
									}
								}
								Behavior on scale {
									SpatialAnim {
										duration: Motion.medium
									}
								}

								Glyph {
									anchors.centerIn: parent
									icon: action.modelData.icon
									size: 40
									color: action.selected ? (action.modelData.id === "lock" ? Theme.onPrimary : Theme.bg) : Theme.text
									spin: action.selected && action.modelData.id === "reboot" ? 360 : 0

									Behavior on spin {
										SpatialAnim {
											duration: Motion.extraLong
										}
									}
								}
							}

							Ring {
								anchors.fill: parent
								visible: action.hold > 0
								value: action.hold
								animated: false
								thickness: 5
								color: "white"
								trackColor: Qt.rgba(1, 1, 1, 0.15)
							}

							MouseArea {
								id: mouse

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onEntered: if (Pointer.moved(mouse, mouseX, mouseY)) action.point()
								onPositionChanged: if (Pointer.moved(mouse, mouseX, mouseY)) action.point()
								onPressed: {
									if (!action.modelData.hold) return;
									releaseAnim.stop();
									holdAnim.restart();
								}
								onReleased: {
									if (!action.modelData.hold) {
										if (containsMouse) Session.run(action.modelData.id);
										return;
									}
									if (action.hold < 1) {
										holdAnim.stop();
										releaseAnim.restart();
									}
								}
							}
						}

						Chip {
							id: later

							readonly property bool waits: Session.pending?.kind === action.modelData.id
							readonly property bool offered: !!action.modelData.after && (action.selected || later.waits)

							anchors.horizontalCenter: parent.horizontalCenter
							y: later.offered ? 164 : 150
							enabled: later.offered
							opacity: later.offered ? 1 : 0
							scale: later.offered ? 1 : 0.7
							text: "After"
							icon: "timer_sand"
							selected: (action.selected && root.lower) || later.waits
							accent: later.waits && !(action.selected && root.lower) ? Qt.alpha(Theme.primary, 0.75) : Theme.primary
							onClicked: root.pick(action.modelData.id)

							Behavior on y {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}
						}

						ColumnLayout {
							anchors.horizontalCenter: parent.horizontalCenter
							y: 156 - height
							spacing: 1

							StyledText {
								Layout.alignment: Qt.AlignHCenter
								text: action.modelData.label
								tone: "white"
								surface: "transparent"
								font.pixelSize: Theme.size.title
								font.weight: action.selected ? Font.Bold : Font.Medium
							}

							StyledText {
								Layout.alignment: Qt.AlignHCenter
								text: action.modelData.hold ? "hold" : "click"
								tone: Qt.rgba(1, 1, 1, action.selected ? 0.6 : 0)
								surface: "transparent"
								font.pixelSize: Theme.size.tiny
								font.weight: Font.Bold
								font.letterSpacing: 1.2
								font.capitalization: Font.AllUppercase
							}
						}
					}
				}
			}
		}
	}

	Rectangle {
		id: picker

		readonly property int rows: Math.max(1, Math.min(7, root.entries.length))

		anchors.centerIn: parent
		width: 540
		height: Math.min(parent.height - 120, 136 + picker.rows * 54)
		visible: root.pickReveal > 0.01
		enabled: root.picking
		opacity: root.pickReveal
		scale: 0.9 + 0.1 * root.pickReveal
		radius: Theme.radius.huge
		color: Theme.base
		border.width: 1
		border.color: Theme.outline
		transform: Translate {
			y: 36 * (1 - root.pickReveal)
		}

		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Keys.onEscapePressed: root.leave()

		// a click on the card is not one beside the menu
		MouseArea {
			anchors.fill: parent
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 14
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				IconButton {
					icon: "arrow_left"
					onClicked: root.leave()
				}

				StyledText {
					Layout.fillWidth: true
					text: `${root.label(root.kind)} after`
					font.pixelSize: Theme.size.title
					font.weight: Font.Bold
				}

				Rectangle {
					Layout.preferredWidth: 34
					Layout.preferredHeight: 34
					Layout.rightMargin: 2
					radius: Theme.radius.medium
					color: Theme.danger

					Glyph {
						anchors.centerIn: parent
						icon: root.kind === "reboot" ? "restart" : "power"
						size: 18
						color: Theme.bg
						spin: root.picking && root.kind === "reboot" ? 360 : 0

						Behavior on spin {
							SpatialAnim {
								duration: Motion.extraLong
							}
						}
					}
				}
			}

			Field {
				id: search

				Layout.fillWidth: true
				icon: "magnify"
				placeholder: "Search"
				onEdited: root.row = 0
				onUpPressed: root.row = Math.max(0, root.row - 1)
				onDownPressed: root.row = Math.min(root.entries.length - 1, root.row + 1)
				onAccepted: root.choose(root.entries[root.row])
			}

			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true

				EmptyState {
					anchors.centerIn: parent
					visible: root.entries.length === 0 && !lister.running
					icon: "magnify"
					title: "Nothing found"
				}

				ListView {
					id: list

					anchors.fill: parent
					clip: true
					spacing: 2
					model: root.entries
					currentIndex: root.row
					highlightMoveDuration: Motion.short
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					delegate: ListItem {
						id: entry

						required property var modelData
						required property int index
						readonly property bool agent: entry.modelData.what === "agent"
						property real arrive: root.fresh ? 0 : 1

						width: list.width - 8
						icon: entry.agent ? "robot" : (entry.modelData.key || entry.modelData.what === "downloads" ? "download" : (entry.modelData.app ? "application" : "console"))
						title: entry.modelData.name
						subtitle: entry.modelData.detail
						selected: entry.index === root.row
						opacity: entry.arrive
						transform: Translate {
							y: 14 * (1 - entry.arrive)
						}
						onPointed: root.row = entry.index
						onClicked: root.choose(entry.modelData)

						Component.onCompleted: if (entry.arrive < 1) arriving.start()

						SequentialAnimation {
							id: arriving

							PauseAnimation {
								duration: 90 + Math.min(entry.index, 8) * 40
							}
							SpatialAnim {
								target: entry
								property: "arrive"
								to: 1
								duration: Motion.medium
							}
						}

						Spinner {
							visible: entry.agent
							Layout.preferredWidth: 14
							Layout.preferredHeight: 14
							color: Theme.primary
						}

						StyledText {
							text: root.age(entry.modelData.seconds)
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
							tabular: true
						}
					}
				}
			}
		}
	}
}
