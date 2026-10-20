import QtQuick
import Quickshell
import qs.core.services

// calendar: the next days of the Microsoft 365 calendar, and the sign-in.
Topic {
	id: topic

	name: "calendar"

	function upcoming() {
		const out = [];
		const today = new Date();
		for (let offset = 0; offset < 14; offset += 1) {
			const date = new Date(today.getFullYear(), today.getMonth(), today.getDate() + offset);
			const key = MsCalendar.dayKey(date);
			for (const event of MsCalendar.eventsOn(date))
				out.push({
					id: String(event.id),
					day: key,
					subject: String(event.subject || ""),
					start: String(event.start || ""),
					end: String(event.end || ""),
					allDay: !!event.allDay,
					location: String(event.location || ""),
					join: String(event.joinUrl || event.onlineMeetingUrl || ""),
					link: String(event.webLink || ""),
					running: MsCalendar.active(event)
				});
		}
		return out;
	}

	onWantedChanged: if (topic.wanted && MsCalendar.signedIn) MsCalendar.refresh()

	data: topic.wanted ? ({
		microsoft: Plugins.on("microsoft-calendar"),
		signedIn: MsCalendar.signedIn,
		account: MsCalendar.account,
		name: MsCalendar.name,
		signingIn: MsCalendar.signingIn,
		loginCode: MsCalendar.loginCode,
		loginUrl: MsCalendar.loginUrl,
		error: MsCalendar.error,
		loading: MsCalendar.loading,
		events: MsCalendar.signedIn ? topic.upcoming() : []
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "refresh":
			MsCalendar.refresh();
			return {};
		case "signIn":
			MsCalendar.signIn();
			return {};
		case "cancelSignIn":
			MsCalendar.cancelSignIn();
			return {};
		case "signOut":
			MsCalendar.signOut();
			return {};
		case "open":
			MsCalendar.open(String(args.url));
			return {};
		}
		throw new Error("unknown-action");
	}
}
