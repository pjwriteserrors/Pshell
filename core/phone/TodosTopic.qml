import QtQuick
import Quickshell
import Quickshell.Io
import qs.core.services

// todos: the tasks of Tasks.md as the shell's board has them – groups, their
// categories, each task's state, priority, description and the notes it
// links. A task is named by its key; one that changed in the meantime is
// left alone (Todos.editTask). A note is read on demand.
Topic {
	id: topic

	name: "todos"
	throttle: 150

	function task(entry) {
		return {
			key: entry.key,
			mark: entry.mark === "X" ? "x" : entry.mark,
			text: entry.text,
			note: entry.note,
			priority: entry.priority,
			notes: entry.notes,
			section: entry.section,
			indent: entry.indent,
			done: entry.done,
			closed: entry.closed,
			classifying: Todos.isClassifying(entry.key)
		};
	}

	data: topic.wanted ? ({
		loaded: Todos.tasksLoaded,
		inbox: Todos.inbox,
		states: Todos.states.map(state => ({ mark: state.mark, name: state.name, icon: state.icon })),
		groups: Todos.groups.map(group => ({
			name: group.name,
			open: group.open,
			done: group.done,
			categories: group.categories,
			tasks: Todos.openOf(group).concat(Todos.closedOf(group)).map(entry => topic.task(entry))
		})),
		notes: Todos.notes.map(note => note.name)
	}) : null

	function key(args) {
		const key = String(args.key || "");
		if (!Todos.findTask(key)) throw new Error("The task changed in the meantime");
		return key;
	}

	function call(action, args, done) {
		switch (action) {
		case "toggle":
			Todos.toggleTask(topic.key(args));
			return {};
		case "mark": {
			const mark = String(args.mark ?? "");
			if (!Todos.states.some(state => state.mark === mark)) throw new Error("No such state");
			Todos.setMark(topic.key(args), mark);
			return {};
		}
		case "priority": {
			const level = Number(args.level);
			if (![0, 1, 2, 3].includes(level)) throw new Error("No such priority");
			Todos.setPriority(topic.key(args), level);
			return {};
		}
		case "edit":
			if (String(args.title || "").trim() === "") throw new Error("A task needs a title");
			Todos.setContent(topic.key(args), String(args.title), String(args.description ?? ""));
			return {};
		case "move": {
			const group = String(args.group || "");
			if (!Todos.findGroup(group)) throw new Error("No such group");
			Todos.moveTask(topic.key(args), group);
			return {};
		}
		case "category": {
			const key = topic.key(args);
			const section = String(args.category ?? "");
			if (section !== "" && !(Todos.findGroup(Todos.findTask(key).group)?.categories ?? []).includes(section)) throw new Error("No such category");
			Todos.setCategory(key, section);
			return {};
		}
		case "delete":
			Todos.deleteTask(topic.key(args));
			return {};
		case "add": {
			const group = Todos.addTask(String(args.group || Todos.inbox), String(args.text || "").replace(/\n/g, " "));
			if (group === "") throw new Error("Nothing to add");
			return { group };
		}
		case "group": {
			const name = Todos.groupNameFor(args.name);
			if (name === "") throw new Error("A group needs a name");
			if (Todos.findGroup(name)) throw new Error("There is a group of that name");
			Todos.addGroup(name);
			return { name };
		}
		case "note": {
			const note = Todos.findNote(String(args.name || ""));
			if (!note) throw new Error("No such note");
			const file = reader.createObject(topic, { path: note.path });
			const text = String(file.text() ?? "");
			file.destroy();
			return { text: text.length > 200000 ? text.slice(0, 200000) : text };
		}
		case "show":
			if (args.key && Todos.findTask(String(args.key))) Todos.showTask(String(args.key));
			else Todos.openLauncher();
			return {};
		}
		throw new Error("unknown-action");
	}

	Component {
		id: reader

		FileView {
			blockAllReads: true
			printErrors: false
		}
	}
}
