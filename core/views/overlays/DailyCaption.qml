pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The story behind Bing's image of the day, set into the wallpaper like a
// caption in a photo book: the photo itself goes soft and a little darker
// behind the text (the wallpaper is redrawn here, cropped like awww does,
// and blurred through a feathered mask), so there is no card or edge.
// Shown while the "Wallpaper of the day" theme runs on a Bing image; only
// the links take input.
PanelWindow {
	id: root

	readonly property string stateDir: `${Paths.home}/.local/state/quickshell-theme`
	readonly property var info: {
		try {
			return JSON.parse(metadataFile.text() || "{}");
		} catch (error) {
			return {};
		}
	}
	readonly property bool active: themeNameFile.text().trim() === "Wallpaper of the day"
		&& root.info.provider === "bing"
		&& !!(root.info.description || root.info.headline)
	readonly property color ink: Qt.tint("#ffffff", Qt.alpha(Theme.primary, 0.08))
	readonly property color accent: Qt.tint("#ffffff", Qt.alpha(Theme.primary, 0.6))
	readonly property real feather: 120

	screen: Popups.primaryScreen
	visible: root.active
	anchors.left: true
	anchors.bottom: true
	implicitWidth: caption.x + caption.width + root.feather + 40
	implicitHeight: caption.implicitHeight + 72 + root.feather + 40
	exclusionMode: ExclusionMode.Ignore
	color: "transparent"
	WlrLayershell.namespace: "shell-daily-caption"
	WlrLayershell.layer: WlrLayer.Bottom
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {
		item: links
	}

	FileView {
		id: metadataFile

		path: `${root.stateDir}/wallpaper-of-day.json`
		watchChanges: true
		onFileChanged: reload()
	}

	FileView {
		id: themeNameFile

		path: `${root.stateDir}/current-theme-name`
		watchChanges: true
		onFileChanged: reload()
	}

	FontLoader {
		id: serif

		source: `${Paths.assets}/fonts/InstrumentSerif-Regular.ttf`
	}

	FontLoader {
		source: `${Paths.assets}/fonts/InstrumentSerif-Italic.ttf`
	}

	// the wallpaper under the caption, in screen coordinates
	Item {
		id: haze

		anchors.fill: parent
		visible: false
		layer.enabled: true
		clip: true

		Image {
			x: 0
			y: root.height - (root.screen?.height ?? root.height)
			width: root.screen?.width ?? root.width
			height: root.screen?.height ?? root.height
			source: root.info.media_path ? `file://${root.info.media_path}?${root.info.candidate_id ?? ""}` : ""
			sourceSize.width: width
			sourceSize.height: height
			fillMode: Image.PreserveAspectCrop
			cache: false
			asynchronous: true
		}
	}

	// where the photo softens: strongest behind the text, fading out
	Item {
		id: hazeMask

		anchors.fill: parent
		visible: false
		layer.enabled: true

		RectangularShadow {
			x: caption.x - 24
			y: caption.y - 24
			width: caption.width + 48
			height: caption.height + 48
			radius: 80
			blur: root.feather
			spread: 24
			color: "white"
		}
	}

	MultiEffect {
		anchors.fill: parent
		source: haze
		blurEnabled: true
		blur: 1
		blurMax: 64
		brightness: -0.26
		saturation: 0.1
		maskEnabled: true
		maskSource: hazeMask
		maskThresholdMin: 0.5
		maskSpreadAtMin: 1
	}

	ColumnLayout {
		id: caption

		x: 72
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 72
		width: 380
		spacing: 0

		layer.enabled: true
		layer.effect: MultiEffect {
			shadowEnabled: true
			shadowColor: Qt.rgba(0, 0, 0, 0.45)
			shadowBlur: 0.8
			shadowVerticalOffset: 1
		}

		StyledText {
			text: ["Bing", root.info.date_label].filter(Boolean).join("   ·   ").toUpperCase()
			tone: root.accent
			surface: "transparent"
			font.pixelSize: Theme.size.tiny
			font.weight: Font.DemiBold
			font.letterSpacing: 2.4
		}

		Text {
			Layout.fillWidth: true
			Layout.topMargin: 10
			visible: text !== ""
			text: root.info.headline || ""
			color: root.ink
			wrapMode: Text.WordWrap
			font.family: serif.name
			font.pixelSize: 46
			lineHeight: 0.92
		}

		Text {
			Layout.fillWidth: true
			Layout.topMargin: 6
			visible: text !== ""
			text: root.info.image_title || ""
			color: Qt.alpha(root.ink, 0.82)
			wrapMode: Text.WordWrap
			font.family: serif.name
			font.italic: true
			font.pixelSize: 19
		}

		Rectangle {
			Layout.topMargin: 18
			implicitWidth: 36
			implicitHeight: 1
			color: Qt.alpha(root.ink, 0.4)
		}

		StyledText {
			Layout.fillWidth: true
			Layout.topMargin: 16
			visible: text !== ""
			text: root.info.description || ""
			tone: Qt.alpha(root.ink, 0.86)
			surface: "transparent"
			wrapMode: Text.WordWrap
			font.pixelSize: Theme.size.body
			lineHeight: 1.4
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.topMargin: 18
			visible: (root.info.quick_fact || "") !== ""
			spacing: 8

			Text {
				Layout.alignment: Qt.AlignTop
				Layout.topMargin: -8
				text: "“"
				color: root.accent
				font.family: serif.name
				font.pixelSize: 44
			}

			Text {
				Layout.fillWidth: true
				text: root.info.quick_fact || ""
				color: Qt.alpha(root.ink, 0.92)
				wrapMode: Text.WordWrap
				font.family: serif.name
				font.italic: true
				font.pixelSize: 17
				lineHeight: 1.1
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.topMargin: 22
			spacing: 18

			StyledText {
				Layout.fillWidth: true
				text: root.info.credit || ""
				tone: Qt.alpha(root.ink, 0.5)
				surface: "transparent"
				font.pixelSize: Theme.size.tiny
			}

			Row {
				id: links

				spacing: 18

				Repeater {
					model: [
						{ label: "Learn more", url: root.info.backstage_url || root.info.source_url || "" },
						{ label: "Map", url: root.info.map_url || "" },
						{ label: "Quiz", url: root.info.quiz_url || "" }
					].filter(link => link.url !== "")

					delegate: Item {
						id: link

						required property var modelData

						implicitWidth: linkRow.implicitWidth
						implicitHeight: linkRow.implicitHeight + 6

						Row {
							id: linkRow

							spacing: 4
							opacity: linkArea.containsMouse ? 1 : 0.7

							Behavior on opacity {
								Anim {}
							}

							StyledText {
								text: link.modelData.label.toUpperCase()
								tone: root.ink
								surface: "transparent"
								font.pixelSize: Theme.size.tiny
								font.weight: Font.DemiBold
								font.letterSpacing: 1.8
							}

							Glyph {
								anchors.verticalCenter: parent.verticalCenter
								icon: "arrow_top_right"
								size: 10
								color: root.accent
								surface: "transparent"
							}
						}

						Rectangle {
							anchors.bottom: parent.bottom
							height: 1
							width: linkArea.containsMouse ? linkRow.width : 0
							color: root.accent

							Behavior on width {
								Anim {}
							}
						}

						MouseArea {
							id: linkArea

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: Qt.openUrlExternally(link.modelData.url)
						}
					}
				}
			}
		}
	}
}
