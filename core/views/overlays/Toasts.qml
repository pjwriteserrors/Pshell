pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Toast stack under the right end of the bar. Toasts glide in from the edge,
// hovering pauses their countdown ring, dragging sideways throws them away.
PanelWindow {
	id: root

	required property var modelData
	screen: modelData

	anchors {
		top: true
		right: true
	}
	margins.top: Theme.barHeight + 10
	margins.right: 12
	implicitWidth: 392
	implicitHeight: Math.max(1, list.contentHeight + 24)
	exclusiveZone: 0
	color: "transparent"
	visible: Notifs.toasts.length > 0 || list.count > 0
	WlrLayershell.namespace: "shell-toasts"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {
		item: list
	}

	ListView {
		id: list

		x: 6
		width: parent.width - 12
		height: contentHeight
		interactive: false
		spacing: 10
		model: Notifs.toasts

		add: Transition {
			ParallelAnimation {
				SpatialAnim {
					property: "x"
					from: 380
					to: 0
				}
				Anim {
					property: "opacity"
					from: 0
					to: 1
				}
			}
		}
		displaced: Transition {
			SpatialAnim {
				property: "y"
				duration: Motion.medium
			}
		}

		delegate: Item {
			id: toast

			required property var modelData
			readonly property var notification: toast.modelData.notification
			readonly property bool internal: !!toast.modelData.internal
			readonly property color urgency: toast.internal
				? (toast.modelData.status === "error" ? Theme.danger : Theme.primary)
				: Notifs.urgencyColor(toast.notification?.urgency ?? -1)
			readonly property string iconSource: toast.internal ? "" : Notifs.iconFor(toast.notification?.image ?? "", toast.notification?.appIcon ?? "")
			property real remaining: 1
			property bool leaving: false

			width: ListView.view.width
			height: card.implicitHeight

			function leave(direction) {
				if (toast.leaving) return;
				toast.leaving = true;
				exit.to = (direction >= 0 ? 1 : -1) * (toast.width + 40);
				exit.start();
			}

			NumberAnimation on remaining {
				id: countdown

				from: 1
				to: 0
				duration: toast.modelData.duration
				paused: hover.hovered || drag.active
				onFinished: toast.leave(1)
			}

			NumberAnimation {
				id: exit

				target: card
				property: "x"
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.accel
				onFinished: {
					if (toast.internal) Notifs.removeToast(toast.modelData.toastId);
					else if (card.x !== 0 && toast.remaining > 0) Notifs.dismissToast(toast.modelData);
					else Notifs.removeToast(toast.modelData.toastId);
				}
			}

			Rectangle {
				id: card

				width: parent.width
				implicitHeight: content.implicitHeight + 28
				radius: Theme.radius.huge
				color: Theme.base
				border.width: 1
				border.color: Qt.alpha(toast.urgency, 0.25)
				opacity: 1 - Math.min(0.85, Math.abs(x) / width)
				rotation: x / 70

				Behavior on x {
					enabled: !drag.active && !exit.running
					SpatialAnim {
						duration: Motion.medium
					}
				}

				HoverHandler {
					id: hover
				}

				DragHandler {
					id: drag

					target: card
					yAxis.enabled: false
					onActiveChanged: {
						if (active) return;
						if (Math.abs(card.x) > toast.width * 0.3) toast.leave(card.x);
						else card.x = 0;
					}
				}

				TapHandler {
					onTapped: {
						if (!toast.internal && toast.notification?.actions?.length > 0) {
							const byDefault = toast.notification.actions.find(action => action.identifier === "default");
							if (byDefault) byDefault.invoke();
						}
					}
				}

				ColumnLayout {
					id: content

					x: 14
					y: 14
					width: parent.width - 28
					spacing: 8

					RowLayout {
						Layout.fillWidth: true
						spacing: 12

						Item {
							Layout.alignment: Qt.AlignTop
							Layout.preferredWidth: 40
							Layout.preferredHeight: 40

							Ring {
								anchors.fill: parent
								value: toast.remaining
								thickness: 2.5
								color: toast.urgency
								trackColor: "transparent"
								animated: false
							}

							ClippingRectangle {
								anchors.centerIn: parent
								width: 32
								height: 32
								radius: 16
								color: Theme.layer2

								Image {
									anchors.fill: parent
									anchors.margins: (toast.notification?.image ?? "") !== "" ? 0 : 6
									visible: toast.iconSource !== ""
									source: toast.iconSource
									fillMode: (toast.notification?.image ?? "") !== "" ? Image.PreserveAspectCrop : Image.PreserveAspectFit
									sourceSize: Qt.size(64, 64)
									asynchronous: true
									smooth: true
									mipmap: true
								}

								Glyph {
									anchors.centerIn: parent
									visible: toast.internal
									icon: toast.modelData.icon || (toast.modelData.status === "error" ? "alert_circle" : (toast.modelData.status === "running" ? "palette" : "check_circle"))
									size: 18
									color: toast.urgency
								}
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 2

							RowLayout {
								Layout.fillWidth: true

								SectionLabel {
									Layout.fillWidth: true
									text: toast.internal ? "Shell" : (toast.notification?.appName || "System")
								}

								IconButton {
									Layout.preferredWidth: 22
									Layout.preferredHeight: 22
									icon: "close"
									iconSize: 13
									opacity: hover.hovered ? 1 : 0.35
									onClicked: toast.leave(1)
								}
							}

							StyledText {
								Layout.fillWidth: true
								text: toast.internal ? toast.modelData.title : (toast.notification?.summary || "Notification")
								font.weight: Font.DemiBold
								wrapMode: Text.WordWrap
								maximumLineCount: 2
							}

							StyledText {
								Layout.fillWidth: true
								visible: text !== ""
								text: toast.internal ? toast.modelData.detail : (toast.notification?.body ?? "")
								textFormat: Text.PlainText
								tone: Theme.textMuted
								font.pixelSize: Theme.size.label
								wrapMode: Text.WordWrap
								maximumLineCount: 4
							}
						}
					}

					ClippingRectangle {
						Layout.fillWidth: true
						visible: toast.internal && (toast.modelData.image ?? "") !== ""
						implicitHeight: visible ? Math.min(180, Math.max(60, width * (preview.implicitHeight / Math.max(1, preview.implicitWidth)))) : 0
						radius: Theme.radius.large
						color: Theme.layer1

						Image {
							id: preview

							anchors.fill: parent
							source: toast.internal ? String(toast.modelData.image || "") : ""
							fillMode: Image.PreserveAspectFit
							sourceSize.width: 720
							asynchronous: true
							cache: false
							smooth: true
							mipmap: true
						}
					}

					Rectangle {
						Layout.fillWidth: true
						readonly property real value: toast.notification?.hints?.value !== undefined ? Number(toast.notification.hints.value) : -1
						visible: value >= 0 && value <= 100
						implicitHeight: 6
						radius: 3
						color: Theme.layer2

						Rectangle {
							height: parent.height
							radius: 3
							width: parent.width * Math.max(0, Math.min(100, parent.value)) / 100
							color: toast.urgency

							Behavior on width {
								Anim {}
							}
						}
					}

					Flow {
						// the "default" action has no label; the whole card triggers it
						readonly property var actions: toast.internal
							? (toast.modelData.actions ?? [])
							: Array.from(toast.notification?.actions ?? []).filter(action => String(action.text || "").trim() !== "" && action.identifier !== "default")

						Layout.fillWidth: true
						visible: actions.length > 0
						spacing: 6

						Repeater {
							model: parent.actions

							delegate: Chip {
								required property var modelData
								text: toast.internal ? String(modelData.label || "") : modelData.text
								icon: toast.internal ? String(modelData.icon || "") : ""
								onClicked: {
									if (!toast.internal) {
										modelData.invoke();
										return;
									}
									if (typeof modelData.run === "function") modelData.run();
									toast.leave(1);
								}
							}
						}
					}

					// a message that can be answered (a chat on the phone, say) is answered right here
					RowLayout {
						Layout.fillWidth: true
						visible: !toast.internal && !!toast.notification?.hasInlineReply
						spacing: 6

						Field {
							id: toastReply

							Layout.fillWidth: true
							implicitHeight: 34
							icon: "reply"
							placeholder: toast.notification?.inlineReplyPlaceholder || "Reply"
							onAccepted: if (Notifs.sendReply(toast.notification, toastReply.text)) toast.leave(1)
						}

						IconButton {
							icon: "send"
							variant: "filled"
							implicitWidth: 34
							implicitHeight: 34
							onClicked: if (Notifs.sendReply(toast.notification, toastReply.text)) toast.leave(1)
						}
					}
				}
			}
		}
	}
}
