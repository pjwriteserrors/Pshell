pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

FloatingWindow {
	id: root

	required property var game
	required property color foreground
	required property color background
	required property color accent
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor

	title: "Archiv der verlorenen Stunden"
	visible: false
	implicitWidth: 980
	implicitHeight: 760
	minimumSize: Qt.size(760, 600)
	color: root.background

	function openWindow() {
		root.visible = true;
		root.minimized = false;
		floatTimer.restart();
	}

	function closeWindow() {
		root.visible = false;
	}

	function showTab(index) {
		windowContent.tab = Math.max(0, Math.min(4, index));
		root.openWindow();
	}

	Timer {
		id: floatTimer
		interval: 160
		repeat: false
		onTriggered: Quickshell.execDetached(["niri", "msg", "action", "move-window-to-floating"])
	}

	Rectangle {
		anchors.fill: parent
		color: root.background

		Rectangle {
			id: titleBar
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			height: 42
			color: root.secondaryBoxStrongColor
			z: 2

			Rectangle {
				anchors.left: parent.left
				anchors.leftMargin: 14
				anchors.verticalCenter: parent.verticalCenter
				width: 22
				height: 22
				radius: 7
				color: root.accent

				Text {
					anchors.centerIn: parent
					color: root.background
					font.pixelSize: 12
					font.bold: true
					text: "◆"
				}
			}

			Text {
				anchors.left: parent.left
				anchors.leftMargin: 46
				anchors.verticalCenter: parent.verticalCenter
				color: root.foreground
				font.pixelSize: 12
				font.weight: Font.DemiBold
				text: "Archiv der verlorenen Stunden"
			}

			MouseArea {
				anchors.left: parent.left
				anchors.right: windowButtons.left
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				acceptedButtons: Qt.LeftButton
				onPressed: {
					if (!root.fullscreen) root.startSystemMove();
				}
				onDoubleClicked: {
					if (!root.fullscreen) root.maximized = !root.maximized;
				}
			}

			Row {
				id: windowButtons
				anchors.right: parent.right
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				spacing: 5

				Repeater {
					model: [
						{ icon: "−", hint: "Minimieren", action: "minimize" },
						{ icon: root.maximized ? "❐" : "□", hint: "Maximieren", action: "maximize" },
						{ icon: root.fullscreen ? "⊡" : "⛶", hint: "Vollbild", action: "fullscreen" },
						{ icon: "×", hint: "Schließen", action: "close" }
					]

					Rectangle {
						id: windowButton
						required property var modelData
						width: 30
						height: 28
						radius: 8
						color: buttonMouse.containsMouse
							? (modelData.action === "close" ? "#d95c5c" : root.secondaryBoxColor)
							: "transparent"

						Text {
							anchors.centerIn: parent
							color: root.foreground
							font.pixelSize: 14
							text: windowButton.modelData.icon
						}

						MouseArea {
							id: buttonMouse
							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: {
								switch (windowButton.modelData.action) {
								case "minimize": root.minimized = true; break;
								case "maximize": root.fullscreen = false; root.maximized = !root.maximized; break;
								case "fullscreen": root.fullscreen = !root.fullscreen; break;
								case "close": root.closeWindow(); break;
								}
							}
						}
					}
				}
			}
		}

		RpgPopupContent {
			id: windowContent
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: titleBar.bottom
			anchors.bottom: parent.bottom
			game: root.game
			foreground: root.foreground
			background: root.background
			accent: root.accent
			secondaryBoxColor: root.secondaryBoxColor
			secondaryBoxStrongColor: root.secondaryBoxStrongColor
			secondaryInsetColor: root.secondaryInsetColor
		}
	}
}
