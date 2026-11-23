pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >cal: what is typed becomes an event of the Baikal calendar
// (NasCalendar.parseText: "morgen 15 Uhr Zahnarzt @Praxis", "Fr 18-20 Kino",
// "jeden Montag 9 Standup 15min"). Enter adds it, Shift+Enter opens it in the
// editor below the Today panel, Tab picks the calendar. With nothing typed:
// the next seven days; Enter shows the event.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0
	property string calendar: ""
	property bool saving: false

	readonly property string words: root.argument.trim()
	readonly property var parsed: root.words !== "" ? NasCalendar.parseText(root.words, new Date()) : null
	readonly property string chosen: root.calendar !== "" && NasCalendar.writable.some(c => c.href === root.calendar) ? root.calendar : NasCalendar.defaultCalendar()
	readonly property var upcoming: {
		const out = [];
		const today = new Date();
		for (let i = 0; i < 7; i += 1) {
			const day = new Date(today.getFullYear(), today.getMonth(), today.getDate() + i);
			for (const event of MsCalendar.eventsOn(day)) {
				if (Date.parse(event.end) < Date.now() || out.some(other => other.id === event.id && other.start === event.start)) continue;
				out.push(event);
			}
		}
		return out.slice(0, 40);
	}

	signal closeRequested

	onActiveChanged: {
		if (!root.active) return;
		root.currentIndex = 0;
		MsCalendar.ensure(new Date());
		NasCalendar.ensure(new Date());
	}

	function when(found) {
		const day = Qt.formatDate(found.start, "ddd, d. MMMM yyyy");
		if (found.allDay) {
			const last = new Date(found.end.getTime() - 1);
			return MsCalendar.dayKey(last) === MsCalendar.dayKey(found.start) ? `${day} · all day` : `${day} – ${Qt.formatDate(last, "d. MMMM")}`;
		}
		return `${day} · ${Qt.formatTime(found.start, "HH:mm")} – ${Qt.formatTime(found.end, "HH:mm")}`;
	}

	function eventWhen(event) {
		const start = new Date(event.start);
		return event.allDay ? Qt.formatDate(start, "ddd d. MMM") : `${Qt.formatDate(start, "ddd d. MMM")} · ${Qt.formatTime(start, "HH:mm")}`;
	}

	function move(delta) {
		if (root.parsed) return;
		root.currentIndex = Math.max(0, Math.min(root.upcoming.length - 1, root.currentIndex + delta));
		list.positionViewAtIndex(root.currentIndex, ListView.Contain);
	}

	function handleKey(event) {
		if (event.key === Qt.Key_Tab && root.parsed && NasCalendar.writable.length > 1) {
			const at = NasCalendar.writable.findIndex(c => c.href === root.chosen);
			root.calendar = NasCalendar.writable[(at + 1) % NasCalendar.writable.length].href;
			return true;
		}
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		if (!root.parsed) {
			const event = root.upcoming[root.currentIndex];
			if (!event) return;
			root.closeRequested();
			later.run = () => MsCalendar.show(event);
			later.restart();
			return;
		}
		if (!NasCalendar.active || root.chosen === "") return;
		const found = root.parsed;
		if ((modifiers & Qt.ShiftModifier) || !found.title) {
			root.closeRequested();
			later.run = () => {
				NasCalendar.draftFrom(root.words, "");
				NasCalendar.draft = Object.assign({}, NasCalendar.draft, { calendar: root.chosen });
			};
			later.restart();
			return;
		}
		root.saving = true;
		const config = NasCalendar.config;
		Nas.setLocal("calendar", Object.assign({}, config, { lastCalendar: root.chosen }));
		NasCalendar.addParsed(found, reply => {
			root.saving = false;
			if (reply.error) return;
			Notifs.pushInternal("done", found.title, root.when(found), { icon: "calendar_check", app: "Calendar" });
			root.closeRequested();
		});
	}

	// once the launcher has gone, the panel that opens takes the keyboard
	Timer {
		id: later

		property var run: null
		interval: Motion.medium
		onTriggered: if (later.run) later.run()
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 10

		EmptyState {
			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: !NasCalendar.active
			icon: "calendar_outline"
			title: "No Baikal calendar"
			subtitle: "Settings › NAS › Baikal calendar"
		}

		// what was typed, as an event
		Rectangle {
			Layout.fillWidth: true
			visible: NasCalendar.active && root.parsed !== null
			implicitHeight: card.implicitHeight + 28
			radius: Theme.radius.large
			color: Theme.layer1

			ColumnLayout {
				id: card

				anchors.fill: parent
				anchors.margins: 14
				spacing: 8

				RowLayout {
					Layout.fillWidth: true
					spacing: 10

					Glyph {
						icon: root.parsed?.repeat ? "repeat" : "calendar_plus"
						size: 22
						color: Theme.primary
					}

					StyledText {
						Layout.fillWidth: true
						text: root.parsed?.title || "Title?"
						tone: root.parsed?.title ? Theme.text : Theme.textSubtle
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
						elide: Text.ElideRight
					}

					Spinner {
						visible: root.saving
						Layout.preferredWidth: 16
						Layout.preferredHeight: 16
					}
				}

				StyledText {
					Layout.fillWidth: true
					text: root.parsed ? root.when(root.parsed) + (root.parsed.repeat ? ` · ${({ daily: "daily", weekly: "weekly", monthly: "monthly", yearly: "yearly" })[root.parsed.repeat]}` : "") : ""
					tone: root.parsed?.when ? Theme.textMuted : Theme.warning
					font.pixelSize: Theme.size.body
				}

				StyledText {
					Layout.fillWidth: true
					visible: (root.parsed?.location ?? "") !== ""
					text: root.parsed?.location ?? ""
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				Flow {
					Layout.fillWidth: true
					visible: NasCalendar.writable.length > 1
					spacing: 6

					Repeater {
						model: NasCalendar.writable

						delegate: Chip {
							required property var modelData

							text: modelData.name
							icon: "circle"
							accent: modelData.color !== "" ? modelData.color : Theme.secondary
							selected: root.chosen === modelData.href
							onClicked: root.calendar = modelData.href
						}
					}
				}
			}
		}

		// the next days
		ListView {
			id: list

			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: NasCalendar.active && root.parsed === null
			clip: true
			spacing: 2
			model: root.upcoming
			currentIndex: root.currentIndex
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			delegate: ListItem {
				id: row

				required property var modelData
				required property int index

				width: list.width
				selected: root.currentIndex === row.index
				icon: row.modelData.source === "birthday" ? "party_popper" : (row.modelData.online ? "video" : "calendar_outline")
				title: row.modelData.subject
				subtitle: [root.eventWhen(row.modelData), row.modelData.location, row.modelData.calendar].filter(s => s).join(" · ")
				onPointed: root.currentIndex = row.index
				onClicked: {
					root.currentIndex = row.index;
					root.activate(0);
				}
			}
		}

		Item {
			Layout.fillHeight: true
			visible: NasCalendar.active && root.parsed !== null
		}
	}
}
