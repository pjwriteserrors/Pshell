pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"

// Studio: the one wide lantern where the desktop's looks are changed.
//
// The five pages are five beads on Studio's own wire across the top; a light
// slides along that wire to whichever page is open, and the page's contents
// surface underneath in bands. Only the open page exists.
//
//   Escape                     close (every page handles it)
//   Ctrl+Tab / Ctrl+Shift+Tab  next / previous page
//   Ctrl+1 .. Ctrl+5           jump to a page
//   arrows / Enter / typing    belong to the page
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
	property real reveal: 1

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

	// A page change re-surfaces the contents: the bands of the new page rise
	// in order, the same way the lantern itself unfolded.
	property real switchReveal: 1
	readonly property real pageReveal: Math.min(root.reveal, root.switchReveal)

	readonly property int headHeight: 78
	readonly property int wireY: 40

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
	Component.onCompleted: {
		Qt.callLater(root.focusPage);
		Qt.callLater(root.placeLight, false);
	}
	onPageChanged: {
		root.switchReveal = 0;
		switchAnim.restart();
		Qt.callLater(root.focusPage);
		Qt.callLater(root.placeLight, true);
	}
	onWidthChanged: Qt.callLater(root.placeLight, false)

	NumberAnimation {
		id: switchAnim
		target: root
		property: "switchReveal"
		to: 1
		duration: Filament.unfold
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Filament.easeUnfold
	}

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

	// ------------------------------------------------------------- the head
	// The stem from the Veil's hook down to Studio's own wire.
	Wire {
		vertical: true
		x: Math.round(root.width / 2) - 1
		y: 0
		width: 2
		height: root.wireY
		lit: root.reveal
		animateLit: false
		glow: false
	}

	// The wire the pages hang on. It is lit for a short stretch under the
	// open page, and the light travels there when the page changes.
	Wire {
		id: headWire
		x: 24
		y: root.wireY - 1
		width: root.width - 48
		height: 2
		cold: Filament.wireDim
		animateLit: false
		lit: Math.min(1, 96 / Math.max(1, width))
		litFrom: Math.max(0, (light.x + light.width / 2 - x - 48) / Math.max(1, width))
	}

	Spark {
		id: light
		x: Math.round(root.width / 2) - size / 2
		y: root.wireY - size / 2
		size: 8
		breathing: !lightTravel.running
		NumberAnimation {
			id: lightTravel
			target: light
			property: "x"
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Filament.easeTravel
		}
	}

	function placeLight(travel) {
		const bead = beadRepeater.itemAt(root.pageIndex);
		if (!bead) return;
		const target = Math.round(beadRow.x + bead.x + bead.width / 2 - light.size / 2);
		lightTravel.stop();
		if (!travel) {
			light.x = target;
			return;
		}
		lightTravel.duration = Filament.travelTime(target - light.x);
		lightTravel.to = target;
		lightTravel.start();
		bead.flash();
	}

	Row {
		id: beadRow
		anchors.horizontalCenter: parent.horizontalCenter
		y: root.wireY - (Filament.beadHeight + 4) / 2
		spacing: 26
		opacity: Math.min(1, root.reveal * 1.4)

		Repeater {
			id: beadRepeater
			model: root.pages

			Bead {
				id: pageBead
				required property var modelData
				required property int index
				readonly property bool open: root.page === pageBead.modelData.id
				beadHeight: Filament.beadHeight + 4
				padding: 13
				lit: open
				active: open
				onClicked: root.showPage(pageBead.modelData.id)

				Row {
					spacing: 8
					FText {
						anchors.verticalCenter: parent.verticalCenter
						text: pageBead.modelData.label
						tone: pageBead.open || pageBead.hovered ? "ink" : "soft"
						font.pixelSize: Filament.textMd
						font.weight: pageBead.open ? Font.DemiBold : Font.Medium
						Behavior on color { ColorAnimation { duration: Filament.quick } }
					}
					FText {
						anchors.verticalCenter: parent.verticalCenter
						text: pageBead.modelData.hint
						mono: true
						tone: pageBead.open ? "charge" : "faint"
						font.pixelSize: Filament.textXs
						Behavior on color { ColorAnimation { duration: Filament.quick } }
					}
				}
			}
		}
	}

	// ------------------------------------------------------------ the stage
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
		anchors.topMargin: root.headHeight
		anchors.left: parent.left
		anchors.leftMargin: 24
		anchors.right: parent.right
		anchors.rightMargin: 24
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 22

		// Only the visible page is instantiated: the wallpaper page starts
		// preview processes and must not run behind another tab.
		Loader {
			id: wallpaperPage
			anchors.fill: parent
			active: root.page === "wallpaper"
			onLoaded: Qt.callLater(root.focusPage)
			sourceComponent: ThemePickerPopup {
				reveal: root.pageReveal
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
				reveal: root.pageReveal
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
				reveal: root.pageReveal
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
				reveal: root.pageReveal
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
				reveal: root.pageReveal
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
