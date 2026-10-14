pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Above the panes: the tabs, the search, the command palette and the
// switches for the split and the details.
Item {
	id: root

	required property var view
	property var pane: null

	function focusSearch() {
		search.focusInput();
		search.input.selectAll();
	}

	// ── tabs ───────────────────────────────────────────────────────────────
	IconButton {
		id: showSidebar

		visible: FileLibrary.view.sidebar === false
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		width: visible ? 34 : 0
		height: 34
		iconSize: 17
		icon: "dock_left"
		onClicked: FileLibrary.setView("", { sidebar: true })
	}

	ListView {
		id: tabs

		anchors.left: showSidebar.right
		anchors.leftMargin: showSidebar.visible ? 6 : 0
		anchors.right: newTab.left
		anchors.rightMargin: 4
		anchors.verticalCenter: parent.verticalCenter
		height: 36
		orientation: ListView.Horizontal
		spacing: 4
		clip: true
		interactive: contentWidth > width
		boundsBehavior: Flickable.StopAtBounds
		model: root.view.tabs
		currentIndex: root.view.currentIndex
		highlightFollowsCurrentItem: true
		highlightMoveDuration: Motion.medium
		highlightResizeDuration: Motion.medium

		// the lit tab is a pill that slides to the tab picked
		highlight: Rectangle {
			radius: 12
			color: Theme.layer2
			border.width: 1
			border.color: Theme.outline
		}

		add: Transition {
			ParallelAnimation {
				NumberAnimation {
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.medium
				}
				NumberAnimation {
					property: "scale"
					from: 0.6
					to: 1
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}
		}
		remove: Transition {
			ParallelAnimation {
				NumberAnimation {
					property: "opacity"
					to: 0
					duration: Motion.short
				}
				NumberAnimation {
					property: "scale"
					to: 0.6
					duration: Motion.short
				}
			}
		}
		displaced: Transition {
			NumberAnimation {
				property: "x"
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}

		delegate: Item {
			id: tab

			required property string tabId
			required property int index
			readonly property var tabState: {
				root.view.tabTick;
				return root.view.tabMap[tab.tabId] ?? null;
			}
			readonly property bool current: tab.index === root.view.currentIndex
			readonly property bool single: root.view.tabs.count === 1

			width: Math.min(230, Math.max(96, label.implicitWidth + 12 + 16 + 8 + (tab.single ? 14 : 34) + (tab.tabState?.split ? 16 : 0)))
			height: tabs.height

			MouseArea {
				id: area

				anchors.fill: parent
				hoverEnabled: true
				acceptedButtons: Qt.LeftButton | Qt.MiddleButton
				cursorShape: Qt.PointingHandCursor
				onClicked: mouse => {
					if (mouse.button === Qt.MiddleButton) root.view.closeTab(tab.index);
					else root.view.selectTab(tab.index);
				}
				onWheel: wheel => root.view.selectTab(Math.max(0, Math.min(root.view.tabs.count - 1, root.view.currentIndex + (wheel.angleDelta.y > 0 ? -1 : 1))))
			}

			Rectangle {
				anchors.fill: parent
				radius: 12
				color: Qt.alpha(Theme.layer1, area.containsMouse && !tab.current ? 1 : 0)

				Behavior on color {
					ColorAnim {}
				}
			}

			Glyph {
				id: glyph

				x: 12
				anchors.verticalCenter: parent.verticalCenter
				icon: tab.tabState?.icon ?? "folder_outline"
				size: 16
				color: tab.current ? Theme.primary : Theme.textMuted
			}

			Text {
				id: label

				anchors.left: glyph.right
				anchors.leftMargin: 8
				anchors.right: tab.single ? parent.right : close.left
				anchors.rightMargin: tab.single ? 12 : 4
				anchors.verticalCenter: parent.verticalCenter
				text: tab.tabState?.title ?? ""
				color: tab.current ? Theme.text : Theme.textMuted
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.body
				font.weight: tab.current ? Font.DemiBold : Font.Normal
				elide: Text.ElideRight
			}

			// a split tab says so
			Glyph {
				visible: !!tab.tabState?.split
				anchors.right: close.left
				anchors.verticalCenter: parent.verticalCenter
				icon: "view_split_vertical"
				size: 13
				color: Theme.textSubtle
			}

			IconButton {
				id: close

				anchors.right: parent.right
				anchors.rightMargin: 4
				anchors.verticalCenter: parent.verticalCenter
				width: 24
				height: 24
				iconSize: 13
				icon: "close"
				visible: !tab.single
				opacity: area.containsMouse || tab.current || hovered ? 1 : 0
				onClicked: root.view.closeTab(tab.index)

				Behavior on opacity {
					Anim {}
				}
			}

			// files dropped on a tab go to its folder; held there, it opens
			DropArea {
				anchors.fill: parent
				onEntered: switchTimer.restart()
				onExited: switchTimer.stop()
				onDropped: drop => {
					switchTimer.stop();
					const pane = tab.tabState?.pane;
					if (pane?.isFolder) {
						drop.acceptProposedAction();
						Files.dropInto(pane.location.path, drop, "auto");
					}
				}

				Timer {
					id: switchTimer

					interval: 600
					onTriggered: root.view.selectTab(tab.index)
				}
			}
		}
	}

	IconButton {
		id: newTab

		anchors.right: search.left
		anchors.rightMargin: 12
		anchors.verticalCenter: parent.verticalCenter
		width: 32
		height: 32
		iconSize: 17
		icon: "plus"
		onClicked: root.view.newTab(root.pane?.isFolder ? root.pane.location : { kind: "home" }, true)
	}

	// ── search ─────────────────────────────────────────────────────────────
	// the folder a search started in; a search always looks below it
	property string scope: ""

	Field {
		id: search

		anchors.right: buttons.left
		anchors.rightMargin: 10
		anchors.verticalCenter: parent.verticalCenter
		height: 36
		width: search.focused || search.text !== "" ? 340 : 230
		icon: "magnify"
		placeholder: root.pane?.isFolder ? `Search in ${root.pane.title}` : "Search your files"

		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		onFocusedChanged: {
			if (search.focused && root.pane?.location.kind !== "search") root.scope = root.pane?.isFolder ? root.pane.location.path : Files.home;
		}
		onEdited: text => searchTimer.restart()
		onAccepted: {
			searchTimer.stop();
			root.runSearch();
			root.view.takeFocus();
		}
		onEscapePressed: {
			search.text = "";
			searchTimer.stop();
			if (root.pane?.location.kind === "search") root.pane.goBack();
			root.view.takeFocus();
		}
		onDownPressed: root.view.takeFocus()

		Connections {
			target: root.pane
			ignoreUnknownSignals: true

			// leaving the search empties the field
			function onLocationChanged() {
				if (root.pane.location.kind !== "search" && !search.focused) search.text = "";
				else if (root.pane.location.kind === "search" && !search.focused) search.text = root.pane.location.query ?? "";
			}
		}
	}

	Timer {
		id: searchTimer

		interval: 260
		onTriggered: root.runSearch()
	}

	function runSearch() {
		const pane = root.pane;
		if (!pane) return;
		const query = search.text.trim();
		if (query === "") {
			if (pane.location.kind === "search") pane.goBack();
			return;
		}
		pane.go({ kind: "search", path: root.scope || Files.home, query: query, contents: pane.location.kind === "search" && !!pane.location.contents });
	}

	// ── switches ───────────────────────────────────────────────────────────
	Row {
		id: buttons

		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		spacing: 4

		IconButton {
			width: 34
			height: 34
			iconSize: 17
			icon: "creation"
			onClicked: root.view.openAiLine()
		}

		Clickable {
			width: paletteRow.implicitWidth + 20
			height: 34
			radius: 12
			color: Theme.layer1
			onClicked: root.view.openPalette()

			Row {
				id: paletteRow

				anchors.centerIn: parent
				spacing: 6

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: "console_line"
					size: 15
					color: Theme.textMuted
				}

				Text {
					anchors.verticalCenter: parent.verticalCenter
					text: "Ctrl K"
					color: Theme.textMuted
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}
			}
		}

		IconButton {
			width: 34
			height: 34
			iconSize: 17
			icon: "view_split_vertical"
			checked: !!root.view.tab?.split
			onClicked: root.view.tab.toggleSplit()
		}

		IconButton {
			width: 34
			height: 34
			iconSize: 17
			icon: "dock_right"
			checked: root.view.detailsOpen
			onClicked: root.view.showDetails(!root.view.detailsOpen)
		}
	}
}
