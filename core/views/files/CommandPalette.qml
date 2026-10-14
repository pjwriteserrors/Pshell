pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../../lib/fuzzysort.js" as Fuzzy

// Ctrl+K: every command of the file manager and every place to go, found
// by typing. What the picked files can do comes first. With a `provider`
// the entries come from it for what is typed (the AI line, Ctrl+Shift+A).
Item {
	id: root

	property var commands: []
	// query => entries, instead of searching the commands
	property var provider: null
	property string placeholder: "What do you want to do?"
	property string glyph: "console_line"
	property bool shown: false
	property int current: 0
	signal closed

	readonly property var found: {
		if (root.provider) return root.shown ? root.provider(field.text) : [];
		const query = field.text.trim().toLowerCase();
		if (query === "") return root.commands.slice(0, 80);
		const scored = [];
		const words = query.split(/\s+/);
		for (const command of root.commands) {
			const label = command.label.toLowerCase();
			const all = `${label} ${String(command.group).toLowerCase()}`;
			const parts = all.split(/[\s:]+/);
			let score = 0;
			if (label.startsWith(query)) score = 100;
			else if (words.length > 1 && words.every(word => parts.some(part => part.startsWith(word)))) score = 80;
			else if (parts.some(part => part.startsWith(query))) score = 70;
			else if (words.every(word => all.includes(word))) score = 45;
			else if (query.length > 1) {
				const fuzzy = Fuzzy.single(query, label);
				if (fuzzy && fuzzy.score > 0.3) score = 5 + fuzzy.score * 30;
			}
			if (score > 0) scored.push({ command: command, score: score });
		}
		scored.sort((a, b) => b.score - a.score);
		return scored.slice(0, 60).map(entry => entry.command);
	}

	onFoundChanged: root.current = 0

	function open(commands) {
		root.commands = commands;
		field.text = "";
		root.current = 0;
		root.shown = true;
		Sounds.play("open");
		Qt.callLater(() => field.focusInput());
	}

	function close() {
		if (!root.shown) return;
		root.shown = false;
		root.closed();
	}

	function run(index) {
		const command = root.found[index];
		if (!command) return;
		root.close();
		Sounds.play("click");
		command.run();
	}

	visible: scrim.opacity > 0.01

	Rectangle {
		id: scrim

		anchors.fill: parent
		color: Theme.scrim
		opacity: root.shown ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			// the files behind do not light up under it
			hoverEnabled: true
			onPressed: root.close()
		}
	}

	Rectangle {
		id: card

		anchors.horizontalCenter: parent.horizontalCenter
		y: root.shown ? parent.height * 0.1 : parent.height * 0.1 - 24
		width: Math.min(640, parent.width - 60)
		height: Math.min(parent.height * 0.75, 72 + list.contentHeight + 12)
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		opacity: root.shown ? 1 : 0
		clip: true

		Behavior on y {
			SpatialAnim {}
		}
		Behavior on opacity {
			Anim {}
		}
		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
		}

		Field {
			id: field

			x: 12
			y: 12
			width: parent.width - 24
			height: 46
			icon: root.glyph
			placeholder: root.placeholder
			fontSize: Theme.size.title
			onAccepted: root.run(root.current)
			onEscapePressed: root.close()
			onDownPressed: {
				root.current = Math.min(root.found.length - 1, root.current + 1);
				list.positionViewAtIndex(root.current, ListView.Contain);
			}
			onUpPressed: {
				root.current = Math.max(0, root.current - 1);
				list.positionViewAtIndex(root.current, ListView.Contain);
			}
		}

		ListView {
			id: list

			anchors.top: field.bottom
			anchors.topMargin: 8
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 8
			clip: true
			model: root.found
			boundsBehavior: Flickable.StopAtBounds
			delegate: Item {
				id: slot

				required property var modelData
				required property int index
				// a group's title above its first command, while nothing is typed
				readonly property bool titled: (root.provider ? String(slot.modelData.group || "") !== "" : field.text.trim() === "") && (slot.index === 0 || root.found[slot.index - 1]?.group !== slot.modelData.group)

				width: list.width
				height: entry.height + (slot.titled ? 28 : 0)

				Text {
					visible: slot.titled
					x: 12
					y: 10
					width: parent.width - 24
					text: String(slot.modelData.group || "").toUpperCase()
					color: Theme.textSubtle
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
					font.letterSpacing: 0.8
					elide: Text.ElideRight
				}

			Rectangle {
				id: entry

				readonly property var modelData: slot.modelData
				readonly property int index: slot.index
				readonly property bool lit: entry.index === root.current

				y: slot.titled ? 28 : 0
				width: list.width
				height: 38
				radius: Theme.radius.medium
				color: entry.lit ? Theme.primarySoft : "transparent"

				Behavior on color {
					ColorAnim {
						duration: Motion.micro
					}
				}

				Glyph {
					x: 12
					anchors.verticalCenter: parent.verticalCenter
					icon: entry.modelData.icon || "circle_small"
					size: 17
					color: entry.lit ? Theme.primary : Theme.textMuted
					animated: false
				}

				Text {
					anchors.left: parent.left
					anchors.leftMargin: 42
					anchors.right: keys.left
					anchors.rightMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					text: entry.modelData.label
					color: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.body
					elide: Text.ElideRight
				}

				Rectangle {
					id: keys

					visible: !!entry.modelData.shortcut
					anchors.right: parent.right
					anchors.rightMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					width: keyText.implicitWidth + 12
					height: 22
					radius: 6
					color: Theme.layer2

					Text {
						id: keyText

						anchors.centerIn: parent
						text: String(entry.modelData.shortcut || "")
						color: Theme.textMuted
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.small
					}
				}

				MouseArea {
					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onPositionChanged: root.current = entry.index
					onClicked: root.run(entry.index)
				}
			}
			}
		}
	}
}
