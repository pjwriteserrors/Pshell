pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Pinned screenshots float above all windows. One transparent layer per
// screen holds the pins of that screen and only takes input where a pin is,
// so dragging works in stable screen coordinates and the pin stays exactly
// under the pointer.
//
// Drag moves · wheel zooms around the pointer · Ctrl+wheel fades
// double-click edits · middle click closes · Ctrl+C / Ctrl+S / Esc act on
// the pin that was clicked last.
PanelWindow {
	id: root

	required property var modelData
	readonly property string name: String(root.modelData.name)
	readonly property var own: Screenshot.pins.filter(p => p.output === root.name)
	property int activePin: -1

	screen: root.modelData
	visible: pinModel.count > 0
	color: "transparent"
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	exclusiveZone: 0
	WlrLayershell.namespace: "shell-pins"
	WlrLayershell.layer: WlrLayer.Top
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: root.visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

	// only the pins take input, everything else reaches the windows below
	mask: Region {
		regions: {
			const out = [];
			for (let i = 0; i < pins.count; i += 1) {
				const item = pins.itemAt(i);
				if (item) out.push(item.region);
			}
			return out;
		}
	}

	// delegates must survive other pins coming and going, so the pins of this
	// screen are mirrored into a ListModel instead of binding the array
	ListModel {
		id: pinModel
	}

	function sync() {
		const ids = root.own.map(p => p.id);
		for (let i = pinModel.count - 1; i >= 0; i -= 1)
			if (!ids.includes(pinModel.get(i).pinId)) pinModel.remove(i);
		for (const p of root.own) {
			let known = false;
			for (let i = 0; i < pinModel.count; i += 1)
				if (pinModel.get(i).pinId === p.id) known = true;
			if (!known) pinModel.append({ pinId: p.id, path: p.path, x0: p.x, y0: p.y, w0: p.width, h0: p.height });
		}
	}

	onOwnChanged: root.sync()
	Component.onCompleted: root.sync()

	function activePath() {
		const pin = Screenshot.pins.find(p => p.id === root.activePin);
		return pin ? pin.path : "";
	}

	Item {
		anchors.fill: parent
		focus: true

		Keys.onPressed: event => {
			const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
			const path = root.activePath();
			if (path === "") return;
			if (event.key === Qt.Key_Escape) Screenshot.unpin(root.activePin);
			else if (ctrl && event.key === Qt.Key_C) Screenshot.copyFile(path);
			else if (ctrl && event.key === Qt.Key_S) Screenshot.saveCopyOf(path);
			else return;
			event.accepted = true;
		}

		Repeater {
			id: pins

			model: pinModel

			delegate: Item {
				id: pin

				required property int pinId
				required property string path
				required property real x0
				required property real y0
				required property real w0
				required property real h0

				readonly property alias region: area
				readonly property bool active: root.activePin === pin.pinId
				readonly property bool hovered: mouse.containsMouse || tools.hovered
				// size on screen at 100 %
				readonly property real baseW: pin.w0 > 0 ? pin.w0 : Math.min(image.implicitWidth, root.width * 0.7, image.implicitWidth * root.height * 0.7 / Math.max(1, image.implicitHeight))
				readonly property real baseH: pin.h0 > 0 ? pin.h0 : pin.baseW * image.implicitHeight / Math.max(1, image.implicitWidth)
				property real zoom: 1
				property real fade: 1
				property bool placed: false
				property real appear: 0

				x: 0
				y: 0
				width: pin.baseW * pin.zoom
				height: pin.baseH * pin.zoom
				z: pin.active ? 2 : 1

				Component.onCompleted: pin.place()
				Connections {
					target: image
					function onStatusChanged() {
						pin.place();
					}
				}

				function place() {
					if (pin.placed || image.status !== Image.Ready) return;
					pin.x = pin.w0 > 0 ? pin.x0 : Math.round((root.width - pin.baseW) / 2);
					pin.y = pin.w0 > 0 ? pin.y0 : Math.round((root.height - pin.baseH) / 2);
					pin.placed = true;
					pin.appear = 1;
					root.activePin = pin.pinId;
				}

				function zoomAt(factor, px, py) {
					const next = Math.max(0.2, Math.min(5, pin.zoom * factor));
					const f = next / pin.zoom;
					pin.x = pin.x + px * (1 - f);
					pin.y = pin.y + py * (1 - f);
					pin.zoom = next;
					zoomBadge.flash();
				}

				Behavior on appear {
					NumberAnimation {
						duration: Motion.medium
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatialFast
					}
				}

				Region {
					id: area

					item: pin
				}

				Item {
					anchors.fill: parent
					visible: pin.placed
					opacity: pin.fade * Math.min(1, pin.appear * 1.5)
					scale: 0.94 + 0.06 * pin.appear

					RectangularShadow {
						anchors.fill: frame
						radius: frame.radius
						blur: 24
						spread: 0
						offset.y: 6
						color: Qt.rgba(0, 0, 0, 0.5)
					}

					ClippingRectangle {
						id: frame

						anchors.fill: parent
						radius: Theme.radius.small
						color: Theme.layer1

						Image {
							id: image

							anchors.fill: parent
							source: Screenshot.fileUrl(pin.path)
							fillMode: Image.Stretch
							asynchronous: false
							cache: false
							smooth: true
							mipmap: true
						}
					}

					Rectangle {
						anchors.fill: parent
						anchors.margins: -1
						radius: frame.radius + 1
						color: "transparent"
						border.width: 1.5
						border.color: pin.hovered || mouse.pressed ? Theme.primary : Qt.alpha(Theme.fg, 0.14)

						Behavior on border.color {
							ColorAnim {}
						}
					}
				}

				MouseArea {
					id: mouse

					property real grabX: 0
					property real grabY: 0

					anchors.fill: parent
					hoverEnabled: true
					acceptedButtons: Qt.LeftButton | Qt.MiddleButton
					cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

					onPressed: event => {
						root.activePin = pin.pinId;
						mouse.grabX = event.x;
						mouse.grabY = event.y;
					}
					// the layer does not move, so screen coordinates stay stable
					onPositionChanged: event => {
						if (!pressed || !(event.buttons & Qt.LeftButton)) return;
						pin.x = Math.round(pin.x + event.x - mouse.grabX);
						pin.y = Math.round(pin.y + event.y - mouse.grabY);
					}
					onClicked: event => {
						if (event.button === Qt.MiddleButton) Screenshot.unpin(pin.pinId);
					}
					onDoubleClicked: event => {
						if (event.button === Qt.LeftButton) Screenshot.editPin(pin.pinId);
					}
					onWheel: wheel => {
						const up = (wheel.angleDelta.y || wheel.angleDelta.x) > 0;
						if (wheel.modifiers & Qt.ControlModifier) {
							pin.fade = Math.max(0.2, Math.min(1, pin.fade + (up ? 0.1 : -0.1)));
							zoomBadge.flash();
						} else {
							pin.zoomAt(up ? 1.1 : 1 / 1.1, wheel.x, wheel.y);
						}
					}
				}

				// zoom / opacity readout while it changes
				Rectangle {
					id: zoomBadge

					function flash() {
						zoomBadge.opacity = 1;
						badgeFade.restart();
					}

					anchors.left: parent.left
					anchors.bottom: parent.bottom
					anchors.margins: 8
					width: badgeText.implicitWidth + 16
					height: 24
					radius: 12
					color: Qt.alpha(Theme.base, 0.9)
					opacity: 0

					Behavior on opacity {
						Anim {
							duration: Motion.medium
						}
					}

					Timer {
						id: badgeFade
						interval: 900
						onTriggered: zoomBadge.opacity = 0
					}

					StyledText {
						id: badgeText

						anchors.centerIn: parent
						tabular: true
						text: pin.fade < 1 ? `${Math.round(pin.zoom * 100)}% · ${Math.round(pin.fade * 100)}% opacity` : `${Math.round(pin.zoom * 100)}%`
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}
				}

				// actions on hover
				Rectangle {
					id: tools

					readonly property bool hovered: toolsHover.hovered

					anchors.top: parent.top
					anchors.right: parent.right
					anchors.margins: 6
					transformOrigin: Item.TopRight
					scale: Math.min(1, (pin.width - 12) / Math.max(1, width))
					width: toolRow.implicitWidth + 8
					height: 34
					radius: 17
					color: Qt.alpha(Theme.base, 0.92)
					opacity: pin.hovered ? 1 : 0
					visible: opacity > 0.01

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}

					HoverHandler {
						id: toolsHover
					}

					Row {
						id: toolRow

						anchors.centerIn: parent
						spacing: 0

						Repeater {
							model: [
								{ icon: "content_copy", run: () => Screenshot.copyFile(pin.path) },
								{ icon: "content_save", run: () => Screenshot.saveCopyOf(pin.path) },
								{ icon: "pencil", run: () => Screenshot.editPin(pin.pinId) },
								{ icon: "close", run: () => Screenshot.unpin(pin.pinId) }
							]

							delegate: IconButton {
								required property var modelData

								width: 28
								height: 28
								icon: modelData.icon
								iconSize: 15
								onClicked: modelData.run()
							}
						}
					}
				}
			}
		}
	}
}
