pragma ComponentBehavior: Bound

import QtQuick
import "components"

// Apps and verbs. The results hang from one thread on the left and the
// light sits on the one Enter would open; on the right a small lantern says
// more about it — the large icon, what it is, how often it has been opened
// as a lit stretch of wire.
Item {
	id: panel

	required property LauncherEngine engine
	property real reveal: 1

	readonly property bool verbs: engine.mode === "verbs"
	readonly property var items: verbs ? engine.filteredCommands : engine.filteredApps
	readonly property int index: verbs ? engine.commandIndex : engine.appIndex
	readonly property var current: index >= 0 && index < items.length ? items[index] : null
	readonly property real maxUsage: {
		let top = 0;
		for (const entry of engine.filteredApps) top = Math.max(top, engine.appUsage(entry));
		return top;
	}
	readonly property real currentUsage: current && !verbs ? engine.appUsage(current) : 0
	readonly property int threadWidth: Math.round(width * 0.52)

	// The theme may not have a glyph for a verb; Adwaita always does.
	function verbFallbacks(id) {
		switch (String(id || "")) {
		case "studio": return ["/usr/share/icons/Adwaita/symbolic/legacy/preferences-desktop-wallpaper-symbolic.svg"];
		case "studio-motion": return ["/usr/share/icons/Adwaita/symbolic/categories/applications-graphics-symbolic.svg"];
		case "studio-dress": return ["/usr/share/icons/Adwaita/symbolic/legacy/preferences-desktop-appearance-symbolic.svg"];
		case "studio-combinations":
		case "combinations": return ["/usr/share/icons/Adwaita/symbolic/actions/bookmark-new-symbolic.svg"];
		case "style":
		case "studio-style": return ["/usr/share/icons/Adwaita/symbolic/actions/view-grid-symbolic.svg"];
		case "calculator": return ["/usr/share/icons/Adwaita/symbolic/legacy/accessories-calculator-symbolic.svg"];
		case "file-browser": return ["/usr/share/icons/Adwaita/symbolic/places/folder-symbolic.svg"];
		case "chat": return ["chat-message-new-symbolic", "/usr/share/icons/Adwaita/symbolic/actions/chat-message-new-symbolic.svg"];
		case "chats": return ["/usr/share/icons/Adwaita/symbolic/actions/view-list-symbolic.svg"];
		case "ollama": return [panel.engine.ollamaIconPath];
		}
		return ["/usr/share/icons/Adwaita/symbolic/actions/system-search-symbolic.svg"];
	}

	function select(i) {
		if (panel.verbs) panel.engine.commandIndex = i;
		else panel.engine.appIndex = i;
	}

	function activate(i) {
		panel.select(i);
		panel.engine.activateCurrent();
	}

	// ------------------------------------------------------------ the thread
	Band {
		reveal: panel.reveal
		order: 1
		x: 0
		y: 0
		width: panel.threadWidth
		height: panel.height

		ListView {
			id: list
			anchors.fill: parent
			anchors.leftMargin: 4
			clip: true
			model: panel.items
			currentIndex: panel.index
			boundsBehavior: Flickable.StopAtBounds
			highlightFollowsCurrentItem: false
			cacheBuffer: 200
			onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

			// The thread lives inside the content so it scrolls with the rows
			// and the light only moves when the selection does.
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
				readonly property bool isVerb: panel.verbs
				width: list.width
				height: 40
				inset: 16
				selected: index === panel.index
				onEntered: panel.select(index)
				onClicked: panel.activate(index)

				// The glyph: an app's icon, or a verb's symbol. A Loader so a row
				// only ever holds the one it needs — a stack of icon items with
				// empty sources stalls the scene graph.
				Loader {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					width: 20
					height: 20
					sourceComponent: row.isVerb ? verbGlyph : appGlyph
				}

				Component {
					id: appGlyph
					Image {
						width: 20
						height: 20
						sourceSize: Qt.size(40, 40)
						source: row.isVerb ? "" : panel.engine.iconSource(row.modelData)
						asynchronous: true
						smooth: true
						opacity: row.selected ? 1 : 0.85
					}
				}

				Component {
					id: verbGlyph
					FIcon {
						name: row.isVerb ? String(row.modelData?.icon || "") : ""
						fallbacks: row.isVerb ? panel.verbFallbacks(row.modelData?.id) : []
						size: 16
						color: row.selected ? Filament.charge : Filament.inkSoft
					}
				}

				Column {
					anchors.left: parent.left
					anchors.leftMargin: 30
					anchors.right: parent.right
					anchors.rightMargin: 8
					anchors.verticalCenter: parent.verticalCenter
					spacing: 1

					Row {
						width: parent.width
						spacing: 6
						FText {
							visible: row.isVerb
							text: row.isVerb ? `>${String(row.modelData?.command || "")}` : ""
							mono: true
							color: row.selected ? Filament.charge : Filament.ink
							font.pixelSize: Filament.textMd
							font.weight: Font.Medium
						}
						FText {
							width: Math.min(implicitWidth, parent.width - (row.isVerb ? 90 : 0))
							text: row.isVerb ? String(row.modelData?.name || "") : String(row.modelData?.name || row.modelData?.id || "")
							font.pixelSize: Filament.textMd
							font.weight: row.selected ? Font.DemiBold : Font.Medium
							color: row.selected ? Filament.ink : Filament.inkSoft
						}
					}
					FText {
						width: parent.width
						text: row.isVerb
							? String(row.modelData?.description || "")
							: String(row.modelData?.genericName || row.modelData?.comment || "")
						tone: "mute"
						font.pixelSize: Filament.textXs
						visible: text !== ""
					}
				}
			}
		}

		// Empty state: the thread stays, with a single cold knot and a line.
		Item {
			anchors.fill: parent
			visible: panel.items.length === 0

			Rectangle {
				x: 2
				y: 20
				width: 6; height: 6; radius: 3
				color: Filament.wireDim
			}
			FText {
				x: 20
				y: 14
				text: panel.verbs ? "No verb matches" : (panel.engine.searchText.trim() === "" ? "No applications found" : "No app matches")
				tone: "soft"
				font.pixelSize: Filament.textMd
			}
			FText {
				x: 20
				y: 34
				text: panel.verbs ? "Verbs start with > — try >c, >file, >chat" : "Type > for the verbs"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}
	}

	// ----------------------------------------------------------- the lantern
	Band {
		reveal: panel.reveal
		order: 2
		x: panel.threadWidth + 26
		y: 6
		width: panel.width - x
		height: panel.height - 6
		visible: panel.current !== null

		// The hook: where the lantern hangs from.
		Wire {
			x: 18
			y: 0
			width: 40
			height: 2
			lit: 1
			animateLit: false
			cold: "transparent"
		}
		Wire {
			vertical: true
			x: 37
			y: 0
			width: 2
			height: 14
			lit: 1
			animateLit: false
			cold: "transparent"
			glow: false
		}

		Rectangle {
			id: lantern
			x: 0
			y: 14
			width: parent.width
			height: Math.min(parent.height - 14, detail.implicitHeight + 36)
			radius: Filament.radius
			color: Filament.planeRaised

			Column {
				id: detail
				x: 20
				y: 18
				width: parent.width - 40
				spacing: 8

				Item {
					width: 56
					height: 56
					Image {
						visible: !panel.verbs
						anchors.fill: parent
						sourceSize: Qt.size(112, 112)
						source: panel.verbs || !panel.current ? "" : panel.engine.iconSource(panel.current)
						asynchronous: true
						smooth: true
					}
					FIcon {
						visible: panel.verbs
						anchors.centerIn: parent
						name: panel.verbs ? String(panel.current?.icon || "") : ""
						fallbacks: ["system-search-symbolic"]
						size: 40
						color: Filament.charge
					}
				}

				FText {
					visible: panel.verbs
					text: panel.verbs ? `>${String(panel.current?.command || "")}` : ""
					mono: true
					tone: "charge"
					font.pixelSize: Filament.textSm
				}

				FText {
					width: parent.width
					text: String(panel.current?.name || panel.current?.id || "")
					font.pixelSize: Filament.textXl
					font.weight: Font.DemiBold
					wrapMode: Text.Wrap
					maximumLineCount: 2
				}

				FText {
					width: parent.width
					visible: text !== ""
					text: panel.verbs ? "" : String(panel.current?.genericName || "")
					tone: "soft"
					font.pixelSize: Filament.textMd
				}

				FText {
					width: parent.width
					visible: text !== ""
					text: panel.verbs ? String(panel.current?.description || "") : String(panel.current?.comment || "")
					tone: "mute"
					font.pixelSize: Filament.textSm
					wrapMode: Text.Wrap
					maximumLineCount: 4
				}

				Item { width: 1; height: 4 }

				// Usage as a lit wire.
				Item {
					visible: !panel.verbs
					width: parent.width
					height: 30
					FText {
						anchors.left: parent.left
						y: 0
						text: "opened"
						tone: "faint"
						font.pixelSize: Filament.textXs
						caps: true
					}
					FText {
						anchors.right: parent.right
						y: -2
						text: panel.currentUsage > 0 ? `${panel.currentUsage} ×` : "never"
						mono: true
						tone: panel.currentUsage > 0 ? "charge" : "faint"
						font.pixelSize: Filament.textSm
					}
					Wire {
						y: 22
						width: parent.width
						height: 2
						cold: Filament.wireDim
						lit: panel.maxUsage > 0 ? panel.currentUsage / panel.maxUsage : 0
					}
				}

				FText {
					visible: !panel.verbs
					width: parent.width
					text: {
						const cmd = panel.current?.command;
						if (!cmd) return "";
						const parts = [];
						for (let i = 0; i < cmd.length; i += 1) parts.push(String(cmd[i]));
						return parts.join(" ");
					}
					mono: true
					tone: "faint"
					font.pixelSize: Filament.textXs
					elide: Text.ElideMiddle
				}

				FText {
					text: panel.verbs ? "Enter runs the verb" : "Enter opens"
					tone: "faint"
					font.pixelSize: Filament.textXs
				}
			}
		}
	}
}
