pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.overlays.screenshot

// One per output. Shows the frozen frame while picking what to capture:
// drag a region (a plain click takes the whole screen), click a screen or a
// window, pick a colour with the loupe or select text for OCR. The screen a
// region was taken on turns into the editor; the frame blurs away behind it.
//
// Keys while selecting: Tab cycles modes, r/s/w/p/c/t/b/l pick one (b = QR,
// l = scroll), Shift keeps the region square, Space held moves it, Esc
// cancels. Picker mode: click picks a colour, a drag extracts a palette.
//
// Smart select (modes that take a region): hovering highlights the box under
// the cursor that was found on the frame (a card, button, image, panel), a
// click takes it. The wheel or Up/Down walk out to the boxes around it and
// finally the whole screen; Enter takes the highlighted box.
//
// Without a frozen frame the window also carries the countdown pill of a
// delayed capture and the frame + stop control of a scroll capture; input
// then only reaches those controls (the mask), the rest stays usable.
PanelWindow {
	id: root

	required property var modelData
	readonly property string name: String(root.modelData.name)
	readonly property string frozenPath: Screenshot.frozenFor(root.name)
	readonly property bool selecting: Screenshot.phase === "select" && root.frozenPath !== ""
	readonly property bool editing: Screenshot.phase === "edit" && Screenshot.editScreen === root.name
	readonly property bool beautifying: Screenshot.phase === "beautify" && Screenshot.beautyScreen === root.name
	readonly property bool shown: root.selecting || root.editing || root.beautifying
	readonly property bool owner: root.editing || root.beautifying || (root.selecting && Screenshot.activeScreen === root.name)
	readonly property bool countingDown: Screenshot.phase === "countdown" && Screenshot.countdown > 0 && Screenshot.countdownScreen === root.name
	readonly property bool scrolling: Screenshot.phase === "scroll" && Screenshot.scrollScreen === root.name
	readonly property bool auxiliary: root.countingDown || root.scrolling
	readonly property string mode: Screenshot.mode
	// native pixels per logical pixel of this output
	readonly property real density: frozen.implicitWidth > 0 ? frozen.implicitWidth / Math.max(1, root.width) : 1
	property real reveal: root.shown ? 1 : 0
	property bool editorLive: false
	// the beautifier crossfades with the editor, which stays alive behind it
	property bool beautyLive: false
	property real beautyMix: root.beautifying ? 1 : 0

	Behavior on beautyMix {
		NumberAnimation {
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
	}

	onBeautifyingChanged: {
		if (root.beautifying) root.beautyLive = true;
		Qt.callLater(() => {
			if (root.beautifying) beautyLoader.item?.forceActiveFocus();
			else if (root.editing) editorLoader.item?.forceActiveFocus();
		});
	}
	onBeautyMixChanged: if (root.beautyMix <= 0.001 && !root.beautifying) root.beautyLive = false

	onEditingChanged: if (root.editing) root.editorLive = true
	onRevealChanged: if (root.reveal <= 0.001 && !root.editing) root.editorLive = false
	onOwnerChanged: if (root.owner && !root.editing && !root.beautifying) Qt.callLater(() => keys.forceActiveFocus())
	onSelectingChanged: selector.reset()
	onScrollingChanged: if (root.scrolling) Qt.callLater(() => scrollKeys.forceActiveFocus())

	Behavior on reveal {
		NumberAnimation {
			duration: root.shown ? Motion.short : Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.shown ? Motion.decel : Motion.accel
		}
	}

	screen: root.modelData
	visible: root.shown || root.reveal > 0.001 || root.auxiliary
	color: "transparent"
	mask: root.shown ? null : (root.countingDown ? countdownMask : scrollMask)
	anchors {
		left: true
		right: true
		top: true
		bottom: true
	}
	exclusiveZone: 0
	WlrLayershell.namespace: "shell-screenshot"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: (root.shown && root.owner) || root.scrolling ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

	Region {
		id: countdownMask

		item: countdownPill
	}

	Region {
		id: scrollMask

		item: scrollControl
	}

	// ── frozen frame ───────────────────────────────────────────────────────
	Image {
		id: frozen

		anchors.fill: parent
		source: Screenshot.fileUrl(root.frozenPath)
		asynchronous: false
		cache: true
		smooth: true
		// shares its texture with the editor, which needs mipmaps
		mipmap: true
		// it *is* the screen, so it appears at once and only fades on the way out
		opacity: root.shown ? 1 : root.reveal
		visible: root.frozenPath !== "" && !backdrop.visible
	}

	// behind the editor the frame blurs and darkens
	property real editDepth: root.editing || root.beautifying ? 1 : 0

	Behavior on editDepth {
		NumberAnimation {
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
	}

	MultiEffect {
		id: backdrop

		anchors.fill: parent
		visible: (root.editorLive || root.beautyLive) && root.frozenPath !== ""
		source: frozen
		opacity: root.reveal
		blurEnabled: true
		blur: root.editDepth
		blurMax: 48
		saturation: -0.2 * root.editDepth
	}

	Rectangle {
		anchors.fill: parent
		visible: root.editorLive || root.beautyLive
		color: Qt.rgba(0, 0, 0, root.frozenPath !== "" ? 0.5 : 0.62)
		opacity: root.editDepth * root.reveal
	}

	// ── selection ──────────────────────────────────────────────────────────
	FocusScope {
		id: keys

		anchors.fill: parent
		focus: true
		visible: root.selecting || (!root.editorLive && !root.beautyLive && root.reveal > 0)
		opacity: root.reveal

		Keys.onPressed: event => {
			if (!root.selecting) return;
			const order = Screenshot.modes;
			const key = event.key;
			if (key === Qt.Key_Escape || key === Qt.Key_Q) {
				Screenshot.cancel();
			} else if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
				const step = key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1;
				Screenshot.mode = order[(order.indexOf(root.mode) + step + order.length) % order.length];
			} else if (key === Qt.Key_R) {
				Screenshot.mode = "region";
			} else if (key === Qt.Key_S) {
				Screenshot.mode = "screen";
			} else if (key === Qt.Key_W) {
				Screenshot.mode = "window";
			} else if (key === Qt.Key_P) {
				Screenshot.mode = "pin";
			} else if (key === Qt.Key_V) {
				Screenshot.mode = "live";
			} else if (key === Qt.Key_C) {
				Screenshot.mode = "picker";
			} else if (key === Qt.Key_T || key === Qt.Key_O) {
				Screenshot.mode = "ocr";
			} else if (key === Qt.Key_B) {
				Screenshot.mode = "qr";
			} else if (key === Qt.Key_L) {
				Screenshot.mode = "scroll";
			} else if (key === Qt.Key_Space) {
				selector.moving = true;
			} else if (key === Qt.Key_Up || key === Qt.Key_Down) {
				if (!selector.snapping) return;
				selector.stepSnap(key === Qt.Key_Up ? 1 : -1);
			} else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
				if (selector.snapping) selector.takeSnap(selector.snap);
				else selector.takeScreen(Screenshot.activeScreen);
			} else {
				return;
			}
			event.accepted = true;
		}
		Keys.onReleased: event => {
			if (event.key === Qt.Key_Space && !event.isAutoRepeat) {
				selector.moving = false;
				event.accepted = true;
			}
		}

		Item {
			id: selector

			readonly property bool regionMode: root.mode === "region" || root.mode === "ocr" || root.mode === "pin" || root.mode === "live" || root.mode === "qr" || root.mode === "scroll"
			// picker mode: a drag takes a palette instead of a single colour
			readonly property bool paletteDrag: root.mode === "picker" && selector.hasSelection
			property bool dragging: false
			property bool moving: false
			property real ax: 0
			property real ay: 0
			property real bx: 0
			property real by: 0
			property real lastX: 0
			property real lastY: 0
			property bool square: false
			readonly property real selX: Math.min(selector.ax, selector.bx)
			readonly property real selY: Math.min(selector.ay, selector.by)
			readonly property real selW: Math.abs(selector.bx - selector.ax)
			readonly property real selH: Math.abs(selector.by - selector.ay)
			readonly property bool hasSelection: selector.dragging && (selector.selW >= 2 || selector.selH >= 2)
			readonly property bool hovered: hover.hovered
			// smart select: the boxes under the cursor (logical px), smallest
			// first and the whole screen last; `snapIndex` is the one offered
			readonly property var boxes: root.selecting && selector.regionMode ? Screenshot.boxesFor(root.name) : []
			readonly property point cursor: hover.point.position
			property var snapStack: []
			property int snapIndex: 0
			// the box a press started on, taken when the press ends as a click
			property var pressSnap: null
			readonly property bool snapping: selector.regionMode && selector.hovered && !selector.hasSelection && selector.snapStack.length > 0
			readonly property rect snap: selector.snapping ? selector.snapStack[Math.min(selector.snapIndex, selector.snapStack.length - 1)] : Qt.rect(0, 0, 0, 0)
			// the "hole" in the dim layer
			readonly property rect hole: {
				if (root.mode === "screen" && selector.hovered) return Qt.rect(0, 0, root.width, root.height);
				if (selector.regionMode || selector.paletteDrag) return Qt.rect(shown.x, shown.y, shown.width, shown.height);
				return Qt.rect(0, 0, 0, 0);
			}
			readonly property real dimAlpha: {
				if (root.mode === "picker") return selector.paletteDrag ? 0.5 : 0;
				if (root.mode === "screen") return selector.hovered ? 0 : 0.5;
				if (root.mode === "window") return selector.hovered ? 0.35 : 0.55;
				return selector.hasSelection || selector.snapping ? 0.5 : 0.3;
			}

			onCursorChanged: selector.updateSnap()
			onBoxesChanged: selector.updateSnap()

			anchors.fill: parent

			function reset() {
				selector.dragging = false;
				selector.moving = false;
				selector.pressSnap = null;
				selector.snapStack = [];
				selector.snapIndex = 0;
			}

			function sameRect(a, b) {
				return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;
			}

			function updateSnap() {
				const d = root.density;
				const px = selector.cursor.x;
				const py = selector.cursor.y;
				const stack = [];
				for (const b of selector.boxes) {
					const box = Qt.rect(b[0] / d, b[1] / d, b[2] / d, b[3] / d);
					if (px >= box.x && px < box.x + box.width && py >= box.y && py < box.y + box.height) stack.push(box);
				}
				if (stack.length > 0) {
					stack.sort((a, b) => a.width * a.height - b.width * b.height);
					stack.push(Qt.rect(0, 0, root.width, root.height));
				}
				// the box walked out to stays while the cursor is inside it
				const current = selector.snapping ? selector.snap : null;
				const kept = current ? stack.findIndex(box => selector.sameRect(box, current)) : -1;
				selector.snapStack = stack;
				selector.snapIndex = Math.max(0, kept);
			}

			// +1 walks out to the box around the offered one, -1 back in
			function stepSnap(step) {
				selector.snapIndex = selector.clamp(selector.snapIndex + step, 0, selector.snapStack.length - 1);
			}

			function takeSnap(box) {
				const d = root.density;
				const x = Math.round(box.x * d);
				const y = Math.round(box.y * d);
				Screenshot.selectRegion(root.name, Qt.rect(x, y, Math.min(frozen.implicitWidth - x, Math.round(box.width * d)), Math.min(frozen.implicitHeight - y, Math.round(box.height * d))), Qt.rect(box.x, box.y, box.width, box.height));
			}

			function clamp(v, lo, hi) {
				return Math.max(lo, Math.min(hi, v));
			}

			function takeScreen(output) {
				const target = Quickshell.screens.find(s => String(s.name) === String(output));
				if (!target || output !== root.name) return;
				if (root.mode === "window") {
					Screenshot.selectWindow(root.name);
				} else if (root.mode !== "picker") {
					Screenshot.selectRegion(root.name, Qt.rect(0, 0, frozen.implicitWidth, frozen.implicitHeight), Qt.rect(0, 0, root.width, root.height));
				}
			}

			function finish() {
				const d = root.density;
				if (selector.selW < 4 && selector.selH < 4) {
					if (selector.pressSnap) selector.takeSnap(selector.pressSnap);
					else selector.takeScreen(root.name);
					return;
				}
				const x = Math.round(selector.selX * d);
				const y = Math.round(selector.selY * d);
				Screenshot.selectRegion(root.name, Qt.rect(x, y, Math.min(frozen.implicitWidth - x, Math.round(selector.selW * d)), Math.min(frozen.implicitHeight - y, Math.round(selector.selH * d))),
					Qt.rect(selector.selX, selector.selY, selector.selW, selector.selH));
			}

			HoverHandler {
				id: hover

				onHoveredChanged: if (hover.hovered && root.selecting) Screenshot.activeScreen = root.name
			}

			// dim everywhere but the hole
			Item {
				anchors.fill: parent
				opacity: root.selecting ? 1 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				Repeater {
					model: [
						Qt.rect(0, 0, root.width, selector.hole.y),
						Qt.rect(0, selector.hole.y + selector.hole.height, root.width, root.height - selector.hole.y - selector.hole.height),
						Qt.rect(0, selector.hole.y, selector.hole.x, selector.hole.height),
						Qt.rect(selector.hole.x + selector.hole.width, selector.hole.y, root.width - selector.hole.x - selector.hole.width, selector.hole.height)
					]

					delegate: Rectangle {
						required property rect modelData

						x: modelData.x
						y: modelData.y
						width: Math.max(0, modelData.width)
						height: Math.max(0, modelData.height)
						color: Qt.rgba(0, 0, 0, selector.dimAlpha)

						Behavior on color {
							ColorAnim {
								duration: Motion.medium
							}
						}
					}
				}
			}

			// crosshair guides before the drag starts
			Item {
				anchors.fill: parent
				visible: selector.regionMode && !selector.dragging && selector.hovered && !selector.snapping

				Rectangle {
					x: 0
					y: Math.round(hover.point.position.y)
					width: parent.width
					height: 1
					color: Qt.alpha(Theme.primary, 0.55)
				}
				Rectangle {
					x: Math.round(hover.point.position.x)
					y: 0
					width: 1
					height: parent.height
					color: Qt.alpha(Theme.primary, 0.55)
				}
			}

			// what is on offer, drawn by the frames below: the dragged region,
			// the box a click would take, or – with neither – a point at the
			// cursor, so a frame grows out of it and shrinks back into it. It
			// follows on a spring: tight while dragging, softer between boxes.
			Item {
				id: shown

				readonly property bool region: (selector.regionMode || selector.paletteDrag) && selector.hasSelection
				readonly property bool active: shown.region || selector.snapping
				readonly property rect target: {
					if (shown.region) return Qt.rect(selector.selX, selector.selY, selector.selW, selector.selH);
					if (selector.snapping) return selector.snap;
					return Qt.rect(selector.cursor.x, selector.cursor.y, 0, 0);
				}
				readonly property real stiffness: shown.region ? 16 : 5.5
				readonly property real damping: shown.region ? 0.95 : 0.55

				x: shown.target.x
				y: shown.target.y
				width: shown.target.width
				height: shown.target.height

				Behavior on x {
					SpringAnimation {
						spring: shown.stiffness
						damping: shown.damping
						epsilon: 0.25
					}
				}
				Behavior on y {
					SpringAnimation {
						spring: shown.stiffness
						damping: shown.damping
						epsilon: 0.25
					}
				}
				Behavior on width {
					SpringAnimation {
						spring: shown.stiffness
						damping: shown.damping
						epsilon: 0.25
					}
				}
				Behavior on height {
					SpringAnimation {
						spring: shown.stiffness
						damping: shown.damping
						epsilon: 0.25
					}
				}
			}

			// smart select: the box a click would take
			Item {
				id: snapFrame

				opacity: selector.snapping && shown.width > 1 ? 1 : 0
				visible: opacity > 0.01
				x: shown.x
				y: shown.y
				width: shown.width
				height: shown.height

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				Rectangle {
					anchors.fill: parent
					anchors.margins: -2
					color: "transparent"
					radius: 4
					border.width: 2
					border.color: Theme.primary
				}

				Rectangle {
					readonly property bool below: snapFrame.y + snapFrame.height + height + 12 < root.height
					x: selector.clamp(snapFrame.width / 2 - width / 2, -snapFrame.x + 8, root.width - snapFrame.x - width - 8)
					y: below ? snapFrame.height + 10 : snapFrame.height - height - 10
					width: snapText.implicitWidth + 20
					height: 26
					radius: 13
					color: Qt.alpha(Theme.base, 0.92)

					StyledText {
						id: snapText

						anchors.centerIn: parent
						tabular: true
						// how many boxes lie around this one (the wheel walks out)
						text: `${Math.round(selector.snap.width * root.density)} × ${Math.round(selector.snap.height * root.density)}` + (selector.snapStack.length > 1 ? `  ·  ${selector.snapIndex + 1}/${selector.snapStack.length}` : "")
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}
				}
			}

			// region frame with corner handles and the size label
			Item {
				id: frame

				opacity: shown.region ? 1 : 0
				visible: opacity > 0.01
				x: shown.x
				y: shown.y
				width: shown.width
				height: shown.height

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				Rectangle {
					anchors.fill: parent
					anchors.margins: -1.5
					color: "transparent"
					border.width: 1.5
					border.color: Theme.primary
				}

				// thirds, only on bigger regions
				Repeater {
					model: frame.width > 160 && frame.height > 120 ? 4 : 0

					delegate: Rectangle {
						required property int index
						readonly property bool vertical: index < 2
						x: vertical ? frame.width * (index + 1) / 3 : 0
						y: vertical ? 0 : frame.height * (index - 1) / 3
						width: vertical ? 1 : frame.width
						height: vertical ? frame.height : 1
						color: Qt.rgba(1, 1, 1, 0.14)
					}
				}

				Repeater {
					model: 4

					delegate: Rectangle {
						required property int index
						x: (index % 2 === 0 ? 0 : frame.width) - width / 2
						y: (index < 2 ? 0 : frame.height) - height / 2
						width: 10
						height: 10
						radius: 5
						color: "white"
						border.width: 2
						border.color: Theme.primary
					}
				}

				Rectangle {
					id: sizeLabel

					readonly property bool below: frame.y + frame.height + height + 12 < root.height
					x: selector.clamp(frame.width / 2 - width / 2, -frame.x + 8, root.width - frame.x - width - 8)
					y: below ? frame.height + 10 : frame.height - height - 10
					width: sizeText.implicitWidth + 20
					height: 26
					radius: 13
					color: Qt.alpha(Theme.base, 0.92)

					StyledText {
						id: sizeText

						anchors.centerIn: parent
						tabular: true
						text: `${Math.round(selector.selW * root.density)} × ${Math.round(selector.selH * root.density)}`
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}
				}
			}

			// screen mode: an accent frame around the hovered output
			Rectangle {
				anchors.fill: parent
				anchors.margins: 3
				visible: root.mode === "screen" && selector.hovered
				color: "transparent"
				radius: Theme.screenCorner
				border.width: 3
				border.color: Theme.primary
			}

			// window mode: what a click on this output captures
			Rectangle {
				id: windowCard

				readonly property var target: root.selecting && root.mode === "window" ? Screenshot.activeWindowOn(root.name) : null

				anchors.centerIn: parent
				visible: root.mode === "window" && selector.hovered
				width: Math.min(root.width - 80, cardRow.implicitWidth + 40)
				height: 76
				radius: Theme.radius.huge
				color: Theme.base
				scale: visible ? 1 : 0.9

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				Row {
					id: cardRow

					anchors.centerIn: parent
					spacing: 14

					Item {
						anchors.verticalCenter: parent.verticalCenter
						width: 40
						height: 40

						IconImage {
							anchors.fill: parent
							visible: windowCard.target !== null
							source: windowCard.target ? AppIcons.forAppId(windowCard.target.app_id ?? "") : ""
							asynchronous: true
						}

						Glyph {
							anchors.centerIn: parent
							visible: windowCard.target === null
							icon: "application_outline"
							size: 30
							color: Theme.textSubtle
						}
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						width: Math.min(implicitWidth, root.width - 200)
						text: windowCard.target ? (windowCard.target.title || windowCard.target.app_id || "Window") : "No window"
						tone: windowCard.target ? Theme.text : Theme.textSubtle
						font.pixelSize: Theme.size.title
						font.weight: Font.DemiBold
					}
				}
			}

			// ── colour picker loupe ────────────────────────────────────────
			PixelReader {
				id: reader

				source: root.selecting && root.mode === "picker" ? Screenshot.fileUrl(root.frozenPath) : ""
				px: Math.floor(hover.point.position.x * root.density)
				py: Math.floor(hover.point.position.y * root.density)
			}

			// the pointer is hidden while picking; a small reticle marks the pixel
			Item {
				visible: loupe.visible
				x: Math.floor(loupe.cx)
				y: Math.floor(loupe.cy)

				Repeater {
					model: [[-9, 0, 6, 1], [4, 0, 6, 1], [0, -9, 1, 6], [0, 4, 1, 6]]

					delegate: Rectangle {
						required property var modelData
						x: modelData[0]
						y: modelData[1]
						width: modelData[2]
						height: modelData[3]
						color: "white"
						border.width: 0

						Rectangle {
							anchors.fill: parent
							anchors.margins: -1
							z: -1
							color: Qt.rgba(0, 0, 0, 0.55)
						}
					}
				}
			}

			Item {
				id: loupe

				readonly property real cx: hover.point.position.x
				readonly property real cy: hover.point.position.y
				readonly property int cells: 15
				readonly property real cell: 9
				readonly property real diameter: loupe.cells * loupe.cell
				readonly property bool flipX: loupe.cx + 24 + loupe.diameter > root.width - 8
				readonly property bool flipY: loupe.cy + 24 + loupe.diameter + 44 > root.height - 8

				visible: root.mode === "picker" && selector.hovered && root.selecting && !selector.paletteDrag
				x: loupe.flipX ? loupe.cx - 24 - loupe.diameter : loupe.cx + 24
				y: loupe.flipY ? loupe.cy - 24 - loupe.diameter - 40 : loupe.cy + 24
				width: loupe.diameter
				height: loupe.diameter + 40

				RectangularShadow {
					anchors.fill: lens
					radius: lens.radius
					blur: 24
					color: Theme.shadow
				}

				ClippingRectangle {
					id: lens

					width: loupe.diameter
					height: loupe.diameter
					radius: width / 2
					color: Theme.base
					border.width: 3
					border.color: reader.color

					ShaderEffectSource {
						anchors.fill: parent
						sourceItem: frozen
						sourceRect: Qt.rect(Math.floor(loupe.cx) - Math.floor(loupe.cells / 2), Math.floor(loupe.cy) - Math.floor(loupe.cells / 2), loupe.cells, loupe.cells)
						smooth: false
					}

					// the pixel under the cursor
					Rectangle {
						x: Math.floor(loupe.cells / 2) * loupe.cell - 1
						y: x
						width: loupe.cell + 2
						height: width
						color: "transparent"
						border.width: 1.5
						border.color: "white"

						Rectangle {
							anchors.fill: parent
							anchors.margins: -1.5
							color: "transparent"
							border.width: 1
							border.color: Qt.rgba(0, 0, 0, 0.6)
						}
					}
				}

				Rectangle {
					anchors.horizontalCenter: lens.horizontalCenter
					y: loupe.diameter + 8
					width: hexRow.implicitWidth + 20
					height: 30
					radius: 15
					color: Theme.base

					Row {
						id: hexRow

						anchors.centerIn: parent
						spacing: 8

						Rectangle {
							anchors.verticalCenter: parent.verticalCenter
							width: 14
							height: 14
							radius: 7
							color: reader.color
							border.width: 1
							border.color: Theme.outline
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: `#${[reader.color.r, reader.color.g, reader.color.b].map(v => Math.round(v * 255).toString(16).padStart(2, "0")).join("").toUpperCase()}`
							font.family: Theme.monoFamily
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
						}
					}
				}
			}

			MouseArea {
				anchors.fill: parent
				enabled: root.selecting
				acceptedButtons: Qt.LeftButton | Qt.RightButton
				cursorShape: {
					if (root.mode === "picker") return selector.paletteDrag ? Qt.CrossCursor : Qt.BlankCursor;
					if (selector.regionMode) return Qt.CrossCursor;
					return Qt.PointingHandCursor;
				}

				onPressed: mouse => {
					if (mouse.button === Qt.RightButton && root.mode !== "picker") {
						Screenshot.cancel();
						return;
					}
					if (root.mode === "picker" && mouse.button === Qt.RightButton) {
						Screenshot.pickColor(reader.color, true);
						return;
					}
					if (!selector.regionMode && root.mode !== "picker") return;
					selector.pressSnap = selector.snapping ? selector.snap : null;
					selector.ax = mouse.x;
					selector.ay = mouse.y;
					selector.bx = mouse.x;
					selector.by = mouse.y;
					selector.lastX = mouse.x;
					selector.lastY = mouse.y;
					selector.dragging = true;
				}
				onPositionChanged: mouse => {
					if (!selector.dragging) return;
					if (selector.moving) {
						const ddx = selector.clamp(mouse.x - selector.lastX, -Math.min(selector.ax, selector.bx), root.width - Math.max(selector.ax, selector.bx));
						const ddy = selector.clamp(mouse.y - selector.lastY, -Math.min(selector.ay, selector.by), root.height - Math.max(selector.ay, selector.by));
						selector.ax += ddx;
						selector.bx += ddx;
						selector.ay += ddy;
						selector.by += ddy;
					} else if (mouse.modifiers & Qt.ShiftModifier) {
						const side = Math.max(Math.abs(mouse.x - selector.ax), Math.abs(mouse.y - selector.ay));
						selector.bx = selector.clamp(selector.ax + (mouse.x >= selector.ax ? side : -side), 0, root.width);
						selector.by = selector.clamp(selector.ay + (mouse.y >= selector.ay ? side : -side), 0, root.height);
					} else {
						selector.bx = selector.clamp(mouse.x, 0, root.width);
						selector.by = selector.clamp(mouse.y, 0, root.height);
					}
					selector.lastX = mouse.x;
					selector.lastY = mouse.y;
				}
				onReleased: mouse => {
					if (!selector.dragging) {
						if (mouse.button === Qt.LeftButton && (root.mode === "screen" || root.mode === "window")) selector.takeScreen(root.name);
						return;
					}
					if (root.mode === "picker" && selector.selW < 4 && selector.selH < 4) {
						selector.dragging = false;
						Screenshot.pickColor(reader.color, !!(mouse.modifiers & Qt.ShiftModifier));
						return;
					}
					selector.finish();
					selector.dragging = false;
					selector.pressSnap = null;
				}
				onWheel: wheel => {
					if (!selector.snapping || wheel.angleDelta.y === 0) {
						wheel.accepted = false;
						return;
					}
					selector.stepSnap(wheel.angleDelta.y > 0 ? 1 : -1);
				}
			}

			// mode switcher on the screen that has the keyboard
			Rectangle {
				id: modeBar

				readonly property bool present: root.selecting && root.owner && !selector.dragging

				anchors.horizontalCenter: parent.horizontalCenter
				y: modeBar.present ? Theme.barHeight + 14 : -height - 10
				width: barRow.implicitWidth + 12
				height: 48
				radius: 24
				color: Theme.base
				opacity: modeBar.present ? 1 : 0

				Behavior on y {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				RectangularShadow {
					anchors.fill: parent
					z: -1
					radius: parent.radius
					blur: 28
					offset.y: 6
					color: Theme.shadow
				}

				Row {
					id: barRow

					anchors.centerIn: parent
					spacing: 8

					Segmented {
						id: modes

						implicitWidth: 9 * 92
						height: 36
						current: root.mode
						options: [
							{ value: "region", label: "Region", icon: "selection_drag" },
							{ value: "screen", label: "Screen", icon: "monitor" },
							{ value: "window", label: "Window", icon: "window_maximize" },
							{ value: "pin", label: "Pin", icon: "pin" },
							{ value: "live", label: "Live", icon: "cast" },
							{ value: "picker", label: "Colour", icon: "eyedropper" },
							{ value: "ocr", label: "Text", icon: "text_recognition" },
							{ value: "qr", label: "QR", icon: "qrcode_scan" },
							{ value: "scroll", label: "Scroll", icon: "arrow_expand_vertical" }
						]
						onSelected: value => Screenshot.mode = value
					}

					// delayed capture: picking a delay drops this frame and
					// freezes again once the countdown is over
					Segmented {
						implicitWidth: 4 * 46
						height: 36
						current: String(Screenshot.delaySeconds)
						options: [
							{ value: "0", icon: "timer_off_outline" },
							{ value: "3", label: "3s" },
							{ value: "5", label: "5s" },
							{ value: "10", label: "10s" }
						]
						onSelected: value => {
							if (value === "0") Screenshot.delaySeconds = 0;
							else Screenshot.startDelayed(root.mode, Number(value));
						}
					}
				}
			}

			// picker mode: the last picked colours, a click copies one again
			Rectangle {
				id: historyBar

				readonly property bool present: modeBar.present && root.mode === "picker" && Screenshot.colorHistory.length > 0

				anchors.horizontalCenter: parent.horizontalCenter
				y: modeBar.y + modeBar.height + 10
				width: historyRow.implicitWidth + 16
				height: 40
				radius: 20
				color: Theme.base
				visible: opacity > 0
				opacity: historyBar.present ? 1 : 0
				scale: historyBar.present ? 1 : 0.94

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				RectangularShadow {
					anchors.fill: parent
					z: -1
					radius: parent.radius
					blur: 24
					offset.y: 4
					color: Theme.shadow
				}

				Row {
					id: historyRow

					anchors.centerIn: parent
					spacing: 6

					Repeater {
						model: Screenshot.colorHistory

						delegate: Rectangle {
							id: swatch

							required property string modelData

							width: 26
							height: 26
							radius: 13
							color: swatch.modelData
							border.width: swatchArea.containsMouse ? 2 : 1
							border.color: swatchArea.containsMouse ? Theme.text : Theme.outline
							scale: swatchArea.pressed ? 0.88 : (swatchArea.containsMouse ? 1.12 : 1)

							Behavior on scale {
								SpatialAnim {
									duration: Motion.short
								}
							}

							MouseArea {
								id: swatchArea

								anchors.fill: parent
								hoverEnabled: true
								acceptedButtons: Qt.LeftButton | Qt.RightButton
								cursorShape: Qt.PointingHandCursor
								onClicked: mouse => Screenshot.pickColor(swatch.modelData, mouse.button === Qt.RightButton || (mouse.modifiers & Qt.ShiftModifier))
							}
						}
					}
				}
			}
		}
	}

	// ── delayed capture: countdown pill (never part of the frame) ─────────
	Rectangle {
		id: countdownPill

		anchors.horizontalCenter: parent.horizontalCenter
		y: Theme.barHeight + 14
		width: countdownRow.implicitWidth + 28
		height: 44
		radius: 22
		color: Theme.base
		// gone at once before the freeze, no fade that could be captured
		visible: root.countingDown

		RectangularShadow {
			anchors.fill: parent
			z: -1
			radius: parent.radius
			blur: 24
			offset.y: 4
			color: Theme.shadow
		}

		Row {
			id: countdownRow

			anchors.centerIn: parent
			spacing: 10

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: "timer_outline"
				size: 18
				color: Theme.primary
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				tabular: true
				text: String(Screenshot.countdown)
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: "close"
				size: 16
				color: countdownArea.containsMouse ? Theme.text : Theme.textMuted
			}
		}

		MouseArea {
			id: countdownArea

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: Screenshot.cancel()
		}
	}

	// ── scroll capture: a frame just outside the region + the stop control ─
	FocusScope {
		id: scrollKeys

		anchors.fill: parent
		visible: root.scrolling
		focus: root.scrolling

		readonly property rect area: Screenshot.scrollRect

		Keys.onPressed: event => {
			if (event.key === Qt.Key_Escape) Screenshot.cancel();
			else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) Screenshot.stopScroll();
			else return;
			event.accepted = true;
		}

		// outside the region, so grim never sees it
		Rectangle {
			x: scrollKeys.area.x - 3
			y: scrollKeys.area.y - 3
			width: scrollKeys.area.width + 6
			height: scrollKeys.area.height + 6
			color: "transparent"
			border.width: 2
			border.color: Theme.primary
			radius: 3
		}

		Rectangle {
			id: scrollControl

			readonly property real gap: 12
			readonly property real w: scrollControlRow.implicitWidth + 12
			readonly property real h: 44
			readonly property real cx: Math.max(8, Math.min(root.width - w - 8, scrollKeys.area.x + scrollKeys.area.width / 2 - w / 2))
			readonly property real cy: Math.max(8, Math.min(root.height - h - 8, scrollKeys.area.y + scrollKeys.area.height / 2 - h / 2))
			// below, above, right or left of the region; none fits → keys only
			readonly property var spot: {
				const a = scrollKeys.area;
				if (a.y + a.height + gap + h + 8 <= root.height) return [cx, a.y + a.height + gap];
				if (a.y - gap - h >= 8) return [cx, a.y - gap - h];
				if (a.x + a.width + gap + w + 8 <= root.width) return [a.x + a.width + gap, cy];
				if (a.x - gap - w >= 8) return [a.x - gap - w, cy];
				return null;
			}

			visible: scrollControl.spot !== null
			x: scrollControl.spot ? scrollControl.spot[0] : 0
			y: scrollControl.spot ? scrollControl.spot[1] : 0
			width: scrollControl.spot ? scrollControl.w : 0
			height: scrollControl.spot ? scrollControl.h : 0
			radius: 22
			color: Theme.base

			RectangularShadow {
				anchors.fill: parent
				z: -1
				radius: parent.radius
				blur: 24
				offset.y: 4
				color: Theme.shadow
			}

			Row {
				id: scrollControlRow

				anchors.centerIn: parent
				spacing: 6

				Item {
					anchors.verticalCenter: parent.verticalCenter
					width: 30
					height: 30

					Rectangle {
						anchors.centerIn: parent
						width: 10
						height: 10
						radius: 5
						color: Theme.danger
						opacity: Screenshot.scrollStopping ? 0.3 : 1

						SequentialAnimation on opacity {
							running: root.scrolling && !Screenshot.scrollStopping
							loops: Animation.Infinite

							Anim {
								to: 0.3
								duration: Motion.extraLong
							}
							Anim {
								to: 1
								duration: Motion.extraLong
							}
						}
					}
				}

				TextButton {
					anchors.verticalCenter: parent.verticalCenter
					variant: "filled"
					icon: "stop"
					text: "Stop"
					busy: Screenshot.scrollStopping
					onActivated: Screenshot.stopScroll()
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					icon: "close"
					onClicked: Screenshot.cancel()
				}
			}
		}
	}

	// ── editor ─────────────────────────────────────────────────────────────
	Loader {
		id: editorLoader

		anchors.fill: parent
		active: root.editorLive
		opacity: root.reveal * (1 - root.beautyMix)
		enabled: !root.beautifying
		focus: root.editing

		sourceComponent: Component {
			Editor {
				source: Screenshot.editSource
				initialCrop: Screenshot.editCrop
				fromFrozen: Screenshot.editFromFrozen
				density: root.density
				focus: true
			}
		}

		onLoaded: Qt.callLater(() => item.forceActiveFocus())
	}

	// ── beautifier ─────────────────────────────────────────────────────────
	Loader {
		id: beautyLoader

		anchors.fill: parent
		active: root.beautyLive
		opacity: root.reveal * root.beautyMix
		enabled: root.beautifying
		focus: root.beautifying

		sourceComponent: Component {
			Beautify {
				source: Screenshot.beautySource
				output: root.name
				density: root.density
				fromEditor: Screenshot.beautyFromEditor
				plain: root.frozenPath === ""
				focus: true
			}
		}

		onLoaded: Qt.callLater(() => item.forceActiveFocus())
	}
}
