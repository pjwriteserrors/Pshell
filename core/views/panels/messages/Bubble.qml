pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One mail as a chat bubble: what was written, with the mail it answers
// quoted on top (a click jumps there), its attachments below, and the
// signature and older quotes folded behind the dots.
Item {
	id: root

	required property var message
	property var previous: null
	// more than one other person: names and faces are shown
	property bool group: false
	// set for a moment when a quote jumped here
	property bool flash: false
	// the mail the answer being written refers to
	property bool picked: false

	readonly property bool mine: root.message.mine
	readonly property date when: new Date(root.message.date * 1000)
	readonly property bool newDay: !root.previous || new Date(root.previous.date * 1000).toDateString() !== root.when.toDateString()
	// the first of a run of mails from one person
	readonly property bool head: root.newDay || !root.previous || root.previous.auto || root.previous.from.email !== root.message.from.email || root.message.date - root.previous.date > 900
	// a drawn layout (a newsletter) carries its signature itself; a note's folds away
	readonly property bool whole: root.page !== null && root.message.designed
	readonly property bool folded: (root.message.signature !== "" && !root.whole) || root.message.quote !== ""
	property bool expanded: false
	// what was picked for this mail: its layout (true) or chat text (false); null takes what fits
	property var choice: null
	// a layout that would have to shrink is too small to read: where the chat is narrow, mails are chat text
	readonly property bool fits: !root.message.page || root.message.page.width * 0.95 <= root.width - (root.group ? 36 : 0) - 24
	// shown as the sender laid it out (a picture) instead of as chat text
	readonly property bool drawn: root.choice ?? root.fits
	readonly property var page: root.drawn ? (root.message.page ?? null) : null
	// a bubble that is on the screen asks for its picture, and for its signature's once that is unfolded
	readonly property bool lacking: root.message.loaded && ((root.drawn && root.message.drawable && !root.message.page)
		|| (root.expanded && root.message.signatureRich && !root.message.signaturePage))

	onLackingChanged: if (root.lacking) Mail.draw(root.message.id)
	Component.onCompleted: if (root.lacking) Mail.draw(root.message.id)
	readonly property real maxWidth: Math.min(620, root.width * 0.74)
	// a drawn mail is shown pixel for pixel: it gets the width it was drawn at where the chat has it
	readonly property real sheetWidth: Math.max(root.page?.width ?? 0, root.expanded && !root.whole ? (root.message.signaturePage?.width ?? 0) : 0)
	readonly property real room: root.sheetWidth > 0 ? Math.max(root.maxWidth, Math.min(root.sheetWidth + 24, root.width - (root.group ? 36 : 0))) : root.maxWidth
	readonly property color surface: root.mine ? Theme.primaryContainer : Theme.layer2

	signal reply
	signal forward
	signal jump(string id)

	function day() {
		const now = new Date();
		const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
		if (root.when.toDateString() === now.toDateString()) return "Today";
		if (root.when.toDateString() === yesterday.toDateString()) return "Yesterday";
		return Qt.formatDate(root.when, root.when.getFullYear() === now.getFullYear() ? "dddd, d MMMM" : "d MMMM yyyy");
	}

	function size(bytes) {
		if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
		if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
		return bytes > 0 ? `${bytes} B` : "";
	}

	function fileIcon(type, name) {
		if (String(type).startsWith("image/")) return "file_image";
		if (String(type).includes("pdf") || String(name).toLowerCase().endsWith(".pdf")) return "file_pdf_box";
		if (String(type).includes("calendar")) return "calendar";
		return "file_outline";
	}

	// links wear the accent, and a picture is a link to itself: a click shows it large
	function tinted(html) {
		return String(html).replace(/<a href=/g, `<a style="color:${Theme.primary}" href=`)
			.replace(/<img src="file:\/\/([^"]+)"[^>]*>/g, (image, path) => `<a href="pshell-picture:${path}">${image}</a>`);
	}

	function follow(link) {
		if (link.startsWith("pshell-picture:")) Mail.view(link.slice(15));
		else Qt.openUrlExternally(link);
	}

	implicitHeight: column.implicitHeight
	// the strip of the bubble under the pointer may reach over the mail above it
	z: hover.hovered || toolsHover.hovered ? 2 : 0

	Avatar {
		id: face

		visible: false
		name: root.message.from.name
		email: root.message.from.email
	}

	// how wide the text would run unwrapped
	Text {
		id: probe

		visible: false
		text: root.message.text || "…"
		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.body
		font.weight: Font.DemiBold
	}

	Column {
		id: column

		width: parent.width
		spacing: 3

		Item {
			visible: root.newDay
			width: parent.width
			height: 36

			Rectangle {
				anchors.centerIn: parent
				width: dayLabel.implicitWidth + 20
				height: 22
				radius: 11
				color: Theme.layer1

				StyledText {
					id: dayLabel

					anchors.centerIn: parent
					text: root.day()
					tone: Theme.textMuted
					font.pixelSize: Theme.size.tiny
					font.weight: Font.DemiBold
				}
			}
		}

		// an automatic reply is a notice, not a message
		Rectangle {
			visible: root.message.auto
			anchors.horizontalCenter: parent.horizontalCenter
			width: Math.min(root.maxWidth, notice.implicitWidth + 28)
			height: notice.implicitHeight + 16
			radius: Theme.radius.medium
			color: Theme.layer1

			ColumnLayout {
				id: notice

				anchors.centerIn: parent
				width: Math.min(implicitWidth, root.maxWidth - 28)
				spacing: 2

				RowLayout {
					Layout.alignment: Qt.AlignHCenter
					spacing: 6

					Glyph {
						icon: "beach"
						size: 13
						color: Theme.textMuted
					}

					StyledText {
						text: `${root.message.from.name} · automatic reply`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}
				}

				StyledText {
					Layout.fillWidth: true
					Layout.maximumWidth: root.maxWidth - 28
					text: root.message.text
					tone: Theme.textSubtle
					wrapMode: Text.Wrap
					horizontalAlignment: Text.AlignHCenter
					maximumLineCount: 4
					elide: Text.ElideRight
					font.pixelSize: Theme.size.small
				}
			}
		}

		Item {
			id: row

			visible: !root.message.auto
			width: parent.width
			height: stack.height + (root.head ? 6 : 0)

			HoverHandler {
				id: hover
			}

			Avatar {
				visible: !root.mine && root.group && root.head
				y: stack.height - bubble.height + (root.head ? 6 : 0)
				size: 28
				name: root.message.from.name
				email: root.message.from.email
			}

			Column {
				id: stack

				x: Math.round(root.mine ? parent.width - width : (root.group ? 36 : 0))
				y: root.head ? 6 : 0
				spacing: 2

				StyledText {
					visible: !root.mine && root.group && root.head
					leftPadding: 12
					text: root.message.from.name
					tone: face.tone
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}

				Rectangle {
					id: bubble

					width: inner.width + 24
					height: inner.implicitHeight + 16
					radius: Theme.radius.large
					color: root.surface
					border.width: root.flash || root.picked ? 2 : 0
					border.color: Theme.primary

					Behavior on border.width {
						Anim {
							duration: Motion.medium
						}
					}

					ColumnLayout {
						id: inner

						// as wide as what it holds, up to the bubble's limit
						readonly property real wanted: Math.max(
							root.page ? root.page.width : Math.ceil(probe.implicitWidth) + 8,
							root.message.html.includes("<img") ? 330 : 0,
							root.message.ref ? 200 : 0,
							root.message.attachments.length > 0 ? 250 : 0,
							root.expanded ? (root.message.signaturePage && !root.whole ? root.message.signaturePage.width : (root.message.signatureRich ? 480 : 320)) : 0,
							title.visible ? Math.ceil(title.implicitWidth) : 0,
							foot.implicitWidth)

						x: 12
						y: 8
						width: Math.min(root.room - 24, inner.wanted)
						spacing: 6

						// the mail this one answers
						Clickable {
							visible: !!root.message.ref
							Layout.fillWidth: true
							implicitHeight: 40
							radius: Theme.radius.small
							color: Qt.alpha(Theme.fg, 0.07)
							pressedScale: 0.98
							onClicked: root.jump(root.message.ref.id)

							Rectangle {
								width: 3
								height: parent.height
								radius: 1.5
								color: Theme.primary
							}

							ColumnLayout {
								x: 11
								width: parent.width - 19
								anchors.verticalCenter: parent.verticalCenter
								spacing: 0

								StyledText {
									Layout.fillWidth: true
									text: root.message.ref?.name ?? ""
									tone: Theme.primary
									elide: Text.ElideRight
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
								}

								StyledText {
									Layout.fillWidth: true
									text: root.message.ref?.text ?? ""
									tone: Theme.textMuted
									elide: Text.ElideRight
									font.pixelSize: Theme.size.small
								}
							}
						}

						RowLayout {
							visible: root.message.forward || root.message.invite
							spacing: 5

							Glyph {
								icon: root.message.invite ? "calendar" : "share"
								size: 12
								color: Theme.textMuted
							}

							StyledText {
								text: root.message.invite ? "Invitation" : "Forwarded"
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
								font.italic: true
							}
						}

						// a mail of the chat that changed the subject
						StyledText {
							id: title

							visible: root.message.subject !== ""
							Layout.fillWidth: true
							text: root.message.subject
							wrapMode: Text.Wrap
							font.pixelSize: Theme.size.body
							font.weight: Font.Bold
						}

						TextEdit {
							id: body

							visible: root.message.loaded && root.message.html !== "" && !root.page
							Layout.fillWidth: true
							readOnly: true
							selectByMouse: true
							textFormat: TextEdit.RichText
							wrapMode: TextEdit.Wrap
							color: Theme.text
							selectionColor: Qt.alpha(Theme.primary, 0.4)
							selectedTextColor: Theme.text
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.body
							text: root.tinted(root.message.html)
							onLinkActivated: link => root.follow(link)

							HoverHandler {
								cursorShape: body.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
							}
						}

						// until the mail itself is here: how it begins
						StyledText {
							id: pending

							visible: !body.visible && !root.page && (root.message.text !== "" || !root.message.loaded)
							Layout.fillWidth: true
							text: root.message.text || "…"
							tone: root.message.loaded ? Theme.text : Theme.textMuted
							wrapMode: Text.Wrap
							font.pixelSize: Theme.size.body
						}

						// the mail as it was laid out, its links where they are
						Sheet {
							visible: root.page !== null
							Layout.fillWidth: true
							page: root.page
						}

						// attached pictures are looked at here; a click shows them large
						Repeater {
							model: root.message.attachments.filter(entry => entry.preview)

							delegate: Image {
								id: picture

								required property var modelData

								Layout.preferredWidth: Math.min(inner.width, 320, picture.implicitWidth > 0 ? picture.implicitWidth : 320)
								Layout.preferredHeight: picture.implicitWidth > 0 ? Layout.preferredWidth * picture.implicitHeight / picture.implicitWidth : 0
								source: `file://${picture.modelData.preview}`
								sourceSize.width: 640
								fillMode: Image.PreserveAspectFit
								asynchronous: true

								MouseArea {
									anchors.fill: parent
									cursorShape: Qt.PointingHandCursor
									onClicked: Mail.view(picture.modelData.preview)
								}
							}
						}

						Repeater {
							model: root.message.attachments

							delegate: Clickable {
								id: file

								required property var modelData

								Layout.fillWidth: true
								implicitHeight: 42
								radius: Theme.radius.small
								color: Qt.alpha(Theme.fg, 0.07)
								pressedScale: 0.98
								onClicked: Mail.openAttachment(root.message.id, file.modelData.id)

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 10
									anchors.rightMargin: 4
									spacing: 8

									Glyph {
										icon: root.fileIcon(file.modelData.type, file.modelData.name)
										size: 20
										color: Theme.primary
									}

									ColumnLayout {
										Layout.fillWidth: true
										spacing: 0

										StyledText {
											Layout.fillWidth: true
											text: file.modelData.name
											elide: Text.ElideMiddle
											font.pixelSize: Theme.size.label
											font.weight: Font.DemiBold
										}

										StyledText {
											visible: text !== ""
											text: root.size(file.modelData.size)
											tone: Theme.textSubtle
											font.pixelSize: Theme.size.tiny
										}
									}

									IconButton {
										implicitWidth: 30
										implicitHeight: 30
										icon: "download"
										onClicked: Mail.saveAttachment(root.message.id, file.modelData.id)
									}
								}
							}
						}

						// a signature with a layout of its own, as it was made
						Sheet {
							visible: root.expanded && !root.whole && !!root.message.signaturePage
							Layout.fillWidth: true
							page: root.expanded ? (root.message.signaturePage ?? null) : null
						}

						// … or what Qt draws of it where no picture could be made
						Rectangle {
							visible: root.expanded && root.message.signatureRich && !root.message.signaturePage && !root.whole
							Layout.fillWidth: true
							implicitHeight: paper.implicitHeight + 20
							radius: Theme.radius.small
							color: "white"
							clip: true

							Text {
								id: paper

								x: 10
								y: 10
								width: parent.width - 20
								textFormat: Text.RichText
								wrapMode: Text.Wrap
								color: "#1b1b1b"
								linkColor: "#0b57d0"
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.body
								text: parent.visible ? root.message.signature : ""
								onLinkActivated: link => Qt.openUrlExternally(link)
							}
						}

						// a plain signature and the mails quoted below it
						TextEdit {
							readonly property string folded: [root.message.signatureRich || root.whole ? "" : root.message.signature, root.message.quote].filter(part => part !== "").join("<br><br>")

							visible: root.expanded && folded !== ""
							Layout.fillWidth: true
							readOnly: true
							selectByMouse: true
							textFormat: TextEdit.RichText
							wrapMode: TextEdit.Wrap
							color: Theme.textMuted
							selectionColor: Qt.alpha(Theme.primary, 0.4)
							selectedTextColor: Theme.text
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.small
							text: root.expanded ? root.tinted(folded) : ""
							onLinkActivated: link => root.follow(link)
						}

						RowLayout {
							id: foot

							Layout.alignment: Qt.AlignRight
							spacing: 4

							Clickable {
								visible: root.folded
								implicitWidth: 24
								implicitHeight: 14
								radius: 7
								color: Qt.alpha(Theme.fg, root.expanded ? 0.16 : 0.08)
								onClicked: root.expanded = !root.expanded

								Glyph {
									anchors.centerIn: parent
									icon: "dots_horizontal"
									size: 13
									color: Theme.textMuted
								}
							}

							Glyph {
								visible: root.message.importance === "high"
								icon: "alert_circle"
								size: 11
								color: Theme.danger
							}

							Glyph {
								visible: root.message.flagged
								icon: "star"
								size: 11
								color: Theme.warning
							}

							StyledText {
								text: Qt.formatTime(root.when, "HH:mm")
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
								tabular: true
							}
						}
					}
				}
			}

			// what can be done with this mail: a strip on the bubble's upper corner while the
			// pointer is there. It stays inside the chat whatever the bubble's width, and
			// follows down a mail that is taller than the view.
			Rectangle {
				id: tools

				readonly property real bubbleTop: stack.y + stack.height - bubble.height
				// the upper edge of what the list shows, as this row sees it
				readonly property real viewTop: (root.ListView.view ? root.ListView.view.contentY - root.y : 0) - row.y

				x: Math.round(Math.max(0, Math.min(row.width - width, stack.x + stack.width - width - 10)))
				y: Math.round(Math.max(tools.bubbleTop - 14, Math.min(tools.viewTop + 6, tools.bubbleTop + bubble.height - height - 6)))
				z: 5
				width: strip.width + 8
				height: 34
				radius: height / 2
				color: Theme.layer3
				border.width: 1
				border.color: Theme.outline
				opacity: hover.hovered || toolsHover.hovered ? 1 : 0
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
					id: strip

					anchors.centerIn: parent
					spacing: 0

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						icon: "reply"
						onClicked: root.reply()
					}

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						icon: "share"
						onClicked: root.forward()
					}

					// as chat text, or the way the sender laid it out
					IconButton {
						visible: root.message.drawable
						implicitWidth: 28
						implicitHeight: 28
						icon: root.drawn ? "text" : "image_outline"
						onClicked: root.choice = !root.drawn
					}

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						icon: "open_in_new"
						onClicked: Mail.original(root.message.id)
					}

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						icon: "delete_outline"
						onClicked: Mail.removeMessage(root.message.id)
					}
				}
			}
		}
	}
}
