pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Notifications
import "components"

// Everything that has arrived, hung from one thread: one knot per app, its
// latest notification beside it, the older ones folded under it. The bell
// can be put out (do not disturb) with the toggle at the top; the whole
// thread can be cut with the hold button.
Item {
	id: centre

	property real reveal: 1
	property var groups: []
	property bool doNotDisturb: false

	signal dismissGroup(string key)
	signal dismissAll()
	signal setExpanded(string key, bool expanded)
	signal reply(var notification, string text)
	signal toggleDoNotDisturb()

	function tone(urgency) {
		if (urgency === NotificationUrgency.Critical) return Filament.alert;
		if (urgency === NotificationUrgency.Low) return Filament.inkMute;
		return Filament.charge;
	}

	Band {
		id: head
		reveal: centre.reveal; order: 0
		width: parent.width; height: 32

		FText {
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			text: centre.groups.length === 0 ? "Nothing waiting" : `${centre.groups.length} ${centre.groups.length === 1 ? "thread" : "threads"}`
			font.pixelSize: Filament.textLg
			font.weight: Font.DemiBold
		}

		FToggle {
			anchors.right: clearButton.left
			anchors.rightMargin: 14
			anchors.verticalCenter: parent.verticalCenter
			text: "quiet"
			checked: centre.doNotDisturb
			onToggled: centre.toggleDoNotDisturb()
		}

		HoldButton {
			id: clearButton
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			text: "clear"
			icon: "user-trash-symbolic"
			holdTime: 500
			implicitHeight: 28
			visible: centre.groups.length > 0
			onHeld: centre.dismissAll()
		}
	}

	// Empty: the thread hangs with nothing on it, and the spark rests at its end.
	Item {
		anchors.fill: parent
		anchors.topMargin: 40
		visible: centre.groups.length === 0
		opacity: Filament.band(centre.reveal, 1)
		Wire {
			vertical: true
			x: 8; y: 0; width: 2; height: parent.height * 0.5
			cold: Filament.wireDim
			lit: 0.15; litFrom: 0.85; hot: Filament.charge; animateLit: false
		}
		Spark { x: 5; y: parent.height * 0.5 - 4; size: 7; breathing: true }
		FText {
			x: 24; y: parent.height * 0.5 - 8
			text: centre.doNotDisturb ? "the bell is quiet; only critical ones light it" : "sparks will arrive here"
			tone: "mute"
			font.pixelSize: Filament.textSm
		}
	}

	ThreadLine {
		x: 8
		y: head.height + 8
		height: list.height
		litY: list.currentItem ? list.currentItem.y - list.contentY + 20 : -1
		litLength: 40
		visible: centre.groups.length > 0
		opacity: Filament.band(centre.reveal, 1)
	}

	ListView {
		id: list
		x: 8
		y: head.height + 8
		width: parent.width - 8
		height: parent.height - y
		clip: true
		spacing: 10
		model: centre.groups
		currentIndex: -1
		boundsBehavior: Flickable.StopAtBounds
		visible: centre.groups.length > 0

		delegate: Item {
			id: group
			required property var modelData
			required property int index
			readonly property var latest: modelData.latestSnapshot
			readonly property var live: modelData.latestNotification
			readonly property color tone: centre.tone(modelData.urgency)
			readonly property bool hot: groupHover.hovered
			width: list.width
			height: card.implicitHeight
			opacity: Filament.band(centre.reveal, 1 + Math.min(index, 6))

			HoverHandler { id: groupHover; onHoveredChanged: if (hovered) list.currentIndex = group.index }

			// The knot on the thread.
			Rectangle {
				x: -4; y: 16
				width: 8; height: 8; radius: 4
				color: group.tone
				scale: group.hot ? 1.4 : 1
				Behavior on scale { SpringAnimation { spring: 4; damping: 0.3 } }
			}

			Wire {
				x: 4; y: 19; width: 12; height: 2
				cold: Filament.wireDim; lit: group.hot ? 1 : 0; hot: group.tone
			}

			Column {
				id: card
				x: 18
				width: parent.width - 18
				spacing: 6

				Item {
					width: parent.width
					height: 18
					FText {
						anchors.left: parent.left
						anchors.verticalCenter: parent.verticalCenter
						text: group.modelData.appName || "system"
						caps: true
						tone: "mute"
						font.pixelSize: Filament.textXs
					}
					FText {
						anchors.right: dismissButton.left
						anchors.rightMargin: 6
						anchors.verticalCenter: parent.verticalCenter
						text: Qt.formatDateTime(new Date(group.latest.timestamp), "HH:mm") + (group.latest.active ? "" : "  ·  closed")
						mono: true
						tone: "faint"
						font.pixelSize: Filament.textXs
					}
					FButton {
						id: dismissButton
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						icon: "window-close-symbolic"
						kind: "ghost"
						square: true
						compact: true
						iconSize: 11
						opacity: group.hot ? 1 : 0.35
						onClicked: centre.dismissGroup(group.modelData.key)
					}
				}

				Item {
					width: parent.width
					height: Math.max(words.implicitHeight, art.visible ? 40 : 0)
					Column {
						id: words
						anchors.left: parent.left
						anchors.right: art.visible ? art.left : parent.right
						anchors.rightMargin: art.visible ? 10 : 0
						spacing: 2
						FText { width: parent.width; text: group.latest.summary; font.weight: Font.DemiBold; wrapMode: Text.Wrap; maximumLineCount: 2 }
						FText { width: parent.width; text: group.latest.body; visible: text !== ""; tone: "soft"; font.pixelSize: Filament.textSm; wrapMode: Text.Wrap; maximumLineCount: 5; textFormat: Text.PlainText }
					}
					Item {
						id: art
						anchors.right: parent.right
						width: 40; height: 40
						visible: (group.latest.image || "") !== "" || (group.latest.appIcon || "") !== ""
						Rectangle { anchors.fill: parent; radius: 8; color: Filament.well }
						Image {
							anchors.fill: parent
							anchors.margins: (group.latest.image || "") !== "" ? 0 : 9
							source: (group.latest.image || "") !== "" ? group.latest.image : FIconTable.resolve(group.latest.appIcon, [])
							fillMode: (group.latest.image || "") !== "" ? Image.PreserveAspectCrop : Image.PreserveAspectFit
							asynchronous: true
						}
					}
				}

				Wire {
					visible: group.latest.progressValue >= 0
					width: parent.width; height: 3; thickness: 3
					cold: Filament.wireDim; hot: group.tone
					lit: Math.max(0, Math.min(1, group.latest.progressValue / 100))
				}

				Flow {
					width: parent.width
					spacing: 6
					visible: group.live !== null && (group.live?.actions?.length ?? 0) > 0
					Repeater {
						model: group.live?.actions ?? []
						FButton {
							required property var modelData
							text: modelData.text
							compact: true
							onClicked: modelData.invoke()
						}
					}
				}

				Item {
					width: parent.width
					height: 30
					visible: group.live !== null && (group.latest.hasInlineReply ?? false)
					FField {
						id: replyField
						anchors.left: parent.left
						anchors.right: sendButton.left
						anchors.rightMargin: 8
						placeholder: group.latest.inlineReplyPlaceholder
						fontSize: Filament.textSm
						onAccepted: { centre.reply(group.live, text); text = ""; }
					}
					FButton {
						id: sendButton
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						icon: "mail-send-symbolic"
						kind: "charge"
						square: true
						compact: true
						onClicked: { centre.reply(group.live, replyField.text); replyField.text = ""; }
					}
				}

				// The older ones fold out under the latest.
				FButton {
					visible: group.modelData.notifications.length > 1
					text: group.modelData.expanded
						? `fold ${group.modelData.notifications.length - 1} older`
						: `${group.modelData.notifications.length - 1} older`
					kind: "ghost"
					compact: true
					onClicked: centre.setExpanded(group.modelData.key, !group.modelData.expanded)
				}

				Column {
					width: parent.width
					spacing: 6
					visible: group.modelData.expanded
					Repeater {
						model: group.modelData.expanded ? group.modelData.notifications.slice(1) : []
						Item {
							id: older
							required property var modelData
							required property int index
							width: parent.width
							height: olderText.implicitHeight + 4
							Wire { vertical: true; x: 2; y: 0; width: 2; height: parent.height; cold: Filament.wireDim }
							Column {
								id: olderText
								x: 12; width: parent.width - 12
								spacing: 1
								FText { width: parent.width; text: older.modelData.summary; font.pixelSize: Filament.textSm; wrapMode: Text.Wrap; maximumLineCount: 2 }
								FText { width: parent.width; text: older.modelData.body; visible: text !== ""; tone: "mute"; font.pixelSize: Filament.textXs; wrapMode: Text.Wrap; maximumLineCount: 3 }
								FText { text: Qt.formatDateTime(new Date(older.modelData.timestamp), "HH:mm") + (older.modelData.active ? "" : "  ·  closed"); mono: true; tone: "faint"; font.pixelSize: Filament.textXs }
							}
						}
					}
				}
			}
		}
	}
}
