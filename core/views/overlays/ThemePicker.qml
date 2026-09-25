pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets
import "../../lib/NiriAnimation.js" as NiriAnimation

// Theme picker. A large live preview renders the candidate palette on top of
// the wallpaper as a miniature shell; themes run along a film strip below,
// the wallust palette/style matrix sits in a side sheet. ↑↓ browse themes,
// → steps into the palette matrix, ← steps back out, Enter applies.
ModalWindow {
	id: root

	modalId: "theme"
	exclusiveKeyboard: true
	onModalOpened: root.reset()

	// wallust v4 remap: grid COLUMNS carry the wallust PALETTE (kmeans /
	// salience / ansi), grid ROWS carry the wallust STYLE (dark / light).
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
	property string selectedDailyProvider: "bing"
	property string dailyStatusText: ""
	property string dailyErrorText: ""
	property bool dailyLoading: false
	property bool dailyFailed: false

	readonly property string themeCatalogScriptPath: `${Quickshell.shellDir}/scripts/theme_catalog.sh`
	readonly property string applyScriptPath: `${Quickshell.shellDir}/scripts/apply_theme_selection.sh`
	readonly property string dailyScriptPath: `${Quickshell.shellDir}/scripts/wallpaper_of_day.py`
	readonly property string dailyThemeDirPath: `${Quickshell.shellDir}/scripts/themes/color_themes/Wallpaper of the day`
	readonly property string wallustConfigPath: `${Quickshell.env("HOME")}/.config/wallust/wallust.toml`
	readonly property string shaderAnimationsDir: `${Quickshell.env("HOME")}/.config/niri/animations/shaders`
	readonly property string nirimationAnimationsDir: `${Quickshell.env("HOME")}/.config/niri/animations/nirimation/animations`
	readonly property string animationStatePath: `${Quickshell.env("HOME")}/.local/state/quickshell-theme/current-animation`
	readonly property string shaderCurrentPath: `${root.shaderAnimationsDir}/.current`
	readonly property var backendOptions: ["full", "resized", "wal", "thumb", "fastresize"]
	// grid columns -> wallust palette
	readonly property var colorSpaceOptions: ["kmeans", "salience", "ansi"]
	// grid rows -> wallust style (dark section on top, light on the bottom)
	readonly property var paletteOptions: ["dark", "light"]
	readonly property var dailyProviders: [
		({ id: "bing", label: "Bing" }),
		({ id: "wallhaven", label: "Wallhaven" }),
		({ id: "moewalls", label: "MoeWalls" })
	]
	readonly property var darkPaletteOptions: ["dark"]
	readonly property var lightPaletteOptions: ["light"]
	readonly property var visualPaletteOptions: root.darkPaletteOptions.concat(root.lightPaletteOptions)
	readonly property var currentAnimationOption: {
		for (const option of root.animationOptions) {
			if (String(option.id || "") === root.selectedAnimationId) return option;
		}
		return root.animationOptions.length > 0 ? root.animationOptions[0] : null;
	}
	readonly property color activePreviewBackground: root.previewPaletteData && root.previewPaletteData.background ? root.previewPaletteData.background : Theme.layer2
	readonly property color activePreviewForeground: root.previewPaletteData && root.previewPaletteData.foreground ? root.previewPaletteData.foreground : Theme.text
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
				videoPath: parts[2],
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
			root.previewPaletteData = {};
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
			if (items.length > 0 && !root.isVariantAvailable(root.selectedColorSpace, root.selectedPalette)) {
				const preferred = root.findPreferredVariant(items);
				if (preferred) root.selectVariant(preferred.colorSpace, preferred.palette);
			}
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

	function isVariantAvailable(colorSpace, palette) {
		return root.matrixCell(colorSpace, palette) !== null;
	}

	function findPreferredVariant(items) {
		const orderedColorSpaces = [root.selectedColorSpace].concat(root.colorSpaceOptions.filter(value => value !== root.selectedColorSpace));
		const orderedPalettes = [root.selectedPalette].concat(root.visualPaletteOptions.filter(value => value !== root.selectedPalette));
		for (const palette of orderedPalettes) {
			for (const colorSpace of orderedColorSpaces) {
				for (const item of items) {
					if (item.colorSpace === colorSpace && item.palette === palette)
						return item;
				}
			}
		}
		return items.length > 0 ? items[0] : null;
	}

	function paletteSwatch(index) {
		const data = root.previewPaletteData || {};
		if (Array.isArray(data.swatches) && index >= 0 && index < data.swatches.length)
			return data.swatches[index];
		if (data.colors && data.colors[`color${index}`])
			return data.colors[`color${index}`];
		const fallbacks = [Theme.layer2, Theme.primary, Theme.layer3, Theme.text];
		return fallbacks[Math.abs(index) % fallbacks.length];
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
		if (index === -2) return data.background || Qt.alpha(Theme.bg, 0.8);
		if (index === -1) return data.foreground || Theme.text;
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
		if (root.previewPaletteStatus === "loading") return;
		if (root.previewPaletteStatus === "error") {
			const preferredFromError = root.findPreferredVariant(root.previewMatrixItems);
			if (preferredFromError) root.selectVariant(preferredFromError.colorSpace, preferredFromError.palette);
			return;
		}
		if (!root.previewMatrixLoading && root.previewMatrixItems.length > 0 && !root.isVariantAvailable(root.selectedColorSpace, root.selectedPalette)) {
			const preferred = root.findPreferredVariant(root.previewMatrixItems);
			if (preferred) root.selectVariant(preferred.colorSpace, preferred.palette);
			return;
		}
		Popups.closeModal();
		Quickshell.execDetached([
			"bash", root.applyScriptPath, theme.path,
			"--backend", root.selectedBackend,
			"--palette", root.selectedColorSpace,
			"--style", root.selectedPalette,
			"--animation", root.selectedAnimationId
		]);
	}

	function applyDailyWallpaper() {
		if (root.dailyLoading) return;
		root.dailyLoading = true;
		root.dailyFailed = false;
		root.dailyErrorText = "";
		root.dailyStatusText = `Loading ${root.selectedDailyProvider}...`;
		dailyDownloadProcess.command = [
			"python3", root.dailyScriptPath,
			"--provider", root.selectedDailyProvider
		];
		dailyDownloadProcess.running = true;
	}

	function setDailyStatus(raw) {
		try {
			const data = JSON.parse(String(raw || "{}"));
			const selected = String(data.selected_provider || data.provider || "bing");
			if (["bing", "wallhaven", "moewalls"].includes(selected))
				root.selectedDailyProvider = selected;
			root.dailyStatusText = data.date ? `Cached ${String(data.date)}` : "Downloads once per day";
		} catch (error) {
			root.dailyStatusText = "Downloads once per day";
		}
	}

	function reset() {
		root.searchText = "";
		root.currentThemeIndex = 0;
		searchInput.text = "";
		root.reloadThemes();
		root.reloadWallustConfig();
		root.reloadAnimations();
		readDailyStatusProcess.running = true;
		Qt.callLater(function() {
			searchInput.selectAll();
			searchInput.forceActiveFocus();
		});
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

	Timer {
		id: previewMatrixReloadTimer
		interval: 260
		repeat: false
		onTriggered: root.reloadPreviewMatrix()
	}

	Process {
		id: listThemesProcess
		command: ["bash", root.themeCatalogScriptPath, "list"]
		stdout: StdioCollector {
			onStreamFinished: root.setThemeEntries(text)
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
		id: readDailyStatusProcess
		command: ["python3", root.dailyScriptPath, "--status"]
		stdout: StdioCollector {
			onStreamFinished: root.setDailyStatus(text)
		}
	}

	Process {
		id: dailyDownloadProcess
		command: ["true"]
		stdout: StdioCollector {}
		stderr: StdioCollector {
			onStreamFinished: root.dailyErrorText = String(text || "").trim().split("\n").pop()
		}
		onExited: function(exitCode) {
			root.dailyLoading = false;
			if (exitCode === 0) {
				root.dailyStatusText = "Downloaded — applying theme";
				Quickshell.execDetached([
					"bash", root.applyScriptPath, root.dailyThemeDirPath,
					"--backend", root.selectedBackend,
					"--palette", root.selectedColorSpace,
					"--style", root.selectedPalette,
					"--animation", root.selectedAnimationId
				]);
				Popups.closeModal();
			} else {
				root.dailyFailed = true;
				root.dailyStatusText = root.dailyErrorText || "Download failed";
			}
		}
	}

	Process {
		id: loadPreviewPaletteProcess
		command: ["true"]
		stdout: StdioCollector {
			onStreamFinished: root.setPreviewPalette(text)
		}
	}

	Process {
		id: loadPreviewMatrixProcess
		command: ["true"]
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
	readonly property real panelWidth: Math.min(1440, root.width - 120)
	readonly property real panelHeight: Math.min(900, root.height - 100)
	readonly property color previewBg: root.previewPaletteData && root.previewPaletteData.background ? root.previewPaletteData.background : Theme.layer2
	readonly property color previewFg: root.previewPaletteData && root.previewPaletteData.foreground ? root.previewPaletteData.foreground : Theme.text
	readonly property bool paletteReady: root.previewPaletteStatus === "ready"

	component KeyHint: RowLayout {
		id: hint

		property string keys: ""
		property string label: ""

		spacing: 5

		Rectangle {
			Layout.preferredHeight: 20
			Layout.preferredWidth: Math.max(22, keyText.implicitWidth + 10)
			radius: 6
			color: Theme.layer2

			StyledText {
				id: keyText
				anchors.centerIn: parent
				text: hint.keys
				font.pixelSize: Theme.size.tiny
				font.weight: Font.Bold
			}
		}

		StyledText {
			text: hint.label
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}
	}

	Rectangle {
		id: panel

		anchors.centerIn: parent
		width: root.panelWidth
		height: root.panelHeight
		radius: Theme.radius.huge + 6
		color: Theme.base

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 22
			spacing: 18

			// ── header ────────────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 14

				ColumnLayout {
					spacing: 0

					StyledText {
						text: "Themes"
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}

					StyledText {
						text: root.searchText !== "" ? `${root.filteredThemes.length} of ${root.themes.length}` : `${root.themes.length} wallpapers`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}

				Rectangle {
					id: searchBox

					readonly property bool focused: searchInput.activeFocus

					Layout.preferredWidth: 320
					Layout.preferredHeight: 40
					Layout.leftMargin: 10
					radius: 20
					color: searchBox.focused ? Theme.layer2 : Theme.layer1
					border.width: searchBox.focused ? 1.5 : 0
					border.color: Qt.alpha(Theme.primary, 0.85)

					Behavior on color {
						ColorAnim {}
					}

					Glyph {
						x: 13
						anchors.verticalCenter: parent.verticalCenter
						icon: "magnify"
						size: 17
						color: searchBox.focused ? Theme.primary : Theme.textSubtle
					}

					TextInput {
						id: searchInput

						anchors.left: parent.left
						anchors.leftMargin: 40
						anchors.right: parent.right
						anchors.rightMargin: 14
						anchors.verticalCenter: parent.verticalCenter
						color: Theme.text
						selectionColor: Qt.alpha(Theme.primary, 0.4)
						selectedTextColor: Theme.text
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.body
						selectByMouse: true
						clip: true
						focus: true
						onTextChanged: root.searchText = text

						Keys.onUpPressed: event => {
							root.moveVertical(-1);
							event.accepted = true;
						}
						Keys.onDownPressed: event => {
							root.moveVertical(1);
							event.accepted = true;
						}
						Keys.onLeftPressed: event => {
							root.moveHorizontal(-1);
							event.accepted = true;
						}
						Keys.onRightPressed: event => {
							root.moveHorizontal(1);
							event.accepted = true;
						}
						Keys.onReturnPressed: event => {
							root.applyTheme(root.currentTheme);
							event.accepted = true;
						}
						Keys.onEnterPressed: event => {
							root.applyTheme(root.currentTheme);
							event.accepted = true;
						}
						Keys.onEscapePressed: Popups.closeModal()

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: "Filter themes"
							tone: Theme.textSubtle
							opacity: searchInput.text.length === 0 ? 1 : 0

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
						}
					}
				}

				Item {
					Layout.fillWidth: true
				}

				ColumnLayout {
					spacing: 4

					RowLayout {
						Layout.alignment: Qt.AlignRight
						spacing: 6

						SectionLabel {
							text: "Wallpaper of the day"
							Layout.rightMargin: 4
						}

						Repeater {
							model: root.dailyProviders

							delegate: Chip {
								required property var modelData

								readonly property bool current: root.selectedDailyProvider === modelData.id

								text: modelData.label
								icon: current && root.dailyLoading ? "sync" : "download"
								selected: current
								enabled: !root.dailyLoading
								opacity: enabled || current ? 1 : 0.5
								onClicked: {
									root.selectedDailyProvider = modelData.id;
									root.applyDailyWallpaper();
								}
							}
						}
					}

					StyledText {
						Layout.alignment: Qt.AlignRight
						text: root.dailyLoading || root.dailyFailed ? root.dailyStatusText : (root.dailyStatusText !== "" ? `${root.dailyStatusText} · click a source to load & apply` : "Click a source to load & apply")
						tone: root.dailyFailed ? Theme.danger : Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}

				IconButton {
					Layout.leftMargin: 4
					icon: "close"
					variant: "tonal"
					onClicked: Popups.closeModal()
				}
			}

			// ── preview + palette sheet ───────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				Layout.fillHeight: true
				spacing: 20

				ClippingRectangle {
					id: preview

					Layout.fillWidth: true
					Layout.fillHeight: true
					radius: Theme.radius.huge
					color: Theme.layer1

					Image {
						id: wallpaper

						anchors.fill: parent
						source: root.currentTheme ? root.currentTheme.previewPath : ""
						fillMode: Image.PreserveAspectCrop
						asynchronous: true
						cache: true
						smooth: true
						mipmap: true
						opacity: status === Image.Ready ? 1 : 0

						Behavior on opacity {
							Anim {}
						}
					}

					SequentialAnimation {
						id: settle

						NumberAnimation {
							target: wallpaper
							property: "scale"
							from: 1.06
							to: 1
							duration: Motion.extraLong
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.decel
						}
					}

					Connections {
						target: root
						function onCurrentThemeChanged() {
							settle.restart();
						}
					}

					Rectangle {
						anchors.fill: parent
						gradient: Gradient {
							GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.12) }
							GradientStop { position: 0.55; color: "transparent" }
							GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.66) }
						}
					}

					// miniature shell in the candidate palette
					Item {
						id: mock

						anchors.fill: parent
						opacity: root.paletteReady ? 1 : 0
						visible: root.currentTheme !== null

						Behavior on opacity {
							Anim {}
						}

						Rectangle {
							id: mockBar

							width: parent.width
							height: Math.round(Math.max(26, parent.height * 0.05))
							color: Qt.alpha(root.previewBg, 0.94)

							Behavior on color {
								ColorAnim {
									duration: Motion.medium
								}
							}

							Row {
								x: 12
								anchors.verticalCenter: parent.verticalCenter
								spacing: 8

								Rectangle {
									anchors.verticalCenter: parent.verticalCenter
									width: mockBar.height - 10
									height: width
									radius: width / 2
									color: root.paletteSwatch(4)
								}

								Repeater {
									model: 4

									delegate: Rectangle {
										required property int index

										anchors.verticalCenter: parent.verticalCenter
										width: index === 0 ? 20 : 7
										height: 7
										radius: 3.5
										color: index === 0 ? root.paletteSwatch(4) : Qt.alpha(root.previewFg, index === 1 ? 0.6 : 0.25)
									}
								}
							}

							Text {
								anchors.centerIn: parent
								text: Qt.formatDateTime(new Date(), "HH:mm")
								color: root.previewFg
								font.family: Theme.fontFamily
								font.pixelSize: Math.round(mockBar.height * 0.46)
								font.weight: Font.Bold
							}

							Row {
								anchors.right: parent.right
								anchors.rightMargin: 12
								anchors.verticalCenter: parent.verticalCenter
								spacing: 7

								Repeater {
									model: [2, 3, 5, 1]

									delegate: Rectangle {
										required property int modelData

										anchors.verticalCenter: parent.verticalCenter
										width: 9
										height: 9
										radius: 4.5
										color: root.paletteSwatch(modelData)
									}
								}
							}
						}

						PanelShape {
							id: mockPanel

							x: parent.width - width - 34
							y: mockBar.height
							width: Math.min(260, parent.width * 0.3)
							height: Math.min(200, parent.height * 0.4)
							color: Qt.alpha(root.previewBg, 0.96)
							radius: 16
							fillet: 12

							ColumnLayout {
								anchors.fill: parent
								anchors.margins: 14
								spacing: 9

								RowLayout {
									Layout.fillWidth: true
									spacing: 8

									Repeater {
										model: [4, 6]

										delegate: Rectangle {
											required property int modelData
											required property int index

											Layout.fillWidth: true
											Layout.preferredHeight: 38
											radius: index === 0 ? 12 : 19
											color: index === 0 ? Qt.alpha(root.paletteSwatch(modelData), 0.3) : Qt.alpha(root.previewFg, 0.08)

											Rectangle {
												x: 7
												anchors.verticalCenter: parent.verticalCenter
												width: 24
												height: 24
												radius: 12
												color: root.paletteSwatch(parent.modelData)
											}

											Rectangle {
												x: 38
												anchors.verticalCenter: parent.verticalCenter
												width: parent.width - 48
												height: 5
												radius: 2.5
												color: Qt.alpha(root.previewFg, 0.5)
											}
										}
									}
								}

								Rectangle {
									Layout.fillWidth: true
									Layout.preferredHeight: 22
									radius: 11
									color: Qt.alpha(root.previewFg, 0.1)

									Rectangle {
										width: parent.width * 0.62
										height: parent.height
										radius: 11
										color: root.paletteSwatch(4)
									}
								}

								Repeater {
									model: [0.82, 0.58, 0.7]

									delegate: Rectangle {
										required property real modelData
										required property int index

										Layout.preferredWidth: (mockPanel.width - 28) * modelData
										Layout.preferredHeight: 6
										radius: 3
										color: Qt.alpha(index === 1 ? root.paletteSwatch(3) : root.previewFg, index === 1 ? 0.8 : 0.28)
									}
								}
							}
						}

						Row {
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							anchors.margins: 22
							spacing: 6

							Repeater {
								model: [-2, -1, 1, 2, 3, 4, 5, 6]

								delegate: Column {
									id: swatch

									required property int modelData
									readonly property color tone: modelData === -2 ? root.previewBg : (modelData === -1 ? root.previewFg : root.paletteSwatch(modelData))

									spacing: 4

									Rectangle {
										width: 30
										height: 40
										radius: 10
										color: swatch.tone
										border.width: 1
										border.color: Qt.rgba(1, 1, 1, 0.18)

										Behavior on color {
											ColorAnim {
												duration: Motion.medium
											}
										}
									}

									Text {
										anchors.horizontalCenter: parent.horizontalCenter
										text: swatch.modelData === -2 ? "bg" : (swatch.modelData === -1 ? "fg" : `c${swatch.modelData}`)
										color: Qt.rgba(1, 1, 1, 0.75)
										font.family: Theme.fontFamily
										font.pixelSize: 9
										font.weight: Font.Bold
									}
								}
							}
						}
					}

					Rectangle {
						x: 20
						y: mockBar.height + 16
						visible: root.currentTheme !== null
						height: 24
						width: mediaText.implicitWidth + 18
						radius: 12
						color: Qt.rgba(0, 0, 0, 0.45)

						StyledText {
							id: mediaText

							anchors.centerIn: parent
							text: root.currentTheme ? String(root.currentTheme.mediaType || "video") : ""
							tone: "white"
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Bold
							font.capitalization: Font.AllUppercase
							font.letterSpacing: 1
						}
					}

					ColumnLayout {
						anchors.left: parent.left
						anchors.bottom: parent.bottom
						anchors.margins: 24
						width: parent.width * 0.55
						spacing: 2
						visible: root.currentTheme !== null

						StyledText {
							Layout.fillWidth: true
							text: root.currentTheme ? root.currentTheme.name : ""
							tone: "white"
							font.pixelSize: 30
							font.weight: Font.Bold
						}

						StyledText {
							Layout.fillWidth: true
							text: `${root.selectedColorSpace} · ${root.selectedPalette}`
							tone: Qt.rgba(1, 1, 1, 0.75)
							font.pixelSize: Theme.size.body
						}
					}

					Spinner {
						anchors.centerIn: parent
						width: 36
						height: 36
						visible: root.currentTheme !== null && root.previewPaletteStatus === "loading"
						color: "white"
					}

					EmptyState {
						anchors.centerIn: parent
						visible: root.filteredThemes.length === 0
						icon: "palette"
						title: root.themes.length === 0 ? "Loading themes…" : "No themes found"
						subtitle: root.themes.length === 0 ? "" : "Try a different search term."
					}

					MouseArea {
						anchors.fill: parent
						acceptedButtons: Qt.NoButton
						onWheel: wheel => root.moveSelection((wheel.angleDelta.y || -wheel.angleDelta.x) < 0 ? 1 : -1)
					}
				}

				// palette sheet
				ColumnLayout {
					Layout.preferredWidth: 300
					Layout.maximumWidth: 300
					Layout.fillWidth: false
					Layout.fillHeight: true
					spacing: 14

					ColumnLayout {
						spacing: 1

						StyledText {
							text: "Palette"
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
						}

						StyledText {
							text: root.variantSelectionActive ? "← back to themes · ↑↓←→ choose" : "→ to choose a palette"
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}

					Item {
						id: matrix

						readonly property real gap: 8
						readonly property real cellW: (width - gap * (root.colorSpaceOptions.length - 1)) / root.colorSpaceOptions.length
						readonly property real cellH: 84
						readonly property real headerH: 20
						readonly property real labelH: 22

						function rowY(paletteIndex) {
							return matrix.headerH + matrix.labelH + paletteIndex * (matrix.cellH + matrix.labelH + 6);
						}

						Layout.fillWidth: true
						Layout.preferredHeight: matrix.rowY(root.visualPaletteOptions.length)
						opacity: root.currentTheme ? 1 : 0.4

						Repeater {
							model: root.colorSpaceOptions

							delegate: StyledText {
								required property int index
								required property string modelData

								x: index * (matrix.cellW + matrix.gap)
								width: matrix.cellW
								height: matrix.headerH
								horizontalAlignment: Text.AlignHCenter
								text: modelData
								tone: index === root.selectedColorIndex ? Theme.primary : Theme.textMuted
								font.pixelSize: Theme.size.small
								font.weight: Font.Bold
							}
						}

						Repeater {
							model: root.visualPaletteOptions

							delegate: Item {
								id: styleRow

								required property int index
								required property string modelData

								width: matrix.width
								height: matrix.cellH + matrix.labelH
								y: matrix.rowY(index) - matrix.labelH

								RowLayout {
									width: parent.width
									height: matrix.labelH
									spacing: 6

									Glyph {
										icon: styleRow.modelData === "light" ? "weather_sunny" : "weather_night"
										size: 14
										color: Theme.textSubtle
									}

									SectionLabel {
										text: styleRow.modelData
									}
								}

								Repeater {
									model: root.colorSpaceOptions

									delegate: Rectangle {
										id: cell

										required property int index
										required property string modelData

										readonly property var cellData: root.matrixCell(cell.modelData, styleRow.modelData)
										readonly property bool available: cell.cellData !== null
										readonly property color tone: root.dataTone(cell.cellData, -2)
										readonly property color ink: root.dataTone(cell.cellData, -1)

										x: cell.index * (matrix.cellW + matrix.gap)
										y: matrix.labelH
										width: matrix.cellW
										height: matrix.cellH
										radius: Theme.radius.large
										color: cell.available ? cell.tone : Theme.layer1
										opacity: cell.available || root.previewMatrixLoading ? 1 : 0.35
										scale: cellMouse.pressed ? 0.94 : (cellMouse.containsMouse && cell.available ? 1.04 : 1)
										clip: true

										Behavior on color {
											ColorAnim {
												duration: Motion.medium
											}
										}
										Behavior on scale {
											SpatialAnim {
												duration: Motion.short
											}
										}

										Text {
											x: 10
											y: 8
											visible: cell.available
											text: "Aa"
											color: cell.ink
											font.family: Theme.fontFamily
											font.pixelSize: 17
											font.weight: Font.Bold
										}

										Row {
											anchors.left: parent.left
											anchors.right: parent.right
											anchors.bottom: parent.bottom
											anchors.margins: 8
											height: 14
											spacing: 3
											visible: cell.available

											Repeater {
												model: [1, 2, 3, 4, 5, 6]

												delegate: Rectangle {
													required property int modelData

													width: (parent.width - 15) / 6
													height: parent.height
													radius: 4
													color: root.dataSwatch(cell.cellData, modelData)
												}
											}
										}

										StyledText {
											anchors.centerIn: parent
											visible: !cell.available && !root.previewMatrixLoading
											text: "n/a"
											tone: Theme.textSubtle
											font.pixelSize: Theme.size.small
										}

										Spinner {
											anchors.centerIn: parent
											width: 18
											height: 18
											visible: !cell.available && root.previewMatrixLoading
										}

										MouseArea {
											id: cellMouse

											anchors.fill: parent
											enabled: cell.available
											hoverEnabled: true
											cursorShape: cell.available ? Qt.PointingHandCursor : Qt.ArrowCursor
											onClicked: root.selectVariant(cell.modelData, styleRow.modelData)
										}
									}
								}
							}
						}

						Rectangle {
							x: root.selectedColorIndex * (matrix.cellW + matrix.gap) - 4
							y: matrix.rowY(root.selectedPaletteIndex) - 4
							width: matrix.cellW + 8
							height: matrix.cellH + 8
							radius: Theme.radius.large + 4
							color: "transparent"
							border.width: root.variantSelectionActive ? 3 : 2
							border.color: root.variantSelectionActive ? Theme.primary : Qt.alpha(Theme.text, 0.5)

							Behavior on x {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on y {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on border.color {
								ColorAnim {}
							}
						}
					}

					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 52
						radius: Theme.radius.large
						color: Theme.layer1

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 14
							anchors.rightMargin: 14
							spacing: 10

							Glyph {
								icon: "animation_play"
								size: 18
								color: Theme.primary
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0

								SectionLabel {
									text: "Window animation"
								}

								StyledText {
									Layout.fillWidth: true
									text: root.currentAnimationOption ? root.currentAnimationOption.label : "Default"
									font.weight: Font.DemiBold
								}
							}
						}
					}

					Item {
						Layout.fillHeight: true
					}

					TextButton {
						Layout.fillWidth: true
						implicitHeight: 48
						text: root.previewPaletteStatus === "loading" ? "Reading palette…" : "Apply theme"
						icon: "check"
						variant: "filled"
						enabled: root.currentTheme !== null && root.previewPaletteStatus !== "loading"
						busy: root.previewPaletteStatus === "loading" && root.currentTheme !== null
						onActivated: root.applyTheme(root.currentTheme)
					}

					Flow {
						Layout.fillWidth: true
						spacing: 12

						KeyHint { keys: "↑↓"; label: "theme" }
						KeyHint { keys: "→"; label: "palette" }
						KeyHint { keys: "↵"; label: "apply" }
						KeyHint { keys: "Esc"; label: "close" }
					}
				}
			}

			// ── film strip ────────────────────────────────────────────────
			ListView {
				id: strip

				readonly property real itemWidth: 168

				Layout.fillWidth: true
				Layout.preferredHeight: 116
				orientation: ListView.Horizontal
				spacing: 10
				clip: true
				model: root.filteredThemes
				currentIndex: root.currentThemeIndex
				highlightRangeMode: ListView.StrictlyEnforceRange
				preferredHighlightBegin: width / 2 - itemWidth / 2
				preferredHighlightEnd: width / 2 + itemWidth / 2
				highlightMoveDuration: Motion.long
				boundsBehavior: Flickable.StopAtBounds
				cacheBuffer: 1200

				onCurrentIndexChanged: {
					if (currentIndex >= 0 && currentIndex !== root.currentThemeIndex) {
						root.variantSelectionActive = false;
						root.currentThemeIndex = currentIndex;
					}
				}

				delegate: Item {
					id: thumb

					required property var modelData
					required property int index
					readonly property bool current: thumb.index === root.currentThemeIndex

					width: strip.itemWidth
					height: strip.height

					ClippingRectangle {
						anchors.centerIn: parent
						width: parent.width
						height: parent.height - 10
						radius: Theme.radius.large
						color: Theme.layer2
						scale: thumb.current ? 1 : (thumbMouse.containsMouse ? 0.9 : 0.84)
						opacity: thumb.current ? 1 : 0.55

						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}
						Behavior on opacity {
							Anim {}
						}

						Image {
							anchors.fill: parent
							source: thumb.modelData.previewPath
							fillMode: Image.PreserveAspectCrop
							asynchronous: true
							cache: true
							smooth: true
							sourceSize: Qt.size(340, 220)
						}

						Rectangle {
							anchors.fill: parent
							gradient: Gradient {
								GradientStop { position: 0.45; color: "transparent" }
								GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.75) }
							}
						}

						StyledText {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							anchors.margins: 9
							text: thumb.modelData.name
							tone: "white"
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}

						Rectangle {
							anchors.fill: parent
							radius: Theme.radius.large
							color: "transparent"
							border.width: thumb.current ? 2.5 : 0
							border.color: Theme.primary
						}
					}

					MouseArea {
						id: thumbMouse

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							if (thumb.current) {
								root.applyTheme(thumb.modelData);
								return;
							}
							root.variantSelectionActive = false;
							root.currentThemeIndex = thumb.index;
						}
					}
				}

				MouseArea {
					anchors.fill: parent
					acceptedButtons: Qt.NoButton
					onWheel: wheel => root.moveSelection((wheel.angleDelta.y || -wheel.angleDelta.x) < 0 ? 1 : -1)
				}
			}
		}
	}
}
