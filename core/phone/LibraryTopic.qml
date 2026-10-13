import QtQuick
import Quickshell
import qs.core.services

// library: the file manager from the phone. The snapshot is its home page
// (favourites, what was opened lately, tags, collections) and stays small;
// a folder, the files of a tag or a collection and a search are asked for
// and come bounded. A file can come to the phone, open on the PC or get a
// tag. Nothing is deleted, renamed or moved from here.
Topic {
	id: topic

	name: "library"
	throttle: 300

	// the most entries one answer carries
	readonly property int most: 500
	readonly property int mostFound: 200
	// hidden files show where the file manager shows them
	readonly property bool hidden: !!FileLibrary.view.hidden
	// the search under way: { id, done, entries }
	property var search: null
	property int searches: 0

	data: topic.wanted ? ({
		home: Files.home,
		favorites: FileLibrary.favorites.map(path => ({
			path: String(path),
			name: Files.nameOf(path),
			dir: true,
			favorite: true,
			tags: FileLibrary.tagsOf(path).map(id => String(id))
		})),
		recent: FileLibrary.opened.slice(0, 30).map(entry => ({
			path: String(entry.path),
			name: Files.nameOf(entry.path),
			at: Number(entry.at) || 0,
			dir: false,
			favorite: false,
			tags: FileLibrary.tagsOf(entry.path).map(id => String(id))
		})),
		tags: FileLibrary.tags.map(tag => ({
			id: String(tag.id),
			name: String(tag.name || ""),
			color: String(tag.color || ""),
			count: FileLibrary.countOf(tag.id)
		})),
		collections: FileLibrary.collections.map(collection => ({
			id: String(collection.id),
			name: String(collection.name || ""),
			count: (collection.paths || []).length
		}))
	}) : null

	// a tag counts the files that are still there
	onWantedChanged: if (topic.wanted) Files.checkTagged()

	// what the phone sends is a string of unknown make: absolute, and
	// written one way, so a tag set from here sits on the path the file
	// manager knows
	function clean(value) {
		const path = String(value ?? "");
		if (!path.startsWith("/")) throw new Error("An absolute path is needed");
		const parts = path.split("/").filter(part => part !== "" && part !== ".");
		if (parts.includes("..")) throw new Error("An absolute path is needed");
		return "/" + parts.join("/");
	}

	function shape(entry) {
		const path = String(entry.path || "");
		return {
			name: String(entry.name || ""),
			path: path,
			dir: !!entry.dir,
			size: Number(entry.size) || 0,
			mtime: Math.floor(Number(entry.mtime) || 0),
			mime: String(entry.mime || ""),
			favorite: FileLibrary.isFavorite(path),
			tags: FileLibrary.tagsOf(path).map(id => String(id))
		};
	}

	// folders first, then by name the way the daemon sorts names
	function order(a, b) {
		if (!!a.dir !== !!b.dir) return a.dir ? -1 : 1;
		const x = String(a.key ?? a.name);
		const y = String(b.key ?? b.name);
		return x < y ? -1 : x > y ? 1 : 0;
	}

	// files named one by one (a tag, a collection); what is gone drops out
	function describe(paths, done, extra) {
		const list = paths.map(path => String(path)).filter(path => path.startsWith("/"));
		Files.request("describe", { paths: list.slice(0, topic.most) }, (data, error) => {
			if (error || !data) return done.fail("failed", error || "The file manager did not answer");
			done(Object.assign({ entries: (data.entries ?? []).sort(topic.order).map(entry => topic.shape(entry)), more: list.length > topic.most }, extra));
		});
		return topic.link.later;
	}

	// what a path is, before anything is done with it; then() answers or throws
	function known(path, done, then) {
		Files.request("describe", { paths: [path] }, (data, error) => {
			const entry = data?.entries?.[0];
			if (!entry) return done.fail("failed", error || "This file does not exist (any more)");
			try {
				done(then(entry) ?? {});
			} catch (failure) {
				done.fail("failed", String(failure?.message ?? failure));
			}
		});
		return topic.link.later;
	}

	function call(action, args, done) {
		switch (action) {
		// a folder; no path is the home
		case "list": {
			const path = args.path ? topic.clean(args.path) : Files.home;
			Files.request("list", { path: path, git: false }, (data, error) => {
				if (error || !data) return done.fail("failed", error || "The file manager did not answer");
				const entries = (data.entries ?? []).filter(entry => topic.hidden || !entry.hidden).sort(topic.order);
				done({
					path: path,
					parent: path === "/" ? "" : Files.parentOf(path),
					entries: entries.slice(0, topic.most).map(entry => topic.shape(entry)),
					more: entries.length > topic.most
				});
			});
			return topic.link.later;
		}
		case "tagged": {
			const tag = FileLibrary.tagById(String(args.id || ""));
			if (!tag) throw new Error("This tag does not exist (any more)");
			return topic.describe(FileLibrary.pathsWithTag(tag.id), done, { name: String(tag.name || "") });
		}
		case "collection": {
			const collection = FileLibrary.collectionById(String(args.id || ""));
			if (!collection) throw new Error("This collection does not exist (any more)");
			return topic.describe(collection.paths || [], done, { name: String(collection.name || "") });
		}
		// by name, below a folder. The daemon runs one search at a time: this
		// one ends a search of the window, and the other way round.
		case "search": {
			const query = String(args.query || "").trim();
			if (query === "") throw new Error("What to look for?");
			const path = args.path ? topic.clean(args.path) : Files.home;
			if (topic.search) topic.search.done.fail("cancelled", "Another search started");
			topic.searches += 1;
			topic.search = { id: `phone-${topic.searches}`, done: done, entries: [] };
			Files.request("search", { search: topic.search.id, root: path, query: query, contents: false, hidden: topic.hidden, limit: topic.mostFound });
			return topic.link.later;
		}
		case "send": {
			const path = topic.clean(args.path);
			return topic.known(path, done, entry => {
				if (entry.dir) throw new Error("A folder cannot be sent");
				topic.link.sendFiles([path]);
			});
		}
		// a folder opens in the file manager, a file in its program
		case "open": {
			const path = topic.clean(args.path);
			return topic.known(path, done, entry => {
				if (entry.dir) Files.open(path);
				else Files.launch([path]);
			});
		}
		case "reveal": {
			const path = topic.clean(args.path);
			return topic.known(path, done, entry => Files.reveal([path]));
		}
		// favourites are folders, as in the file manager's sidebar
		case "favorite": {
			const path = topic.clean(args.path);
			return topic.known(path, done, entry => {
				if (!entry.dir) throw new Error("Only folders can be favorites");
				FileLibrary.toggleFavorite(path);
				return { favorite: FileLibrary.isFavorite(path) };
			});
		}
		case "tag": {
			const path = topic.clean(args.path);
			const tag = FileLibrary.tagById(String(args.id || ""));
			if (!tag) throw new Error("This tag does not exist (any more)");
			return topic.known(path, done, entry => {
				FileLibrary.toggleTag([path], tag.id);
				return { tags: FileLibrary.tagsOf(path).map(id => String(id)) };
			});
		}
		}
		throw new Error("unknown-action");
	}

	Connections {
		target: Files

		function onSearchResults(search, entries, done, error) {
			const running = topic.search;
			if (!running || search !== running.id) return;
			for (const entry of entries) running.entries.push(entry);
			if (!done) return;
			topic.search = null;
			if (error && running.entries.length === 0) return running.done.fail("failed", error);
			running.done({
				entries: running.entries.slice(0, topic.mostFound).map(entry => topic.shape(entry)),
				more: running.entries.length >= topic.mostFound
			});
		}
	}
}
