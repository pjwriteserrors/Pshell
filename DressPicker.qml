pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"

// Studio's dress page: the icon set the desktop wears, and the pointer.
//
// Both lists show the real thing — icons drawn from the theme's own files, and
// a pointer decoded out of the cursor theme's own left_ptr — because a list of
// theme names tells you nothing about what you are choosing.
//
// `scripts/appearance_themes.py` does the finding and the applying. Applying
// means GSettings, GTK 3 and 4, Qt's own config, the Xcursor default, and
// niri's cursor block, all at once: a cursor set in only one of those places
// leaves half the session on the old one, which reads as "it did not work".
//
// If you are writing a new style: keep this page and keep it calling that
// script. Draw the lists however your style draws lists.
Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor

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
	}

	function move(delta) {
		if (root.column === "icons") {
			if (root.iconThemes.length === 0) return;
			root.iconIndex = Math.max(0, Math.min(root.iconThemes.length - 1, root.iconIndex + delta));
			iconList.positionViewAtIndex(root.iconIndex, ListView.Contain);
		} else {
			if (root.cursorThemes.length === 0) return;
			root.cursorIndex = Math.max(0, Math.min(root.cursorThemes.length - 1, root.cursorIndex + delta));
			cursorList.positionViewAtIndex(root.cursorIndex, ListView.Contain);
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
	Keys.onUpPressed: root.move(-1)
	Keys.onDownPressed: root.move(1)
	Keys.onLeftPressed: root.column = "icons"
	Keys.onRightPressed: root.column = "cursors"
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

	// ------------------------------------------------------------- icon index
	BioText {
		id: iconHeading
		anchors.left: parent.left
		anchors.top: parent.top
		role: "label"
		tone: root.column === "icons" ? "organ" : "muted"
		text: "Marks"
	}

	ListView {
		id: iconList

		anchors.left: parent.left
		anchors.top: iconHeading.bottom
		anchors.topMargin: Bio.s3
		anchors.bottom: parent.bottom
		width: Math.round(Math.min(parent.width * 0.30, 320))
		clip: true
		model: root.iconThemes
		currentIndex: root.iconIndex
		boundsBehavior: Flickable.StopAtBounds

		delegate: Item {
			id: iconRow

			required property var modelData
			required property int index

			readonly property bool selected: root.iconIndex === iconRow.index && root.column === "icons"
			readonly property bool marked: root.iconIndex === iconRow.index
			readonly property bool live: String(iconRow.modelData.id) === root.liveIcon

			width: iconList.width
			height: 40

			Rectangle {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				width: Bio.rib * 1.6
				height: parent.height * (iconRow.marked ? 0.6 : 0)
				radius: width / 2
				color: iconRow.selected ? Bio.organ : Bio.boneDim
				opacity: iconRow.marked ? 1 : 0

				Behavior on height {
					NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
				}
			}

			BioText {
				id: iconName
				anchors.left: parent.left
				anchors.leftMargin: Bio.s4
				anchors.right: iconStrip.left
				anchors.rightMargin: Bio.s3
				anchors.verticalCenter: parent.verticalCenter
				role: "heading"
				font.pixelSize: 13
				tone: iconRow.marked ? "default" : "muted"
				text: String(iconRow.modelData.name || iconRow.modelData.id)
			}

			// The theme, in its own hand.
			Row {
				id: iconStrip
				anchors.right: liveDot.visible ? liveDot.left : parent.right
				anchors.rightMargin: Bio.s3
				anchors.verticalCenter: parent.verticalCenter
				spacing: 3

				Repeater {
					model: (iconRow.modelData.samples || []).slice(0, 3)

					delegate: Image {
						required property string modelData
						width: 18
						height: 18
						source: `file://${modelData}`
						sourceSize: Qt.size(36, 36)
						fillMode: Image.PreserveAspectFit
						smooth: true
						mipmap: true
						asynchronous: true
					}
				}
			}

			Rectangle {
				id: liveDot
				visible: iconRow.live
				anchors.right: parent.right
				anchors.rightMargin: Bio.s4
				anchors.verticalCenter: parent.verticalCenter
				width: Bio.nodule * 2
				height: Bio.nodule * 2
				radius: width / 2
				color: Bio.vital
			}

			BioTouch {
				onEntered: {
					root.column = "icons";
					root.iconIndex = iconRow.index;
				}
				onClicked: {
					root.column = "icons";
					root.iconIndex = iconRow.index;
				}
				onDoubleClicked: root.apply()
			}
		}
	}

	// ----------------------------------------------------------- cursor index
	BioText {
		id: cursorHeading
		anchors.left: cursorList.left
		anchors.top: parent.top
		role: "label"
		tone: root.column === "cursors" ? "organ" : "muted"
		text: "Pointer"
	}

	ListView {
		id: cursorList

		anchors.left: iconList.right
		anchors.leftMargin: Bio.s6
		anchors.top: iconHeading.bottom
		anchors.topMargin: Bio.s3
		anchors.bottom: parent.bottom
		width: Math.round(Math.min(parent.width * 0.22, 240))
		clip: true
		model: root.cursorThemes
		currentIndex: root.cursorIndex
		boundsBehavior: Flickable.StopAtBounds

		delegate: Item {
			id: cursorRow

			required property var modelData
			required property int index

			readonly property bool selected: root.cursorIndex === cursorRow.index && root.column === "cursors"
			readonly property bool marked: root.cursorIndex === cursorRow.index
			readonly property bool live: String(cursorRow.modelData.id) === root.liveCursor

			width: cursorList.width
			height: 40

			Rectangle {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				width: Bio.rib * 1.6
				height: parent.height * (cursorRow.marked ? 0.6 : 0)
				radius: width / 2
				color: cursorRow.selected ? Bio.organ : Bio.boneDim
				opacity: cursorRow.marked ? 1 : 0

				Behavior on height {
					NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
				}
			}

			Image {
				id: pointerMark
				anchors.left: parent.left
				anchors.leftMargin: Bio.s4
				anchors.verticalCenter: parent.verticalCenter
				width: 18
				height: 18
				source: String(cursorRow.modelData.preview || "") === ""
					? ""
					: `file://${cursorRow.modelData.preview}`
				sourceSize: Qt.size(48, 48)
				fillMode: Image.PreserveAspectFit
				smooth: true
				asynchronous: true
			}

			BioText {
				anchors.left: pointerMark.right
				anchors.leftMargin: Bio.s3
				anchors.right: cursorLiveDot.visible ? cursorLiveDot.left : parent.right
				anchors.rightMargin: Bio.s3
				anchors.verticalCenter: parent.verticalCenter
				role: "heading"
				font.pixelSize: 13
				tone: cursorRow.marked ? "default" : "muted"
				text: String(cursorRow.modelData.name || cursorRow.modelData.id)
			}

			Rectangle {
				id: cursorLiveDot
				visible: cursorRow.live
				anchors.right: parent.right
				anchors.rightMargin: Bio.s4
				anchors.verticalCenter: parent.verticalCenter
				width: Bio.nodule * 2
				height: Bio.nodule * 2
				radius: width / 2
				color: Bio.vital
			}

			BioTouch {
				onEntered: {
					root.column = "cursors";
					root.cursorIndex = cursorRow.index;
				}
				onClicked: {
					root.column = "cursors";
					root.cursorIndex = cursorRow.index;
				}
				onDoubleClicked: root.apply()
			}
		}
	}

	Rectangle {
		id: dressBone
		anchors.left: cursorList.right
		anchors.leftMargin: Bio.s6
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.topMargin: Bio.s3
		anchors.bottomMargin: Bio.s3
		width: Bio.ribThin
		color: Bio.boneGhost
	}

	// --------------------------------------------------------- what is chosen
	Item {
		id: specimen

		anchors.left: dressBone.right
		anchors.leftMargin: Bio.s7
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom

		BioText {
			id: specimenName
			anchors.left: parent.left
			anchors.top: parent.top
			role: "specimen"
			font.pixelSize: 26
			text: root.currentIcon ? String(root.currentIcon.name || root.currentIcon.id) : ""
		}

		BioText {
			id: specimenComment
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: specimenName.bottom
			anchors.topMargin: Bio.s2
			role: "body"
			tone: "muted"
			wrapMode: Text.WordWrap
			maximumLineCount: 2
			text: root.currentIcon ? String(root.currentIcon.comment || "") : ""
		}

		// Six marks at the size a person actually sees them.
		Grid {
			id: sampleGrid
			anchors.left: parent.left
			anchors.top: specimenComment.bottom
			anchors.topMargin: Bio.s6
			columns: 3
			columnSpacing: Bio.s6
			rowSpacing: Bio.s5

			Repeater {
				model: root.currentIcon ? (root.currentIcon.samples || []) : []

				delegate: Image {
					required property string modelData
					width: 56
					height: 56
					source: `file://${modelData}`
					sourceSize: Qt.size(112, 112)
					fillMode: Image.PreserveAspectFit
					smooth: true
					mipmap: true
					asynchronous: true
				}
			}
		}

		BioTendon {
			id: specimenRule
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: sampleGrid.bottom
			anchors.topMargin: Bio.s6
			height: 12
			facing: Qt.LeftToRight
			lineColor: Bio.boneFaint
		}

		// The pointer, at the size it will be drawn.
		Item {
			id: pointerBlock
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: specimenRule.bottom
			anchors.topMargin: Bio.s5
			height: 72

			Image {
				id: pointerLarge
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				width: Math.max(32, root.liveCursorSize)
				height: width
				source: root.currentCursor && String(root.currentCursor.preview || "") !== ""
					? `file://${root.currentCursor.preview}`
					: ""
				sourceSize: Qt.size(128, 128)
				fillMode: Image.PreserveAspectFit
				smooth: true
				asynchronous: true
			}

			Column {
				anchors.left: pointerLarge.right
				anchors.leftMargin: Bio.s5
				anchors.verticalCenter: parent.verticalCenter
				spacing: -1

				BioText {
					role: "heading"
					font.pixelSize: 15
					text: root.currentCursor ? String(root.currentCursor.name || root.currentCursor.id) : ""
				}

				BioText {
					role: "caption"
					tone: "faint"
					text: `${root.liveCursorSize} px`
				}
			}
		}

		// How big the pointer is drawn — the one number on this page.
		Item {
			id: sizeBlock
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: pointerBlock.bottom
			anchors.topMargin: Bio.s3
			height: 30

			BioText {
				id: sizeLabel
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				role: "label"
				tone: "muted"
				text: "Size"
			}

			Row {
				anchors.left: sizeLabel.right
				anchors.leftMargin: Bio.s5
				anchors.verticalCenter: parent.verticalCenter
				spacing: Bio.s4

				Repeater {
					model: [16, 24, 32, 48, 64]

					delegate: BioText {
						required property int modelData
						role: "mono"
						font.pixelSize: 12
						tone: root.liveCursorSize === modelData ? "organ" : "faint"
						text: String(modelData)

						BioTouch {
							anchors.margins: -Bio.s2
							onClicked: root.liveCursorSize = modelData
						}
					}
				}
			}
		}

		BioText {
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.bottomMargin: Bio.s3
			role: "label"
			tone: dressTouch.containsMouse ? "organ" : "muted"
			text: root.loading ? "Looking…" : (root.dressed ? "Worn" : "Dress")

			BioTouch {
				id: dressTouch
				anchors.margins: -Bio.s2
				onClicked: root.apply()
			}
		}
	}
}
