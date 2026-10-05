import QtQuick
import Quickshell.Services.Notifications

// A notification that did not come over D-Bus but looks like one to Notifs
// and its views: a notification of the phone, or a question the phone asks.
// What happens on a click is up to whoever made it (the callbacks).
QtObject {
	id: root

	property int id: 0
	property string key: ""
	property string appName: ""
	property string summary: ""
	property string body: ""
	property string image: ""
	property string appIcon: ""
	property string desktopEntry: ""
	property int urgency: NotificationUrgency.Normal
	property var hints: ({})
	// [{ text, identifier, invoke: function }]
	property var actions: []
	property bool hasInlineReply: false
	property string inlineReplyPlaceholder: "Reply"
	property real expireTimeout: -1
	property bool lastGeneration: false
	property bool tracked: true
	// never mirrored back to the phone
	readonly property bool local: true

	property var onDismissed: null
	property var onReplied: null

	signal closed(int reason)

	function close() {
		root.closed(0);
		root.destroy();
	}

	function dismiss() {
		if (root.onDismissed) root.onDismissed();
		root.close();
	}

	function expire() {
		root.close();
	}

	function sendInlineReply(text) {
		if (root.onReplied) root.onReplied(String(text));
	}
}
