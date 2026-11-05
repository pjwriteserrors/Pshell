import QtQuick

// A ListModel of keys that follows an ordered list of them: gone keys are
// removed, new ones inserted and the rest moved into place, so the list
// animates what changed. Unlike SyncedModel it keeps no data, only the key –
// a row reads what it shows by its key – and finds keys in a plain array, so
// following a list of several hundred costs next to nothing.
ListModel {
	id: root

	property var keys: []

	function sync(list) {
		const next = list ?? [];
		const wanted = new Set(next);
		const keys = root.keys;
		for (let i = keys.length - 1; i >= 0; i -= 1) {
			if (!wanted.has(keys[i])) {
				root.remove(i);
				keys.splice(i, 1);
			}
		}
		for (let i = 0; i < next.length; i += 1) {
			const key = next[i];
			if (keys[i] === key) continue;
			const at = keys.indexOf(key, i + 1);
			if (at < 0) {
				root.insert(i, { key: key });
				keys.splice(i, 0, key);
			} else {
				root.move(at, i, 1);
				keys.splice(at, 1);
				keys.splice(i, 0, key);
			}
		}
		root.keys = keys;
	}
}
