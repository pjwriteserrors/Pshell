pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The address books of the Baikal account (CardDAV; the phone fills them
// with DAVx5): names for numbers WhatsApp only knows as +49…, and the
// birthdays as whole-day events in the calendar (NasCalendar.eventsOn).
// Read every half hour while the calendar is connected, kept in
// contacts.json for the start before Baikal answers.
Singleton {
	id: root

	readonly property bool on: NasCalendar.active
	// [{ name, phones, emails, birthday }]
	property var list: []
	// last 9 digits → name
	readonly property var byPhone: {
		const out = {};
		for (const contact of root.list)
			for (const phone of contact.phones ?? [])
				out[root.tail(phone)] = contact.name;
		return out;
	}

	function tail(number) {
		return String(number).replace(/\D/g, "").slice(-9);
	}

	function nameForPhone(number) {
		const key = root.tail(number);
		return key.length >= 7 ? (root.byPhone[key] ?? "") : "";
	}

	// a WhatsApp chat named only by its number gets the name from the address book
	function named(chat) {
		if (!chat || chat.group || root.list.length === 0) return chat;
		const name = String(chat.name ?? "");
		if (name !== "" && !/^\+?[\d\s()-]+$/.test(name)) return chat;
		const found = root.nameForPhone(chat.phone || String(chat.id ?? "").split("@")[0]);
		return found ? Object.assign({}, chat, { name: found }) : chat;
	}

	// whole-day birthday events of one day, "YYYY-MM-DD"
	function birthdaysOn(key) {
		const md = key.slice(5);
		const out = [];
		for (const contact of root.list) {
			const b = String(contact.birthday ?? "");
			if (b === "" || b.slice(-5) !== md) continue;
			const year = Number(key.slice(0, 4));
			const age = b.length === 10 ? year - Number(b.slice(0, 4)) : 0;
			const start = new Date(`${key}T00:00:00`);
			out.push({
				id: `birthday:${contact.name}:${key}`,
				source: "birthday",
				readOnly: true,
				subject: age > 0 ? `${contact.name} (${age})` : contact.name,
				start: start.toISOString(),
				end: new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1).toISOString(),
				allDay: true,
				days: [key],
				location: "",
				joinUrl: "",
				online: false,
				webLink: "",
				body: "",
				showAs: "free",
				cancelled: false,
				response: "",
				recurring: true,
				private: false,
				isOrganizer: true,
				organizer: { name: "Birthday", email: "" },
				attendees: [],
				calendar: "Birthdays",
				color: "",
				reminder: -1
			});
		}
		return out;
	}

	function load() {
		if (!root.on) return;
		NasCalendar.write("contacts", {}, reply => {
			if (reply.error) return;
			root.list = reply.contacts ?? [];
			cache.setText(JSON.stringify(root.list));
		});
	}

	FileView {
		id: cache

		path: Paths.stateFile("contacts.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				if (root.list.length === 0) root.list = JSON.parse(cache.text() || "[]");
			} catch (e) {}
		}
	}

	Timer {
		running: root.on
		repeat: true
		interval: 30 * 60000
		triggeredOnStart: true
		onTriggered: root.load()
	}
}
