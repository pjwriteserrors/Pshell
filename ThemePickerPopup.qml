pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"
import "NiriAnimation.js" as NiriAnimation

// Studio's wallpaper page: the wallpaper, and the wallust palette made from it.
//
// The wallpapers are lanterns hung from one long wire you scroll along; the
// chosen one grows and the light rests under it. On that lantern sits a
// mock of this very shell — a wire with beads and a small lantern — coloured
// with the REAL palette wallust makes from that wallpaper (`palette-json`).
// The six wallust variants (palette × style) are six short swatch-threads
// under it, the chosen one lit. Nothing is applied until Enter or Apply.
//
//   Up/Down      move along the wire (or dark/light inside the variants)
//   Right/Left   step into the variants and across them; Left past the first
//                steps back out
//   Enter        apply; Escape closes; typing filters
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
	property real reveal: 1

	// wallust v4 remap: the picker keeps a two-axis grid, but the axes map
	// onto wallust's options. COLUMNS (historically "colorSpace") carry the
	// wallust PALETTE (kmeans/salience/ansi); ROWS (historically "palette")
	// carry the wallust STYLE (dark/light). The property names keep their
	// historical meaning: selectedColorSpace → --palette, selectedPalette → --style.
	property string searchText: ""
	property var themes: []
	property string selectedBackend: "fastresize"
	property string selectedColorSpace: "salience"
	property string selectedPalette: "dark"
	property int selectedColorIndex: 0
	property int selectedPaletteIndex: 0
	property bool variantSelectionActive: false
	property var animationOptions: []
	property string animationStateHint: ""
	property string selectedAnimationId: ""
	property var previewPaletteData: ({})
	property string previewPaletteStatus: "idle"
	property string previewPaletteRequestKey: ""
	property var previewMatrixItems: []
	property var previewMatrixMap: ({})
	property string previewMatrixRequestKey: ""
	property bool previewMatrixLoading: false
	property int currentThemeIndex: 0
	property var pendingDeleteTheme: null
	property bool deleteInProgress: false
	property string deleteError: ""
	focus: true

	readonly property string themeCatalogScriptPath: `${Quickshell.shellDir}/scripts/theme_catalog.sh`
	readonly property string applyScriptPath: `${Quickshell.shellDir}/scripts/apply_theme_selection.sh`
	readonly property string wallustConfigPath: "/home/lu/.config/wallust/wallust.toml"
	readonly property string shaderAnimationsDir: "/home/lu/.config/niri/animations/shaders"
	readonly property string nirimationAnimationsDir: "/home/lu/.config/niri/animations/nirimation/animations"
	readonly property string animationStatePath: "/home/lu/.local/state/quickshell-theme/current-animation"
	readonly property string shaderCurrentPath: "/home/lu/.config/niri/animations/shaders/.current"
	readonly property var backendOptions: ["full", "resized", "wal", "thumb", "fastresize"]
	// grid columns -> wallust palette
	readonly property var colorSpaceOptions: ["salience", "ansi", "kmeans"]
	// grid rows -> wallust style (dark on top, light below)
	readonly property var paletteOptions: ["dark", "light"]
	readonly property var darkPaletteOptions: ["dark"]
	readonly property var lightPaletteOptions: ["light"]
	readonly property var visualPaletteOptions: root.darkPaletteOptions.concat(root.lightPaletteOptions)
	readonly property var currentAnimationOption: {
		for (const option of root.animationOptions) {
			if (String(option.id || "") === root.selectedAnimationId) return option;
		}
		return root.animationOptions.length > 0 ? root.animationOptions[0] : null;
	}
	readonly property color activePreviewBackground: root.previewPaletteStatus === "ready" ? (root.previewPaletteData.background || "transparent") : "transparent"
	readonly property color activePreviewForeground: root.previewPaletteStatus === "ready" ? (root.previewPaletteData.foreground || "transparent") : "transparent"
	readonly property var filteredThemes: {
		const query = root.searchText.trim().toLowerCase();
		if (query === "") return root.themes;
		return root.themes.filter(theme => String(theme.name || "").toLowerCase().includes(query));
	}
	readonly property var currentTheme: {
		if (root.filteredThemes.length === 0) return null;
		const index = Math.max(0, Math.min(root.currentThemeIndex, root.filteredThemes.length - 1));
		return root.filteredThemes[index];
	}

	// ------------------------------------------------------------ the data
	function setThemeEntries(raw) {
		const entries = [];
		for (const line of String(raw || "").split("\n")) {
			const trimmed = line.trim();
			if (trimmed === "") continue;
			const parts = trimmed.split("\t");
			if (parts.length < 4) continue;
			entries.push({
				name: parts[0],
				path: parts[1],
				mediaPath: parts[2],
				previewPath: parts[3],
				mediaType: parts.length >= 5 ? parts[4] : "video"
			});
		}
		root.themes = entries;
		Qt.callLater(function() {
			root.reloadPreviewPalette();
			previewMatrixReloadTimer.restart();
		});
	}

	function parseWallustValue(raw, key) {
		const match = String(raw || "").match(new RegExp(`^${key}\\s*=\\s*"([^"]+)"`, "m"));
		return match ? match[1] : "";
	}

	function setWallustConfig(raw) {
		const backend = root.parseWallustValue(raw, "backend");
		const palette = root.parseWallustValue(raw, "palette");
		const style = root.parseWallustValue(raw, "style");

		if (backend !== "" && root.backendOptions.indexOf(backend) >= 0) root.selectedBackend = backend;
		if (palette !== "" && root.colorSpaceOptions.indexOf(palette) >= 0) root.selectedColorSpace = palette;
		if (style !== "" && root.paletteOptions.indexOf(style) >= 0) root.selectedPalette = style;
		root.syncVariantIndexes();
	}

	function syncVariantIndexes() {
		const colorIndex = root.colorSpaceOptions.indexOf(root.selectedColorSpace);
		const paletteIndex = root.visualPaletteOptions.indexOf(root.selectedPalette);
		root.selectedColorIndex = Math.max(0, colorIndex);
		root.selectedPaletteIndex = Math.max(0, paletteIndex);
		if (colorIndex < 0) root.selectedColorSpace = root.colorSpaceOptions[0];
		if (paletteIndex < 0) root.selectedPalette = root.visualPaletteOptions[0] || root.paletteOptions[0];
	}

	function selectColorIndex(index) {
		const next = Math.max(0, Math.min(root.colorSpaceOptions.length - 1, index));
		root.selectedColorIndex = next;
		root.selectedColorSpace = root.colorSpaceOptions[next];
	}

	function selectPaletteIndex(index) {
		const next = Math.max(0, Math.min(root.visualPaletteOptions.length - 1, index));
		root.selectedPaletteIndex = next;
		root.selectedPalette = root.visualPaletteOptions[next];
	}

	function selectVariant(colorSpace, palette) {
		const colorIndex = root.colorSpaceOptions.indexOf(colorSpace);
		const paletteIndex = root.visualPaletteOptions.indexOf(palette);
		if (colorIndex >= 0) root.selectColorIndex(colorIndex);
		if (paletteIndex >= 0) root.selectPaletteIndex(paletteIndex);
		root.variantSelectionActive = true;
	}

	function setAnimationOptions(raw) {
		root.animationOptions = NiriAnimation.parseOptions(raw);
		root.selectedAnimationId = NiriAnimation.chooseSelectedId(root.animationStateHint, root.animationOptions, "");
	}

	function setAnimationState(raw) {
		root.animationStateHint = String(raw || "").trim();
		root.selectedAnimationId = NiriAnimation.chooseSelectedId(root.animationStateHint, root.animationOptions, "");
	}

	function previewKey(theme, backend, colorSpace, palette) {
		if (!theme) return "";
		return [String(theme.path || ""), String(theme.previewPath || ""), backend, colorSpace, palette].join("");
	}

	function matrixKey(theme, backend) {
		if (!theme) return "";
		return [String(theme.path || ""), String(theme.previewPath || ""), backend].join("");
	}

	function reloadPreviewPalette() {
		const theme = root.currentTheme;
		if (!theme) {
			root.previewPaletteData = {};
			root.previewPaletteStatus = "idle";
			root.previewPaletteRequestKey = "";
			return;
		}

		const key = root.previewKey(theme, root.selectedBackend, root.selectedColorSpace, root.selectedPalette);
		root.previewPaletteRequestKey = key;
		root.previewPaletteStatus = "loading";
		root.previewPaletteData = {};
		loadPreviewPaletteProcess.running = false;
		loadPreviewPaletteProcess.command = [
			"bash", root.themeCatalogScriptPath, "palette-json",
			theme.path, theme.previewPath,
			root.selectedBackend, root.selectedColorSpace, root.selectedPalette
		];
		loadPreviewPaletteProcess.running = true;
	}

	function setPreviewPalette(raw) {
		const text = String(raw || "").trim();
		if (text === "") {
			root.previewPaletteStatus = "error";
			return;
		}

		try {
			const data = JSON.parse(text);
			const key = root.previewKey({ path: data.themePath, previewPath: data.previewPath }, data.backend, data.colorSpace, data.palette);
			if (key !== root.previewPaletteRequestKey) return;
			root.previewPaletteData = data;
			root.previewPaletteStatus = "ready";
		} catch (error) {
			console.warn(`Could not parse theme preview palette: ${error}`);
			root.previewPaletteStatus = "error";
		}
	}

	function reloadPreviewMatrix() {
		const theme = root.currentTheme;
		if (!theme) {
			root.previewMatrixItems = [];
			root.previewMatrixMap = {};
			root.previewMatrixRequestKey = "";
			root.previewMatrixLoading = false;
			return;
		}

		const key = root.matrixKey(theme, root.selectedBackend);
		root.previewMatrixRequestKey = key;
		root.previewMatrixLoading = true;
		root.previewMatrixItems = [];
		root.previewMatrixMap = {};
		loadPreviewMatrixProcess.running = false;
		loadPreviewMatrixProcess.command = [
			"bash", root.themeCatalogScriptPath, "matrix-json",
			theme.path, theme.previewPath, root.selectedBackend
		];
		loadPreviewMatrixProcess.running = true;
	}

	function setPreviewMatrix(raw) {
		const text = String(raw || "").trim();
		if (text === "") {
			root.previewMatrixItems = [];
			root.previewMatrixMap = {};
			root.previewMatrixLoading = false;
			return;
		}

		try {
			const data = JSON.parse(text);
			const key = root.matrixKey({ path: data.themePath, previewPath: data.previewPath }, data.backend);
			if (key !== root.previewMatrixRequestKey) return;
			const items = Array.isArray(data.items) ? data.items : [];
			const map = {};
			for (const item of items)
				map[`${item.colorSpace}|${item.palette}`] = item;
			root.previewMatrixItems = items;
			root.previewMatrixMap = map;
			root.previewMatrixLoading = false;
		} catch (error) {
			console.warn(`Could not parse theme preview matrix: ${error}`);
			root.previewMatrixItems = [];
			root.previewMatrixMap = {};
			root.previewMatrixLoading = false;
		}
	}

	function matrixCell(colorSpace, palette) {
		return root.previewMatrixMap[`${colorSpace}|${palette}`] || null;
	}

	function paletteSwatch(index) {
		return root.dataSwatch(root.previewPaletteData, index);
	}

	function dataSwatch(data, index) {
		if (!data) return "transparent";
		if (Array.isArray(data.swatches) && index >= 0 && index < data.swatches.length)
			return data.swatches[index];
		if (data.colors && data.colors[`color${index}`])
			return data.colors[`color${index}`];
		return "transparent";
	}

	function dataTone(data, index) {
		if (!data) return "transparent";
		if (index === -2) return data.background;
		if (index === -1) return data.foreground;
		return root.dataSwatch(data, index);
	}

	// The light of a palette: the entry among color1..6 with the most chroma
	// that still reads on its background — the same rule Filament uses.
	function dataAccent(data) {
		if (!data || !data.background) return Filament.charge;
		let best = null;
		let bestScore = -1;
		for (let i = 1; i <= 6; i += 1) {
			const raw = root.dataSwatch(data, i);
			if (raw === "transparent") continue;
			const col = Filament.legible(raw, data.background, 2.6);
			const score = Filament.chroma(col) * Math.min(Filament.contrast(col, data.background), 7);
			if (score > bestScore) { bestScore = score; best = col; }
		}
		return best || data.foreground;
	}

	function colorChannel(hex, offset) {
		let value = String(hex || "").replace("#", "");
		if (value.length === 8) value = value.slice(2);
		if (value.length < 6) return 0;
		const parsed = parseInt(value.slice(offset, offset + 2), 16);
		return isNaN(parsed) ? 0 : parsed / 255;
	}

	function readableTextColor(hex) {
		const r = root.colorChannel(hex, 0);
		const g = root.colorChannel(hex, 2);
		const b = root.colorChannel(hex, 4);
		return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.58 ? "#141414" : "#ffffff";
	}

	function mediaBadgeLabel(mediaType) {
		return String(mediaType || "") === "video" ? "VIDEO" : "IMAGE";
	}

	function reloadThemes() {
		listThemesProcess.running = true;
	}

	function reloadWallustConfig() {
		readWallustConfigProcess.running = true;
	}

	function reloadAnimations() {
		listAnimationOptionsProcess.running = true;
		readAnimationStateProcess.running = true;
	}

	// ------------------------------------------------------- the selection
	function syncCurrentThemeIndex() {
		if (root.filteredThemes.length === 0) {
			root.currentThemeIndex = -1;
			return;
		}

		if (root.currentThemeIndex < 0 || root.currentThemeIndex >= root.filteredThemes.length)
			root.currentThemeIndex = 0;
	}

	function moveSelection(delta) {
		if (root.filteredThemes.length === 0) return;
		root.variantSelectionActive = false;
		root.currentThemeIndex = Math.max(0, Math.min(root.filteredThemes.length - 1, root.currentThemeIndex + delta));
	}

	function moveVertical(delta) {
		if (root.variantSelectionActive) {
			root.selectPaletteIndex(root.selectedPaletteIndex + delta);
			return;
		}

		root.moveSelection(delta);
	}

	function moveHorizontal(delta) {
		if (!root.variantSelectionActive) {
			if (delta > 0) root.variantSelectionActive = true;
			return;
		}

		const next = root.selectedColorIndex + delta;
		if (next < 0) {
			root.variantSelectionActive = false;
			return;
		}
		root.selectColorIndex(next);
	}

	function applyTheme(theme) {
		if (!theme) return;
		root.closeRequested();
		const command = [
			"bash", root.applyScriptPath, theme.path,
			"--backend", root.selectedBackend,
			"--palette", root.selectedColorSpace,
			"--style", root.selectedPalette
		];
		if (root.selectedAnimationId !== "") command.push("--animation", root.selectedAnimationId);
		Quickshell.execDetached(command);
	}

	function deleteThemeMedia(theme) {
		if (!theme || root.deleteInProgress) return;

		root.pendingDeleteTheme = theme;
		root.deleteInProgress = true;
		root.deleteError = "";
		loadPreviewPaletteProcess.running = false;
		loadPreviewMatrixProcess.running = false;
		deleteThemeMediaProcess.command = [
			"bash", root.themeCatalogScriptPath, "trash-theme",
			theme.path, theme.mediaPath, theme.previewPath
		];
		deleteThemeMediaProcess.running = true;
	}

	function reset() {
		root.searchText = "";
		root.currentThemeIndex = 0;
		filter.text = "";
		root.reloadThemes();
		root.reloadWallustConfig();
		root.reloadAnimations();
		Qt.callLater(function() {
			filter.selectAll();
			filter.take();
		});
	}

	Component.onCompleted: {
		// The field keeps the keyboard, so the arrows have to be taken off it
		// before the caret gets them: the wire and the variants own them.
		filter.input.Keys.pressed.connect(function (event) {
			switch (event.key) {
			case Qt.Key_Up: root.moveVertical(-1); event.accepted = true; break;
			case Qt.Key_Down: root.moveVertical(1); event.accepted = true; break;
			case Qt.Key_Left: root.moveHorizontal(-1); event.accepted = true; break;
			case Qt.Key_Right: root.moveHorizontal(1); event.accepted = true; break;
			}
		});
		root.reset();
	}
	onFilteredThemesChanged: syncCurrentThemeIndex()
	onCurrentThemeChanged: {
		root.reloadPreviewPalette();
		previewMatrixReloadTimer.restart();
	}
	onSelectedBackendChanged: {
		root.reloadPreviewPalette();
		previewMatrixReloadTimer.restart();
	}
	onSelectedColorSpaceChanged: root.reloadPreviewPalette()
	onSelectedPaletteChanged: root.reloadPreviewPalette()
	Keys.onUpPressed: moveVertical(-1)
	Keys.onDownPressed: moveVertical(1)
	Keys.onLeftPressed: moveHorizontal(-1)
	Keys.onRightPressed: moveHorizontal(1)
	Keys.onReturnPressed: applyTheme(currentTheme)
	Keys.onEnterPressed: applyTheme(currentTheme)
	Keys.onEscapePressed: root.closeRequested()

	Timer {
		id: previewMatrixReloadTimer
		interval: 260
		repeat: false
		onTriggered: root.reloadPreviewMatrix()
	}

	Timer {
		id: deleteErrorTimer
		interval: 5000
		repeat: false
		onTriggered: root.deleteError = ""
	}

	Process {
		id: listThemesProcess
		command: ["bash", root.themeCatalogScriptPath, "list"]
		stdout: StdioCollector {
			onStreamFinished: root.setThemeEntries(text)
		}
	}

	Process {
		id: deleteThemeMediaProcess
		command: ["true"]
		onExited: function(exitCode) {
			root.deleteInProgress = false;
			if (exitCode === 0) {
				const deletedPath = root.pendingDeleteTheme ? String(root.pendingDeleteTheme.mediaPath || "") : "";
				root.themes = root.themes.filter(theme => String(theme.mediaPath || "") !== deletedPath);
				root.pendingDeleteTheme = null;
				root.deleteError = "";
				root.reloadThemes();
				Qt.callLater(function() { filter.take(); });
			} else if (root.deleteError === "") {
				root.deleteError = "Could not move the theme file to Trash.";
				deleteErrorTimer.restart();
			}
		}
		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") {
					root.deleteError = message;
					deleteErrorTimer.restart();
				}
			}
		}
	}

	Process {
		id: readWallustConfigProcess
		command: ["sh", "-lc", `cat '${root.wallustConfigPath}'`]
		stdout: StdioCollector {
			onStreamFinished: root.setWallustConfig(text)
		}
	}

	Process {
		id: loadPreviewPaletteProcess
		command: ["true"]
		onExited: function(exitCode) {
			if (exitCode !== 0) {
				root.previewPaletteData = {};
				root.previewPaletteStatus = "error";
			}
		}
		stdout: StdioCollector {
			onStreamFinished: root.setPreviewPalette(text)
		}
	}

	Process {
		id: loadPreviewMatrixProcess
		command: ["true"]
		onExited: function(exitCode) {
			if (exitCode !== 0) {
				root.previewMatrixItems = [];
				root.previewMatrixMap = {};
				root.previewMatrixLoading = false;
			}
		}
		stdout: StdioCollector {
			onStreamFinished: root.setPreviewMatrix(text)
		}
	}

	Process {
		id: listAnimationOptionsProcess
		command: ["sh", "-lc", `
{
	for dir in "${root.shaderAnimationsDir}"/*; do
		[ -d "$dir" ] || continue
		[ -f "$dir/open.glsl" ] || continue
		[ -f "$dir/close.glsl" ] || continue
		printf 'shader:%s\\n' "$(basename "$dir")"
	done
	for file in "${root.nirimationAnimationsDir}"/*.kdl; do
		[ -f "$file" ] || continue
		printf 'nirimation:%s\\n' "$(basename "$file" .kdl)"
	done
} | sort
`]
		stdout: StdioCollector {
			onStreamFinished: root.setAnimationOptions(text)
		}
	}

	Process {
		id: readAnimationStateProcess
		command: ["sh", "-lc", `
if [ -f "${root.animationStatePath}" ]; then
	cat "${root.animationStatePath}"
elif [ -f "${root.shaderCurrentPath}" ]; then
	printf 'shader:%s\\n' "$(sed -n '1p' "${root.shaderCurrentPath}")"
fi
`]
		stdout: StdioCollector {
			onStreamFinished: root.setAnimationState(text)
		}
	}

	// =============================================================== LAYOUT
	readonly property real bigWidth: 560
	readonly property real bigHeight: 315
	readonly property real smallWidth: 280
	readonly property real smallHeight: 158
	readonly property real lanternGap: 22
	readonly property real stemLength: 18

	// ------------------------------------------------------------ the head
	Band {
		id: head
		reveal: root.reveal
		order: 0
		width: parent.width
		height: 40

		FField {
			id: filter
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			width: 280
			placeholder: "Filter themes"
			icon: "system-search-symbolic"
			onTextChanged: root.searchText = text
			onAccepted: root.applyTheme(root.currentTheme)
			onEscaped: root.closeRequested()
		}

		Row {
			anchors.left: filter.right
			anchors.leftMargin: 36
			anchors.right: verbs.left
			anchors.rightMargin: 20
			anchors.verticalCenter: parent.verticalCenter
			spacing: 12
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: root.currentTheme ? String(root.currentTheme.name || "") : (root.themes.length === 0 ? "Reading the wallpapers…" : "No themes found")
				font.pixelSize: Filament.textXl
				font.weight: Font.DemiBold
				tone: root.currentTheme ? "ink" : "faint"
			}
			Chip {
				anchors.verticalCenter: parent.verticalCenter
				visible: !!root.currentTheme
				text: root.mediaBadgeLabel(root.currentTheme?.mediaType).toLowerCase()
			}
			FText {
				anchors.verticalCenter: parent.verticalCenter
				visible: !!root.currentTheme
				text: `${root.selectedColorSpace} / ${root.selectedPalette}`
				mono: true
				tone: "charge"
				font.pixelSize: Filament.textSm
			}
			FText {
				anchors.verticalCenter: parent.verticalCenter
				visible: !!root.currentTheme && root.selectedAnimationId !== ""
				text: `keeps ${root.selectedAnimationId}`
				mono: true
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}

		Row {
			id: verbs
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 10
			HoldButton {
				anchors.verticalCenter: parent.verticalCenter
				text: root.deleteInProgress ? "Trashing…" : "Trash"
				icon: "user-trash-symbolic"
				enabled: !!root.currentTheme && !root.deleteInProgress
				onHeld: root.deleteThemeMedia(root.currentTheme)
			}
			FButton {
				anchors.verticalCenter: parent.verticalCenter
				kind: "charge"
				text: "Apply"
				enabled: !!root.currentTheme
				onClicked: root.applyTheme(root.currentTheme)
			}
		}
	}

	// The delete error, as a line of alert ink under the head for five seconds.
	FText {
		id: errorLine
		anchors.top: head.bottom
		anchors.topMargin: 4
		anchors.right: parent.right
		width: parent.width
		horizontalAlignment: Text.AlignRight
		text: root.deleteError
		visible: root.deleteError !== ""
		tone: "alert"
		font.pixelSize: Filament.textSm
	}

	// ---------------------------------------------------------- the wire
	Band {
		id: wireBand
		reveal: root.reveal
		order: 1
		anchors.top: head.bottom
		anchors.topMargin: 26
		width: parent.width
		height: root.stemLength + root.bigHeight + 46

		readonly property real wireY: 8
		readonly property int count: root.filteredThemes.length
		readonly property real contentWidth: Math.max(width,
			root.lanternGap + (wireBand.count > 0 ? root.bigWidth + (wireBand.count - 1) * (root.smallWidth + root.lanternGap) : 0) + root.lanternGap)
		// Where the chosen lantern's stem meets the wire, in content coordinates.
		property real lightX: root.lanternGap + root.bigWidth / 2

		function centreOf(index) {
			return root.lanternGap + index * (root.smallWidth + root.lanternGap) + root.bigWidth / 2;
		}

		function settle() {
			if (wireBand.count === 0) return;
			const index = Math.max(0, Math.min(wireBand.count - 1, root.currentThemeIndex));
			const target = Math.max(0, Math.min(Math.max(0, wireBand.contentWidth - strip.width), wireBand.centreOf(index) - strip.width / 2));
			scrollAnim.stop();
			scrollAnim.duration = Filament.travelTime(target - strip.contentX);
			scrollAnim.to = target;
			scrollAnim.start();
		}

		Connections {
			target: root
			function onCurrentThemeIndexChanged() { wireBand.settle(); }
			function onFilteredThemesChanged() { Qt.callLater(wireBand.settle); }
		}

		NumberAnimation {
			id: scrollAnim
			target: strip
			property: "contentX"
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Filament.easeTravel
		}

		// The wheel moves the selection, the same as the arrows.
		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.NoButton
			z: 5
			onWheel: wheel => {
				if (wheel.angleDelta.y < 0) root.moveSelection(1);
				else if (wheel.angleDelta.y > 0) root.moveSelection(-1);
			}
		}

		Flickable {
			id: strip
			anchors.fill: parent
			contentWidth: wireBand.contentWidth
			contentHeight: height
			clip: true
			flickableDirection: Flickable.HorizontalFlick
			boundsBehavior: Flickable.StopAtBounds

			Wire {
				id: longWire
				x: 0
				y: wireBand.wireY - 1
				width: wireBand.contentWidth
				height: 2
				cold: Filament.wireDim
				animateLit: false
				lit: Math.min(1, (root.bigWidth * 0.7) / Math.max(1, width))
				litFrom: Math.max(0, (wireBand.lightX - root.bigWidth * 0.35) / Math.max(1, width))
			}

			// The light that rests under the chosen wallpaper.
			Spark {
				x: wireBand.lightX - size / 2
				y: wireBand.wireY - size / 2
				size: 9
				breathing: true
				z: 2
			}

			Row {
				id: lanternRow
				x: root.lanternGap
				y: wireBand.wireY
				spacing: root.lanternGap

				Repeater {
					id: lanternRepeater
					model: root.filteredThemes

					Item {
						id: lantern
						required property var modelData
						required property int index
						readonly property bool chosen: root.currentThemeIndex === lantern.index
						readonly property bool hovered: lanternTouch.containsMouse
						readonly property real planeWidth: chosen ? root.bigWidth : root.smallWidth
						readonly property real planeHeight: chosen ? root.bigHeight : root.smallHeight

						width: planeWidth
						height: root.stemLength + root.bigHeight + 30
						Behavior on width { SpringAnimation { spring: 3.5; damping: 0.32; epsilon: 0.2 } }

						function report() { if (lantern.chosen) wireBand.lightX = lanternRow.x + lantern.x + lantern.width / 2; }
						onXChanged: report()
						onWidthChanged: report()
						onChosenChanged: report()
						Component.onCompleted: report()

						// The stem.
						Wire {
							vertical: true
							x: Math.round(parent.width / 2) - 1
							y: 0
							width: 2
							height: root.stemLength
							lit: lantern.chosen ? 1 : 0
							glow: false
							cold: Filament.wireDim
						}

						Rectangle {
							id: plane
							x: 0
							y: root.stemLength
							width: parent.width
							height: lantern.planeHeight
							radius: Filament.radius
							color: Filament.planeRaised
							border.width: 1
							border.color: lantern.chosen ? Filament.charge : (lantern.hovered ? Filament.wireBright : Filament.wireDim)
							clip: true
							Behavior on height { SpringAnimation { spring: 3.5; damping: 0.32; epsilon: 0.2 } }
							Behavior on border.color { ColorAnimation { duration: Filament.quick } }

							Image {
								anchors.fill: parent
								source: String(lantern.modelData?.previewPath || "")
								fillMode: Image.PreserveAspectCrop
								asynchronous: true
								cache: true
								mipmap: true
								sourceSize: Qt.size(root.bigWidth * 2, root.bigHeight * 2)
								opacity: lantern.chosen || lantern.hovered ? 1 : 0.72
								Behavior on opacity { NumberAnimation { duration: Filament.quick } }
							}

							// The shell, on this wallpaper, in the palette it would get.
							ShellMock {
								anchors.fill: parent
								visible: lantern.chosen && root.previewPaletteStatus === "ready"
								palette: lantern.chosen ? root.previewPaletteData : null
								title: String(lantern.modelData?.name || "")
								subtitle: `${root.selectedColorSpace} · ${root.selectedPalette}`
							}

							FText {
								anchors.centerIn: parent
								visible: lantern.chosen && root.previewPaletteStatus === "loading"
								text: "wallust is reading it…"
								mono: true
								tone: "faint"
								font.pixelSize: Filament.textXs
							}
							FText {
								anchors.centerIn: parent
								visible: lantern.chosen && root.previewPaletteStatus === "error"
								text: "no palette for this wallpaper"
								mono: true
								tone: "alert"
								font.pixelSize: Filament.textXs
							}

							// The click: choose, or apply the one already chosen.
							MouseArea {
								id: lanternTouch
								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: {
									filter.take();
									if (lantern.chosen) root.applyTheme(root.filteredThemes[lantern.index]);
									else {
										root.variantSelectionActive = false;
										root.currentThemeIndex = lantern.index;
									}
								}
							}
						}

						Row {
							anchors.horizontalCenter: parent.horizontalCenter
							y: root.stemLength + lantern.planeHeight + 8
							spacing: 8
							FText {
								anchors.verticalCenter: parent.verticalCenter
								text: String(lantern.modelData?.name || "")
								tone: lantern.chosen ? "ink" : "soft"
								font.pixelSize: lantern.chosen ? Filament.textMd : Filament.textSm
								font.weight: lantern.chosen ? Font.DemiBold : Font.Medium
								width: Math.min(implicitWidth, lantern.width - 60)
							}
							Chip {
								anchors.verticalCenter: parent.verticalCenter
								visible: !lantern.chosen
								text: root.mediaBadgeLabel(lantern.modelData?.mediaType).toLowerCase()
								opacity: 0.7
							}
						}
					}
				}
			}
		}

		// Empty: no wallpaper matches the filter (or none exist).
		Column {
			anchors.centerIn: parent
			spacing: 6
			visible: root.filteredThemes.length === 0
			FText {
				anchors.horizontalCenter: parent.horizontalCenter
				text: root.themes.length === 0 ? "No wallpapers yet" : "No themes found"
				font.pixelSize: Filament.textLg
				font.weight: Font.DemiBold
			}
			FText {
				anchors.horizontalCenter: parent.horizontalCenter
				text: root.themes.length === 0 ? "Put images or videos in ~/Scripts/themes/color_themes" : "Try a different search term"
				tone: "mute"
				font.pixelSize: Filament.textSm
			}
		}
	}

	// ------------------------------------------------------- the variants
	Band {
		id: variants
		reveal: root.reveal
		order: 2
		anchors.top: wireBand.bottom
		anchors.topMargin: 20
		anchors.bottom: parent.bottom
		width: parent.width
		visible: root.currentTheme !== null

		readonly property real cellWidth: 200
		readonly property real cellHeight: 66
		readonly property bool complete: root.previewMatrixItems.length >= root.colorSpaceOptions.length * root.visualPaletteOptions.length

		Row {
			x: 0; y: 0
			spacing: 8
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: "palette"
				caps: true
				tone: root.variantSelectionActive ? "charge" : "mute"
				font.pixelSize: Filament.textXs
				Behavior on color { ColorAnimation { duration: Filament.quick } }
			}
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: root.previewMatrixLoading && !variants.complete ? "wallust is making the six variants…" : (root.variantSelectionActive ? "arrows move across · Left steps back to the wallpapers" : "Right steps in")
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}

		Column {
			x: 0
			y: 24
			spacing: 6

			Repeater {
				model: root.visualPaletteOptions

				Row {
					id: variantRow
					required property string modelData
					required property int index
					spacing: 12

					FText {
						anchors.verticalCenter: parent.verticalCenter
						width: 44
						text: variantRow.modelData
						caps: true
						tone: root.selectedPalette === variantRow.modelData ? "ink" : "faint"
						font.pixelSize: Filament.textXs
					}

					Repeater {
						model: root.colorSpaceOptions

						Item {
							id: cell
							required property string modelData
							required property int index
							readonly property string colorSpaceName: cell.modelData
							readonly property string paletteName: variantRow.modelData
							readonly property var cellData: root.matrixCell(cell.colorSpaceName, cell.paletteName)
							readonly property bool chosen: root.selectedColorSpace === cell.colorSpaceName && root.selectedPalette === cell.paletteName
							readonly property bool hovered: cellTouch.containsMouse
							width: variants.cellWidth
							height: variants.cellHeight
							opacity: cell.cellData ? 1 : 0.4
							Behavior on opacity { NumberAnimation { duration: Filament.settle } }

							MouseArea {
								id: cellTouch
								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: {
									filter.take();
									root.selectVariant(cell.colorSpaceName, cell.paletteName);
								}
							}

							FText {
								x: 12; y: 0
								text: cell.colorSpaceName
								mono: true
								tone: cell.chosen ? "charge" : (cell.hovered ? "ink" : "soft")
								font.pixelSize: Filament.textXs
								Behavior on color { ColorAnimation { duration: Filament.quick } }
							}

							Wire {
								id: cellWire
								x: 0
								y: 36
								width: parent.width - 12
								height: 2
								cold: Filament.wireDim
								lit: cell.chosen ? 1 : (cell.hovered ? 0.35 : 0)
								hot: cell.chosen ? Filament.charge : Filament.wireBright
							}

							// The swatches strung on it: bg, fg, then colour 1..6.
							Row {
								x: 12
								y: 37 - 7
								spacing: 8
								Repeater {
									model: [-2, -1, 1, 2, 3, 4, 5, 6]
									Rectangle {
										required property int modelData
										required property int index
										width: index < 2 ? 16 : 13
										height: width
										anchors.verticalCenter: parent.verticalCenter
										radius: width / 2
										color: cell.cellData ? root.dataTone(cell.cellData, modelData) : Filament.planeRaised
										border.width: 1
										border.color: cell.chosen ? Qt.alpha(Filament.charge, 0.7) : Filament.wire
										Behavior on color { ColorAnimation { duration: Filament.settle } }
									}
								}
							}

							// Where the keyboard is, when it is in the variants.
							Spark {
								x: -size / 2 + 1
								y: 37 - size / 2
								size: 8
								visible: cell.chosen
								breathing: root.variantSelectionActive
								intensity: root.variantSelectionActive ? 1 : 0.55
							}
						}
					}
				}
			}
		}

		// The whole chosen palette, as knots on a wire.
		Item {
			id: ramp
			x: variants.cellWidth * 3 + 44 + 12 * 3 + 48
			y: 0
			width: parent.width - x
			height: parent.height

			Row {
				x: 0; y: 0
				spacing: 8
				FText { anchors.verticalCenter: parent.verticalCenter; text: "colours"; caps: true; tone: "mute"; font.pixelSize: Filament.textXs }
				FText {
					anchors.verticalCenter: parent.verticalCenter
					text: root.previewPaletteStatus === "ready"
						? `${root.selectedColorSpace} · ${root.selectedPalette} · ${root.selectedBackend}`
						: (root.previewPaletteStatus === "error" ? "no palette for this wallpaper" : "reading…")
					mono: true
					tone: root.previewPaletteStatus === "error" ? "alert" : "faint"
					font.pixelSize: Filament.textXs
				}
			}

			Wire {
				x: 0
				y: 46
				width: parent.width
				height: 2
				cold: Filament.wireDim
				lit: root.previewPaletteStatus === "ready" ? 1 : 0
				hot: root.previewPaletteStatus === "ready" ? root.activePreviewForeground : Filament.charge
				glow: false
			}

			Row {
				x: 0
				y: 47 - 11
				spacing: Math.max(4, (ramp.width - 22 * 18) / 17)
				Repeater {
					model: [-2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
					Item {
						id: rampKnot
						required property int modelData
						required property int index
						width: 22
						height: 44
						Rectangle {
							anchors.horizontalCenter: parent.horizontalCenter
							y: 0
							width: rampKnot.index < 2 ? 22 : 16
							height: width
							radius: width / 2
							color: root.previewPaletteStatus === "ready" ? (root.dataTone(root.previewPaletteData, rampKnot.modelData) || Filament.planeRaised) : Filament.planeRaised
							border.width: 1
							border.color: Filament.wire
							Behavior on color { ColorAnimation { duration: Filament.settle } }
						}
						FText {
							anchors.horizontalCenter: parent.horizontalCenter
							y: 26
							text: rampKnot.modelData === -2 ? "bg" : (rampKnot.modelData === -1 ? "fg" : String(rampKnot.modelData))
							mono: true
							tone: rampKnot.index < 2 ? "soft" : "faint"
							font.pixelSize: Filament.textXs
						}
					}
				}
			}

			Row {
				x: 0
				y: 100
				spacing: 18
				visible: root.previewPaletteStatus === "ready"
				Repeater {
					model: [
						{ label: "background", key: "background" },
						{ label: "foreground", key: "foreground" },
						{ label: "cursor", key: "cursor" }
					]
					Row {
						required property var modelData
						spacing: 6
						FText { anchors.verticalCenter: parent.verticalCenter; text: modelData.label; caps: true; tone: "faint"; font.pixelSize: Filament.textXs }
						FText { anchors.verticalCenter: parent.verticalCenter; text: String(root.previewPaletteData[modelData.key] || ""); mono: true; tone: "soft"; font.pixelSize: Filament.textXs }
					}
				}
			}
		}
	}

	// ============================================================ THE MOCK
	// This shell, in miniature, in a palette that is not the one it is wearing:
	// a wire with the workspace knots, the clock bead with its resting spark,
	// three tray dots, and a lantern hung from the clock with the wallpaper's
	// name and its six colours strung inside it.
	component ShellMock: Item {
		id: mock
		property var palette: null
		property string title: ""
		property string subtitle: ""
		readonly property color bg: mock.palette?.background ?? "transparent"
		readonly property color fg: mock.palette?.foreground ?? "transparent"
		readonly property color accent: root.dataAccent(mock.palette)
		readonly property color thread: Filament.mix(bg, fg, 0.45)
		readonly property real barH: 30
		readonly property real clockW: 78

		Rectangle {
			x: 0; y: 0
			width: parent.width
			height: mock.barH
			color: Qt.alpha(mock.bg, 0.86)
		}

		// The thread, lit for a stretch under the clock.
		Rectangle {
			x: 0; y: mock.barH / 2 - 1
			width: parent.width; height: 2
			color: mock.thread
		}
		Rectangle {
			x: parent.width / 2 - mock.clockW / 2 - 24
			y: mock.barH / 2 - 1
			width: mock.clockW + 48; height: 2
			color: mock.accent
		}
		Rectangle {
			x: parent.width / 2 - mock.clockW / 2 - 24
			y: mock.barH / 2 - 4
			width: mock.clockW + 48; height: 8
			radius: 4
			color: Qt.alpha(mock.accent, 0.18)
		}

		// Launcher spark and workspace knots.
		Rectangle { x: 14; y: mock.barH / 2 - 4; width: 8; height: 8; radius: 4; color: mock.accent }
		Rectangle { x: 10; y: mock.barH / 2 - 8; width: 16; height: 16; radius: 8; color: Qt.alpha(mock.accent, 0.22) }
		Row {
			x: 34
			y: mock.barH / 2 - 4
			spacing: 8
			Repeater {
				model: 4
				Rectangle {
					required property int index
					width: 8; height: 8; radius: 4
					color: index === 1 ? mock.accent : Qt.alpha(mock.bg, 0.6)
					border.width: 1
					border.color: index === 1 ? mock.accent : mock.thread
				}
			}
		}
		// A window title laid along the thread.
		Rectangle {
			x: 88; y: mock.barH / 2 - 7
			width: 70; height: 14; radius: 7
			color: Qt.alpha(mock.bg, 0.8)
			border.width: 1; border.color: mock.thread
			Rectangle { anchors.centerIn: parent; width: 44; height: 3; radius: 1.5; color: Qt.alpha(mock.fg, 0.55) }
		}

		// The clock bead.
		Rectangle {
			id: clockBead
			x: parent.width / 2 - mock.clockW / 2
			y: mock.barH / 2 - 11
			width: mock.clockW; height: 22; radius: 11
			color: Qt.tint(Qt.alpha(mock.bg, 0.96), Qt.alpha(mock.accent, 0.16))
			border.width: 1; border.color: mock.accent
			Text {
				anchors.centerIn: parent
				text: Qt.formatTime(new Date(), "HH:mm")
				color: mock.fg
				font.family: Filament.fontMono
				font.pixelSize: 11
				font.weight: Font.DemiBold
			}
		}

		// Tray dots from the palette.
		Row {
			anchors.right: parent.right
			anchors.rightMargin: 14
			y: mock.barH / 2 - 4
			spacing: 8
			Repeater {
				model: [2, 3, 5, 4]
				Rectangle {
					required property int modelData
					width: 8; height: 8; radius: 4
					color: root.dataSwatch(mock.palette, modelData)
					border.width: 1; border.color: mock.thread
				}
			}
		}

		// The lantern hung from the clock.
		Rectangle {
			x: parent.width / 2 - 1
			y: mock.barH - 4
			width: 2; height: 14
			color: mock.accent
		}
		Rectangle {
			id: miniLantern
			x: parent.width / 2 - width / 2
			y: mock.barH + 10
			width: 196; height: 84
			radius: 8
			color: Qt.alpha(mock.bg, 0.94)
			border.width: 1; border.color: mock.thread
			Rectangle { x: parent.width / 2 - 14; y: 0; width: 28; height: 2; color: mock.accent }

			Text {
				x: 14; y: 12
				width: parent.width - 28
				text: mock.title
				color: mock.fg
				elide: Text.ElideRight
				font.family: Filament.fontUi
				font.pixelSize: 13
				font.weight: Font.DemiBold
			}
			Text {
				x: 14; y: 30
				text: mock.subtitle
				color: Qt.alpha(mock.fg, 0.6)
				font.family: Filament.fontMono
				font.pixelSize: 9
			}
			Rectangle { x: 14; y: 60; width: parent.width - 28; height: 2; color: mock.thread }
			Rectangle { x: 14; y: 60; width: (parent.width - 28) * 0.6; height: 2; color: mock.accent }
			Row {
				x: 14
				y: 60 - 5
				spacing: 12
				Repeater {
					model: [1, 2, 3, 4, 5, 6]
					Rectangle {
						required property int modelData
						width: 11; height: 11; radius: 5.5
						color: root.dataSwatch(mock.palette, modelData)
						border.width: 1
						border.color: Qt.alpha(mock.fg, 0.35)
					}
				}
			}
			Rectangle {
				anchors.right: parent.right
				anchors.rightMargin: 14
				y: 60 - 4
				width: 8; height: 8; radius: 4
				color: mock.accent
			}
		}
	}
}
