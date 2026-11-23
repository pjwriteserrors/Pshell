pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A Baikal event, new or its series, in the panel below the Today panel:
// NasCalendar.draft in, NasCalendar.saveDraft() out. Dates are typed as
// d.M.yyyy, times as H:mm; moving the start takes the end along.
Item {
	id: root

	property var draft: null
	// the last draft stays drawn while the card fades out
	property var shown: null
	property string problem: ""

	readonly property var repeats: {
		const out = [{ value: "", label: "Once" }, { value: "daily", label: "Daily" }, { value: "weekly", label: "Weekly" }, { value: "monthly", label: "Monthly" }, { value: "yearly", label: "Yearly" }];
		if (root.shown?.repeat === "custom") out.push({ value: "custom", label: "As set" });
		return out;
	}
	readonly property var reminders: {
		const out = [{ value: "-1", label: "None" }, { value: "0", label: "At start" }, { value: "10", label: "10 min" }, { value: "60", label: "1 h" }, { value: "1440", label: "1 day" }];
		const has = root.shown?.reminder;
		if (has === null) out.push({ value: "keep", label: "As set" });
		else if (has !== undefined && !out.some(o => o.value === String(has))) out.splice(1, 0, { value: String(has), label: root.minutes(has) });
		return out;
	}

	property bool allDay: false
	property string calendar: ""
	property string repeat: ""
	property string reminder: "-1"

	function minutes(n) {
		if (n % 1440 === 0) return `${n / 1440} d`;
		if (n % 60 === 0) return `${n / 60} h`;
		return `${n} min`;
	}

	function pad(n) {
		return String(n).padStart(2, "0");
	}

	// "2026-11-20" / "2026-11-20T10:00" → Date
	function fromWall(text) {
		const m = String(text).match(/^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/);
		if (!m) return new Date();
		return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4] ?? 0), Number(m[5] ?? 0));
	}

	function dateText(date) {
		return `${date.getDate()}.${date.getMonth() + 1}.${date.getFullYear()}`;
	}

	function timeText(date) {
		return `${date.getHours()}:${root.pad(date.getMinutes())}`;
	}

	// typed "20.11.2026", "20.11." or "20.11.26" and "10", "10:30", "1030" → Date or null
	function read(dateField, timeField, withTime) {
		const d = dateField.trim().match(/^(\d{1,2})\.(\d{1,2})\.?(\d{2,4})?$/);
		if (!d) return null;
		const year = d[3] ? (d[3].length === 2 ? 2000 + Number(d[3]) : Number(d[3])) : new Date().getFullYear();
		let h = 0;
		let m = 0;
		if (withTime) {
			const t = timeField.trim().match(/^(\d{1,2})(?::?(\d{2}))?$/);
			if (!t) return null;
			h = Number(t[1]);
			m = Number(t[2] ?? 0);
			if (h > 23 || m > 59) return null;
		}
		const out = new Date(year, Number(d[2]) - 1, Number(d[1]), h, m);
		return out.getDate() === Number(d[1]) && out.getMonth() === Number(d[2]) - 1 ? out : null;
	}

	function wall(date, withTime) {
		const day = `${date.getFullYear()}-${root.pad(date.getMonth() + 1)}-${root.pad(date.getDate())}`;
		return withTime ? `${day}T${root.pad(date.getHours())}:${root.pad(date.getMinutes())}` : day;
	}

	function load() {
		const d = root.shown;
		if (!d) return;
		const start = root.fromWall(d.start);
		let end = root.fromWall(d.end);
		// whole days end the day after: the editor shows the last day
		if (d.allDay) end = new Date(end.getFullYear(), end.getMonth(), end.getDate() - 1);
		title.text = d.title ?? "";
		place.text = d.location ?? "";
		notes.text = d.notes ?? "";
		startDate.text = root.dateText(start);
		startTime.text = root.timeText(start);
		endDate.text = root.dateText(end < start ? start : end);
		endTime.text = root.timeText(d.allDay ? new Date(start.getTime() + 3600000) : end);
		root.allDay = !!d.allDay;
		root.calendar = d.calendar ?? "";
		root.repeat = d.repeat ?? "";
		root.reminder = d.reminder === null ? "keep" : String(d.reminder ?? -1);
		root.problem = "";
		if (!d.href) Qt.callLater(() => title.focusInput());
	}

	onDraftChanged: {
		if (!root.draft) return;
		root.shown = root.draft;
		root.load();
	}

	// the start moved: the end keeps the length
	property real length: 3600000
	function noteLength() {
		const start = root.read(startDate.text, startTime.text, !root.allDay);
		const end = root.read(endDate.text, endTime.text, !root.allDay);
		if (start && end && end >= start) root.length = end - start;
	}
	function startMoved() {
		const start = root.read(startDate.text, startTime.text, !root.allDay);
		if (!start) return;
		const end = new Date(start.getTime() + root.length);
		endDate.text = root.dateText(end);
		if (!root.allDay) endTime.text = root.timeText(end);
	}

	function save() {
		const start = root.read(startDate.text, startTime.text, !root.allDay);
		let end = root.read(endDate.text, endTime.text, !root.allDay);
		if (title.text.trim() === "") return root.problem = "Title";
		if (!start) return root.problem = "Start";
		if (!end || end < start) return root.problem = "End";
		if (root.allDay) end = new Date(end.getFullYear(), end.getMonth(), end.getDate() + 1);
		root.problem = "";
		NasCalendar.saveDraft({
			calendar: root.calendar,
			title: title.text.trim(),
			location: place.text.trim(),
			notes: notes.text,
			allDay: root.allDay,
			start: root.wall(start, !root.allDay),
			end: root.wall(end, !root.allDay),
			repeat: root.repeat === "custom" ? null : root.repeat,
			reminder: root.reminder === "keep" ? null : Number(root.reminder)
		});
	}

	implicitHeight: column.implicitHeight

	Keys.onEscapePressed: NasCalendar.draft = null

	ColumnLayout {
		id: column

		anchors.fill: parent
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Field {
				id: title

				Layout.fillWidth: true
				placeholder: "Title"
				fontSize: Theme.size.heading
				onAccepted: root.save()
				onEscapePressed: NasCalendar.draft = null
			}

			IconButton {
				implicitWidth: 28
				implicitHeight: 28
				icon: "close"
				onClicked: NasCalendar.draft = null
			}
		}

		Flow {
			Layout.fillWidth: true
			visible: NasCalendar.writable.length > 1 && !(root.shown?.href)
			spacing: 6

			Repeater {
				model: NasCalendar.writable

				delegate: Chip {
					required property var modelData

					text: modelData.name
					icon: "circle"
					accent: modelData.color !== "" ? modelData.color : Theme.secondary
					selected: root.calendar === modelData.href
					onClicked: root.calendar = modelData.href
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: "All day"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}

			Toggle {
				checked: root.allDay
				onToggled: on => root.allDay = on
			}
		}

		GridLayout {
			Layout.fillWidth: true
			columns: 3
			columnSpacing: 6
			rowSpacing: 6

			StyledText {
				text: "From"
				tone: root.problem === "Start" ? Theme.danger : Theme.textMuted
				font.pixelSize: Theme.size.label
				Layout.preferredWidth: 40
			}

			Field {
				id: startDate

				Layout.fillWidth: true
				clearable: false
				onFocusedChanged: focused ? root.noteLength() : root.startMoved()
				onAccepted: root.save()
			}

			Field {
				id: startTime

				visible: !root.allDay
				Layout.preferredWidth: 76
				clearable: false
				onFocusedChanged: focused ? root.noteLength() : root.startMoved()
				onAccepted: root.save()
			}

			StyledText {
				text: "To"
				tone: root.problem === "End" ? Theme.danger : Theme.textMuted
				font.pixelSize: Theme.size.label
				Layout.preferredWidth: 40
			}

			Field {
				id: endDate

				Layout.fillWidth: true
				clearable: false
				onAccepted: root.save()
			}

			Field {
				id: endTime

				visible: !root.allDay
				Layout.preferredWidth: 76
				clearable: false
				onAccepted: root.save()
			}
		}

		Segmented {
			Layout.fillWidth: true
			implicitHeight: 32
			options: root.repeats
			current: root.repeat
			onSelected: value => root.repeat = value
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Glyph {
				icon: "bell_outline"
				size: 16
				color: Theme.textMuted
			}

			Segmented {
				Layout.fillWidth: true
				implicitHeight: 32
				options: root.reminders
				current: root.reminder
				onSelected: value => root.reminder = value
			}
		}

		Field {
			id: place

			Layout.fillWidth: true
			icon: "map_marker_outline"
			placeholder: "Place"
			onAccepted: root.save()
		}

		AreaField {
			id: notes

			Layout.fillWidth: true
			Layout.preferredHeight: 64
			placeholder: "Notes"
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				visible: (root.shown?.overrides ?? 0) > 0
				text: `${root.shown?.overrides} moved ${root.shown?.overrides === 1 ? "date stays" : "dates stay"}`
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			Item {
				Layout.fillWidth: true
				visible: (root.shown?.overrides ?? 0) === 0
			}

			TextButton {
				text: "Save"
				icon: "check"
				variant: "filled"
				busy: NasCalendar.saving
				enabled: root.calendar !== ""
				onActivated: root.save()
			}
		}
	}
}
