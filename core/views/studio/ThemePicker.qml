pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.studio

// Theme picker. One stage shows the wallpaper in front with the shell in
// miniature on top of it, painted in the palette that is chosen in the dock
// at its corner. Below it runs the library as a film strip, or, on the
// second tab, the pictures of the day (Daily) that are already fetched, or,
// on the third, what Wallhaven and MoeWalls find (OnlineSearch), with the
// categories as chips and the other filters in a sheet (OnlineFilters).
// ←→ step through the strip, ↑↓ through the palettes, Tab changes the tab,
// Enter applies (on the third tab, a query not asked yet is asked first).
//
// The palettes come from scripts/theme_catalog.sh: one `matrix-all` run per
// opening brings every theme's matrix (cached on disk, generated in parallel
// where missing), so browsing never waits on a process.
ModalWindow {
	id: root

	modalId: "theme"
	exclusiveKeyboard: true
	onModalOpened: root.reset()

	// wallust v4 remap: "colour space" carries the wallust PALETTE (kmeans /
	// salience / ansi), "palette" carries the wallust STYLE (dark / light).
	property string view: "library"
	readonly property var views: ["library", "daily", "online"]
	readonly property int viewIndex: Math.max(0, root.views.indexOf(root.view))
	property bool filtersOpen: false
	property string searchText: ""
	property var themes: []
	property string selectedBackend: "fastresize"
	property string selectedColorSpace: "salience"
	property string selectedPalette: "dark"
	property int currentThemeIndex: 0
	property string dailyProvider: "bing"
	// the level picked for the live wallpaper of the day, by its kept path
	property var resolutionChoice: ({})
	readonly property var resolutionLevels: [
		{ value: "2160", label: "4K", w: 3840, h: 2160 },
		{ value: "1440", label: "2K", w: 2560, h: 1440 },
		{ value: "1080", label: "1080p", w: 1920, h: 1080 }
	]
	readonly property var currentResolutionOptions: root.resolutionOptions(root.currentTheme)
	readonly property string selectedResolution: {
		const theme = root.currentTheme;
		if (!theme || root.currentResolutionOptions.length === 0) return "original";
		const chosen = root.resolutionChoice[theme.path] ?? "original";
		return root.currentResolutionOptions.some(option => option.value === chosen) ? chosen : "original";
	}
	// the scaled copy being made before an apply: how far, 0 to 1
	property bool scaling: false
	property real scaleProgress: 0
	property string scalingLabel: ""
	property var scalingCommand: []
	// until the first touch, the picker stands on what the desktop wears
	property bool startPending: false
	// an apply asked for while the theme in front was still loading (its
	// download, its colours): done once it is ready, unless it is left
	property bool applyPending: false
	// Every theme's palette matrix (the wallust colours per palette x style)
	// by matrixKey, filled by one `matrix-all` run after the list and by a
	// `matrix-json` run for the theme in front when it is not there yet.
	// Stepping through the library then costs no process at all.
	property var matrixCache: ({})
	property string previewMatrixRequestKey: ""
	readonly property var previewMatrix: root.matrixCache[root.previewMatrixRequestKey] ?? null
	readonly property var previewMatrixItems: root.previewMatrix ? root.previewMatrix.items : []
	readonly property var previewMatrixMap: root.previewMatrix ? root.previewMatrix.map : ({})
	readonly property bool previewMatrixLoading: root.currentTheme !== null && root.previewMatrix === null
	// the cell of the matrix that is selected: what the preview is painted in
	readonly property var previewPaletteData: root.matrixCell(root.selectedColorSpace, root.selectedPalette) ?? ({})
	readonly property string previewPaletteStatus: {
		if (!root.currentTheme) return "idle";
		if (root.currentTheme.online && online.currentStageError !== "") return "error";
		if (root.previewMatrix === null) return "loading";
		return root.matrixCell(root.selectedColorSpace, root.selectedPalette) ? "ready" : "error";
	}

	readonly property string themeCatalogScriptPath: `${Quickshell.shellDir}/scripts/theme_catalog.sh`
	readonly property string applyScriptPath: `${Quickshell.shellDir}/scripts/apply_theme_selection.sh`
	readonly property string wallustConfigPath: `${Quickshell.env("HOME")}/.config/wallust/wallust.toml`
	readonly property var backendOptions: ["full", "resized", "wal", "thumb", "fastresize"]
	readonly property var colorSpaceOptions: ["kmeans", "salience", "ansi"]
	readonly property var paletteOptions: ["dark", "light"]
	readonly property int selectedColorIndex: Math.max(0, root.colorSpaceOptions.indexOf(root.selectedColorSpace))
	readonly property var filteredThemes: {
		const query = root.searchText.trim().toLowerCase();
		if (query === "") return root.themes;
		return root.themes.filter(theme => String(theme.name || "").toLowerCase().includes(query));
	}
	readonly property var dailyEntry: Daily.entries[root.dailyProvider] ?? null
	readonly property var currentTheme: {
		if (root.view === "online") {
			const item = online.current;
			if (!item) return null;
			const stage = online.currentStage;
			return {
				name: String(item.title || stage?.title || (item.width ? `${item.width} × ${item.height}` : "")),
				path: String(stage?.themePath ?? ""),
				previewPath: String(stage?.previewPath ?? ""),
				// Wallhaven's full picture once it is here, MoeWalls' still
				backdropPath: String(item.source === "wallhaven" && stage ? stage.previewPath : item.still),
				mediaType: String(item.mediaType || "image"),
				online: item,
				stage: stage
			};
		}
		if (root.view === "daily") {
			const entry = root.dailyEntry;
			if (!entry) return null;
			return {
				name: String(entry.headline || entry.title || ""),
				path: String(entry.theme_path || ""),
				previewPath: String(entry.preview_path || ""),
				mediaType: String(entry.media_type || "image"),
				daily: entry
			};
		}
		if (root.filteredThemes.length === 0) return null;
		const index = Math.max(0, Math.min(root.currentThemeIndex, root.filteredThemes.length - 1));
		return root.filteredThemes[index];
	}
	// the theme in front by name: it stays the same while Daily tells news
	// about the other sources
	readonly property string currentKey: {
		const theme = root.currentTheme;
		if (!theme) return "";
		if (theme.online) return `online\u001f${theme.online.source}\u001f${theme.online.id}`;
		return `${theme.path}\u001f${theme.previewPath}`;
	}

	function setThemeEntries(raw) {
		const entries = [];
		for (const line of String(raw || "").split("\n")) {
			const trimmed = line.trim();
			if (trimmed === "") continue;
			const parts = trimmed.split("\t");
			if (parts.length < 4) continue;
			// the picture of the day has a tab of its own
			if (parts[1] === Daily.themeDir) continue;
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
		root.settleStart();
		Qt.callLater(function() {
			root.reloadPreviewMatrix();
			root.prewarmMatrices();
		});
	}

	// the levels a live wallpaper of the day can be scaled down to, as
	// theme_resolution_levels in scripts/theme_paths.sh: those whose box is
	// smaller in both directions. The library is always painted as it is.
	function resolutionOptions(theme) {
		const size = root.mediaSize(theme);
		if (!size || theme.daily?.provider !== "moewalls") return [];
		const options = [{ value: "original", label: "Original" }];
		for (const level of root.resolutionLevels) {
			if (level.w < size.w && level.h < size.h) options.push({ value: level.value, label: level.label });
		}
		return options.length > 1 ? options : [];
	}

	function mediaSize(theme) {
		const w = Number(theme?.daily?.width ?? 0);
		const h = Number(theme?.daily?.height ?? 0);
		return w > 0 && h > 0 ? { w, h } : null;
	}

	function parseWallustValue(raw, key) {
		const match = String(raw || "").match(new RegExp(`^${key}\\s*=\\s*"([^"]+)"`, "m"));
		return match ? match[1] : "";
	}

	function setWallustConfig(raw) {
		const backend = root.parseWallustValue(raw, "backend");
		const palette = root.parseWallustValue(raw, "palette");
		const style = root.parseWallustValue(raw, "style");

		if (root.backendOptions.indexOf(backend) >= 0) root.selectedBackend = backend;
		if (root.colorSpaceOptions.indexOf(palette) >= 0) root.selectedColorSpace = palette;
		if (root.paletteOptions.indexOf(style) >= 0) root.selectedPalette = style;
	}

	function selectVariant(colorSpace, palette) {
		if (root.colorSpaceOptions.indexOf(colorSpace) >= 0) root.selectedColorSpace = colorSpace;
		if (root.paletteOptions.indexOf(palette) >= 0) root.selectedPalette = palette;
	}

	function matrixKey(theme, backend) {
		if (!theme) return "";
		return [String(theme.path || ""), String(theme.previewPath || ""), backend].join("\u001f");
	}

	function matrixOf(data) {
		const items = Array.isArray(data.items) ? data.items : [];
		const map = {};
		for (const item of items)
			map[`${item.colorSpace}|${item.palette}`] = item;
		return { items: items, map: map };
	}

	// the matrix of the theme in front: from the cache, or asked for
	function reloadPreviewMatrix() {
		const theme = root.currentTheme;
		// an online result has its colours once it is staged
		if (!theme || (theme.online && !theme.stage)) {
			root.previewMatrixRequestKey = "";
			return;
		}

		const key = root.matrixKey(theme, root.selectedBackend);
		root.previewMatrixRequestKey = key;
		if (root.matrixCache[key] !== undefined) {
			root.settleVariant();
			return;
		}
		if (loadPreviewMatrixProcess.running && loadPreviewMatrixProcess.key === key) return;
		loadPreviewMatrixProcess.running = false;
		loadPreviewMatrixProcess.key = key;
		loadPreviewMatrixProcess.command = [
			"bash", root.themeCatalogScriptPath, "matrix-json",
			theme.path, theme.previewPath, root.selectedBackend
		];
		loadPreviewMatrixProcess.running = true;
	}

	// an empty answer is wallust not reading this one: an empty matrix, so
	// the palettes show as missing instead of a spinner forever
	function setPreviewMatrix(key, raw) {
		let data = {};
		try {
			data = JSON.parse(String(raw || "").trim() || "{}");
		} catch (error) {
			console.warn(`Could not parse theme preview matrix: ${error}`);
		}
		const next = Object.assign({}, root.matrixCache);
		next[key] = root.matrixOf(data);
		root.matrixCache = next;
		if (key === root.previewMatrixRequestKey) root.settleVariant();
	}

	// every theme's matrix in one go, so the other themes are ready before
	// they are stepped to; what the current theme asked for is shared
	function prewarmMatrices() {
		if (root.themes.length === 0) return;
		prewarmMatricesProcess.running = false;
		prewarmMatricesProcess.command = ["bash", root.themeCatalogScriptPath, "matrix-all", root.selectedBackend];
		prewarmMatricesProcess.running = true;
	}

	function setAllMatrices(raw) {
		const text = String(raw || "").trim();
		if (text === "") return;
		try {
			const data = JSON.parse(text);
			const next = Object.assign({}, root.matrixCache);
			for (const matrix of (Array.isArray(data.matrices) ? data.matrices : []))
				next[root.matrixKey({ path: matrix.themePath, previewPath: matrix.previewPath }, matrix.backend)] = root.matrixOf(matrix);
			root.matrixCache = next;
			root.settleVariant();
		} catch (error) {
			console.warn(`Could not parse the theme matrices: ${error}`);
		}
	}

	// a variant the theme does not have falls back to the nearest one it has
	function settleVariant() {
		const items = root.previewMatrixItems;
		if (items.length > 0 && !root.matrixCell(root.selectedColorSpace, root.selectedPalette)) {
			const preferred = root.findPreferredVariant(items);
			if (preferred) root.selectVariant(preferred.colorSpace, preferred.palette);
		}
	}

	function matrixCell(colorSpace, palette) {
		return root.previewMatrixMap[`${colorSpace}|${palette}`] || null;
	}

	function findPreferredVariant(items) {
		const orderedColorSpaces = [root.selectedColorSpace].concat(root.colorSpaceOptions.filter(value => value !== root.selectedColorSpace));
		const orderedPalettes = [root.selectedPalette].concat(root.paletteOptions.filter(value => value !== root.selectedPalette));
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
		const fallbacks = [Theme.layer2, Theme.primary, Theme.layer3, Theme.text];
		return fallbacks[Math.abs(index) % fallbacks.length];
	}

	function dataSwatch(data, index) {
		if (data && Array.isArray(data.swatches) && index >= 0 && index < data.swatches.length)
			return data.swatches[index];
		return "transparent";
	}

	function selectView(view) {
		root.startPending = false;
		root.filtersOpen = false;
		root.view = view;
		if (view === "daily") {
			if (!root.dailyEntry) root.dailyProvider = root.firstDailyProvider();
			Daily.refresh(false);
		}
		// the search field holds the library's filter or the online query
		const text = view === "online" ? online.query : root.searchText;
		if (searchInput.text !== text) searchInput.text = text;
		if (view === "online") {
			if (!online.searched) online.search();
			else online.stageSoon();
		}
	}

	function stepView(delta) {
		root.selectView(root.views[(root.viewIndex + delta + root.views.length) % root.views.length]);
	}

	// Enter: a query that was not asked yet is asked, else what is in front
	// is applied
	function accept() {
		if (root.view === "online" && (online.query.trim() !== online.askedQuery || online.error !== "")) {
			online.search();
			return;
		}
		root.applyTheme(root.currentTheme);
	}

	function dismiss() {
		if (root.applyPending) root.applyPending = false;
		else if (root.scaling) root.cancelScaling();
		else if (online.saving) online.cancelSave();
		else if (root.filtersOpen) root.filtersOpen = false;
		else Popups.closeModal();
	}

	function firstDailyProvider() {
		const source = Daily.sources.find(source => Daily.entries[source.id]);
		return source ? source.id : Daily.sources[0].id;
	}

	// stands on what the desktop wears, as long as nothing was touched
	function settleStart() {
		if (!root.startPending) return;
		if (Daily.applied.provider) {
			root.view = "daily";
			root.dailyProvider = Daily.applied.provider;
			return;
		}
		root.view = "library";
		const index = root.filteredThemes.findIndex(theme => theme.path === currentDirFile.text().trim());
		if (index >= 0) root.currentThemeIndex = index;
	}

	function syncCurrentThemeIndex() {
		if (root.filteredThemes.length === 0) {
			root.currentThemeIndex = -1;
			return;
		}

		if (root.currentThemeIndex < 0 || root.currentThemeIndex >= root.filteredThemes.length)
			root.currentThemeIndex = 0;
	}

	// a step along the strip
	function move(delta) {
		root.startPending = false;
		if (root.view === "online") {
			online.move(delta);
			return;
		}
		if (root.view === "daily") {
			const sources = Daily.sources.filter(source => Daily.entries[source.id]);
			if (sources.length === 0) return;
			const index = sources.findIndex(source => source.id === root.dailyProvider);
			root.dailyProvider = sources[Math.max(0, Math.min(sources.length - 1, index + delta))].id;
			return;
		}
		if (root.filteredThemes.length === 0) return;
		root.currentThemeIndex = Math.max(0, Math.min(root.filteredThemes.length - 1, root.currentThemeIndex + delta));
	}

	// a step through the palettes the theme has
	function movePalette(delta) {
		const count = root.colorSpaceOptions.length;
		for (let step = 1; step <= count; step += 1) {
			const colorSpace = root.colorSpaceOptions[(root.selectedColorIndex + delta * step + count * step) % count];
			if (root.matrixCell(colorSpace, root.selectedPalette)) {
				root.selectedColorSpace = colorSpace;
				return;
			}
		}
	}

	function applyTheme(theme) {
		if (!theme) return;
		if (root.previewPaletteStatus === "loading") {
			root.applyPending = theme === root.currentTheme;
			return;
		}
		root.applyPending = false;
		if (root.previewPaletteStatus === "error") {
			const preferred = root.findPreferredVariant(root.previewMatrixItems);
			if (preferred) root.selectVariant(preferred.colorSpace, preferred.palette);
			return;
		}
		const look = [
			"--backend", root.selectedBackend,
			"--palette", root.selectedColorSpace,
			"--style", root.selectedPalette
		];
		// an online result is worn from memory, and forgotten once left
		if (theme.online) {
			online.wear(theme.online, path => {
				Popups.closeModal();
				Quickshell.execDetached(["bash", root.applyScriptPath, path].concat(look));
			});
			return;
		}
		// the picture that is kept becomes the library's theme of the day
		const apply = theme.daily ? [
			"sh", "-c", 'python3 "$1" --provider "$2" --cached >/dev/null && shift 2 && exec bash "$@"', "sh",
			Daily.script, theme.daily.provider, root.applyScriptPath, Daily.themeDir
		].concat(look, ["--resolution", root.selectedResolution]) : ["bash", root.applyScriptPath, theme.path].concat(look);
		if (root.selectedResolution === "original") {
			Popups.closeModal();
			Quickshell.execDetached(apply);
			return;
		}
		// the scaled copy is made from the kept file here first, with the bar
		// on the stage; the apply then finds it ready (it is keyed by the
		// file, and the library's theme of the day is a hard link of it)
		if (root.scaling) return;
		const level = root.resolutionLevels.find(level => level.value === root.selectedResolution);
		root.scalingLabel = level ? level.label : root.selectedResolution;
		root.scalingCommand = apply;
		root.scaleProgress = 0;
		root.scaling = true;
		scaleProcess.command = ["bash", root.themeCatalogScriptPath, "scale", theme.path, root.selectedResolution];
		scaleProcess.running = true;
	}

	function cancelScaling() {
		root.scaling = false;
		scaleProcess.running = false;
	}

	function scalingFinished(ok) {
		root.scaling = false;
		if (!ok) return;
		Popups.closeModal();
		Quickshell.execDetached(root.scalingCommand);
	}

	function reset() {
		root.cancelScaling();
		root.applyPending = false;
		root.filtersOpen = false;
		root.resolutionChoice = ({});
		root.searchText = "";
		root.currentThemeIndex = 0;
		searchInput.text = "";
		root.startPending = true;
		currentDirFile.reload();
		Daily.reload();
		Daily.refresh(false);
		root.settleStart();
		listThemesProcess.running = true;
		readWallustConfigProcess.running = true;
		Qt.callLater(() => searchInput.forceActiveFocus());
	}

	onFilteredThemesChanged: syncCurrentThemeIndex()
	onCurrentKeyChanged: {
		root.applyPending = false;
		root.reloadPreviewMatrix();
	}
	onPreviewPaletteStatusChanged: {
		if (root.previewPaletteStatus === "loading" || !root.applyPending) return;
		root.applyPending = false;
		if (root.previewPaletteStatus === "ready") Qt.callLater(() => root.applyTheme(root.currentTheme));
	}

	// "4.2 / 6.7 MB · 3 s left" of a download that started at `started`
	function downloadText(bytes, total, started) {
		if (total <= 0) return "";
		const mb = value => (value / 1048576).toFixed(value < 10485760 ? 1 : 0);
		let text = `${mb(bytes)} / ${mb(total)} MB`;
		const elapsed = (Date.now() - started) / 1000;
		if (bytes > 0 && bytes < total && elapsed > 0.5) {
			const left = Math.ceil((total - bytes) / (bytes / elapsed));
			text += left >= 60 ? ` · ${Math.floor(left / 60)} min ${left % 60} s left` : ` · ${left} s left`;
		}
		return text;
	}
	onSelectedBackendChanged: {
		root.reloadPreviewMatrix();
		root.prewarmMatrices();
	}

	Connections {
		target: Daily
		function onAppliedChanged() {
			root.settleStart();
		}
	}

	OnlineSearch {
		id: online

		// once the bindings that read it have followed
		onCurrentStageChanged: Qt.callLater(root.reloadPreviewMatrix)
		onQueryChanged: if (root.view === "online" && searchInput.text !== online.query) searchInput.text = online.query
	}

	// what was looked at online is not kept
	onShownChanged: if (!root.shown) online.forget()
	// the keyboard goes back to the search when the filters fold away
	onFiltersOpenChanged: if (!root.filtersOpen) searchInput.forceActiveFocus()

	FileView {
		id: currentDirFile

		path: `${Quickshell.env("HOME")}/.local/state/quickshell-theme/current-theme-dir`
		printErrors: false
	}

	Process {
		id: listThemesProcess
		command: ["bash", root.themeCatalogScriptPath, "list"]
		stdout: StdioCollector {
			onStreamFinished: root.setThemeEntries(text)
		}
	}

	Process {
		id: scaleProcess

		command: ["true"]
		stdout: SplitParser {
			onRead: line => {
				const match = String(line).match(/^progress ([0-9.]+)$/);
				if (match) root.scaleProgress = Math.max(0, Math.min(1, Number(match[1])));
			}
		}
		// a run that was stopped (Esc, a new opening) says nothing
		onExited: (exitCode, exitStatus) => {
			if (root.scaling) root.scalingFinished(exitCode === 0 && exitStatus === 0);
		}
	}

	Process {
		id: readWallustConfigProcess
		command: ["cat", root.wallustConfigPath]
		stdout: StdioCollector {
			onStreamFinished: root.setWallustConfig(text)
		}
	}

	Process {
		id: loadPreviewMatrixProcess

		// the matrixKey this run was started for
		property string key: ""

		command: ["true"]
		// a run that was stopped for the next theme has nothing to say
		onExited: (exitCode, exitStatus) => {
			if (exitStatus === 0) root.setPreviewMatrix(loadPreviewMatrixProcess.key, matrixText.text);
		}
		stdout: StdioCollector {
			id: matrixText
		}
	}

	Process {
		id: prewarmMatricesProcess
		command: ["true"]
		stdout: StdioCollector {
			onStreamFinished: root.setAllMatrices(text)
		}
	}

	readonly property real panelWidth: Math.min(1440, root.width - 120)
	readonly property real panelHeight: Math.min(900, root.height - 170)
	readonly property color previewBg: root.previewPaletteData && root.previewPaletteData.background ? root.previewPaletteData.background : Theme.layer2
	readonly property color previewFg: root.previewPaletteData && root.previewPaletteData.foreground ? root.previewPaletteData.foreground : Theme.text
	readonly property bool paletteReady: root.previewPaletteStatus === "ready"

	// A picture of the strip: it grows and lights up when it is the one in
	// front, and its image fades in once it is read.
	component Thumb: Item {
		id: thumb

		property string source: ""
		property string title: ""
		property string label: ""
		property bool current: false
		property bool busy: false
		property bool worn: false
		property bool missing: false
		signal clicked

		ClippingRectangle {
			anchors.centerIn: parent
			width: parent.width
			height: parent.height - 10
			radius: Theme.radius.large
			color: Theme.layer2
			scale: thumb.current ? 1 : (thumbMouse.containsMouse ? 0.95 : 0.9)
			opacity: thumb.current || thumbMouse.containsMouse ? 1 : 0.6

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
				source: thumb.source
				fillMode: Image.PreserveAspectCrop
				asynchronous: true
				cache: true
				smooth: true
				sourceSize: Qt.size(680, 220)
				opacity: status === Image.Ready ? 1 : 0

				Behavior on opacity {
					Anim {}
				}
			}

			Rectangle {
				anchors.fill: parent
				gradient: Gradient {
					GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, thumb.label !== "" ? 0.35 : 0) }
					GradientStop { position: 0.45; color: "transparent" }
					GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.75) }
				}
			}

			Glyph {
				anchors.centerIn: parent
				visible: thumb.missing
				icon: "wifi_off"
				size: 22
				color: Theme.textFaint
			}

			SectionLabel {
				x: 11
				y: 9
				visible: thumb.label !== ""
				text: thumb.label
				tone: thumb.missing ? Theme.textSubtle : Qt.rgba(1, 1, 1, 0.9)
				surface: thumb.missing ? Theme.layer2 : "transparent"
			}

			Spinner {
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 9
				width: 14
				height: 14
				visible: thumb.busy
				color: "white"
			}

			Rectangle {
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 8
				width: 18
				height: 18
				radius: 9
				color: Theme.primary
				scale: thumb.worn && !thumb.busy ? 1 : 0

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: "check"
					size: 12
					color: Theme.onPrimary
				}
			}

			StyledText {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 10
				text: thumb.title
				tone: "white"
				surface: "transparent"
				elide: Text.ElideRight
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			Rectangle {
				anchors.fill: parent
				radius: Theme.radius.large
				color: "transparent"
				border.width: 2.5
				border.color: Theme.primary
				opacity: thumb.current ? 1 : 0

				Behavior on opacity {
					Anim {}
				}
			}
		}

		MouseArea {
			id: thumbMouse

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: thumb.clicked()
		}
	}

	StudioTabs {}

	Rectangle {
		id: panel

		anchors.centerIn: parent
		anchors.verticalCenterOffset: 25
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
			anchors.margins: 20
			spacing: 16

			// ── header ────────────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 12

				Segmented {
					Layout.preferredWidth: 372
					Layout.preferredHeight: 40
					options: [
						{ value: "library", label: Words.of("wallpaper.library", "Library"), icon: "image_multiple" },
						{ value: "daily", label: Words.of("wallpaper.today", "Today"), icon: "calendar_today" },
						{ value: "online", label: Words.of("wallpaper.online", "Online"), icon: "earth" }
					]
					current: root.view
					onSelected: value => root.selectView(value)
				}

				Rectangle {
					id: searchBox

					readonly property bool shown: root.view !== "daily"

					property real span: searchBox.shown ? 300 : 0

					Layout.preferredWidth: searchBox.span
					Layout.minimumWidth: Math.min(searchBox.span, 140)
					Layout.maximumWidth: searchBox.span
					Layout.fillWidth: true
					Layout.preferredHeight: 40
					radius: 20
					color: Theme.layer1
					opacity: searchBox.shown ? 1 : 0
					visible: searchBox.span > 0.5
					clip: true

					Behavior on span {
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on opacity {
						Anim {}
					}

					Glyph {
						x: 13
						anchors.verticalCenter: parent.verticalCenter
						icon: "magnify"
						size: 17
						color: searchInput.text !== "" ? Theme.primary : Theme.textSubtle
					}

					// holds the keyboard on both tabs
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
						readOnly: !searchBox.shown
						clip: true
						focus: true
						onTextChanged: {
							if (text !== "") root.startPending = false;
							if (root.view === "online") {
								if (online.query === text) return;
								online.query = text;
								online.searchSoon();
							} else {
								root.searchText = text;
							}
						}

						Keys.onLeftPressed: root.move(-1)
						Keys.onRightPressed: root.move(1)
						Keys.onUpPressed: root.movePalette(-1)
						Keys.onDownPressed: root.movePalette(1)
						Keys.onTabPressed: root.stepView(1)
						Keys.onBacktabPressed: root.stepView(-1)
						Keys.onReturnPressed: root.accept()
						Keys.onEnterPressed: root.accept()
						Keys.onEscapePressed: root.dismiss()

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: root.view === "online" ? `Search ${online.source === "wallhaven" ? "Wallhaven" : "MoeWalls"}` : "Search"
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

				// where the online tab searches
				Segmented {
					id: sourceSwitch

					readonly property bool shown: root.view === "online"

					Layout.preferredWidth: sourceSwitch.shown ? 240 : 0
					Layout.preferredHeight: 40
					opacity: sourceSwitch.shown ? 1 : 0
					visible: Layout.preferredWidth > 0.5
					clip: true
					options: online.sources
					current: online.source
					onSelected: value => online.setSource(value)

					Behavior on Layout.preferredWidth {
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on opacity {
						Anim {}
					}
				}

				Item {
					Layout.fillWidth: true
				}

				// the filters online, the asking again today: one place
				Item {
					implicitWidth: 34
					implicitHeight: 34

				IconButton {
					id: filtersButton

					anchors.centerIn: parent
					icon: "tune_variant"
					variant: "tonal"
					checked: root.filtersOpen
					opacity: root.view === "online" ? 1 : 0
					scale: root.view === "online" ? 1 : 0.8
					visible: opacity > 0
					onClicked: root.filtersOpen = !root.filtersOpen

					Behavior on opacity {
						Anim {}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					// how many filters differ from the defaults
					Rectangle {
						x: parent.width - width + 3
						y: -3
						width: Math.max(16, badgeText.implicitWidth + 8)
						height: 16
						radius: 8
						color: Theme.primary
						border.width: 2
						border.color: Theme.base
						scale: online.activeFilters > 0 && !root.filtersOpen ? 1 : 0

						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						StyledText {
							id: badgeText

							anchors.centerIn: parent
							text: String(online.activeFilters)
							tone: Theme.onPrimary
							surface: Theme.primary
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Bold
						}
					}
				}

				IconButton {
					id: refreshButton

					anchors.centerIn: parent
					icon: "refresh"
					variant: "tonal"
					opacity: root.view === "daily" ? 1 : 0
					visible: opacity > 0
					onClicked: Daily.refresh(true)

					Behavior on opacity {
						Anim {}
					}

					// turns while the sources are asked, and comes to rest upright
					RotationAnimator on rotation {
						running: Daily.fetching
						loops: Animation.Infinite
						from: 0
						to: 360
						duration: 900
						onRunningChanged: if (!running) refreshButton.rotation = 0
					}
				}
				}

				IconButton {
					icon: "close"
					variant: "tonal"
					onClicked: Popups.closeModal()
				}
			}

			// ── the categories online, as chips ──────────────────────────
			Item {
				id: chipRow

				readonly property bool shown: root.view === "online"
				readonly property bool wallhaven: online.source === "wallhaven"
				// Wallhaven: its three categories, then topics that fill the
				// query; MoeWalls: its categories
				readonly property var chips: chipRow.wallhaven
					? online.wallhavenCategories.map(category => ({ kind: "category", value: category.value, label: category.label }))
						.concat([{ kind: "divider" }])
						.concat(online.wallhavenTopics.map(topic => ({ kind: "topic", value: topic, label: topic })))
					: online.moewallsCategories.map(category => ({ kind: "moewalls", value: category.value, label: category.label }))

				Layout.fillWidth: true
				Layout.preferredHeight: chipRow.shown ? 30 : 0
				Layout.topMargin: chipRow.shown ? 0 : -16
				opacity: chipRow.shown ? 1 : 0
				visible: Layout.preferredHeight > 0.5
				clip: true

				Behavior on Layout.preferredHeight {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on Layout.topMargin {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					Anim {}
				}

				ListView {
					id: chipList

					anchors.fill: parent
					orientation: ListView.Horizontal
					spacing: 6
					boundsBehavior: Flickable.StopAtBounds
					model: chipRow.chips
					// the chips change with the source: they come in anew
					onModelChanged: chipsIn.restart()

					delegate: Item {
						id: chipCell

						required property var modelData
						required property int index

						width: chipCell.modelData.kind === "divider" ? 13 : chip.implicitWidth
						height: 30

						Rectangle {
							anchors.centerIn: parent
							visible: chipCell.modelData.kind === "divider"
							width: 1
							height: 16
							color: Theme.outline
						}

						Chip {
							id: chip

							visible: chipCell.modelData.kind !== "divider"
							height: 30
							text: chipCell.modelData.label ?? ""
							selected: {
								const data = chipCell.modelData;
								if (data.kind === "category") return online.wallhaven.categories.indexOf(data.value) >= 0;
								if (data.kind === "topic") return online.query.trim().toLowerCase() === String(data.value).toLowerCase();
								return online.moewalls.category === data.value;
							}
							onClicked: {
								const data = chipCell.modelData;
								if (data.kind === "category") {
									online.toggle("categories", data.value, true);
								} else if (data.kind === "topic") {
									online.query = chip.selected ? "" : data.value;
									online.search();
								} else {
									online.set("category", data.value);
								}
							}
						}
					}

					MouseArea {
						anchors.fill: parent
						acceptedButtons: Qt.NoButton
						onWheel: wheel => chipList.flick((wheel.angleDelta.y || wheel.angleDelta.x) * 6, 0)
					}
				}

				ParallelAnimation {
					id: chipsIn

					NumberAnimation {
						target: chipList
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.standard
					}

					NumberAnimation {
						target: chipShift
						property: "x"
						from: 24
						to: 0
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.decel
					}
				}

				transform: Translate {
					id: chipShift
				}
			}

			// ── stage ─────────────────────────────────────────────────────
			ClippingRectangle {
				id: stage

				Layout.fillWidth: true
				Layout.fillHeight: true
				radius: Theme.radius.huge
				color: Theme.layer1

				// the wallpaper in front: a new one fades in over the last
				Item {
					id: backdrop

					readonly property string source: root.currentTheme ? (root.currentTheme.backdropPath ?? root.currentTheme.previewPath) : ""
					property Image front: backdropA
					// the same one sharper (an online result's full picture after
					// its thumbnail) only fades over
					property string revealedKey: ""

					function reveal(layer) {
						const last = layer === backdropA ? backdropB : backdropA;
						rise.stop();
						rise.zoom = backdrop.revealedKey === root.currentKey ? 1 : 1.06;
						backdrop.revealedKey = root.currentKey;
						last.opacity = 1;
						last.z = 0;
						layer.z = 1;
						layer.opacity = 0;
						backdrop.front = layer;
						rise.target = layer;
						rise.start();
					}

					function arrived(layer) {
						if (layer.status === Image.Ready && layer !== backdrop.front && layer.wanted === backdrop.source)
							backdrop.reveal(layer);
					}

					// the layer behind is loaded, and comes to the front when read
					onSourceChanged: {
						if (backdrop.source === "" || backdrop.front.wanted === backdrop.source) return;
						const next = backdrop.front === backdropA ? backdropB : backdropA;
						if (next.wanted === backdrop.source) {
							backdrop.arrived(next);
							return;
						}
						next.wanted = backdrop.source;
						next.source = backdrop.source;
					}

					anchors.fill: parent
					opacity: backdrop.source !== "" ? 1 : 0

					Behavior on opacity {
						Anim {}
					}

					Image {
						id: backdropA

						property string wanted: ""

						anchors.fill: parent
						// a screen's worth is plenty for the backdrop
						sourceSize: Qt.size(2560, 2560)
						fillMode: Image.PreserveAspectCrop
						asynchronous: true
						smooth: true
						mipmap: true
						opacity: 0
						onStatusChanged: backdrop.arrived(backdropA)
					}

					Image {
						id: backdropB

						property string wanted: ""

						anchors.fill: parent
						sourceSize: Qt.size(2560, 2560)
						fillMode: Image.PreserveAspectCrop
						asynchronous: true
						smooth: true
						mipmap: true
						opacity: 0
						onStatusChanged: backdrop.arrived(backdropB)
					}

					ParallelAnimation {
						id: rise

						property Image target: null
						property real zoom: 1.06

						NumberAnimation {
							target: rise.target
							property: "opacity"
							to: 1
							duration: Motion.long
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.standard
						}

						NumberAnimation {
							target: rise.target
							property: "scale"
							from: rise.zoom
							to: 1
							duration: Motion.extraLong
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.decel
						}
					}
				}

				// MoeWalls' preview of a live wallpaper, over its still once it runs
				Video {
					id: livePreview

					readonly property string wanted: root.shown && root.view === "online" ? String(root.currentTheme?.stage?.video ?? "") : ""

					anchors.fill: parent
					source: livePreview.wanted
					muted: true
					loops: MediaPlayer.Infinite
					fillMode: VideoOutput.PreserveAspectCrop
					opacity: livePreview.wanted !== "" && livePreview.playbackState === MediaPlayer.PlayingState && livePreview.position > 0 ? 1 : 0
					visible: opacity > 0
					// once the source has followed
					onWantedChanged: Qt.callLater(() => {
						if (livePreview.wanted !== "") livePreview.play();
						else livePreview.stop();
					})

					Behavior on opacity {
						Anim {
							duration: Motion.long
						}
					}
				}

				Rectangle {
					anchors.fill: parent
					gradient: Gradient {
						GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.12) }
						GradientStop { position: 0.5; color: "transparent" }
						GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.72) }
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
				}

				// what is in front
				ColumnLayout {
					id: caption

					readonly property var daily: root.currentTheme?.daily ?? null
					readonly property var online: root.currentTheme?.online ?? null
					readonly property string link: caption.daily?.source_url || caption.online?.url || ""

					anchors.left: parent.left
					anchors.right: dock.left
					anchors.bottom: parent.bottom
					anchors.leftMargin: 26
					anchors.rightMargin: 40
					anchors.bottomMargin: 24
					spacing: 3
					visible: root.currentTheme !== null

					transform: Translate {
						id: captionShift
					}

					RowLayout {
						Layout.bottomMargin: 4
						spacing: 8
						visible: caption.daily !== null || caption.online !== null || root.currentTheme?.mediaType === "video"

						Rectangle {
							implicitHeight: 24
							implicitWidth: captionLabel.implicitWidth + 20
							radius: 12
							color: Qt.rgba(0, 0, 0, 0.45)

							StyledText {
								id: captionLabel

								anchors.centerIn: parent
								text: {
									const daily = caption.daily;
									const found = caption.online;
									if (found) {
										const source = online.sources.find(source => source.value === found.source);
										return [source ? source.label : "", found.category.replace("-", " "), found.width ? `${found.width} × ${found.height}` : "", found.mediaType === "video" ? "Live" : ""].filter(Boolean).join("  ·  ");
									}
									if (!daily) return "Live";
									const source = Daily.sources.find(source => source.id === daily.provider);
									return [source ? source.label : "", daily.date_label, daily.media_type === "video" ? "Live" : ""].filter(Boolean).join("  ·  ");
								}
								tone: "white"
								surface: "transparent"
								font.pixelSize: Theme.size.tiny
								font.weight: Font.Bold
								font.capitalization: Font.AllUppercase
								font.letterSpacing: 1
							}
						}

						// pictures like this one (Wallhaven)
						Rectangle {
							implicitWidth: 24
							implicitHeight: 24
							radius: 12
							visible: caption.online?.source === "wallhaven"
							color: Qt.rgba(0, 0, 0, similarMouse.containsMouse ? 0.7 : 0.45)

							Behavior on color {
								ColorAnim {}
							}

							Glyph {
								anchors.centerIn: parent
								icon: "image_multiple"
								size: 13
								color: "white"
								surface: "transparent"
							}

							MouseArea {
								id: similarMouse

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: online.searchFor(`like:${caption.online.id}`)
							}
						}

						Rectangle {
							implicitWidth: 24
							implicitHeight: 24
							radius: 12
							visible: caption.link !== ""
							color: Qt.rgba(0, 0, 0, linkMouse.containsMouse ? 0.7 : 0.45)

							Behavior on color {
								ColorAnim {}
							}

							Glyph {
								anchors.centerIn: parent
								icon: "open_in_new"
								size: 13
								color: "white"
								surface: "transparent"
							}

							MouseArea {
								id: linkMouse

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: {
									Qt.openUrlExternally(caption.link);
									Popups.closeModal();
								}
							}
						}
					}

					StyledText {
						Layout.fillWidth: true
						text: root.currentTheme ? root.currentTheme.name : ""
						tone: "white"
						surface: "transparent"
						elide: Text.ElideRight
						font.pixelSize: 30
						font.weight: Font.Bold
					}

					// online: how liked it is, and its tags to search by
					RowLayout {
						Layout.topMargin: 2
						spacing: 14
						visible: caption.online !== null && (caption.online.views > 0 || !!root.currentTheme?.stage?.uploader)

						Repeater {
							model: caption.online ? [
								{ icon: "eye_outline", text: caption.online.views > 0 ? caption.online.views.toLocaleString(Qt.locale(), "f", 0) : "" },
								{ icon: "heart_outline", text: caption.online.favorites > 0 ? caption.online.favorites.toLocaleString(Qt.locale(), "f", 0) : "" },
								{ icon: "account_outline", text: String(root.currentTheme?.stage?.uploader ?? "") }
							].filter(stat => stat.text !== "") : []

							delegate: Item {
								id: stat

								required property var modelData
								readonly property bool uploader: modelData.icon === "account_outline"

								implicitWidth: statRow.implicitWidth
								implicitHeight: statRow.implicitHeight

								Row {
									id: statRow

									spacing: 5

									Glyph {
										anchors.verticalCenter: parent.verticalCenter
										icon: stat.modelData.icon
										size: 14
										color: Qt.rgba(1, 1, 1, 0.75)
										surface: "transparent"
									}

									StyledText {
										anchors.verticalCenter: parent.verticalCenter
										text: stat.modelData.text
										tone: Qt.rgba(1, 1, 1, stat.uploader && uploaderMouse.containsMouse ? 1 : 0.8)
										surface: "transparent"
										font.pixelSize: Theme.size.label
										font.underline: stat.uploader && uploaderMouse.containsMouse
									}
								}

								// an uploader's other pictures
								MouseArea {
									id: uploaderMouse

									anchors.fill: parent
									enabled: stat.uploader
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onClicked: online.searchFor(`@${stat.modelData.text}`)
								}
							}
						}
					}

					Flow {
						id: tagFlow

						readonly property var tags: (caption.online?.tags ?? root.currentTheme?.stage?.tags ?? []).slice(0, 10)

						Layout.fillWidth: true
						Layout.maximumWidth: 760
						Layout.topMargin: 8
						// one line: what does not fit is left out
						Layout.preferredHeight: 26
						spacing: 6
						clip: true
						visible: tagFlow.tags.length > 0
						opacity: visible ? 1 : 0

						Behavior on opacity {
							Anim {}
						}

						Repeater {
							model: tagFlow.tags

							delegate: Rectangle {
								id: tag

								required property var modelData

								width: tagText.implicitWidth + 20
								height: 26
								radius: 13
								color: Qt.rgba(0, 0, 0, tagMouse.containsMouse ? 0.62 : 0.4)
								scale: tagMouse.pressed ? 0.94 : 1

								Behavior on color {
									ColorAnim {}
								}
								Behavior on scale {
									SpatialAnim {
										duration: Motion.short
									}
								}

								StyledText {
									id: tagText

									anchors.centerIn: parent
									text: `#${tag.modelData.name}`
									tone: Qt.rgba(1, 1, 1, 0.88)
									surface: "transparent"
									font.pixelSize: Theme.size.label
								}

								MouseArea {
									id: tagMouse

									anchors.fill: parent
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onClicked: online.searchFor(tag.modelData.name)
								}
							}
						}
					}

					StyledText {
						Layout.topMargin: 4
						visible: online.currentStageError !== "" && caption.online !== null
						text: online.currentStageError
						tone: Qt.rgba(1, 0.75, 0.72, 1)
						surface: "transparent"
						font.pixelSize: Theme.size.label
					}

					// the size it is painted at: its own, or scaled down
					RowLayout {
						Layout.topMargin: 6
						Layout.bottomMargin: 2
						spacing: 10
						visible: root.currentResolutionOptions.length > 0

						Rectangle {
							implicitHeight: 32
							implicitWidth: sizeLabel.implicitWidth + 24
							radius: 16
							color: Qt.rgba(0, 0, 0, 0.45)

							StyledText {
								id: sizeLabel

								anchors.centerIn: parent
								text: {
									const size = root.mediaSize(root.currentTheme);
									return size ? `${size.w} × ${size.h}` : "";
								}
								tone: "white"
								surface: "transparent"
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
							}
						}

						Segmented {
							Layout.preferredWidth: root.currentResolutionOptions.length * 82
							Layout.preferredHeight: 32
							enabled: !root.scaling
							color: Qt.alpha(Theme.base, 0.85)
							options: root.currentResolutionOptions
							current: root.selectedResolution
							onSelected: value => {
								const next = Object.assign({}, root.resolutionChoice);
								next[root.currentTheme.path] = value;
								root.resolutionChoice = next;
							}
						}
					}

					StyledText {
						Layout.fillWidth: true
						visible: text !== ""
						text: [caption.daily?.image_title, caption.daily?.credit].filter(Boolean).join("  ·  ")
						tone: Qt.rgba(1, 1, 1, 0.8)
						surface: "transparent"
						elide: Text.ElideRight
						font.pixelSize: Theme.size.body
					}

					StyledText {
						Layout.fillWidth: true
						Layout.maximumWidth: 720
						Layout.topMargin: 4
						visible: text !== ""
						text: caption.daily?.description ?? ""
						tone: Qt.rgba(1, 1, 1, 0.7)
						surface: "transparent"
						wrapMode: Text.WordWrap
						maximumLineCount: 2
						elide: Text.ElideRight
						font.pixelSize: Theme.size.label
						lineHeight: 1.25
					}
				}

				ParallelAnimation {
					id: captionIn

					NumberAnimation {
						target: caption
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.standard
					}

					NumberAnimation {
						target: captionShift
						property: "y"
						from: 14
						to: 0
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.decel
					}
				}

				Connections {
					target: root
					function onCurrentKeyChanged() {
						captionIn.restart();
					}
				}

				// the look: palette, dark or light, and on it goes
				Rectangle {
					id: dock

					readonly property real cardW: 62
					readonly property real gap: 8

					anchors.right: parent.right
					anchors.bottom: parent.bottom
					anchors.margins: 18
					width: dockRow.implicitWidth + 20
					height: 64
					radius: 32
					color: Qt.alpha(Theme.base, 0.94)
					opacity: root.currentTheme ? 1 : 0
					scale: root.currentTheme ? 1 : 0.92
					visible: opacity > 0

					Behavior on opacity {
						Anim {}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					RowLayout {
						id: dockRow

						anchors.centerIn: parent
						spacing: 12

						Item {
							implicitWidth: root.colorSpaceOptions.length * (dock.cardW + dock.gap) - dock.gap
							implicitHeight: 44

							Repeater {
								model: root.colorSpaceOptions

								delegate: Rectangle {
									id: card

									required property int index
									required property string modelData

									readonly property var cellData: root.matrixCell(card.modelData, root.selectedPalette)
									readonly property bool available: card.cellData !== null

									x: card.index * (dock.cardW + dock.gap)
									width: dock.cardW
									height: 44
									radius: 22
									color: card.available ? card.cellData.background : Theme.layer1
									opacity: card.available || root.previewMatrixLoading ? 1 : 0.35
									scale: cardMouse.pressed ? 0.92 : (cardMouse.containsMouse && card.available ? 1.06 : 1)

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

									Row {
										anchors.centerIn: parent
										spacing: -5
										visible: card.available

										Repeater {
											model: [4, 2, 5, 6]

											delegate: Rectangle {
												required property int modelData

												width: 15
												height: 15
												radius: 7.5
												color: root.dataSwatch(card.cellData, modelData)
												border.width: 1.5
												border.color: card.color

												Behavior on color {
													ColorAnim {
														duration: Motion.medium
													}
												}
											}
										}
									}

									Spinner {
										anchors.centerIn: parent
										width: 16
										height: 16
										visible: !card.available && root.previewMatrixLoading
									}

									MouseArea {
										id: cardMouse

										anchors.fill: parent
										enabled: card.available
										hoverEnabled: true
										cursorShape: card.available ? Qt.PointingHandCursor : Qt.ArrowCursor
										onClicked: root.selectedColorSpace = card.modelData
									}
								}
							}

							Rectangle {
								x: root.selectedColorIndex * (dock.cardW + dock.gap) - 3
								y: -3
								width: dock.cardW + 6
								height: 50
								radius: 25
								color: "transparent"
								border.width: 2
								border.color: Theme.primary
								opacity: root.paletteReady ? 1 : 0

								Behavior on x {
									SpatialAnim {
										duration: Motion.medium
									}
								}
								Behavior on opacity {
									Anim {}
								}
							}
						}

						// dark or light
						Rectangle {
							id: modeSwitch

							readonly property int index: Math.max(0, root.paletteOptions.indexOf(root.selectedPalette))

							implicitWidth: 80
							implicitHeight: 40
							radius: 20
							color: Theme.layer1

							Rectangle {
								x: 3 + modeSwitch.index * 37
								y: 3
								width: 37
								height: 34
								radius: 17
								color: Theme.primary

								Behavior on x {
									SpatialAnim {
										duration: Motion.medium
									}
								}
							}

							Repeater {
								model: root.paletteOptions

								delegate: Item {
									id: mode

									required property int index
									required property string modelData

									x: 3 + mode.index * 37
									y: 3
									width: 37
									height: 34

									Glyph {
										anchors.centerIn: parent
										icon: mode.modelData === "light" ? "weather_sunny" : "weather_night"
										size: 16
										color: mode.index === modeSwitch.index ? Theme.onPrimary : Theme.textMuted
										surface: mode.index === modeSwitch.index ? Theme.primary : Theme.layer1
									}

									MouseArea {
										anchors.fill: parent
										cursorShape: Qt.PointingHandCursor
										onClicked: root.selectVariant(root.selectedColorSpace, mode.modelData)
									}
								}
							}
						}

						TextButton {
							implicitHeight: 44
							text: "Apply"
							icon: "check"
							variant: "filled"
							enabled: root.currentTheme !== null && !root.scaling && !(root.currentTheme.online && root.previewPaletteStatus === "error")
							busy: (root.previewPaletteStatus === "loading" && root.currentTheme !== null) || root.scaling || online.saving
							onActivated: root.applyTheme(root.currentTheme)
						}
					}
				}

				// the scaled copy being made, or a picture found online being
				// downloaded (to be looked at, or a live one to be worn), or its
				// colours read for an apply that waits: a bar that follows it
				Rectangle {
					id: progressCard

					readonly property bool saving: online.saving && root.currentTheme?.mediaType === "video"
					// a small one (MoeWalls' still) would only flash
					readonly property bool staging: root.view === "online" && online.currentStaging && (online.stageTotal > 2097152 || root.applyPending)
					readonly property bool reading: root.applyPending && !progressCard.staging
					readonly property bool shown: root.scaling || progressCard.saving || progressCard.staging || progressCard.reading
					readonly property real progress: progressCard.saving ? online.saveProgress
						: progressCard.staging ? online.stageProgress
						: progressCard.reading ? 1 : root.scaleProgress
					readonly property string detail: progressCard.saving ? root.downloadText(online.saveBytes, online.saveTotal, online.saveStarted)
						: progressCard.staging ? root.downloadText(online.stageBytes, online.stageTotal, online.stageStarted) : ""

					anchors.centerIn: parent
					width: 360
					height: 92
					radius: 24
					color: Qt.alpha(Theme.base, 0.94)
					opacity: progressCard.shown ? 1 : 0
					scale: progressCard.shown ? 1 : 0.94
					visible: opacity > 0

					Behavior on opacity {
						Anim {}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					ColumnLayout {
						anchors.fill: parent
						anchors.margins: 18
						spacing: 10

						RowLayout {
							Layout.fillWidth: true

							StyledText {
								Layout.fillWidth: true
								text: progressCard.saving || progressCard.staging ? "Downloading"
									: progressCard.reading ? "Reading the colours" : `Scaling to ${root.scalingLabel}`
								font.pixelSize: Theme.size.body
								font.weight: Font.DemiBold
								elide: Text.ElideRight
							}

							StyledText {
								visible: !progressCard.reading
								text: `${Math.floor(progressCard.progress * 100)} %`
								tone: Theme.textMuted
								font.pixelSize: Theme.size.label
							}
						}

						Rectangle {
							Layout.fillWidth: true
							Layout.preferredHeight: 8
							radius: 4
							color: Theme.layer1

							Rectangle {
								width: parent.width * progressCard.progress
								height: parent.height
								radius: 4
								color: Theme.primary

								Behavior on width {
									SpatialAnim {
										duration: Motion.short
									}
								}
							}
						}

						StyledText {
							Layout.fillWidth: true
							// a picture being looked at is not stopped, only left
							text: [progressCard.detail, progressCard.staging && !root.applyPending ? "" : "Esc cancels"].filter(part => part !== "").join("  ·  ")
							tone: Theme.textMuted
							font.pixelSize: Theme.size.tiny
							elide: Text.ElideRight
						}
					}
				}

				Spinner {
					anchors.centerIn: parent
					width: 36
					height: 36
					visible: root.view === "daily" && root.currentTheme === null && !!Daily.asking[root.dailyProvider]
				}

				EmptyState {
					anchors.centerIn: parent
					visible: root.view === "library" && root.filteredThemes.length === 0
					icon: "palette"
					title: root.themes.length === 0 ? "Loading…" : "Nothing found"
				}

				EmptyState {
					anchors.centerIn: parent
					visible: root.view === "daily" && root.currentTheme === null && !Daily.asking[root.dailyProvider]
					icon: "wifi_off"
					title: "No picture today"
				}

				Spinner {
					anchors.centerIn: parent
					width: 36
					height: 36
					visible: root.view === "online" && online.loading && online.items.length === 0
				}

				EmptyState {
					anchors.centerIn: parent
					visible: root.view === "online" && !online.loading && online.items.length === 0 && online.searched
					icon: online.error !== "" ? "wifi_off" : "image_off_outline"
					title: online.error !== "" ? online.error : "Nothing found"
				}

				MouseArea {
					anchors.fill: parent
					acceptedButtons: Qt.NoButton
					onWheel: wheel => root.move((wheel.angleDelta.y || -wheel.angleDelta.x) < 0 ? 1 : -1)
				}

				// a click beside the open filters folds them away
				MouseArea {
					anchors.fill: parent
					enabled: root.filtersOpen
					onClicked: root.filtersOpen = false
				}

				OnlineFilters {
					anchors.top: parent.top
					anchors.right: parent.right
					anchors.margins: 14
					search: online
					open: root.filtersOpen && root.view === "online"
					maxHeight: stage.height - 28
					onDismissed: root.filtersOpen = false
				}
			}

			// ── strip: the library, the pictures of the day, or what was ──
			// found online; a strip comes in from the side of its tab
			Item {
				id: strips

				Layout.fillWidth: true
				Layout.preferredHeight: 116

				ListView {
					id: strip

					readonly property real itemWidth: 168
					readonly property bool shown: root.view === "library"

					anchors.fill: parent
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
					opacity: strip.shown ? 1 : 0
					visible: opacity > 0
					enabled: strip.shown

					transform: Translate {
						x: strip.shown ? 0 : -48

						Behavior on x {
							SpatialAnim {
								duration: Motion.long
							}
						}
					}

					Behavior on opacity {
						Anim {}
					}

					onCurrentIndexChanged: {
						if (currentIndex >= 0 && currentIndex !== root.currentThemeIndex)
							root.currentThemeIndex = currentIndex;
					}

					delegate: Thumb {
						required property var modelData
						required property int index

						width: strip.itemWidth
						height: strip.height
						source: modelData.previewPath
						title: modelData.name
						current: index === root.currentThemeIndex
						onClicked: {
							if (current) {
								root.applyTheme(modelData);
								return;
							}
							root.startPending = false;
							root.currentThemeIndex = index;
						}
					}

					MouseArea {
						anchors.fill: parent
						acceptedButtons: Qt.NoButton
						onWheel: wheel => root.move((wheel.angleDelta.y || -wheel.angleDelta.x) < 0 ? 1 : -1)
					}
				}

				ListView {
					id: onlineStrip

					readonly property real itemWidth: 168
					readonly property bool shown: root.view === "online"

					anchors.fill: parent
					orientation: ListView.Horizontal
					spacing: 10
					clip: true
					model: online.items
					currentIndex: online.index
					highlightRangeMode: ListView.StrictlyEnforceRange
					preferredHighlightBegin: width / 2 - itemWidth / 2
					preferredHighlightEnd: width / 2 + itemWidth / 2
					highlightMoveDuration: Motion.long
					boundsBehavior: Flickable.StopAtBounds
					cacheBuffer: 1200
					opacity: onlineStrip.shown ? 1 : 0
					visible: opacity > 0
					enabled: onlineStrip.shown

					transform: Translate {
						x: onlineStrip.shown ? 0 : 48

						Behavior on x {
							SpatialAnim {
								duration: Motion.long
							}
						}
					}

					Behavior on opacity {
						Anim {}
					}

					onCurrentIndexChanged: {
						if (currentIndex >= 0 && currentIndex !== online.index)
							online.select(currentIndex);
					}

					delegate: Thumb {
						required property var modelData
						required property int index

						width: onlineStrip.itemWidth
						height: onlineStrip.height
						source: modelData.thumb
						title: modelData.title || (modelData.width ? `${modelData.width} × ${modelData.height}` : "")
						current: index === online.index
						busy: current && online.staging(modelData)
						onClicked: {
							if (current) {
								root.applyTheme(root.currentTheme);
								return;
							}
							online.select(index);
						}
					}

					// the next page is on its way
					footer: Item {
						width: online.loadingMore ? 64 : 0
						height: onlineStrip.height

						Spinner {
							anchors.centerIn: parent
							width: 22
							height: 22
							visible: online.loadingMore
						}
					}

					MouseArea {
						anchors.fill: parent
						acceptedButtons: Qt.NoButton
						onWheel: wheel => root.move((wheel.angleDelta.y || -wheel.angleDelta.x) < 0 ? 1 : -1)
					}
				}

				Row {
					id: dailyStrip

					readonly property bool shown: root.view === "daily"

					anchors.fill: parent
					spacing: 12
					opacity: dailyStrip.shown ? 1 : 0
					visible: opacity > 0
					enabled: dailyStrip.shown

					transform: Translate {
						x: dailyStrip.shown ? 0 : (root.viewIndex > 1 ? -48 : 48)

						Behavior on x {
							SpatialAnim {
								duration: Motion.long
							}
						}
					}

					Behavior on opacity {
						Anim {}
					}

					Repeater {
						model: Daily.sources

						delegate: Thumb {
							id: dailyThumb

							required property var modelData

							readonly property var entry: Daily.entries[modelData.id] ?? null

							width: (dailyStrip.width - dailyStrip.spacing * (Daily.sources.length - 1)) / Daily.sources.length
							height: dailyStrip.height
							source: dailyThumb.entry ? String(dailyThumb.entry.preview_path || "") : ""
							label: modelData.label
							title: dailyThumb.entry ? String(dailyThumb.entry.headline || dailyThumb.entry.title || "") : ""
							current: root.dailyProvider === modelData.id
							busy: !!Daily.asking[modelData.id]
							worn: Daily.wears(dailyThumb.entry)
							missing: !dailyThumb.entry && !dailyThumb.busy
							onClicked: {
								if (current) {
									root.applyTheme(root.currentTheme);
									return;
								}
								root.startPending = false;
								root.dailyProvider = modelData.id;
							}
						}
					}

				}

				MouseArea {
					anchors.fill: parent
					acceptedButtons: Qt.NoButton
					enabled: dailyStrip.shown
					onWheel: wheel => root.move((wheel.angleDelta.y || -wheel.angleDelta.x) < 0 ? 1 : -1)
				}
			}
		}
	}
}
