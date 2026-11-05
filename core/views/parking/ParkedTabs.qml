pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.shelf

// The windows parked on a screen's right edge (Parking), one tab each like a
// docked shelf: the icon, the icon with the title, or the window live. A click
// brings the window back onto the workspace the screen shows, a middle click
// closes it, a right click picks how it shows. Resting on a tab that is not
// live shows the window live beside it.
PanelWindow {
	id: root

	required property var modelData
	readonly property string name: String(root.modelData.name)
	readonly property var own: Parking.parked[root.name] ?? []

	property var menuEntries: []
	property real menuY: 0
	property real menuRight: 0
	readonly property bool menuOpen: root.menuEntries.length > 0

	// the tab the pointer rests on, for the live look beside it
	property int peekId: -1
	property real peekCenter: 0
	property real peekRight: 0
	property var peekSize: [16, 9]

	screen: root.modelData
	visible: root.own.length > 0
	anchors {
		top: true
		bottom: true
		right: true
	}
	implicitWidth: 760
	exclusiveZone: 0
	color: "transparent"
	mask: Region {
		item: root.menuOpen ? catcher : tabs
	}
	WlrLayershell.namespace: "shell-parked"
	WlrLayershell.layer: WlrLayer.Top
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	onOwnChanged: if (!root.own.some(window => window.id === root.peekId)) root.peekId = -1
	onPeekIdChanged: Parking.peeking = root.peekId
	Component.onDestruction: if (Parking.peeking === root.peekId) Parking.peeking = -1

	function openMenu(window, tabItem) {
		const entries = Parking.views.map(view => ({
			label: view.label,
			icon: view.icon,
			checked: () => Parking.viewOf(window.id) === view.id,
			run: () => Parking.setView(window.id, view.id)
		}));
		entries.push({ label: "Same for all", icon: "select_all", run: () => Parking.setViewForAll(Parking.viewOf(window.id)) });
		entries.push({ separator: true });
		if (Parking.canPause) entries.push({
			label: "Pause while parked",
			icon: "pause_circle_outline",
			checked: () => Parking.pausesWhileParked(window.id),
			run: () => Parking.setPauseWhileParked(window.id, !Parking.pausesWhileParked(window.id))
		});
		entries.push({ label: "Bring back", icon: "restore", run: () => Parking.restore(window.id) });
		entries.push({ label: "Close", icon: "window_close", danger: true, run: () => Niri.closeWindow(window.id) });
		const top = tabItem.mapToItem(root.contentItem, 0, 0);
		root.peekId = -1;
		root.menuRight = top.x - 8;
		root.menuY = top.y;
		root.menuEntries = entries;
	}

	// a click next to the open menu closes it
	MouseArea {
		id: catcher

		anchors.fill: parent
		enabled: root.menuOpen
		acceptedButtons: Qt.AllButtons
		onPressed: root.menuEntries = []
	}

	Column {
		id: tabs

		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		spacing: 6

		Repeater {
			model: root.own

			delegate: Item {
				id: tab

				required property var modelData
				readonly property int windowId: tab.modelData.id
				readonly property string view: {
					Parking.view;
					Parking.viewFor;
					return Parking.viewOf(tab.windowId);
				}
				readonly property bool live: tab.view === "live"
				readonly property bool titled: tab.view === "title"
				readonly property bool hovered: mouse.containsMouse
				readonly property bool busy: !!Agents.busy[tab.windowId]
				readonly property bool news: {
					Parking.seenTitle;
					return Parking.hasNews(tab.modelData);
				}
				readonly property string title: Agents.topic(tab.modelData.title) || tab.modelData.appId
				readonly property real aspect: {
					const size = tab.modelData.size;
					return Math.max(0.3, Math.min(1.4, Number(size?.[1] || 9) / Math.max(1, Number(size?.[0] || 16))));
				}
				readonly property real faceWidth: tab.live ? 300 : tab.titled ? 250 : tab.hovered ? 48 : 40
				property real shown: 0

				width: tab.live ? 300 : tab.titled ? 250 : 48
				height: tab.live ? 40 + Math.round(Math.max(96, Math.min(220, 284 * tab.aspect))) : tab.titled ? 56 : 48

				Component.onCompleted: tab.shown = 1

				Behavior on shown {
					NumberAnimation {
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.emphasized
					}
				}

				Behavior on height {
					NumberAnimation {
						duration: Motion.medium
						easing.type: Easing.OutCubic
					}
				}

				Rectangle {
					id: face

					x: tab.width - face.width * tab.shown
					width: tab.faceWidth
					height: tab.height
					topLeftRadius: Theme.radius.large
					bottomLeftRadius: Theme.radius.large
					color: tab.hovered ? Theme.layer1 : Theme.base
					border.width: tab.modelData.urgent ? 2 : 1
					border.color: tab.modelData.urgent ? Theme.primary : Theme.outline
					clip: true

					Behavior on width {
						NumberAnimation {
							duration: Motion.medium
							easing.type: Easing.OutCubic
						}
					}

					Behavior on color {
						ColorAnim {}
					}

					// urgent: it breathes until looked at
					SequentialAnimation on opacity {
						running: tab.modelData.urgent
						loops: Animation.Infinite
						onRunningChanged: if (!running) face.opacity = 1

						NumberAnimation {
							to: 0.55
							duration: 700
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							to: 1
							duration: 700
							easing.type: Easing.InOutSine
						}
					}

					// the app, with what happened since it was last looked at
					Item {
						id: badge

						x: 9
						y: tab.live ? 8 : (tab.height - badge.height) / 2
						width: tab.live ? 20 : 24
						height: badge.width

						Image {
							anchors.fill: parent
							source: AppIcons.forAppId(tab.modelData.appId)
							sourceSize: Qt.size(48, 48)
							fillMode: Image.PreserveAspectFit
							asynchronous: true
							smooth: true
							mipmap: true
						}

						Spinner {
							anchors.centerIn: parent
							width: parent.width + 10
							height: width
							visible: tab.busy
							color: Theme.primary
						}

						// paused while parked
						Rectangle {
							x: parent.width - width + 3
							y: parent.height - height + 3
							width: 13
							height: 13
							radius: 6.5
							color: Theme.warning
							border.width: 1.5
							border.color: face.color
							scale: Parking.pausedIds.includes(Number(tab.modelData.id)) ? 1 : 0
							visible: scale > 0.01

							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Glyph {
								anchors.centerIn: parent
								icon: "pause"
								size: 8
								color: Theme.bg
							}
						}

						Rectangle {
							x: parent.width - width / 2 - 1
							y: -height / 2 + 1
							width: 9
							height: 9
							radius: 4.5
							visible: tab.news && !tab.busy
							color: Theme.primary
							border.width: 1.5
							border.color: face.color
						}
					}

					StyledText {
						visible: tab.live
						x: badge.x + badge.width + 8
						anchors.verticalCenter: badge.verticalCenter
						width: face.width - x - 10
						text: tab.title
						elide: Text.ElideRight
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}

					Column {
						visible: tab.titled
						x: badge.x + badge.width + 10
						anchors.verticalCenter: parent.verticalCenter
						width: face.width - x - 12
						spacing: 1

						StyledText {
							width: parent.width
							text: tab.title
							elide: Text.ElideRight
							maximumLineCount: 2
							wrapMode: Text.Wrap
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
						}

						StyledText {
							width: parent.width
							visible: tab.title !== tab.modelData.appId
							text: tab.modelData.appId
							elide: Text.ElideRight
							tone: Theme.textMuted
							font.pixelSize: Theme.size.tiny
						}
					}

					LiveShot {
						visible: tab.live
						x: 8
						y: 36
						width: face.width - 14
						height: tab.height - 44
						windowId: tab.windowId
						appId: tab.modelData.appId
					}
				}

				MouseArea {
					id: mouse

					anchors.fill: parent
					hoverEnabled: true
					acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
					cursorShape: Qt.PointingHandCursor
					onContainsMouseChanged: {
						if (mouse.containsMouse) {
							Parking.markSeen(tab.windowId);
							if (!tab.live && !root.menuOpen) peekDelay.restart();
						} else {
							peekDelay.stop();
							if (root.peekId === tab.windowId) root.peekId = -1;
						}
					}
					onClicked: event => {
						if (event.button === Qt.MiddleButton) Niri.closeWindow(tab.windowId);
						else if (event.button === Qt.RightButton) root.openMenu(tab.modelData, tab);
						else Parking.restore(tab.windowId);
					}
				}

				Timer {
					id: peekDelay

					interval: 350
					onTriggered: {
						const at = tab.mapToItem(root.contentItem, 0, 0);
						root.peekCenter = at.y + tab.height / 2;
						root.peekRight = at.x + tab.width - face.width - 10;
						root.peekSize = tab.modelData.size;
						root.peekId = tab.windowId;
					}
				}
			}
		}
	}

	// ── the window live beside the tab the pointer rests on ───────────────
	Rectangle {
		id: peek

		readonly property real aspect: Math.max(0.3, Math.min(1.4, Number(root.peekSize?.[1] || 9) / Math.max(1, Number(root.peekSize?.[0] || 16))))
		readonly property var window: root.own.find(window => window.id === root.peekId) ?? null

		width: 360
		height: Math.round(352 * peek.aspect) + 8 + (peekTitle.visible ? peekTitle.height + 6 : 0)
		x: root.peekRight - peek.width
		y: Math.max(8, Math.min(root.height - peek.height - 8, root.peekCenter - peek.height / 2))
		visible: opacity > 0
		opacity: peek.window ? 1 : 0
		scale: peek.window ? 1 : 0.94
		transformOrigin: Item.Right
		radius: Theme.radius.large
		color: Theme.base
		border.width: 1
		border.color: Theme.outline

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		StyledText {
			id: peekTitle

			visible: !!peek.window && Parking.viewOf(peek.window.id) === "icon"
			x: 12
			y: 8
			width: peek.width - 24
			text: peek.window ? (Agents.topic(peek.window.title) || peek.window.appId) : ""
			elide: Text.ElideRight
			font.pixelSize: Theme.size.label
			font.weight: Font.DemiBold
		}

		LiveShot {
			x: 4
			y: peekTitle.visible ? peekTitle.y + peekTitle.height + 6 : 4
			width: peek.width - 8
			height: peek.height - y - 4
			windowId: peek.window?.id ?? -1
			appId: peek.window?.appId ?? ""
		}
	}

	ShelfMenu {
		id: menu

		x: root.menuRight - menu.implicitWidth
		y: Math.max(8, Math.min(root.height - menu.implicitHeight - 8, root.menuY))
		visible: root.menuOpen
		entries: root.menuEntries
		onDone: root.menuEntries = []
	}

	// a parked window live (Parking's pictures), its icon until the first one
	// comes; two pictures take turns, so a new frame never blinks
	component LiveShot: ClippingRectangle {
		id: root

		property int windowId: -1
		property string appId: ""
		readonly property string picture: root.windowId < 0 ? "" : Parking.shot(root.windowId, Parking.shotsRev)
		readonly property bool ready: (front.shown && front.status === Image.Ready) || (back.shown && back.status === Image.Ready)

		radius: Theme.radius.medium
		color: Theme.layer1

		onPictureChanged: {
			if (root.picture === "") return;
			if (front.shown && front.status === Image.Ready) back.source = root.picture;
			else front.source = root.picture;
		}
		Component.onCompleted: if (root.picture !== "") front.source = root.picture

		Image {
			anchors.centerIn: parent
			width: Math.min(40, parent.height * 0.4)
			height: width
			visible: !root.ready
			source: AppIcons.forAppId(root.appId)
			sourceSize: Qt.size(64, 64)
			fillMode: Image.PreserveAspectFit
			asynchronous: true
			opacity: 0.6
		}

		Image {
			id: front

			property bool shown: true

			anchors.fill: parent
			visible: status === Image.Ready && shown
			fillMode: Image.PreserveAspectCrop
			verticalAlignment: Image.AlignTop
			asynchronous: true
			cache: false
			smooth: true
			mipmap: true
			onStatusChanged: if (status === Image.Ready) {
				front.shown = true;
				back.shown = false;
			}
		}

		Image {
			id: back

			property bool shown: false

			anchors.fill: parent
			visible: status === Image.Ready && shown
			fillMode: Image.PreserveAspectCrop
			verticalAlignment: Image.AlignTop
			asynchronous: true
			cache: false
			smooth: true
			mipmap: true
			onStatusChanged: if (status === Image.Ready) {
				back.shown = true;
				front.shown = false;
			}
		}
	}
}
