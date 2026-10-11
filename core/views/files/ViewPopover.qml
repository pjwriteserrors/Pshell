pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// How a place is shown, opened from the sort button: cards or a list, the
// order, the groups, the size of the cards. Each of the first three applies
// to every folder or only to this one (in a split the layout may also be
// only this side's). It stays open while things are changed, so the files
// behind show what each choice does.
Item {
	id: root

	required property var view
	property var pane: null
	property bool shown: false
	// where the card hangs from (its top right corner)
	property real anchorX: 0
	property real anchorY: 0
	signal closed

	readonly property bool split: !!root.view.tab?.split
	readonly property string key: root.pane?.viewKey ?? ""
	readonly property string placeName: root.pane ? (root.pane.isFolder ? Files.nameOf(root.pane.location.path) : root.pane.title) : ""
	readonly property real cardSize: FileLibrary.view.cardSize || 172

	function open(pane, item) {
		root.pane = pane;
		const at = item.mapToItem(root, item.width, item.height + 6);
		root.anchorX = at.x;
		root.anchorY = at.y;
		root.shown = true;
		Sounds.play("open");
		keys.forceActiveFocus();
	}

	function close() {
		if (!root.shown) return;
		root.shown = false;
		root.closed();
	}

	// what a scope switch shows for a setting
	function scopeOf(setting) {
		if (!root.pane) return "everywhere";
		if (setting === "mode" && root.pane.modeOverride !== "") return "side";
		FileLibrary.folderViews;
		return FileLibrary.scopeOf(root.key, setting);
	}

	function setScope(setting, scope) {
		if (!root.pane) return;
		Sounds.play("select");
		if (setting === "mode") {
			if (scope === "side") {
				root.pane.modeOverride = root.pane.mode;
				return;
			}
			// the side's own layout becomes the folder's (or everyone's)
			const mode = root.pane.mode;
			root.pane.modeOverride = "";
			FileLibrary.setScope(root.key, "mode", scope);
			FileLibrary.setView(root.key, { mode: mode });
			return;
		}
		FileLibrary.setScope(root.key, setting, scope);
	}

	function sortBy(value) {
		Sounds.play("select");
		FileLibrary.setView(root.key, { sort: value, desc: value === "modified" || value === "size" });
	}

	visible: card.opacity > 0.01

	// a click beside it closes it, and is not taken by the files
	MouseArea {
		anchors.fill: parent
		enabled: root.shown
		acceptedButtons: Qt.AllButtons
		// the files behind do not light up under it
		hoverEnabled: true
		onPressed: root.close()
		onWheel: wheel => wheel.accepted = false
	}

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.close()
	}

	Rectangle {
		id: card

		x: Math.max(8, Math.min(root.width - width - 8, root.anchorX - width))
		y: Math.max(8, Math.min(root.height - height - 8, root.anchorY))
		width: 372
		height: body.implicitHeight + 32
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		transformOrigin: Item.TopRight
		scale: root.shown ? 1 : 0.92
		opacity: root.shown ? 1 : 0

		Behavior on scale {
			SpatialAnim {
				duration: root.shown ? Motion.long : Motion.short
			}
		}
		Behavior on opacity {
			Anim {
				duration: root.shown ? Motion.medium : Motion.short
			}
		}

		Rectangle {
			z: -1
			anchors.fill: parent
			anchors.topMargin: 8
			anchors.bottomMargin: -14
			anchors.leftMargin: 6
			anchors.rightMargin: 6
			radius: parent.radius
			color: Theme.shadow
			opacity: 0.45
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		ColumnLayout {
			id: body

			x: 16
			y: 16
			width: parent.width - 32
			spacing: 14

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				StyledText {
					text: "View"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: root.placeName
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}

				IconButton {
					width: 28
					height: 28
					iconSize: 15
					icon: "close"
					onClicked: root.close()
				}
			}

			// ── layout ─────────────────────────────────────────────────────
			ViewSection {
				Layout.fillWidth: true
				title: "Layout"
				scope: root.scopeOf("mode")
				scopes: root.split ? [{ value: "side", label: "This side" }, { value: "here", label: "Folder" }, { value: "everywhere", label: "All" }]
					: [{ value: "here", label: "This folder" }, { value: "everywhere", label: "All folders" }]
				onScopePicked: value => root.setScope("mode", value)

				Segmented {
					Layout.fillWidth: true
					height: 32
					options: [{ value: "grid", label: "Cards", icon: "view_grid_outline" }, { value: "list", label: "List", icon: "view_list_outline" }]
					current: root.pane?.mode ?? "grid"
					onSelected: value => {
						Sounds.play("select");
						root.view.setMode(root.pane, value);
					}
				}
			}

			// ── order ──────────────────────────────────────────────────────
			ViewSection {
				Layout.fillWidth: true
				title: "Sort by"
				scope: root.scopeOf("sort")
				scopes: [{ value: "here", label: "This folder" }, { value: "everywhere", label: "All folders" }]
				onScopePicked: value => root.setScope("sort", value)

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					Segmented {
						Layout.fillWidth: true
						height: 32
						options: [{ value: "name", label: "Name" }, { value: "modified", label: "Date" }, { value: "size", label: "Size" }, { value: "kind", label: "Kind" }]
						current: root.pane?.sort ?? "name"
						onSelected: value => root.sortBy(value)
					}

					IconButton {
						width: 32
						height: 32
						iconSize: 17
						variant: "tonal"
						icon: root.pane?.desc ? "sort_descending" : "sort_ascending"
						onClicked: FileLibrary.setView(root.key, { desc: !root.pane.desc })
					}
				}
			}

			// ── groups ─────────────────────────────────────────────────────
			ViewSection {
				Layout.fillWidth: true
				title: "Group by"
				scope: root.scopeOf("group")
				scopes: [{ value: "here", label: "This folder" }, { value: "everywhere", label: "All folders" }]
				onScopePicked: value => root.setScope("group", value)

				Segmented {
					Layout.fillWidth: true
					height: 32
					options: [{ value: "none", label: "None" }, { value: "kind", label: "Kind" }, { value: "date", label: "Date" }, { value: "size", label: "Size" }]
					current: root.pane?.group ?? "none"
					onSelected: value => {
						Sounds.play("select");
						FileLibrary.setView(root.key, { group: value });
					}
				}
			}

			// ── the size of the cards ──────────────────────────────────────
			ColumnLayout {
				Layout.fillWidth: true
				spacing: 6

				RowLayout {
					Layout.fillWidth: true

					StyledText {
						Layout.fillWidth: true
						text: "Card size"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}

					SizeReset {}
				}

				PillSlider {
					Layout.fillWidth: true
					height: 26
					showValue: false
					icon: "view_grid_outline"
					stepSize: 0.07
					value: (root.cardSize - 110) / 230
					onMoved: v => FileLibrary.setView("", { cardSize: Math.round(110 + v * 230) })
				}
			}

			Rectangle {
				Layout.fillWidth: true
				height: 1
				color: Theme.outline
			}

			ViewSwitch {
				Layout.fillWidth: true
				text: "Hidden files"
				hint: "Ctrl+H"
				checked: !!FileLibrary.view.hidden
				onToggled: on => FileLibrary.setView("", { hidden: on })
			}

			ViewSwitch {
				Layout.fillWidth: true
				text: "Folders first"
				checked: FileLibrary.view.foldersFirst !== false
				onToggled: on => {
					FileLibrary.setView("", { foldersFirst: on });
					root.pane?.arrange(false);
				}
			}

			// folders that keep their own view, and a way to let them all go
			RowLayout {
				Layout.fillWidth: true
				visible: FileLibrary.ownViews > 0
				spacing: 8

				StyledText {
					Layout.fillWidth: true
					text: FileLibrary.ownViews === 1 ? "1 folder keeps its own view" : `${FileLibrary.ownViews} folders keep their own view`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}

				TextButton {
					height: 28
					variant: "ghost"
					text: "Reset all"
					confirm: true
					onActivated: FileLibrary.forgetFolderViews()
				}
			}
		}
	}

	// the title of a group of settings and where it applies
	component ViewSection: ColumnLayout {
		id: section

		property string title: ""
		property string scope: "everywhere"
		property var scopes: []
		default property alias content: inner.data
		signal scopePicked(string value)

		spacing: 6

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: section.title
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			// only here or everywhere
			Row {
				spacing: 2

				Repeater {
					model: section.scopes

					delegate: Rectangle {
						id: chip

						required property var modelData
						readonly property bool on: section.scope === chip.modelData.value

						width: chipLabel.implicitWidth + 16
						height: 22
						radius: 11
						color: chip.on ? Theme.primarySoft : Qt.alpha(Theme.layer2, chipMouse.containsMouse ? 1 : 0)
						border.width: 1
						border.color: chip.on ? Qt.alpha(Theme.primary, 0.5) : Theme.outline

						Behavior on color {
							ColorAnim {}
						}

						Text {
							id: chipLabel

							anchors.centerIn: parent
							text: chip.modelData.label
							color: chip.on ? Theme.primary : Theme.textSubtle
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.tiny
							font.weight: chip.on ? Font.DemiBold : Font.Medium
						}

						MouseArea {
							id: chipMouse

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: if (!chip.on) section.scopePicked(chip.modelData.value)
						}
					}
				}
			}
		}

		ColumnLayout {
			id: inner

			Layout.fillWidth: true
			spacing: 6
		}
	}

	component ViewSwitch: RowLayout {
		id: line

		property string text: ""
		property string hint: ""
		property bool checked: false
		signal toggled(bool on)

		spacing: 8

		StyledText {
			Layout.fillWidth: true
			text: line.text
		}

		StyledText {
			visible: line.hint !== ""
			text: line.hint
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
		}

		Toggle {
			checked: line.checked
			onToggled: on => line.toggled(on)
		}
	}
}
