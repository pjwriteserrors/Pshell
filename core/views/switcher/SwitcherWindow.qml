pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Layouts.js" as Layouts

// The window switcher on the focused screen (core/services/Switcher.qml has
// the logic). It takes the keyboard and holds niri's shortcuts off while it
// is open, so Tab and the arrows come straight here; letting go of Alt or
// Super picks. The cards are one set whatever the layout: a new pick or a
// new layout moves them (Layouts.js), the blur behind is one capture of the
// screen taken as it opens, at a quarter of its size.
PanelWindow {
	id: root

	readonly property bool open: Switcher.open
	readonly property bool shown: Switcher.shown
	// fades out after a pick or a cancel before the surface goes
	property bool leaving: false
	property real reveal: 0
	// the pointer only picks once it moved (a still one under a card would
	// steal the pick the moment the cards appear)
	property bool pointerMoved: false
	// moves of the pick animate only once the cards are where they belong
	property bool settled: false

	readonly property var placed: Layouts.compute(Switcher.layout, Switcher.items, Switcher.index, stage.width, stage.height, Switcher.size, name => Niri.outputOrder(name))

	screen: Switcher.screen
	// mapped only once it shows: a quick Alt+Tab is over before that, and a
	// layer surface mapped and unmapped within a few milliseconds crashed
	// Qt's Wayland client (QWaylandWindow::handleScreensChanged on a screen
	// already gone). Until then held_keys.py watches the modifier.
	visible: root.shown || root.leaving
	color: "transparent"
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.namespace: "shell-switcher"
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
	// nothing to click while it fades away
	mask: Region {
		item: root.open ? fullMask : null
	}

	Item {
		id: fullMask

		anchors.fill: parent
	}

	ShortcutInhibitor {
		window: root
		enabled: root.open
	}

	onOpenChanged: {
		if (root.open) {
			leaveTimer.stop();
			root.leaving = false;
			root.pointerMoved = false;
			root.settled = false;
			keys.forceActiveFocus();
		} else if (root.visible) {
			root.leaving = true;
			leaveTimer.restart();
		}
	}

	onShownChanged: if (root.shown) {
		settleTimer.restart();
		keys.forceActiveFocus();
	}

	Timer {
		id: leaveTimer

		interval: 260
		onTriggered: root.leaving = false
	}

	Timer {
		id: settleTimer

		interval: Motion.long + 120
		onTriggered: root.settled = true
	}

	// how far it is open: 0 hidden, 1 there; a little bloom in, quick out
	readonly property bool wanted: root.shown && (Switcher.backdrop !== "blur" || capture.hasContent || blurWait.waited)

	onWantedChanged: {
		revealAnim.stop();
		revealAnim.to = root.wanted ? 1 : 0;
		revealAnim.duration = root.wanted ? Motion.long : 180;
		revealAnim.easing.bezierCurve = root.wanted ? Motion.decel : Motion.accel;
		revealAnim.start();
	}

	NumberAnimation {
		id: revealAnim

		target: root
		property: "reveal"
		easing.type: Easing.BezierSpline
	}

	// the capture may be slow on a busy GPU; then it comes in late
	Timer {
		id: blurWait

		property bool waited: false

		interval: 160
		running: root.shown
		onRunningChanged: if (running) waited = false
		onTriggered: waited = true
	}

	// ── behind the cards ───────────────────────────────────────────────────
	Item {
		id: backdrop

		anchors.fill: parent
		opacity: root.reveal

		ScreencopyView {
			id: capture

			anchors.fill: parent
			visible: false
			// a new capture every opening: the screen as it is now
			captureSource: root.open && Switcher.backdrop === "blur" ? root.screen : null
			live: false
			constraintSize: Qt.size(Math.round(root.width / 3), Math.round(root.height / 3))
		}

		MultiEffect {
			anchors.fill: parent
			visible: Switcher.backdrop === "blur" && capture.hasContent
			source: capture
			blurEnabled: true
			blurMax: 48
			blur: 0.5 + Switcher.backdropStrength * 0.5
			saturation: -0.1
			autoPaddingEnabled: false
		}

		Rectangle {
			anchors.fill: parent
			color: Switcher.backdrop === "blur" ? Theme.bg : "black"
			opacity: Switcher.backdrop === "clear" ? 0 : (Switcher.backdrop === "blur" ? 0.15 + Switcher.backdropStrength * 0.35 : 0.2 + Switcher.backdropStrength * 0.55)
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.LeftButton | Qt.RightButton
			onClicked: Switcher.cancel()
		}
	}

	// ── the cards ──────────────────────────────────────────────────────────
	Item {
		id: stage

		anchors.fill: parent
		anchors.margins: 40
		opacity: Switcher.entrance === "cascade" ? Math.min(1, root.reveal * 3) : root.reveal
		scale: Switcher.entrance === "zoom" ? 0.9 + 0.1 * root.reveal
			: (!root.open && Switcher.picked >= 0 ? 1.02 : 1)
		transform: Translate {
			y: Switcher.entrance === "rise" ? (1 - root.reveal) * 70 : 0
		}

		// frames of the workspaces layout
		Repeater {
			model: root.placed.groups

			delegate: Rectangle {
				id: group

				required property var modelData

				x: group.modelData.x
				y: group.modelData.y
				width: group.modelData.w
				height: group.modelData.h
				radius: Switcher.radius + 10
				color: Qt.alpha(Theme.bg, 0.55)
				border.width: 1
				border.color: group.modelData.active ? Qt.alpha(Theme.primary, 0.45) : Qt.alpha(Theme.fg, 0.1)

				Behavior on x {
					enabled: root.settled
					SpatialAnim {}
				}
				Behavior on y {
					enabled: root.settled
					SpatialAnim {}
				}

				StyledText {
					x: 16
					y: 8
					text: group.modelData.label
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
					tone: group.modelData.active ? Theme.primary : Theme.textMuted
				}
			}
		}

		// the picked window big, beside the list
		Item {
			id: hero

			readonly property var place: root.placed.hero
			readonly property var item: Switcher.current

			visible: !!hero.place && !!hero.item
			x: hero.place?.x ?? 0
			y: hero.place?.y ?? 0
			width: hero.place?.w ?? 0
			height: hero.place?.h ?? 0

			Behavior on width {
				enabled: root.settled
				SpatialAnim {}
			}
			Behavior on height {
				enabled: root.settled
				SpatialAnim {}
			}
			Behavior on y {
				enabled: root.settled
				SpatialAnim {}
			}

			SwitcherCard {
				anchors.fill: parent
				item: hero.item ?? ({ appId: "", title: "", urgent: false })
				picture: hero.item ? Switcher.shot(hero.item.id, Switcher.shotsRev) : ""
				radius: Switcher.radius
				selected: true
				effect: Switcher.effect === "spotlight" ? "glow" : Switcher.effect
				showTitle: Switcher.titles !== "none"
				showNumber: false
				onClicked: Switcher.pick()
				onCloseClicked: if (hero.item) Switcher.closeWindow(hero.item.id)
			}
		}

		Repeater {
			id: cards

			model: Switcher.items

			delegate: SwitcherCard {
				id: card

				required property var modelData
				required property int index

				readonly property var place: root.placed.cards[card.index] ?? ({ x: 0, y: 0, w: 1, h: 1, z: 0, rotation: 0, yaw: 0, scale: 1, opacity: 0, row: false })
				readonly property int distance: Math.abs(card.index - Switcher.index)
				// 0 → 1 as the card comes in (cascade, rise: one after another)
				property real intro: 0

				item: card.modelData
				number: card.index + 1
				selected: card.index === Switcher.index
				row: card.place.row
				picture: Switcher.shot(card.modelData.id, Switcher.shotsRev)
				radius: card.place.row ? 12 : Switcher.radius
				effect: Switcher.effect
				dimmed: Switcher.effect === "spotlight" && !card.selected && !card.place.row
				showTitle: !card.place.row && (Switcher.titles === "all" || (Switcher.titles === "selected" && card.selected))
				showNumber: Switcher.numbers
				animate: root.settled

				readonly property real cx: stage.width / 2 - card.place.w / 2
				readonly property real cy: stage.height / 2 - card.place.h / 2
				readonly property bool flying: Switcher.entrance === "cascade"

				x: card.flying ? card.cx + (card.place.x - card.cx) * card.intro : card.place.x
				y: (card.flying ? card.cy + (card.place.y - card.cy) * card.intro : card.place.y)
					+ (Switcher.entrance === "rise" ? (1 - card.intro) * 50 : 0)
				z: card.place.z
				width: card.place.w
				height: card.place.h
				rotation: card.place.rotation * (card.flying ? card.intro : 1)
				yaw: card.place.yaw
				scale: card.place.scale * (card.flying ? 0.4 + 0.6 * card.intro : 1)
					* (!root.open && Switcher.picked === card.modelData.id ? 1.06 : 1)
				opacity: card.place.opacity * (Switcher.entrance === "rise" || card.flying ? card.intro : 1)
				transformOrigin: Item.Center

				Behavior on x {
					enabled: root.settled
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on y {
					enabled: root.settled
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on width {
					enabled: root.settled
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on height {
					enabled: root.settled
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on rotation {
					enabled: root.settled
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on scale {
					enabled: root.settled || !root.open
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					enabled: root.settled
					Anim {}
				}

				// the entrance, nearest to the pick first
				SequentialAnimation {
					id: comeIn

					PauseAnimation {
						duration: Math.min(card.distance, 8) * 28
					}
					NumberAnimation {
						target: card
						property: "intro"
						to: 1
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}

				Connections {
					target: root

					function onRevealChanged() {
						if (root.reveal > 0 && card.intro === 0 && !comeIn.running) comeIn.start();
					}
					function onOpenChanged() {
						if (root.open) {
							comeIn.stop();
							card.intro = 0;
						}
					}
				}
				Component.onCompleted: if (root.reveal > 0) card.intro = 1

				onHovered: {
					if (!root.pointerMoved) return;
					Switcher.select(card.index);
				}
				onClicked: Switcher.pickAt(card.index)
				onCloseClicked: Switcher.closeWindow(card.modelData.id)
			}
		}

		// the pointer has to move before hovering picks
		HoverHandler {
			property point first: Qt.point(-1, -1)

			onPointChanged: {
				if (root.pointerMoved || !root.open) return;
				const p = point.position;
				if (first.x < 0) first = p;
				else if (Math.hypot(p.x - first.x, p.y - first.y) > 6) root.pointerMoved = true;
			}
		}
	}

	// ── what is shown at the bottom ────────────────────────────────────────
	Row {
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 34
		spacing: 18
		opacity: root.reveal * 0.9

		Repeater {
			model: [
				{ key: "Tab", text: "next" },
				{ key: "Enter", text: "switch" },
				{ key: "Del", text: "close" },
				{ key: "[ ]", text: Switcher.layouts.find(l => l.id === Switcher.layout)?.label ?? "" },
				{ key: "Esc", text: "cancel" }
			]

			delegate: Row {
				id: hint

				required property var modelData

				spacing: 6

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: keyText.implicitWidth + 12
					height: 20
					radius: 6
					color: Qt.alpha(Theme.bg, 0.75)
					border.width: 1
					border.color: Qt.alpha(Theme.fg, 0.14)

					StyledText {
						id: keyText

						anchors.centerIn: parent
						text: hint.modelData.key
						font.pixelSize: Theme.size.tiny
						font.weight: Font.DemiBold
					}
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: hint.modelData.text
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
				}
			}
		}
	}

	// ── keys ───────────────────────────────────────────────────────────────
	Item {
		id: keys

		focus: true

		function isHolder(key) {
			return key === Qt.Key_Alt || key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_AltGr;
		}

		function go(direction) {
			Switcher.select(Layouts.neighbour(Switcher.layout, root.placed, Switcher.index, direction));
		}

		Keys.onReleased: event => {
			if (keys.isHolder(event.key) && !event.isAutoRepeat) {
				// another holder still down keeps it open
				const rest = event.modifiers & (Qt.AltModifier | Qt.MetaModifier);
				const self = event.key === Qt.Key_Alt ? Qt.AltModifier : Qt.MetaModifier;
				if ((rest & ~self) === 0) Switcher.release();
				event.accepted = true;
			}
		}

		Keys.onPressed: event => {
			const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
			switch (event.key) {
			case Qt.Key_Tab:
				Switcher.move(shift ? -1 : 1);
				break;
			case Qt.Key_Backtab:
				Switcher.move(-1);
				break;
			case Qt.Key_QuoteLeft:
			case Qt.Key_AsciiTilde:
			case Qt.Key_Dead_Grave:
				Switcher.move(shift ? -1 : 1);
				break;
			case Qt.Key_Left:
			case Qt.Key_H:
				keys.go("left");
				break;
			case Qt.Key_Right:
			case Qt.Key_L:
				keys.go("right");
				break;
			case Qt.Key_Up:
			case Qt.Key_K:
				keys.go("up");
				break;
			case Qt.Key_Down:
			case Qt.Key_J:
				keys.go("down");
				break;
			case Qt.Key_Home:
				Switcher.select(0);
				break;
			case Qt.Key_End:
				Switcher.select(Switcher.items.length - 1);
				break;
			case Qt.Key_Return:
			case Qt.Key_Enter:
			case Qt.Key_Space:
				Switcher.pick();
				break;
			case Qt.Key_Delete:
			case Qt.Key_Q:
				if (Switcher.current) Switcher.closeWindow(Switcher.current.id);
				break;
			case Qt.Key_BracketLeft:
				Switcher.cycleLayout(-1);
				break;
			case Qt.Key_BracketRight:
				Switcher.cycleLayout(1);
				break;
			case Qt.Key_Escape:
				Switcher.cancel();
				break;
			default:
				if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
					const at = event.key - Qt.Key_1;
					if (at < Switcher.items.length) Switcher.pickAt(at);
					break;
				}
				return;
			}
			// something happened: it shows now, not after the delay
			if (Switcher.open && !Switcher.shown) Switcher.shown = true;
			event.accepted = true;
		}
	}
}
