pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"

// The launcher. It hangs from the wire at the centre-left of the bar, and
// it is made of two threads: the mode wire along the top edge, with the six
// mode beads strung on it and a light that slides to the one the query has
// chosen, and the query wire under it — the typed words lie on the
// filament, the caret is a spark, and the wire lights up under what has
// been typed. Below, what the mode shows: apps and verbs on a thread with
// a lantern for the chosen one, the calculator's answer, a directory, the
// saved chats, the model shelf, or a chat timeline.
//
// All of the thinking is in LauncherEngine; this file and the panels only
// draw and hand keys over.
Item {
	id: root

	property real reveal: 1
	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	property color danger: Filament.alert

	signal closeRequested()
	signal launchRequested()
	signal openStudioRequested(string page)

	readonly property alias engine: engine
	readonly property alias searchText: engine.searchText

	function reset() {
		engine.reset();
		root.takeFocus();
	}

	function takeFocus() {
		Qt.callLater(function() {
			input.cursorPosition = input.length;
			input.forceActiveFocus();
		});
	}

	function stepOut() {
		if (engine.aiAttachmentPickerOpen) { engine.closeAttachmentPicker(); return; }
		if (chatPanel.dismissOverlay()) return;
		if (engine.editingMessageId !== "") { engine.cancelMessageEdit(); return; }
		root.closeRequested();
	}

	LauncherEngine {
		id: engine
		onCloseRequested: root.closeRequested()
		onLaunchRequested: root.launchRequested()
		onOpenStudioRequested: page => root.openStudioRequested(page)
		onFocusRequested: root.takeFocus()
	}

	Component.onCompleted: root.takeFocus()

	// ------------------------------------------------------------- geometry
	readonly property int pad: 22
	readonly property int topWireY: 24
	readonly property int queryTop: 46
	readonly property int queryFont: 16
	readonly property int beadWidth: 82
	readonly property int beadGap: 8
	readonly property int queryWireY: input.y + input.height + 7
	readonly property int panelTop: queryWireY + (engine.inChatMode ? 40 : 18)
	readonly property int panelBottom: height - 18
	readonly property var modes: [
		{ id: "apps", label: "apps", icon: "system-search-symbolic", fallbacks: ["/usr/share/icons/Adwaita/symbolic/actions/system-search-symbolic.svg"] },
		{ id: "calc", label: "calc", icon: "accessories-calculator-symbolic", fallbacks: ["/usr/share/icons/Adwaita/symbolic/legacy/accessories-calculator-symbolic.svg"] },
		{ id: "files", label: "files", icon: "folder-symbolic", fallbacks: ["/usr/share/icons/Adwaita/symbolic/places/folder-symbolic.svg"] },
		{ id: "chat", label: "chat", icon: "chat-message-new-symbolic", fallbacks: ["/usr/share/icons/Adwaita/symbolic/actions/chat-message-new-symbolic.svg"] },
		{ id: "chats", label: "chats", icon: "view-list-symbolic", fallbacks: ["/usr/share/icons/Adwaita/symbolic/actions/view-list-symbolic.svg"] },
		{ id: "ollama", label: "ollama", icon: engine.ollamaIconPath, fallbacks: [] }
	]
	readonly property int modeIndex: {
		for (let i = 0; i < modes.length; i += 1) if (modes[i].id === engine.mode) return i;
		return -1;
	}
	readonly property real lightTarget: modeIndex < 0
		? pad + 6
		: pad + modeIndex * (beadWidth + beadGap) + beadWidth / 2
	property real lightX: lightTarget
	Behavior on lightX {
		NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeTravel }
	}

	readonly property string placeholder: {
		switch (engine.mode) {
		case "chat": return "Message";
		case "chats": return "Search chats";
		case "files": return "Search files";
		case "calc": return "Expression";
		case "verbs": return "Verb";
		default: return "Search apps or type >c 5+5";
		}
	}
	readonly property string hint: {
		if (engine.aiAttachmentPickerOpen) return "Enter attaches · Escape returns";
		switch (engine.mode) {
		case "chat": return engine.aiStreaming ? "answering · Escape closes" : "Enter sends · Shift+Enter new line";
		case "chats": return "Enter opens";
		case "files": return "Enter opens · Tab next mode";
		case "calc": return "Enter copies";
		case "verbs": return "Enter runs";
		case "ollama": return "Enter chats with the model";
		default: return "Enter opens · > verbs · Tab next mode";
		}
	}
	readonly property var modeIconFallbacks: {
		switch (engine.inputIconName) {
		case "document-edit-symbolic": return ["/usr/share/icons/Adwaita/symbolic/actions/document-edit-symbolic.svg"];
		case "accessories-calculator-symbolic": return ["/usr/share/icons/Adwaita/symbolic/legacy/accessories-calculator-symbolic.svg"];
		case "folder-symbolic": return ["/usr/share/icons/Adwaita/symbolic/places/folder-symbolic.svg"];
		case "chat-symbolic": return ["chat-message-new-symbolic", "/usr/share/icons/Adwaita/symbolic/actions/chat-message-new-symbolic.svg"];
		case "view-list-symbolic": return ["/usr/share/icons/Adwaita/symbolic/actions/view-list-symbolic.svg"];
		case "ollama": return [engine.ollamaIconPath];
		default: return ["/usr/share/icons/Adwaita/symbolic/actions/system-search-symbolic.svg"];
		}
	}

	// ----------------------------------------------------- the mode wire
	Band {
		reveal: root.reveal
		order: 0
		x: 0
		y: 0
		width: parent.width
		height: root.queryTop

		Wire {
			id: modeWire
			x: root.pad
			y: root.topWireY - 1
			width: parent.width - root.pad * 2
			height: 2
			cold: Filament.wireDim
			lit: root.modeIndex < 0 ? 0 : 48 / Math.max(1, width)
			litFrom: (root.lightX - root.pad - 24) / Math.max(1, width)
			animateLit: false
		}

		Spark {
			x: root.lightX - 4
			y: root.topWireY - 4
			size: 8
			breathing: root.modeIndex < 0
			visible: root.modeIndex < 0
		}

		Row {
			x: root.pad
			y: root.topWireY - Filament.beadHeight / 2
			spacing: root.beadGap
			Repeater {
				model: root.modes
				Bead {
					id: modeBead
					required property var modelData
					required property int index
					readonly property bool current: index === root.modeIndex
					width: root.beadWidth
					lit: current
					onClicked: root.engine.setMode(modeBead.modelData.id)
					Row {
						spacing: 6
						FIcon {
							anchors.verticalCenter: parent.verticalCenter
							name: modeBead.modelData.icon
							fallbacks: modeBead.modelData.fallbacks
							size: 12
							color: modeBead.current ? Filament.charge : Filament.inkMute
							Behavior on color { ColorAnimation { duration: Filament.quick } }
						}
						FText {
							anchors.verticalCenter: parent.verticalCenter
							text: modeBead.modelData.label
							font.pixelSize: Filament.textSm
							font.weight: modeBead.current ? Font.DemiBold : Font.Medium
							color: modeBead.current ? Filament.ink : Filament.inkSoft
							Behavior on color { ColorAnimation { duration: Filament.quick } }
						}
					}
				}
			}
		}

		FText {
			anchors.right: parent.right
			anchors.rightMargin: root.pad
			y: root.topWireY - 7
			text: root.hint
			tone: "faint"
			font.pixelSize: Filament.textXs
			Rectangle {
				anchors.fill: parent
				anchors.leftMargin: -8
				anchors.rightMargin: -2
				z: -1
				color: Filament.planeSolid
			}
		}
	}

	// ---------------------------------------------------- the query wire
	Band {
		reveal: root.reveal
		order: 0
		x: 0
		y: 0
		width: parent.width
		height: root.queryWireY + 4

		FIcon {
			id: modeIcon
			x: root.pad
			y: root.queryTop + 3
			name: root.engine.inputIconName === "ollama" ? root.engine.ollamaIconPath : root.engine.inputIconName
			fallbacks: root.modeIconFallbacks
			size: 16
			color: input.activeFocus ? Filament.charge : Filament.inkMute
			Behavior on color { ColorAnimation { duration: Filament.quick } }
		}

		TextEdit {
			id: input
			x: root.pad + 28
			y: root.queryTop
			width: verbsRow.x - x - 10
			height: Math.max(root.queryFont + 8, Math.min(contentHeight + 4, root.engine.inChatMode ? (root.queryFont + 8) * 4 : root.queryFont + 8))
			clip: true
			focus: true
			color: Filament.ink
			selectionColor: Qt.alpha(Filament.charge, 0.35)
			selectedTextColor: Filament.ink
			font.family: Filament.fontUi
			font.pixelSize: root.queryFont
			wrapMode: root.engine.inChatMode ? TextEdit.Wrap : TextEdit.NoWrap
			selectByMouse: true
			persistentSelection: false
			textFormat: TextEdit.PlainText
			cursorDelegate: Item {
				width: 8
				Spark {
					anchors.centerIn: parent
					size: 5
					breathing: true
					visible: input.activeFocus
				}
			}
			onTextChanged: root.engine.searchText = text
			Keys.onPressed: event => {
				if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
					if (root.engine.inChatMode && (event.modifiers & Qt.ShiftModifier)) {
						input.insert(input.cursorPosition, "\n");
						event.accepted = true;
						return;
					}
					event.accepted = true;
					if (root.engine.aiAttachmentPickerOpen) root.engine.openSelectedAttachmentEntry();
					else root.engine.activateCurrent();
					return;
				}
				if (event.key === Qt.Key_Escape) {
					event.accepted = true;
					root.stepOut();
					return;
				}
				if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
					event.accepted = true;
					if (!root.engine.aiAttachmentPickerOpen) root.engine.cycleMode(event.key === Qt.Key_Tab ? 1 : -1);
					return;
				}
				if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
					if (root.engine.mode === "chat" && !root.engine.aiAttachmentPickerOpen) return;
					event.accepted = true;
					root.engine.moveSelection(event.key === Qt.Key_Up ? -1 : 1);
					return;
				}
			}

			FText {
				x: 10
				y: 0
				height: root.queryFont + 8
				text: root.placeholder
				tone: "faint"
				font.pixelSize: root.queryFont
				visible: input.length === 0
			}
		}

		Connections {
			target: root.engine
			function onSearchTextChanged() {
				if (input.text !== root.engine.searchText) input.text = root.engine.searchText;
			}
		}

		// The verbs at the end of the wire: attach and stop for a chat, clear otherwise.
		Row {
			id: verbsRow
			anchors.right: parent.right
			anchors.rightMargin: root.pad
			y: root.queryTop - 2
			spacing: 4

			FButton {
				visible: root.engine.inChatMode && root.engine.editingMessageId !== ""
				text: "cancel edit"
				kind: "ghost"
				compact: true
				onClicked: root.engine.cancelMessageEdit()
			}
			FButton {
				visible: root.engine.inChatMode && !root.engine.aiStreaming
				icon: "mail-attachment-symbolic"
				kind: "ghost"
				square: true
				compact: true
				tooltip: root.engine.selectedAiSupportsVision ? "Attach files or images" : "Attach files"
				onClicked: root.engine.openAttachmentPicker()
			}
			FButton {
				visible: root.engine.inChatMode && root.engine.aiStreaming
				icon: "media-playback-stop-symbolic"
				text: "Stop"
				kind: "alert"
				compact: true
				iconSize: 11
				onClicked: root.engine.cancelAiStream()
			}
			FButton {
				visible: !root.engine.inChatMode && root.engine.searchText !== ""
				icon: "edit-clear-symbolic"
				kind: "ghost"
				square: true
				compact: true
				onClicked: root.engine.setLauncherSearch("")
			}
		}

		Wire {
			x: root.pad
			y: root.queryWireY
			width: parent.width - root.pad * 2
			height: 2
			cold: Filament.wireDim
			lit: input.activeFocus ? Math.min(1, Math.max(0.05, (input.contentWidth + 34) / Math.max(1, width))) : 0
		}
	}

	// ------------------------------------------ the chat's line of numbers
	Band {
		reveal: root.reveal
		order: 1
		x: root.pad
		y: root.queryWireY + 10
		width: parent.width - root.pad * 2
		height: 20
		visible: root.engine.inChatMode

		Row {
			anchors.verticalCenter: parent.verticalCenter
			spacing: 10

			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: "context"
				tone: "faint"
				caps: true
				font.pixelSize: Filament.textXs
			}
			Wire {
				anchors.verticalCenter: parent.verticalCenter
				width: 120
				height: 2
				cold: Filament.wireDim
				lit: root.engine.activeContextProgress
				hot: root.engine.activeContextProgress > 0.85 ? Filament.alert : Filament.charge
			}
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: `${root.engine.formatTokenCount(root.engine.activeContextUsed)} / ${root.engine.formatTokenCount(root.engine.activeContextLimit)}`
				mono: true
				tone: "mute"
				font.pixelSize: Filament.textXs
			}
			FText {
				anchors.verticalCenter: parent.verticalCenter
				visible: root.engine.activeResponseTokens > 0
				text: `· ${root.engine.activeTokensPerSecond.toFixed(1)} tok/s · ${root.engine.activeResponseTokens} tokens`
				mono: true
				tone: "mute"
				font.pixelSize: Filament.textXs
			}
		}

		Row {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 8
			Spark {
				anchors.verticalCenter: parent.verticalCenter
				size: 5
				breathing: root.engine.chatLoadedModel !== undefined && root.engine.chatLoadedModel !== null
				color: root.engine.chatLoadedModel ? Filament.charge : Filament.wireDim
				intensity: root.engine.chatLoadedModel ? 1 : 0.5
			}
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: root.engine.chatLoadedTimerText
				mono: true
				tone: root.engine.chatLoadedModel ? "soft" : "faint"
				font.pixelSize: Filament.textXs
			}
		}
	}

	// ------------------------------------------------------------ panels
	Item {
		id: panels
		x: root.pad
		y: root.panelTop
		width: parent.width - root.pad * 2
		height: root.panelBottom - root.panelTop

		LauncherApps {
			anchors.fill: parent
			visible: root.engine.mode === "apps" || root.engine.mode === "verbs"
			engine: root.engine
			reveal: root.reveal
		}

		// The calculator: the expression is already on the wire above; the
		// answer sits under it in the numeral face, and Enter copies it.
		Band {
			anchors.fill: parent
			visible: root.engine.mode === "calc"
			reveal: root.reveal
			order: 1

			FText {
				x: 18
				y: 8
				text: root.engine.calculatorExpression !== "" ? root.engine.calculatorExpression : "…"
				mono: true
				tone: "mute"
				font.pixelSize: Filament.textSm
			}
			FText {
				id: calcResult
				x: 18
				y: 26
				width: parent.width - 36
				text: root.engine.calculatorEvaluation.valid ? String(root.engine.calculatorEvaluation.result) : "—"
				mono: true
				font.pixelSize: 44
				font.weight: Font.DemiBold
				color: root.engine.calculatorEvaluation.valid ? Filament.ink : Filament.inkFaint
				elide: Text.ElideRight
			}
			Wire {
				x: 18
				y: 86
				width: Math.min(parent.width - 36, Math.max(80, calcResult.contentWidth + 20))
				height: 2
				cold: Filament.wireDim
				lit: root.engine.calculatorEvaluation.valid ? 1 : 0
			}
			FText {
				x: 18
				y: 98
				width: parent.width - 36
				text: root.engine.calculatorEvaluation.message
				tone: root.engine.calculatorEvaluation.valid ? "soft" : (root.engine.calculatorExpression === "" ? "mute" : "alert")
				font.pixelSize: Filament.textSm
			}
			FText {
				x: 18
				y: 120
				text: root.engine.calculatorEvaluation.valid ? "Enter copies the result" : "Numbers and + - * / % ^ ( ) · , works as the decimal point"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
			MouseArea {
				anchors.fill: parent
				enabled: root.engine.calculatorEvaluation.valid
				cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
				onClicked: root.engine.launchCommand(root.engine.calculatorCommand())
			}
		}

		Band {
			anchors.fill: parent
			visible: root.engine.mode === "files"
			reveal: root.reveal
			order: 1
			LauncherFileThread {
				anchors.fill: parent
				engine: root.engine
				directory: root.engine.fileBrowserDirectory
				entries: root.engine.filteredFileBrowserEntries
				loading: root.engine.fileBrowserDirectoryLoading
				error: root.engine.fileBrowserDirectoryError
				selectedIndex: root.engine.fileIndex
				query: root.engine.fileBrowserSearchQuery
				shortcuts: {
					const home = String(Quickshell.env("HOME") || "");
					return [
						{ label: "Home", path: home, icon: "go-home-symbolic" },
						{ label: "Downloads", path: `${home}/Downloads`, icon: "folder-download-symbolic" },
						{ label: "Documents", path: `${home}/Documents`, icon: "folder-documents-symbolic" },
						{ label: "Pictures", path: `${home}/Pictures`, icon: "folder-pictures-symbolic" }
					];
				}
				onSelected: index => root.engine.fileIndex = index
				onActivated: entry => root.engine.openFileBrowserEntry(entry)
				onDirectoryRequested: path => root.engine.fileBrowserDirectory = path
				onOpenFolderRequested: path => root.engine.openPathWithDefaultApp(path)
			}
		}

		LauncherChats {
			anchors.fill: parent
			visible: root.engine.mode === "chats"
			engine: root.engine
			reveal: root.reveal
		}

		LauncherOllama {
			anchors.fill: parent
			visible: root.engine.mode === "ollama"
			engine: root.engine
			reveal: root.reveal
		}

		LauncherChat {
			id: chatPanel
			anchors.fill: parent
			visible: root.engine.mode === "chat"
			engine: root.engine
			reveal: root.reveal
		}

		LauncherAttachmentPicker {
			anchors.fill: parent
			visible: root.engine.aiAttachmentPickerOpen && root.engine.mode === "chat"
			engine: root.engine
			z: 20
		}
	}
}
