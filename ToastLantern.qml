pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Notifications
import "components"

// A toast: a small lantern that unfolds under the bell when the spark
// lands there. Its lifetime is the wire along its bottom draining from
// full to dark; the pointer over it holds the light. Actions are beads,
// the reply is a field on a wire.
Item {
	id: toast

	required property var notification
	property int duration: 5000
	property bool first: false
	property real stemX: 190
	property real reveal: 0
	property bool leaving: false
	readonly property bool hovered: hover.hovered
	readonly property color tone: notification?.urgency === NotificationUrgency.Critical ? Filament.alert
		: notification?.urgency === NotificationUrgency.Low ? Filament.inkMute : Filament.charge

	signal expired()
	signal dismissed()
	signal reply(string text)

	implicitHeight: 12 + Math.round(plane.height)

	Component.onCompleted: unfold.start()

	NumberAnimation { id: unfold; target: toast; property: "reveal"; from: 0; to: 1; duration: Filament.unfold; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeUnfold }
	NumberAnimation { id: fold; target: toast; property: "reveal"; to: 0; duration: Filament.fold; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeFold; onFinished: toast.expired() }

	function leave() {
		if (toast.leaving) return;
		toast.leaving = true;
		drain.stop();
		fold.start();
	}

	// The lifetime: the wire drains unless the hand is over the toast.
	property real life: 1
	NumberAnimation {
		id: drain
		target: toast; property: "life"; to: 0
		duration: toast.duration
		running: true
		paused: toast.hovered && running
		onFinished: toast.leave()
	}

	// The stem, only from the first toast (the rest hang from the one above).
	Wire {
		vertical: true
		x: toast.stemX - 1
		y: 0
		width: 2
		height: 12
		lit: 1
		animateLit: false
		glow: false
		visible: toast.first
		opacity: toast.reveal
	}

	Item {
		id: clipBox
		y: 12
		width: parent.width
		height: Math.round(plane.implicitHeight * Math.min(1.06, toast.reveal))
		clip: true
		opacity: Math.min(1, toast.reveal * 1.6)

		HoverHandler { id: hover }

		Rectangle {
			id: plane
			width: parent.width
			implicitHeight: body.implicitHeight + 24
			height: implicitHeight
			radius: Filament.radius
			color: Filament.plane
			border.width: 1
			border.color: toast.hovered ? toast.tone : Filament.wireDim
			Behavior on border.color { ColorAnimation { duration: Filament.quick } }

			Wire {
				visible: toast.first
				x: toast.stemX - 18; y: 0; width: 36; height: 2
				lit: 1; animateLit: false; cold: "transparent"; hot: toast.tone
			}

			Column {
				id: body
				x: 14; y: 12
				width: parent.width - 28
				spacing: 8

				Item {
					width: parent.width
					height: 16
					Rectangle { x: 0; anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: toast.tone }
					FText {
						x: 12
						anchors.verticalCenter: parent.verticalCenter
						text: toast.notification?.appName || "system"
						caps: true
						tone: "mute"
						font.pixelSize: Filament.textXs
					}
					FText {
						anchors.right: closeButton.left
						anchors.rightMargin: 8
						anchors.verticalCenter: parent.verticalCenter
						text: Qt.formatDateTime(new Date(), "HH:mm")
						mono: true
						tone: "faint"
						font.pixelSize: Filament.textXs
					}
					FButton {
						id: closeButton
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						icon: "window-close-symbolic"
						kind: "ghost"
						square: true
						compact: true
						iconSize: 12
						onClicked: { toast.dismissed(); toast.leave(); }
					}
				}

				Item {
					width: parent.width
					height: Math.max(textColumn.implicitHeight, art.visible ? 44 : 0)

					Column {
						id: textColumn
						anchors.left: parent.left
						anchors.right: art.visible ? art.left : parent.right
						anchors.rightMargin: art.visible ? 12 : 0
						spacing: 3
						FText {
							width: parent.width
							text: toast.notification?.summary || ""
							font.pixelSize: Filament.textMd
							font.weight: Font.DemiBold
							wrapMode: Text.Wrap
							maximumLineCount: 2
						}
						FText {
							width: parent.width
							text: toast.notification?.body || ""
							visible: text !== ""
							tone: "soft"
							font.pixelSize: Filament.textSm
							wrapMode: Text.Wrap
							maximumLineCount: 4
							textFormat: Text.PlainText
						}
					}

					Item {
						id: art
						anchors.right: parent.right
						width: 44; height: 44
						visible: (toast.notification?.image || "") !== "" || (toast.notification?.appIcon || "") !== ""
						Rectangle { anchors.fill: parent; radius: 8; color: Filament.well }
						Image {
							anchors.fill: parent
							anchors.margins: (toast.notification?.image || "") !== "" ? 0 : 10
							source: (toast.notification?.image || "") !== "" ? toast.notification.image : FIconTable.resolve(toast.notification?.appIcon || "", [])
							fillMode: (toast.notification?.image || "") !== "" ? Image.PreserveAspectCrop : Image.PreserveAspectFit
							asynchronous: true
							layer.enabled: true
						}
					}
				}

				Wire {
					visible: toast.notification?.hints?.value !== undefined && Number(toast.notification.hints.value) >= 0
					width: parent.width; height: 3; thickness: 3
					cold: Filament.wireDim; hot: toast.tone
					lit: Math.max(0, Math.min(1, Number(toast.notification?.hints?.value ?? 0) / 100))
				}

				Flow {
					width: parent.width
					spacing: 6
					visible: (toast.notification?.actions?.length ?? 0) > 0
					Repeater {
						model: toast.notification?.actions ?? []
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
					visible: toast.notification?.hasInlineReply ?? false
					FField {
						id: replyField
						anchors.left: parent.left
						anchors.right: sendButton.left
						anchors.rightMargin: 8
						placeholder: toast.notification?.inlineReplyPlaceholder || "Reply"
						fontSize: Filament.textSm
						onAccepted: { toast.reply(text); text = ""; }
					}
					FButton {
						id: sendButton
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						icon: "mail-send-symbolic"
						kind: "charge"
						square: true
						compact: true
						onClicked: { toast.reply(replyField.text); replyField.text = ""; }
					}
				}
			}

			// The lifetime, draining along the bottom edge.
			Wire {
				x: 14; y: parent.height - 3
				width: parent.width - 28; height: 2
				cold: "transparent"; hot: toast.tone
				lit: toast.life
				animateLit: false
				glow: false
			}
		}
	}
}
