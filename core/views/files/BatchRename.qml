pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Renaming many at once: every name on a line of its own, to be edited like
// any text (the multicursor plugin works in it too), with find and replace,
// numbering and case at hand. What changes is shown before it is done;
// names that would collide stop it.
DialogFrame {
	id: root

	property var rows: []
	readonly property var names: area.text.split("\n")
	readonly property var pairs: root.rows.map((row, i) => [row.path, String(root.names[i] ?? "").trim()])
	readonly property int changed: root.pairs.filter((pair, i) => pair[1] !== "" && pair[1] !== root.rows[i].name).length
	readonly property var clashes: {
		const seen = {};
		const out = [];
		root.pairs.forEach((pair, i) => {
			const key = Files.parentOf(pair[0]) + "/" + pair[1];
			if (seen[key] !== undefined) out.push(i);
			seen[key] = i;
		});
		return out;
	}
	readonly property bool fits: root.names.length === root.rows.length && root.pairs.every(pair => pair[1] !== "" && !pair[1].includes("/"))

	function open(rows) {
		root.rows = rows;
		area.text = rows.map(row => row.name).join("\n");
		findField.text = "";
		replaceField.text = "";
		root.show();
		Qt.callLater(() => area.focusInput());
	}

	function finish(keep) {
		const pairs = root.pairs.filter((pair, i) => pair[1] !== root.rows[i].name);
		root.hide();
		if (!keep || pairs.length === 0) return;
		Files.renameMany(pairs);
	}

	function split(name) {
		const dot = name.lastIndexOf(".");
		return dot > 0 ? [name.slice(0, dot), name.slice(dot)] : [name, ""];
	}

	function transform(change) {
		area.text = root.names.map((name, i) => {
			const [stem, ext] = root.split(name);
			return change(stem, ext, i, name);
		}).join("\n");
	}

	function replaceAll() {
		const find = findField.text;
		if (find === "") return;
		let pattern;
		try {
			pattern = regex.checked ? new RegExp(find, "g") : new RegExp(find.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g");
		} catch (error) {
			Files.fail("That pattern does not work");
			return;
		}
		root.transform((stem, ext) => stem.replace(pattern, replaceField.text) + ext);
	}

	cardWidth: 720
	onDismissed: root.finish(false)

	// the field keeps Enter for new lines: Ctrl+Enter renames, Escape leaves
	Shortcut {
		sequences: ["Escape"]
		enabled: root.shown
		onActivated: root.finish(false)
	}

	Shortcut {
		sequences: ["Ctrl+Return", "Ctrl+Enter"]
		enabled: root.shown && root.fits && root.clashes.length === 0 && root.changed > 0
		onActivated: root.finish(true)
	}

	ColumnLayout {
		width: parent.width
		spacing: 14

		RowLayout {
			Layout.fillWidth: true

			StyledText {
				text: `Rename ${root.rows.length} items`
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
			}

			Item {
				Layout.fillWidth: true
			}

			StyledText {
				text: root.clashes.length > 0 ? `${root.clashes.length} names collide` : (!root.fits ? "One name per line" : `${root.changed} change${root.changed === 1 ? "" : "s"}`)
				tone: root.clashes.length > 0 || !root.fits ? Theme.danger : Theme.textMuted
				font.pixelSize: Theme.size.label
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Field {
				id: findField

				Layout.fillWidth: true
				implicitHeight: 34
				icon: "magnify"
				placeholder: "Find"
				onAccepted: root.replaceAll()
			}

			Field {
				id: replaceField

				Layout.fillWidth: true
				implicitHeight: 34
				icon: "swap_horizontal"
				placeholder: "Replace with"
				onAccepted: root.replaceAll()
			}

			Chip {
				id: regex

				property bool checked: false
				text: ".*"
				selected: regex.checked
				onClicked: regex.checked = !regex.checked
			}

			TextButton {
				text: "Replace"
				onClicked: root.replaceAll()
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Chip {
				text: "Number them"
				icon: "numeric"
				onClicked: {
					const width = String(root.rows.length).length;
					const base = root.split(root.names[0] || "File")[0].replace(/[\s_-]*\d+$/, "") || "File";
					root.transform((stem, ext, i) => `${base} ${String(i + 1).padStart(Math.max(2, width), "0")}${ext}`);
				}
			}
			Chip {
				text: "Date first"
				icon: "calendar"
				onClicked: root.transform((stem, ext, i) => `${Qt.formatDate(new Date(root.rows[i].mtime * 1000), "yyyy-MM-dd")} ${stem.replace(/^\d{4}-\d{2}-\d{2}\s*/, "")}${ext}`)
			}
			Chip {
				text: "lower case"
				onClicked: root.transform((stem, ext) => stem.toLowerCase() + ext)
			}
			Chip {
				text: "Title Case"
				onClicked: root.transform((stem, ext) => stem.toLowerCase().replace(/(^|[\s_-])(\p{L})/gu, (m, a, b) => a + b.toUpperCase()) + ext)
			}
			Chip {
				text: "Spaces → _"
				onClicked: root.transform((stem, ext) => stem.replace(/\s+/g, "_") + ext)
			}
			Chip {
				text: "_ → spaces"
				onClicked: root.transform((stem, ext) => stem.replace(/[_]+/g, " ") + ext)
			}
			Chip {
				text: "Undo all"
				icon: "restore"
				onClicked: area.text = root.rows.map(row => row.name).join("\n")
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(360, Math.max(140, root.rows.length * 22 + 24))
			spacing: 10

			// the old names, to compare
			Rectangle {
				Layout.fillHeight: true
				Layout.preferredWidth: 1
				Layout.fillWidth: true
				radius: Theme.radius.large
				color: Theme.layer2
				clip: true

				Flickable {
					id: before

					anchors.fill: parent
					anchors.margins: 12
					interactive: false
					contentHeight: oldNames.implicitHeight

					Text {
						id: oldNames

						width: parent.width
						text: root.rows.map(row => row.name).join("\n")
						color: Theme.textSubtle
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.label
						lineHeight: 1.0
					}
				}
			}

			Glyph {
				icon: "arrow_right"
				size: 18
				color: Theme.textSubtle
			}

			AreaField {
				id: area

				Layout.fillHeight: true
				Layout.preferredWidth: 1
				Layout.fillWidth: true
				monospace: true
			}
		}

		RowLayout {
			Layout.alignment: Qt.AlignRight
			spacing: 8

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.finish(false)
			}

			TextButton {
				text: root.changed > 0 ? `Rename ${root.changed}  Ctrl+Enter` : "Rename"
				variant: "filled"
				icon: "check"
				enabled: root.fits && root.clashes.length === 0 && root.changed > 0
				onClicked: root.finish(true)
			}
		}
	}
}
