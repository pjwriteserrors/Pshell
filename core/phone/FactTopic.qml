import QtQuick
import Quickshell
import qs.core.services

// fact: the useless fact of the day and where it is from.
Topic {
	id: topic

	name: "fact"

	data: topic.wanted ? ({
		text: Facts.text,
		source: Facts.source,
		sourceUrl: Facts.sourceUrl
	}) : null

	function call(action, args, done) {
		if (action !== "refresh") throw new Error("unknown-action");
		Facts.refresh();
		return {};
	}
}
