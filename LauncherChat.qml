pragma ComponentBehavior: Bound

import QtQuick
import "components"

// A chat as a timeline: one vertical thread, the user's messages hung to
// its right, the model's to its left, the newest at the bottom where the
// light rests. Above it the chat's own line — where it came from, which
// model answers, the three switches — and the files waiting to be sent.
// The composer is the launcher's own query wire, above this panel.
Item {
	id: panel

	required property LauncherEngine engine
	property real reveal: 1
	property bool modelPickerOpen: false

	readonly property var chat: engine.activeChat
	readonly property string title: String(chat?.title || (engine.aiTemporaryChatEnabled ? "Temporary chat" : "New chat"))
	readonly property real threadX: Math.round(width * 0.56)
	readonly property bool hasPending: engine.aiPendingAttachments.length > 0
	readonly property int listTop: 44 + (hasPending ? 34 : 0)

	function dismissOverlay() {
		if (panel.modelPickerOpen) {
			panel.modelPickerOpen = false;
			return true;
		}
		return false;
	}

	function jumpToEnd() {
		timeline.contentY = Math.max(0, timeline.contentHeight - timeline.height);
	}

	Connections {
		target: panel.engine
		function onScrollToEnd() { panel.jumpToEnd(); }
		function onFollowNow() { panel.jumpToEnd(); }
	}

	Binding {
		target: panel.engine
		property: "chatViewNearEnd"
		value: timeline.contentY >= Math.max(0, timeline.contentHeight - timeline.height) - 36
	}

	// ----------------------------------------------------------- the line
	Band {
		reveal: panel.reveal
		order: 1
		x: 0
		y: 0
		width: parent.width
		height: 32

		FButton {
			id: back
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			icon: "go-previous-symbolic"
			text: "chats"
			kind: "ghost"
			compact: true
			iconSize: 12
			onClicked: panel.engine.openAiOverview()
		}

		FText {
			anchors.left: back.right
			anchors.leftMargin: 6
			anchors.right: switches.left
			anchors.rightMargin: 12
			anchors.verticalCenter: parent.verticalCenter
			text: panel.engine.editingMessageId !== "" ? `${panel.title} · editing` : panel.title
			font.pixelSize: Filament.textMd
			font.weight: Font.DemiBold
			color: panel.engine.editingMessageId !== "" ? Filament.charge : Filament.ink
		}

		Row {
			id: switches
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 16

			Bead {
				id: modelBead
				anchors.verticalCenter: parent.verticalCenter
				beadHeight: 22
				padding: 10
				lit: panel.modelPickerOpen
				active: panel.modelPickerOpen
				interactive: !panel.engine.aiStreaming
				onClicked: panel.modelPickerOpen = !panel.modelPickerOpen
				Row {
					spacing: 6
					FText {
						anchors.verticalCenter: parent.verticalCenter
						text: panel.engine.selectedAiModel !== "" ? panel.engine.selectedAiModel : "no model"
						mono: true
						font.pixelSize: Filament.textXs
						color: panel.engine.selectedAiModel !== "" ? Filament.inkSoft : Filament.alert
					}
					FIcon {
						anchors.verticalCenter: parent.verticalCenter
						name: "pan-down-symbolic"
						fallbacks: ["go-down-symbolic"]
						size: 10
						color: Filament.inkMute
					}
				}
			}

			FToggle {
				anchors.verticalCenter: parent.verticalCenter
				text: "Think"
				checked: panel.engine.aiThinkingEnabled
				enabled: panel.engine.selectedAiSupportsThinking && !panel.engine.aiStreaming
				onToggled: {
					panel.engine.toggleAiThinking();
					checked = Qt.binding(() => panel.engine.aiThinkingEnabled);
				}
			}

			FToggle {
				anchors.verticalCenter: parent.verticalCenter
				text: "Short"
				checked: panel.engine.aiShortResponseEnabled
				enabled: !panel.engine.aiStreaming
				onToggled: {
					panel.engine.toggleShortResponse();
					checked = Qt.binding(() => panel.engine.aiShortResponseEnabled);
				}
			}

			FToggle {
				anchors.verticalCenter: parent.verticalCenter
				text: "Temporary"
				checked: panel.engine.aiTemporaryChatEnabled
				enabled: !panel.engine.aiStreaming
				onToggled: {
					panel.engine.toggleTemporaryChat();
					checked = Qt.binding(() => panel.engine.aiTemporaryChatEnabled);
				}
			}
		}
	}

	// ------------------------------------------------- files waiting to go
	Band {
		reveal: panel.reveal
		order: 1
		x: 0
		y: 38
		width: parent.width
		height: 28
		visible: panel.hasPending

		Row {
			anchors.verticalCenter: parent.verticalCenter
			spacing: 8

			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: "attached"
				tone: "faint"
				caps: true
				font.pixelSize: Filament.textXs
			}

			Repeater {
				model: panel.engine.aiPendingAttachments
				Rectangle {
					id: pending
					required property var modelData
					readonly property bool loading: String(modelData?.status || "") === "loading"
					readonly property bool incompatible: String(modelData?.kind || "") === "image" && !panel.engine.selectedAiSupportsVision
					anchors.verticalCenter: parent.verticalCenter
					width: Math.min(220, pendingRow.implicitWidth + 16)
					height: 24
					radius: 7
					color: Filament.well
					opacity: incompatible ? 0.5 : 1

					Row {
						id: pendingRow
						anchors.left: parent.left
						anchors.leftMargin: 8
						anchors.verticalCenter: parent.verticalCenter
						spacing: 6

						Spark {
							visible: pending.loading
							anchors.verticalCenter: parent.verticalCenter
							size: 5
							breathing: true
						}
						Rectangle {
							visible: !pending.loading && pending.modelData?.kind === "image" && String(pending.modelData?.path || "") !== ""
							anchors.verticalCenter: parent.verticalCenter
							width: 16; height: 16; radius: 4
							clip: true
							color: Filament.wellDeep
							Image {
								anchors.fill: parent
								source: parent.visible ? `file://${pending.modelData.path}` : ""
								sourceSize: Qt.size(32, 32)
								fillMode: Image.PreserveAspectCrop
								asynchronous: true
							}
						}
						FIcon {
							visible: !pending.loading && !(pending.modelData?.kind === "image" && String(pending.modelData?.path || "") !== "")
							anchors.verticalCenter: parent.verticalCenter
							name: pending.modelData?.source === "primary-selection" ? "edit-select-all-symbolic" : "text-x-generic-symbolic"
							size: 11
							color: Filament.inkMute
						}
						FText {
							anchors.verticalCenter: parent.verticalCenter
							width: Math.min(implicitWidth, 150)
							text: pending.loading ? `Reading ${String(pending.modelData?.name || "")}` : String(pending.modelData?.name || "")
							tone: "soft"
							font.pixelSize: Filament.textXs
						}
						FButton {
							anchors.verticalCenter: parent.verticalCenter
							icon: "window-close-symbolic"
							iconSize: 9
							kind: "ghost"
							square: true
							compact: true
							implicitHeight: 16
							onClicked: panel.engine.removePendingAttachment(pending.modelData?.id)
						}
					}
				}
			}
		}
	}

	// ---------------------------------------------------------- the thread
	Band {
		reveal: panel.reveal
		order: 2
		x: 0
		y: panel.listTop
		width: parent.width
		height: parent.height - panel.listTop - (panel.engine.aiError !== "" ? 22 : 0)

		ListView {
			id: timeline
			anchors.fill: parent
			clip: true
			model: panel.engine.chatMessageModel
			currentIndex: count - 1
			boundsBehavior: Flickable.StopAtBounds
			highlightFollowsCurrentItem: false
			reuseItems: false
			cacheBuffer: 800
			spacing: 0
			onContentHeightChanged: panel.engine.followChatImmediately()
			onMovementStarted: panel.engine.chatAutoFollow = false
			onMovementEnded: if (panel.engine.chatViewNearEnd) panel.engine.chatAutoFollow = true

			// The timeline: one thread, the light at the newest message.
			ThreadLine {
				parent: timeline.contentItem
				x: panel.threadX - 1
				y: 0
				height: Math.max(timeline.height, timeline.contentHeight)
				litY: timeline.currentItem ? timeline.currentItem.y + 16 : -1
				litLength: 40
				z: -1
			}

			delegate: LauncherMessage {
				required property int index
				width: timeline.width
				engine: panel.engine
				threadX: panel.threadX
				thinkingShown: Boolean(panel.chat?.thinkingEnabled)
				onEditRequested: panel.engine.beginEditMessage(entry)
				onThinkingToggled: panel.engine.toggleThinkingExpanded(String(entry?.id || ""))
			}
		}

		// Nothing said yet.
		Item {
			anchors.fill: parent
			visible: timeline.count === 0

			Wire {
				vertical: true
				x: panel.threadX - 1
				y: 0
				width: 2
				height: parent.height
				cold: Filament.wireDim
				lit: 0
				glow: false
			}
			Spark {
				x: panel.threadX - 6
				y: 26
				size: 12
				breathing: true
				color: panel.engine.selectedAiModel !== "" ? Filament.charge : Filament.alert
			}
			FText {
				x: panel.threadX + 20
				y: 20
				width: parent.width - x
				text: panel.engine.selectedAiModel !== ""
					? (panel.engine.chatPrompt === "" ? "Say something" : "Enter sends")
					: "No model to talk to"
				font.pixelSize: Filament.textLg
				font.weight: Font.DemiBold
			}
			FText {
				x: panel.threadX + 20
				y: 42
				width: parent.width - x
				text: panel.engine.selectedAiModel !== ""
					? `${panel.engine.selectedAiModel} answers · Shift+Enter breaks a line · selected text is attached by itself`
					: (panel.engine.aiModelsLoading ? "Reading the models" : "Pull one with >ollama")
				tone: "mute"
				font.pixelSize: Filament.textXs
				wrapMode: Text.Wrap
			}
		}
	}

	FText {
		anchors.left: parent.left
		anchors.leftMargin: 4
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		visible: panel.engine.aiError !== ""
		text: panel.engine.aiError
		tone: "alert"
		font.pixelSize: Filament.textXs
	}

	// ------------------------------------------------------- model picker
	Item {
		anchors.fill: parent
		visible: panel.modelPickerOpen
		z: 10

		MouseArea {
			anchors.fill: parent
			onClicked: panel.modelPickerOpen = false
		}

		Rectangle {
			id: modelPlane
			x: Math.max(0, switches.x + modelBead.x - 40)
			y: 30
			width: Math.min(300, panel.width)
			height: Math.min(panel.height - 40, modelList.contentHeight + 28)
			radius: Filament.radius
			color: Filament.planeSolid
			border.width: 1
			border.color: Filament.wireDim

			Wire {
				x: 46
				y: 0
				width: 36
				height: 2
				lit: 1
				animateLit: false
				cold: "transparent"
			}

			MouseArea { anchors.fill: parent }

			ListView {
				id: modelList
				x: 20
				y: 14
				width: parent.width - 28
				height: parent.height - 28
				clip: true
				model: panel.engine.aiModels
				boundsBehavior: Flickable.StopAtBounds

				ThreadLine {
					parent: modelList.contentItem
					x: 0
					y: 0
					height: Math.max(modelList.height, modelList.contentHeight)
					litY: {
						for (let i = 0; i < panel.engine.aiModels.length; i += 1) {
							const name = String(panel.engine.aiModels[i]?.name || panel.engine.aiModels[i]?.model || "");
							if (name === panel.engine.selectedAiModel) return i * 34 + 17;
						}
						return -1;
					}
					litLength: 26
					z: -1
				}

				delegate: ThreadRow {
					id: modelRow
					required property var modelData
					required property int index
					readonly property string name: String(modelData?.name || modelData?.model || "")
					width: modelList.width
					height: 34
					inset: 14
					selected: name === panel.engine.selectedAiModel
					onClicked: {
						panel.engine.selectAiModel(modelRow.name);
						panel.modelPickerOpen = false;
					}
					Row {
						anchors.verticalCenter: parent.verticalCenter
						spacing: 8
						FText {
							anchors.verticalCenter: parent.verticalCenter
							text: modelRow.name
							mono: true
							font.pixelSize: Filament.textSm
							color: modelRow.selected ? Filament.ink : Filament.inkSoft
						}
						Spark {
							visible: panel.engine.isOllamaModelRunning(modelRow.name)
							anchors.verticalCenter: parent.verticalCenter
							size: 5
							breathing: true
						}
					}
				}

				FText {
					visible: panel.engine.aiModels.length === 0
					x: 14
					y: 8
					text: "No models installed"
					tone: "mute"
					font.pixelSize: Filament.textSm
				}
			}
		}
	}
}
