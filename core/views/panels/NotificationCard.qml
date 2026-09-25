pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One notification group. Drag it sideways to throw it away; it follows the
// pointer, tilts slightly and fades, and snaps back if you let go early.
Item {
	id: root

	required property var group
	readonly property var entry: root.group.latestSnapshot
	readonly property var live: root.group.latestNotification
	readonly property color urgency: Notifs.urgencyColor(root.entry?.urgency ?? -1)
	readonly property string iconSource: Notifs.iconFor(root.entry?.image ?? "", root.entry?.appIcon ?? "")
	readonly property int olderCount: Math.max(0, (root.group.notifications?.length ?? 1) - 1)
	property bool leaving: false
	property string replyText: ""

	implicitHeight: card.implicitHeight
	height: root.leaving ? 0 : implicitHeight
	clip: root.leaving

	Behavior on height {
		enabled: root.leaving
		SpatialAnim {
			duration: Motion.medium
		}
	}

	function dismiss(direction) {
		if (root.leaving) return;
		throwAnim.to = (direction >= 0 ? 1 : -1) * (root.width + 40);
		throwAnim.start();
	}

	NumberAnimation {
		id: throwAnim

		target: card
		property: "x"
		duration: Motion.medium
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.accel
		onFinished: {
			root.leaving = true;
			removeTimer.start();
		}
	}

	Timer {
		id: removeTimer
		interval: Motion.medium
		onTriggered: Notifs.dismissGroup(root.group.key)
	}

	Rectangle {
		id: card

		width: root.width
		implicitHeight: column.implicitHeight + 24
		radius: Theme.radius.large
		color: hover.hovered ? Theme.layer2 : Theme.layer1
		opacity: 1 - Math.min(0.8, Math.abs(x) / (root.width * 0.9))
		rotation: x / 60

		Behavior on color {
			ColorAnim {}
		}
		Behavior on x {
			enabled: !drag.active && !throwAnim.running
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
			xAxis.enabled: true
			yAxis.enabled: false
			onActiveChanged: {
				if (active) return;
				if (Math.abs(card.x) > root.width * 0.32) root.dismiss(card.x);
				else card.x = 0;
			}
		}

		Rectangle {
			x: 0
			y: 14
			width: 3
			height: 22
			radius: 1.5
			color: root.urgency
		}

		ColumnLayout {
			id: column

			x: 12
			y: 12
			width: parent.width - 24
			spacing: 8

			RowLayout {
				Layout.fillWidth: true
				spacing: 12

				ClippingRectangle {
					Layout.alignment: Qt.AlignTop
					Layout.preferredWidth: 38
					Layout.preferredHeight: 38
					radius: 11
					color: Theme.layer3
					visible: root.iconSource !== ""

					Image {
						anchors.fill: parent
						anchors.margins: (root.entry?.image ?? "") !== "" ? 0 : 7
						source: root.iconSource
						fillMode: (root.entry?.image ?? "") !== "" ? Image.PreserveAspectCrop : Image.PreserveAspectFit
						sourceSize: Qt.size(76, 76)
						smooth: true
						mipmap: true
						asynchronous: true
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 2

					RowLayout {
						Layout.fillWidth: true
						spacing: 6

						SectionLabel {
							Layout.fillWidth: true
							text: root.group.appName || "System"
						}

						StyledText {
							text: `${Notifs.formatTime(root.entry?.timestamp)}${root.entry?.active === false ? " · closed" : ""}`
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.tiny
						}

						IconButton {
							Layout.preferredWidth: 22
							Layout.preferredHeight: 22
							icon: "close"
							iconSize: 13
							opacity: hover.hovered ? 1 : 0
							onClicked: root.dismiss(1)

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
						}
					}

					StyledText {
						Layout.fillWidth: true
						text: root.entry?.summary ?? root.group.appName
						font.weight: Font.DemiBold
						wrapMode: Text.WordWrap
						maximumLineCount: 2
					}

					StyledText {
						Layout.fillWidth: true
						visible: text !== ""
						text: root.entry?.body ?? ""
						textFormat: Text.PlainText
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
						wrapMode: Text.WordWrap
						maximumLineCount: 4
					}
				}
			}

			Rectangle {
				Layout.fillWidth: true
				visible: (root.entry?.progressValue ?? -1) >= 0 && (root.entry?.progressValue ?? -1) <= 100
				implicitHeight: 6
				radius: 3
				color: Theme.layer3

				Rectangle {
					height: parent.height
					radius: 3
					width: parent.width * Math.max(0, Math.min(100, root.entry?.progressValue ?? 0)) / 100
					color: root.urgency
				}
			}

			Flow {
				Layout.fillWidth: true
				visible: !!root.live && root.live.actions.length > 0
				spacing: 6

				Repeater {
					model: root.live ? root.live.actions : []

					delegate: Chip {
						required property var modelData
						text: modelData.text
						onClicked: modelData.invoke()
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				visible: !!root.live && root.live.hasInlineReply
				spacing: 6

				Field {
					id: reply

					Layout.fillWidth: true
					implicitHeight: 36
					icon: "reply"
					placeholder: root.live ? (root.live.inlineReplyPlaceholder || "Reply") : "Reply"
					onAccepted: if (Notifs.sendReply(root.live, reply.text)) reply.text = ""
				}

				IconButton {
					icon: "send"
					variant: "filled"
					enabled: reply.text.trim() !== ""
					onClicked: if (Notifs.sendReply(root.live, reply.text)) reply.text = ""
				}
			}

			Clickable {
				Layout.fillWidth: true
				visible: root.olderCount > 0
				implicitHeight: 28
				radius: 14
				color: Theme.layer2
				pressedScale: 0.98
				onClicked: Notifs.setExpanded(root.group.key, !root.group.expanded)

				RowLayout {
					anchors.centerIn: parent
					spacing: 4

					StyledText {
						text: root.group.expanded ? "Show less" : `${root.olderCount} earlier`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}

					Glyph {
						icon: "chevron_down"
						size: 15
						color: Theme.textMuted
						rotation: root.group.expanded ? 180 : 0

						Behavior on rotation {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}
				}
			}

			Item {
				Layout.fillWidth: true
				visible: root.olderCount > 0
				implicitHeight: root.group.expanded ? older.implicitHeight : 0
				clip: true

				Behavior on implicitHeight {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				ColumnLayout {
					id: older

					width: parent.width
					spacing: 6

					Repeater {
						model: root.group.notifications.slice(1)

						delegate: Rectangle {
							id: old

							required property var modelData

							Layout.fillWidth: true
							implicitHeight: oldColumn.implicitHeight + 16
							radius: Theme.radius.medium
							color: Theme.layer2

							ColumnLayout {
								id: oldColumn

								x: 10
								y: 8
								width: parent.width - 20
								spacing: 2

								RowLayout {
									Layout.fillWidth: true
									StyledText {
										Layout.fillWidth: true
										text: old.modelData.summary || "Notification"
										font.pixelSize: Theme.size.label
										font.weight: Font.DemiBold
									}
									StyledText {
										text: Notifs.formatTime(old.modelData.timestamp)
										tone: Theme.textSubtle
										font.pixelSize: Theme.size.tiny
									}
								}

								StyledText {
									Layout.fillWidth: true
									visible: text !== ""
									text: old.modelData.body
									textFormat: Text.PlainText
									tone: Theme.textMuted
									font.pixelSize: Theme.size.small
									wrapMode: Text.WordWrap
									maximumLineCount: 3
								}
							}
						}
					}
				}
			}
		}
	}
}
