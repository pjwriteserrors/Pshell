import QtQuick
import Quickshell

// One topic of mobile/protocol/protocol.json that the shell owns: `data` is
// its snapshot, call() runs what the phone asks for. Nothing is computed or
// sent while nobody is subscribed: bind data as `wanted ? ({ … }) : null`.
Scope {
	id: topic

	required property var link
	property string name: ""
	property var data: null
	// at most one snapshot per this many ms
	property int throttle: 80

	readonly property bool allowed: topic.link.allowed(topic.name)
	readonly property bool wanted: topic.allowed && topic.link.connected && topic.link.wanted.includes(topic.name)
	property string sent: ""

	// returns the answer, or link.later and answers through done(data) /
	// done.fail(code, message); throws "unknown-action" for the rest
	function call(action, args, done) {
		throw new Error("unknown-action");
	}

	function flush() {
		if (!topic.wanted) return;
		const text = JSON.stringify(topic.data ?? null);
		if (text === topic.sent) return;
		topic.sent = text;
		topic.link.sendRaw(`{"type":"state","topic":${JSON.stringify(topic.name)},"data":${text}}`);
	}

	onDataChanged: if (topic.wanted && !timer.running) timer.start()
	onWantedChanged: {
		topic.sent = "";
		if (topic.wanted) timer.restart();
	}

	Timer {
		id: timer

		interval: topic.throttle
		onTriggered: topic.flush()
	}

	Component.onCompleted: topic.link.register(topic)
}
