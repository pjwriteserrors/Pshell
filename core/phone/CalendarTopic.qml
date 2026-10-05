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
			const key = Outlook.dayKey(date);
			for (const event of Outlook.eventsOn(date))
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
					running: Outlook.active(event)
				});
		}
		return out;
	}

	onWantedChanged: if (topic.wanted && Outlook.signedIn) Outlook.refresh()

	data: topic.wanted ? ({
		microsoft: Plugins.on("microsoft-calendar"),
		signedIn: Outlook.signedIn,
		account: Outlook.account,
		name: Outlook.name,
		signingIn: Outlook.signingIn,
		loginCode: Outlook.loginCode,
		loginUrl: Outlook.loginUrl,
		error: Outlook.error,
		loading: Outlook.loading,
		events: Outlook.signedIn ? topic.upcoming() : []
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "refresh":
			Outlook.refresh();
			return {};
		case "signIn":
			Outlook.signIn();
			return {};
		case "cancelSignIn":
			Outlook.cancelSignIn();
			return {};
		case "signOut":
			Outlook.signOut();
			return {};
		case "open":
			Outlook.open(String(args.url));
			return {};
		}
		throw new Error("unknown-action");
	}
}
