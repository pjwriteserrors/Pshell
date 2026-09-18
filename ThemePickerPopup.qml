pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "components"
import "NiriAnimation.js" as NiriAnimation

Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	required property color danger

	// wallust v4 remap: the picker keeps a two-axis grid, but the axes now map
	// onto wallust's new options. Grid COLUMNS (historically "colorSpace") now
	// carry the wallust PALETTE (kmeans/salience/ansi). Grid ROWS/sections
	// (historically "palette", split into Dark/Light) now carry the wallust
	// STYLE (dark on top, light on bottom). There is no colorspace axis anymore.
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
	// grid rows -> wallust style (dark section on top, light on the bottom)
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
	readonly property color activePreviewBackground: root.previewPaletteStatus === "ready" ? root.previewPaletteData.background : "transparent"
	readonly property color activePreviewForeground: root.previewPaletteStatus === "ready" ? root.previewPaletteData.foreground : "transparent"
	readonly property real searchBarWidth: Math.max(360, Math.min(root.width - 96, 640))
	readonly property bool wideVariantLayout: root.width >= 980
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
	readonly property real activeCardWidth: root.wideVariantLayout ? Math.max(360, Math.min(root.width * 0.42, 560)) : Math.max(340, Math.min(root.width * 0.78, 760))
	readonly property real activeCardHeight: root.wideVariantLayout ? Math.max(260, Math.min(stackArea.height * 0.74, 430)) : Math.max(220, Math.min(stackArea.height * 0.74, 540))
	readonly property real activeCardTop: Math.max(10, stackArea.height * 0.05)
	readonly property real stackCenterOffset: root.wideVariantLayout ? -Math.min(root.width * 0.2, 260) : 0
	readonly property real variantGridWidth: Math.max(390, Math.min(root.width * 0.47, 600))
	readonly property real variantGridHeight: Math.max(500, Math.min(stackArea.height - 24, 680))

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
		// wallust "palette" -> grid columns; wallust "style" -> grid rows
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
		return [String(theme.path || ""), String(theme.previewPath || ""), backend, colorSpace, palette].join("\u001f");
	}

	function matrixKey(theme, backend) {
		if (!theme) return "";
		return [String(theme.path || ""), String(theme.previewPath || ""), backend].join("\u001f");
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
		const data = root.previewPaletteData || {};
		if (Array.isArray(data.swatches) && index >= 0 && index < data.swatches.length)
			return data.swatches[index];
		if (data.colors && data.colors[`color${index}`])
			return data.colors[`color${index}`];
		return "transparent";
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
		searchField.text = "";
		root.reloadThemes();
		root.reloadWallustConfig();
		root.reloadAnimations();
		Qt.callLater(function() {
			searchField.selectAll();
			searchField.forceActiveFocus();
		});
	}

	Component.onCompleted: root.reset()
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
				Qt.callLater(function() { searchField.forceActiveFocus(); });
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

	ThemedRectangle {
		id: searchBox
		z: 30
		width: root.searchBarWidth
		height: 48
		anchors.top: parent.top
		anchors.topMargin: 18
		anchors.horizontalCenter: parent.horizontalCenter
		themeStyle: "inset"
		radius: ThemeEngine.radiusMedium
		color: Qt.alpha(root.secondaryBoxColor, 0.86)
		border.width: searchField.activeFocus ? 1 : 0
		border.color: Qt.alpha(root.barColor, 0.65)

		Image {
			anchors.left: parent.left
			anchors.leftMargin: 15
			anchors.verticalCenter: parent.verticalCenter
			width: 16
			height: 16
			source: "/usr/share/icons/Adwaita/symbolic/actions/system-search-symbolic.svg"
			fillMode: Image.PreserveAspectFit
			smooth: true
			mipmap: true
			layer.enabled: visible
			layer.effect: MultiEffect {
				colorization: 1
				colorizationColor: root.barColor
			}
		}

		TextField {
			id: searchField
			anchors.left: parent.left
			anchors.leftMargin: 43
			anchors.right: closeButton.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			color: root.foreground
			placeholderText: "Filter themes"
			placeholderTextColor: Qt.alpha(root.foreground, 0.45)
			selectedTextColor: root.foreground
			selectionColor: Qt.alpha(root.barColor, 0.22)
			selectByMouse: true
			focus: true
			background: Item {}
			onTextChanged: root.searchText = text
			Keys.onEscapePressed: root.closeRequested()
			Keys.onUpPressed: function(event) {
				root.moveVertical(-1);
				event.accepted = true;
			}
			Keys.onDownPressed: function(event) {
				root.moveVertical(1);
				event.accepted = true;
			}
			Keys.onLeftPressed: function(event) {
				root.moveHorizontal(-1);
				event.accepted = true;
			}
			Keys.onRightPressed: function(event) {
				root.moveHorizontal(1);
				event.accepted = true;
			}
			Keys.onReturnPressed: function(event) {
				root.applyTheme(root.currentTheme);
				event.accepted = true;
			}
			Keys.onEnterPressed: function(event) {
				root.applyTheme(root.currentTheme);
				event.accepted = true;
			}
		}

		ThemedRectangle {
			id: closeButton
			anchors.right: parent.right
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			width: 30
			height: 30
			radius: ThemeEngine.radiusMedium
			color: closeMouse.containsMouse ? Qt.alpha(root.barColor, 0.18) : "transparent"

			MouseArea {
				id: closeMouse
				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: root.closeRequested()
			}

			BioText {
				role: "heading"
				anchors.centerIn: parent
				color: root.foreground
				font.pixelSize: 14
				text: "x"
			}
		}
	}

	ThemedRectangle {
		visible: root.deleteError !== ""
		z: 90
		anchors.top: searchBox.bottom
		anchors.topMargin: 8
		anchors.horizontalCenter: parent.horizontalCenter
		width: Math.min(deleteErrorText.implicitWidth + 28, root.width - 80)
		height: deleteErrorText.implicitHeight + 16
		radius: ThemeEngine.radiusMedium
		color: Qt.alpha(root.danger, 0.92)

		BioText {
			role: "bodyStrong"
			id: deleteErrorText
			anchors.centerIn: parent
			width: Math.min(implicitWidth, root.width - 108)
			color: "white"
			font.pixelSize: 12
			font.weight: Font.DemiBold
			wrapMode: Text.Wrap
			horizontalAlignment: Text.AlignHCenter
			text: root.deleteError
		}
	}

		Item {
			id: variantSelector
			visible: root.wideVariantLayout && root.currentTheme !== null
			z: 18
			width: root.variantGridWidth
			height: root.variantGridHeight
			x: stackArea.width * 0.5 + root.stackCenterOffset + root.activeCardWidth * 0.5 + 24 + (root.variantSelectionActive ? 0 : 18)
			y: stackArea.y + root.activeCardTop
			opacity: root.previewMatrixItems.length === root.colorSpaceOptions.length * root.paletteOptions.length ? 1 : 0.55

			readonly property real gap: 8
			readonly property real sectionGap: 14
			readonly property real sectionTitleHeight: 20
			readonly property real headerHeight: 24
			readonly property int darkRowCount: root.darkPaletteOptions.length
			readonly property int lightRowCount: root.lightPaletteOptions.length
			readonly property int totalPaletteRows: darkRowCount + lightRowCount
			readonly property real paletteGapsHeight: Math.max(0, darkRowCount - 1) * gap + Math.max(0, lightRowCount - 1) * gap
			readonly property real cellWidth: (width - gap * (root.colorSpaceOptions.length - 1)) / root.colorSpaceOptions.length
			readonly property real cellHeight: (height - sectionGap - (sectionTitleHeight + headerHeight) * 2 - paletteGapsHeight) / Math.max(1, totalPaletteRows)

			function sectionHeight(rowCount) {
				return variantSelector.sectionTitleHeight + variantSelector.headerHeight
					+ rowCount * variantSelector.cellHeight
					+ Math.max(0, rowCount - 1) * variantSelector.gap;
			}

			function sectionY(sectionName) {
				return sectionName === "Light" ? variantSelector.sectionHeight(variantSelector.darkRowCount) + variantSelector.sectionGap : 0;
			}

			function paletteY(paletteName) {
				const darkIndex = root.darkPaletteOptions.indexOf(paletteName);
				if (darkIndex >= 0)
					return variantSelector.sectionY("Dark") + variantSelector.sectionTitleHeight + variantSelector.headerHeight + darkIndex * (variantSelector.cellHeight + variantSelector.gap);

				const lightIndex = root.lightPaletteOptions.indexOf(paletteName);
				if (lightIndex >= 0)
					return variantSelector.sectionY("Light") + variantSelector.sectionTitleHeight + variantSelector.headerHeight + lightIndex * (variantSelector.cellHeight + variantSelector.gap);

				return 0;
			}

			Behavior on x { NumberAnimation { duration: ThemeEngine.duration(180); easing.type: ThemeEngine.standardEasing } }
			Behavior on opacity { NumberAnimation { duration: ThemeEngine.duration(140) } }

			Repeater {
				model: ["Dark", "Light"]

				delegate: Item {
					id: paletteSection
					required property int index
					required property string modelData

					readonly property string sectionName: modelData
					readonly property var palettes: sectionName === "Dark" ? root.darkPaletteOptions : root.lightPaletteOptions

					width: variantSelector.width
					height: variantSelector.sectionHeight(palettes.length)
					y: variantSelector.sectionY(sectionName)

					BioText {
						role: "bodyStrong"
						width: parent.width
						height: variantSelector.sectionTitleHeight
						color: root.foreground
						font.pixelSize: 12
						font.weight: Font.DemiBold
						verticalAlignment: Text.AlignVCenter
						text: paletteSection.sectionName
					}

					Row {
						id: variantHeader
						y: variantSelector.sectionTitleHeight
						width: parent.width
						height: variantSelector.headerHeight
						spacing: variantSelector.gap

						Repeater {
							model: root.colorSpaceOptions

							delegate: ThemedRectangle {
								required property int index
								required property string modelData

								width: variantSelector.cellWidth
								height: variantSelector.headerHeight - 4
								radius: ThemeEngine.radiusMedium
								color: Qt.alpha(root.selectedColorIndex === index ? root.barColor : root.secondaryBoxStrongColor, root.selectedColorIndex === index ? 0.34 : 0.42)
								border.width: root.selectedColorIndex === index ? 1 : 0
								border.color: Qt.alpha(root.barColor, 0.72)

								BioText {
									role: "caption"
									anchors.fill: parent
									anchors.leftMargin: 8
									anchors.rightMargin: 8
									color: root.foreground
									font.pixelSize: 11
									font.weight: parent.index === root.selectedColorIndex ? Font.DemiBold : Font.Medium
									horizontalAlignment: Text.AlignHCenter
									verticalAlignment: Text.AlignVCenter
									elide: Text.ElideRight
									text: parent.modelData
								}
							}
						}
					}

					Repeater {
						model: paletteSection.palettes

						delegate: Item {
							id: paletteRow
							required property int index
							required property string modelData

							readonly property string paletteName: modelData

							width: variantSelector.width
							height: variantSelector.cellHeight
							y: variantSelector.sectionTitleHeight + variantSelector.headerHeight + index * (variantSelector.cellHeight + variantSelector.gap)

							Repeater {
								model: root.colorSpaceOptions

								delegate: ThemedRectangle {
									id: variantCell
									required property int index
									required property string modelData

									readonly property string colorSpaceName: modelData
									readonly property var cellData: root.matrixCell(colorSpaceName, paletteRow.paletteName)
									readonly property bool selected: colorSpaceName === root.selectedColorSpace
										&& paletteRow.paletteName === root.selectedPalette
									readonly property color previewBackground: root.dataTone(cellData, -2)
									readonly property color previewForeground: root.dataTone(cellData, -1)

									x: index * (variantSelector.cellWidth + variantSelector.gap)
									width: variantSelector.cellWidth
									height: variantSelector.cellHeight
									radius: ThemeEngine.radiusMedium
									color: Qt.alpha(root.secondaryInsetColor, 0.8)
									border.width: 1
									border.color: Qt.alpha(selected ? root.barColor : root.foreground, selected ? 0.68 : 0.12)
									clip: true

									Image {
										anchors.fill: parent
										asynchronous: true
										cache: true
										fillMode: Image.PreserveAspectCrop
										mipmap: true
										smooth: true
										source: root.currentTheme ? root.currentTheme.previewPath : ""
									}

									ThemedRectangle {
										anchors.fill: parent
										color: root.previewMatrixLoading && !variantCell.cellData ? Qt.rgba(0, 0, 0, 0.34) : Qt.rgba(0, 0, 0, 0.08)
									}

									ThemedRectangle {
										anchors.fill: parent
										gradient: Gradient {
											GradientStop { position: 0.0; color: Qt.alpha(variantCell.previewBackground, 0.34) }
											GradientStop { position: 0.56; color: "transparent" }
											GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.62) }
										}
									}

									ThemedRectangle {
										anchors.left: parent.left
										anchors.right: parent.right
										anchors.top: parent.top
										anchors.margins: 8
										height: Math.max(12, parent.height * 0.13)
										radius: ThemeEngine.radiusSmall
										color: Qt.alpha(variantCell.previewBackground, 0.88)
										border.width: 1
										border.color: Qt.alpha(root.dataSwatch(variantCell.cellData, 4), 0.48)

										Row {
											anchors.left: parent.left
											anchors.leftMargin: 7
											anchors.verticalCenter: parent.verticalCenter
											spacing: 4

											Repeater {
												model: [1, 2, 3]

												delegate: ThemedRectangle {
													required property int modelData

													width: 7
													height: 7
													radius: ThemeEngine.radiusSmall
													color: root.dataSwatch(variantCell.cellData, modelData)
												}
											}
										}
									}

									ThemedRectangle {
										anchors.left: parent.left
										anchors.leftMargin: 10
										anchors.top: parent.top
										anchors.topMargin: Math.max(28, parent.height * 0.28)
										width: parent.width * 0.52
										height: parent.height * 0.34
										radius: ThemeEngine.radiusSmall
										color: Qt.alpha(variantCell.previewBackground, 0.82)
										border.width: 1
										border.color: Qt.alpha(variantCell.previewForeground, 0.18)

										Column {
											anchors.fill: parent
											anchors.margins: 7
											spacing: 4

											Repeater {
												model: [2, 3, 4]

												delegate: ThemedRectangle {
													required property int modelData

													width: parent.width
													height: Math.max(5, (parent.height - 8) / 3)
													radius: ThemeEngine.radiusTiny
													color: Qt.alpha(root.dataSwatch(variantCell.cellData, modelData), modelData === 3 ? 0.86 : 0.48)
												}
											}
										}
									}

									Row {
										anchors.right: parent.right
										anchors.rightMargin: 9
										anchors.bottom: parent.bottom
										anchors.bottomMargin: 9
										spacing: 3

										Repeater {
											model: [-2, -1, 1, 2, 3, 4]

											delegate: ThemedRectangle {
												required property int modelData

												width: 11
												height: 18
												radius: ThemeEngine.radiusTiny
												color: root.dataTone(variantCell.cellData, modelData)
												border.width: 1
												border.color: Qt.rgba(255, 255, 255, 0.16)
											}
										}
									}

									BioText {
										role: "label"
										anchors.left: parent.left
										anchors.leftMargin: 10
										anchors.right: parent.right
										anchors.rightMargin: 10
										anchors.bottom: parent.bottom
										anchors.bottomMargin: 8
										color: "white"
										font.pixelSize: 10
										font.weight: variantCell.selected ? Font.DemiBold : Font.Medium
										elide: Text.ElideRight
										text: paletteRow.paletteName
									}

									MouseArea {
										anchors.fill: parent
										hoverEnabled: true
										cursorShape: Qt.PointingHandCursor
										onClicked: root.selectVariant(variantCell.colorSpaceName, paletteRow.paletteName)
									}
								}
							}
						}
					}
				}
			}

			ThemedRectangle {
				x: root.selectedColorIndex * (variantSelector.cellWidth + variantSelector.gap)
				y: variantSelector.paletteY(root.selectedPalette)
				z: 40
				width: variantSelector.cellWidth
				height: variantSelector.cellHeight
				radius: ThemeEngine.radiusMedium
				color: "transparent"
				border.width: root.variantSelectionActive ? 3 : 2
				border.color: root.variantSelectionActive ? root.barColor : Qt.alpha(root.foreground, 0.72)

				Behavior on x { NumberAnimation { duration: ThemeEngine.duration(180); easing.type: ThemeEngine.standardEasing } }
				Behavior on y { NumberAnimation { duration: ThemeEngine.duration(180); easing.type: ThemeEngine.standardEasing } }
			}
		}

	Item {
		id: stackArea
		anchors.top: searchBox.bottom
		anchors.topMargin: 14
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: footerPill.top
		anchors.bottomMargin: 8
		visible: root.filteredThemes.length > 0
		clip: false

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.NoButton
			onWheel: function(wheel) {
				if (wheel.angleDelta.y < 0) root.moveSelection(1);
				else if (wheel.angleDelta.y > 0) root.moveSelection(-1);
				wheel.accepted = true;
			}
		}

		Repeater {
			model: root.filteredThemes.length

			delegate: Item {
				required property int index
				readonly property int offset: index - root.currentThemeIndex
				readonly property int absOffset: Math.abs(offset)
				readonly property bool active: offset === 0

				visible: absOffset <= 2
				z: 10 - absOffset
				width: root.activeCardWidth - absOffset * 58
				height: root.activeCardHeight - absOffset * 46
				anchors.horizontalCenter: stackArea.horizontalCenter
				anchors.horizontalCenterOffset: root.stackCenterOffset
				y: root.activeCardTop + absOffset * 102 + (offset < 0 ? -34 : offset > 0 ? 34 : 0)
				opacity: active ? 1 : (absOffset === 1 ? 0.52 : 0.18)
				scale: active ? 1 : (absOffset === 1 ? 0.92 : 0.84)

				Behavior on y { NumberAnimation { duration: ThemeEngine.duration(220); easing.type: ThemeEngine.standardEasing } }
				Behavior on opacity { NumberAnimation { duration: ThemeEngine.duration(180) } }
				Behavior on scale { NumberAnimation { duration: ThemeEngine.duration(220); easing.type: ThemeEngine.standardEasing } }

				ThemedRectangle {
					anchors.fill: parent
					radius: ThemeEngine.radiusMedium
					color: Qt.alpha(root.secondaryInsetColor, active ? 0.96 : 0.74)
					border.width: active ? 1 : 0
					border.color: Qt.alpha(root.barColor, 0.85)
					clip: true

					Behavior on color { ColorAnimation { duration: ThemeEngine.duration(180) } }

					Image {
						anchors.fill: parent
						asynchronous: true
						cache: true
						fillMode: Image.PreserveAspectCrop
						mipmap: true
						smooth: true
						source: root.filteredThemes[index].previewPath
					}

					ThemedRectangle {
						anchors.fill: parent
						radius: ThemeEngine.radiusMedium
						gradient: Gradient {
							GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, active ? 0.06 : 0.16) }
							GradientStop { position: 0.6; color: "transparent" }
							GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, active ? 0.58 : 0.68) }
						}
					}

					ThemedRectangle {
						id: mediaTypeBadge
						z: 6
						anchors.top: parent.top
						anchors.right: parent.right
						anchors.margins: active ? 18 : 14
						width: mediaBadgeText.implicitWidth + 18
						height: 24
						radius: ThemeEngine.radiusMedium
						color: Qt.rgba(0, 0, 0, 0.58)
						border.width: 1
						border.color: Qt.rgba(255, 255, 255, 0.22)

						BioText {
							role: "label"
							id: mediaBadgeText
							anchors.centerIn: parent
							color: "white"
							font.pixelSize: 10
							font.weight: Font.DemiBold
							text: root.mediaBadgeLabel(root.filteredThemes[index].mediaType)
						}
					}

					ThemedRectangle {
						id: deleteMediaButton
						visible: active
						z: 8
						anchors.top: parent.top
						anchors.left: parent.left
						anchors.margins: 18
						width: 34
						height: 34
						radius: ThemeEngine.radiusMedium
						color: Qt.alpha(root.danger, deleteMediaMouse.containsMouse ? 0.78 : 0.52)
						opacity: root.deleteInProgress ? 0.45 : 1
						border.width: 1
						border.color: Qt.rgba(255, 255, 255, 0.26)

						Image {
							anchors.centerIn: parent
							width: 16
							height: 16
							source: "/usr/share/icons/Adwaita/symbolic/actions/edit-delete-symbolic.svg"
							fillMode: Image.PreserveAspectFit
							layer.enabled: true
							layer.effect: MultiEffect {
								colorization: 1
								colorizationColor: "white"
							}
						}

						MouseArea {
							id: deleteMediaMouse
							anchors.fill: parent
							enabled: !root.deleteInProgress
							hoverEnabled: enabled
							cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
							onClicked: root.deleteThemeMedia(root.filteredThemes[index])
						}
					}

						MouseArea {
							anchors.fill: parent
							enabled: active
							hoverEnabled: active
							z: 1
							cursorShape: active ? Qt.PointingHandCursor : Qt.ArrowCursor
							onClicked: {
								root.applyTheme(root.filteredThemes[index]);
							}
						}

					Item {
						id: livePreviewOverlay
						anchors.fill: parent
						visible: active && root.previewPaletteStatus === "ready"
						z: 4

							readonly property color previewBackground: root.activePreviewBackground
							readonly property color previewForeground: root.activePreviewForeground
							readonly property bool showMockup: parent.width > 410 && parent.height > 280

						ThemedRectangle {
							id: previewTopbar
							anchors.top: parent.top
							anchors.topMargin: 18
							anchors.horizontalCenter: parent.horizontalCenter
							width: Math.min(parent.width - 48, 590)
							height: Math.max(28, Math.min(38, parent.height * 0.08))
							radius: ThemeEngine.radiusMedium
							color: Qt.alpha(livePreviewOverlay.previewBackground, 0.86)
							border.width: 1
							border.color: Qt.alpha(root.paletteSwatch(4), 0.7)

							Row {
								anchors.left: parent.left
								anchors.leftMargin: 12
								anchors.verticalCenter: parent.verticalCenter
								spacing: 7

								Repeater {
									model: [1, 2, 3, 4, 5]

									delegate: ThemedRectangle {
										required property int modelData

										width: 16
										height: 16
										radius: ThemeEngine.radiusLarge
										color: modelData === 2 ? root.paletteSwatch(4) : Qt.alpha(livePreviewOverlay.previewForeground, 0.13)
										border.width: modelData === 2 ? 0 : 1
										border.color: Qt.alpha(livePreviewOverlay.previewForeground, 0.24)

										BioText {
											role: "label"
											anchors.centerIn: parent
											color: modelData === 2 ? root.readableTextColor(root.paletteSwatch(4)) : Qt.alpha(livePreviewOverlay.previewForeground, 0.72)
											font.pixelSize: 8
											font.weight: Font.DemiBold
											text: modelData
										}
									}
								}
							}

							Row {
								anchors.right: parent.right
								anchors.rightMargin: 12
								anchors.verticalCenter: parent.verticalCenter
								spacing: 8

								Repeater {
									model: [2, 3, 5]

									delegate: ThemedRectangle {
										required property int modelData

										width: 18
										height: 18
										radius: ThemeEngine.radiusLarge
										color: root.paletteSwatch(modelData)
										border.width: 1
										border.color: Qt.alpha(livePreviewOverlay.previewForeground, 0.2)
									}
								}
							}
						}

						ThemedRectangle {
							id: previewFileBrowser
							visible: livePreviewOverlay.showMockup
							anchors.left: parent.left
							anchors.leftMargin: 24
							anchors.top: previewTopbar.bottom
							anchors.topMargin: 18
							width: Math.min(parent.width * 0.38, 340)
							height: Math.min(parent.height * 0.44, 250)
							radius: ThemeEngine.radiusMedium
							color: Qt.alpha(livePreviewOverlay.previewBackground, 0.86)
							border.width: 1
							border.color: Qt.alpha(root.paletteSwatch(3), 0.62)

							ThemedRectangle {
								anchors.left: parent.left
								anchors.top: parent.top
								anchors.bottom: parent.bottom
								width: Math.max(58, parent.width * 0.24)
								color: Qt.alpha(root.paletteSwatch(0), 0.48)

								Column {
									anchors.fill: parent
									anchors.margins: 10
									spacing: 8

									Repeater {
										model: [4, 2, 3, 5]

										delegate: ThemedRectangle {
											required property int modelData

											width: parent.width
											height: 18
											radius: ThemeEngine.radiusSmall
											color: modelData === 2 ? Qt.alpha(root.paletteSwatch(2), 0.82) : Qt.alpha(livePreviewOverlay.previewForeground, 0.09)

											ThemedRectangle {
												anchors.left: parent.left
												anchors.leftMargin: 7
												anchors.verticalCenter: parent.verticalCenter
												width: 7
												height: 7
												radius: ThemeEngine.radiusTiny
												color: root.paletteSwatch(modelData)
											}
										}
									}
								}
							}

							Column {
								anchors.left: parent.left
								anchors.leftMargin: Math.max(72, parent.width * 0.29)
								anchors.right: parent.right
								anchors.rightMargin: 12
								anchors.top: parent.top
								anchors.topMargin: 12
								spacing: 9

								Repeater {
									model: [1, 2, 3, 4, 5]

									delegate: ThemedRectangle {
										required property int modelData

										width: parent.width
										height: 25
										radius: ThemeEngine.radiusSmall
										color: Qt.alpha(modelData === 3 ? root.paletteSwatch(3) : root.paletteSwatch(0), modelData === 3 ? 0.82 : 0.34)
										border.width: modelData === 3 ? 1 : 0
										border.color: Qt.alpha(livePreviewOverlay.previewForeground, 0.2)

										Row {
											anchors.left: parent.left
											anchors.leftMargin: 8
											anchors.verticalCenter: parent.verticalCenter
											spacing: 8

											ThemedRectangle {
												width: 12
												height: 12
												radius: ThemeEngine.radiusTiny
												color: root.paletteSwatch(modelData + 1)
											}

											ThemedRectangle {
												width: Math.max(42, previewFileBrowser.width * (0.26 + modelData * 0.035))
												height: 4
												radius: ThemeEngine.radiusTiny
												color: Qt.alpha(livePreviewOverlay.previewForeground, 0.58)
											}
										}
									}
								}
							}
						}

						Column {
							id: selectedSwatches
							visible: livePreviewOverlay.showMockup
							anchors.right: parent.right
							anchors.rightMargin: 24
							anchors.top: previewTopbar.bottom
							anchors.topMargin: 18
							width: Math.min(178, parent.width * 0.24)
							spacing: 8

							ThemedRectangle {
								width: parent.width
								height: 28
								radius: ThemeEngine.radiusMedium
								color: Qt.alpha(livePreviewOverlay.previewBackground, 0.88)
								border.width: 1
								border.color: Qt.alpha(root.paletteSwatch(4), 0.45)

								BioText {
									role: "label"
									anchors.fill: parent
									anchors.leftMargin: 10
									anchors.rightMargin: 10
									color: livePreviewOverlay.previewForeground
									font.pixelSize: 10
									font.weight: Font.DemiBold
									horizontalAlignment: Text.AlignHCenter
									verticalAlignment: Text.AlignVCenter
									elide: Text.ElideRight
									text: `${root.selectedColorSpace} / ${root.selectedPalette}`
								}
							}

							Grid {
								width: parent.width
								columns: 2
								columnSpacing: 6
								rowSpacing: 6

								Repeater {
									model: [-2, -1, 1, 2, 3, 4, 5, 6]

									delegate: ThemedRectangle {
										required property int modelData

										readonly property color blockColor: modelData === -2 ? livePreviewOverlay.previewBackground : modelData === -1 ? livePreviewOverlay.previewForeground : root.paletteSwatch(modelData)

										width: (selectedSwatches.width - 6) / 2
										height: 28
										radius: ThemeEngine.radiusSmall
										color: blockColor
										border.width: 1
										border.color: Qt.rgba(255, 255, 255, 0.18)

										BioText {
											role: "label"
											anchors.centerIn: parent
											color: root.readableTextColor(parent.blockColor)
											font.pixelSize: 8
											font.weight: Font.DemiBold
											text: modelData === -2 ? "bg" : modelData === -1 ? "fg" : `c${modelData}`
										}
									}
								}
							}
						}

					}

						Column {
							anchors.left: parent.left
							width: parent.width - 48
							anchors.bottom: parent.bottom
							anchors.margins: 24
							spacing: 6

						BioText {
							role: "bodyStrong"
							width: parent.width
							color: "white"
							font.pixelSize: active ? 28 : 20
							font.weight: Font.DemiBold
							elide: Text.ElideRight
							text: root.filteredThemes[index].name
						}

						BioText {
							role: "body"
							width: parent.width
							color: Qt.rgba(255, 255, 255, 0.78)
							font.pixelSize: 12
							elide: Text.ElideRight
							text: active ? `${root.selectedColorSpace} / ${root.selectedPalette}` : "Select"
						}
					}
				}
			}
		}
	}

		Item {
			id: footerPill
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.bottom: parent.bottom
			anchors.bottomMargin: 18
			width: 1
			height: 1
			visible: false
		}

	Item {
		anchors.fill: parent
		visible: root.filteredThemes.length === 0

		Column {
			anchors.centerIn: parent
			spacing: 8

			BioText {
				role: "title"
				horizontalAlignment: Text.AlignHCenter
				color: root.foreground
				font.pixelSize: 18
				font.weight: Font.DemiBold
				text: "No themes found"
			}

			BioText {
				role: "body"
				horizontalAlignment: Text.AlignHCenter
				color: Qt.alpha(root.foreground, 0.58)
				font.pixelSize: 12
				text: "Try a different search term"
			}
		}
	}

}
