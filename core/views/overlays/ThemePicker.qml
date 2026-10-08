pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.overlays.studio

// Theme picker. One stage shows the wallpaper in front with the shell in
// miniature on top of it, painted in the palette that is chosen in the dock
// at its corner. Below it runs the library as a film strip, or, on the
// second tab, the pictures of the day (Daily) that are already fetched.
// ←→ step through the strip, ↑↓ through the palettes, Tab changes the tab,
// Enter applies.
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
	property string searchText: ""
	property var themes: []
	property string selectedBackend: "fastresize"
	property string selectedColorSpace: "salience"
	property string selectedPalette: "dark"
	property int currentThemeIndex: 0
	property string dailyProvider: "bing"
	// until the first touch, the picker stands on what the desktop wears
	property bool startPending: false
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
	readonly property string currentKey: root.currentTheme ? `${root.currentTheme.path}\u001f${root.currentTheme.previewPath}` : ""

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
		if (!theme) {
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
		root.view = view;
		if (view === "daily") {
			if (!root.dailyEntry) root.dailyProvider = root.firstDailyProvider();
			Daily.refresh(false);
		}
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
		if (root.previewPaletteStatus === "loading") return;
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
		Popups.closeModal();
		if (theme.daily) {
			// the picture that is kept becomes the library's theme of the day
			Quickshell.execDetached([
				"sh", "-c", 'python3 "$1" --provider "$2" --cached >/dev/null && shift 2 && exec bash "$@"', "sh",
				Daily.script, theme.daily.provider, root.applyScriptPath, Daily.themeDir
			].concat(look));
			return;
		}
		Quickshell.execDetached(["bash", root.applyScriptPath, theme.path].concat(look));
	}

	function reset() {
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
	onCurrentKeyChanged: root.reloadPreviewMatrix()
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
					Layout.preferredWidth: 250
					Layout.preferredHeight: 40
					options: [
						{ value: "library", label: Words.of("wallpaper.library", "Library"), icon: "image_multiple" },
						{ value: "daily", label: Words.of("wallpaper.today", "Today"), icon: "calendar_today" }
					]
					current: root.view
					onSelected: value => root.selectView(value)
				}

				Rectangle {
					id: searchBox

					readonly property bool shown: root.view === "library"

					Layout.preferredWidth: searchBox.shown ? 300 : 0
					Layout.preferredHeight: 40
					radius: 20
					color: Theme.layer1
					opacity: searchBox.shown ? 1 : 0
					clip: true

					Behavior on Layout.preferredWidth {
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
							root.searchText = text;
						}

						Keys.onLeftPressed: root.move(-1)
						Keys.onRightPressed: root.move(1)
						Keys.onUpPressed: root.movePalette(-1)
						Keys.onDownPressed: root.movePalette(1)
						Keys.onTabPressed: root.selectView(root.view === "daily" ? "library" : "daily")
						Keys.onReturnPressed: root.applyTheme(root.currentTheme)
						Keys.onEnterPressed: root.applyTheme(root.currentTheme)
						Keys.onEscapePressed: Popups.closeModal()

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: "Search"
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

				IconButton {
					id: refreshButton

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

				IconButton {
					icon: "close"
					variant: "tonal"
					onClicked: Popups.closeModal()
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

					readonly property string source: root.currentTheme ? root.currentTheme.previewPath : ""
					property Image front: backdropA

					function reveal(layer) {
						const last = layer === backdropA ? backdropB : backdropA;
						rise.stop();
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
							from: 1.06
							to: 1
							duration: Motion.extraLong
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.decel
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
						visible: caption.daily !== null || root.currentTheme?.mediaType === "video"

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

						Rectangle {
							implicitWidth: 24
							implicitHeight: 24
							radius: 12
							visible: !!caption.daily?.source_url
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
									Qt.openUrlExternally(caption.daily.source_url);
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
							enabled: root.currentTheme !== null && root.previewPaletteStatus !== "loading"
							busy: root.previewPaletteStatus === "loading" && root.currentTheme !== null
							onActivated: root.applyTheme(root.currentTheme)
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

				MouseArea {
					anchors.fill: parent
					acceptedButtons: Qt.NoButton
					onWheel: wheel => root.move((wheel.angleDelta.y || -wheel.angleDelta.x) < 0 ? 1 : -1)
				}
			}

			// ── strip: the library, or the pictures of the day ────────────
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

				Row {
					id: dailyStrip

					readonly property bool shown: root.view === "daily"

					anchors.fill: parent
					spacing: 12
					opacity: dailyStrip.shown ? 1 : 0
					visible: opacity > 0
					enabled: dailyStrip.shown

					transform: Translate {
						x: dailyStrip.shown ? 0 : 48

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
