pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"

// Studio's dress page: the icon set the desktop wears, and the pointer.
//
// Both lists show the real thing - icons drawn from the theme's own files, and
// a pointer decoded out of the cursor theme's own left_ptr - because a list of
// theme names tells you nothing about what you are choosing.
//
// `scripts/appearance_themes.py` does the finding and the applying. Applying
// means GSettings, GTK 3 and 4, Qt's own config, the Xcursor default, and
// niri's cursor block, all at once: a cursor set in only one of those places
// leaves half the session on the old one, which reads as "it did not work".
//
// If you are writing a new style: keep this page and keep it calling that
// script. Draw the lists however your style draws lists. See STUDIO.md.
Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor

	property var iconThemes: []
	property var cursorThemes: []
	property int iconIndex: 0
	property int cursorIndex: 0
	property string column: "icons"          // which list the keyboard is in
	property string liveIcon: ""
	property string liveCursor: ""
	property int liveCursorSize: 24
	property bool loading: false

	readonly property string scriptPath: `${Quickshell.shellDir}/scripts/appearance_themes.py`

	readonly property var currentIcon: root.iconThemes.length > 0
		? root.iconThemes[Math.max(0, Math.min(root.iconThemes.length - 1, root.iconIndex))]
		: null
	readonly property var currentCursor: root.cursorThemes.length > 0
		? root.cursorThemes[Math.max(0, Math.min(root.cursorThemes.length - 1, root.cursorIndex))]
		: null

	readonly property bool dressed: root.currentIcon
		&& root.currentCursor
		&& String(root.currentIcon.id) === root.liveIcon
		&& String(root.currentCursor.id) === root.liveCursor

	focus: true

	function reset() {
		root.loading = true;
		listProcess.running = true;
		currentProcess.running = true;
		Qt.callLater(function () {
			root.forceActiveFocus();
		});
	}

	function selectByIds(iconId, cursorId) {
		for (let i = 0; i < root.iconThemes.length; i += 1) {
			if (String(root.iconThemes[i].id) === iconId) {
				root.iconIndex = i;
				break;
			}
		}
		for (let i = 0; i < root.cursorThemes.length; i += 1) {
			if (String(root.cursorThemes[i].id) === cursorId) {
				root.cursorIndex = i;
				break;
			}
		}
	}

	function move(delta) {
		if (root.column === "icons") {
			if (root.iconThemes.length === 0) return;
			root.iconIndex = Math.max(0, Math.min(root.iconThemes.length - 1, root.iconIndex + delta));
			iconGrid.positionViewAtIndex(root.iconIndex, GridView.Contain);
		} else {
			if (root.cursorThemes.length === 0) return;
			root.cursorIndex = Math.max(0, Math.min(root.cursorThemes.length - 1, root.cursorIndex + delta));
			cursorRow.positionViewAtIndex(root.cursorIndex, ListView.Contain);
		}
	}

	function apply() {
		if (!root.currentIcon && !root.currentCursor) return;
		const command = ["python3", root.scriptPath, "apply"];
		if (root.currentIcon) command.push("--icon", String(root.currentIcon.id));
		if (root.currentCursor) {
			command.push("--cursor", String(root.currentCursor.id));
			command.push("--cursor-size", String(root.liveCursorSize));
		}
		Quickshell.execDetached(command);
		root.liveIcon = root.currentIcon ? String(root.currentIcon.id) : root.liveIcon;
		root.liveCursor = root.currentCursor ? String(root.currentCursor.id) : root.liveCursor;
	}

	Component.onCompleted: root.reset()
	Keys.onEscapePressed: root.closeRequested()
	Keys.onReturnPressed: root.apply()
	Keys.onEnterPressed: root.apply()
	Keys.onLeftPressed: root.move(-1)
	Keys.onRightPressed: root.move(1)
	Keys.onUpPressed: root.move(root.column === "icons" ? -iconGrid.columns : -1)
	Keys.onDownPressed: root.move(root.column === "icons" ? iconGrid.columns : 1)
	Keys.onTabPressed: root.column = root.column === "icons" ? "cursors" : "icons"

	Process {
		id: listProcess
		command: ["python3", root.scriptPath, "list"]

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const parsed = JSON.parse(String(text || "{}"));
					root.iconThemes = parsed.icons || [];
					root.cursorThemes = parsed.cursors || [];
					root.selectByIds(root.liveIcon, root.liveCursor);
				} catch (error) {
					root.iconThemes = [];
					root.cursorThemes = [];
				}
				root.loading = false;
			}
		}
	}

	Process {
		id: currentProcess
		command: ["python3", root.scriptPath, "current"]

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const parsed = JSON.parse(String(text || "{}"));
					root.liveIcon = String(parsed.icon || "");
					root.liveCursor = String(parsed.cursor || "");
					root.liveCursorSize = Number(parsed.cursorSize || 24);
					root.selectByIds(root.liveIcon, root.liveCursor);
				} catch (error) {
					// leave what we had
				}
			}
		}
	}

	Column {
		anchors.fill: parent
		anchors.margins: 6
		spacing: 12

		Text {
			text: "Icons & Pointer"
			color: root.foreground
			font.family: "C059"
			font.pixelSize: 34
		}

		Text {
			width: parent.width
			color: root.foreground
			opacity: 0.65
			font.pixelSize: 12
			elide: Text.ElideRight
			text: root.loading
				? "Reading the icon and cursor themes on this machine…"
				: `Worn now: ${root.liveIcon || "-"} · pointer ${root.liveCursor || "-"} at ${root.liveCursorSize} px`
		}

		// ------------------------------------------------------- the icon sets
		GridView {
			id: iconGrid

			readonly property int columns: Math.max(1, Math.floor(width / 250))

			width: parent.width
			height: Math.max(120, parent.height - 300)
			clip: true
			model: root.iconThemes
			cellWidth: width / iconGrid.columns
			cellHeight: 134
			currentIndex: root.iconIndex
			boundsBehavior: Flickable.StopAtBounds

			delegate: Item {
				id: iconCard

				required property var modelData
				required property int index

				readonly property bool chosen: root.iconIndex === iconCard.index
				readonly property bool live: String(iconCard.modelData.id) === root.liveIcon

				width: iconGrid.cellWidth
				height: iconGrid.cellHeight

				Rectangle {
					anchors.fill: parent
					anchors.margins: 6
					radius: ThemeEngine.radiusLarge
					color: iconCard.chosen
						? root.secondaryBoxStrongColor
						: iconMouse.containsMouse ? root.secondaryBoxColor : Qt.alpha(root.secondaryBoxColor, 0.45)
					border.width: iconCard.chosen && root.column === "icons" ? 1 : 0
					border.color: root.barColor

					Behavior on color {
						CAnim {}
					}

					Column {
						anchors.fill: parent
						anchors.margins: 14
						spacing: 8

						// The theme, in its own hand.
						Row {
							spacing: 8

							Repeater {
								model: (iconCard.modelData.samples || []).slice(0, 4)

								delegate: Image {
									required property string modelData
									width: 30
									height: 30
									source: `file://${modelData}`
									sourceSize: Qt.size(60, 60)
									fillMode: Image.PreserveAspectFit
									smooth: true
									mipmap: true
									asynchronous: true
								}
							}
						}

						Text {
							width: parent.width
							color: root.foreground
							font.pixelSize: 14
							font.weight: iconCard.chosen ? Font.DemiBold : Font.Medium
							elide: Text.ElideRight
							text: String(iconCard.modelData.name || iconCard.modelData.id)
						}

						Text {
							width: parent.width
							color: root.foreground
							opacity: iconCard.live ? 0.8 : 0.55
							font.family: iconCard.live ? "Adwaita Mono" : "sans-serif"
							font.pixelSize: 11
							elide: Text.ElideRight
							text: iconCard.live
								? "WORN"
								: String(iconCard.modelData.comment || "")
						}
					}

					MouseArea {
						id: iconMouse
						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							root.forceActiveFocus();
							root.column = "icons";
							root.iconIndex = iconCard.index;
						}
						onDoubleClicked: root.apply()
					}
				}
			}

			ScrollBar.vertical: ScrollBar {}
		}

		// -------------------------------------------------------- the pointers
		Text {
			text: "Pointer"
			color: root.foreground
			opacity: root.column === "cursors" ? 1 : 0.6
			font.family: "Adwaita Mono"
			font.pixelSize: 10
		}

		ListView {
			id: cursorRow

			width: parent.width
			height: 76
			orientation: ListView.Horizontal
			clip: true
			model: root.cursorThemes
			currentIndex: root.cursorIndex
			spacing: 8
			boundsBehavior: Flickable.StopAtBounds

			delegate: Rectangle {
				id: cursorCard

				required property var modelData
				required property int index

				readonly property bool chosen: root.cursorIndex === cursorCard.index
				readonly property bool live: String(cursorCard.modelData.id) === root.liveCursor

				width: 168
				height: cursorRow.height
				radius: ThemeEngine.radiusLarge
				color: cursorCard.chosen
					? root.secondaryBoxStrongColor
					: cursorMouse.containsMouse ? root.secondaryBoxColor : Qt.alpha(root.secondaryBoxColor, 0.45)
				border.width: cursorCard.chosen && root.column === "cursors" ? 1 : 0
				border.color: root.barColor

				Behavior on color {
					CAnim {}
				}

				Image {
					id: pointerMark
					anchors.left: parent.left
					anchors.leftMargin: 14
					anchors.verticalCenter: parent.verticalCenter
					width: 28
					height: 28
					source: String(cursorCard.modelData.preview || "") === ""
						? ""
						: `file://${cursorCard.modelData.preview}`
					sourceSize: Qt.size(64, 64)
					fillMode: Image.PreserveAspectFit
					smooth: true
					asynchronous: true
				}

				Column {
					anchors.left: pointerMark.right
					anchors.leftMargin: 12
					anchors.right: parent.right
					anchors.rightMargin: 12
					anchors.verticalCenter: parent.verticalCenter
					spacing: 1

					Text {
						width: parent.width
						color: root.foreground
						font.pixelSize: 12
						font.weight: cursorCard.chosen ? Font.DemiBold : Font.Medium
						elide: Text.ElideRight
						text: String(cursorCard.modelData.name || cursorCard.modelData.id)
					}

					Text {
						width: parent.width
						color: root.foreground
						opacity: 0.5
						font.family: "Adwaita Mono"
						font.pixelSize: 9
						text: cursorCard.live ? "WORN" : ""
					}
				}

				MouseArea {
					id: cursorMouse
					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: {
						root.forceActiveFocus();
						root.column = "cursors";
						root.cursorIndex = cursorCard.index;
					}
					onDoubleClicked: root.apply()
				}
			}

			ScrollBar.horizontal: ScrollBar {}
		}

		// How big the pointer is drawn - the one number on this page.
		Row {
			width: parent.width
			height: 24
			spacing: 8

			Text {
				height: 24
				verticalAlignment: Text.AlignVCenter
				color: root.foreground
				opacity: 0.6
				font.family: "Adwaita Mono"
				font.pixelSize: 10
				text: "SIZE"
			}

			Repeater {
				model: [16, 24, 32, 48, 64]

				delegate: Rectangle {
					required property int modelData

					width: 42
					height: 24
					radius: ThemeEngine.radiusMedium
					color: root.liveCursorSize === modelData
						? Qt.alpha(root.barColor, 0.28)
						: Qt.alpha(root.secondaryBoxColor, 0.45)
					border.width: root.liveCursorSize === modelData ? 1 : 0
					border.color: Qt.alpha(root.barColor, 0.52)

					Behavior on color {
						CAnim {}
					}

					Text {
						anchors.centerIn: parent
						color: root.foreground
						opacity: root.liveCursorSize === modelData ? 1 : 0.6
						font.family: "Adwaita Mono"
						font.pixelSize: 11
						text: String(modelData)
					}

					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.PointingHandCursor
						onClicked: root.liveCursorSize = modelData
					}
				}
			}
		}

		Rectangle {
			width: parent.width
			height: 44
			radius: ThemeEngine.radiusMedium
			color: dressMouse.containsMouse && !root.dressed
				? Qt.lighter(root.secondaryBoxStrongColor, 1.15)
				: root.secondaryBoxStrongColor
			opacity: root.dressed ? 0.5 : 1

			Behavior on color {
				CAnim {}
			}

			Text {
				anchors.centerIn: parent
				color: root.foreground
				font.pixelSize: 13
				text: root.loading
					? "Looking…"
					: root.dressed ? "Already worn" : "Wear these"
			}

			MouseArea {
				id: dressMouse
				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: {
					root.forceActiveFocus();
					root.apply();
				}
			}
		}
	}
}
