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
//   Ctrl+1 .. Ctrl+5  jump to a page
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

	// The page list is a contract, not a style decision: every style branch
	// carries all five, because each one is the only way to reach what it
	// controls. Validate.qml fails the build if one goes missing. See STUDIO.md.
	readonly property var pages: [
		{ id: "wallpaper", label: "Wallpaper & Colours", hint: "Ctrl+1" },
		{ id: "motion", label: "Motion", hint: "Ctrl+2" },
		{ id: "dress", label: "Icons & Pointer", hint: "Ctrl+3" },
		{ id: "styles", label: "Style", hint: "Ctrl+4" },
		{ id: "combinations", label: "Combinations", hint: "Ctrl+5" }
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
		case Qt.Key_3:
		case Qt.Key_4:
		case Qt.Key_5: {
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
	// Studio brings its own panel: without it they float unreadably over the
	// desktop.
	Rectangle {
		anchors.fill: parent
		radius: ThemeEngine.radiusLarge
		color: root.background
		border.width: 1
		border.color: Qt.alpha(root.foreground, 0.12)
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

			delegate: Rectangle {
				id: tab

				required property var modelData
				readonly property bool active: root.page === tab.modelData.id

				width: Math.min(240, (root.width - 46) / root.pages.length)
				height: tabs.height
				radius: ThemeEngine.radiusMedium
				color: tab.active
					? root.secondaryBoxStrongColor
					: tabMouse.containsMouse ? root.secondaryBoxColor : "transparent"

				Behavior on color {
					CAnim {}
				}

				Row {
					anchors.centerIn: parent
					spacing: 8

					Text {
						anchors.verticalCenter: parent.verticalCenter
						text: tab.modelData.label
						color: root.foreground
						opacity: tab.active ? 1 : 0.62
						font.pixelSize: 13
					}

					Text {
						anchors.verticalCenter: parent.verticalCenter
						text: tab.modelData.hint
						color: root.foreground
						opacity: tab.active ? 0.45 : 0.28
						font.family: "Adwaita Mono"
						font.pixelSize: 10
					}
				}

				MouseArea {
					id: tabMouse
					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
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
			if (dressPage.active) return dressPage.item;
			if (stylePage.active) return stylePage.item;
			if (combinationPage.active) return combinationPage.item;
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
			id: dressPage
			anchors.fill: parent
			active: root.page === "dress"
			onLoaded: Qt.callLater(root.focusPage)
			sourceComponent: DressPicker {
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

		Loader {
			id: combinationPage
			anchors.fill: parent
			active: root.page === "combinations"
			onLoaded: Qt.callLater(root.focusPage)
			sourceComponent: CombinationPicker {
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
