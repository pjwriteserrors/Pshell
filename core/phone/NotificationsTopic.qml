pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import qs.core.services

// notifications: what pops up on the PC also reaches the phone, with its
// buttons and its reply field; by default only while nobody sits at the PC
// (locked, or idle for a minute). The phone can also ask the PC something
// (`ask`): a notification here with choices and a text field, answered back.
Topic {
	id: topic

	name: "notifications"

	// "away" | "always" | "off"
	property string mode: "away"
	readonly property bool away: Session.locked || idle.isIdle
	// mirror id → the toast it stands for
	property var live: ({})
	property int lastToast: Notifs.nextToastId
	property int asked: 0

	data: topic.wanted ? ({ mode: topic.mode, away: topic.away }) : null

	IdleMonitor {
		id: idle

		enabled: topic.allowed
		timeout: 60
		respectInhibitors: false
	}

	function localPath(value) {
		const text = String(value || "");
		if (text.startsWith("file://")) return text.slice(7);
		return text.startsWith("/") ? text : "";
	}

	// what was sent lately: "app|title|body" → when. The same thing again within
	// a minute (a program that repeats itself, a toast per file of a batch)
	// is not sent again.
	property var recent: ({})

	function remember(id, entry, message) {
		const now = Date.now();
		const key = `${message.app}|${message.title}|${message.body}`;
		const last = topic.recent[key] || 0;
		for (const old of Object.keys(topic.recent))
			if (now - topic.recent[old] > 60000) delete topic.recent[old];
		topic.recent[key] = now;
		if (now - last < 60000) return;
		topic.live[id] = entry;
		const ids = Object.keys(topic.live).map(Number).sort((x, y) => x - y);
		while (ids.length > 80) delete topic.live[ids.shift()];
		topic.link.emit("notifications", "posted", message);
	}

	// one of the shell's own messages (a break reminder, a finished update)
	function mirrorToast(toast) {
		const id = toast.toastId;
		const message = {
			id: id,
			time: Date.now(),
			app: "Shell",
			title: toast.title,
			body: toast.detail,
			glyph: toast.icon,
			actions: (toast.actions || []).map((action, index) => ({ id: String(index), label: String(action.label || "") }))
		};
		if (topic.localPath(toast.image) !== "") message.image = { "$blob": topic.localPath(toast.image) };
		topic.remember(id, { toast: toast }, message);
	}

	// a notification of a program; its id never meets a toast's (those count up from 1)
	function mirrorNotification(n) {
		const id = 100000 + (Number(n.id) % 1000000);
		const message = {
			id: id,
			time: Date.now(),
			app: n.appName || "Notification",
			title: n.summary || n.appName || "",
			body: n.body || "",
			critical: n.urgency === NotificationUrgency.Critical,
			actions: Array.from(n.actions || []).filter(action => String(action.text || "").trim() !== "" && action.identifier !== "default")
				.map(action => ({ id: String(action.identifier), label: String(action.text) })),
			reply: !!n.hasInlineReply,
			placeholder: n.inlineReplyPlaceholder || "Reply"
		};
		const icon = topic.localPath(n.image) || topic.localPath(Notifs.iconFor(n.image, n.appIcon));
		if (icon !== "") message.image = { "$blob": icon };
		n.closed.connect(() => {
			if (!topic.live[id]) return;
			delete topic.live[id];
			topic.link.emit("notifications", "closed", { id: id });
		});
		topic.remember(id, { notification: n }, message);
	}

	readonly property bool mirroring: topic.allowed && topic.link.reachable && (topic.mode === "always" || (topic.mode === "away" && topic.away))
	// notifications already looked at, by their id
	property var seen: ({})

	Connections {
		target: Notifs

		// the shell's own toasts
		function onToastsChanged() {
			const fresh = Notifs.toasts.filter(toast => toast.toastId > topic.lastToast && toast.internal);
			topic.lastToast = Notifs.nextToastId;
			if (topic.mirroring) fresh.forEach(toast => topic.mirrorToast(toast));
		}

		// every notification of a program lands in a group, also during
		// do-not-disturb: the phone has a do-not-disturb of its own
		function onGroupsChanged() {
			for (const group of Notifs.groups) {
				const n = group.latestNotification;
				if (!n || n.local || topic.seen[n.id]) continue;
				topic.seen[n.id] = true;
				if (topic.mirroring && !n.lastGeneration) topic.mirrorNotification(n);
			}
		}
	}

	Component {
		id: questionComponent

		LocalNotification {}
	}

	// a question of the phone: choices become buttons, `text` a reply field
	function ask(args, done) {
		topic.asked += 1;
		let answered = false;
		let question = null;
		const answer = payload => {
			if (answered) return;
			answered = true;
			done(payload);
			question.close();
		};
		question = questionComponent.createObject(topic, {
			id: -(2000000 + topic.asked),
			appName: topic.link.name,
			summary: String(args.title || "Question"),
			body: String(args.body || ""),
			appIcon: "phone",
			urgency: NotificationUrgency.Critical,
			actions: (args.choices || []).map(choice => ({ text: String(choice.label ?? choice), identifier: String(choice.id ?? choice), invoke: () => answer({ choice: String(choice.id ?? choice) }) })),
			hasInlineReply: !!args.text,
			inlineReplyPlaceholder: String(args.placeholder || "Answer"),
			onDismissed: () => {
				if (answered) return;
				answered = true;
				done.fail("dismissed", "Dismissed on the PC");
			},
			onReplied: text => answer({ text: text })
		});
		question.closed.connect(() => Notifs.markClosed(question.id));
		Notifs.addGroup(question, Notifs.snapshot(question));
		Notifs.addToast(question);
	}

	function call(action, args, done) {
		if (action === "mode") {
			if (!["away", "always", "off"].includes(String(args.mode))) throw new Error("Unknown mode");
			topic.mode = String(args.mode);
			settings.setText(JSON.stringify({ mirror: topic.mode }, null, "\t") + "\n");
			return {};
		}
		if (action === "ask") {
			topic.ask(args, done);
			return topic.link.later;
		}
		const entry = topic.live[Number(args.id)];
		if (!entry) throw new Error("That notification is gone");
		switch (action) {
		case "act":
			if (entry.toast) {
				const button = (entry.toast.actions || [])[Number(args.action)];
				if (typeof button?.run === "function") button.run();
				Notifs.removeToast(entry.toast.toastId);
			} else {
				const button = Array.from(entry.notification.actions || []).find(a => String(a.identifier) === String(args.action));
				if (!button) throw new Error("No such action");
				button.invoke();
			}
			return {};
		case "reply":
			if (!entry.notification || !Notifs.sendReply(entry.notification, args.text)) throw new Error("Nothing to reply to");
			return {};
		case "dismiss":
			if (entry.toast) Notifs.removeToast(entry.toast.toastId);
			else entry.notification.dismiss();
			delete topic.live[Number(args.id)];
			return {};
		}
		throw new Error("unknown-action");
	}

	FileView {
		id: settings

		path: Paths.stateFile("phone.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const mode = JSON.parse(text() || "{}").mirror;
				if (["away", "always", "off"].includes(mode)) topic.mode = mode;
			} catch (error) {}
		}
	}
}
