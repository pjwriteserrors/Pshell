pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Reminders: what is due, what is ahead (own and the shell's sources), a
// line to add one (parsed by core), and the level of every source.
Drawer {
	id: root

	panelId: "reminders"
	panelWidth: 520
	centered: true
	contentHeight: layout.implicitHeight

	property bool levelsPage: false
	property var parsed: null
	readonly property var ahead: Reminders.items.filter(item => !item.pending).slice(0, 10)

	onPanelOpened: {
		root.levelsPage = false;
		Reminders.collect();
		Reminders.load();
	}

	Timer {
		id: parseDelay

		interval: 350
		onTriggered: {
			const text = field.text.trim();
			if (text === "") {
				root.parsed = null;
				return;
			}
			Reminders.parse(text, found => {
				if (field.text.trim() === text) root.parsed = found;
			});
		}
	}

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 14

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			StyledText {
				Layout.fillWidth: true
				text: root.levelsPage ? "Levels" : "Reminders"
				font.pixelSize: Theme.size.heading
				font.weight: Font.Bold
			}

			Glyph {
				visible: Reminders.enabled && !Reminders.online
				icon: "cloud_off_outline"
				size: 16
				color: Theme.textMuted
			}

			IconButton {
				implicitWidth: 32
				implicitHeight: 32
				icon: root.levelsPage ? "arrow_left" : "tune"
				onClicked: root.levelsPage = !root.levelsPage
			}
		}

		// ── add ───────────────────────────────────────────────────────────
		Field {
			id: field

			Layout.fillWidth: true
			visible: !root.levelsPage
			enabled: Reminders.online
			icon: "bell_plus_outline"
			placeholder: "morgen 9 Arzt"
			onEdited: parseDelay.restart()
			onAccepted: {
				const text = field.text.trim();
				if (text === "") return;
				Reminders.add(text, (data, error) => {
					if (error) return;
					field.text = "";
					root.parsed = null;
				});
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 4
			visible: !root.levelsPage && root.parsed !== null && field.text.trim() !== ""
			text: root.parsed ? [root.parsed.title, root.parsed.trigger && root.parsed.trigger !== "time" ? Reminders.triggerName(root.parsed.trigger) : Reminders.whenText(root.parsed.at, root.parsed.all_day), Reminders.repeatText(root.parsed.repeat), root.parsed.level && root.parsed.level !== "normal" ? Reminders.levelName(root.parsed.level) : ""].filter(s => s).join(" · ") : ""
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
			elide: Text.ElideRight
		}

		// ── due ───────────────────────────────────────────────────────────
		SectionLabel {
			visible: !root.levelsPage && Reminders.alerts.length > 0
			text: "Now"
		}

		Repeater {
			model: root.levelsPage ? [] : Reminders.alerts

			delegate: ListItem {
				id: alertRow

				required property var modelData

				Layout.fillWidth: true
				icon: alertRow.modelData.icon || Reminders.sourceGlyph(alertRow.modelData.source)
				accent: Theme.warning
				selected: true
				title: alertRow.modelData.title
				subtitle: [alertRow.modelData.source !== "own" ? Reminders.sourceName(alertRow.modelData.source) : "", alertRow.modelData.body].filter(s => s).join(" · ")

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "timer_outline"
					onClicked: Reminders.snooze(alertRow.modelData.uid, 60)
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "check"
					onClicked: Reminders.done(alertRow.modelData.uid)
				}
			}
		}

		// ── ahead ─────────────────────────────────────────────────────────
		SectionLabel {
			visible: !root.levelsPage && root.ahead.length > 0
			text: "Ahead"
		}

		Repeater {
			model: root.levelsPage ? [] : root.ahead

			delegate: ListItem {
				id: row

				required property var modelData

				Layout.fillWidth: true
				icon: row.modelData.icon || (row.modelData.kind === "own" ? (row.modelData.trigger !== "time" ? Reminders.triggerGlyph(row.modelData.trigger) : "bell_outline") : Reminders.sourceGlyph(row.modelData.source))
				title: row.modelData.title
				subtitle: Reminders.itemText(row.modelData)

				Glyph {
					visible: row.modelData.kind === "own" && row.modelData.level !== "normal"
					icon: Reminders.levelGlyph(row.modelData.level)
					size: 14
					color: Theme.textMuted
				}

				IconButton {
					visible: row.modelData.kind === "own"
					implicitWidth: 30
					implicitHeight: 30
					icon: "check"
					onClicked: Reminders.done(row.modelData.uid)
				}

				IconButton {
					visible: row.modelData.kind === "own"
					implicitWidth: 30
					implicitHeight: 30
					icon: "delete_outline"
					onClicked: Reminders.remove(row.modelData.id)
				}
			}
		}

		EmptyState {
			Layout.fillWidth: true
			Layout.preferredHeight: 120
			visible: !root.levelsPage && Reminders.alerts.length === 0 && root.ahead.length === 0
			icon: "bell_outline"
			title: "Nothing ahead"
		}

		// ── levels ────────────────────────────────────────────────────────
		Repeater {
			model: root.levelsPage ? Reminders.sourceIds : []

			delegate: RowLayout {
				id: level

				required property string modelData

				Layout.fillWidth: true
				spacing: 10

				Glyph {
					icon: Reminders.sourceGlyph(level.modelData)
					size: 18
					color: Theme.textMuted
				}

				StyledText {
					Layout.fillWidth: true
					text: Reminders.sourceName(level.modelData)
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
				}

				Segmented {
					Layout.preferredWidth: 340
					implicitHeight: 32
					current: Reminders.levelOf(level.modelData)
					options: Reminders.levelIds.map(id => ({ value: id, label: Reminders.levelName(id) }))
					onSelected: value => Reminders.setLevel(level.modelData, value)
				}
			}
		}
	}
}
