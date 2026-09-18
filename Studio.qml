pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"

// The one place where the desktop's looks are changed.
//
// This used to be four separate launcher commands opening four separate
// windows: a wallpaper picker, a shell-shape picker, an animation picker and a
// style-branch picker. They are pages here now, and the page that gets you a
// new wallpaper and a new palette is the one that opens first.
//
// Everything is reachable with the mouse and with the keyboard:
//   Escape            close
//   Ctrl+Tab / Ctrl+Shift+Tab  next / previous page
//   Ctrl+1 .. Ctrl+3  jump to a page
//   arrows / Enter    handled by the page itself
FocusScope {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	required property color danger

	property string page: "wallpaper"

	readonly property var pages: [
		{ id: "wallpaper", label: "Wallpaper & Colours", hint: "Ctrl+1" },
		{ id: "motion", label: "Motion", hint: "Ctrl+2" },
		{ id: "styles", label: "Style", hint: "Ctrl+3" }
	]

	readonly property int pageIndex: {
		for (let i = 0; i < root.pages.length; i += 1)
			if (root.pages[i].id === root.page) return i;
		return 0;
	}

	function showPage(id) {
		if (!id || id === root.page) return;
		root.page = id;
	}

	function cyclePage(delta) {
		const next = (root.pageIndex + delta + root.pages.length) % root.pages.length;
		root.showPage(root.pages[next].id);
	}

	// The page owns the arrow keys, so it has to hold the focus. Re-claiming it
	// after every page change keeps a freshly loaded page keyboard-usable
	// without a click.
	function focusPage() {
		if (stage.activeItem) stage.activeItem.forceActiveFocus();
		else root.forceActiveFocus();
	}

	focus: true
	Component.onCompleted: Qt.callLater(root.focusPage)
	onPageChanged: Qt.callLater(root.focusPage)

	// Page shortcuts are deliberately Ctrl-modified: the pages themselves use
	// plain arrows, Enter and typing, and must keep them.
	Keys.onPressed: event => {
		if (!(event.modifiers & Qt.ControlModifier)) return;

		switch (event.key) {
		case Qt.Key_Tab:
			root.cyclePage(event.modifiers & Qt.ShiftModifier ? -1 : 1);
			event.accepted = true;
			return;
		case Qt.Key_Backtab:
			root.cyclePage(-1);
			event.accepted = true;
			return;
		case Qt.Key_1:
		case Qt.Key_2:
		case Qt.Key_3: {
			const index = event.key - Qt.Key_1;
			if (index < root.pages.length) {
				root.showPage(root.pages[index].id);
				event.accepted = true;
			}
			return;
		}
		}
	}

	// The sheet itself draws no surface and the pages are plain content, so
	// Studio brings its own chamber: without it they float unreadably over the
	// desktop.
	BioSurface {
		anchors.fill: parent
		washTop: Bio.membrane
		washBottom: Bio.membraneDeep
		haloStrength: 0.18
		intensity: 0.35
		padding: 0
	}

	Row {
		id: tabs

		anchors.top: parent.top
		anchors.topMargin: 18
		anchors.left: parent.left
		anchors.leftMargin: 20
		anchors.right: parent.right
		anchors.rightMargin: 20
		height: 40
		spacing: 6

		Repeater {
			model: root.pages

			// A tab is a lobe of the same organ: it does not get a box of its
			// own, it lights and grows a bone under it when it is the one you
			// are in.
			delegate: Item {
				id: tab

				required property var modelData
				readonly property bool active: root.page === tab.modelData.id
				readonly property real live: Math.max(tabMouse.live, tab.active ? 1 : 0)

				width: Math.min(240, (root.width - 46) / root.pages.length)
				height: tabs.height

				Row {
					anchors.centerIn: parent
					spacing: Bio.s2

					BioText {
						role: "heading"
						anchors.verticalCenter: parent.verticalCenter
						text: tab.modelData.label
						tone: tab.active ? "organ" : "muted"
						font.pixelSize: 14
					}

					BioText {
						role: "mono"
						anchors.verticalCenter: parent.verticalCenter
						text: tab.modelData.hint
						tone: "faint"
						opacity: tab.live > 0.3 ? 1 : 0.5
						font.pixelSize: 10
					}
				}

				BioTendon {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					anchors.leftMargin: Bio.s4
					anchors.rightMargin: Bio.s4
					height: 10
					facing: Qt.LeftToRight
					lineColor: tab.active ? Bio.organ : Bio.boneGhost
					opacity: 0.35 + 0.65 * tab.live

					Behavior on opacity {
						NumberAnimation { duration: Bio.twitch }
					}
				}

				BioTouch {
					id: tabMouse
					onClicked: root.showPage(tab.modelData.id)
				}
			}
		}
	}

	Item {
		id: stage

		// The item of whichever page is currently loaded; the keyboard follows it.
		readonly property Item activeItem: {
			if (wallpaperPage.active) return wallpaperPage.item;
			if (motionPage.active) return motionPage.item;
			if (stylePage.active) return stylePage.item;
			return null;
		}

		anchors.top: tabs.bottom
		anchors.topMargin: 10
		anchors.left: parent.left
		anchors.leftMargin: 20
		anchors.right: parent.right
		anchors.rightMargin: 20
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 20

		// Only the visible page is instantiated: the wallpaper page starts
		// preview processes and must not run behind another tab.
		Loader {
			id: wallpaperPage
			anchors.fill: parent
			active: root.page === "wallpaper"
			onLoaded: Qt.callLater(root.focusPage)
			sourceComponent: ThemePickerPopup {
				foreground: root.foreground
				background: root.background
				secondaryBoxColor: root.secondaryBoxColor
				secondaryBoxStrongColor: root.secondaryBoxStrongColor
				secondaryInsetColor: root.secondaryInsetColor
				barColor: root.barColor
				danger: root.danger
				onCloseRequested: root.closeRequested()
			}
		}

		Loader {
			id: motionPage
			anchors.fill: parent
			active: root.page === "motion"
			onLoaded: Qt.callLater(root.focusPage)
			sourceComponent: AnimationPickerPopup {
				foreground: root.foreground
				background: root.background
				secondaryBoxColor: root.secondaryBoxColor
				secondaryBoxStrongColor: root.secondaryBoxStrongColor
				secondaryInsetColor: root.secondaryInsetColor
				barColor: root.barColor
				onCloseRequested: root.closeRequested()
			}
		}

		Loader {
			id: stylePage
			anchors.fill: parent
			active: root.page === "styles"
			onLoaded: Qt.callLater(root.focusPage)
			sourceComponent: BranchStylePicker {
				foreground: root.foreground
				background: root.background
				secondaryBoxColor: root.secondaryBoxColor
				secondaryBoxStrongColor: root.secondaryBoxStrongColor
				secondaryInsetColor: root.secondaryInsetColor
				barColor: root.barColor
				danger: root.danger
				onCloseRequested: root.closeRequested()
			}
		}
	}
}
