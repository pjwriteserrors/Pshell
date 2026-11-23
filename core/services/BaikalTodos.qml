pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The tasks of Tasks.md (Todos) and the tasks (VTODO) of one Baikal calendar
// kept the same both ways, so the phone has them (DAVx5 → Tasks.org, …).
// nas.json `calendar.todos: { on, calendar }`. A task is matched by its
// group and title: the group is the VTODO's category, [ ] / x - its STATUS
// (NEEDS-ACTION, IN-PROCESS, COMPLETED, CANCELLED), ⏫ 🔼 🔽 its PRIORITY,
// the description its DESCRIPTION. What was the same at the last sync is
// kept in baikal-todos.json; a side that changed since wins, Baikal when
// both did. A title changed on one side is a task gone and a new one. When
// the server gives no task at all while several were there, nothing is
// deleted on this side (a calendar emptied by mistake).
Singleton {
	id: root

	readonly property var settings: NasCalendar.config.todos ?? ({})
	readonly property bool on: NasCalendar.active && !!root.settings.on && Todos.tasksLoaded
	readonly property string calendar: String(root.settings.calendar || NasCalendar.defaultCalendar())
	property bool busy: false
	property bool again: false
	property string error: ""
	property real syncedAt: 0
	// uid → { href, etag, group, title, mark, priority, note }
	property var known: ({})

	function setTodos(change) {
		Nas.setLocal("calendar", Object.assign({}, NasCalendar.config, { todos: Object.assign({}, root.settings, change) }));
		if (change.calendar !== undefined) {
			root.known = {};
			store.setText("{}");
		}
		Qt.callLater(root.sync);
	}

	FileView {
		id: store

		path: Paths.stateFile("baikal-todos.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.known = JSON.parse(store.text() || "{}");
			} catch (e) {
				root.known = {};
			}
		}
	}

	function save() {
		store.setText(JSON.stringify(root.known));
	}

	function markOf(status) {
		switch (status) {
		case "COMPLETED":
			return "x";
		case "IN-PROCESS":
			return "/";
		case "CANCELLED":
			return "-";
		default:
			return " ";
		}
	}

	// marks Baikal has no word for (! ? …) stay as they are while it says "open"
	function sameMark(local, remote) {
		return local === remote || (remote === " " && !["x", "X", "/", "-"].includes(local));
	}

	function localOf(entry) {
		return Todos.tasks.find(task => task.indent === 0 && task.group === entry.group && task.text === entry.title) ?? null;
	}

	function snapshot(task, remote) {
		return { href: remote.href, etag: remote.etag, group: task.group, title: task.text, mark: task.mark === "X" ? "x" : task.mark, priority: task.priority, note: task.note };
	}

	function push(task, entry, done) {
		NasCalendar.write("savetodo", {
			calendar: root.calendar,
			href: entry?.href ?? "",
			etag: entry?.etag ?? "",
			title: task.text,
			note: task.note,
			mark: task.mark === "X" ? "x" : task.mark,
			priority: task.priority,
			category: task.group
		}, reply => done(reply));
	}

	function sync() {
		if (!root.on || root.calendar === "") return;
		if (root.busy) {
			root.again = true;
			return;
		}
		root.busy = true;
		NasCalendar.write("todos", { calendar: root.calendar }, reply => {
			if (reply.error) {
				root.error = reply.error;
				return root.finish();
			}
			root.error = "";
			root.merge(reply.todos ?? []);
		});
	}

	function finish() {
		root.busy = false;
		root.syncedAt = Date.now();
		root.save();
		if (root.again) {
			root.again = false;
			Qt.callLater(root.sync);
		}
	}

	function merge(remote) {
		const byUid = {};
		for (const todo of remote) byUid[todo.uid] = todo;
		const known = Object.assign({}, root.known);
		const careful = remote.length === 0 && Object.keys(known).length > 2;
		const jobs = [];
		const matched = new Set();

		for (const uid of Object.keys(known)) {
			const entry = known[uid];
			const there = byUid[uid];
			const task = root.localOf(entry);
			if (task) matched.add(task.key);
			if (!there && !task) {
				delete known[uid];
			} else if (!there) {
				// gone from Baikal (done and cleared on the phone, deleted): gone here too
				if (!careful) {
					Todos.deleteTask(task.key);
					delete known[uid];
				}
			} else if (!task) {
				// gone from Tasks.md
				jobs.push(done => NasCalendar.write("delete", { href: there.href, etag: there.etag }, () => {
					delete known[uid];
					done();
				}));
			} else if (there.etag !== entry.etag) {
				// changed in Baikal: into Tasks.md
				const mark = root.markOf(there.status);
				let key = task.key;
				if (there.title !== task.text || there.note !== task.note) Todos.setContent(key, there.title || task.text, there.note);
				const now = root.localOf({ group: task.group, title: there.title || task.text }) ?? task;
				if (!root.sameMark(now.mark, mark)) Todos.setMark(now.key, mark);
				const after = root.localOf({ group: now.group, title: now.text }) ?? now;
				if (after.priority !== there.priority) Todos.setPriority(after.key, there.priority);
				const final = root.localOf({ group: after.group, title: after.text }) ?? after;
				matched.add(final.key);
				known[uid] = root.snapshot(final, there);
			} else {
				const mark = task.mark === "X" ? "x" : task.mark;
				if (mark !== entry.mark || task.priority !== entry.priority || task.note !== entry.note) {
					jobs.push(done => root.push(task, there, reply => {
						if (!reply.error) known[uid] = root.snapshot(task, reply);
						done();
					}));
				}
			}
		}

		// new in Baikal: into Tasks.md (its category is the group)
		const knownUids = new Set(Object.keys(known));
		for (const todo of remote) {
			if (knownUids.has(todo.uid) || !todo.title) continue;
			const group = todo.category || Todos.inbox;
			let task = root.localOf({ group: group, title: todo.title });
			if (!task || matched.has(task.key)) {
				Todos.addPlain(group, todo.title);
				task = Todos.tasks.filter(t => t.group === group && t.text === todo.title && !matched.has(t.key)).pop() ?? null;
				if (!task) continue;
				const mark = root.markOf(todo.status);
				if (mark !== " ") Todos.setMark(task.key, mark);
				if (todo.priority) Todos.setPriority(root.localOf({ group: group, title: todo.title }).key, todo.priority);
				if (todo.note) Todos.setContent(root.localOf({ group: group, title: todo.title }).key, todo.title, todo.note);
				task = root.localOf({ group: group, title: todo.title });
			}
			matched.add(task.key);
			known[todo.uid] = root.snapshot(task, todo);
		}

		// new in Tasks.md: to Baikal (cancelled ones stay here)
		for (const task of Todos.tasks) {
			if (task.indent !== 0 || matched.has(task.key) || task.mark === "-") continue;
			matched.add(task.key);
			jobs.push(done => root.push(task, null, reply => {
				if (!reply.error) {
					known[reply.uid] = root.snapshot(task, reply);
				}
				done();
			}));
		}

		const step = () => {
			if (jobs.length === 0) {
				root.known = known;
				return root.finish();
			}
			jobs.shift()(step);
		};
		step();
	}

	// Tasks.md changed (here, in Obsidian, from the NAS): a moment later
	Connections {
		target: Todos

		function onTasksTextChanged() {
			if (root.on && !root.busy) soon.restart();
		}
	}

	Timer {
		id: soon
		interval: 4000
		onTriggered: root.sync()
	}

	Timer {
		running: root.on
		repeat: true
		interval: 5 * 60000
		triggeredOnStart: true
		onTriggered: root.sync()
	}
}
