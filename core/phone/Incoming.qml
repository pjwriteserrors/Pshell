pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Services.Notifications
import qs.core.services

// What the phone tells the shell: its notifications land in the shell's
// notification centre (with their actions and replies going back), a call
// pauses what plays.
Scope {
	id: root

	required property var link

	// key → the notification shown for it
	property var shown: ({})
	property int counter: 0
	// players this paused for a call, to start them again after it
	property var pausedForCall: []

	Component {
		id: notificationComponent

		LocalNotification {}
	}

	function forget(key) {
		const old = root.shown[key];
		if (!old) return;
		delete root.shown[key];
		old.close();
	}

	function posted(data, device) {
		const key = String(data.key || "");
		if (key === "") return;
		root.forget(key);
		root.counter += 1;
		const act = (action, args) => root.link.call("phone.notifications", action, Object.assign({ key: key }, args || {}), null, { device: device });
		const actions = (data.actions || []).filter(action => !action.reply).map(action => ({
			text: String(action.label || ""),
			identifier: String(action.id),
			invoke: () => act("act", { action: action.id })
		}));
		// a code in a message (2FA) can be copied with one click
		const code = String(`${data.title || ""} ${data.text || ""}`).match(/(?:^|[^\d])(\d{4,8})(?!\d)/);
		if (code && /code|pin|otp|tan|verif|bestätig|passwor|kennwor/i.test(String(data.text || "")))
			actions.unshift({ text: `Copy ${code[1]}`, identifier: "copy-code", invoke: () => Quickshell.execDetached(["wl-copy", "--", code[1]]) });
		if (data.canOpen) actions.unshift({ text: "", identifier: "default", invoke: () => {} });
		const replyAction = (data.actions || []).find(action => action.reply);
		const notification = notificationComponent.createObject(root, {
			id: -(1000000 + root.counter),
			key: key,
			appName: String(data.app || root.link.name),
			summary: String(data.title || data.app || ""),
			body: String(data.text || ""),
			image: String(data.icon || ""),
			appIcon: "phone",
			urgency: data.silent ? NotificationUrgency.Low : NotificationUrgency.Normal,
			actions: actions,
			hasInlineReply: !!replyAction,
			inlineReplyPlaceholder: String(replyAction?.label || "Reply"),
			onDismissed: () => {
				delete root.shown[key];
				act("dismiss");
			},
			onReplied: text => act("reply", { action: replyAction.id, text: text })
		});
		root.shown[key] = notification;
		notification.closed.connect(() => Notifs.markClosed(notification.id));
		Notifs.addGroup(notification, Notifs.snapshot(notification));
		// an update of something already seen, or a quiet one, makes no toast
		if (data.update || data.silent) return;
		if (Notifs.dnd) return;
		Notifs.addToast(notification);
	}

	function telephony(data) {
		const state = String(data.state || "");
		const who = String(data.name || data.number || "Unknown number");
		if (state === "ringing" || state === "offhook") {
			if (root.pausedForCall.length === 0) {
				const playing = Mpris.players.values.filter(player => player.isPlaying && player.canPause);
				for (const player of playing) player.pause();
				root.pausedForCall = playing;
			}
			if (state === "ringing") Notifs.pushInternal("running", "Incoming call", who, {
				icon: "phone_ring",
				duration: 20000,
				actions: [{ label: "Silence", icon: "volume_off", run: () => root.link.call("phone.telephony", "silence") }]
			});
		} else if (state === "idle") {
			for (const player of root.pausedForCall)
				if (Mpris.players.values.includes(player) && player.canPlay) player.play();
			root.pausedForCall = [];
		}
	}

	// a file of the phone arrived in the downloads folder (a shelf that
	// watches it shows it by itself)
	function received(data) {
		const path = String(data.path || "");
		const image = /\.(png|jpe?g|webp|gif)$/i.test(path);
		Notifs.pushInternal("done", String(data.name || "File"), `From ${data.from || root.link.name}`, {
			icon: "file_download_outline",
			image: image ? path : "",
			duration: 9000,
			actions: [
				{ label: "Open", icon: "open_in_new", run: () => Quickshell.execDetached(["xdg-open", path]) },
				{ label: "Folder", icon: "folder_outline", run: () => Quickshell.execDetached(["xdg-open", path.replace(/\/[^/]*$/, "")]) }
			]
		});
	}

	Connections {
		target: root.link

		function onEvent(topic, name, data, device) {
			if (topic === "phone.notifications" && name === "posted") root.posted(data, device);
			else if (topic === "phone.notifications" && name === "removed") root.forget(String(data.key || ""));
			else if (topic === "phone.telephony" && name === "call") root.telephony(data);
			else if (topic === "files" && name === "received") root.received(data);
		}

		// a phone that is gone cannot answer for its notifications; one that
		// came tells what it has (the shell may have started after it)
		function onReachableChanged() {
			if (root.link.reachable) {
				root.sync();
				return;
			}
			for (const key of Object.keys(root.shown)) root.forget(key);
		}
	}

	function sync() {
		root.link.call("phone.notifications", "sync", {}, () => {});
	}

	Component.onCompleted: if (root.link.reachable) root.sync()
}
