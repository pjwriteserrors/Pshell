import QtQuick
import Quickshell
import qs.core.services

// translate: the launcher's translator, for a text of the phone.
Topic {
	id: topic

	name: "translate"

	property var waiting: []

	data: topic.wanted ? ({ languages: Translator.languages, target: Translator.target }) : null

	Connections {
		target: Translator
		function onFinished() {
			const pending = topic.waiting;
			topic.waiting = [];
			for (const done of pending) {
				if (Translator.error !== "") done.fail("failed", Translator.error);
				else done({ text: Translator.result, source: Translator.source, target: Translator.resultTarget });
			}
		}
	}

	function call(action, args, done) {
		if (action !== "translate") throw new Error("unknown-action");
		const text = String(args.text || "").trim();
		if (text === "") throw new Error("Nothing to translate");
		topic.waiting = topic.waiting.concat([done]);
		Translator.clear();
		Translator.request(text, String(args.target || "auto"));
		// the request is debounced on the PC; this skips the wait
		Translator.start();
		return topic.link.later;
	}
}
