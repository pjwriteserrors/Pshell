pragma ComponentBehavior: Bound

import QtQuick
import "components"

ThemedRectangle {
	id: root

	signal backendSelected(string backend)
	signal schemeSelected(string colorSpace, string palette)

	property var matrixItems: []
	property var backendOptions: []
	property var colorSpaceOptions: []
	property var paletteOptions: []
	property string selectedBackend: "fastresize"
	property string selectedColorSpace: "salience"
	property string selectedPalette: "dark"
	property string previewPath: ""
	property bool loading: false
	property color foreground: "white"
	property color accent: "white"
	property color surface: "#222222"
	property color strongSurface: "#333333"

	function cellData(colorSpace, palette) {
		for (const item of root.matrixItems) {
			if (String(item.colorSpace || "") === colorSpace && String(item.palette || "") === palette) return item;
		}
		return null;
	}

	function swatch(data, index) {
		if (!data) return "transparent";
		if (Array.isArray(data.swatches) && index < data.swatches.length) return data.swatches[index];
		return data.colors ? String(data.colors[`color${index}`] || "transparent") : "transparent";
	}

	radius: ThemeEngine.radiusMedium
	color: Qt.alpha(root.surface, 0.76)
	border.width: 1
	border.color: Qt.alpha(root.foreground, 0.11)
	clip: true

	AtelierText {
		id: heading
		anchors.top: parent.top
		anchors.left: parent.left
		anchors.margins: 12
		color: root.foreground
		font.pixelSize: 13
		font.weight: Font.DemiBold
		text: "Color scheme"
	}

	Row {
		id: backendRow
		anchors.top: heading.bottom
		anchors.topMargin: 9
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.margins: 9
		height: 28
		spacing: 4

		Repeater {
			model: root.backendOptions
			delegate: ThemedRectangle {
				id: backendChip
				required property string modelData
				readonly property bool selected: modelData === root.selectedBackend
				width: (backendRow.width - backendRow.spacing * (root.backendOptions.length - 1)) / root.backendOptions.length
				height: 26
				radius: ThemeEngine.radiusSmall
				color: Qt.alpha(selected ? root.accent : root.strongSurface, selected ? 0.3 : 0.5)
				border.width: selected ? 1 : 0
				border.color: Qt.alpha(root.accent, 0.66)
				AtelierText { anchors.fill: parent; anchors.margins: 3; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; color: root.foreground; font.pixelSize: 8; text: backendChip.modelData }
				MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.backendSelected(backendChip.modelData) }
			}
		}
	}

	Grid {
		id: schemeGrid
		anchors.top: backendRow.bottom
		anchors.topMargin: 8
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 9
		columns: root.colorSpaceOptions.length
		columnSpacing: 6
		rowSpacing: 6

		Repeater {
			model: root.colorSpaceOptions.length * root.paletteOptions.length
			delegate: ThemedRectangle {
				id: schemeCell
				required property int index
				readonly property int columnIndex: index % root.colorSpaceOptions.length
				readonly property int rowIndex: Math.floor(index / root.colorSpaceOptions.length)
				readonly property string colorSpaceName: String(root.colorSpaceOptions[columnIndex] || "")
				readonly property string paletteName: String(root.paletteOptions[rowIndex] || "")
				readonly property var previewData: root.cellData(colorSpaceName, paletteName)
				readonly property bool selected: colorSpaceName === root.selectedColorSpace && paletteName === root.selectedPalette
				width: (schemeGrid.width - schemeGrid.columnSpacing * (root.colorSpaceOptions.length - 1)) / root.colorSpaceOptions.length
				height: (schemeGrid.height - schemeGrid.rowSpacing * (root.paletteOptions.length - 1)) / root.paletteOptions.length
				radius: ThemeEngine.radiusMedium
				color: previewData ? String(previewData.background || root.strongSurface) : root.strongSurface
				border.width: selected ? 3 : 1
				border.color: selected ? root.accent : Qt.alpha(root.foreground, 0.14)
				clip: true

				Image { anchors.fill: parent; source: root.previewPath; fillMode: Image.PreserveAspectCrop; opacity: 0.62; asynchronous: true; cache: true }
				ThemedRectangle { anchors.fill: parent; color: Qt.alpha(schemeCell.previewData ? String(schemeCell.previewData.background || root.surface) : root.surface, 0.44) }
				Row {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.verticalCenter: parent.verticalCenter
					spacing: 3
					Repeater {
						model: [1, 2, 3, 4, 5]
						delegate: ThemedRectangle { required property int modelData; width: 13; height: 22; radius: ThemeEngine.radiusTiny; color: root.swatch(schemeCell.previewData, modelData); border.width: 1; border.color: Qt.rgba(255, 255, 255, 0.16) }
					}
				}
				ThemedRectangle {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					height: 24
					color: Qt.rgba(0, 0, 0, 0.58)
					AtelierText { anchors.centerIn: parent; color: "white"; font.pixelSize: 9; font.weight: schemeCell.selected ? Font.DemiBold : Font.Medium; text: `${schemeCell.colorSpaceName} · ${schemeCell.paletteName}` }
				}
				MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.schemeSelected(schemeCell.colorSpaceName, schemeCell.paletteName) }
			}
		}
	}

	AtelierText {
		visible: root.loading
		anchors.centerIn: schemeGrid
		z: 10
		color: root.foreground
		font.pixelSize: 11
		text: "Generating previews…"
	}
}
