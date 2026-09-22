pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"

// Studio's combinations page: a whole look, saved under a name.
//
// Every other page changes one thing - the wallpaper, the motion, the icons,
// the style branch. This one keeps the *set*: what all of them were at once.
// Put a look together across the other pages, come here, keep it, and it can
// be worn again in one action however far you wander afterwards.
//
// The work is in `scripts/combinations.py`. Combinations are stored outside
// the style branch on purpose: a combination names a branch, so keeping them
// inside one would lose the lot on the first switch.
//
// If you are writing a new style: keep this page and keep it calling that
// script, so combinations saved under one style still work under the next.
// See STUDIO.md.
Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	required property color danger

	property var combinations: []
	property var currentState: ({})
	property int selectedIndex: 0
	property bool busy: false
	property string notice: ""

	readonly property string scriptPath: `${Quickshell.shellDir}/scripts/combinations.py`
	readonly property var selected: root.combinations.length > 0
		? root.combinations[Math.max(0, Math.min(root.combinations.length - 1, root.selectedIndex))]
		: null

	// A combination is "worn" when every part it names matches what is on.
	function partsOf(entry) {
		if (!entry) return [];
		const state = root.currentState || ({});
		return [
			{ label: "Wallpaper", value: String(entry.themeName || entry.theme || ""), live: String(state.theme || "") === String(entry.theme || "") },
			{ label: "Palette", value: [entry.backend, entry.palette, entry.style].filter(v => String(v || "") !== "").join(" · "), live: String(state.palette || "") === String(entry.palette || "") && String(state.style || "") === String(entry.style || "") },
			{ label: "Motion", value: String(entry.animation || ""), live: String(state.animation || "") === String(entry.animation || "") },
			{ label: "Icons", value: String(entry.icons || ""), live: String(state.icons || "") === String(entry.icons || "") },
			{ label: "Pointer", value: String(entry.cursor || "") + (entry.cursorSize ? ` · ${entry.cursorSize} px` : ""), live: String(state.cursor || "") === String(entry.cursor || "") },
			{ label: "Style", value: String(entry.branch || ""), live: String(state.branch || "") === String(entry.branch || "") }
		].filter(part => part.value !== "");
	}

	readonly property bool selectedWorn: {
		const parts = root.partsOf(root.selected);
		if (parts.length === 0) return false;
		for (const part of parts) {
			if (!part.live) return false;
		}
		return true;
	}

	focus: true

	function reset() {
		root.reload();
		Qt.callLater(function () {
			root.forceActiveFocus();
		});
	}

	function reload() {
		root.busy = true;
		listProcess.running = true;
	}

	function move(delta) {
		if (root.combinations.length === 0) return;
		root.selectedIndex = Math.max(0, Math.min(root.combinations.length - 1, root.selectedIndex + delta));
		combinationList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
	}

	function wear() {
		if (!root.selected) return;
		root.notice = `Wearing ${root.selected.name}…`;
		Quickshell.execDetached(["python3", root.scriptPath, "apply", "--name", String(root.selected.name)]);
	}

	function keep(name) {
		const trimmed = String(name || "").trim();
		if (trimmed === "") return;
		root.busy = true;
		captureProcess.command = ["python3", root.scriptPath, "capture", "--name", trimmed];
		captureProcess.running = true;
		root.notice = `Kept ${trimmed}`;
		nameField.text = "";
	}

	function discard() {
		if (!root.selected) return;
		root.busy = true;
		deleteProcess.command = ["python3", root.scriptPath, "delete", "--name", String(root.selected.name)];
		deleteProcess.running = true;
	}

	Component.onCompleted: root.reset()
	Keys.onEscapePressed: root.closeRequested()
	Keys.onUpPressed: root.move(-1)
	Keys.onDownPressed: root.move(1)
	Keys.onReturnPressed: root.wear()
	Keys.onEnterPressed: root.wear()

	Process {
		id: listProcess
		command: ["python3", root.scriptPath, "list"]

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const parsed = JSON.parse(String(text || "{}"));
					root.combinations = parsed.combinations || [];
					root.currentState = parsed.current || ({});
				} catch (error) {
					root.combinations = [];
				}
				root.busy = false;
				if (root.selectedIndex >= root.combinations.length)
					root.selectedIndex = Math.max(0, root.combinations.length - 1);
			}
		}
	}

	Process {
		id: captureProcess
		onExited: root.reload()
	}

	Process {
		id: deleteProcess
		onExited: root.reload()
	}

	Column {
		anchors.fill: parent
		anchors.margins: 6
		spacing: 12

		Text {
			text: "Combinations"
			color: root.foreground
			font.family: "C059"
			font.pixelSize: 34
		}

		Text {
			width: parent.width
			color: root.foreground
			opacity: 0.65
			font.pixelSize: 12
			elide: Text.ElideRight
			text: root.busy
				? "Reading…"
				: `${root.combinations.length} kept. A combination applies only the parts it names.`
		}

		Item {
			id: body

			width: parent.width
			height: parent.height - 158

			// ----------------------------------------------------------- kept
			ListView {
				id: combinationList

				anchors.left: parent.left
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				width: Math.round(Math.min(parent.width * 0.38, 360))
				clip: true
				model: root.combinations
				currentIndex: root.selectedIndex
				spacing: 6
				boundsBehavior: Flickable.StopAtBounds

				delegate: Rectangle {
					id: comboRow

					required property var modelData
					required property int index

					readonly property bool chosen: root.selectedIndex === comboRow.index

					width: combinationList.width - 10
					height: 58
					radius: ThemeEngine.radiusLarge
					color: comboRow.chosen
						? root.secondaryBoxStrongColor
						: comboMouse.containsMouse ? root.secondaryBoxColor : Qt.alpha(root.secondaryBoxColor, 0.45)
					border.width: comboRow.chosen ? 1 : 0
					border.color: root.barColor

					Behavior on color {
						CAnim {}
					}

					Column {
						anchors.left: parent.left
						anchors.leftMargin: 14
						anchors.right: parent.right
						anchors.rightMargin: 14
						anchors.verticalCenter: parent.verticalCenter
						spacing: 2

						Text {
							width: parent.width
							color: root.foreground
							font.pixelSize: 14
							font.weight: comboRow.chosen ? Font.DemiBold : Font.Medium
							elide: Text.ElideRight
							text: String(comboRow.modelData.name || "")
						}

						Text {
							width: parent.width
							color: root.foreground
							opacity: 0.55
							font.family: "Adwaita Mono"
							font.pixelSize: 10
							elide: Text.ElideRight
							text: [
								String(comboRow.modelData.themeName || ""),
								String(comboRow.modelData.animation || "").split(":").pop(),
								String(comboRow.modelData.branch || "").split("/").pop()
							].filter(v => v !== "").join(" · ")
						}
					}

					MouseArea {
						id: comboMouse
						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							root.forceActiveFocus();
							root.selectedIndex = comboRow.index;
						}
						onDoubleClicked: root.wear()
					}
				}

				ScrollBar.vertical: ScrollBar {}
			}

			// ------------------------------------------------- what is in one
			Item {
				id: detail

				anchors.left: combinationList.right
				anchors.leftMargin: 20
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				opacity: root.selected ? 1 : 0

				Behavior on opacity {
					CAnim {}
				}

				Text {
					id: detailName
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					color: root.foreground
					font.family: "C059"
					font.pixelSize: 28
					elide: Text.ElideRight
					text: root.selected ? String(root.selected.name || "") : ""
				}

				// What the combination is made of, part by part, with the parts
				// the desktop is already wearing marked.
				Column {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: detailName.bottom
					anchors.topMargin: 14
					spacing: 2

					Repeater {
						model: root.partsOf(root.selected)

						delegate: Item {
							id: partRow
							required property var modelData

							width: detail.width
							height: 30

							Text {
								id: partLabel
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								width: 92
								color: root.foreground
								opacity: 0.5
								font.family: "Adwaita Mono"
								font.pixelSize: 10
								text: String(partRow.modelData.label).toUpperCase()
							}

							Text {
								anchors.left: partLabel.right
								anchors.leftMargin: 10
								anchors.right: partMark.left
								anchors.rightMargin: 10
								anchors.verticalCenter: parent.verticalCenter
								color: root.foreground
								opacity: partRow.modelData.live ? 1 : 0.62
								font.pixelSize: 12
								elide: Text.ElideRight
								text: String(partRow.modelData.value)
							}

							// Already on, or waiting.
							Rectangle {
								id: partMark
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								width: 6
								height: 6
								radius: 3
								color: partRow.modelData.live ? root.barColor : Qt.alpha(root.foreground, 0.2)
							}

							Rectangle {
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.bottom: parent.bottom
								height: 1
								color: Qt.alpha(root.foreground, 0.08)
							}
						}
					}
				}

				Text {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					color: root.foreground
					opacity: 0.55
					font.pixelSize: 11
					elide: Text.ElideRight
					text: root.notice
				}
			}

			// Nothing kept yet.
			Column {
				anchors.centerIn: detail
				width: detail.width - 40
				visible: !root.selected && !root.busy
				spacing: 6

				Text {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					color: root.foreground
					font.family: "C059"
					font.pixelSize: 22
					text: "Nothing kept yet"
				}

				Text {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					color: root.foreground
					opacity: 0.6
					font.pixelSize: 12
					wrapMode: Text.WordWrap
					text: "Set the desktop up across the other pages, then name what is on now and keep it."
				}
			}
		}

		// Keeping what is on now: the one place this page writes anything.
		Row {
			width: parent.width
			height: 40
			spacing: 8

			TextField {
				id: nameField

				width: parent.width - keepButton.width - wearButton.width - replaceButton.width - discardButton.width - 40
				height: 40
				color: root.foreground
				font.pixelSize: 12
				placeholderText: "Keep what is on now as…"
				placeholderTextColor: Qt.alpha(root.foreground, 0.42)
				selectionColor: Qt.alpha(root.barColor, 0.4)
				selectedTextColor: root.foreground
				leftPadding: 14
				rightPadding: 14
				onAccepted: root.keep(text)

				background: Rectangle {
					radius: ThemeEngine.radiusMedium
					color: Qt.alpha(root.secondaryBoxColor, 0.45)
					border.width: nameField.activeFocus ? 1 : 0
					border.color: root.barColor
				}
			}

			Rectangle {
				id: keepButton
				width: 84
				height: 40
				radius: ThemeEngine.radiusMedium
				color: keepMouse.containsMouse && nameField.text.trim() !== ""
					? Qt.lighter(root.secondaryBoxStrongColor, 1.15)
					: root.secondaryBoxStrongColor
				opacity: nameField.text.trim() === "" ? 0.5 : 1

				Behavior on color {
					CAnim {}
				}

				Text {
					anchors.centerIn: parent
					color: root.foreground
					font.pixelSize: 12
					text: "Keep"
				}

				MouseArea {
					id: keepMouse
					anchors.fill: parent
					hoverEnabled: true
					enabled: nameField.text.trim() !== ""
					cursorShape: Qt.PointingHandCursor
					onClicked: root.keep(nameField.text)
				}
			}

			Rectangle {
				id: replaceButton
				width: 88
				height: 40
				radius: ThemeEngine.radiusMedium
				color: replaceMouse.containsMouse
					? Qt.lighter(root.secondaryBoxColor, 1.15)
					: Qt.alpha(root.secondaryBoxColor, 0.6)
				opacity: root.selected ? 1 : 0.4

				Behavior on color {
					CAnim {}
				}

				Text {
					anchors.centerIn: parent
					color: root.foreground
					font.pixelSize: 12
					text: "Replace"
				}

				MouseArea {
					id: replaceMouse
					anchors.fill: parent
					hoverEnabled: true
					enabled: !!root.selected
					cursorShape: Qt.PointingHandCursor
					onClicked: {
						if (root.selected) root.keep(String(root.selected.name));
					}
				}
			}

			Rectangle {
				id: discardButton
				width: 88
				height: 40
				radius: ThemeEngine.radiusMedium
				color: discardMouse.containsMouse
					? Qt.alpha(root.danger, 0.24)
					: Qt.alpha(root.secondaryBoxColor, 0.6)
				opacity: root.selected ? 1 : 0.4

				Behavior on color {
					CAnim {}
				}

				Text {
					anchors.centerIn: parent
					color: discardMouse.containsMouse ? root.danger : root.foreground
					font.pixelSize: 12
					text: "Discard"
				}

				MouseArea {
					id: discardMouse
					anchors.fill: parent
					hoverEnabled: true
					enabled: !!root.selected
					cursorShape: Qt.PointingHandCursor
					onClicked: root.discard()
				}
			}

			Rectangle {
				id: wearButton
				width: 96
				height: 40
				radius: ThemeEngine.radiusMedium
				color: wearMouse.containsMouse && root.selected
					? Qt.lighter(root.secondaryBoxStrongColor, 1.15)
					: Qt.alpha(root.barColor, 0.28)
				border.width: 1
				border.color: Qt.alpha(root.barColor, 0.52)
				opacity: root.selected ? 1 : 0.4

				Behavior on color {
					CAnim {}
				}

				Text {
					anchors.centerIn: parent
					color: root.foreground
					font.pixelSize: 12
					font.weight: Font.DemiBold
					text: root.selectedWorn ? "Worn" : "Wear"
				}

				MouseArea {
					id: wearMouse
					anchors.fill: parent
					hoverEnabled: true
					enabled: !!root.selected
					cursorShape: Qt.PointingHandCursor
					onClicked: root.wear()
				}
			}
		}
	}
}
