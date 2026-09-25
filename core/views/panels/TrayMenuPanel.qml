pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.SystemTray
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Tray drop-down. The first page lists every tray app: click activates it
// (or opens its menu for menu-only apps), right click or the chevron opens
// its menu, middle click triggers the secondary action. Menus and submenus
// slide in from the right; "Back" slides back out.
Drawer {
	id: root

	property var stack: []
	readonly property var handle: root.stack.length > 0 ? root.stack[root.stack.length - 1] : null
	property string menuTitle: ""
	property int direction: 1

	panelId: "tray"
	panelWidth: 300
	padding: 10
	keyboard: false
	contentHeight: content.implicitHeight

	onPanelOpened: {
		root.stack = [];
		root.menuTitle = "";
	}

	function openMenu(item) {
		if (!item?.hasMenu) return;
		root.menuTitle = item.tooltipTitle || item.title || item.id;
		root.push(item.menu);
	}

	function push(menu) {
		root.direction = 1;
		root.stack = root.stack.concat([menu]);
		slide.restart();
	}

	function pop() {
		root.direction = -1;
		root.stack = root.stack.slice(0, -1);
		slide.restart();
	}

	QsMenuOpener {
		id: opener
		menu: root.handle
	}

	ColumnLayout {
		id: content

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 2

		transform: Translate {
			id: shift
		}

		// ── tray apps ─────────────────────────────────────────────────────
		SectionLabel {
			Layout.leftMargin: 8
			Layout.topMargin: 2
			Layout.bottomMargin: 4
			visible: root.stack.length === 0
			text: "Tray"
		}

		Repeater {
			model: root.stack.length === 0 ? SystemTray.items.values : []

			delegate: Clickable {
				id: app

				required property SystemTrayItem modelData

				Layout.fillWidth: true
				implicitHeight: 40
				radius: Theme.radius.medium
				pressedScale: 0.97
				acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
				onClicked: {
					if (app.modelData.onlyMenu && app.modelData.hasMenu) {
						root.openMenu(app.modelData);
						return;
					}
					app.modelData.activate();
					Popups.close();
				}
				onRightClicked: {
					if (app.modelData.hasMenu) root.openMenu(app.modelData);
					else app.modelData.secondaryActivate();
				}
				onMiddleClicked: app.modelData.secondaryActivate()

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 10
					anchors.rightMargin: 4
					spacing: 10

					Image {
						Layout.preferredWidth: 20
						Layout.preferredHeight: 20
						source: AppIcons.app(AppIcons.trayIconSource(app.modelData.icon))
						sourceSize: Qt.size(40, 40)
						fillMode: Image.PreserveAspectFit
						asynchronous: true
						smooth: true
						mipmap: true
					}

					StyledText {
						Layout.fillWidth: true
						text: app.modelData.tooltipTitle || app.modelData.title || app.modelData.id
						font.pixelSize: Theme.size.label
						font.weight: Font.Medium
					}

					IconButton {
						visible: app.modelData.hasMenu
						Layout.preferredWidth: 30
						Layout.preferredHeight: 30
						icon: "dots_horizontal"
						iconSize: 16
						onClicked: root.openMenu(app.modelData)
					}
				}
			}
		}

		// ── menu ──────────────────────────────────────────────────────────
		Clickable {
			Layout.fillWidth: true
			visible: root.stack.length > 0
			implicitHeight: 36
			radius: Theme.radius.medium
			color: Theme.layer1
			onClicked: root.pop()

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 10
				anchors.rightMargin: 10
				spacing: 8

				Glyph {
					icon: "arrow_left"
					size: 16
				}

				StyledText {
					Layout.fillWidth: true
					text: root.stack.length > 1 ? "Back" : root.menuTitle
					font.weight: Font.DemiBold
				}
			}
		}

		Repeater {
			model: root.stack.length > 0 ? opener.children : []

			delegate: Loader {
				id: row

				required property QsMenuEntry modelData

				Layout.fillWidth: true
				sourceComponent: row.modelData.isSeparator ? separator : entry

				Component {
					id: separator

					Item {
						implicitHeight: 9

						Rectangle {
							anchors.centerIn: parent
							width: parent.width - 16
							height: 1
							color: Theme.outline
						}
					}
				}

				Component {
					id: entry

					Clickable {
						implicitHeight: 34
						radius: Theme.radius.medium
						interactive: row.modelData.enabled
						opacity: row.modelData.enabled ? 1 : 0.4
						pressedScale: 0.97
						onClicked: {
							if (row.modelData.hasChildren) {
								root.push(row.modelData);
							} else {
								row.modelData.triggered();
								Popups.close();
							}
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 10
							anchors.rightMargin: 8
							spacing: 10

							Item {
								Layout.preferredWidth: 16
								Layout.preferredHeight: 16

								Image {
									anchors.fill: parent
									visible: row.modelData.icon !== ""
									source: row.modelData.icon
									sourceSize: Qt.size(32, 32)
									fillMode: Image.PreserveAspectFit
								}

								Glyph {
									anchors.centerIn: parent
									visible: row.modelData.icon === "" && row.modelData.buttonType !== QsMenuButtonType.None
									icon: row.modelData.checkState === Qt.Checked ? (row.modelData.buttonType === QsMenuButtonType.RadioButton ? "record" : "check") : ""
									size: 15
									color: Theme.primary
								}
							}

							StyledText {
								Layout.fillWidth: true
								text: row.modelData.text
								font.pixelSize: Theme.size.label
							}

							Glyph {
								visible: row.modelData.hasChildren
								icon: "chevron_right"
								size: 16
								color: Theme.textMuted
							}
						}
					}
				}
			}
		}
	}

	ParallelAnimation {
		id: slide

		NumberAnimation {
			target: shift
			property: "x"
			from: 40 * root.direction
			to: 0
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}
		NumberAnimation {
			target: content
			property: "opacity"
			from: 0
			to: 1
			duration: Motion.medium
		}
	}
}
