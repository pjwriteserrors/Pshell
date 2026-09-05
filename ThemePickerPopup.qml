pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
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
	readonly property real variantGridHeight: Math.max(240, Math.min(stackArea.height - 24, 680))

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


    Item {
        id: stackArea
        anchors.fill: parent; anchors.margins: 12
        property bool confirmDelete: false
        Rectangle {
            id: searchBox
            width: parent.width; height: 42; radius: 21; color: Atelier.surface
            TextInput {
                id: searchField
                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20
                verticalAlignment: TextInput.AlignVCenter; color: Atelier.text; font.family: Atelier.sans; font.pixelSize: 13
                onTextChanged: root.searchText = text
                AtelierText { anchors.verticalCenter: parent.verticalCenter; text: "Find a landscape…"; visible: !parent.text; color: Atelier.muted; font.pixelSize: 13 }
                Keys.onReturnPressed: root.applyTheme(root.currentTheme)
                Keys.onEscapePressed: root.closeRequested()
                Keys.onDownPressed: root.moveSelection(1)
                Keys.onUpPressed: root.moveSelection(-1)
            }
        }
        Item {
            id: exhibition
            y: 58; width: parent.width * 0.59; height: parent.height - 58
            ClippingRectangle {
                id: artwork
                width: parent.width; height: parent.height - 118; radius: 24
                color: Atelier.surface
                Image { anchors.fill: parent; source: root.currentTheme ? root.currentTheme.previewPath : ""; fillMode: Image.PreserveAspectCrop; asynchronous: true }
                Rectangle {
                    x: 16; y: 16; width: edition.implicitWidth + 28; height: 32; radius: 16; color: Atelier.canvas
                    AtelierText { id: edition; anchors.centerIn: parent; text: "LANDSCAPE  /  " + (root.currentThemeIndex + 1) + " OF " + root.filteredThemes.length; font.family: Atelier.mono; font.pixelSize: 10 }
                }
            }
            AtelierText { y: artwork.height + 12; width: parent.width - 100; text: root.currentTheme ? root.currentTheme.name : "No landscapes found"; display: true; font.pixelSize: 28; elide: Text.ElideRight }
            Row {
                anchors.right: parent.right; y: artwork.height + 12; spacing: 8
                Repeater {
                    model: ["←", "→"]
                    delegate: Rectangle {
                        required property string modelData
                        required property int index
                        width: 36; height: 36; radius: 18; color: Atelier.surface
                        AtelierText { anchors.centerIn: parent; text: parent.modelData; font.pixelSize: 18 }
                        MouseArea { anchors.fill: parent; onClicked: root.moveSelection(parent.index === 0 ? -1 : 1) }
                    }
                }
            }
            ListView {
                y: artwork.height + 58; width: parent.width; height: 60; orientation: ListView.Horizontal; spacing: 8; clip: true
                model: root.filteredThemes
                delegate: ClippingRectangle {
                    id: thumbnail
                    required property var modelData
                    required property int index
                    width: 88; height: 56; radius: 10
                    Image { anchors.fill: parent; source: thumbnail.modelData.previewPath; fillMode: Image.PreserveAspectCrop; asynchronous: true }
                    Rectangle { anchors.fill: parent; radius: 10; color: "transparent"; border.width: thumbnail.index === root.currentThemeIndex ? 3 : 0; border.color: Atelier.accent }
                    MouseArea { anchors.fill: parent; onClicked: root.currentThemeIndex = thumbnail.index }
                }
            }
        }
        Flickable {
            x: exhibition.width + 28; y: 58; width: parent.width - x; height: parent.height - 58
            contentHeight: controls.height; clip: true
            Column {
                id: controls; width: parent.width; spacing: 12
                AtelierText { text: "Colour studies"; display: true; font.pixelSize: 28 }
                AtelierText { width: parent.width; text: "Six ways to interpret your landscape."; color: Atelier.muted; font.pixelSize: 12; wrapMode: Text.WordWrap }
                Grid {
                    width: parent.width; columns: 3; spacing: 8
                    Repeater {
                        model: 6
                        delegate: Rectangle {
                            id: study
                            required property int index
                            property string palette: root.colorSpaceOptions[index % 3]
                            property string styleName: index < 3 ? "dark" : "light"
                            property var paletteData: root.matrixCell(palette, styleName)
                            width: (controls.width - 16) / 3; height: 86; radius: 12
                            color: paletteData && paletteData.background ? paletteData.background : index < 3 ? Atelier.ink : Atelier.surface
                            border.width: root.selectedColorSpace === palette && root.selectedPalette === styleName ? 2 : 0; border.color: Atelier.accent
                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter; y: 16; spacing: 2
                                Repeater { model: 3; delegate: Rectangle { required property int index; width: 14; height: 24; radius: 7; color: study.paletteData ? root.dataSwatch(study.paletteData, index + 1) : [Atelier.sage,Atelier.gold,Atelier.accent][index] } }
                            }
                            AtelierText { anchors.horizontalCenter: parent.horizontalCenter; y: 51; text: study.palette; color: root.readableTextColor(String(study.color)); font.pixelSize: 10 }
                            AtelierText { anchors.horizontalCenter: parent.horizontalCenter; y: 66; text: study.styleName; color: root.readableTextColor(String(study.color)); font.pixelSize: 8 }
                            MouseArea { anchors.fill: parent; onClicked: root.selectVariant(study.palette, study.styleName) }
                        }
                    }
                }
                AtelierText { text: "EXTRACTION / TRANSITION"; color: Atelier.muted; font.family: Atelier.mono; font.pixelSize: 9 }
                AtelierSelect { width: parent.width; model: root.backendOptions; currentIndex: root.backendOptions.indexOf(root.selectedBackend); onActivated: root.selectedBackend = currentText }
                AtelierSelect { width: parent.width; model: root.animationOptions; textRole: "name"; currentIndex: Math.max(0, root.animationOptions.findIndex(option => option.id === root.selectedAnimationId)); onActivated: root.selectedAnimationId = root.animationOptions[currentIndex].id }
                Rectangle {
                    width: parent.width; height: 44; radius: 22; color: Atelier.accent
                    AtelierText { anchors.centerIn: parent; text: "Bring this landscape home  ↗"; color: Atelier.paper; font.pixelSize: 12 }
                    MouseArea { anchors.fill: parent; onClicked: root.applyTheme(root.currentTheme) }
                }
                AtelierText {
                    width: parent.width; text: root.deleteError || (stackArea.confirmDelete ? "Move this wallpaper to trash? Click again." : "Move landscape to trash"); color: Atelier.muted; font.pixelSize: 10; wrapMode: Text.WordWrap
                    MouseArea { anchors.fill: parent; onClicked: { if(stackArea.confirmDelete) { root.deleteThemeMedia(root.currentTheme); stackArea.confirmDelete=false; } else stackArea.confirmDelete=true; } }
                }
            }
            ScrollBar.vertical: ScrollBar {}
        }
    }
}
