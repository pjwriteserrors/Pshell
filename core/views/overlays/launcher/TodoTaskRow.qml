pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One task: state icon, text, description, notes, priority.
//
// On the board (Tasks.md) a click on the icon ticks it off – it shows done
// for a moment before it leaves the open ones – and a click on the task
// opens its actions: every state and priority, a new note, another group,
// editing in place, deleting. In a note (board false) it is a checkbox of
// the note: a click ticks it, a right click shows the states and the way
// into the editor.
Clickable {
	id: root

	// a task of Todos.parse / Todos.board
	required property var entry
	property bool board: false
	property bool compact: false
	property real zoom: 1
	// where the task lives, shown below it
	property string subtitle: ""
	property bool expanded: false
	// room kept free at the right (the drag grip of the board)
	property real trailing: 0
	property bool editing: false
	// the group list of "move to" is open
	property bool moving: false
	property bool confirmDelete: false
	// ticked off on the board: shows done until it leaves
	property bool completing: false
	readonly property string shownMark: root.completing ? "x" : root.entry.mark
	readonly property bool shownClosed: root.completing || root.entry.closed === true
	readonly property var noteNames: root.entry.notes ?? []
	// on the board: its category, the ones of its group, the model at work on it
	readonly property string category: root.entry.section ?? ""
	property var categories: []
	property bool classifying: false

	signal toggleRequested
	signal expandRequested
	signal markPicked(string mark)
	signal priorityPicked(int level)
	// in a note: the editor at the task's line
	signal editRequested
	signal contentEdited(string title, string description)
	signal noteRequested
	signal moveRequested(string group)
	signal deleteRequested
	signal categoryPicked(string name)
	signal classifyRequested

	function px(value) {
		return Math.max(1, Math.round(value * root.zoom));
	}

	function pulse() {
		pulseAnim.restart();
	}

	function toggle() {
		iconPop.restart();
		if (root.board && !root.entry.closed) {
			root.completing = true;
			Sounds.play("toggleOn");
			leave.restart();
			return;
		}
		root.toggleRequested();
	}

	function startEdit() {
		titleField.text = root.entry.text;
		descField.text = root.entry.note ?? "";
		root.editing = true;
		titleField.focusInput();
	}

	function finishEdit(save) {
		if (!root.editing) return;
		root.editing = false;
		if (save && (titleField.text.trim() !== root.entry.text || descField.text.trim() !== String(root.entry.note ?? "").trim()))
			root.contentEdited(titleField.text.trim(), descField.text);
	}

	readonly property int buttonSize: root.px(root.compact ? 26 : 30)
	readonly property int actionIcon: root.px(root.compact ? 15 : 17)

	// a widget on the desktop takes the keyboard while something is typed in it
	onEditingChanged: {
		const window = QsWindow.window;
		if (window && window.typing !== undefined) window.typing += root.editing ? 1 : -1;
	}
	onExpandedChanged: {
		if (root.expanded) return;
		root.moving = false;
		root.confirmDelete = false;
	}
	Component.onDestruction: {
		if (!root.editing) return;
		const window = QsWindow.window;
		if (window && window.typing !== undefined) window.typing -= 1;
	}

	implicitHeight: Math.max(body.implicitHeight + root.px(root.compact ? 6 : 10), root.px(root.compact ? 26 : 32))
	radius: Theme.radius.small
	pressedScale: root.editing ? 1 : 0.985
	interactive: !root.editing
	acceptedButtons: Qt.LeftButton | Qt.RightButton
	color: root.expanded ? Qt.alpha(Theme.text, 0.045) : "transparent"
	onClicked: {
		if (root.board) root.expandRequested();
		else root.toggle();
	}
	onRightClicked: root.expandRequested()

	Behavior on implicitHeight {
		enabled: root.expanded || expander.height > 0
		Anim {
			duration: Motion.short
		}
	}

	Timer {
		id: leave

		interval: 520
		onTriggered: root.toggleRequested()
	}

	Rectangle {
		id: flash

		anchors.fill: parent
		radius: root.radius
		color: Theme.primary
		opacity: 0
	}

	SequentialAnimation {
		id: pulseAnim

		loops: 2
		Anim {
			target: flash
			property: "opacity"
			to: 0.22
			duration: Motion.medium
		}
		Anim {
			target: flash
			property: "opacity"
			to: 0
			duration: Motion.long
		}
	}

	RowLayout {
		x: root.px(6) + (root.entry.indent ?? 0) * root.px(root.compact ? 16 : 20)
		width: root.width - x - root.px(6) - root.trailing
		height: root.height
		spacing: root.px(root.compact ? 8 : 10)

		Item {
			Layout.alignment: Qt.AlignTop
			Layout.topMargin: root.px(root.compact ? 4 : 6)
			implicitWidth: stateIcon.width
			implicitHeight: stateIcon.height

			Glyph {
				id: stateIcon

				icon: Todos.state(root.shownMark).icon
				size: root.px(root.compact ? 17 : 19)
				color: Todos.markColor(root.shownMark)

				Behavior on color {
					ColorAnim {}
				}
			}

			SequentialAnimation {
				id: iconPop

				SpatialAnim {
					target: stateIcon
					property: "scale"
					to: 1.32
					duration: Motion.short
				}
				SpatialAnim {
					target: stateIcon
					property: "scale"
					to: 1
					duration: Motion.long
				}
			}

			MouseArea {
				anchors.fill: parent
				anchors.margins: -5
				cursorShape: Qt.PointingHandCursor
				enabled: !root.editing
				onClicked: root.toggle()
			}
		}

		ColumnLayout {
			id: body

			Layout.fillWidth: true
			Layout.alignment: Qt.AlignVCenter
			spacing: root.px(root.compact ? 1 : 2)

			Keys.onPressed: event => {
				if (!root.editing) return;
				if (event.key === Qt.Key_Escape) {
					event.accepted = true;
					root.finishEdit(false);
				} else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
					event.accepted = true;
					root.finishEdit(true);
				}
			}

			StyledText {
				Layout.fillWidth: true
				visible: !root.editing
				text: Todos.inline(root.entry.text, Theme.primary, Theme.monoFamily)
				textFormat: Text.StyledText
				wrapMode: Text.Wrap
				elide: Text.ElideNone
				linkColor: Theme.primary
				tone: root.shownClosed ? Theme.textSubtle : Theme.text
				font.strikeout: root.shownClosed
				font.pixelSize: root.px(root.compact ? Theme.size.label + 1 : Theme.size.body + 1)
				onLinkActivated: link => Qt.openUrlExternally(link)

				Behavior on color {
					ColorAnim {}
				}
			}

			StyledText {
				Layout.fillWidth: true
				visible: !root.editing && (root.entry.note ?? "") !== ""
				text: String(root.entry.note ?? "").split("\n").map(part => Todos.inline(part, Theme.primary, Theme.monoFamily)).join("<br>")
				textFormat: Text.StyledText
				wrapMode: Text.Wrap
				maximumLineCount: root.compact && !root.expanded ? 3 : 1000
				elide: Text.ElideRight
				linkColor: Theme.primary
				tone: root.shownClosed ? Theme.textFaint : Theme.textMuted
				font.pixelSize: root.px(root.compact ? Theme.size.small : Theme.size.label)
				onLinkActivated: link => Qt.openUrlExternally(link)
			}

			// ── in place editing ──────────────────────────────────────────
			Field {
				id: titleField

				Layout.fillWidth: true
				visible: root.editing
				clearable: false
				fontSize: root.px(root.compact ? Theme.size.label + 1 : Theme.size.body)
				onAccepted: root.finishEdit(true)
				onEscapePressed: root.finishEdit(false)
				onFocusedChanged: focusCheck.restart()
			}

			AreaField {
				id: descField

				Layout.fillWidth: true
				Layout.preferredHeight: Math.max(root.px(64), Math.min(root.px(180), descField.area.contentHeight + 28))
				visible: root.editing
				placeholder: "Description"
				onFocusedChanged: focusCheck.restart()
			}

			Timer {
				id: focusCheck

				interval: 180
				onTriggered: if (root.editing && !titleField.focused && !descField.focused) root.finishEdit(true)
			}

			// ── notes ─────────────────────────────────────────────────────
			Flow {
				Layout.fillWidth: true
				Layout.topMargin: root.px(2)
				visible: (root.noteNames.length > 0 || (root.board && (root.category !== "" || root.classifying))) && !root.editing
				spacing: root.px(4)

				// the category, or the model at work on it
				Rectangle {
					id: tag

					visible: root.board && (root.category !== "" || root.classifying)
					implicitHeight: root.px(root.compact ? 20 : 24)
					implicitWidth: tagRow.implicitWidth + root.px(14)
					width: implicitWidth
					height: implicitHeight
					radius: height / 2
					color: "transparent"
					border.width: 1
					border.color: root.classifying ? Qt.alpha(Theme.primary, 0.6) : Theme.outline

					Behavior on implicitWidth {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					SequentialAnimation on opacity {
						running: root.classifying
						loops: Animation.Infinite
						alwaysRunToEnd: true
						Anim {
							to: 0.45
							duration: Motion.extraLong
						}
						Anim {
							to: 1
							duration: Motion.extraLong
						}
					}

					RowLayout {
						id: tagRow

						anchors.centerIn: parent
						spacing: root.px(4)

						Spinner {
							visible: root.classifying
							Layout.preferredWidth: root.px(11)
							Layout.preferredHeight: root.px(11)
						}

						Glyph {
							visible: !root.classifying
							icon: "tag_outline"
							size: root.px(root.compact ? 12 : 13)
							color: Theme.textMuted
						}

						StyledText {
							text: root.category !== "" ? root.category : "…"
							tone: Theme.textMuted
							font.pixelSize: root.px(root.compact ? Theme.size.small : Theme.size.label)
							font.weight: Font.Medium
							Layout.maximumWidth: root.px(200)
							elide: Text.ElideRight
						}
					}
				}

				Repeater {
					model: root.noteNames

					delegate: Clickable {
						id: chip

						required property string modelData
						required property int index
						readonly property bool there: Todos.findNote(chip.modelData) !== null

						implicitHeight: root.px(root.compact ? 20 : 24)
						implicitWidth: chipRow.implicitWidth + root.px(14)
						radius: height / 2
						pressedScale: 0.92
						color: chip.hovered ? Qt.alpha(Theme.primary, 0.22) : (chip.there ? Theme.primarySoft : "transparent")
						border.width: chip.there ? 0 : 1
						border.color: Theme.outline
						scale: 0.6
						opacity: 0
						onClicked: Todos.openNote(chip.modelData)

						Component.onCompleted: chipIn.start()

						ParallelAnimation {
							id: chipIn

							SpatialAnim {
								target: chip
								property: "scale"
								to: 1
								duration: Motion.long + chip.index * 40
							}
							Anim {
								target: chip
								property: "opacity"
								to: 1
								duration: Motion.medium
							}
						}

						RowLayout {
							id: chipRow

							anchors.centerIn: parent
							spacing: root.px(4)

							Glyph {
								icon: chip.there ? "note_text_outline" : "note_plus"
								size: root.px(root.compact ? 12 : 14)
								color: chip.there ? Theme.primary : Theme.textSubtle
							}

							StyledText {
								text: chip.modelData
								tone: chip.there ? Theme.text : Theme.textSubtle
								font.pixelSize: root.px(root.compact ? Theme.size.small : Theme.size.label)
								font.weight: Font.Medium
								Layout.maximumWidth: root.px(200)
								elide: Text.ElideRight
							}
						}
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				visible: root.subtitle !== "" && !root.editing
				text: root.subtitle
				tone: Theme.textSubtle
				elide: Text.ElideRight
				font.pixelSize: root.px(Theme.size.small)
			}

			// ── actions ───────────────────────────────────────────────────
			Item {
				id: expander

				Layout.fillWidth: true
				Layout.preferredHeight: root.expanded && !root.editing ? actions.implicitHeight + root.px(4) : 0
				clip: true
				visible: Layout.preferredHeight > 0.5
				opacity: root.expanded && !root.editing ? 1 : 0

				Behavior on Layout.preferredHeight {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				Behavior on opacity {
					Anim {}
				}

				ColumnLayout {
					id: actions

					y: root.px(4)
					width: expander.width
					spacing: root.px(4)

					Flow {
						Layout.fillWidth: true
						spacing: 2

						Repeater {
							model: Todos.states

							delegate: IconButton {
								required property var modelData

								width: root.buttonSize
								height: root.buttonSize
								icon: modelData.icon
								iconSize: root.actionIcon
								iconColor: Todos.markColor(modelData.mark)
								variant: Todos.state(root.entry.mark).mark === modelData.mark ? "tonal" : "ghost"
								onClicked: root.markPicked(modelData.mark)
							}
						}
					}

					Flow {
						Layout.fillWidth: true
						spacing: 2

						Repeater {
							model: Todos.priorities

							delegate: IconButton {
								required property var modelData

								width: root.buttonSize
								height: root.buttonSize
								icon: modelData.icon
								iconSize: root.actionIcon
								iconColor: Todos.priorityColor(modelData.level)
								variant: root.entry.priority === modelData.level ? "tonal" : "ghost"
								onClicked: root.priorityPicked(root.entry.priority === modelData.level ? 0 : modelData.level)
							}
						}

						Item {
							width: root.px(10)
							height: root.buttonSize
						}

						IconButton {
							visible: root.board
							width: root.buttonSize
							height: root.buttonSize
							icon: "note_plus"
							iconSize: root.actionIcon
							onClicked: root.noteRequested()
						}

						IconButton {
							visible: root.board
							width: root.buttonSize
							height: root.buttonSize
							icon: "folder_move_outline"
							iconSize: root.actionIcon
							checked: root.moving
							onClicked: root.moving = !root.moving
						}

						IconButton {
							width: root.buttonSize
							height: root.buttonSize
							icon: "pencil"
							iconSize: root.actionIcon
							onClicked: {
								if (root.board) root.startEdit();
								else root.editRequested();
							}
						}

						IconButton {
							visible: root.board
							width: root.buttonSize
							height: root.buttonSize
							icon: root.confirmDelete ? "delete" : "delete_outline"
							iconSize: root.actionIcon
							variant: root.confirmDelete ? "danger" : "ghost"
							onClicked: {
								if (root.confirmDelete) root.deleteRequested();
								else {
									root.confirmDelete = true;
									unconfirm.restart();
								}
							}

							Timer {
								id: unconfirm

								interval: 2600
								onTriggered: root.confirmDelete = false
							}
						}
					}

					// its category: picked by hand, or asked of the model again
					Flow {
						Layout.fillWidth: true
						visible: root.board && root.categories.length > 0
						spacing: root.px(4)

						Repeater {
							model: root.expanded ? root.categories : []

							delegate: Chip {
								required property string modelData

								height: root.px(26)
								text: modelData
								icon: "tag_outline"
								selected: root.category === modelData
								onClicked: root.categoryPicked(root.category === modelData ? "" : modelData)
							}
						}

						IconButton {
							visible: Todos.aiEnabled
							width: root.px(26)
							height: root.px(26)
							icon: "robot_outline"
							iconSize: root.px(15)
							enabled: !root.classifying
							onClicked: root.classifyRequested()
						}
					}

					Flow {
						Layout.fillWidth: true
						visible: root.moving
						spacing: root.px(4)

						Repeater {
							model: root.moving ? Todos.groups.filter(group => group.name !== root.entry.group) : []

							delegate: Chip {
								required property var modelData

								height: root.px(26)
								text: modelData.name
								icon: modelData.name === Todos.inbox ? "inbox_outline" : "folder_outline"
								onClicked: root.moveRequested(modelData.name)
							}
						}
					}
				}
			}
		}

		Glyph {
			visible: (root.entry.priority ?? 0) > 0
			Layout.alignment: Qt.AlignTop
			Layout.topMargin: root.px(root.compact ? 4 : 6)
			icon: Todos.priorities.find(entry => entry.level === root.entry.priority)?.icon ?? ""
			size: root.px(root.compact ? 15 : 17)
			color: Todos.priorityColor(root.entry.priority)
		}
	}
}
