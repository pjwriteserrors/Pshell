pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Pinned notes as tabs with a colored spine. The strip folds into a counter
// with the chevron; the plus opens a fresh note. On a crowded bar the titles
// shorten evenly, and when even that does not fit this bar shows the counter.
Row {
	id: root

	required property var bar

	// width with the strip folded, and what the unfolded strip would add
	readonly property real fixedWidth: plus.width + (Notes.pinned.length > 0 ? 4 * 2 + 2 + 16 + count.implicitWidth : 0)
	readonly property real textWant: Notes.collapsed ? 0 : root.stripWidth(1e6)
	// extra width the bar can spare for the strip
	property real room: 1e6
	readonly property real minTitle: 36
	readonly property bool squeezed: !Notes.collapsed && Notes.pinned.length > 0 && root.room < root.stripWidth(root.minTitle)
	readonly property bool folded: Notes.collapsed || root.squeezed
	readonly property real titleCap: root.fitTitles(root.room + 2 + count.implicitWidth - root.chrome * titles.count)

	readonly property real chrome: 6 * 2 + 22
	readonly property var wants: {
		const out = [];
		for (let i = 0; i < titles.count; i += 1)
			out.push(titles.itemAt(i)?.want ?? 0);
		return out;
	}

	// strip width (minus the counter it replaces) with titles capped at `cap`
	function stripWidth(cap) {
		return root.wants.reduce((sum, want) => sum + root.chrome + Math.min(cap, want), 0) - 2 - count.implicitWidth;
	}

	// the largest even cap that fits the titles into `budget`
	function fitTitles(budget) {
		const sorted = root.wants.slice().sort((a, b) => a - b);
		let left = budget;
		for (let i = 0; i < sorted.length; i += 1) {
			const share = left / (sorted.length - i);
			if (sorted[i] > share) return Math.max(root.minTitle, share);
			left -= sorted[i];
		}
		return 150;
	}

	spacing: 0

	BarButton {
		id: plus

		bar: root.bar
		panelId: "notes"
		tooltip: "New note"
		padding: 8
		onClicked: toggle("create")

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			icon: "note_plus"
			size: 18
			color: Popups.current === "notes" && Popups.page === "create" ? Theme.primary : Theme.text
		}
	}

	Item {
		id: strip

		visible: Notes.pinned.length > 0 && !root.folded || width > 1
		height: Theme.barHeight
		width: root.folded ? 0 : notesRow.implicitWidth
		clip: true

		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Row {
			id: notesRow

			opacity: root.folded ? 0 : 1

			Behavior on opacity {
				Anim {}
			}

			Repeater {
				id: titles

				model: Notes.pinned

				delegate: BarButton {
					id: note

					required property var modelData
					readonly property bool open: Popups.current === "notes" && Popups.page === String(note.modelData.id)
					readonly property real want: Math.min(150, title.implicitWidth)

					bar: root.bar
					panelId: "notes"
					primaryAnchor: false
					padding: 6
					tooltip: Notes.titleOf(note.modelData)
					onClicked: toggle(String(note.modelData.id))

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						height: 24
						width: title.width + 22
						radius: 8
						color: note.open ? Theme.primaryContainer : Theme.layer1

						Behavior on color {
							ColorAnim {}
						}

						Rectangle {
							x: 6
							anchors.verticalCenter: parent.verticalCenter
							width: 3
							height: note.hovered || note.open ? 14 : 10
							radius: 1.5
							color: Theme.primary

							Behavior on height {
								SpatialAnim {
									duration: Motion.short
								}
							}
						}

						StyledText {
							id: title

							x: 15
							anchors.verticalCenter: parent.verticalCenter
							width: Math.min(note.want, root.titleCap)
							text: Notes.titleOf(note.modelData)
							font.pixelSize: Theme.size.small
							font.weight: Font.Medium
						}
					}
				}
			}
		}
	}

	BarButton {
		id: fold

		bar: root.bar
		visible: Notes.pinned.length > 0
		tooltip: root.squeezed ? "Pinned notes" : (Notes.collapsed ? "Show pinned notes" : "Hide pinned notes")
		padding: 4
		onClicked: {
			if (root.squeezed) Popups.toggle("notes", root.bar.screen, undefined, undefined, fold);
			else Notes.collapsed = !Notes.collapsed;
		}

		Row {
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			StyledText {
				id: count

				anchors.verticalCenter: parent.verticalCenter
				visible: root.folded
				text: Notes.pinned.length
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				font.weight: Font.Bold
			}

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: "chevron_left"
				size: 16
				color: Theme.textMuted
				rotation: root.folded ? 180 : 0

				Behavior on rotation {
					SpatialAnim {
						duration: Motion.medium
					}
				}
			}
		}
	}
}
