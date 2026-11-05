pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One toast in one of the looks of Notifs.toastStyles. `entry` is a toast of
// Notifs.toasts (or a made-up one for a preview), `remaining` the share of
// its time left (-1: no timer shown), `count` how many sit in its stack.
Rectangle {
	id: root

	property var entry: null
	property string look: Notifs.toastStyle
	property real remaining: -1
	property int count: 1
	property bool expanded: false
	// a preview: nothing reacts, the reply field stays away
	property bool still: false
	property bool hovered: false
	// the whole text, the whole picture
	property bool open: false

	signal closeClicked
	signal countClicked
	signal answered(string text)

	readonly property var notification: root.entry?.notification ?? null
	readonly property bool internal: !!root.entry?.internal
	readonly property color urgency: root.internal
		? (root.entry?.status === "error" ? Theme.danger : Theme.primary)
		: Notifs.urgencyColor(root.notification?.urgency ?? -1)
	readonly property string avatar: root.internal ? String(root.entry?.avatar ?? "") : ""
	readonly property string iconSource: root.internal
		? (root.avatar === "" || root.avatar.includes("://") ? root.avatar : `file://${root.avatar}`)
		: Notifs.iconFor(root.notification?.image ?? "", root.notification?.appIcon ?? "")
	readonly property bool whole: root.avatar !== "" || (root.notification?.image ?? "") !== ""
	readonly property string glyph: root.entry?.icon || (root.entry?.status === "error" ? "alert_circle" : (root.entry?.status === "running" ? "palette" : "check_circle"))
	readonly property string app: root.internal ? (root.entry?.app || "Shell") : (root.notification?.appName || "System")
	readonly property string title: root.internal ? String(root.entry?.title ?? "") : (root.notification?.summary || "Notification")
	readonly property string body: root.internal ? String(root.entry?.detail ?? "") : (root.notification?.body ?? "")
	readonly property string preview: root.internal ? String(root.entry?.image || "") : ""
	readonly property real progress: root.notification?.hints?.value !== undefined ? Number(root.notification.hints.value) : -1
	readonly property var reply: root.internal ? (root.entry?.reply ?? null) : null
	readonly property bool answerable: !root.still && (root.reply !== null || (!root.internal && !!root.notification?.hasInlineReply))
	// the "default" action has no label; the whole card triggers it
	readonly property var actions: root.internal
		? (root.entry?.actions ?? [])
		: Array.from(root.notification?.actions ?? []).filter(action => String(action.text || "").trim() !== "" && action.identifier !== "default")
	readonly property bool typing: replyField.focused || replyField.text !== ""
	readonly property bool cut: (root.compact ? compactTitle.truncated : titleText.truncated) || bodyText.truncated
		|| (previewFrame.visible && previewFrame.width * previewImage.implicitHeight / Math.max(1, previewImage.implicitWidth) > previewFrame.height + 1)

	readonly property bool compact: root.look === "compact"
	readonly property bool accent: root.look === "accent"
	readonly property bool floating: root.look === "floating"
	readonly property int pad: root.compact ? 10 : 14
	readonly property int face: root.compact ? 26 : (root.floating ? 44 : (root.accent ? 36 : 32))

	// another toast in the same card: closed again, no draft carried over
	property int shownId: 0
	onEntryChanged: {
		const id = Number(root.entry?.toastId ?? 0);
		if (id === root.shownId) return;
		root.shownId = id;
		root.open = false;
		replyField.text = "";
	}

	function answer() {
		const text = replyField.text.trim();
		if (text === "") return;
		if (root.reply !== null) root.reply.send(text);
		else if (!Notifs.sendReply(root.notification, text)) return;
		replyField.text = "";
		root.answered(text);
	}

	implicitHeight: content.implicitHeight + root.pad * 2
	radius: root.compact ? Theme.radius.large : (root.accent ? Theme.radius.large : Theme.radius.huge)
	color: root.floating ? Theme.glass : (root.accent ? Theme.layer1 : Theme.base)
	border.width: root.accent ? 0 : 1
	border.color: root.floating ? Theme.outline : Qt.alpha(root.urgency, root.compact ? 0.18 : 0.25)
	clip: root.accent

	// accent: a stripe in the urgency's colour down the left edge
	Rectangle {
		visible: root.accent
		width: 4
		height: parent.height
		color: root.urgency
	}

	// accent and floating: the time left as a line along the bottom
	Rectangle {
		visible: (root.accent || root.floating) && root.remaining >= 0
		x: root.floating ? root.radius : 0
		anchors.bottom: parent.bottom
		anchors.bottomMargin: root.floating ? 1 : 0
		width: (parent.width - (root.floating ? root.radius * 2 : 0)) * Math.max(0, root.remaining)
		height: root.floating ? 2 : 3
		radius: 1
		color: Qt.alpha(root.urgency, root.floating ? 0.8 : 1)
	}

	ColumnLayout {
		id: content

		x: root.pad + (root.accent ? 6 : 0)
		y: root.pad
		width: parent.width - root.pad * 2 - (root.accent ? 6 : 0)
		spacing: root.compact ? 6 : 8

		RowLayout {
			Layout.fillWidth: true
			spacing: root.compact ? 10 : 12

			Item {
				Layout.alignment: root.compact ? Qt.AlignVCenter : Qt.AlignTop
				Layout.preferredWidth: root.face + ((root.look === "card" || root.compact) ? 8 : 0)
				Layout.preferredHeight: Layout.preferredWidth

				// card and compact: the time left as a ring around the face
				Ring {
					anchors.fill: parent
					visible: (root.look === "card" || root.compact) && root.remaining >= 0
					value: root.remaining
					thickness: root.compact ? 2 : 2.5
					color: root.urgency
					trackColor: "transparent"
					animated: false
				}

				ClippingRectangle {
					anchors.centerIn: parent
					width: root.face
					height: root.face
					radius: root.floating ? 14 : (root.accent ? 10 : root.face / 2)
					color: root.accent ? Qt.alpha(root.urgency, 0.14) : Theme.layer2

					Image {
						id: faceImage

						anchors.fill: parent
						anchors.margins: root.whole ? 0 : Math.round(root.face * 0.19)
						visible: root.iconSource !== "" && faceImage.status !== Image.Error
						source: root.iconSource
						fillMode: root.whole ? Image.PreserveAspectCrop : Image.PreserveAspectFit
						sourceSize: Qt.size(96, 96)
						asynchronous: true
						smooth: true
						mipmap: true
					}

					Glyph {
						anchors.centerIn: parent
						visible: !faceImage.visible
						icon: root.internal ? root.glyph : "bell_outline"
						size: Math.round(root.face * 0.55)
						color: root.urgency
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				Layout.alignment: Qt.AlignVCenter
				spacing: root.compact ? 0 : 2

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					SectionLabel {
						visible: !root.compact
						Layout.fillWidth: true
						text: root.app
					}

					StyledText {
						id: compactTitle

						visible: root.compact
						Layout.fillWidth: true
						text: root.title
						font.weight: Font.DemiBold
						wrapMode: root.open ? Text.WordWrap : Text.NoWrap
						maximumLineCount: root.open ? 6 : 1
						elide: Text.ElideRight
					}

					Rectangle {
						visible: root.count > 1
						implicitWidth: countLabel.implicitWidth + 12
						implicitHeight: 18
						radius: 9
						color: root.expanded ? root.urgency : Qt.alpha(root.urgency, 0.18)

						StyledText {
							id: countLabel

							anchors.centerIn: parent
							text: root.expanded ? "−" : `+${root.count - 1}`
							tone: root.expanded ? Theme.onPrimary : root.urgency
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}

						// takes the click, so the card's own tap stays out of it
						MouseArea {
							anchors.fill: parent
							anchors.margins: -4
							enabled: !root.still
							cursorShape: Qt.PointingHandCursor
							onClicked: root.countClicked()
						}
					}

					IconButton {
						Layout.preferredWidth: 22
						Layout.preferredHeight: 22
						visible: !root.still && (root.cut || root.open)
						icon: root.open ? "chevron_up" : "chevron_down"
						iconSize: 14
						opacity: root.hovered || root.open ? 1 : 0.35
						onClicked: root.open = !root.open
					}

					IconButton {
						Layout.preferredWidth: 22
						Layout.preferredHeight: 22
						icon: "close"
						iconSize: 13
						opacity: root.hovered ? 1 : 0.35
						enabled: !root.still
						onClicked: root.closeClicked()
					}
				}

				StyledText {
					id: titleText

					visible: !root.compact
					Layout.fillWidth: true
					text: root.title
					font.weight: Font.DemiBold
					font.pixelSize: root.floating ? Theme.size.title : Theme.size.body
					wrapMode: Text.WordWrap
					maximumLineCount: root.open ? 8 : 2
					elide: Text.ElideRight
				}

				StyledText {
					id: bodyText

					Layout.fillWidth: true
					visible: text !== ""
					text: root.body
					textFormat: Text.PlainText
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
					wrapMode: root.compact && !root.open ? Text.NoWrap : Text.WordWrap
					maximumLineCount: root.open ? 40 : (root.compact ? 1 : 4)
					elide: Text.ElideRight
				}
			}
		}

		ClippingRectangle {
			id: previewFrame

			Layout.fillWidth: true
			visible: root.preview !== ""
			implicitHeight: visible ? Math.min(root.open ? 480 : (root.compact ? 120 : 180), Math.max(60, width * (previewImage.implicitHeight / Math.max(1, previewImage.implicitWidth)))) : 0
			radius: Theme.radius.large
			color: Theme.layer1

			Image {
				id: previewImage

				anchors.fill: parent
				source: root.preview
				fillMode: Image.PreserveAspectFit
				sourceSize.width: 720
				asynchronous: true
				cache: false
				smooth: true
				mipmap: true
			}

			// a click opens the picture in the picture viewer, grown from here
			MouseArea {
				anchors.fill: parent
				enabled: Viewer.enabled && /^(file:\/\/)?\//.test(root.preview)
				cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
				onClicked: {
					const win = previewFrame.QsWindow.window;
					const p = previewImage.mapToItem(null, 0, 0);
					const scr = win?.screen;
					const box = previewImage.paintedWidth > 0 ? Qt.rect((previewImage.width - previewImage.paintedWidth) / 2, (previewImage.height - previewImage.paintedHeight) / 2, previewImage.paintedWidth, previewImage.paintedHeight) : Qt.rect(0, 0, previewImage.width, previewImage.height);
					const from = win && scr ? { screen: scr.name, x: scr.width - (win.margins?.right ?? 0) - win.width + p.x + box.x, y: (win.margins?.top ?? 0) + p.y + box.y, w: box.width, h: box.height } : null;
					Viewer.open(root.preview, { from: from });
				}
			}
		}

		Rectangle {
			Layout.fillWidth: true
			visible: root.progress >= 0 && root.progress <= 100
			implicitHeight: root.compact ? 4 : 6
			radius: height / 2
			color: Theme.layer2

			Rectangle {
				height: parent.height
				radius: parent.radius
				width: parent.width * Math.max(0, Math.min(100, root.progress)) / 100
				color: root.urgency

				Behavior on width {
					Anim {}
				}
			}
		}

		Flow {
			Layout.fillWidth: true
			visible: root.actions.length > 0
			spacing: 6

			Repeater {
				model: root.actions

				delegate: Chip {
					required property var modelData
					text: root.internal ? String(modelData.label || "") : modelData.text
					icon: root.internal ? String(modelData.icon || "") : ""
					enabled: !root.still
					onClicked: {
						if (!root.internal) {
							modelData.invoke();
							return;
						}
						if (typeof modelData.run === "function") modelData.run();
						root.closeClicked();
					}
				}
			}
		}

		// a message that can be answered (a chat, a mail, a chat on the phone) is answered right here
		RowLayout {
			Layout.fillWidth: true
			visible: root.answerable
			spacing: 6

			Field {
				id: replyField

				Layout.fillWidth: true
				implicitHeight: 36
				icon: "reply"
				autocorrect: true
				placeholder: root.reply?.placeholder || root.notification?.inlineReplyPlaceholder || "Reply"
				onAccepted: root.answer()
				onEscapePressed: {
					if (replyField.text === "") root.closeClicked();
					else replyField.text = "";
				}
			}

			IconButton {
				icon: "send"
				variant: "filled"
				implicitWidth: 36
				implicitHeight: 36
				enabled: replyField.text.trim() !== ""
				onClicked: root.answer()
			}
		}
	}
}
