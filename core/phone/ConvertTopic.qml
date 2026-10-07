import QtQuick
import Quickshell
import qs.core.services
import "../lib/Convert.js" as Convert

// convert: the launcher's converter (>conv) for a query typed on the phone:
// units, temperatures, number bases, money at the PC's cached rates.
Topic {
	id: topic

	name: "convert"

	// money questions that wait for the rates: [{ query, done }]
	property var waiting: []

	data: topic.wanted ? ({ rates: Converter.rates !== null, date: Converter.date, failed: Converter.failed }) : null

	onWantedChanged: if (topic.wanted && Converter.rates === null) Converter.refresh()

	function answer(query, rates) {
		const result = Convert.convert(query, rates);
		if (!result || typeof result !== "object") return { ok: false, message: "Nothing to convert" };
		return result;
	}

	function settle() {
		const pending = topic.waiting;
		topic.waiting = [];
		for (const entry of pending) entry.done(topic.answer(entry.query, Converter.rates));
	}

	Connections {
		target: Converter
		function onRatesChanged() {
			topic.settle();
		}
		function onFailedChanged() {
			if (Converter.failed) topic.settle();
		}
	}

	function call(action, args, done) {
		if (action !== "convert") throw new Error("unknown-action");
		const query = String(args.query || "").trim();
		if (query === "") throw new Error("Nothing to convert");
		const result = topic.answer(query, Converter.rates);
		// money without rates: fetch them and answer when they are there
		if (!result.ok && result.money && Converter.rates === null && !Converter.failed) {
			Converter.refresh();
			topic.waiting = topic.waiting.concat([{ query: query, done: done }]);
			return topic.link.later;
		}
		return result;
	}
}
