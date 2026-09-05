pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import "components"

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

	property var presets: []
	property var wallpapers: []
	property var uiThemes: []
	property var animations: []
	property var currentSelection: ({})
	property string searchText: ""
	property int currentPresetIndex: 0
	property bool composerOpen: false
	property int selectedWallpaperIndex: 0
	property int selectedThemeIndex: 0
	property int selectedAnimationIndex: 0
	property string selectedBackend: "fastresize"
	property string selectedColorSpace: "salience"
	property string selectedPalette: "dark"
	property var previewMatrixItems: []
	property string previewMatrixRequestKey: ""
	property bool previewMatrixLoading: false
	property bool mutationRunning: false
	property string errorText: ""

	readonly property string presetScriptPath: `${Quickshell.shellDir}/scripts/style_presets.py`
	readonly property string themeCatalogScriptPath: `${Quickshell.shellDir}/scripts/theme_catalog.sh`
	readonly property var backendOptions: ["full", "resized", "wal", "thumb", "fastresize"]
	readonly property var colorSpaceOptions: ["salience", "ansi", "kmeans"]
	readonly property var paletteOptions: ["dark", "light"]
	readonly property var filteredPresets: {
		const query = root.searchText.trim().toLowerCase();
		if (query === "") return root.presets;
		return root.presets.filter(function(preset) {
			return String(preset.name || "").toLowerCase().includes(query)
				|| String(preset.wallpaperName || "").toLowerCase().includes(query)
				|| String(preset.themeName || "").toLowerCase().includes(query)
				|| String(preset.animationName || "").toLowerCase().includes(query)
				|| String(preset.palette || "").toLowerCase().includes(query)
				|| String(preset.style || "").toLowerCase().includes(query);
		});
	}
	readonly property var currentPreset: root.filteredPresets.length > 0
		? root.filteredPresets[Math.max(0, Math.min(root.currentPresetIndex, root.filteredPresets.length - 1))]
		: null
	readonly property var selectedWallpaper: root.wallpapers.length > 0 ? root.wallpapers[root.selectedWallpaperIndex] : null
	readonly property var selectedUiTheme: root.uiThemes.length > 0 ? root.uiThemes[root.selectedThemeIndex] : null
	readonly property var selectedAnimation: root.animations.length > 0 ? root.animations[root.selectedAnimationIndex] : null
	readonly property bool canSave: !root.mutationRunning && presetNameField.text.trim() !== ""
		&& root.selectedWallpaper && root.selectedUiTheme && root.selectedAnimation

	function parseCatalog(raw) {
		try {
			const data = JSON.parse(String(raw || "{}"));
			root.presets = Array.isArray(data.presets) ? data.presets : [];
			root.wallpapers = Array.isArray(data.wallpapers) ? data.wallpapers : [];
			root.uiThemes = Array.isArray(data.themes) ? data.themes : [];
			root.animations = Array.isArray(data.animations) ? data.animations : [];
			root.currentSelection = data.current || {};
			root.errorText = "";
			root.syncComposerSelection();
			root.clampPresetIndex();
		} catch (error) {
			root.errorText = `Could not load style presets: ${error}`;
		}
	}

	function syncComposerSelection() {
		for (let i = 0; i < root.wallpapers.length; i += 1) {
			if (String(root.wallpapers[i].mediaPath || "") === String(root.currentSelection.wallpaper || "")) {
				root.selectedWallpaperIndex = i;
				break;
			}
		}
		for (let i = 0; i < root.uiThemes.length; i += 1) {
			if (String(root.uiThemes[i].id || "") === String(root.currentSelection.theme || "")) {
				root.selectedThemeIndex = i;
				break;
			}
		}
		for (let i = 0; i < root.animations.length; i += 1) {
			if (String(root.animations[i].id || "") === String(root.currentSelection.animation || "")) {
				root.selectedAnimationIndex = i;
				break;
			}
		}
		const backend = String(root.currentSelection.backend || "fastresize");
		const colorSpace = String(root.currentSelection.palette || "salience");
		const palette = String(root.currentSelection.style || "dark");
		root.selectedBackend = root.backendOptions.indexOf(backend) >= 0 ? backend : "fastresize";
		root.selectedColorSpace = root.colorSpaceOptions.indexOf(colorSpace) >= 0 ? colorSpace : "salience";
		root.selectedPalette = root.paletteOptions.indexOf(palette) >= 0 ? palette : "dark";
	}

	function matrixKey(wallpaper, backend) {
		if (!wallpaper) return "";
		return [String(wallpaper.path || ""), String(wallpaper.previewPath || ""), backend].join("\u001f");
	}

	function reloadPreviewMatrix() {
		if (!root.composerOpen || !root.selectedWallpaper) return;
		const key = root.matrixKey(root.selectedWallpaper, root.selectedBackend);
		root.previewMatrixRequestKey = key;
		root.previewMatrixItems = [];
		root.previewMatrixLoading = true;
		previewMatrixProcess.running = false;
		previewMatrixProcess.command = [
			"bash", root.themeCatalogScriptPath, "matrix-json",
			root.selectedWallpaper.path, root.selectedWallpaper.previewPath, root.selectedBackend
		];
		previewMatrixProcess.running = true;
	}

	function parsePreviewMatrix(raw) {
		try {
			const data = JSON.parse(String(raw || "{}"));
			const key = root.matrixKey({ path: data.themePath, previewPath: data.previewPath }, String(data.backend || ""));
			if (key !== root.previewMatrixRequestKey) return;
			root.previewMatrixItems = Array.isArray(data.items) ? data.items : [];
			root.previewMatrixLoading = false;
			root.errorText = "";
		} catch (error) {
			root.previewMatrixItems = [];
			root.previewMatrixLoading = false;
			root.errorText = `Could not load color schemes: ${error}`;
		}
	}

	function clampPresetIndex() {
		if (root.filteredPresets.length === 0) root.currentPresetIndex = -1;
		else root.currentPresetIndex = Math.max(0, Math.min(root.currentPresetIndex, root.filteredPresets.length - 1));
	}

	function reloadCatalog() {
		catalogProcess.running = false;
		catalogProcess.running = true;
	}

	function openComposer() {
		root.syncComposerSelection();
		presetNameField.text = "";
		root.errorText = "";
		root.composerOpen = true;
		previewMatrixReloadTimer.restart();
		Qt.callLater(function() { presetNameField.forceActiveFocus(); });
	}

	function savePreset() {
		if (!root.canSave) return;
		root.mutationRunning = true;
		root.errorText = "";
		mutationProcess.operation = "save";
		mutationProcess.command = [
			"python3", root.presetScriptPath, "save",
			"--name", presetNameField.text.trim(),
			"--wallpaper", root.selectedWallpaper.mediaPath,
			"--theme", root.selectedUiTheme.id,
			"--animation", root.selectedAnimation.id,
			"--backend", root.selectedBackend,
			"--palette", root.selectedColorSpace,
			"--style", root.selectedPalette
		];
		mutationProcess.running = true;
	}

	function deletePreset(preset) {
		if (!preset || root.mutationRunning) return;
		root.mutationRunning = true;
		root.errorText = "";
		mutationProcess.operation = "delete";
		mutationProcess.command = ["python3", root.presetScriptPath, "delete", String(preset.id || "")];
		mutationProcess.running = true;
	}

	function applyPreset(preset) {
		if (!preset || !preset.valid) return;
		root.closeRequested();
		Quickshell.execDetached(["python3", root.presetScriptPath, "apply", String(preset.id || "")]);
	}

	function movePreset(delta) {
		if (root.filteredPresets.length === 0) return;
		root.currentPresetIndex = Math.max(0, Math.min(root.filteredPresets.length - 1, root.currentPresetIndex + delta));
	}

	focus: true
	Component.onCompleted: root.reloadCatalog()
	onFilteredPresetsChanged: root.clampPresetIndex()
	onSelectedWallpaperIndexChanged: if (root.composerOpen) previewMatrixReloadTimer.restart()
	onSelectedBackendChanged: if (root.composerOpen) previewMatrixReloadTimer.restart()
	Keys.onEscapePressed: {
		if (root.composerOpen) root.composerOpen = false;
		else root.closeRequested();
	}
	Keys.onUpPressed: root.movePreset(-1)
	Keys.onDownPressed: root.movePreset(1)
	Keys.onReturnPressed: root.applyPreset(root.currentPreset)
	Keys.onEnterPressed: root.applyPreset(root.currentPreset)

	Process {
		id: catalogProcess
		command: ["python3", root.presetScriptPath, "catalog"]
		onExited: function(exitCode) {
			if (exitCode !== 0 && root.errorText === "") root.errorText = "Could not load style preset catalog.";
		}
		stdout: StdioCollector { onStreamFinished: root.parseCatalog(text) }
		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") root.errorText = message;
			}
		}
	}

	Process {
		id: mutationProcess
		property string operation: ""
		command: ["true"]
		onExited: function(exitCode) {
			root.mutationRunning = false;
			if (exitCode === 0) {
				if (operation === "save") root.composerOpen = false;
				root.reloadCatalog();
			} else if (root.errorText === "") {
				root.errorText = operation === "save" ? "Could not save style preset." : "Could not delete style preset.";
			}
		}
		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") root.errorText = message;
			}
		}
	}

	Timer {
		id: previewMatrixReloadTimer
		interval: 180
		repeat: false
		onTriggered: root.reloadPreviewMatrix()
	}

	Process {
		id: previewMatrixProcess
		command: ["true"]
		onExited: function(exitCode) {
			if (exitCode !== 0) root.previewMatrixLoading = false;
		}
		stdout: StdioCollector { onStreamFinished: root.parsePreviewMatrix(text) }
		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") root.errorText = message;
			}
		}
	}

	ThemedRectangle {
		anchors.fill: parent
		radius: ThemeEngine.radiusLarge
		color: root.background
		border.width: 0
		border.color: Qt.alpha(root.barColor, 0.34)
		clip: true
	}

	ThemedRectangle {
		id: searchBox
		z: 10
		anchors.top: parent.top
		anchors.topMargin: 18
		anchors.horizontalCenter: parent.horizontalCenter
		width: Math.max(420, Math.min(root.width - 160, 680))
		height: 48
		themeStyle: "inset"
		radius: ThemeEngine.radiusMedium
		color: Qt.alpha(root.secondaryBoxColor, 0.88)

		Image {
			anchors.left: parent.left
			anchors.leftMargin: 15
			anchors.verticalCenter: parent.verticalCenter
			width: 16
			height: 16
			source: "/usr/share/icons/Adwaita/symbolic/actions/system-search-symbolic.svg"
			layer.enabled: true
			layer.effect: MultiEffect { colorization: 1; colorizationColor: root.barColor }
		}

		TextField {
			id: searchField
			anchors.left: parent.left
			anchors.leftMargin: 43
			anchors.right: addButton.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			color: root.foreground
			placeholderText: "Filter style presets"
			placeholderTextColor: Qt.alpha(root.foreground, 0.45)
			selectionColor: Qt.alpha(root.barColor, 0.28)
			background: Item {}
			onTextChanged: root.searchText = text
			Keys.onDownPressed: function(event) { root.movePreset(1); event.accepted = true; }
			Keys.onUpPressed: function(event) { root.movePreset(-1); event.accepted = true; }
			Keys.onReturnPressed: function(event) { root.applyPreset(root.currentPreset); event.accepted = true; }
		}

		ThemedRectangle {
			id: addButton
			anchors.right: closeButton.left
			anchors.rightMargin: 6
			anchors.verticalCenter: parent.verticalCenter
			width: 32
			height: 32
			radius: ThemeEngine.radiusMedium
			color: addMouse.containsMouse ? Qt.alpha(root.barColor, 0.32) : Qt.alpha(root.barColor, 0.16)
			border.width: 1
			border.color: Qt.alpha(root.barColor, 0.5)
			AtelierText { anchors.centerIn: parent; color: root.foreground; display: true; font.pixelSize: 22; text: "+" }
			MouseArea { id: addMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openComposer() }
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
			AtelierText { anchors.centerIn: parent; color: root.foreground; font.pixelSize: 14; text: "x" }
			MouseArea { id: closeMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeRequested() }
		}
	}

	ThemedRectangle {
		visible: root.errorText !== ""
		z: 40
		anchors.top: searchBox.bottom
		anchors.topMargin: 8
		anchors.horizontalCenter: parent.horizontalCenter
		width: Math.min(errorLabel.implicitWidth + 32, root.width - 100)
		height: errorLabel.implicitHeight + 16
		radius: ThemeEngine.radiusMedium
		color: Qt.alpha(root.danger, 0.9)
		AtelierText { id: errorLabel; anchors.centerIn: parent; width: Math.min(implicitWidth, root.width - 140); wrapMode: Text.Wrap; color: "white"; font.pixelSize: 12; text: root.errorText }
	}

	Item {
		id: stackArea
		anchors.top: searchBox.bottom
		anchors.topMargin: 18
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: footer.top
		anchors.bottomMargin: 10
		visible: root.filteredPresets.length > 0

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.NoButton
			onWheel: function(wheel) {
				root.movePreset(wheel.angleDelta.y < 0 ? 1 : -1);
				wheel.accepted = true;
			}
		}

		Repeater {
			model: root.filteredPresets.length
			delegate: Item {
				id: presetCard
				required property int index
				readonly property int offset: index - root.currentPresetIndex
				readonly property int distance: Math.abs(offset)
				readonly property bool active: offset === 0
				readonly property var preset: root.filteredPresets[index]
				visible: active
				z: 8 - distance
				width: Math.max(1, stackArea.width - 48)
				height: Math.max(1, stackArea.height - 24)
				anchors.horizontalCenter: parent.horizontalCenter
				y: 12
				opacity: 1
				scale: 1
				Behavior on y { NumberAnimation { duration: ThemeEngine.duration(220); easing.type: ThemeEngine.standardEasing } }
				Behavior on opacity { NumberAnimation { duration: ThemeEngine.duration(180) } }
				Behavior on scale { NumberAnimation { duration: ThemeEngine.duration(220); easing.type: ThemeEngine.standardEasing } }

				ThemedRectangle {
					anchors.fill: parent
					radius: ThemeEngine.radiusMedium
					color: root.secondaryBoxColor
					border.width: 0
					border.color: presetCard.preset.valid ? Qt.alpha(root.barColor, 0.82) : Qt.alpha(root.danger, 0.8)
					clip: true

					Image {
						anchors.fill: parent
						asynchronous: true
						cache: true
						fillMode: Image.PreserveAspectCrop
						source: presetCard.preset.previewPath || ""
					}

					ThemedRectangle {
						anchors.fill: parent
						gradient: Gradient {
							GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.04) }
							GradientStop { position: 0.48; color: "transparent" }
							GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.78) }
						}
					}

					Row {
						anchors.top: parent.top
						anchors.right: parent.right
						anchors.margins: 16
						spacing: 7
						Repeater {
							model: [
								presetCard.preset.themeName || "Theme",
								presetCard.preset.animationName || "Animation",
								`${presetCard.preset.palette || "salience"} · ${presetCard.preset.style || "dark"}`
							]
							delegate: ThemedRectangle {
								required property string modelData
								width: badgeLabel.implicitWidth + 18
								height: 26
								radius: ThemeEngine.radiusMedium
								color: Qt.rgba(0, 0, 0, 0.62)
								border.width: 1
								border.color: Qt.rgba(255, 255, 255, 0.22)
								AtelierText { id: badgeLabel; anchors.centerIn: parent; color: "white"; font.pixelSize: 10; font.weight: Font.DemiBold; text: parent.modelData }
							}
						}
					}

					ThemedRectangle {
						visible: presetCard.active
						z: 5
						anchors.top: parent.top
						anchors.left: parent.left
						anchors.margins: 16
						width: 34
						height: 34
						radius: ThemeEngine.radiusMedium
						color: Qt.alpha(root.danger, deleteMouse.containsMouse ? 0.82 : 0.55)
						Image {
							anchors.centerIn: parent
							width: 16
							height: 16
							source: "/usr/share/icons/Adwaita/symbolic/actions/edit-delete-symbolic.svg"
							layer.enabled: true
							layer.effect: MultiEffect { colorization: 1; colorizationColor: "white" }
						}
						MouseArea { id: deleteMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !root.mutationRunning; onClicked: root.deletePreset(presetCard.preset) }
					}

					Column {
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						anchors.margins: 22
						spacing: 5
						AtelierText { width: parent.width; color: "white"; display: true; font.pixelSize: 25; font.weight: Font.DemiBold; elide: Text.ElideRight; text: presetCard.preset.name || "Style" }
						AtelierText { width: parent.width; color: Qt.rgba(255, 255, 255, 0.72); font.pixelSize: 12; elide: Text.ElideRight; text: `${presetCard.preset.wallpaperName || "Wallpaper"}  ·  ${presetCard.preset.themeName || "Theme"}  ·  ${presetCard.preset.animationName || "Animation"}  ·  ${presetCard.preset.palette || "salience"}/${presetCard.preset.style || "dark"}` }
						AtelierText { visible: !presetCard.preset.valid; color: "#ffb7b7"; font.pixelSize: 11; text: "A referenced wallpaper, theme or animation is missing" }
					}

					MouseArea {
						anchors.fill: parent
						z: 2
						enabled: presetCard.active && presetCard.preset.valid
						cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
						onClicked: root.applyPreset(presetCard.preset)
					}
				}
			}
		}
	}

	Column {
		visible: root.filteredPresets.length === 0
		anchors.centerIn: parent
		spacing: 10
		AtelierText { anchors.horizontalCenter: parent.horizontalCenter; color: root.foreground; font.pixelSize: 20; font.weight: Font.DemiBold; text: root.presets.length === 0 ? "No style presets yet" : "No matching style presets" }
		AtelierText { anchors.horizontalCenter: parent.horizontalCenter; color: Qt.alpha(root.foreground, 0.58); font.pixelSize: 12; text: root.presets.length === 0 ? "Use + to combine a wallpaper, interface theme and animation" : "Try another search" }
	}

	Row {
		id: footer
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 16
		anchors.horizontalCenter: parent.horizontalCenter
		height: 28
		spacing: 12
		AtelierText { color: Qt.alpha(root.foreground, 0.62); font.pixelSize: 11; text: `${root.filteredPresets.length} presets` }
		AtelierText { color: Qt.alpha(root.foreground, 0.38); font.pixelSize: 11; text: "↑↓ browse  ·  Enter apply  ·  + create" }
	}

	ThemedRectangle {
		id: composer
		visible: root.composerOpen
		z: 100
		anchors.fill: parent
		radius: ThemeEngine.radiusLarge
		color: Qt.alpha(root.secondaryInsetColor, 0.99)
		border.width: 1
		border.color: Qt.alpha(root.barColor, 0.48)

		Column {
			anchors.fill: parent
			anchors.margins: 22
			spacing: 14

			Row {
				width: parent.width
				height: 52
				spacing: 14
				Column {
					width: parent.width - composerClose.width - 14
					spacing: 3
					AtelierText { color: root.foreground; display: true; font.pixelSize: 22; font.weight: Font.DemiBold; text: "Create style preset" }
					AtelierText { color: Qt.alpha(root.foreground, 0.6); font.pixelSize: 11; text: "Choose wallpaper, colors, interface style and window animation" }
				}
				ThemedRectangle {
					id: composerClose
					width: 38
					height: 38
					radius: ThemeEngine.radiusMedium
					color: composerCloseMouse.containsMouse ? Qt.alpha(root.barColor, 0.2) : "transparent"
					AtelierText { anchors.centerIn: parent; color: root.foreground; text: "x" }
					MouseArea { id: composerCloseMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.composerOpen = false }
				}
			}

			ThemedRectangle {
				width: parent.width
				height: 46
				themeStyle: "inset"
				radius: ThemeEngine.radiusMedium
				color: root.secondaryBoxColor
				TextField {
					id: presetNameField
					anchors.fill: parent
					anchors.leftMargin: 14
					anchors.rightMargin: 14
					color: root.foreground
					placeholderText: "Style name"
					placeholderTextColor: Qt.alpha(root.foreground, 0.45)
					selectionColor: Qt.alpha(root.barColor, 0.28)
					background: Item {}
					Keys.onReturnPressed: root.savePreset()
				}
			}

			Row {
				id: selectionRow
				width: parent.width
				height: parent.height - 52 - 46 - 48 - 42
				spacing: 12

			PresetChoicePanel {
				width: selectionRow.width * 0.36
				height: parent.height
					title: "Wallpaper"
					model: root.wallpapers
					selectedIndex: root.selectedWallpaperIndex
					foreground: root.foreground
					accent: root.barColor
					surface: root.secondaryBoxColor
					strongSurface: root.secondaryBoxStrongColor
					showImages: true
					onChoiceSelected: function(index) { root.selectedWallpaperIndex = index; }
			}

			ColorSchemeChoicePanel {
				width: selectionRow.width * 0.36
				height: parent.height
				matrixItems: root.previewMatrixItems
				backendOptions: root.backendOptions
				colorSpaceOptions: root.colorSpaceOptions
				paletteOptions: root.paletteOptions
				selectedBackend: root.selectedBackend
				selectedColorSpace: root.selectedColorSpace
				selectedPalette: root.selectedPalette
				previewPath: root.selectedWallpaper ? String(root.selectedWallpaper.previewPath || "") : ""
				loading: root.previewMatrixLoading
				foreground: root.foreground
				accent: root.barColor
				surface: root.secondaryBoxColor
				strongSurface: root.secondaryBoxStrongColor
				onBackendSelected: function(backend) { root.selectedBackend = backend; }
				onSchemeSelected: function(colorSpace, palette) {
					root.selectedColorSpace = colorSpace;
					root.selectedPalette = palette;
				}
			}

			Column {
				width: selectionRow.width - selectionRow.width * 0.72 - selectionRow.spacing * 2
				height: parent.height
				spacing: 12

				PresetChoicePanel {
					width: parent.width
					height: (parent.height - parent.spacing) * 0.45
					title: "Interface theme"
					model: root.uiThemes
					selectedIndex: root.selectedThemeIndex
					foreground: root.foreground
					accent: root.barColor
					surface: root.secondaryBoxColor
					strongSurface: root.secondaryBoxStrongColor
					labelRole: "name"
					detailRole: "description"
					onChoiceSelected: function(index) { root.selectedThemeIndex = index; }
				}

				PresetChoicePanel {
					width: parent.width
					height: (parent.height - parent.spacing) * 0.55
					title: "Animation"
					model: root.animations
					selectedIndex: root.selectedAnimationIndex
					foreground: root.foreground
					accent: root.barColor
					surface: root.secondaryBoxColor
					strongSurface: root.secondaryBoxStrongColor
					labelRole: "name"
					detailRole: "kind"
					onChoiceSelected: function(index) { root.selectedAnimationIndex = index; }
				}
			}
			}

			Row {
				anchors.right: parent.right
				height: 42
				spacing: 10
				ThemedRectangle {
					width: 96
					height: 40
					radius: ThemeEngine.radiusMedium
					color: cancelMouse.containsMouse ? Qt.alpha(root.foreground, 0.1) : root.secondaryBoxColor
					AtelierText { anchors.centerIn: parent; color: root.foreground; font.pixelSize: 12; text: "Cancel" }
					MouseArea { id: cancelMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.composerOpen = false }
				}
				ThemedRectangle {
					width: 124
					height: 40
					radius: ThemeEngine.radiusMedium
					color: root.canSave ? Qt.alpha(root.barColor, saveMouse.containsMouse ? 0.48 : 0.32) : Qt.alpha(root.secondaryBoxColor, 0.5)
					border.width: root.canSave ? 1 : 0
					border.color: Qt.alpha(root.barColor, 0.62)
					AtelierText { anchors.centerIn: parent; color: root.canSave ? root.foreground : Qt.alpha(root.foreground, 0.42); font.pixelSize: 12; font.weight: Font.DemiBold; text: root.mutationRunning ? "Saving…" : "Save preset" }
					MouseArea { id: saveMouse; anchors.fill: parent; enabled: root.canSave; hoverEnabled: enabled; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: root.savePreset() }
				}
			}
		}
	}
}
