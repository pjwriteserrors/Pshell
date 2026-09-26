pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Markdown sticky notes (notes.json), pinned to the bar.
Singleton {
	id: root

	property var notes: []
	property bool collapsed: false
	readonly property var pinned: root.notes.filter(note => note.pinned !== false)

	function load(raw) {
		try {
			const data = JSON.parse(String(raw || "[]"));
			root.notes = Array.isArray(data) ? data.map((note, index) => ({
				id: String(note.id || `legacy-${index}`),
				title: String(note.title || ""),
				body: String(note.body || ""),
				pinned: note.pinned !== false
			})) : [];
		} catch (error) {
			root.notes = [];
		}
	}

	function save(next) {
		root.notes = next || [];
		file.setText(JSON.stringify(root.notes, null, 2));
	}

	function find(id) {
		return root.notes.find(note => String(note.id) === String(id)) || null;
	}

	// returns the id of the stored note
	function upsert(id, title, body) {
		const next = root.notes.slice();
		const index = next.findIndex(note => String(note.id) === String(id));
		const note = { id: String(id || ""), title: String(title || "").trim(), body: String(body || ""), pinned: true };
		if (index < 0 || note.id === "") {
			note.id = `${Date.now()}-${Math.floor(Math.random() * 100000)}`;
			next.push(note);
		} else {
			next[index] = note;
		}
		root.save(next);
		return note.id;
	}

	function remove(id) {
		root.save(root.notes.filter(note => String(note.id) !== String(id)));
	}

	function titleOf(note) {
		const title = String(note?.title || "").trim();
		if (title !== "") return title;
		const firstLine = String(note?.body || "").split("\n").find(line => line.trim() !== "") || "Note";
		return firstLine.replace(/^#+\s*/, "").trim();
	}

	// Markdown with single newlines kept as line breaks (outside code fences).
	function markdown(raw) {
		const lines = String(raw || "").replace(/\r\n/g, "\n").split("\n");
		const rendered = [];
		let insideFence = false;
		for (let i = 0; i < lines.length; i += 1) {
			const line = lines[i];
			const trimmed = line.trim();
			if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
				rendered.push(line);
				insideFence = !insideFence;
				continue;
			}
			if (insideFence || i === lines.length - 1 || trimmed === "" || lines[i + 1].trim() === "" || /\s{2}$/.test(line) || /\\$/.test(line))
				rendered.push(line);
			else
				rendered.push(`${line}  `);
		}
		return rendered.join("\n");
	}

	FileView {
		id: file
		// a machine without notes never reads the file
		path: Host.has("notes") ? Paths.stateFile("notes.json") : ""
		printErrors: false
		onLoaded: root.load(text())
	}
}
