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
// Here it is a book of five chapters, and the chapters are runes across the
// foot of the page — the same five runes the codex has at its foot, and turned
// to the same way. Changing chapter does not slide or cross-fade: what is on
// the page comes apart into motes and the next condenses in its place.
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

	function showPage(id) {
		if (!id || id === root.page) return;
		root.page = id;
		changeover.restart();
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
	//
	// They are Shortcuts and not only key handlers because Tab is claimed by
	// focus navigation before an unhandled key ever reaches this scope, so
	// Ctrl+Tab would quietly do nothing. The Keys handler below stays as the
	// path for the digits, which do arrive.
	Shortcut {
		sequences: ["Ctrl+Tab"]
		context: Qt.WindowShortcut
		onActivated: root.cyclePage(1)
	}

	Shortcut {
		sequences: ["Ctrl+Shift+Tab", "Ctrl+Shift+Backtab"]
		context: Qt.WindowShortcut
		onActivated: root.cyclePage(-1)
	}

	Repeater {
		model: root.pages

		delegate: Item {
			required property var modelData
			required property int index

			Shortcut {
				sequences: [`Ctrl+${index + 1}`]
				context: Qt.WindowShortcut
				onActivated: root.showPage(modelData.id)
			}
		}
	}

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

	// The stage. Changing chapter does not slide or cross-fade: what is on the
	// page comes apart into motes and the next chapter condenses in its place,
	// which is the only way anything arrives in this shell.
	property real settled: 1

	SequentialAnimation {
		id: changeover
		NumberAnimation { target: root; property: "settled"; to: 0; duration: Arc.recoil; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveSink }
		ScriptAction { script: pageMotes.burst(pageMotes.width / 2, pageMotes.height / 2, 26) }
		NumberAnimation { target: root; property: "settled"; to: 1; duration: Arc.draw; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveRise }
	}

	ArcLeaf {
		id: page

		anchors.fill: parent
		variant: "chamber"
		crest: true
		washTop: Arc.haze
		washBottom: Arc.hazeDeep
		haloStrength: 0.14
		padding: Arc.s6

		// The running head: what book this is and what chapter is open.
		Item {
			id: runningHead
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			height: 24

			ArcText {
				id: bookName
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				role: "label"
				tone: "aether"
				text: "Studio"
				font.letterSpacing: Arc.trackingRubric + 2
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
				anchors.right: parent.right
				anchors.leftMargin: Arc.s4
				anchors.verticalCenter: parent.verticalCenter
				height: 10
				lineColor: Arc.goldGhost
				facing: Qt.LeftToRight
				visible: width > 36
			}
		}

		Item {
			id: stage

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
			anchors.top: runningHead.bottom
			anchors.bottom: chapters.top
			anchors.topMargin: Arc.s5
			anchors.bottomMargin: Arc.s5

			opacity: root.settled

			transform: Translate {
				y: (1 - root.settled) * 14
			}

			// Only the visible chapter is instantiated: the wallpaper page
			// starts preview processes and must not run behind another.
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

		ArcMotes {
			id: pageMotes
			anchors.fill: stage
			color: Arc.aether
			span: 3.4
		}

		// THE CHAPTERS.
		//
		// Five runes across the foot of the page, exactly as the codex has its
		// runes, and for the same reason: this is a book of five chapters and
		// the runes are how you turn to one. The one you are in is alight with
		// a ley drawn under it and its name written beneath; the others name
		// themselves when the pointer finds them.
		Item {
			id: chapters

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: 64

			Row {
				id: chapterRow
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.top: parent.top
				spacing: Arc.s7

				Repeater {
					model: root.pages

					delegate: Item {
						id: chapter

						required property var modelData
						required property int index
						readonly property bool active: root.page === chapter.modelData.id
						readonly property real live: Math.max(chapterTouch.live, chapter.active ? 1 : 0)

						width: 46
						height: 64

						ArcHalo {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.top: parent.top
							width: 88
							height: 88
							color: Arc.aether
							strength: 0.32
							spread: 0.3
							flicker: true
							opacity: chapter.live
							visible: opacity > 0.01

							Behavior on opacity {
								NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveKindle }
							}
						}

						ArcRune {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.top: parent.top
							anchors.topMargin: 2
							width: 22
							height: 30
							seed: chapter.index * 9 + 5
							weight: chapter.active ? Arc.rule * 1.4 : Arc.ruleThin
							lineColor: chapter.active ? Arc.aether
								: chapter.live > 0.2 ? Arc.ink : Qt.alpha(Arc.gold, 0.4)
						}

						Rectangle {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.top: parent.top
							anchors.topMargin: 38
							width: chapter.active ? parent.width : 0
							height: Arc.ruleThin
							color: Arc.aether

							Behavior on width {
								NumberAnimation { duration: Arc.draw; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveInk }
							}
						}

						ArcText {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.top: parent.top
							anchors.topMargin: 44
							width: 128
							horizontalAlignment: Text.AlignHCenter
							role: "label"
							font.pixelSize: 9
							tone: chapter.active ? "aether" : "muted"
							text: chapter.modelData.label
							opacity: chapter.live > 0.2 ? 1 : 0
							elide: Text.ElideNone

							Behavior on opacity {
								NumberAnimation { duration: Arc.tick }
							}
						}

						ArcTouch {
							id: chapterTouch
							onClicked: root.showPage(chapter.modelData.id)
						}
					}
				}
			}
		}
	}
}
