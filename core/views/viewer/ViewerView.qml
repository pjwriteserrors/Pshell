pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.files
import qs.core.views.screenshot
import "Recipe.js" as Recipe
import "Geometry.js" as Geo

// The pictures' window: the picture as large as it goes, the bars above
// and below fading away while it is looked at, and four ways of being
// there – looking, adjusting light and colour, cropping and straightening,
// drawing on it (the screenshot editor). See core/services/Viewer.qml.
FocusScope {
	id: root

	property bool shown: false
	readonly property bool editing: Viewer.mode !== "view" && Viewer.mode !== "compare"
	readonly property bool sidePanel: Viewer.mode === "adjust" || (Viewer.infoShown && Viewer.mode === "view")
	// the bars: always while editing, otherwise while the pointer moves (never in a slideshow)
	property bool chromeWanted: true
	readonly property bool chrome: root.chromeWanted && !Viewer.sliding
	property bool comparing: false
	// before | after side by side; grows in from the left when switched on
	property real split: 0

	function toggleSplit() {
		splitAnim.stop();
		splitAnim.to = root.split > 0.001 ? 0 : 0.5;
		splitAnim.start();
	}

	NumberAnimation {
		id: splitAnim

		target: root
		property: "split"
		duration: Motion.long
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.spatial
	}

	Connections {
		target: Viewer

		function onModeChanged() {
			// comparing belongs to adjusting
			if (Viewer.mode !== "adjust" && root.split > 0) {
				splitAnim.stop();
				root.split = 0;
			}
		}
	}
	property bool clipWarning: false
	property var histogram: null

	function takeFocus() {
		root.forceActiveFocus();
		root.wake();
	}

	function wake() {
		root.chromeWanted = true;
		hideChrome.restart();
	}

	Timer {
		id: hideChrome

		interval: 2400
		onTriggered: if (!root.editing && !topMouse.containsMouse && !stripMouse.containsMouse && !menu.open) root.chromeWanted = false
	}

	Component.onCompleted: Viewer.renderer = root
	Component.onDestruction: if (Viewer.renderer === root) Viewer.renderer = null

	readonly property bool ready: stage.ready

	// what saving asks for: the result at full size into a file
	function render(path, done) {
		stage.render(path, done);
	}

	// ── what is around the picture ─────────────────────────────────────────
	Rectangle {
		anchors.fill: parent
		color: Theme.base
	}

	// the picture's own colours, blurred far behind it
	Item {
		id: ambient

		anchors.fill: parent
		visible: Viewer.setting("ambient", true)
		opacity: Viewer.mode === "markup" ? 0 : 0.5

		Behavior on opacity {
			Anim {}
		}

		Image {
			id: ambientImage

			anchors.fill: parent
			source: Viewer.shownPath && !Viewer.info?.animated ? "file://" + Viewer.shownPath : ""
			sourceSize: Qt.size(48, 48)
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			autoTransform: true
			visible: false
		}

		MultiEffect {
			anchors.fill: parent
			source: ambientImage
			blurEnabled: true
			blur: 1
			blurMax: 64
			saturation: 0.2
			opacity: ambientImage.status === Image.Ready ? 1 : 0

			Behavior on opacity {
				NumberAnimation {
					duration: Motion.extraLong
				}
			}
		}

		Rectangle {
			anchors.fill: parent
			color: Theme.base
			opacity: 0.55
		}
	}

	// ── the picture ────────────────────────────────────────────────────────
	Item {
		id: area

		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.right: side.left

		Stage {
			id: stage

			anchors.fill: parent
			anchors.topMargin: root.editing ? top.height + 8 : 0
			anchors.bottomMargin: Viewer.mode === "crop" ? crop.barHeight : (Viewer.mode === "retouch" ? retouch.barHeight : (root.editing ? 16 : 0))
			margin: root.editing ? 36 : 24
			cropless: Viewer.mode === "crop"
			original: root.comparing
			split: root.split
			onSplitDragged: value => {
				splitAnim.stop();
				root.split = value;
			}
			clipWarning: root.clipWarning && Viewer.mode === "adjust"
			visible: Viewer.mode !== "markup" && Viewer.mode !== "compare"
			onPointerMoved: root.wake()
			onDragOut: root.startDragOut()

			Behavior on anchors.topMargin {
				SpatialAnim {}
			}
			Behavior on anchors.bottomMargin {
				SpatialAnim {}
			}
		}

		RetouchTools {
			id: retouch

			anchors.fill: parent
			stage: stage
			visible: Viewer.mode === "retouch" && stage.ready
		}

		Loader {
			anchors.fill: parent
			anchors.topMargin: top.height
			active: Viewer.mode === "compare"
			sourceComponent: CompareView {}
		}

		CropTools {
			id: crop

			anchors.fill: parent
			stage: stage
			visible: Viewer.mode === "crop" && stage.ready
		}

		// nothing to show
		Column {
			anchors.centerIn: parent
			spacing: 10
			visible: Viewer.error !== "" || (!stage.ready && Viewer.decoding)

			Glyph {
				anchors.horizontalCenter: parent.horizontalCenter
				icon: Viewer.error ? "image_broken_variant" : "image_refresh_outline"
				size: 44
				color: Theme.textSubtle
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				text: Viewer.error || "Opening the picture…"
				tone: Theme.textMuted
			}
		}

		Spinner {
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 18
			width: 22
			height: 22
			running: Viewer.busy || (Viewer.mode !== "view" && stage.ready && !stage.sharp)
			visible: running
		}

		// stepping with the pointer: large arrows at the sides
		Repeater {
			model: [-1, 1]

			delegate: IconButton {
				required property int modelData

				anchors.verticalCenter: parent.verticalCenter
				x: modelData < 0 ? 16 : area.width - width - 16
				width: 48
				height: 48
				icon: modelData < 0 ? "chevron_left" : "chevron_right"
				iconSize: 28
				variant: "tonal"
				visible: Viewer.mode === "view" && Viewer.files.length > 1
				opacity: root.chrome ? 0.9 : 0
				onClicked: Viewer.step(modelData)

				Behavior on opacity {
					Anim {}
				}
			}
		}

		// how far it is zoomed
		Rectangle {
			anchors.left: parent.left
			anchors.bottom: parent.bottom
			anchors.margins: 16
			anchors.bottomMargin: Viewer.mode === "view" && Viewer.setting("filmstrip", true) && Viewer.files.length > 1 ? strip.height + 24 : 16
			width: zoomText.implicitWidth + 20
			height: 28
			radius: 14
			color: Theme.glass
			visible: Viewer.mode !== "markup" && Viewer.mode !== "crop"
			opacity: zoomFade.running || !stage.fitted || root.chrome ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			// a click: 100 %, again: the whole picture
			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onClicked: Math.abs(stage.zoom - 1) < 1e-3 ? stage.fit() : stage.zoomTo(1)
			}

			StyledText {
				id: zoomText

				anchors.centerIn: parent
				text: `${Math.round(stage.zoom * 100)} %`
				tabular: true
				font.pixelSize: Theme.size.small
			}

			Timer {
				id: zoomFade

				interval: 1200
			}

			Connections {
				target: stage

				function onZoomChanged() {
					zoomFade.restart();
				}
			}
		}
	}

	// pictures dropped on the window open here; the picture dragged out of it
	// goes as a file (the result, when it is changed)
	DropArea {
		anchors.fill: parent
		keys: ["text/uri-list"]
		onDropped: drop => {
			const paths = drop.urls.map(u => decodeURIComponent(String(u).replace(/^file:\/\//, ""))).filter(p => p.startsWith("/"));
			if (paths.length === 0) return;
			Viewer.open(paths[0], paths.length > 1 ? { list: paths } : {});
			drop.accept(Qt.CopyAction);
		}
	}

	Item {
		id: dragOut

		property string file: ""

		Drag.dragType: Drag.Automatic
		Drag.supportedActions: Qt.CopyAction
		Drag.mimeData: ({ "text/uri-list": "file://" + encodeURI(dragOut.file) + "\r\n", "text/plain": dragOut.file })
	}

	function startDragOut() {
		Viewer.renderTemp("", path => {
			dragOut.file = path;
			dragOut.Drag.active = true;
		});
	}

	// ── sorting out ────────────────────────────────────────────────────────
	Rectangle {
		anchors.horizontalCenter: area.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: (bottom.visible ? bottom.height : 0) + 70
		width: cullRow.implicitWidth + 28
		height: 46
		radius: 23
		color: Theme.glass
		border.width: 1
		border.color: Theme.outline
		visible: Viewer.culling && Viewer.mode === "view"
		z: 40

		readonly property var mine: Viewer.ratingOf(Viewer.path)

		Row {
			id: cullRow

			anchors.centerIn: parent
			spacing: 10

			TextButton {
				text: "Keep"
				icon: "thumb_up_outline"
				variant: parent.parent.mine.flag === "keep" ? "filled" : "tonal"
				onActivated: Viewer.setFlag("keep")
			}

			TextButton {
				text: "Reject"
				icon: "thumb_down_outline"
				variant: parent.parent.mine.flag === "reject" ? "danger" : "tonal"
				onActivated: Viewer.setFlag("reject")
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: `${Viewer.allFiles.filter(f => Viewer.ratingOf(f.path).flag === "keep").length} kept · ${Viewer.rejected.length} rejected · ${Viewer.allFiles.filter(f => !Viewer.ratingOf(f.path).flag).length} to go`
				tabular: true
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}

			TextButton {
				visible: Viewer.rejected.length > 0
				text: `Trash ${Viewer.rejected.length}`
				icon: "trash_can_outline"
				variant: "danger"
				confirm: true
				onActivated: Viewer.trashRejected()
			}

			IconButton {
				width: 32
				height: 32
				icon: "close"
				onClicked: Viewer.culling = false
			}
		}
	}

	// the stars and the flag of the picture, quietly in a corner
	Row {
		anchors.right: side.left
		anchors.bottom: parent.bottom
		anchors.margins: 16
		anchors.bottomMargin: (bottom.visible ? bottom.height : 0) + 16
		spacing: 2
		readonly property var mine: Viewer.ratingOf(Viewer.path)
		visible: Viewer.mode === "view" && !Viewer.sliding && (mine.stars > 0 || !!mine.flag || Viewer.marked.includes(Viewer.path) || root.chrome)
		opacity: root.chrome || mine.stars > 0 || !!mine.flag ? 1 : 0

		Repeater {
			model: 5

			delegate: Glyph {
				required property int index

				icon: index < parent.mine.stars ? "star" : "star_outline"
				size: 18
				color: index < parent.mine.stars ? Theme.warning : Theme.textFaint

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: Viewer.setStars(parent.index + 1)
				}
			}
		}

		Glyph {
			visible: !!parent.mine.flag
			icon: parent.mine.flag === "keep" ? "thumb_up" : "thumb_down"
			size: 18
			color: parent.mine.flag === "keep" ? Theme.success : Theme.danger
		}

		Glyph {
			visible: Viewer.marked.includes(Viewer.path)
			icon: "checkbox_marked"
			size: 18
			color: Theme.primary
		}
	}

	// ── before / after ─────────────────────────────────────────────────────
	Rectangle {
		anchors.horizontalCenter: area.horizontalCenter
		anchors.top: parent.top
		anchors.topMargin: top.height + 14
		width: compareText.implicitWidth + 24
		height: 30
		radius: 15
		color: Theme.glass
		opacity: root.comparing ? 1 : 0
		visible: opacity > 0

		Behavior on opacity {
			Anim {}
		}

		StyledText {
			id: compareText

			anchors.centerIn: parent
			text: "Before"
			font.pixelSize: Theme.size.label
		}
	}

	// ── drawing on it: the screenshot editor ───────────────────────────────
	property string markupSource: ""

	function startMarkup() {
		const r = Viewer.recipe;
		const colourAndShape = Recipe.copy(r);
		colourAndShape.markup = { items: [] };
		if (Recipe.isPlain(colourAndShape)) {
			root.markupSource = Viewer.shownPath;
			return;
		}
		// the editor draws on the result, so the result goes first
		root.markupSource = "";
		stage.markingsShown = false;
		const out = `${Viewer.workDir}/draw-${Date.now()}.tiff`;
		stage.render(out, ok => {
			stage.markingsShown = true;
			if (!ok) {
				Viewer.fail("The picture could not be rendered");
				Viewer.setMode("view");
				return;
			}
			root.markupSource = out;
		});
	}

	Connections {
		target: Viewer

		function onModeChanged() {
			if (Viewer.mode === "markup") root.startMarkup();
			else if (root.markupSource) {
				if (root.markupSource.startsWith(Viewer.workDir)) Quickshell.execDetached(["rm", "-f", root.markupSource]);
				root.markupSource = "";
			}
			root.wake();
			root.takeFocus();
		}

		function onActed(action) {
			const [verb, arg] = action.split(":");
			switch (verb) {
			case "auto":
				Viewer.setMode("adjust");
				Qt.callLater(() => adjustLoader.item?.auto());
				break;
			case "look":
				Viewer.commit(Recipe.withLook(Viewer.recipe, arg || ""));
				break;
			case "horizon":
				crop.findHorizon();
				break;
			case "page":
				crop.findDocument();
				break;
			case "aspect": {
				const option = crop.aspects().find(o => o.id === action.slice(7));
				if (option) crop.setAspect(option);
				break;
			}
			case "turn":
				crop.turn(arg === "left" ? -1 : 1);
				break;
			case "mirror":
				crop.mirror();
				break;
			case "cutout":
				root.cutout();
				break;
			case "export":
				exportDialog.show();
				break;
			case "copy":
				Viewer.copyResult();
				break;
			case "wallpaper":
				root.setWallpaper();
				break;
			case "fit":
				stage.fit();
				break;
			case "actual":
				stage.actualSize();
				break;
			case "compare":
				root.comparing = arg !== "off";
				break;
			case "split":
				root.toggleSplit();
				break;
			case "mark":
				Viewer.toggleMark();
				break;
			case "faces":
				root.blurFaces();
				break;
			case "similar":
				root.similar();
				break;
			case "describe":
				root.describe(arg || "");
				break;
			case "print":
				printDialog.show();
				break;
			case "slideshow":
				Viewer.slideshow(arg !== "off");
				break;
			case "edits": {
				const p = badge.mapToItem(root, 0, badge.height + 4);
				menu.show(root.editEntries(), p.x, p.y);
				break;
			}
			case "more":
				menu.show(root.moreEntries(), root.width - 300, 60);
				break;
			case "revert": {
				const edit = Recipe.edits(Viewer.recipe).find(e => e.id === arg);
				if (edit) root.revertEdit(edit);
				break;
			}
			}
		}

		function onSaid(text, icon) {
			toast.show(text, icon);
		}

		function onOffered(label, run) {
			toast.show(toastText.text, toastGlyph.icon, label, run);
		}

		function onPathChanged() {
			root.histogram = null;
			root.description = "";
		}
	}

	QtObject {
		id: markupHost

		property var items: Viewer.recipe.markup?.items ?? []

		function keep(items) {
			const next = Recipe.copy(Viewer.recipe);
			next.markup = { items: items };
			Viewer.commit(next);
		}

		function done(items) {
			markupHost.keep(items);
			Viewer.setMode("view");
		}

		function save(items) {
			markupHost.keep(items);
			Viewer.setMode("view");
			Qt.callLater(() => Viewer.saveCopy());
		}
	}

	Loader {
		id: markup

		anchors.fill: parent
		anchors.topMargin: top.height
		active: Viewer.mode === "markup" && root.markupSource !== ""
		focus: active
		sourceComponent: Editor {
			source: root.markupSource
			initialCrop: Qt.rect(0, 0, 0, 0)
			fromFrozen: false
			density: 1
			host: markupHost
			focus: true
		}
		onLoaded: Qt.callLater(() => item.forceActiveFocus())
	}

	// ── the side: facts, or light and colour ───────────────────────────────
	Item {
		id: side

		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.right: parent.right
		anchors.topMargin: top.height
		width: root.sidePanel ? 340 : 0
		clip: true

		Behavior on width {
			SpatialAnim {}
		}

		Rectangle {
			anchors.fill: parent
			color: Theme.layer1
			opacity: 0.92
		}

		Rectangle {
			width: 1
			height: parent.height
			color: Theme.outline
		}

		InfoPanel {
			x: 0
			width: 340
			height: parent.height
			histogram: root.histogram
			description: root.description
			describing: root.describing
			onDescribeAsked: root.describe("")
			opacity: Viewer.mode === "view" ? 1 : 0
			visible: opacity > 0

			Behavior on opacity {
				Anim {}
			}
		}

		Loader {
			id: adjustLoader

			x: 0
			width: 340
			height: parent.height
			active: Viewer.mode === "adjust" || item !== null
			opacity: Viewer.mode === "adjust" ? 1 : 0
			visible: opacity > 0
			sourceComponent: AdjustPanel {
				histogram: root.histogram
				splitShown: root.split > 0
				onSplitToggled: root.toggleSplit()
				onClipWarningChanged: root.clipWarning = clipWarning
			}

			Behavior on opacity {
				Anim {}
			}
		}
	}

	// the tones of the result, measured shortly after it changes
	Timer {
		id: histogramTimer

		interval: 220
		onTriggered: {
			const f = stage.frontSlot;
			if (!f || !f.develop.ready || !root.sidePanel) return;
			const w = f.content.width, h = f.content.height;
			const k = Math.min(1, 320 / Math.max(w, h));
			const path = `${Viewer.workDir}/histogram.png`;
			const asked = Viewer.path;
			f.content.grabToImage(result => {
				if (!result.saveToFile(path)) return;
				Viewer.request("histogram", { path: path, bins: 64 }, data => {
					if (data && Viewer.path === asked) root.histogram = data;
				});
			}, Qt.size(Math.max(1, Math.round(w * k)), Math.max(1, Math.round(h * k))));
		}
	}

	Connections {
		target: Viewer

		function onRecipeChanged() {
			histogramTimer.restart();
		}
	}

	onSidePanelChanged: histogramTimer.restart()

	Connections {
		target: stage

		function onReadyChanged() {
			histogramTimer.restart();
		}
	}

	// ── the bar above ──────────────────────────────────────────────────────
	Item {
		id: top

		anchors.left: parent.left
		anchors.right: parent.right
		height: 60
		opacity: (root.chrome || root.editing) && !Viewer.sliding ? 1 : 0
		visible: opacity > 0

		Behavior on opacity {
			Anim {}
		}

		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.alpha(Theme.base, root.editing ? 0.96 : 0.82)
				}
				GradientStop {
					position: 1
					color: Qt.alpha(Theme.base, root.editing ? 0.96 : 0)
				}
			}
		}

		MouseArea {
			id: topMouse

			anchors.fill: parent
			hoverEnabled: true
			acceptedButtons: Qt.NoButton
		}

		Row {
			anchors.left: parent.left
			anchors.leftMargin: 18
			anchors.verticalCenter: parent.verticalCenter
			spacing: 12
			width: Math.max(0, modes.x - 36)

			Column {
				width: parent.width - badge.width - 12
				anchors.verticalCenter: parent.verticalCenter
				spacing: 1

				StyledText {
					width: parent.width
					text: Viewer.current?.name ?? ""
					elide: Text.ElideMiddle
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					text: Viewer.files.length > 1 ? `${Viewer.index + 1} of ${Viewer.files.length}` : (Viewer.pasted ? "From the clipboard" : "")
					visible: text !== ""
					tabular: true
					font.pixelSize: Theme.size.small
					tone: Theme.textSubtle
				}
			}

			Chip {
				id: badge

				anchors.verticalCenter: parent.verticalCenter
				visible: Viewer.edited
				text: Viewer.saved ? "Copy saved" : "Edited"
				icon: Viewer.saved ? "check" : "pencil_outline"
				selected: !Viewer.saved
				onClicked: {
					const p = badge.mapToItem(root, 0, badge.height + 4);
					menu.show(root.editEntries(), p.x, p.y);
				}
			}
		}

		Segmented {
			id: modes

			anchors.centerIn: parent
			width: 420
			height: 38
			visible: !Viewer.info?.animated
			options: [{ value: "view", label: "Look", icon: "eye_outline" }, { value: "adjust", label: "Adjust", icon: "tune_variant" }, { value: "crop", label: "Crop", icon: "crop_rotate" }, { value: "markup", label: "Draw", icon: "draw" }]
			current: Viewer.mode
			onSelected: value => Viewer.setMode(value)
		}

		Row {
			anchors.right: parent.right
			anchors.rightMargin: 14
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4

			IconButton {
				width: 36
				height: 36
				icon: "undo"
				visible: Viewer.past.length > 0 || Viewer.future.length > 0
				enabled: Viewer.past.length > 0
				opacity: enabled ? 1 : 0.4
				onClicked: Viewer.undo()
			}

			IconButton {
				width: 36
				height: 36
				icon: "redo"
				visible: Viewer.past.length > 0 || Viewer.future.length > 0
				enabled: Viewer.future.length > 0
				opacity: enabled ? 1 : 0.4
				onClicked: Viewer.redo()
			}

			IconButton {
				width: 36
				height: 36
				icon: "information_outline"
				checked: Viewer.infoShown
				visible: Viewer.mode === "view"
				onClicked: Viewer.toggleInfo()
			}

			IconButton {
				id: shareButton

				width: 36
				height: 36
				icon: "share_variant_outline"
				onClicked: {
					const p = shareButton.mapToItem(root, 0, shareButton.height + 4);
					menu.show(root.shareEntries(), p.x - 160, p.y);
				}
			}

			TextButton {
				anchors.verticalCenter: parent.verticalCenter
				text: Viewer.saved ? "Saved" : "Save copy"
				icon: Viewer.saved ? "check" : "content_save_outline"
				variant: Viewer.edited && !Viewer.saved ? "filled" : "tonal"
				busy: Viewer.busy
				visible: Viewer.edited || Viewer.pasted
				onActivated: Viewer.saveCopy()
			}

			IconButton {
				id: moreButton

				width: 36
				height: 36
				icon: "dots_vertical"
				onClicked: {
					const p = moreButton.mapToItem(root, 0, moreButton.height + 4);
					menu.show(root.moreEntries(), p.x - 220, p.y);
				}
			}

			IconButton {
				width: 36
				height: 36
				icon: "close"
				onClicked: Viewer.close()
			}
		}
	}

	// ── the strip below ────────────────────────────────────────────────────
	Item {
		id: bottom

		anchors.left: parent.left
		anchors.right: side.left
		anchors.bottom: parent.bottom
		height: strip.height + 20
		visible: Viewer.mode === "view" && Viewer.setting("filmstrip", true) && Viewer.files.length > 1
		opacity: root.chrome ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.alpha(Theme.base, 0)
				}
				GradientStop {
					position: 1
					color: Qt.alpha(Theme.base, 0.82)
				}
			}
		}

		Filmstrip {
			id: strip

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.bottomMargin: 10
		}

		MouseArea {
			id: stripMouse

			anchors.fill: parent
			hoverEnabled: true
			acceptedButtons: Qt.NoButton
			onPositionChanged: root.wake()
		}
	}

	// ── menus ──────────────────────────────────────────────────────────────
	// every change on its own, each taken back alone (one step: undo brings it back)
	function revertEdit(edit) {
		const next = edit.revert();
		if (edit.geometry) next.markup.items = Geo.remapItems(Viewer.recipe.markup?.items ?? [], Viewer.recipe.geometry, next.geometry, Viewer.info?.width ?? 1, Viewer.info?.height ?? 1);
		Viewer.commit(next);
		Viewer.say(`${edit.label} – taken back`, "backup_restore");
	}

	function editEntries() {
		const edits = Recipe.edits(Viewer.recipe);
		const out = [{ header: edits.length === 1 ? "One change" : `${edits.length} changes – a click takes one back` }];
		for (const edit of edits) out.push({ label: edit.label, icon: edit.icon, hint: "Take back", run: () => root.revertEdit(edit) });
		out.push({ separator: true });
		out.push({ label: "Back to the original", icon: "backup_restore", danger: true, run: () => Viewer.revert() });
		if (Viewer.saved) out.push({ label: "Show the copy", icon: "folder_open_outline", run: () => Files.reveal([Viewer.sidecar.copy]) });
		else out.push({ label: "Save copy", icon: "content_save_outline", shortcut: "Ctrl+S", run: () => Viewer.saveCopy() });
		return out;
	}

	function shareEntries() {
		const plain = Recipe.isPlain(Viewer.recipe) && !Viewer.pasted && !Viewer.info?.proxy;
		return ShareTargets.entries([Viewer.path], plain ? null : done => Viewer.renderTemp("", done));
	}

	function moreEntries() {
		const path = Viewer.path;
		const one = [path];
		const file = !Viewer.pasted;
		const out = [];
		out.push({ header: "Save" });
		out.push({ label: "Save a copy…", icon: "content_save_cog_outline", shortcut: "Ctrl+Shift+S", run: () => exportDialog.show() });
		out.push({ label: "Copy the picture", icon: "content_copy", shortcut: "Ctrl+C", run: () => Viewer.copyResult() });
		out.push({ label: "Print…", icon: "printer_outline", shortcut: "Ctrl+P", run: () => printDialog.show() });
		if (Viewer.edited) out.push({ label: "Back to the original", icon: "backup_restore", run: () => Viewer.revert() });
		if (Viewer.madeFrom) out.push({ label: "Change it again from the original", icon: "history", run: () => Viewer.editOriginal() });

		out.push({ header: "Change" });
		out.push({ label: "Remove things from it…", icon: "auto_fix", run: () => Viewer.setMode("retouch") });
		out.push({ label: "Cut out what is in front", icon: "account_box_outline", run: () => root.cutout() });
		if (Viewer.recipe.cutout) out.push({ label: "Put the background back", icon: "image_outline", run: () => {
			const next = Recipe.copy(Viewer.recipe);
			next.cutout = "";
			Viewer.commit(next);
		} });
		out.push({ label: "Blur faces and number plates", icon: "face_recognition", run: () => root.blurFaces() });
		out.push({ label: "Copy the changes", icon: "content_copy", shortcut: "Ctrl+Shift+C", enabled: !Recipe.colourIsPlain(Viewer.recipe) || !!Viewer.recipe.geometry?.pad, run: () => Viewer.copyEdits() });
		out.push({ label: "Lay the copied changes on it", icon: "content_paste", shortcut: "Ctrl+Shift+V", enabled: !!Viewer.copiedRecipe, run: () => Viewer.pasteEdits() });

		out.push({ header: "Text and meaning" });
		if (Plugins.on("ocr")) out.push({ label: "Copy the text", icon: "text_recognition", run: () => Viewer.renderTemp("", p => Screenshot.runOcr(p, null, false)) });
		if (Plugins.on("qr")) out.push({ label: "Read a QR code", icon: "qrcode_scan", run: () => Viewer.renderTemp("", p => Screenshot.runQr(p, null)) });
		out.push({ label: "Describe it", icon: "creation", run: () => root.describe("") });
		if (Plugins.on("chat")) out.push({ label: "Ask AI about it…", icon: "chat_question_outline", run: () => root.askAi() });
		if (file) {
			out.push({ label: "Text as a .txt beside it", icon: "text_box_outline", run: () => Files.startJob("capturetext", { paths: one }) });
			out.push({ label: "Name it by what it shows", icon: "form_textbox", run: () => Files.startJob("ainame", { paths: one }, job => {
				if (job.state === "failed") Viewer.fail(job.error);
				else if (job.state === "done") Viewer.listFolder(Viewer.folder + "/");
			}) });
			out.push({ label: "Similar pictures here", icon: "image_search_outline", run: () => root.similar() });
		}

		out.push({ header: "Many pictures" });
		out.push({ label: Viewer.marked.includes(path) ? "Unmark it" : "Mark it", icon: "checkbox_marked_outline", shortcut: "M", run: () => Viewer.toggleMark() });
		if (Viewer.marked.length > 1) {
			out.push({ label: `Compare the ${Viewer.marked.length} marked`, icon: "view_grid_outline", run: () => Viewer.setMode("compare") });
			out.push({ label: `A collage of the ${Viewer.marked.length} marked`, icon: "view_quilt_outline", run: () => Viewer.collage() });
			out.push({ label: `The copied changes on the ${Viewer.marked.length} marked`, icon: "content_paste", enabled: !!Viewer.copiedRecipe, run: () => Viewer.batch() });
		}
		if (Viewer.marked.length > 0) out.push({ label: "Unmark all", icon: "checkbox_blank_off_outline", run: () => Viewer.marked = [] });
		out.push({ label: "Slideshow", icon: "play_box_outline", shortcut: "F5", run: () => Viewer.slideshow(true) });
		out.push({ label: Viewer.culling ? "Stop sorting out" : "Sort out (↑ keep, ↓ reject)", icon: "thumbs_up_down_outline", checked: Viewer.culling, run: () => Viewer.culling = !Viewer.culling });
		out.push({ label: "Show only", icon: "filter_outline", children: [
			{ label: "All", checked: Viewer.filter === "", run: () => Viewer.setFilter("") },
			{ label: "★ and more", checked: Viewer.filter === "stars:1", run: () => Viewer.setFilter("stars:1") },
			{ label: "★★★ and more", checked: Viewer.filter === "stars:3", run: () => Viewer.setFilter("stars:3") },
			{ label: "★★★★★", checked: Viewer.filter === "stars:5", run: () => Viewer.setFilter("stars:5") },
			{ label: "Kept", checked: Viewer.filter === "kept", run: () => Viewer.setFilter("kept") },
			{ label: "Not sorted yet", checked: Viewer.filter === "unsorted", run: () => Viewer.setFilter("unsorted") }
		] });

		out.push({ header: "Use" });
		if (Plugins.on("pins")) out.push({ label: "Pin to the screen", icon: "pin_outline", run: () => Viewer.renderTemp("", p => Screenshot.pinShot(p)) });
		if (Plugins.on("studio-wallpaper")) out.push({ label: "Set as wallpaper", icon: "wallpaper", hint: "Crop it to a screen first for a perfect fit", run: () => root.setWallpaper() });
		if (Plugins.on("shelves")) out.push({ label: "Put it on the shelf", icon: "tray_arrow_down", run: () => Viewer.renderTemp("", p => Shelf.keep([{ kind: "file", path: p, name: p.slice(p.lastIndexOf("/") + 1), mime: Shelf.guessMime(p) }])) });
		out.push({ label: "Make a PDF of it", icon: "file_pdf_box", enabled: file, run: () => Files.pdfTool("fromimages", one, {}) });
		if (file) {
			out.push({ label: FileLibrary.isFavorite(path) ? "No longer a favourite" : "A favourite", icon: FileLibrary.isFavorite(path) ? "heart" : "heart_outline", shortcut: "Ctrl+F", run: () => root.toggleFavourite() });
			out.push({ label: "Tags", icon: "tag_outline", children: () => FileLibrary.tags.map(tag => ({ label: tag.name, checked: FileLibrary.hasTag(path, tag.id), run: () => FileLibrary.toggleTag(one, tag.id) })).concat(FileLibrary.tags.length > 0 ? [] : [{ label: "No tags yet – make them in Files", enabled: false }]) });
			out.push({ label: "Remove location and camera data", icon: "map_marker_off_outline", run: () => Files.imageTool("strip", one, {}) });
			out.push({ header: "File" });
			out.push({ label: "Show in Files", icon: "folder_open_outline", shortcut: "Ctrl+O", run: () => Files.reveal(one) });
			out.push({ label: "Open with", icon: "open_in_app", children: done => Files.request("apps", { path: path }, data => {
				const apps = data?.apps ?? [];
				done(apps.length > 0 ? apps.map(app => ({ label: app.name, image: AppIcons.resolveIconSource(app.icon), run: () => Files.launch(one, app.id) })) : [{ label: "No app opens this", enabled: false }]);
			}) });
			out.push({ label: "Sort by", icon: "sort", children: [["name", "Name"], ["date", "Date"], ["size", "Size"]].map(([key, label]) => ({
				label: label, checked: Viewer.setting("sort", "name") === key, run: () => Viewer.resort(key, Viewer.setting("reverse", false))
			})).concat([{ separator: true }, { label: "Reversed", checked: Viewer.setting("reverse", false), run: () => Viewer.resort(Viewer.setting("sort", "name"), !Viewer.setting("reverse", false)) }]) });
			out.push({ label: "Move to the trash", icon: "trash_can_outline", danger: true, shortcut: "Delete", run: () => root.trash() });
		}
		out.push({ header: "Window" });
		out.push({ label: "Pictures in a row below", icon: "filmstrip", checked: Viewer.setting("filmstrip", true), run: () => Viewer.setSetting("filmstrip", !Viewer.setting("filmstrip", true)) });
		out.push({ label: "The picture's colours behind it", icon: "blur", checked: Viewer.setting("ambient", true), run: () => Viewer.setSetting("ambient", !Viewer.setting("ambient", true)) });
		out.push({ label: "Slideshow", icon: "timer_outline", children: [3, 5, 8, 15].map(sec => ({ label: `${sec} seconds a picture`, checked: Viewer.setting("slideSeconds", 5) === sec, run: () => Viewer.setSetting("slideSeconds", sec) })).concat([{ separator: true }, { label: "Shuffled", checked: Viewer.setting("slideShuffle", false), run: () => Viewer.setSetting("slideShuffle", !Viewer.setting("slideShuffle", false)) }]) });
		return out;
	}

	function toggleFavourite() {
		if (Viewer.pasted || !Viewer.path) return;
		FileLibrary.toggleFavorite(Viewer.path);
		Viewer.say(FileLibrary.isFavorite(Viewer.path) ? "A favourite now" : "No longer a favourite", FileLibrary.isFavorite(Viewer.path) ? "heart" : "heart_outline");
	}

	// faces and number plates found, each pixelated (drawings: they move, they can be taken away)
	function blurFaces() {
		const path = Viewer.path;
		Viewer.busy = true;
		Viewer.busyText = "Looking for faces and number plates…";
		Viewer.request("faces", { path: Viewer.shownPath }, (data, error) => {
			Viewer.busy = false;
			if (error) return Viewer.fail(error);
			if (Viewer.path !== path) return;
			const boxes = (data.faces ?? []).concat(data.plates ?? []);
			if (boxes.length === 0) return Viewer.say("No faces or number plates found", "face_recognition");
			const g = Viewer.recipe.geometry, w = Viewer.info.width, h = Viewer.info.height;
			const back = Geo.inverse(Geo.matrix(g, w, h));
			const [ow, oh] = Geo.outputSize(g, w, h);
			const items = boxes.map(b => {
				const corners = [[b[0], b[1]], [b[0] + b[2], b[1]], [b[0], b[1] + b[3]], [b[0] + b[2], b[1] + b[3]]].map(p => Geo.apply(back, p[0], p[1]));
				const xs = corners.map(p => p[0] * ow), ys = corners.map(p => p[1] * oh);
				const x1 = Math.min(...xs), y1 = Math.min(...ys), x2 = Math.max(...xs), y2 = Math.max(...ys);
				return { type: "pixelate", color: "#000000", size: Math.max(4, Math.round((y2 - y1) / 7)), opacity: 1, fill: false, x1: x1, y1: y1, x2: x2, y2: y2 };
			}).filter(a => a.x2 > 0 && a.y2 > 0 && a.x1 < ow && a.y1 < oh);
			const next = Recipe.copy(Viewer.recipe);
			next.markup = { items: (next.markup.items || []).concat(items) };
			Viewer.commit(next);
			Viewer.say(`${items.length} ${items.length === 1 ? "spot" : "spots"} blurred – Draw changes them`, "face_recognition");
		});
	}

	// what the picture shows, in words (to copy as alt text)
	property string description: ""
	property bool describing: false

	function describe(question) {
		if (root.describing) return;
		root.describing = true;
		root.description = "";
		if (!Viewer.infoShown) Viewer.toggleInfo();
		Viewer.renderTemp("", p => Viewer.request("describe", { path: p, question: question || "" }, (data, error) => {
			root.describing = false;
			if (error) return Viewer.fail(error);
			root.description = data.text ?? "";
		}));
	}

	function askAi() {
		Viewer.renderTemp("", p => {
			Popups.open("launcher", null, "", { aiFiles: [{ path: p, name: p.slice(p.lastIndexOf("/") + 1), mimeType: "image/png", size: 0, isDir: false }] });
		});
	}

	// the pictures of the folder that look like this one, walked on their own
	function similar() {
		const path = Viewer.path;
		Viewer.busy = true;
		Viewer.busyText = "Comparing the pictures here…";
		Viewer.request("similar", { path: path, folder: Viewer.folder }, (data, error) => {
			Viewer.busy = false;
			if (error) return Viewer.fail(error);
			const found = (data.similar ?? []).map(e => e.path).filter(p => p !== path);
			if (found.length === 0) return Viewer.say("Nothing here looks like it", "image_search_outline");
			const twins = (data.duplicates ?? []).length;
			Viewer.open(path, { list: [path].concat(found) });
			Viewer.say(`${found.length} similar${twins > 0 ? `, ${twins} of them the same picture` : ""} – Escape twice for the folder again`, "image_search_outline");
			root.similarOf = path;
		});
	}

	property string similarOf: ""

	FileMenu {
		id: menu

		anchors.fill: parent
		z: 50
		onClosed: {
			root.calmUntil = Date.now() + 400;
			root.takeFocus();
		}
	}

	function setWallpaper() {
		// an edited picture becomes a file of its own in Pictures/Wallpapers
		const apply = path => {
			Quickshell.execDetached(["bash", `${Paths.scripts}/apply_theme_selection.sh`, path]);
			Viewer.say("The wallpaper changes in a moment", "wallpaper");
		};
		if (Recipe.isPlain(Viewer.recipe) && !Viewer.pasted && !Viewer.info?.proxy) return apply(Viewer.path);
		const stem = (Viewer.current?.name ?? "Wallpaper").replace(/\.[^.]+$/, "");
		Viewer.saveCopy({ format: "png", target: `${Paths.home}/Pictures/Wallpapers/${stem} (wallpaper).png`, metadata: false }, path => {
			if (path) apply(path);
		});
	}

	function trash() {
		const path = Viewer.path;
		if (!path || Viewer.pasted) return;
		Files.trash([path]);
		const files = Viewer.files.filter(f => f.path !== path);
		if (files.length === 0) {
			Viewer.close();
			return;
		}
		const i = Math.min(Viewer.index, files.length - 1);
		Viewer.files = files;
		Viewer.show(i);
	}

	// what is in front, its background left out (rembg, once it is set up)
	property bool cutting: false

	function cutout() {
		if (root.cutting || !Viewer.shownPath) return;
		Viewer.request("cutoutstatus", {}, status => {
			if (!status) return;
			if (!status.installed && !status.installing) {
				toast.show("Cutting out works best with rembg (about 250 MB, set up once)", "account_box_outline", "Set it up", () => root.installCutout());
			}
			root.runCutout();
		});
	}

	function runCutout() {
		root.cutting = true;
		const path = Viewer.path;
		const out = `${Paths.cache}/viewer/masks/${Qt.md5(path + (Viewer.info?.mtime ?? ""))}.png`;
		Viewer.busyText = "Cutting out…";
		Quickshell.execDetached(["mkdir", "-p", `${Paths.cache}/viewer/masks`]);
		Viewer.request("cutout", { path: Viewer.shownPath, out: out }, (data, error) => {
			root.cutting = false;
			if (error) return Viewer.fail(error);
			if (Viewer.path !== path) return;
			const next = Recipe.copy(Viewer.recipe);
			next.cutout = data.mask;
			Viewer.commit(next);
			Viewer.say(data.engine === "rembg" ? "Cut out – saved as PNG it stays see-through" : "Cut out roughly – set up rembg for clean edges", "account_box_outline");
		});
	}

	function installCutout() {
		Viewer.request("cutoutinstall", {}, (data, error) => {
			if (error) Viewer.fail(error);
			else Viewer.say("rembg is set up – cut out again for clean edges", "check");
		});
	}

	PrintDialog {
		id: printDialog

		anchors.fill: parent
		z: 61
		onOpenChanged: if (!open) root.takeFocus()
	}

	ExportDialog {
		id: exportDialog

		anchors.fill: parent
		z: 60
		onOpenChanged: if (!open) root.takeFocus()
	}

	// ── a line of news at the bottom ───────────────────────────────────────
	Rectangle {
		id: toast

		property var action: null
		property string actionText: ""

		function show(text, icon, actionText, action) {
			toastText.text = text;
			toastGlyph.icon = icon || "information_outline";
			toast.actionText = actionText || "";
			toast.action = action || null;
			toast.opacity = 1;
			toastTimer.interval = action ? 8000 : 3200;
			toastTimer.restart();
		}

		anchors.horizontalCenter: area.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: (bottom.visible ? bottom.height : 0) + (Viewer.mode === "crop" ? crop.barHeight : 0) + 18
		width: toastRow.implicitWidth + 28
		height: 42
		radius: 21
		color: Theme.layer3
		opacity: 0
		visible: opacity > 0
		z: 70

		Behavior on opacity {
			Anim {}
		}

		Row {
			id: toastRow

			anchors.centerIn: parent
			spacing: 10

			Glyph {
				id: toastGlyph

				anchors.verticalCenter: parent.verticalCenter
				size: 18
				color: Theme.primary
			}

			StyledText {
				id: toastText

				anchors.verticalCenter: parent.verticalCenter
			}

			TextButton {
				anchors.verticalCenter: parent.verticalCenter
				visible: toast.action !== null
				text: toast.actionText
				variant: "ghost"
				onActivated: {
					const run = toast.action;
					toast.opacity = 0;
					if (run) run();
				}
			}
		}

		Timer {
			id: toastTimer

			onTriggered: toast.opacity = 0
		}
	}

	// progress of what the helper does slowly (cutting out, setting it up)
	Rectangle {
		anchors.horizontalCenter: area.horizontalCenter
		anchors.top: parent.top
		anchors.topMargin: top.height + 12
		readonly property var job: {
			const ids = Object.keys(Viewer.progress);
			return ids.length > 0 ? Viewer.progress[ids[ids.length - 1]] : null;
		}
		width: progressRow.implicitWidth + 28
		height: 36
		radius: 18
		color: Theme.layer3
		opacity: job || Viewer.busy ? 1 : 0
		visible: opacity > 0
		z: 65

		Behavior on opacity {
			Anim {}
		}

		Row {
			id: progressRow

			anchors.centerIn: parent
			spacing: 10

			Spinner {
				width: 16
				height: 16
				running: parent.visible
				anchors.verticalCenter: parent.verticalCenter
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: parent.parent.job ? `${parent.parent.job.text}${parent.parent.job.value > 0 && parent.parent.job.value < 1 ? ` · ${Math.round(parent.parent.job.value * 100)} %` : ""}` : Viewer.busyText
				font.pixelSize: Theme.size.label
			}
		}
	}

	// ── keys ───────────────────────────────────────────────────────────────
	// when a menu or a mode was left a moment ago, Escape does not close the window
	property real calmUntil: 0

	Keys.onPressed: event => {
		root.wake();
		if (menu.open) {
			if (event.key === Qt.Key_Escape) {
				menu.close();
				root.calmUntil = Date.now() + 400;
				event.accepted = true;
			}
			return;
		}
		const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
		const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
		const key = event.key;
		event.accepted = true;
		if (printDialog.open) {
			if (key === Qt.Key_Escape) printDialog.close();
			else if (key === Qt.Key_Return || key === Qt.Key_Enter) printDialog.send();
			else event.accepted = false;
			return;
		}
		if (exportDialog.open) {
			if (key === Qt.Key_Escape) exportDialog.close();
			else if (key === Qt.Key_Return || key === Qt.Key_Enter) exportDialog.save();
			else event.accepted = false;
			return;
		}
		if (ctrl) {
			if (key === Qt.Key_Z) shift ? Viewer.redo() : Viewer.undo();
			else if (key === Qt.Key_Y) Viewer.redo();
			else if (key === Qt.Key_S) shift ? exportDialog.show() : Viewer.saveCopy();
			else if (key === Qt.Key_C) shift ? Viewer.copyEdits() : Viewer.copyResult();
			else if (key === Qt.Key_V) shift ? Viewer.pasteEdits() : Viewer.paste();
			else if (key === Qt.Key_P) printDialog.show();
			else if (key === Qt.Key_F) root.toggleFavourite();
			else if (key === Qt.Key_W || key === Qt.Key_Q) Viewer.close();
			else if (key === Qt.Key_O) Files.reveal([Viewer.path]);
			else event.accepted = false;
			return;
		}
		// stars: Shift+1…5 (or 1…5 while sorting out)
		if (key >= Qt.Key_1 && key <= Qt.Key_5 && (shift || Viewer.culling) && Viewer.mode === "view") {
			Viewer.setStars(key - Qt.Key_0);
			return;
		}
		// Shift+1 … arrives as !, ", § … on many layouts
		const shifted = { [Qt.Key_Exclam]: 1, [Qt.Key_QuoteDbl]: 2, [Qt.Key_section]: 3, [Qt.Key_At]: 2, [Qt.Key_NumberSign]: 3, [Qt.Key_Dollar]: 4, [Qt.Key_Percent]: 5 };
		if (shifted[key] !== undefined && Viewer.mode === "view") {
			Viewer.setStars(shifted[key]);
			return;
		}
		if (Viewer.culling && Viewer.mode === "view") {
			if (key === Qt.Key_Up || key === Qt.Key_K) return Viewer.setFlag("keep");
			if (key === Qt.Key_Down || key === Qt.Key_X) return Viewer.setFlag("reject");
		}
		if (Viewer.sliding) {
			if (key === Qt.Key_Space) {
				Viewer.slidePaused = !Viewer.slidePaused;
				Viewer.say(Viewer.slidePaused ? "Paused" : "On it goes", Viewer.slidePaused ? "pause" : "play");
				return;
			}
			if (key === Qt.Key_Escape || key === Qt.Key_F5) {
				Viewer.slideshow(false);
				return;
			}
		}
		switch (key) {
		case Qt.Key_F5:
			Viewer.slideshow(true);
			return;
		case Qt.Key_M:
			Viewer.toggleMark();
			return;
		case Qt.Key_Escape:
			if (Viewer.culling) Viewer.culling = false;
			else if (root.similarOf && Viewer.mode === "view" && stage.fitted) {
				// back from the similar ones to the whole folder
				const from = root.similarOf;
				root.similarOf = "";
				Viewer.open(from);
			}
			else if (Viewer.mode !== "view") {
				Viewer.setMode("view");
				root.calmUntil = Date.now() + 400;
			} else if (!stage.fitted) stage.fit();
			else if (Date.now() > root.calmUntil) Viewer.close();
			return;
		case Qt.Key_Right:
		case Qt.Key_PageDown:
		case Qt.Key_Space:
			if (Viewer.mode === "view") Viewer.step(1);
			return;
		case Qt.Key_Left:
		case Qt.Key_PageUp:
		case Qt.Key_Backspace:
			if (Viewer.mode === "view") Viewer.step(-1);
			return;
		case Qt.Key_Home:
			Viewer.first();
			return;
		case Qt.Key_End:
			Viewer.last();
			return;
		case Qt.Key_Plus:
		case Qt.Key_Equal:
			stage.zoomBy(1.25);
			return;
		case Qt.Key_Minus:
			stage.zoomBy(0.8);
			return;
		case Qt.Key_0:
			stage.fit();
			return;
		case Qt.Key_1:
			stage.actualSize();
			return;
		case Qt.Key_I:
			Viewer.toggleInfo();
			return;
		case Qt.Key_E:
		case Qt.Key_A:
			Viewer.setMode(Viewer.mode === "adjust" ? "view" : "adjust");
			return;
		case Qt.Key_C:
		case Qt.Key_X:
			Viewer.setMode(Viewer.mode === "crop" ? "view" : "crop");
			return;
		case Qt.Key_D:
			Viewer.setMode("markup");
			return;
		case Qt.Key_R:
			crop.turn(shift ? -1 : 1);
			return;
		case Qt.Key_H:
			crop.mirror();
			return;
		case Qt.Key_Backslash:
			if (!event.isAutoRepeat) root.comparing = true;
			return;
		case Qt.Key_Delete:
			if (Viewer.mode === "view") root.trash();
			return;
		case Qt.Key_Return:
		case Qt.Key_Enter:
			if (Viewer.mode === "crop") crop.done();
			return;
		}
		event.accepted = false;
	}

	Keys.onReleased: event => {
		if (event.key === Qt.Key_Backslash && !event.isAutoRepeat) {
			root.comparing = false;
			event.accepted = true;
		}
	}
}
