pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"

// Studio's dress page: the icon set the desktop wears, and the pointer.
//
// Both show the real thing - icons drawn from the theme's own files strung as
// beads on a thread, and a pointer decoded out of the cursor theme's own
// left_ptr - because a list of theme names tells you nothing about what you
// are choosing. The pointer size is a spark on a short wire with five knots.
//
// `scripts/appearance_themes.py` does the finding and the applying. Applying
// means GSettings, GTK 3 and 4, Qt's own config, the Xcursor default, and
// niri's cursor block, all at once. Tab moves the keyboard between the icon
// thread and the pointer row. See STUDIO.md.
FocusScope {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	property real reveal: 1

	property var iconThemes: []
	property var cursorThemes: []
	property int iconIndex: 0
	property int cursorIndex: 0
	property string column: "icons"          // which list the keyboard is in
	property string liveIcon: ""
	property string liveCursor: ""
	property int liveCursorSize: 24
	property bool loading: false

	readonly property string scriptPath: `${Quickshell.shellDir}/scripts/appearance_themes.py`
	readonly property var sizes: [16, 24, 32, 48, 64]

	readonly property var currentIcon: root.iconThemes.length > 0
		? root.iconThemes[Math.max(0, Math.min(root.iconThemes.length - 1, root.iconIndex))]
		: null
	readonly property var currentCursor: root.cursorThemes.length > 0
		? root.cursorThemes[Math.max(0, Math.min(root.cursorThemes.length - 1, root.cursorIndex))]
		: null

	readonly property bool dressed: root.currentIcon
		&& root.currentCursor
		&& String(root.currentIcon.id) === root.liveIcon
		&& String(root.currentCursor.id) === root.liveCursor

	focus: true

	function reset() {
		root.loading = true;
		listProcess.running = true;
		currentProcess.running = true;
		Qt.callLater(function () {
			root.forceActiveFocus();
		});
	}

	function selectByIds(iconId, cursorId) {
		for (let i = 0; i < root.iconThemes.length; i += 1) {
			if (String(root.iconThemes[i].id) === iconId) {
				root.iconIndex = i;
				break;
			}
		}
		for (let i = 0; i < root.cursorThemes.length; i += 1) {
			if (String(root.cursorThemes[i].id) === cursorId) {
				root.cursorIndex = i;
				break;
			}
		}
		Qt.callLater(function () { iconList.positionViewAtIndex(root.iconIndex, ListView.Center); });
	}

	function move(delta) {
		if (root.column === "icons") {
			if (root.iconThemes.length === 0) return;
			root.iconIndex = Math.max(0, Math.min(root.iconThemes.length - 1, root.iconIndex + delta));
			iconList.positionViewAtIndex(root.iconIndex, ListView.Contain);
		} else {
			if (root.cursorThemes.length === 0) return;
			root.cursorIndex = Math.max(0, Math.min(root.cursorThemes.length - 1, root.cursorIndex + delta));
		}
	}

	function apply() {
		if (!root.currentIcon && !root.currentCursor) return;
		const command = ["python3", root.scriptPath, "apply"];
		if (root.currentIcon) command.push("--icon", String(root.currentIcon.id));
		if (root.currentCursor) {
			command.push("--cursor", String(root.currentCursor.id));
			command.push("--cursor-size", String(root.liveCursorSize));
		}
		Quickshell.execDetached(command);
		root.liveIcon = root.currentIcon ? String(root.currentIcon.id) : root.liveIcon;
		root.liveCursor = root.currentCursor ? String(root.currentCursor.id) : root.liveCursor;
	}

	Component.onCompleted: root.reset()
	Keys.onEscapePressed: root.closeRequested()
	Keys.onReturnPressed: root.apply()
	Keys.onEnterPressed: root.apply()
	Keys.onLeftPressed: root.move(-1)
	Keys.onRightPressed: root.move(1)
	Keys.onUpPressed: root.move(-1)
	Keys.onDownPressed: root.move(1)
	Keys.onTabPressed: root.column = root.column === "icons" ? "cursors" : "icons"

	Process {
		id: listProcess
		command: ["python3", root.scriptPath, "list"]

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const parsed = JSON.parse(String(text || "{}"));
					root.iconThemes = parsed.icons || [];
					root.cursorThemes = parsed.cursors || [];
					root.selectByIds(root.liveIcon, root.liveCursor);
				} catch (error) {
					root.iconThemes = [];
					root.cursorThemes = [];
				}
				root.loading = false;
			}
		}
	}

	Process {
		id: currentProcess
		command: ["python3", root.scriptPath, "current"]

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const parsed = JSON.parse(String(text || "{}"));
					root.liveIcon = String(parsed.icon || "");
					root.liveCursor = String(parsed.cursor || "");
					root.liveCursorSize = Number(parsed.cursorSize || 24);
					root.selectByIds(root.liveIcon, root.liveCursor);
				} catch (error) {
					// leave what we had
				}
			}
		}
	}

	readonly property real pointerWidth: Math.max(340, Math.min(width * 0.36, 440))

	// ------------------------------------------------------------ the head
	Band {
		id: head
		reveal: root.reveal
		order: 0
		width: parent.width
		height: 36

		FText {
			anchors.left: parent.left
			anchors.right: wearButton.left
			anchors.rightMargin: 20
			anchors.verticalCenter: parent.verticalCenter
			text: root.loading
				? "Reading the icon and cursor themes on this machine…"
				: `Worn now: ${root.liveIcon || "-"} · pointer ${root.liveCursor || "-"} at ${root.liveCursorSize} px`
			tone: "soft"
			font.pixelSize: Filament.textSm
		}

		FButton {
			id: wearButton
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			kind: "charge"
			text: root.loading ? "Looking…" : (root.dressed ? "Already worn" : "Wear these")
			enabled: !root.loading && !root.dressed
			onClicked: {
				root.forceActiveFocus();
				root.apply();
			}
		}
	}

	// ------------------------------------------------------- the icon thread
	Band {
		id: iconsBand
		reveal: root.reveal
		order: 1
		anchors.top: head.bottom
		anchors.topMargin: 16
		anchors.bottom: parent.bottom
		width: parent.width - root.pointerWidth - 48
		implicitHeight: 0

		readonly property real rowHeight: 56
		readonly property bool active: root.column === "icons"

		Row {
			x: 20; y: 0
			spacing: 8
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: "icons"
				caps: true
				tone: iconsBand.active ? "charge" : "mute"
				font.pixelSize: Filament.textXs
				Behavior on color { ColorAnimation { duration: Filament.quick } }
			}
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: iconsBand.active ? "arrows move · Tab to the pointer" : "Tab to come back here"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}

		ThreadLine {
			id: iconThread
			x: 8
			y: 28
			height: parent.height - 28
			litY: root.iconThemes.length > 0
				? root.iconIndex * iconsBand.rowHeight + iconsBand.rowHeight / 2 - iconList.contentY
				: -1
			litLength: iconsBand.rowHeight
			opacity: iconsBand.active ? 1 : 0.5
			Behavior on opacity { NumberAnimation { duration: Filament.quick } }
		}

		ListView {
			id: iconList
			x: 9
			y: 28
			width: parent.width - 9
			height: parent.height - 28
			clip: true
			model: root.iconThemes
			currentIndex: root.iconIndex
			boundsBehavior: Flickable.StopAtBounds
			reuseItems: true
			cacheBuffer: iconsBand.rowHeight * 4

			delegate: ThreadRow {
				id: row
				required property var modelData
				required property int index
				readonly property bool live: String(row.modelData?.id ?? "") === root.liveIcon
				width: iconList.width
				height: iconsBand.rowHeight
				selected: root.iconIndex === row.index
				dim: !iconsBand.active && !selected
				onClicked: {
					root.forceActiveFocus();
					root.column = "icons";
					root.iconIndex = row.index;
				}
				onDoubleClicked: root.apply()

				// The samples: real icons from the theme, strung as beads.
				Row {
					id: samples
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					spacing: 6
					Repeater {
						model: (row.modelData?.samples ?? []).slice(0, 4)
						Bead {
							required property var modelData
							interactive: false
							padding: 6
							beadHeight: 34
							lit: row.selected
							outlined: true
							Image {
								width: 22; height: 22
								source: "file://" + String(modelData)
								sourceSize: Qt.size(44, 44)
								asynchronous: true
								cache: true
								fillMode: Image.PreserveAspectFit
							}
						}
					}
				}

				Column {
					anchors.left: samples.right
					anchors.leftMargin: 18
					anchors.right: wornChip.left
					anchors.rightMargin: 12
					anchors.verticalCenter: parent.verticalCenter
					spacing: 2
					FText {
						width: parent.width
						text: row.modelData?.name || row.modelData?.id || ""
						tone: row.selected ? "ink" : "soft"
						font.pixelSize: Filament.textMd
						font.weight: row.selected ? Font.DemiBold : Font.Medium
					}
					FText {
						width: parent.width
						text: String(row.modelData?.comment || row.modelData?.id || "")
						tone: "faint"
						font.pixelSize: Filament.textXs
					}
				}

				Chip {
					id: wornChip
					anchors.right: parent.right
					anchors.rightMargin: 12
					anchors.verticalCenter: parent.verticalCenter
					visible: row.live
					text: "worn"
					lit: true
					mono: false
				}
			}
		}

		FText {
			anchors.centerIn: parent
			visible: root.iconThemes.length === 0
			text: root.loading ? "Looking for icon themes…" : "No icon themes found"
			tone: "faint"
			font.pixelSize: Filament.textSm
		}
	}

	// ----------------------------------------------------------- the pointer
	Band {
		id: pointerBand
		reveal: root.reveal
		order: 2
		anchors.top: head.bottom
		anchors.topMargin: 16
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		width: root.pointerWidth
		implicitHeight: 0

		readonly property bool active: root.column === "cursors"

		Wire {
			vertical: true
			x: -24
			y: 0
			height: parent.height
			width: 2
			cold: Filament.wireDim
			glow: false
		}

		Row {
			x: 0; y: 0
			spacing: 8
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: "pointer"
				caps: true
				tone: pointerBand.active ? "charge" : "mute"
				font.pixelSize: Filament.textXs
				Behavior on color { ColorAnimation { duration: Filament.quick } }
			}
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: pointerBand.active ? "arrows move · Tab to the icons" : "Tab to come here"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}

		// The cursor themes: beads with the real left_ptr on them.
		Flow {
			id: cursorFlow
			x: 0
			y: 30
			width: parent.width
			spacing: 10

			Repeater {
				model: root.cursorThemes
				Bead {
					id: cursorBead
					required property var modelData
					required property int index
					readonly property bool chosen: root.cursorIndex === cursorBead.index
					readonly property bool live: String(cursorBead.modelData?.id ?? "") === root.liveCursor
					beadHeight: 40
					padding: 10
					lit: chosen
					active: chosen && pointerBand.active
					onClicked: {
						root.forceActiveFocus();
						root.column = "cursors";
						root.cursorIndex = cursorBead.index;
					}
					Row {
						spacing: 9
						Image {
							anchors.verticalCenter: parent.verticalCenter
							width: 26; height: 26
							source: String(cursorBead.modelData?.preview || "") !== "" ? "file://" + String(cursorBead.modelData.preview) : ""
							sourceSize: Qt.size(64, 64)
							asynchronous: true
							cache: true
							fillMode: Image.PreserveAspectFit
						}
						FText {
							anchors.verticalCenter: parent.verticalCenter
							text: cursorBead.modelData?.name || cursorBead.modelData?.id || ""
							tone: cursorBead.chosen ? "ink" : "soft"
							font.pixelSize: Filament.textSm
							font.weight: cursorBead.chosen ? Font.DemiBold : Font.Medium
						}
						Chip {
							anchors.verticalCenter: parent.verticalCenter
							visible: cursorBead.live
							text: "worn"
							lit: true
							mono: false
						}
					}
				}
			}
		}

		FText {
			x: 0; y: 34
			visible: root.cursorThemes.length === 0
			text: root.loading ? "Looking for cursor themes…" : "No cursor themes found"
			tone: "faint"
			font.pixelSize: Filament.textSm
		}

		// The size: a short wire with five knots and the spark on the one worn.
		Item {
			id: sizeRow
			x: 0
			anchors.top: cursorFlow.bottom
			anchors.topMargin: 36
			width: parent.width
			height: 70

			readonly property real inset: 14
			readonly property int sizeIndex: Math.max(0, root.sizes.indexOf(root.liveCursorSize))
			function knotX(index) { return Math.round(sizeRow.inset + (sizeRow.width - sizeRow.inset * 2) * index / (root.sizes.length - 1)); }

			FText { x: 0; y: 0; text: "size"; caps: true; tone: "mute"; font.pixelSize: Filament.textXs }
			FText { anchors.right: parent.right; y: 0; text: `${root.liveCursorSize} px`; mono: true; tone: "charge"; font.pixelSize: Filament.textSm }

			Wire {
				id: sizeWire
				x: 0
				y: 36
				width: parent.width
				height: 2
				cold: Filament.wireDim
				animateLit: false
				lit: sizeSpark.x / Math.max(1, width)
			}

			Repeater {
				model: root.sizes
				Item {
					id: sizeKnot
					required property int modelData
					required property int index
					readonly property bool on: root.liveCursorSize === sizeKnot.modelData
					x: sizeRow.knotX(index) - 16
					y: 22
					width: 32
					height: 44
					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							root.forceActiveFocus();
							root.liveCursorSize = sizeKnot.modelData;
						}
					}
					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						y: 15 - height / 2
						width: 4 + sizeKnot.index * 1.5
						height: width
						radius: width / 2
						color: sizeKnot.on ? Filament.charge : Filament.wireBright
					}
					FText {
						anchors.horizontalCenter: parent.horizontalCenter
						y: 26
						text: String(sizeKnot.modelData)
						mono: true
						tone: sizeKnot.on ? "ink" : "faint"
						font.pixelSize: Filament.textXs
					}
				}
			}

			Spark {
				id: sizeSpark
				x: sizeRow.knotX(sizeRow.sizeIndex) - size / 2 + 1
				y: 37 - size / 2
				size: 9
				breathing: true
				Behavior on x { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.1 } }
			}
		}

		// What the pointer will look like at that size.
		Item {
			anchors.top: sizeRow.bottom
			anchors.topMargin: 18
			width: parent.width
			height: 96
			visible: !!root.currentCursor && String(root.currentCursor.preview || "") !== ""
			Image {
				x: 0
				y: 0
				width: root.liveCursorSize
				height: root.liveCursorSize
				source: root.currentCursor && String(root.currentCursor.preview || "") !== "" ? "file://" + String(root.currentCursor.preview) : ""
				sourceSize: Qt.size(96, 96)
				asynchronous: true
				fillMode: Image.PreserveAspectFit
				Behavior on width { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.1 } }
				Behavior on height { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.1 } }
			}
			FText {
				x: 80; y: 0
				width: parent.width - 80
				text: (root.currentCursor?.name || root.currentCursor?.id || "") + (root.currentCursor?.comment ? "\n" + root.currentCursor.comment : "")
				tone: "soft"
				font.pixelSize: Filament.textSm
				wrapMode: Text.WordWrap
				maximumLineCount: 3
			}
		}
	}
}
