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
		for (let i = root.count - 1; i >= 0; i -= 1) {
			if (keys.indexOf(root.get(i).key) < 0) root.remove(i);
		}
		for (let i = 0; i < list.length; i += 1) {
			const json = JSON.stringify(list[i]);
			let at = -1;
			for (let j = i; j < root.count; j += 1) {
				if (root.get(j).key === keys[i]) {
					at = j;
					break;
				}
			}
			if (at < 0) {
				root.insert(i, { key: keys[i], json });
				continue;
			}
			if (at !== i) root.move(at, i, 1);
			if (root.get(i).json !== json) root.setProperty(i, "json", json);
		}
	}
}
