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
	// a forwarded conversation, oldest first: [{ name, email, date, html, text, right }]
	readonly property var chain: root.message.chain ?? []
	// a long one shows its newest mails until asked for all
	property bool wholeChain: false
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
	readonly property color surface: root.mine ? Messages.mine : Messages.theirs
	// the room above the first of a run, and the corner of the ones that follow it
	readonly property real lead: root.head && !root.newDay ? 10 : 0
	readonly property real joint: Messages.bubbleJoint

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

	function fileIcon(type, name) {
		if (String(type).startsWith("image/")) return "file_image";
		if (String(type).includes("pdf") || String(name).toLowerCase().endsWith(".pdf")) return "file_pdf_box";
		if (String(type).includes("calendar")) return "calendar";
		return "file_outline";
	}

	// links wear the accent, and a picture is a link to itself: a click shows it large
	function tinted(html) {
		return root.snug(html).replace(/<a href=/g, `<a style="color:${Messages.accent}" href=`)
			.replace(/<img src="file:\/\/([^"]+)"[^>]*>/g, (image, path) => `<a href="pshell-picture:${path}">${image}</a>`);
	}

	// rich text puts room above its first and below its last paragraph: in a bubble that is a hole
	function snug(html) {
		let text = String(html).trim();
		const first = text.match(/^<p(\s[^>]*)?>/);
		if (first && !/style=/.test(first[0])) text = `<p style="margin-top:0"${first[1] ?? ""}>` + text.slice(first[0].length);
		const last = text.lastIndexOf("<p");
		if (last >= 0 && text.endsWith("</p>")) {
			const tag = text.slice(last).match(/^<p(\s[^>]*)?>/);
			if (tag && tag[0].includes("margin-top:0") && !tag[0].includes("margin-bottom")) text = text.slice(0, last) + tag[0].replace("margin-top:0", "margin-top:0;margin-bottom:0") + text.slice(last + tag[0].length);
			else if (tag && !/style=/.test(tag[0])) text = text.slice(0, last) + `<p style="margin-bottom:0"${tag[1] ?? ""}>` + text.slice(last + tag[0].length);
		}
		return text;
	}

	function follow(link) {
		if (link.startsWith("pshell-picture:")) Mail.view(link.slice(15));
		else Qt.openUrlExternally(link);
	}

	// a mail that just arrived comes up out of its corner
	function appear() {
		if (Messages.style.arrival !== "none") pop.restart();
	}

	implicitHeight: column.implicitHeight
	// the strip of the bubble under the pointer may reach over the mail above it
	z: hover.hovered || root.toolsOver ? 2 : 0
	// the pointer was on this mail once: its tools are made
	property bool touched: false
	readonly property bool toolsOver: toolsLoader.item?.over ?? false

	ParallelAnimation {
		id: pop

		Anim {
			target: stack
			property: "opacity"
			from: 0
			to: 1
			duration: Messages.style.arrival === "fade" ? Motion.long : Motion.short
		}
		SpatialAnim {
			target: stack
			property: "scale"
			from: Messages.style.arrival === "pop" ? 0.9 : 1
			to: 1
			duration: Motion.long
		}
		SpatialAnim {
			target: slide
			property: "x"
			from: Messages.style.arrival === "slide" ? (root.mine ? 48 : -48) : 0
			to: 0
			duration: Motion.long
		}
	}

	// the colour of who wrote, where names are shown
	readonly property color tone: root.toneOf(root.message.from.email || root.message.from.name)

	function toneOf(key) {
		let sum = 0;
		for (let i = 0; i < key.length; i += 1) sum = (sum * 31 + key.charCodeAt(i)) % 360;
		return Qt.hsla(sum / 360, 0.45, Theme.dark ? 0.62 : 0.42, 1);
	}

	Gradient {
		id: ownGradient

		orientation: Gradient.Horizontal

		GradientStop {
			position: 0
			color: Messages.mine
		}
		GradientStop {
			position: 1
			color: Messages.mineEnd
		}
	}

	// how wide the text would run unwrapped
	Text {
		id: probe

		visible: false
		// a line this long is wider than any bubble: the rest of a long mail need not be measured
		text: String(root.message.text || "…").slice(0, 240)
		font.family: Theme.fontFamily
		font.pixelSize: Messages.textSize
		font.weight: Font.DemiBold
	}

	Column {
		id: column

		width: parent.width
		spacing: 3

		Item {
			visible: root.newDay
			width: parent.width
			height: 44

			Rectangle {
				anchors.centerIn: parent
				width: dayLabel.implicitWidth + 24
				height: 24
				radius: 12
				color: Theme.layer2

				StyledText {
					id: dayLabel

					anchors.centerIn: parent
					text: root.day()
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}
			}
		}

		// an automatic reply is a notice, not a message
		// Only where the mail is one: laid out by hand, as a layout that takes its width from
		// the wrapped words it holds never settles – and every bubble of a long chat paid for it.
		Loader {
			active: root.message.auto
			visible: active
			anchors.horizontalCenter: parent.horizontalCenter
			sourceComponent: Rectangle {
				// how wide the words would run unwrapped
				readonly property real wanted: Math.max(noticeHead.implicitWidth, noticeProbe.implicitWidth)

				width: Math.min(root.maxWidth, Math.ceil(wanted) + 28)
				height: notice.height + 16
				radius: Theme.radius.medium
				color: Theme.layer2

				Text {
					id: noticeProbe

					visible: false
					text: String(root.message.text).slice(0, 400)
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
				}

				Column {
					id: notice

					x: 14
					y: 8
					width: parent.width - 28
					spacing: 2

					Row {
						id: noticeHead

						anchors.horizontalCenter: parent.horizontalCenter
						spacing: 6

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
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
						width: parent.width
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
		}

		Item {
			id: row

			visible: !root.message.auto
			width: parent.width
			height: stack.height + root.lead

			HoverHandler {
				id: hover

				onHoveredChanged: if (hovered) root.touched = true
			}

			Avatar {
				visible: !root.mine && root.group && root.head
				y: root.lead
				size: 28
				name: root.message.from.name
				email: root.message.from.email
			}

			Column {
				id: stack

				x: Math.round(root.mine ? parent.width - width : (root.group ? 36 : 0))
				y: root.lead
				spacing: 2
				transformOrigin: root.mine ? Item.BottomRight : Item.BottomLeft
				transform: Translate {
					id: slide
				}

				Rectangle {
					id: bubble

					width: inner.width + 24
					height: inner.implicitHeight + 16
					radius: Messages.bubbleRadius
					gradient: root.mine && Messages.style.gradient ? ownGradient : null
					// one of a run hangs on the one before it
					topLeftRadius: !root.mine && !root.head ? root.joint : radius
					topRightRadius: root.mine && !root.head ? root.joint : radius
					color: root.surface
					border.width: root.flash || root.picked ? 2 : 0
					border.color: Messages.accent

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
							root.chain.length > 0 ? 460 : 0,
							root.message.attachments.length > 0 ? 250 : 0,
							root.expanded ? (root.message.signaturePage && !root.whole ? root.message.signaturePage.width : (root.message.signatureRich ? 480 : 320)) : 0,
							title.visible ? Math.ceil(title.implicitWidth) : 0,
							name.visible ? Math.ceil(name.implicitWidth) : 0,
							foot.implicitWidth)

						x: 12
						y: 8
						width: Math.min(root.room - 24, inner.wanted)
						spacing: 6

						// who wrote it, where more than one could have
						StyledText {
							id: name

							visible: !root.mine && root.group && root.head
							text: root.message.from.name
							tone: root.tone
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}

						// the mail this one answers
						Loader {
							active: !!root.message.ref
							visible: active
							Layout.fillWidth: true
							sourceComponent: Clickable {
								implicitHeight: 40
								radius: Theme.radius.small
								color: Qt.alpha(Theme.fg, 0.07)
								pressedScale: 0.98
								onClicked: root.jump(root.message.ref.id)

								Rectangle {
									width: 3
									height: parent.height
									radius: 1.5
									color: Messages.accent
								}

								ColumnLayout {
									x: 11
									width: parent.width - 19
									anchors.verticalCenter: parent.verticalCenter
									spacing: 0

									StyledText {
										text: root.message.ref?.name ?? ""
										tone: Messages.accent
										elide: Text.ElideRight
										font.pixelSize: Theme.size.small
										font.weight: Font.DemiBold
									}

									StyledText {
										text: root.message.ref?.text ?? ""
										tone: Theme.textMuted
										elide: Text.ElideRight
										font.pixelSize: Theme.size.small
									}
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

						Loader {
							id: body
							
							active: root.message.loaded && root.message.html !== "" && !root.page
							visible: active
							Layout.fillWidth: true
							sourceComponent: TextEdit {
								readOnly: true
								selectByMouse: true
								textFormat: TextEdit.RichText
								wrapMode: TextEdit.Wrap
								color: Theme.text
								selectionColor: Qt.alpha(Messages.accent, 0.4)
								selectedTextColor: Theme.text
								font.family: Theme.fontFamily
								font.pixelSize: Messages.textSize
								text: root.tinted(root.message.html)
								onLinkActivated: link => root.follow(link)

								HoverHandler {
									cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
								}
							}
						}

						// until the mail itself is here: how it begins
						Loader {
							active: !body.active && !root.page && root.chain.length === 0 && (root.message.text !== "" || !root.message.loaded)
							visible: active
							Layout.fillWidth: true
							sourceComponent: StyledText {
								text: root.message.text || "…"
								tone: root.message.loaded ? Theme.text : Theme.textMuted
								wrapMode: Text.Wrap
								elide: Text.ElideNone
								font.pixelSize: Messages.textSize
							}
						}

						// the mail as it was laid out, its links where they are
						Loader {
							active: root.page !== null
							visible: active
							Layout.fillWidth: true
							sourceComponent: Sheet {
								page: root.page
							}
						}

						// the forwarded conversation, packed: its mails as a chat of their own
						Loader {
							active: root.chain.length > 0
							visible: active
							Layout.fillWidth: true
							sourceComponent: Rectangle {
								id: pack

								readonly property int hidden: root.wholeChain ? 0 : Math.max(0, root.chain.length - 4)

								implicitHeight: thread.implicitHeight + 16
								radius: Theme.radius.medium
								color: Qt.alpha(Theme.fg, 0.05)
								border.width: 1
								border.color: Qt.alpha(Theme.fg, 0.08)

								Column {
									id: thread

									x: 8
									y: 8
									width: parent.width - 16
									spacing: 3

									Clickable {
										visible: pack.hidden > 0
										anchors.horizontalCenter: parent.horizontalCenter
										implicitWidth: earlier.implicitWidth + 20
										implicitHeight: 22
										radius: 11
										color: Qt.alpha(Theme.fg, 0.08)
										onClicked: root.wholeChain = true

										StyledText {
											id: earlier

											anchors.centerIn: parent
											text: pack.hidden === 1 ? "1 earlier mail" : `${pack.hidden} earlier mails`
											tone: Theme.textMuted
											font.pixelSize: Theme.size.small
										}
									}

									Repeater {
										model: root.chain.slice(pack.hidden)

										delegate: Item {
											id: quoted

											required property var modelData
											required property int index
											readonly property var before: quoted.index > 0 ? root.chain[pack.hidden + quoted.index - 1] : null
											// the first of a run from one person carries the name
											readonly property bool head: !quoted.before || quoted.before.email !== quoted.modelData.email || quoted.before.name !== quoted.modelData.name
											readonly property real wanted: Math.max(Math.ceil(quotedProbe.implicitWidth) + 4, Math.ceil(quotedHead.implicitWidth))

											width: thread.width
											height: card.height + (quoted.head && quoted.index > 0 ? 5 : 0)

											Text {
												id: quotedProbe

												visible: false
												text: String(quoted.modelData.text).slice(0, 200)
												font.family: Theme.fontFamily
												font.pixelSize: Messages.textSize
											}

											Rectangle {
												id: card

												x: quoted.modelData.right ? parent.width - width : 0
												y: parent.height - height
												width: Math.min(parent.width * 0.86, quoted.wanted + 20)
												height: cardColumn.implicitHeight + 12
												radius: Math.max(4, Messages.bubbleRadius - 4)
												topLeftRadius: !quoted.modelData.right && !quoted.head ? root.joint : radius
												topRightRadius: quoted.modelData.right && !quoted.head ? root.joint : radius
												color: quoted.modelData.right ? Qt.alpha(Messages.accent, 0.16) : Qt.alpha(Theme.fg, 0.07)

												ColumnLayout {
													id: cardColumn

													x: 10
													y: 6
													width: parent.width - 20
													spacing: 2

													RowLayout {
														id: quotedHead

														visible: quoted.head
														spacing: 6

														StyledText {
															text: quoted.modelData.name
															tone: root.toneOf(quoted.modelData.email || quoted.modelData.name)
															font.pixelSize: Theme.size.small
															font.weight: Font.DemiBold
														}

														StyledText {
															text: quoted.modelData.date
															tone: Theme.textSubtle
															font.pixelSize: Theme.size.tiny
														}
													}

													TextEdit {
														Layout.fillWidth: true
														readOnly: true
														selectByMouse: true
														textFormat: TextEdit.RichText
														wrapMode: TextEdit.Wrap
														color: Theme.text
														selectionColor: Qt.alpha(Messages.accent, 0.4)
														selectedTextColor: Theme.text
														font.family: Theme.fontFamily
														font.pixelSize: Messages.textSize
														text: root.tinted(quoted.modelData.html)
														onLinkActivated: link => root.follow(link)

														HoverHandler {
															cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
														}
													}
												}
											}
										}
									}
								}
							}
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
										color: Messages.accent
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
											text: Format.bytes(file.modelData.size, "")
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
						Loader {
							active: root.expanded && !root.whole && !!root.message.signaturePage
							visible: active
							Layout.fillWidth: true
							sourceComponent: Sheet {
								page: root.expanded ? (root.message.signaturePage ?? null) : null
							}
						}

						// … or what Qt draws of it where no picture could be made
						Loader {
							active: root.expanded && root.message.signatureRich && !root.message.signaturePage && !root.whole
							visible: active
							Layout.fillWidth: true
							sourceComponent: Rectangle {
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
						}

						// a plain signature and the mails quoted below it
						Loader {
							id: fold

							readonly property string folded: [root.message.signatureRich || root.whole ? "" : root.message.signature, root.message.quote].filter(part => part !== "").join("<br><br>")

							active: root.expanded && folded !== ""
							visible: active
							Layout.fillWidth: true
							sourceComponent: TextEdit {
								readOnly: true
								selectByMouse: true
								textFormat: TextEdit.RichText
								wrapMode: TextEdit.Wrap
								color: Theme.textMuted
								selectionColor: Qt.alpha(Messages.accent, 0.4)
								selectedTextColor: Theme.text
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.small
								text: root.expanded ? root.tinted(fold.folded) : ""
								onLinkActivated: link => root.follow(link)
							}
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
			// Made when the pointer first comes to the mail: a long chat does not pay for strips nobody sees.
			Loader {
				id: toolsLoader

				z: 5
				active: root.touched
				sourceComponent: Rectangle {
					id: tools

					readonly property bool over: toolsHover.hovered
					readonly property real bubbleTop: stack.y + stack.height - bubble.height
					// the upper edge of what the list shows, as this row sees it
					readonly property real viewTop: (root.ListView.view ? root.ListView.view.contentY - root.y : 0) - row.y

					x: Math.round(Math.max(0, Math.min(row.width - width, stack.x + stack.width - width - 10)))
					y: Math.round(Math.max(tools.bubbleTop - 14, Math.min(tools.viewTop + 6, tools.bubbleTop + bubble.height - height - 6)))
					width: strip.width + 8
					height: 34
					radius: height / 2
					color: Theme.layer3
					border.width: 1
					border.color: Theme.outline
					readonly property bool shown: hover.hovered || toolsHover.hovered
					opacity: shown ? 1 : 0
					scale: shown ? 1 : 0.86
					transformOrigin: Item.BottomRight
					visible: opacity > 0.01

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
					Behavior on scale {
						SpatialAnim {
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
}
