import QtQuick
import Quickshell
import qs.core.services

// shelves: the stashes on the desktop and what lies on them; files go from a
// shelf to the phone and from the phone onto a shelf.
Topic {
	id: topic

	name: "shelves"

	data: topic.wanted ? ({
		shelves: Shelf.shelves.map(shelf => ({
			id: shelf.id,
			name: Shelf.titleOf(shelf),
			output: shelf.output,
			items: (shelf.items || []).map(item => ({
				id: item.id,
				kind: item.kind,
				name: item.name,
				path: item.path,
				url: item.url,
				text: item.text,
				size: item.size,
				icon: Shelf.iconFor(item),
				image: Shelf.pictureOf(item) !== "" ? { "$blob": Shelf.pictureOf(item) } : null
			}))
		})),
		recent: Shelf.recent.map(shelf => ({ id: shelf.id, name: Shelf.titleOf(shelf), count: (shelf.items || []).length }))
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "send": {
			const shelf = Shelf.shelfById(args.id);
			const item = shelf?.items.find(entry => entry.id === args.item);
			if (!item) throw new Error("That is gone from the shelf");
			if (item.kind === "file") topic.link.sendFiles([item.path]);
			else topic.link.sendText(item.url || item.text);
			return {};
		}
		case "sendAll": {
			const shelf = Shelf.shelfById(args.id);
			if (!shelf) throw new Error("That shelf is gone");
			const files = shelf.items.filter(item => item.kind === "file").map(item => item.path);
			if (files.length > 0) topic.link.sendFiles(files);
			return { sent: files.length };
		}
		// a file the phone uploaded, or a text, onto a shelf (a new one without an id)
		case "add": {
			const items = [];
			for (const path of args.paths || []) items.push({ kind: "file", path: String(path) });
			if (args.text) items.push(/^https?:\/\/\S+$/.test(String(args.text).trim()) ? { kind: "link", url: String(args.text).trim() } : { kind: "text", text: String(args.text) });
			if (items.length === 0) throw new Error("Nothing to put on the shelf");
			if (args.id !== undefined && Shelf.shelfById(args.id)) Shelf.addItems(args.id, items);
			else Shelf.create(items, String(args.name || ""));
			return {};
		}
		case "remove":
			Shelf.remove(args.id, args.item);
			return {};
		case "close":
			Shelf.close(args.id);
			return {};
		case "reopen":
			Shelf.reopen(args.id);
			return {};
		case "forget":
			Shelf.forgetRecent(args.id);
			return {};
		case "clipboard":
			Shelf.fromClipboard();
			return {};
		case "locate":
			Shelf.locate(args.id);
			return {};
		}
		throw new Error("unknown-action");
	}
}
