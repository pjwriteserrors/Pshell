pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >remind: what is typed is parsed by core as it is typed ("20m
// Wäsche", "morgen 9 Arzt !", "wenn ich zurück bin …"), Enter saves it.
// With nothing typed: what is due and ahead; Enter is Done, Tab snoozes
// an hour, Delete removes an own one.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0
	property bool saving: false
	property var parsed: null
	property string parsedFor: ""
	property string failed: ""

	readonly property string words: root.argument.trim()
	readonly property var list: Reminders.items.slice(0, 60)
	readonly property bool typing: root.words !== ""
	readonly property string enterHint: root.typing ? "add" : "done"

	signal closeRequested

	onActiveChanged: {
		root.saving = false;
		if (!root.active) return;
		root.currentIndex = 0;
		Reminders.collect();
		Reminders.load();
	}

	onWordsChanged: {
		root.failed = "";
		root.saving = false;
		if (root.words === "") {
			root.parsed = null;
			parseDelay.stop();
		} else {
			parseDelay.restart();
		}
	}

	Timer {
		id: parseDelay

		interval: 300
		onTriggered: {
			const text = root.words;
			Reminders.parse(text, (found, error) => {
				if (root.words !== text) return;
				root.parsed = found;
				root.parsedFor = text;
				root.failed = found ? "" : (error || "?");
			});
		}
	}

	function move(delta) {
		if (root.typing) return;
		root.currentIndex = Math.max(0, Math.min(root.list.length - 1, root.currentIndex + delta));
		view.positionViewAtIndex(root.currentIndex, ListView.Contain);
	}

	function handleKey(event) {
		if (root.typing) return false;
		const item = root.list[root.currentIndex];
		if (!item || item.kind !== "own") return false;
		if (event.key === Qt.Key_Tab) {
			Reminders.snooze(item.uid, 60);
			return true;
		}
		if (event.key === Qt.Key_Delete) {
			Reminders.remove(item.id);
			return true;
		}
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		if (!root.typing) {
			const item = root.list[root.currentIndex];
			if (item && (item.kind === "own" || item.pending)) Reminders.done(item.uid);
			return;
		}
		if (!Reminders.online || root.saving) return;
		const text = root.words;
		root.saving = true;
		// stays saving until the launcher closes: a held Enter adds it once
		const save = found => Reminders.create(found, (data, error) => {
			if (error) {
				root.saving = false;
				return;
			}
			Notifs.pushInternal("done", found.title, [found.trigger && found.trigger !== "time" ? Reminders.triggerName(found.trigger) : Reminders.whenText(found.at, found.all_day), Reminders.repeatText(found.repeat)].filter(s => s).join(" · "), { icon: "bell_plus_outline", app: "Reminders" });
			root.closeRequested();
		});
		if (root.parsed && root.parsedFor === text) {
			save(root.parsed);
			return;
		}
		Reminders.parse(text, (found, error) => {
			if (!found) {
				root.saving = false;
				root.failed = error || "?";
				return;
			}
			save(found);
		});
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 10

		EmptyState {
			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: !Reminders.online && root.list.length === 0
			icon: "cloud_off_outline"
			title: "Core not reachable"
		}

		// what was typed, as a reminder
		Rectangle {
			Layout.fillWidth: true
			visible: root.typing
			implicitHeight: card.implicitHeight + 28
			radius: Theme.radius.large
			color: Theme.layer1

			ColumnLayout {
				id: card

				anchors.fill: parent
				anchors.margins: 14
				spacing: 8

				RowLayout {
					Layout.fillWidth: true
					spacing: 10

					Glyph {
						icon: root.parsed ? (root.parsed.trigger && root.parsed.trigger !== "time" ? Reminders.triggerGlyph(root.parsed.trigger) : Reminders.levelGlyph(root.parsed.level || "normal")) : "bell_plus_outline"
						size: 22
						color: root.parsed?.level === "fullscreen" || root.parsed?.level === "important" ? Theme.warning : Theme.primary
					}

					StyledText {
						Layout.fillWidth: true
						text: root.parsed?.title || root.words
						tone: root.parsed ? Theme.text : Theme.textSubtle
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
						elide: Text.ElideRight
					}

					Spinner {
						visible: root.saving || parseDelay.running
						Layout.preferredWidth: 16
						Layout.preferredHeight: 16
					}
				}

				StyledText {
					Layout.fillWidth: true
					text: root.parsed ? [root.parsed.trigger && root.parsed.trigger !== "time" ? Reminders.triggerName(root.parsed.trigger) : Reminders.whenText(root.parsed.at, root.parsed.all_day), Reminders.repeatText(root.parsed.repeat), Reminders.levelName(root.parsed.level || "normal")].filter(s => s).join(" · ") : (root.failed !== "" ? "When?" : "")
					tone: root.parsed ? Theme.textMuted : Theme.warning
					font.pixelSize: Theme.size.body
				}
			}
		}

		ListView {
			id: view

			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: !root.typing && root.list.length > 0
			clip: true
			spacing: 2
			model: root.list
			currentIndex: root.currentIndex
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			delegate: ListItem {
				id: row

				required property var modelData
				required property int index

				width: view.width
				selected: root.currentIndex === row.index
				accent: row.modelData.pending ? Theme.warning : Theme.primary
				icon: row.modelData.icon || (row.modelData.kind === "own" ? (row.modelData.trigger !== "time" ? Reminders.triggerGlyph(row.modelData.trigger) : "bell_outline") : Reminders.sourceGlyph(row.modelData.source))
				title: row.modelData.title
				subtitle: Reminders.itemText(row.modelData)
				onPointed: root.currentIndex = row.index
				onClicked: root.currentIndex = row.index

				IconButton {
					visible: row.modelData.kind === "own" || row.modelData.pending
					implicitWidth: 28
					implicitHeight: 28
					icon: "timer_outline"
					onClicked: Reminders.snooze(row.modelData.uid, 60)
				}

				IconButton {
					visible: row.modelData.kind === "own" || row.modelData.pending
					implicitWidth: 28
					implicitHeight: 28
					icon: "check"
					onClicked: Reminders.done(row.modelData.uid)
				}
			}
		}

		EmptyState {
			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: Reminders.online && !root.typing && root.list.length === 0
			icon: "bell_outline"
			title: "Nothing ahead"
		}

		Item {
			Layout.fillHeight: true
			visible: root.typing
		}
	}
}
