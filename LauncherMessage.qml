pragma ComponentBehavior: Bound

import QtQuick
import "components"

// One message hung from the timeline. The knot sits on the thread; a short
// stem runs out to the plane the words are on — assistant messages hang to
// the left of the thread, the user's to the right. A message still being
// written has a breathing knot; thinking is folded under a small knot of
// its own; attachments are small planes above the words.
Item {
	id: message

	required property LauncherEngine engine
	required property var entry
	property real threadX: 0
	property bool thinkingShown: false

	signal editRequested()
	signal thinkingToggled()

	readonly property bool fromUser: String(entry?.role || "") === "user"
	readonly property string modelName: !fromUser ? String(entry?.model || "") : ""
	readonly property bool streaming: Boolean(entry?.streaming)
	readonly property bool hasThinking: !fromUser && thinkingShown && String(entry?.thinking || "") !== ""
	readonly property bool loadingModel: !fromUser && streaming && String(entry?.content || "") === "" && String(entry?.thinking || "") === ""
	readonly property string displayText: String(entry?.content || "") !== ""
		? String(entry.content)
		: (loadingModel ? "" : (streaming ? "…" : ""))
	readonly property var attachments: engine.messageAttachments(entry)
	readonly property var segments: engine.markdownImageSegments(displayText)
	readonly property bool hasImages: segments.some(segment => segment.kind === "image")
	readonly property bool thinkingOpen: engine.thinkingExpanded(String(entry?.id || ""))
	readonly property real planeX: fromUser ? threadX + 18 : 0
	readonly property real planeWidth: fromUser ? width - planeX : threadX - 18

	implicitHeight: plane.height + 14
	height: implicitHeight

	// The knot on the thread.
	Rectangle {
		x: message.threadX - 4
		y: 12
		width: 8; height: 8; radius: 4
		color: message.streaming ? Filament.charge : (message.fromUser ? Filament.wireBright : Filament.planeSolid)
		border.width: 1
		border.color: message.streaming ? Filament.charge : (message.fromUser ? Filament.wireBright : Filament.wire)
		visible: !message.streaming
	}
	Spark {
		x: message.threadX - 5
		y: 11
		size: 10
		breathing: true
		visible: message.streaming
	}

	// The stem out to the plane.
	Wire {
		x: message.fromUser ? message.threadX + 4 : message.threadX - 18
		y: 15
		width: 14
		height: 2
		cold: message.streaming ? Filament.charge : Filament.wire
		lit: message.streaming ? 1 : 0
		animateLit: false
		glow: false
	}

	Rectangle {
		id: plane
		x: message.planeX
		y: 2
		width: message.planeWidth
		height: body.implicitHeight + 22
		radius: Filament.radius
		color: message.fromUser ? Qt.alpha(Filament.charge, 0.09) : Filament.planeRaised

		MouseArea {
			id: hover
			anchors.fill: parent
			hoverEnabled: true
			acceptedButtons: Qt.NoButton
		}

		Column {
			id: body
			x: 14
			y: 11
			width: parent.width - 28
			spacing: 6

			// Who: the model on the left, "you" on the right, with the edit verb.
			Item {
				width: parent.width
				height: 16
				FText {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					text: message.fromUser ? "you" : (message.modelName !== "" ? message.modelName : "assistant")
					mono: !message.fromUser
					tone: "faint"
					caps: message.fromUser
					font.pixelSize: Filament.textXs
				}
				FButton {
					visible: message.fromUser && !message.engine.aiStreaming
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					text: "edit"
					icon: "document-edit-symbolic"
					iconSize: 11
					kind: "ghost"
					compact: true
					implicitHeight: 18
					opacity: hover.containsMouse ? 1 : 0
					Behavior on opacity { NumberAnimation { duration: Filament.quick } }
					onClicked: message.editRequested()
				}
			}

			// Attachments the message carried.
			Flow {
				visible: message.attachments.length > 0
				width: parent.width
				spacing: 6
				Repeater {
					model: message.attachments
					Rectangle {
						id: chip
						required property var modelData
						readonly property bool unavailable: String(modelData?.status || "") === "unavailable"
						width: Math.min(180, chipRow.implicitWidth + 16)
						height: 22
						radius: 6
						color: Filament.well
						opacity: unavailable ? 0.55 : 1
						Row {
							id: chipRow
							anchors.centerIn: parent
							spacing: 5
							FIcon {
								anchors.verticalCenter: parent.verticalCenter
								name: chip.modelData?.kind === "image" ? "image-x-generic-symbolic"
									: (chip.modelData?.source === "primary-selection" ? "edit-select-all-symbolic" : "text-x-generic-symbolic")
								size: 11
								color: Filament.inkMute
							}
							FText {
								anchors.verticalCenter: parent.verticalCenter
								width: Math.min(implicitWidth, 150)
								text: String(chip.modelData?.name || "file")
								tone: "soft"
								font.pixelSize: Filament.textXs
							}
						}
					}
				}
			}

			// Waiting for the first token.
			Row {
				visible: message.loadingModel
				spacing: 8
				Spark {
					anchors.verticalCenter: parent.verticalCenter
					size: 5
					breathing: true
				}
				FText {
					anchors.verticalCenter: parent.verticalCenter
					text: message.modelName !== "" ? `Loading ${message.modelName}` : "Loading model"
					tone: "mute"
					font.pixelSize: Filament.textSm
				}
			}

			// Thinking, folded under its own knot.
			Item {
				visible: message.hasThinking
				width: parent.width
				height: 18
				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: message.thinkingToggled()
				}
				Rectangle {
					x: 0
					anchors.verticalCenter: parent.verticalCenter
					width: 6; height: 6; radius: 3
					color: message.thinkingOpen ? Filament.charge : Filament.wire
				}
				Wire {
					x: 6
					anchors.verticalCenter: parent.verticalCenter
					width: 10
					height: 2
					cold: Filament.wireDim
					lit: message.thinkingOpen ? 1 : 0
					glow: false
				}
				FText {
					x: 22
					anchors.verticalCenter: parent.verticalCenter
					text: message.streaming && String(message.entry?.content || "") === ""
						? "Thinking…"
						: (message.thinkingOpen ? "Thinking" : "Thinking · folded")
					tone: message.thinkingOpen ? "soft" : "mute"
					font.pixelSize: Filament.textXs
				}
			}

			TextEdit {
				id: thinkingText
				visible: message.hasThinking && message.thinkingOpen
				width: parent.width
				color: Filament.inkMute
				text: String(message.entry?.thinking || "")
				textFormat: TextEdit.MarkdownText
				baseUrl: Qt.resolvedUrl(".")
				wrapMode: TextEdit.Wrap
				readOnly: true
				selectByMouse: true
				persistentSelection: true
				selectionColor: Qt.alpha(Filament.charge, 0.35)
				selectedTextColor: Filament.ink
				font.family: Filament.fontUi
				font.pixelSize: Filament.textSm
				onLinkActivated: link => Qt.openUrlExternally(link)
				onSelectedTextChanged: message.engine.updateChatSelection(selectedText)
				HoverHandler { cursorShape: thinkingText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor }
			}

			// The words, as markdown; pictures are lifted out into frames.
			Repeater {
				model: message.displayText !== "" ? message.segments : []
				delegate: Item {
					id: segment
					required property var modelData
					width: body.width
					height: modelData.kind === "image" ? frame.height : segmentText.implicitHeight

					TextEdit {
						id: segmentText
						visible: segment.modelData.kind === "text"
						width: parent.width
						color: Filament.ink
						text: String(segment.modelData.text || "")
						textFormat: TextEdit.MarkdownText
						baseUrl: Qt.resolvedUrl(".")
						wrapMode: TextEdit.Wrap
						readOnly: true
						selectByMouse: true
						persistentSelection: true
						selectionColor: Qt.alpha(Filament.charge, 0.35)
						selectedTextColor: Filament.ink
						font.family: Filament.fontUi
						font.pixelSize: Filament.textMd
						onLinkActivated: link => Qt.openUrlExternally(link)
						onSelectedTextChanged: message.engine.updateChatSelection(selectedText)
						HoverHandler { cursorShape: segmentText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor }
					}

					Rectangle {
						id: frame
						visible: segment.modelData.kind === "image"
						width: parent.width
						height: !visible ? 0
							: (picture.status === Image.Ready && picture.sourceSize.width > 0
								? Math.min(280, Math.max(80, width * picture.sourceSize.height / picture.sourceSize.width))
								: (picture.status === Image.Error ? 64 : 96))
						radius: Filament.radiusSmall
						color: Filament.well
						clip: true

						Image {
							id: picture
							anchors.fill: parent
							anchors.margins: 4
							source: frame.visible ? message.engine.resolveMarkdownImageSource(segment.modelData.source) : ""
							fillMode: Image.PreserveAspectFit
							asynchronous: true
							cache: true
							smooth: true
							mipmap: true
						}
						FText {
							anchors.centerIn: parent
							width: parent.width - 20
							visible: picture.status === Image.Loading || picture.status === Image.Error
							text: picture.status === Image.Error ? String(segment.modelData.alt || "Image could not be loaded") : "Loading image"
							tone: "mute"
							horizontalAlignment: Text.AlignHCenter
							font.pixelSize: Filament.textXs
						}
						MouseArea {
							anchors.fill: parent
							cursorShape: Qt.PointingHandCursor
							onClicked: Qt.openUrlExternally(message.engine.resolveMarkdownImageSource(segment.modelData.source))
						}
					}
				}
			}
		}
	}
}
