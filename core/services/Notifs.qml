pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.style.theme

// Notification server, grouped history for the notification center and the
// transient toast stack. Internal messages (e.g. theme task progress) can be
// pushed as toasts without a D-Bus notification behind them.
Singleton {
	id: root

	property int nextToastId: 0
	property var toasts: []
	property var groups: []
	readonly property int count: root.groups.length

	// ── do not disturb ─────────────────────────────────────────────────────
	// Notifications still land in the list, only toasts and haptics pause.
	// Critical ones always come through.
	property bool dndManual: false
	property bool dndWhileTracking: true
	property bool dndFullscreen: true
	property bool dndSharing: true
	readonly property bool trackingNow: Tmpo.tracking && !Tmpo.paused
	// a screencast of someone else than the shell's own live pins
	readonly property bool sharing: Niri.casts.some(cast => cast.is_active && !Screenshot.liveNodes.includes(Number(cast.pw_node_id)))
	readonly property bool dndAuto: (root.dndWhileTracking && root.trackingNow) || (root.dndFullscreen && Niri.focusedFullscreen) || (root.dndSharing && root.sharing)
	// switched off by hand while a rule applied: stays off until the rule ends
	property bool dndAutoSuppressed: false
	readonly property bool dnd: root.dndManual || (root.dndAuto && !root.dndAutoSuppressed)
	readonly property string dndReason: {
		if (root.dndManual) return "On";
		if (!root.dnd) return "Off";
		if (root.dndSharing && root.sharing) return "Sharing";
		return root.dndFullscreen && Niri.focusedFullscreen ? "Fullscreen" : "Tracking";
	}

	onDndAutoChanged: if (!root.dndAuto) root.dndAutoSuppressed = false

	function setDnd(on) {
		if (!!on === root.dnd) return;
		if (on) {
			root.dndManual = true;
		} else {
			root.dndManual = false;
			root.dndAutoSuppressed = root.dndAuto;
		}
		Haptics.play(on ? "dndOn" : "dndOff");
		root.persist();
	}

	function toggleDnd() {
		root.setDnd(!root.dnd);
	}

	function setDndRule(rule, on) {
		if (rule === "tracking") root.dndWhileTracking = !!on;
		else if (rule === "fullscreen") root.dndFullscreen = !!on;
		else if (rule === "sharing") root.dndSharing = !!on;
		root.persist();
	}

	function persist() {
		settings.setText(JSON.stringify({
			dnd: root.dndManual,
			whileTracking: root.dndWhileTracking,
			fullscreen: root.dndFullscreen,
			sharing: root.dndSharing
		}, null, 2));
	}

	FileView {
		id: settings

		path: Paths.stateFile("dnd.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.dndManual = data.dnd === true;
				root.dndWhileTracking = data.whileTracking !== false;
				root.dndFullscreen = data.fullscreen !== false;
				root.dndSharing = data.sharing !== false;
			} catch (error) {}
		}
	}

	function toastDuration(expireTimeout) {
		if (expireTimeout <= 0) return 5000;
		return expireTimeout < 1000 ? expireTimeout * 1000 : expireTimeout;
	}

	function appKey(notification) {
		const parts = [];
		if (notification.appName) parts.push(notification.appName);
		if (notification.appIcon) parts.push(notification.appIcon);
		if (notification.desktopEntry) parts.push(notification.desktopEntry);
		if (parts.length === 0) return String(notification.id);
		return parts.join("::");
	}

	function snapshot(notification) {
		return {
			notificationId: notification.id,
			appKey: root.appKey(notification),
			appName: notification.appName || "Notification",
			summary: notification.summary || notification.appName || "Notification",
			body: notification.body || "",
			urgency: notification.urgency,
			progressValue: notification.hints.value !== undefined ? Number(notification.hints.value) : -1,
			image: notification.image || "",
			appIcon: notification.appIcon || "",
			hasInlineReply: notification.hasInlineReply,
			inlineReplyPlaceholder: notification.inlineReplyPlaceholder || "Reply",
			timestamp: Date.now(),
			active: true
		};
	}

	function formatTime(timestamp) {
		const delta = Math.max(0, Date.now() - Number(timestamp || 0));
		if (delta < 60000) return "now";
		if (delta < 3600000) return `${Math.floor(delta / 60000)} min`;
		return Qt.formatDateTime(new Date(timestamp), "HH:mm");
	}

	function addGroup(notification, snap) {
		const groups = root.groups.slice();
		let existingIndex = -1;
		for (let i = 0; i < groups.length; i += 1) {
			if (groups[i].key === snap.appKey) {
				existingIndex = i;
				break;
			}
		}

		let group;
		if (existingIndex >= 0) {
			group = groups[existingIndex];
			group.notifications = [snap].concat(group.notifications);
			group.latestSnapshot = snap;
			group.latestNotification = notification;
			group.latestNotificationId = snap.notificationId;
			group.appName = snap.appName;
			group.appIcon = snap.appIcon;
			group.image = snap.image;
			group.urgency = snap.urgency;
			groups.splice(existingIndex, 1);
		} else {
			group = {
				key: snap.appKey,
				appName: snap.appName,
				appIcon: snap.appIcon,
				image: snap.image,
				urgency: snap.urgency,
				expanded: false,
				latestSnapshot: snap,
				latestNotification: notification,
				latestNotificationId: snap.notificationId,
				notifications: [snap]
			};
		}
		groups.unshift(group);
		root.groups = groups;
	}

	function register(notification) {
		// niri announces the window shots the screenshot editor takes itself
		if (String(notification.appName) === "niri" && `${notification.image ?? ""} ${notification.appIcon ?? ""}`.indexOf("/qs-screenshot/") >= 0) {
			notification.dismiss();
			return;
		}
		root.addGroup(notification, root.snapshot(notification));
		// carried over from before a shell reload: already seen, no toast again
		if (notification.lastGeneration) return;
		if (root.dnd && notification.urgency !== NotificationUrgency.Critical) return;
		root.addToast(notification);
		Haptics.play("notification");
	}

	function addToast(notification) {
		root.nextToastId += 1;
		root.toasts = root.toasts.concat([{
			toastId: root.nextToastId,
			notificationId: notification.id,
			notification: notification,
			internal: false,
			duration: root.toastDuration(notification.expireTimeout)
		}]);
	}

	// status: "running" | "done" | "error" | anything
	// options (all optional):
	//   icon     – glyph name instead of the status glyph
	//   image    – file:// or absolute path, shown as a thumbnail
	//   actions  – [{ label, icon, run: function }], clicking one closes the toast
	//   duration – ms
	// Internal toasts are feedback for something the user just did, so they
	// show during do-not-disturb as well.
	function pushInternal(status, title, detail, options) {
		const extra = options || {};
		root.nextToastId += 1;
		root.toasts = root.toasts.concat([{
			toastId: root.nextToastId,
			notificationId: -root.nextToastId,
			notification: null,
			internal: true,
			status: String(status || ""),
			title: String(title || ""),
			detail: String(detail || ""),
			icon: String(extra.icon || ""),
			image: String(extra.image || ""),
			actions: Array.isArray(extra.actions) ? extra.actions : [],
			duration: Number(extra.duration) > 0 ? Number(extra.duration) : (String(status) === "running" ? 8000 : 5000)
		}]);
		return root.nextToastId;
	}

	function removeToast(toastId) {
		root.toasts = root.toasts.filter(toast => toast.toastId !== toastId);
	}

	function dismissToast(toast) {
		if (!toast) return;
		if (toast.notification) toast.notification.dismiss();
		root.removeToast(toast.toastId);
	}

	function removeToastByNotificationId(notificationId) {
		const kept = root.toasts.filter(toast => toast.notificationId !== notificationId);
		if (kept.length !== root.toasts.length) root.toasts = kept;
	}

	function markClosed(notificationId) {
		const groups = root.groups.slice();
		let changed = false;
		for (const group of groups) {
			for (const snap of group.notifications) {
				if (snap.notificationId === notificationId && snap.active) {
					snap.active = false;
					changed = true;
				}
			}
			if (group.latestNotification && group.latestNotification.id === notificationId) {
				group.latestNotification = null;
				changed = true;
			}
		}
		if (changed) root.groups = groups;
		root.removeToastByNotificationId(notificationId);
	}

	function setExpanded(key, expanded) {
		const groups = root.groups.slice();
		for (const group of groups) {
			if (group.key === key) {
				group.expanded = expanded;
				root.groups = groups;
				return;
			}
		}
	}

	function dismissGroup(key) {
		const groups = [];
		for (const group of root.groups) {
			if (group.key === key) {
				if (group.latestNotification) group.latestNotification.dismiss();
				continue;
			}
			groups.push(group);
		}
		root.groups = groups;
	}

	function dismissAll() {
		for (const group of root.groups)
			if (group.latestNotification) group.latestNotification.dismiss();
		root.groups = [];
	}

	function urgencyColor(urgency) {
		if (urgency === NotificationUrgency.Critical) return Theme.danger;
		if (urgency === NotificationUrgency.Low) return Theme.textSubtle;
		return Theme.primary;
	}

	function iconFor(image, appIcon) {
		if (image && image !== "") return image;
		return AppIcons.app(appIcon, ["dialog-information-symbolic", "dialog-information"]);
	}

	function sendReply(notification, text) {
		const reply = String(text || "").trim();
		if (!notification || reply === "") return false;
		notification.sendInlineReply(reply);
		return true;
	}

	NotificationServer {
		id: server

		actionsSupported: true
		bodySupported: true
		bodyMarkupSupported: false
		inlineReplySupported: true
		persistenceSupported: true
		imageSupported: true

		onNotification: notification => {
			notification.tracked = true;
			root.register(notification);
			notification.closed.connect(() => root.markClosed(notification.id));
		}
	}
}
