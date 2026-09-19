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

	// The pages Studio has. Adding one means adding a lobe here and a Loader
	// in the stage below — nothing else.
	//
	// STUDIO IS PART OF EVERY STYLE. A style branch may draw these pages any
	// way it likes, but it may not drop one: `>studio` is how the desktop is
	// changed at all, and a style that ships without a page leaves the thing
	// that page controls unreachable. See STUDIO.md.
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

	// Studio is a bench, not a box: the scrim behind it is the surface, and the
	// only structure drawn is the bone between the lobes and the pages.
	//
	// The lobes stand in a column down the left, the way everything in this
	// shell is now read — top to bottom, against a bone.
	Column {
		id: tabs

		anchors.top: parent.top
		anchors.topMargin: Bio.s5
		anchors.left: parent.left
		width: 210
		spacing: Bio.s2

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

				width: tabs.width
				height: 44

				// The vein: the lobe you are in is the one the organ is
				// feeding, exactly as a row is marked everywhere else.
				Rectangle {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					width: Bio.rib * 1.6
					height: parent.height * (tab.active ? 0.6 : 0)
					radius: width / 2
					color: Bio.organ
					opacity: tab.active ? 1 : 0

					Behavior on opacity {
						NumberAnimation { duration: Bio.twitch }
					}
					Behavior on height {
						NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
					}
				}

				Column {
					anchors.left: parent.left
					anchors.leftMargin: Bio.s4
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					spacing: -2

					BioText {
						width: parent.width
						role: "heading"
						text: tab.modelData.label
						tone: tab.active ? "organ" : (tab.live > 0.3 ? "default" : "muted")
						font.pixelSize: 15
					}

					BioText {
						width: parent.width
						role: "mono"
						text: tab.modelData.hint
						tone: "faint"
						opacity: tab.live > 0.3 ? 1 : 0.55
						font.pixelSize: 10
					}
				}

				BioTouch {
					id: tabMouse
					onClicked: root.showPage(tab.modelData.id)
				}
			}
		}
	}

	// The bone the lobes are written against, and the pages hang off.
	Rectangle {
		id: studioBone

		anchors.left: tabs.right
		anchors.leftMargin: Bio.s6
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.topMargin: Bio.s4
		anchors.bottomMargin: Bio.s4
		width: Bio.ribThin
		color: Bio.boneGhost
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

		anchors.top: parent.top
		anchors.topMargin: Bio.s5
		anchors.left: studioBone.right
		anchors.leftMargin: Bio.s7
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.bottomMargin: Bio.s5

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
