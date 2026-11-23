import QtQuick

// A ListModel that follows an array of objects with a `key`: changed items
// are updated in place, new ones inserted, gone ones removed and the rest
// moved into order, so a view can animate what changed instead of
// rebuilding. A row carries key and json (the item; JSON.parse it).
ListModel {
	id: root

	function sync(items) {
		const list = items ?? [];
		const keys = list.map(item => String(item.key));
		const wanted = new Set(keys);
		// the keys as they stand, kept beside the model: asking the model for
		// each one again is what made long lists slow
		const current = [];
		for (let i = 0; i < root.count; i += 1) current.push(root.get(i).key);
		for (let i = current.length - 1; i >= 0; i -= 1) {
			if (!wanted.has(current[i])) {
				root.remove(i);
				current.splice(i, 1);
			}
		}
		for (let i = 0; i < list.length; i += 1) {
			const json = JSON.stringify(list[i]);
			const at = current.indexOf(keys[i], i);
			if (at < 0) {
				root.insert(i, { key: keys[i], json });
				current.splice(i, 0, keys[i]);
				continue;
			}
			if (at !== i) {
				root.move(at, i, 1);
				current.splice(at, 1);
				current.splice(i, 0, keys[i]);
			}
			if (root.get(i).json !== json) root.setProperty(i, "json", json);
		}
	}
}
