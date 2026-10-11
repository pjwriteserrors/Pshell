pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A pane on the screen: back, forward and up, where it is, how it is
// shown, then the place itself (the home page or the files) and a line
// that counts. In a split the pane with the keyboard is lifted a little.
Item {
	id: root

	required property var pane
	required property var shell
	property bool active: true
	property bool split: false
	readonly property alias browse: browse
	readonly property bool home: root.pane.location.kind === "home"

	signal focusRequested

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.huge
		color: root.split ? (root.active ? Theme.layer1 : Qt.alpha(Theme.fg, 0.02)) : "transparent"
		border.width: root.split && root.active ? 1 : 0
		border.color: Qt.alpha(Theme.primary, 0.35)

		Behavior on color {
			ColorAnim {}
		}
	}

	// ── where it is ────────────────────────────────────────────────────────
	Item {
		id: bar

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.leftMargin: 10
		anchors.rightMargin: 10
		anchors.topMargin: 8
		height: 36

		Row {
			id: nav

			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			IconButton {
				width: 30
				height: 30
				icon: "arrow_left"
				iconSize: 17
				enabled: root.pane.back.length > 0
				onClicked: root.pane.goBack()
			}
			IconButton {
				width: 30
				height: 30
				icon: "arrow_right"
				iconSize: 17
				enabled: root.pane.forward.length > 0
				onClicked: root.pane.goForward()
			}
			IconButton {
				width: 30
				height: 30
				icon: "arrow_up"
				iconSize: 17
				enabled: root.pane.isFolder && root.pane.location.path !== "/"
				onClicked: root.pane.goUp()
			}
		}

		Breadcrumbs {
			id: crumbs

			anchors.left: nav.right
			anchors.leftMargin: 8
			anchors.right: tools.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			pane: root.pane
		}

		Row {
			id: tools

			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4
			visible: !root.home

			// a search that started here may also look into the files
			Chip {
				visible: root.pane.location.kind === "search"
				height: 28
				text: "Contents"
				icon: "text_search"
				selected: !!root.pane.location.contents
				onClicked: root.pane.go(Object.assign({}, root.pane.location, { contents: !root.pane.location.contents }), { history: false })
			}

			IconButton {
				id: sortButton

				width: 30
				height: 30
				icon: "sort"
				iconSize: 17
				onClicked: root.shell.showViewMenu(root.pane, sortButton)
			}

			Segmented {
				width: 76
				height: 30
				options: [{ value: "grid", icon: "view_grid_outline" }, { value: "list", icon: "view_list_outline" }]
				current: root.pane.mode
				onSelected: value => FileLibrary.setView(root.pane.isFolder ? root.pane.location.path : `:${root.pane.location.kind}`, { mode: value })
			}
		}
	}

	function editPath() {
		crumbs.edit();
	}

	// ── the place ──────────────────────────────────────────────────────────
	Item {
		id: content

		anchors.top: bar.bottom
		anchors.topMargin: 6
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: status.top

		BrowseView {
			id: browse

			anchors.fill: parent
			visible: !root.home
			pane: root.pane
			active: root.active
			onFocusRequested: root.focusRequested()
			onOpened: (index, newTab) => root.shell.openRow(root.pane, root.pane.rows[index], newTab)
			onMenuRequested: (index, x, y) => {
				const at = browse.mapToItem(root.shell, x, y);
				root.shell.showItemMenu(root.pane, index, at.x, at.y);
			}
		}

		Loader {
			anchors.fill: parent
			active: root.home
			visible: root.home
			sourceComponent: HomeView {
				pane: root.pane
				shell: root.shell
			}
		}
	}

	// ── what is in it ──────────────────────────────────────────────────────
	Item {
		id: status

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.leftMargin: 16
		anchors.rightMargin: 14
		height: root.home ? 0 : 30
		visible: !root.home

		Row {
			anchors.verticalCenter: parent.verticalCenter
			spacing: 6

			Text {
				anchors.verticalCenter: parent.verticalCenter
				text: {
					const count = root.pane.rows.length;
					const base = root.pane.location.kind === "search" && root.pane.searching ? `${count} found so far` : `${count} item${count === 1 ? "" : "s"}`;
					return root.pane.filter !== "" ? `${base} matching “${root.pane.filter}”` : base;
				}
				color: Theme.textSubtle
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
			}

			Rectangle {
				visible: root.pane.selectionCount > 0
				anchors.verticalCenter: parent.verticalCenter
				width: picked.implicitWidth + 14
				height: 20
				radius: 10
				color: Theme.primarySoft
				scale: visible ? 1 : 0.6

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				Text {
					id: picked

					anchors.centerIn: parent
					text: `${root.pane.selectionCount} picked${root.pane.selectedSize > 0 ? " · " + Files.sizeText(root.pane.selectedSize) : ""}`
					color: Theme.primary
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}
			}

			Spinner {
				visible: root.pane.searching || root.pane.loading
				anchors.verticalCenter: parent.verticalCenter
				width: 12
				height: 12
			}
		}

		Row {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 10

			Text {
				visible: root.pane.total > 0
				anchors.verticalCenter: parent.verticalCenter
				text: `${Files.sizeText(root.pane.free)} free`
				color: Theme.textSubtle
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
			}

			// the size of the cards, also Ctrl and the wheel
			PillSlider {
				visible: root.pane.mode === "grid"
				anchors.verticalCenter: parent.verticalCenter
				width: 120
				height: 22
				showValue: false
				icon: "view_grid_outline"
				stepSize: 0.07
				value: (FileLibrary.view.cardSize - 110) / 230
				onMoved: v => FileLibrary.setView("", { cardSize: Math.round(110 + v * 230) })
			}
		}
	}
}
