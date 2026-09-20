pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"

// The one place where the desktop's looks are changed.
//
// STUDIO IS PART OF EVERY STYLE. A style branch may draw these pages any way it
// likes, but it may not drop one: `>studio` is how the desktop is changed at
// all, and a style that ships without a page leaves whatever that page controls
// unreachable. See STUDIO.md.
//
// Here it is a ledger. The five sections are tabbed dividers standing out of
// the fore-edge of the book, on the right where a thumb would find them; the
// one you are in is pulled proud of the block and the rest sit flush. Changing
// section turns a leaf: a blank page sweeps over the stage about its right edge
// and what is underneath it is the new section, written band by band.
//
// Everything is reachable with the mouse and with the keyboard:
//   Escape            close
//   Ctrl+Tab / Ctrl+Shift+Tab  next / previous section
//   Ctrl+1 .. Ctrl+5  jump to a section
//   arrows / Enter    handled by the section itself
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

	// The sections the ledger has. Adding one means adding a divider here and a
	// Loader in the stage below — nothing else.
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

	readonly property real tabColumn: 46

	function showPage(id) {
		if (!id || id === root.page) return;
		root.page = id;
		leafTurn.restart();
	}

	function cyclePage(delta) {
		const next = (root.pageIndex + delta + root.pages.length) % root.pages.length;
		root.showPage(root.pages[next].id);
	}

	// The section owns the arrow keys, so it has to hold the focus. Re-claiming
	// it after every change keeps a freshly loaded section keyboard-usable
	// without a click.
	function focusPage() {
		if (stage.activeItem) stage.activeItem.forceActiveFocus();
		else root.forceActiveFocus();
	}

	focus: true
	Component.onCompleted: Qt.callLater(root.focusPage)
	onPageChanged: Qt.callLater(root.focusPage)

	// Section shortcuts are deliberately Ctrl-modified: the sections themselves
	// use plain arrows, Enter and typing, and must keep them.
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

	// The block: the leaf everything is written on, with the cut edges of the
	// paper showing along its foot.
	Rectangle {
		id: block
		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.right: parent.right
		anchors.rightMargin: root.tabColumn
		color: Arc.leaf1

		Rectangle {
			anchors.fill: parent
			color: "transparent"
			border.width: Arc.ruleThin
			border.color: Arc.giltFaint
		}

		// The running head: what book this is and what section is open.
		Item {
			id: runningHead
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.leftMargin: Arc.s6
			anchors.rightMargin: Arc.s6
			anchors.topMargin: Arc.s4
			height: 22

			ArcText {
				id: bookName
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				role: "label"
				tone: "aether"
				text: "Studio"
				font.letterSpacing: Arc.trackingRubric + 1.4
			}

			ArcText {
				id: sectionName
				anchors.left: bookName.right
				anchors.leftMargin: Arc.s4
				anchors.verticalCenter: parent.verticalCenter
				role: "label"
				tone: "muted"
				text: root.pages[root.pageIndex].label
			}

			ArcFlourish {
				anchors.left: sectionName.right
				anchors.right: headFolio.left
				anchors.leftMargin: Arc.s4
				anchors.rightMargin: Arc.s4
				anchors.verticalCenter: parent.verticalCenter
				height: 10
				facing: Qt.LeftToRight
				lineColor: Arc.giltFaint
				visible: width > 36
			}

			ArcText {
				id: headFolio
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				role: "mono"
				tone: "faint"
				font.pixelSize: 10
				text: `${root.pageIndex + 1} / ${root.pages.length}`
			}
		}

		Rectangle {
			id: headRule
			anchors.left: runningHead.left
			anchors.right: runningHead.right
			anchors.top: runningHead.bottom
			anchors.topMargin: Arc.s2
			height: Arc.ruleThin
			color: Arc.giltFaint
		}

		Item {
			id: stage

			// The item of whichever section is currently loaded; the keyboard
			// follows it.
			readonly property Item activeItem: {
				if (wallpaperPage.active) return wallpaperPage.item;
				if (motionPage.active) return motionPage.item;
				if (dressPage.active) return dressPage.item;
				if (stylePage.active) return stylePage.item;
				if (combinationPage.active) return combinationPage.item;
				return null;
			}

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: headRule.bottom
			anchors.bottom: parent.bottom
			anchors.leftMargin: Arc.s6
			anchors.rightMargin: Arc.s6
			anchors.topMargin: Arc.s5
			anchors.bottomMargin: Arc.s5

			// Only the visible section is instantiated: the wallpaper page
			// starts preview processes and must not run behind another tab.
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

		// THE LEAF. Changing section turns a page: a blank sheet lies over the
		// stage for a beat and then swings away about its right edge, in real
		// perspective, and what is under it is the new section. Nothing here
		// cross-fades.
		Item {
			id: turningLeaf

			property real turn: 1

			anchors.fill: parent
			visible: turningLeaf.turn < 0.995
			z: 5

			NumberAnimation {
				id: leafTurn
				target: turningLeaf
				property: "turn"
				from: 0
				to: 1
				duration: Arc.unroll
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveSwing
			}

			transform: Matrix4x4 {
				readonly property real angle: -104 * Math.max(0, (turningLeaf.turn - 0.18) / 0.82)

				matrix: {
					const d = 2600;
					const rad = angle * Math.PI / 180;
					const c = Math.cos(rad), s = Math.sin(rad);
					const px = turningLeaf.width, py = turningLeaf.height / 2;
					const toPivot = Qt.matrix4x4(1, 0, 0, px, 0, 1, 0, py, 0, 0, 1, 0, 0, 0, 0, 1);
					const persp = Qt.matrix4x4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -1 / d, 1);
					const rotate = Qt.matrix4x4(c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1);
					const fromPivot = Qt.matrix4x4(1, 0, 0, -px, 0, 1, 0, -py, 0, 0, 1, 0, 0, 0, 0, 1);
					return toPivot.times(persp).times(rotate).times(fromPivot);
				}
			}

			Rectangle {
				anchors.fill: parent
				gradient: Gradient {
					orientation: Gradient.Horizontal
					GradientStop { position: 0.0; color: Arc.leaf2 }
					GradientStop { position: 0.85; color: Arc.leaf1 }
					GradientStop { position: 1.0; color: Arc.leaf3 }
				}

				Rectangle {
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.bottom: parent.bottom
					width: Arc.rule
					color: Arc.giltFaint
				}
			}
		}
	}

	// The dividers, standing out of the fore-edge. The one you are in is pulled
	// proud of the block; the rest sit flush with it and only their titles show.
	Column {
		id: dividers

		anchors.right: parent.right
		anchors.top: parent.top
		anchors.topMargin: Arc.s6
		width: root.tabColumn
		spacing: Arc.s3

		Repeater {
			model: root.pages

			delegate: Item {
				id: divider

				required property var modelData
				required property int index
				readonly property bool active: root.page === divider.modelData.id
				readonly property real live: Math.max(dividerTouch.live, divider.active ? 1 : 0)

				width: root.tabColumn
				height: Math.max(118, tabName.implicitWidth + 46)

				// Pulled out by the thumb, and it stops against a detent.
				x: 0

				transform: Translate {
					x: divider.active ? 7 : dividerTouch.containsMouse ? 4 : 0

					Behavior on x {
						NumberAnimation {
							duration: Arc.turn
							easing.type: Easing.Bezier
							easing.bezierCurve: Arc.curveDetent
						}
					}
				}

				ArcHalo {
					anchors.centerIn: parent
					width: parent.width * 3
					height: parent.height * 1.4
					color: Arc.aether
					strength: 0.22
					spread: 0.34
					opacity: divider.live
					visible: opacity > 0.01

					Behavior on opacity {
						NumberAnimation {
							duration: Arc.turn
							easing.type: Easing.Bezier
							easing.bezierCurve: Arc.curveKindle
						}
					}
				}

				ArcPlate {
					anchors.fill: parent
					variant: "plate"
					weight: Arc.ruleThin
					inset: 0
					beading: false
					lineColor: Arc.giltFaint
					liveColor: Arc.aether
					fillTop: divider.active ? Arc.leaf2 : Arc.leaf0
					fillBottom: divider.active ? Arc.leaf1 : Arc.leaf0
					intensity: divider.live
				}

				// The title, read up the divider the way a divider is read.
				ArcText {
					id: tabName
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.horizontalCenterOffset: -4
					y: Math.round(parent.height / 2 - height / 2)
					rotation: -90
					transformOrigin: Item.Center
					role: "label"
					tone: divider.active ? "aether" : (divider.live > 0.3 ? "default" : "muted")
					text: divider.modelData.label
					font.letterSpacing: Arc.trackingRubric
				}

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.horizontalCenterOffset: 12
					y: Math.round(parent.height / 2 - height / 2)
					rotation: -90
					transformOrigin: Item.Center
					role: "mono"
					tone: "faint"
					font.pixelSize: 9
					text: divider.modelData.hint
					opacity: divider.live > 0.3 ? 1 : 0.55
				}

				ArcTouch {
					id: dividerTouch
					onClicked: root.showPage(divider.modelData.id)
				}
			}
		}
	}
}
