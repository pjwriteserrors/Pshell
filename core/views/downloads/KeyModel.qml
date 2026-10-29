import QtQuick

// A ListModel that follows a list of keys by inserting, moving and removing
// rows instead of being made anew, so a ListView animates what comes and goes.
QtObject {
	id: root

	property var keys: []
	readonly property ListModel model: ListModel {}

	onKeysChanged: root.sync()
	Component.onCompleted: root.sync()

	function sync() {
		const keys = root.keys || [];
		const model = root.model;
		for (let i = model.count - 1; i >= 0; i -= 1) {
			if (!keys.includes(model.get(i).key)) model.remove(i);
		}
		for (let i = 0; i < keys.length; i += 1) {
			if (i < model.count && model.get(i).key === keys[i]) continue;
			let found = -1;
			for (let j = i + 1; j < model.count; j += 1) {
				if (model.get(j).key === keys[i]) {
					found = j;
					break;
				}
			}
			if (found >= 0) model.move(found, i, 1);
			else model.insert(i, { key: keys[i] });
		}
	}
}
