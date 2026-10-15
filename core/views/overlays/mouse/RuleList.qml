pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Controls.js" as Controls

// Every rule as a sentence – "Gesture button, swipe up, in firefox, with
// Ctrl → New tab" – to switch off, change or take away; and a sentence to
// build a new one from, where held modifier keys can be a condition too.
ColumnLayout {
	id: root

	property var picker: null
	readonly property bool recording: modPicker.recording

	signal opened(string control, string app)

	spacing: 8

	readonly property var sorted: Mouse.rules.slice().sort((a, b) => {
		const order = Controls.controls.map(c => c.id);
		return (a.app ?? "").localeCompare(b.app ?? "") || order.indexOf(a.control) - order.indexOf(b.control);
	})

	// ── the new one ────────────────────────────────────────────────────────
	property string newControl: "gesture"
	property string newTrigger: "click"
	property string newApp: ""
	property var newMods: []

	EmptyState {
		Layout.fillWidth: true
		visible: Mouse.rules.length === 0
		icon: "gesture_tap_button"
		title: "No rules yet"
		subtitle: "Every button does what it does on its own. Pick a tile above or build a sentence below."
	}

	Repeater {
		model: root.sorted

		delegate: Rectangle {
			id: line

			required property var modelData
			required property int index
			readonly property var meta: Controls.byId(line.modelData.control)
			readonly property var info: Mouse.describe(line.modelData.action, line.modelData.control)
			readonly property bool on: line.modelData.on !== false
			property real glow: 0

			Layout.fillWidth: true
			implicitHeight: 52
			radius: Theme.radius.large
			color: Theme.layer2
			opacity: line.on ? 1 : 0.55
			border.width: 1.5
			border.color: Qt.alpha(Theme.primary, line.glow)

			Behavior on opacity {
				Anim {}
			}

			Connections {
				target: Mouse

				function onFired(rule) {
					if (rule === line.modelData.id) flash.restart();
				}
			}

			SequentialAnimation {
				id: flash

				NumberAnimation {
					target: line
					property: "glow"
					to: 1
					duration: Motion.micro
				}
				NumberAnimation {
					target: line
					property: "glow"
					to: 0
					duration: Motion.extraLong * 2
				}
			}

			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onClicked: {
					root.opened(line.modelData.control, line.modelData.app ?? "");
					if ((line.modelData.mods ?? []).length === 0 && root.picker) root.picker.show(line.modelData.control, line.modelData.trigger, line.modelData.app ?? "");
				}
			}

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 12
				anchors.rightMargin: 8
				spacing: 8

				Glyph {
					icon: line.meta?.icon ?? "mouse"
					size: 16
					color: Theme.primary
				}

				Word {
					text: line.meta?.label ?? line.modelData.control
					strong: true
				}

				Word {
					text: Controls.triggerLabel(line.modelData.control, line.modelData.trigger).toLowerCase()
				}

				Pill {
					visible: (line.modelData.app ?? "") !== ""
					text: `in ${line.modelData.app}`
					icon: "application_outline"
				}

				Pill {
					visible: (line.modelData.mods ?? []).length > 0
					text: `with ${(line.modelData.mods ?? []).map(m => m.charAt(0).toUpperCase() + m.slice(1)).join(" + ")}`
					icon: "keyboard_outline"
				}

				Glyph {
					icon: "arrow_right"
					size: 14
					color: Theme.textFaint
				}

				Glyph {
					visible: (line.info.icon || "") !== ""
					icon: line.info.icon || "flash"
					size: 15
					color: Theme.text
				}

				Word {
					Layout.fillWidth: true
					text: line.info.label
					strong: true
					elide: Text.ElideRight
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "play_outline"
					onClicked: Mouse.test(line.modelData.action)
				}

				Toggle {
					checked: line.on
					onToggled: on => Mouse.toggleRule(line.modelData.id, on)
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "delete_outline"
					onClicked: Mouse.removeRule(line.modelData.id)
				}
			}
		}
	}

	// ── the sentence to build from ─────────────────────────────────────────
	Rectangle {
		Layout.fillWidth: true
		Layout.topMargin: 6
		implicitHeight: builder.implicitHeight + 24
		radius: Theme.radius.large
		color: "transparent"
		border.width: 1.5
		border.color: Theme.outline

		Flow {
			id: builder

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			anchors.margins: 12
			spacing: 8

			Word {
				height: 34
				verticalAlignment: Text.AlignVCenter
				text: "When"
			}

			Choice {
				text: Controls.byId(root.newControl)?.label ?? ""
				icon: Controls.byId(root.newControl)?.icon ?? ""
				entries: Controls.controls.filter(c => c.triggers !== "none").map(c => ({ value: c.id, label: c.label, icon: c.icon }))
				current: root.newControl
				onPicked: value => {
					root.newControl = value;
					if (!Controls.triggersOf(value).includes(root.newTrigger)) root.newTrigger = Controls.triggersOf(value)[0];
				}
			}

			Choice {
				text: Controls.triggerLabel(root.newControl, root.newTrigger).toLowerCase()
				entries: Controls.triggersOf(root.newControl).map(t => ({ value: t, label: Controls.triggerLabel(root.newControl, t) }))
				current: root.newTrigger
				onPicked: value => root.newTrigger = value
			}

			Choice {
				text: root.newApp === "" ? "everywhere" : `in ${root.newApp}`
				icon: root.newApp === "" ? "earth" : "application_outline"
				entries: [{ value: "", label: "Everywhere", icon: "earth" }].concat(Mouse.apps.map(a => ({ value: a, label: a, icon: "application_outline" }))).concat(Niri.windows.map(w => String(w.app_id || "")).filter((a, i, all) => a && !Mouse.apps.includes(a) && all.indexOf(a) === i).map(a => ({ value: a, label: a, detail: "open now", icon: "application_outline" })))
				current: root.newApp
				onPicked: value => root.newApp = String(value)
			}

			Word {
				height: 34
				verticalAlignment: Text.AlignVCenter
				text: "while holding"
			}

			Repeater {
				model: ["ctrl", "shift", "alt", "super"]

				delegate: Chip {
					required property string modelData

					text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
					selected: root.newMods.includes(modelData)
					onClicked: root.newMods = root.newMods.includes(modelData) ? root.newMods.filter(m => m !== modelData) : root.newMods.concat([modelData])
				}
			}

			TextButton {
				variant: "filled"
				icon: "plus"
				text: "Choose what it does"
				onActivated: {
					if (root.newMods.length === 0) {
						root.picker.show(root.newControl, root.newTrigger, root.newApp);
						return;
					}
					modPicker.show(root.newControl, root.newTrigger, root.newApp);
				}
			}
		}
	}

	StyledText {
		Layout.fillWidth: true
		text: "Held keys are read from the keyboards themselves (Solaar cannot on Wayland). The most exact rule wins: an app and keys before an app before keys before everywhere."
		tone: Theme.textFaint
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}

	// a rule with modifiers is not on a tile: its own picker writes it
	ActionPicker {
		id: modPicker

		onChosen: (action, extra) => {
			Mouse.putRule(Object.assign({ id: Mouse.newId(), control: modPicker.control, trigger: modPicker.trigger, app: modPicker.app, mods: root.newMods.slice(), on: true }, extra, { action }));
			root.newMods = [];
		}
	}

	component Word: StyledText {
		property bool strong: false

		font.weight: strong ? Font.DemiBold : Font.Normal
		tone: strong ? Theme.text : Theme.textMuted
	}

	component Pill: Rectangle {
		property string text: ""
		property string icon: ""

		implicitWidth: pillRow.implicitWidth + 16
		implicitHeight: 24
		radius: 12
		color: Theme.primarySoft

		Row {
			id: pillRow

			anchors.centerIn: parent
			spacing: 5

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: parent.parent.icon
				size: 12
				color: Theme.primary
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: parent.parent.text
				tone: Theme.primary
				font.pixelSize: Theme.size.small
				font.weight: Font.Medium
			}
		}
	}

	// a word of the sentence that opens a list
	component Choice: Clickable {
		id: choice

		property string text: ""
		property string icon: ""
		property var entries: []
		property string current: ""

		signal picked(var value)

		width: choiceRow.implicitWidth + 24
		height: 34
		radius: 17
		color: Theme.primaryContainer
		onClicked: list.open()

		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Row {
			id: choiceRow

			anchors.centerIn: parent
			spacing: 6

			Glyph {
				visible: choice.icon !== ""
				anchors.verticalCenter: parent.verticalCenter
				icon: choice.icon
				size: 14
				color: Theme.primary
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: choice.text
				tone: Theme.primary
				font.weight: Font.DemiBold
			}

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: "chevron_down"
				size: 14
				color: Theme.primary
			}
		}

		PickList {
			id: list

			y: parent.height + 6
			entries: choice.entries
			current: choice.current
			onPicked: value => choice.picked(value)
		}
	}
}
