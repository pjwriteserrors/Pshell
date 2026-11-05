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
	readonly property bool editing: Viewer.mode !== "view"
	readonly property bool sidePanel: Viewer.mode === "adjust" || (Viewer.infoShown && Viewer.mode === "view")
	// the bars: always while editing, otherwise while the pointer moves
	property bool chrome: true
	property bool comparing: false
	// before | after side by side; grows in from the left when switched on
	property real split: 0

	function toggleSplit() {
		splitAnim.to = root.split > 0 ? 0 : 0.5;
		splitAnim.restart();
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

		function onPathChanged() {
			if (Viewer.mode === "view") root.split = 0;
		}
	}
	property bool clipWarning: false
	property var histogram: null

	function takeFocus() {
		root.forceActiveFocus();
		root.wake();
	}

	function wake() {
		root.chrome = true;
		hideChrome.restart();
	}

	Timer {
		id: hideChrome

		interval: 2400
		onTriggered: if (!root.editing && !topMouse.containsMouse && !stripMouse.containsMouse && !menu.open) root.chrome = false
	}

	Component.onCompleted: Viewer.renderer = root
	Component.onDestruction: if (Viewer.renderer === root) Viewer.renderer = null

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
			anchors.bottomMargin: Viewer.mode === "crop" ? crop.barHeight : (root.editing ? 16 : 0)
			margin: root.editing ? 36 : 24
			cropless: Viewer.mode === "crop"
			original: root.comparing
			split: root.split
			clipWarning: root.clipWarning && Viewer.mode === "adjust"
			visible: Viewer.mode !== "markup"
			onPointerMoved: root.wake()

			Behavior on anchors.topMargin {
				SpatialAnim {}
			}
			Behavior on anchors.bottomMargin {
				SpatialAnim {}
			}
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
			}
		}

		function onSaid(text, icon) {
			toast.show(text, icon);
		}

		function onPathChanged() {
			root.histogram = null;
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
		opacity: root.chrome || root.editing ? 1 : 0
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
				onClicked: Viewer.saved ? Files.reveal([Viewer.sidecar.copy]) : Viewer.saveCopy()
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
	function shareEntries() {
		const plain = Recipe.isPlain(Viewer.recipe) && !Viewer.pasted && !Viewer.info?.proxy;
		return ShareTargets.entries([Viewer.path], plain ? null : done => Viewer.renderTemp("", done));
	}

	function moreEntries() {
		const path = Viewer.path;
		const one = [path];
		const out = [];
		out.push({ header: "Save" });
		out.push({ label: "Save a copy…", icon: "content_save_cog_outline", shortcut: "Ctrl+Shift+S", run: () => exportDialog.show() });
		out.push({ label: "Copy the picture", icon: "content_copy", shortcut: "Ctrl+C", run: () => Viewer.copyResult() });
		out.push({ label: "Cut out what is in front", icon: "account_box_outline", run: () => root.cutout() });
		if (Viewer.recipe.cutout) out.push({ label: "Put the background back", icon: "image_outline", run: () => {
			const next = Recipe.copy(Viewer.recipe);
			next.cutout = "";
			Viewer.commit(next);
		} });
		if (Viewer.edited) out.push({ label: "Back to the original", icon: "backup_restore", run: () => Viewer.revert() });
		if (Viewer.madeFrom) out.push({ label: "Change it again from the original", icon: "history", run: () => Viewer.editOriginal() });
		out.push({ header: "Text" });
		if (Plugins.on("ocr")) out.push({ label: "Copy the text", icon: "text_recognition", run: () => Viewer.renderTemp("", p => Screenshot.runOcr(p, null, false)) });
		if (!Viewer.pasted) {
			out.push({ label: "Text as a .txt beside it", icon: "text_box_outline", run: () => Files.startJob("capturetext", { paths: one }) });
			out.push({ label: "Name it by what it shows", icon: "creation", run: () => Files.startJob("ainame", { paths: one }, job => {
				if (job.state === "failed") Viewer.fail(job.error);
				else if (job.state === "done") Viewer.listFolder(Viewer.folder + "/");
			}) });
		}
		out.push({ header: "Use" });
		if (Plugins.on("pins")) out.push({ label: "Pin to the screen", icon: "pin_outline", run: () => Viewer.renderTemp("", p => Screenshot.pinShot(p)) });
		if (Plugins.on("studio-wallpaper")) out.push({ label: "Set as wallpaper", icon: "wallpaper", hint: "Crop it to a screen first for a perfect fit", run: () => root.setWallpaper() });
		out.push({ label: "Make a PDF of it", icon: "file_pdf_box", enabled: !Viewer.pasted, run: () => Files.pdfTool("fromimages", one, {}) });
		if (!Viewer.pasted) {
			out.push({ label: "Remove location and camera data", icon: "map_marker_off_outline", run: () => Files.imageTool("strip", one, {}) });
			out.push({ header: "File" });
			out.push({ label: "Show in Files", icon: "folder_open_outline", run: () => Files.reveal(one) });
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
		return out;
	}

	FileMenu {
		id: menu

		anchors.fill: parent
		z: 50
		onClosed: root.takeFocus()
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
	Keys.onPressed: event => {
		root.wake();
		const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
		const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
		const key = event.key;
		event.accepted = true;
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
			else if (key === Qt.Key_C) Viewer.copyResult();
			else if (key === Qt.Key_V) Viewer.paste();
			else if (key === Qt.Key_W || key === Qt.Key_Q) Viewer.close();
			else if (key === Qt.Key_O) Files.reveal([Viewer.path]);
			else event.accepted = false;
			return;
		}
		switch (key) {
		case Qt.Key_Escape:
			if (Viewer.mode !== "view") Viewer.setMode("view");
			else if (!stage.fitted) stage.fit();
			else Viewer.close();
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
