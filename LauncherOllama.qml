pragma ComponentBehavior: Bound

import QtQuick
import "components"

// The model shelf. A pull field whose wire fills as the download comes in,
// a line that says what is loaded right now, and the installed models hung
// on a thread — a running one has a breathing knot beside its name.
Item {
	id: panel

	required property LauncherEngine engine
	property real reveal: 1

	readonly property var models: engine.aiModels
	readonly property var selectedModel: engine.ollamaIndex >= 0 && engine.ollamaIndex < models.length ? models[engine.ollamaIndex] : null
	readonly property bool pullFocused: pullField.focused
	readonly property string errorText: engine.ollamaManagerError !== ""
		? engine.ollamaManagerError
		: (engine.aiModels.length === 0 ? engine.aiError : "")

	function modelName(model) {
		return String(model?.name || model?.model || "");
	}

	function modelSubtitle(model) {
		const parts = [];
		const details = model?.details || {};
		if (details.parameter_size) parts.push(String(details.parameter_size));
		if (details.quantization_level) parts.push(String(details.quantization_level));
		const size = panel.engine.formatModelSize(model?.size);
		if (size !== "") parts.push(size);
		return parts.join(" · ");
	}

	function pullStatusText() {
		const parts = [String(panel.engine.ollamaPullStatus || "")];
		if (panel.engine.ollamaPullTotal > 0) parts.push(`${Math.round(panel.engine.ollamaPullProgress * 100)}%`);
		const rate = panel.engine.formatTransferRate(panel.engine.ollamaPullSpeed);
		if (rate !== "") parts.push(rate);
		const eta = panel.engine.formatDuration(panel.engine.ollamaPullEtaSeconds);
		if (eta !== "" && panel.engine.ollamaPullProgress < 1) parts.push(`${eta} left`);
		return parts.filter(part => part !== "").join(" · ");
	}

	function leavePullField() {
		panel.engine.focusRequested();
	}

	// ---------------------------------------------------------- the pull
	Band {
		id: pullBand
		reveal: panel.reveal
		order: 1
		x: 0
		y: 0
		width: parent.width
		height: 58

		FField {
			id: pullField
			anchors.left: parent.left
			anchors.right: pullButton.left
			anchors.rightMargin: 14
			y: 0
			icon: ""
			placeholder: "Model to pull, for example qwen3:4b"
			mono: true
			showWire: false
			text: panel.engine.ollamaPullModel
			onAccepted: panel.engine.startOllamaPull(text)
			onEscaped: panel.leavePullField()
			onTextChanged: if (!panel.engine.ollamaPulling) panel.engine.ollamaPullModel = text
		}

		// The wire under the field: the typed text lights it, a pull fills it.
		Wire {
			anchors.left: pullField.left
			anchors.right: pullField.right
			y: pullField.input.y + pullField.input.height + 4
			height: 2
			cold: Filament.wireDim
			lit: panel.engine.ollamaPulling
				? Math.max(0.02, panel.engine.ollamaPullProgress)
				: (pullField.focused ? Math.min(1, Math.max(0.06, (pullField.input.contentWidth + 6) / Math.max(1, width))) : 0)
			animateLit: !panel.engine.ollamaPulling
		}

		FButton {
			id: pullButton
			anchors.right: parent.right
			y: 0
			text: panel.engine.ollamaPulling ? "Pulling" : "Pull"
			icon: panel.engine.ollamaPulling ? "" : "folder-download-symbolic"
			kind: "charge"
			enabled: !panel.engine.ollamaPulling && pullField.text.trim() !== ""
			onClicked: panel.engine.startOllamaPull(pullField.text)
		}

		FText {
			anchors.left: parent.left
			anchors.right: parent.right
			y: 40
			visible: panel.engine.ollamaPulling
			text: panel.pullStatusText()
			mono: true
			tone: "charge"
			font.pixelSize: Filament.textXs
		}

		FText {
			anchors.left: parent.left
			y: 40
			visible: !panel.engine.ollamaPulling
			text: panel.engine.ollamaVersion !== "" ? `ollama ${panel.engine.ollamaVersion}` : "ollama"
			mono: true
			tone: "faint"
			font.pixelSize: Filament.textXs
		}
	}

	// -------------------------------------------------------- the running
	Band {
		reveal: panel.reveal
		order: 2
		x: 0
		y: 70
		width: parent.width
		height: 26

		Spark {
			x: 2
			y: 10
			size: 6
			breathing: panel.engine.ollamaRunningModels.length > 0
			color: panel.engine.ollamaRunningModels.length > 0 ? Filament.charge : Filament.wireDim
			intensity: panel.engine.ollamaRunningModels.length > 0 ? 1 : 0.5
		}

		FText {
			x: 18
			anchors.verticalCenter: parent.verticalCenter
			text: "loaded"
			tone: "faint"
			caps: true
			font.pixelSize: Filament.textXs
		}

		FText {
			x: 78
			anchors.verticalCenter: parent.verticalCenter
			width: parent.width - 78 - 40
			text: panel.engine.ollamaRunningSummary()
			mono: true
			tone: panel.engine.ollamaRunningModels.length > 0 ? "ink" : "mute"
			font.pixelSize: Filament.textSm
		}

		FButton {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			icon: "view-refresh-symbolic"
			kind: "ghost"
			square: true
			compact: true
			tooltip: "Refresh models"
			onClicked: panel.engine.refreshOllamaOverview()
		}
	}

	// ------------------------------------------------------ the installed
	Band {
		reveal: panel.reveal
		order: 3
		x: 0
		y: 108
		width: parent.width
		height: parent.height - 108 - (panel.errorText !== "" ? 22 : 0)

		FText {
			x: 18
			y: 0
			text: `installed · ${panel.models.length}`
			tone: "faint"
			caps: true
			font.pixelSize: Filament.textXs
		}

		ListView {
			id: list
			x: 4
			y: 22
			width: parent.width - 4
			height: parent.height - 22
			clip: true
			model: panel.models
			currentIndex: panel.engine.ollamaIndex
			boundsBehavior: Flickable.StopAtBounds
			highlightFollowsCurrentItem: false
			onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

			ThreadLine {
				parent: list.contentItem
				x: 0
				y: 0
				height: Math.max(list.height, list.contentHeight)
				litY: list.currentItem ? list.currentItem.y + list.currentItem.height / 2 : -1
				litLength: 30
				z: -1
			}

			delegate: ThreadRow {
				id: row
				required property var modelData
				required property int index
				readonly property string name: panel.modelName(modelData)
				readonly property bool running: panel.engine.isOllamaModelRunning(name)
				readonly property bool removing: panel.engine.ollamaRemovingModel === name
				readonly property bool isSelected: name === panel.engine.selectedAiModel
				width: list.width
				height: 46
				inset: 16
				selected: index === panel.engine.ollamaIndex
				onEntered: panel.engine.ollamaIndex = index
				onClicked: panel.engine.ollamaIndex = index
				onDoubleClicked: panel.engine.startNewChatWithModel(row.name)

				Column {
					anchors.left: parent.left
					anchors.right: verbs.left
					anchors.rightMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					spacing: 2

					Row {
						spacing: 8
						FText {
							text: row.name
							mono: true
							font.pixelSize: Filament.textMd
							font.weight: row.selected ? Font.DemiBold : Font.Medium
							color: row.selected ? Filament.ink : Filament.inkSoft
						}
						Spark {
							visible: row.running
							anchors.verticalCenter: parent.verticalCenter
							size: 5
							breathing: true
						}
						Chip {
							visible: row.running
							anchors.verticalCenter: parent.verticalCenter
							text: "running"
							lit: true
							mono: false
						}
						Chip {
							visible: row.isSelected && !row.running
							anchors.verticalCenter: parent.verticalCenter
							text: "chat model"
							mono: false
						}
					}

					FText {
						text: panel.modelSubtitle(row.modelData)
						tone: "mute"
						mono: true
						font.pixelSize: Filament.textXs
					}
				}

				Row {
					id: verbs
					anchors.right: parent.right
					anchors.rightMargin: 6
					anchors.verticalCenter: parent.verticalCenter
					spacing: 8
					opacity: row.selected || row.hovered || row.removing ? 1 : 0
					Behavior on opacity { NumberAnimation { duration: Filament.quick } }

					FText {
						visible: row.removing
						anchors.verticalCenter: parent.verticalCenter
						text: "removing"
						tone: "alert"
						font.pixelSize: Filament.textXs
					}

					FButton {
						visible: !row.removing
						anchors.verticalCenter: parent.verticalCenter
						text: "Chat"
						icon: "chat-message-new-symbolic"
						iconSize: 12
						compact: true
						enabled: !panel.engine.aiStreaming
						onClicked: panel.engine.startNewChatWithModel(row.name)
					}

					HoldButton {
						visible: !row.removing
						anchors.verticalCenter: parent.verticalCenter
						text: "Remove"
						icon: "edit-delete-symbolic"
						enabled: !panel.engine.aiStreaming && panel.engine.ollamaRemovingModel === ""
						implicitHeight: 28
						onHeld: panel.engine.removeOllamaModel(row.name)
					}
				}
			}
		}

		// No models, or still reading them.
		Item {
			x: 4
			y: 22
			width: parent.width - 4
			height: 48
			visible: panel.models.length === 0

			Spark {
				x: -2
				y: 17
				size: 6
				breathing: panel.engine.aiModelsLoading
				color: panel.engine.aiModelsLoading ? Filament.charge : Filament.wireDim
				intensity: panel.engine.aiModelsLoading ? 1 : 0.5
			}
			FText {
				x: 20
				y: 6
				text: panel.engine.aiModelsLoading ? "Reading the models" : "No models installed"
				tone: "soft"
				font.pixelSize: Filament.textMd
			}
			FText {
				x: 20
				y: 26
				text: panel.engine.aiModelsLoading ? "" : "Pull one above — the wire fills as it comes in"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}
	}

	FText {
		anchors.left: parent.left
		anchors.leftMargin: 18
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		visible: panel.errorText !== ""
		text: panel.errorText
		tone: "alert"
		font.pixelSize: Filament.textXs
	}
}
