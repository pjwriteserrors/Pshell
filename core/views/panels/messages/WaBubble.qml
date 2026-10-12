pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One WhatsApp message: words, a photo, a video or GIF, a voice message, a
// sticker, a document, a place, a contact or a poll – with what it answers
// above it, the reactions below it, and under the pointer what can be done
// with it.
Item {
	id: root

	required property var message
	property var previous: null
	// a group: who wrote stands above what they wrote
	property bool group: false
	// lights up when a quote or a search leads here
	property bool flash: false

	readonly property bool mine: root.message.mine
	readonly property string kind: root.message.kind
	readonly property var media: root.message.media ?? null
	readonly property date when: new Date(root.message.date * 1000)
	readonly property bool newDay: !root.previous || new Date(root.previous.date * 1000).toDateString() !== root.when.toDateString()
	readonly property bool system: root.kind === "system"
	readonly property bool head: root.newDay || !root.previous || root.previous.kind === "system" || root.previous.sender !== root.message.sender || root.message.date - root.previous.date > 900
	// drawn without a bubble around it
	readonly property bool bare: root.kind === "sticker" && root.file !== ""
	// seen once and gone: linked devices are not shown these
	readonly property bool hidden: (root.media?.viewOnce ?? false) || root.kind === "unsupported" || root.kind === "waiting" || root.kind === "deleted"
	readonly property bool pictured: !root.hidden && (root.kind === "image" || root.kind === "video" || root.kind === "gif")
	readonly property string file: root.media?.path ?? ""
	readonly property real maxWidth: Math.min(520, root.width * 0.74)
	readonly property real mediaScale: {
		const w = root.media?.width || 260;
		const h = root.media?.height || 200;
		return Math.min(Math.min(300, root.maxWidth - 8) / w, 340 / h, 1.5);
	}
	readonly property real mediaWidth: Math.max(140, Math.round((root.media?.width || 260) * root.mediaScale))
	readonly property real mediaHeight: Math.max(90, Math.round((root.media?.height || 200) * root.mediaScale))
	readonly property color surface: root.mine ? Messages.mine : Messages.theirs
	// the room above the first of a run, and the corner of the ones that follow it
	readonly property real lead: root.head && !root.newDay ? 10 : 0
	readonly property real joint: Messages.bubbleJoint
	readonly property bool playing: WhatsApp.playing === root.message.id
	// the reactions are offered instead of the tools
	property bool reacting: false
	// plays as soon as its file is here
	property bool awaited: false

	signal reply
	signal forward
	signal edit
	signal jump(string id)
	// emoji are thrown into the air from a place in the list
	signal burst(string emoji, real x, real y)

	function day() {
		const now = new Date();
		const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
		if (root.when.toDateString() === now.toDateString()) return "Today";
		if (root.when.toDateString() === yesterday.toDateString()) return "Yesterday";
		return Qt.formatDate(root.when, root.when.getFullYear() === now.getFullYear() ? "dddd, d MMMM" : "d MMMM yyyy");
	}

	function note() {
		if (root.kind === "deleted") return "Message deleted";
		if (root.kind === "waiting") return "Waiting for this message";
		if (root.media?.viewOnce) return "View once – shown on the phone";
		return "This message is shown on the phone";
	}

	function play() {
		if (root.file === "") {
			root.awaited = true;
			patience.restart();
			WhatsApp.fetch(root.message.id, "");
			return;
		}
		WhatsApp.playing = root.playing ? "" : root.message.id;
	}

	function vote(option) {
		const poll = root.message.poll;
		let chosen = poll.options.filter(entry => entry.mine).map(entry => entry.name);
		if (chosen.includes(option)) chosen = chosen.filter(name => name !== option);
		else chosen = poll.multi ? chosen.concat([option]) : [option];
		WhatsApp.act("vote", root.message.id, { options: chosen });
	}

	// a video is watched over the chat, as soon as its file is here
	function watch() {
		if (root.file !== "") {
			Mail.view(root.file);
			return;
		}
		root.awaited = true;
		patience.restart();
		WhatsApp.fetch(root.message.id, "");
	}

	onFileChanged: if (root.awaited && root.file !== "") {
		root.awaited = false;
		if (root.kind === "video") Mail.view(root.file);
		else WhatsApp.playing = root.message.id;
	}
	// it could not be fetched: nothing is waited for
	readonly property string trouble: root.media?.error ?? ""
	onTroubleChanged: if (root.trouble !== "") root.awaited = false

	Timer {
		id: patience

		interval: 90000
		onTriggered: root.awaited = false
	}

	// a message that just arrived or was sent comes up out of its corner
	function appear() {
		if (Messages.style.arrival !== "none") pop.restart();
		// nothing but emoji: they fly
		if (root.message.big && Messages.style.effects) root.burst(root.message.text, stack.x + stack.width / 2, root.y + row.y + stack.y + stack.height / 2);
	}

	implicitHeight: column.implicitHeight
	z: hover.hovered || toolsHover.hovered ? 2 : 0

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
			from: Messages.style.arrival === "pop" ? 0.82 : 1
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

	WaAvatar {
		id: face

		visible: false
		key: root.message.sender
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

	// how wide the words would run unwrapped
	Text {
		id: probe

		visible: false
		text: String(root.message.text).split("\n").reduce((longest, line) => line.length > longest.length ? line : longest, "") || "…"
		font.family: Theme.fontFamily
		font.pixelSize: root.message.big ? 34 : Messages.textSize
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

		// what happened in the chat is a line, not a message
		Item {
			visible: root.system
			width: parent.width
			height: systemLabel.implicitHeight + 14

			Rectangle {
				anchors.centerIn: parent
				width: Math.min(root.maxWidth, systemLabel.implicitWidth + 24)
				height: systemLabel.implicitHeight + 10
				radius: Theme.radius.medium
				color: Theme.layer2

				StyledText {
					id: systemLabel

					anchors.centerIn: parent
					width: Math.min(implicitWidth, root.maxWidth - 24)
					text: root.message.text
					tone: Theme.textMuted
					wrapMode: Text.Wrap
					horizontalAlignment: Text.AlignHCenter
					font.pixelSize: Theme.size.small
				}
			}
		}

		Item {
			id: row

			visible: !root.system
			width: parent.width
			height: stack.height + root.lead

			HoverHandler {
				id: hover

				onHoveredChanged: if (!hovered && !toolsHover.hovered) root.reacting = false
			}

			WaAvatar {
				visible: !root.mine && root.group && root.head
				y: root.lead
				size: 28
				name: root.message.name
				key: root.message.sender
				picture: WhatsApp.people[root.message.sender]?.avatar ?? ""
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

					width: inner.width + (root.bare ? 0 : (root.pictured ? 8 : 24))
					height: inner.implicitHeight + (root.bare ? 0 : (root.pictured ? 8 : 16))
					radius: Messages.bubbleRadius
					gradient: root.mine && !root.bare && Messages.style.gradient ? ownGradient : null
					// one of a run hangs on the one before it
					topLeftRadius: !root.mine && !root.head ? root.joint : radius
					topRightRadius: root.mine && !root.head ? root.joint : radius
					color: root.bare ? "transparent" : root.surface
					border.width: root.flash ? 2 : 0
					border.color: Messages.accent

					Behavior on border.width {
						Anim {
							duration: Motion.medium
						}
					}

					ColumnLayout {
						id: inner

						readonly property real wanted: Math.max(
							Math.ceil(probe.implicitWidth) + 8,
							root.pictured ? root.mediaWidth : 0,
							root.bare ? 150 : 0,
							root.message.quote ? 200 : 0,
							root.message.poll ? 280 : 0,
							root.message.link ? 280 : 0,
							root.kind === "voice" || root.kind === "audio" ? 250 : 0,
							root.kind === "document" || root.kind === "contact" || root.kind === "location" ? 240 : 0,
							root.hidden ? 210 : 0,
							name.visible ? Math.ceil(name.implicitWidth) : 0,
							foot.implicitWidth + 4)

						x: root.bare ? 0 : (root.pictured ? 4 : 12)
						y: root.bare ? 0 : (root.pictured ? 4 : 8)
						width: Math.min(inner.wanted, root.maxWidth - (root.pictured ? 8 : 24))
						spacing: 5

						StyledText {
							id: name

							visible: !root.mine && root.group && root.head && !root.bare
							Layout.leftMargin: root.pictured ? 8 : 0
							Layout.topMargin: root.pictured ? 4 : 0
							text: root.message.name
							tone: face.tone
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}

						RowLayout {
							visible: (root.message.forwarded ?? false) && !root.bare
							Layout.leftMargin: root.pictured ? 8 : 0
							spacing: 4

							Glyph {
								icon: "share"
								size: 11
								color: Theme.textSubtle
							}

							StyledText {
								text: "Forwarded"
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
								font.italic: true
							}
						}

						// what it answers
						Clickable {
							visible: root.message.quote !== undefined
							Layout.fillWidth: true
							Layout.margins: root.pictured || root.bare ? 4 : 0
							implicitHeight: quoted.implicitHeight + 12
							radius: Theme.radius.small
							pressedScale: 0.99
							color: root.bare ? Theme.layer2 : Qt.alpha(Theme.text, 0.07)
							onClicked: root.jump(root.message.quote.id)

							Rectangle {
								width: 3
								height: parent.height
								radius: 1.5
								color: Messages.accent
							}

							ColumnLayout {
								id: quoted

								x: 10
								y: 6
								width: parent.width - 18
								spacing: 1

								StyledText {
									text: root.message.quote?.name ?? ""
									tone: Messages.accent
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
								}

								StyledText {
									Layout.fillWidth: true
									text: root.message.quote?.text ?? ""
									tone: Theme.textMuted
									elide: Text.ElideRight
									maximumLineCount: 2
									wrapMode: Text.Wrap
									font.pixelSize: Theme.size.small
								}
							}
						}

						// a photo, a video, a GIF
						ClippingRectangle {
							id: frame

							visible: root.pictured
							Layout.preferredWidth: inner.width
							Layout.preferredHeight: Math.round(root.mediaHeight * inner.width / root.mediaWidth)
							radius: Math.max(2, Messages.bubbleRadius - 4)
							color: Qt.alpha(Theme.text, 0.06)

							Image {
								anchors.fill: parent
								visible: root.pictured
								// a video's own first picture, a photo itself once it is here
								source: {
									if (!root.pictured) return "";
									const shown = root.kind === "image" && root.file !== "" ? root.file : (root.media?.thumb ?? "");
									return shown !== "" ? `file://${shown}` : "";
								}
								sourceSize.width: 900
								fillMode: Image.PreserveAspectCrop
								asynchronous: true
								smooth: true
							}

							Loader {
								anchors.fill: parent
								active: root.kind === "gif" && root.file !== "" && (hover.hovered || root.playing)
								sourceComponent: Item {
									MediaPlayer {
										source: `file://${root.file}`
										loops: MediaPlayer.Infinite
										videoOutput: moving
										Component.onCompleted: play()
									}

									VideoOutput {
										id: moving

										anchors.fill: parent
										fillMode: VideoOutput.PreserveAspectCrop
									}
								}
							}

							Rectangle {
								anchors.centerIn: parent
								visible: root.kind !== "image" || root.file === ""
								width: 44
								height: 44
								radius: 22
								color: Qt.rgba(0, 0, 0, 0.5)

								Glyph {
									anchors.centerIn: parent
									visible: !(root.awaited && root.file === "")
									icon: root.kind === "gif" ? "file_gif_box" : (root.kind === "video" ? "play" : "download")
									size: 22
									color: "white"
								}

								Spinner {
									anchors.centerIn: parent
									visible: root.awaited && root.file === ""
									width: 20
									height: 20
									color: "white"
								}
							}

							Rectangle {
								visible: root.kind === "video" && (root.media?.seconds ?? 0) > 0
								anchors.left: parent.left
								anchors.bottom: parent.bottom
								anchors.margins: 6
								width: length.implicitWidth + 10
								height: 18
								radius: 9
								color: Qt.rgba(0, 0, 0, 0.5)

								Text {
									id: length

									anchors.centerIn: parent
									text: WhatsApp.clock(root.media?.seconds ?? 0)
									color: "white"
									font.family: Theme.fontFamily
									font.pixelSize: Theme.size.tiny
								}
							}

							MouseArea {
								anchors.fill: parent
								cursorShape: Qt.PointingHandCursor
								onClicked: {
									if (root.kind === "image") {
										if (root.file !== "") Mail.view(root.file);
										else WhatsApp.fetch(root.message.id, "");
									} else if (root.kind === "gif") {
										root.play();
									} else {
										root.watch();
									}
								}
							}
						}

						// a sticker
						Item {
							visible: root.bare
							implicitWidth: 150
							implicitHeight: 150

							Loader {
								anchors.fill: parent
								active: root.bare
								sourceComponent: root.file.endsWith(".png") ? still : animated
							}

							Component {
								id: still

								Image {
									source: `file://${root.file}`
									sourceSize.width: 300
									sourceSize.height: 300
									fillMode: Image.PreserveAspectFit
									asynchronous: true
								}
							}

							Component {
								id: animated

								AnimatedImage {
									source: `file://${root.file}`
									fillMode: Image.PreserveAspectFit
									asynchronous: true
									playing: hover.hovered || (root.ListView.view?.moving === false)
								}
							}
						}

						// why its file is not here
						StyledText {
							visible: root.trouble !== "" && root.kind !== "sticker" && !root.hidden
							Layout.fillWidth: true
							Layout.leftMargin: root.pictured ? 8 : 0
							Layout.rightMargin: root.pictured ? 8 : 0
							text: root.trouble
							tone: Theme.textSubtle
							wrapMode: Text.Wrap
							font.pixelSize: Theme.size.small
							font.italic: true
						}

						RowLayout {
							visible: root.kind === "sticker" && !root.bare
							spacing: 6

							Glyph {
								icon: "sticker_emoji"
								size: 16
								color: Theme.textMuted
							}

							StyledText {
								text: root.media?.error || "Sticker"
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}
						}

						// a voice message, or sound of another kind
						RowLayout {
							visible: (root.kind === "voice" || root.kind === "audio") && !root.hidden
							Layout.fillWidth: true
							spacing: 8

							IconButton {
								implicitWidth: 34
								implicitHeight: 34
								icon: root.awaited && root.file === "" ? "" : (root.playing && sound.item?.playbackState === MediaPlayer.PlayingState ? "pause" : "play")
								variant: "filled"
								onClicked: root.play()

								Spinner {
									anchors.centerIn: parent
									visible: root.awaited && root.file === ""
									width: 16
									height: 16
									color: Theme.onPrimary
								}
							}

							Loader {
								id: sound

								active: root.playing && root.file !== ""
								sourceComponent: MediaPlayer {
									source: `file://${root.file}`
									audioOutput: AudioOutput {}
									Component.onCompleted: play()
									onPlaybackStateChanged: if (playbackState === MediaPlayer.StoppedState && position > 0 && WhatsApp.playing === root.message.id) WhatsApp.playing = ""
								}
							}

							Rectangle {
								Layout.fillWidth: true
								implicitHeight: 4
								radius: 2
								color: Qt.alpha(Theme.text, 0.14)

								Rectangle {
									width: parent.width * (sound.item && sound.item.duration > 0 ? sound.item.position / sound.item.duration : 0)
									height: parent.height
									radius: 2
									color: Messages.accent
								}

								MouseArea {
									anchors.fill: parent
									anchors.margins: -8
									enabled: sound.item !== null
									onClicked: event => sound.item.position = sound.item.duration * Math.max(0, Math.min(1, (event.x - 8) / parent.width))
								}
							}

							Glyph {
								icon: root.kind === "voice" ? "microphone" : "music_note"
								size: 13
								color: root.message.status >= 4 || (!root.mine && root.file !== "") ? Messages.accent : Theme.textSubtle
							}

							StyledText {
								text: WhatsApp.clock(sound.item ? sound.item.position / 1000 : (root.media?.seconds ?? 0))
								tone: Theme.textMuted
								tabular: true
								font.pixelSize: Theme.size.small
							}
						}

						// a document
						Clickable {
							visible: root.kind === "document" && !root.hidden
							Layout.fillWidth: true
							implicitHeight: 48
							radius: Theme.radius.small
							pressedScale: 0.98
							color: Qt.alpha(Theme.text, 0.07)
							onClicked: WhatsApp.fetch(root.message.id, "open")

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 10
								anchors.rightMargin: 10
								spacing: 10

								Glyph {
									icon: "file_document_outline"
									size: 22
									color: Messages.accent
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 1

									StyledText {
										Layout.fillWidth: true
										text: root.media?.name || "Document"
										elide: Text.ElideMiddle
										font.pixelSize: Theme.size.label
										font.weight: Font.DemiBold
									}

									StyledText {
										text: WhatsApp.size(root.media?.size ?? 0)
										tone: Theme.textSubtle
										font.pixelSize: Theme.size.tiny
									}
								}
							}
						}

						// a place
						Clickable {
							visible: root.kind === "location"
							Layout.fillWidth: true
							implicitHeight: 48
							radius: Theme.radius.small
							pressedScale: 0.98
							color: Qt.alpha(Theme.text, 0.07)
							onClicked: {
								const place = root.message.place;
								Qt.openUrlExternally(`https://www.openstreetmap.org/?mlat=${place.lat}&mlon=${place.lng}#map=16/${place.lat}/${place.lng}`);
							}

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 10
								anchors.rightMargin: 10
								spacing: 10

								Glyph {
									icon: "map_marker"
									size: 22
									color: Theme.danger
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 1

									StyledText {
										Layout.fillWidth: true
										text: root.message.place?.name || (root.message.place?.live ? "Live location" : "Location")
										elide: Text.ElideRight
										font.pixelSize: Theme.size.label
										font.weight: Font.DemiBold
									}

									StyledText {
										Layout.fillWidth: true
										text: root.message.place?.address || `${(root.message.place?.lat ?? 0).toFixed(5)}, ${(root.message.place?.lng ?? 0).toFixed(5)}`
										tone: Theme.textSubtle
										elide: Text.ElideRight
										font.pixelSize: Theme.size.tiny
									}
								}
							}
						}

						// people sent as contacts
						Repeater {
							model: root.message.cards ?? []

							delegate: Clickable {
								id: person

								required property var modelData

								Layout.fillWidth: true
								implicitHeight: 48
								radius: Theme.radius.small
								pressedScale: 0.98
								color: Qt.alpha(Theme.text, 0.07)
								onClicked: if (person.modelData.phones.length > 0) WhatsApp.startChat(person.modelData.phones[0])

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 10
									anchors.rightMargin: 10
									spacing: 10

									WaAvatar {
										size: 30
										name: person.modelData.name
									}

									ColumnLayout {
										Layout.fillWidth: true
										spacing: 1

										StyledText {
											Layout.fillWidth: true
											text: person.modelData.name
											elide: Text.ElideRight
											font.pixelSize: Theme.size.label
											font.weight: Font.DemiBold
										}

										StyledText {
											text: person.modelData.phones.join(", ")
											tone: Theme.textSubtle
											font.pixelSize: Theme.size.tiny
										}
									}
								}
							}
						}

						// a link, as its page presents itself
						Clickable {
							visible: root.message.link !== undefined
							Layout.fillWidth: true
							implicitHeight: 56
							radius: Theme.radius.small
							pressedScale: 0.99
							color: Qt.alpha(Theme.text, 0.07)
							onClicked: Qt.openUrlExternally(root.message.link.url)

							RowLayout {
								anchors.fill: parent
								anchors.rightMargin: 10
								spacing: 10

								ClippingRectangle {
									visible: (root.message.link?.thumb ?? "") !== ""
									Layout.preferredWidth: 56
									Layout.preferredHeight: 56
									radius: Theme.radius.small
									color: "transparent"

									Image {
										anchors.fill: parent
										source: root.message.link?.thumb ? `file://${root.message.link.thumb}` : ""
										fillMode: Image.PreserveAspectCrop
										asynchronous: true
									}
								}

								ColumnLayout {
									Layout.fillWidth: true
									Layout.leftMargin: (root.message.link?.thumb ?? "") !== "" ? 0 : 10
									spacing: 1

									StyledText {
										Layout.fillWidth: true
										text: root.message.link?.title ?? ""
										elide: Text.ElideRight
										font.pixelSize: Theme.size.label
										font.weight: Font.DemiBold
									}

									StyledText {
										Layout.fillWidth: true
										text: root.message.link?.description ?? ""
										tone: Theme.textSubtle
										elide: Text.ElideRight
										maximumLineCount: 2
										wrapMode: Text.Wrap
										font.pixelSize: Theme.size.tiny
									}
								}
							}
						}

						// what cannot be shown here
						RowLayout {
							visible: root.hidden
							spacing: 6

							Glyph {
								icon: root.kind === "deleted" ? "cancel" : (root.kind === "waiting" ? "clock_outline" : "cellphone")
								size: 14
								color: Theme.textSubtle
							}

							StyledText {
								text: root.note()
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
								font.italic: true
							}
						}

						// the words: a text, a caption, the question of a poll
						TextEdit {
							visible: root.message.text !== "" && !root.hidden
							Layout.fillWidth: true
							Layout.leftMargin: root.pictured ? 8 : 0
							Layout.rightMargin: root.pictured ? 8 : 0
							readOnly: true
							selectByMouse: true
							textFormat: TextEdit.RichText
							text: root.message.html.replace(/<a /g, `<a style="color:${Messages.accent}" `)
							color: Theme.text
							selectionColor: Qt.alpha(Messages.accent, 0.4)
							selectedTextColor: Theme.text
							wrapMode: TextEdit.Wrap
							font.family: Theme.fontFamily
							font.pixelSize: root.message.big ? 34 : Messages.textSize
							font.weight: root.kind === "poll" ? Font.DemiBold : Font.Normal
							onLinkActivated: link => Qt.openUrlExternally(link)

							HoverHandler {
								cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
							}
						}

						// the answers of a poll
						Repeater {
							model: root.message.poll?.options ?? []

							delegate: Clickable {
								id: option

								required property var modelData

								Layout.fillWidth: true
								implicitHeight: 34
								radius: Theme.radius.small
								pressedScale: 0.98
								color: Qt.alpha(Theme.text, 0.07)
								onClicked: root.vote(option.modelData.name)

								Rectangle {
									width: parent.width * Math.min(1, (option.modelData.count ?? 0) / Math.max(1, root.message.poll?.voters ?? 1))
									height: parent.height
									radius: option.radius
									color: Qt.alpha(Messages.accent, option.modelData.mine ? 0.4 : 0.2)

									Behavior on width {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 10
									anchors.rightMargin: 10
									spacing: 8

									Glyph {
										icon: option.modelData.mine ? "check_circle" : "circle_outline"
										size: 15
										color: option.modelData.mine ? Messages.accent : Theme.textSubtle
									}

									StyledText {
										Layout.fillWidth: true
										text: option.modelData.name
										elide: Text.ElideRight
										font.pixelSize: Theme.size.label
									}

									StyledText {
										text: option.modelData.count
										tone: Theme.textMuted
										font.pixelSize: Theme.size.small
										font.weight: Font.DemiBold
									}
								}
							}
						}

						StyledText {
							visible: root.message.status < 0 && (root.message.error ?? "") !== ""
							Layout.fillWidth: true
							text: root.message.error ?? ""
							tone: Theme.danger
							wrapMode: Text.Wrap
							font.pixelSize: Theme.size.tiny
						}

						RowLayout {
							id: foot

							Layout.alignment: Qt.AlignRight
							Layout.rightMargin: root.pictured ? 6 : 0
							Layout.bottomMargin: root.pictured ? 2 : 0
							spacing: 4

							StyledText {
								visible: root.message.edited ?? false
								text: "Edited"
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
							}

							Glyph {
								visible: root.message.starred ?? false
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

							WaTicks {
								visible: root.mine && root.kind !== "deleted"
								status: root.message.status
							}
						}
					}
				}

				// how people took it
				Row {
					visible: (root.message.reactions ?? []).length > 0
					anchors.right: root.mine ? parent.right : undefined
					leftPadding: 6
					rightPadding: 6
					spacing: 3

					Repeater {
						model: root.message.reactions ?? []

						delegate: Clickable {
							id: reaction

							required property var modelData

							implicitWidth: reactionLabel.implicitWidth + 16
							implicitHeight: 26
							radius: 13
							pressedScale: 0.9
							color: reaction.modelData.mine ? Messages.mine : Theme.layer2
							border.width: 1
							border.color: reaction.modelData.mine ? Qt.alpha(Messages.accent, 0.6) : Theme.outline
							onClicked: WhatsApp.act("react", root.message.id, { emoji: reaction.modelData.emoji })

							StyledText {
								id: reactionLabel

								anchors.centerIn: parent
								text: reaction.modelData.count > 1 ? `${reaction.modelData.emoji} ${reaction.modelData.count}` : reaction.modelData.emoji
								font.pixelSize: Theme.size.label
							}
						}
					}
				}
			}

			// what can be done with the message: a strip at the bubble's upper corner while the pointer is there
			Rectangle {
				id: tools

				x: Math.round(Math.max(0, Math.min(row.width - width, root.mine ? stack.x - 6 : stack.x + stack.width - width + 6)))
				y: stack.y - 16
				z: 5
				width: strip.width + 8
				height: 32
				radius: height / 2
				color: Theme.layer3
				border.width: 1
				border.color: Theme.outline
				readonly property bool shown: (hover.hovered || toolsHover.hovered) && root.kind !== "waiting"
				opacity: shown ? 1 : 0
				scale: shown ? 1 : 0.86
				transformOrigin: root.mine ? Item.BottomLeft : Item.BottomRight
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
				Behavior on width {
					SpatialAnim {
						duration: Motion.short
					}
				}

				HoverHandler {
					id: toolsHover

					onHoveredChanged: if (!hovered && !hover.hovered) root.reacting = false
				}

				component Tool: IconButton {
					implicitWidth: 26
					implicitHeight: 26
				}

				Row {
					id: strip

					anchors.centerIn: parent

					Repeater {
						model: root.reacting ? ["👍", "❤️", "😂", "😮", "😢", "🙏"] : []

						delegate: Clickable {
							id: quick

							required property string modelData

							implicitWidth: 28
							implicitHeight: 26
							radius: 13
							pressedScale: 0.85
							onClicked: {
								WhatsApp.act("react", root.message.id, { emoji: quick.modelData });
								root.reacting = false;
							}

							StyledText {
								anchors.centerIn: parent
								text: quick.modelData
								font.pixelSize: 15
							}
						}
					}

					Tool {
						visible: root.kind !== "deleted" && root.message.status >= 1
						icon: root.reacting ? "close" : "emoticon_happy_outline"
						onClicked: root.reacting = !root.reacting
					}

					Tool {
						visible: !root.reacting && root.message.status < 0
						icon: "refresh"
						onClicked: WhatsApp.act("retry", root.message.id)
					}

					Tool {
						visible: !root.reacting && root.kind !== "deleted" && root.message.status >= 1
						icon: "reply"
						onClicked: root.reply()
					}

					Tool {
						visible: !root.reacting && !root.hidden && root.message.status >= 1
						icon: "share"
						onClicked: root.forward()
					}

					Tool {
						visible: !root.reacting && !root.hidden && root.message.status >= 1
						icon: root.message.starred ? "star" : "star_outline"
						onClicked: WhatsApp.act("star", root.message.id, { value: !root.message.starred })
					}

					Tool {
						visible: !root.reacting && root.message.text !== ""
						icon: "content_copy"
						onClicked: Quickshell.execDetached(["wl-copy", "--", root.message.text])
					}

					Tool {
						visible: !root.reacting && root.media !== null && !root.hidden && root.kind !== "sticker"
						icon: "download"
						onClicked: WhatsApp.fetch(root.message.id, "save")
					}

					// a sticker is kept among one's own
					Tool {
						visible: !root.reacting && root.bare
						icon: "heart_outline"
						onClicked: WhatsApp.act("keepSticker", root.message.id)
					}

					// WhatsApp lets a message be changed for a quarter of an hour
					Tool {
						visible: !root.reacting && root.mine && root.message.status >= 1 && Date.now() / 1000 - root.message.date < 880 && (root.kind === "text" || (root.pictured && root.message.text !== ""))
						icon: "pencil"
						onClicked: root.edit()
					}

					// one's own is deleted for everyone, another's is taken out of this chat here
					Tool {
						visible: !root.reacting && root.kind !== "deleted"
						icon: "delete_outline"
						onClicked: WhatsApp.act(root.mine ? "revoke" : "remove", root.message.id)
					}
				}
			}
		}
	}
}
