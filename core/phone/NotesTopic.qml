import QtQuick
import Quickshell
import qs.core.services

// notes: the shell's notes, to read and write from the phone.
Topic {
	id: topic

	name: "notes"

	data: topic.wanted ? ({
		notes: Notes.notes.map(note => ({ id: note.id, title: Notes.titleOf(note), ownTitle: note.title, body: note.body, pinned: note.pinned !== false }))
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "save":
			return { id: Notes.upsert(String(args.id || ""), String(args.title || ""), String(args.body || "")) };
		case "remove":
			Notes.remove(String(args.id));
			return {};
		}
		throw new Error("unknown-action");
	}
}
