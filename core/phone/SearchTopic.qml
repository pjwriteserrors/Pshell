import QtQuick
import Quickshell
import qs.core.services

// search: a web search, or a page, opened in the PC's browser.
Topic {
	id: topic

	name: "search"

	function call(action, args, done) {
		switch (action) {
		case "search":
			Browser.search(String(args.query || ""));
			return {};
		case "open":
			if (!/^https?:\/\//.test(String(args.url))) throw new Error("Not a link");
			Browser.open(String(args.url));
			return {};
		}
		throw new Error("unknown-action");
	}
}
