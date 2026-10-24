pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// One reaction of a zone, read like a sentence: what happens, the pattern
// it plays, and what follows it – each word a choice. Carried by its grip
// it goes elsewhere in the list, onto another zone, a scene or the shelf.
Rectangle {
	id: root

	property var page: null
	property string zoneId: ""
	required property int index
	property var trigger: ({})
	// the gap it leaves while carried
	readonly property bool carried: root.page.carry?.type === "reaction" && root.page.carry?.zoneId === root.zoneId && root.page.carry?.index === root.index
	readonly property var kind: root.page.kindOf(root.trigger.kind)
	readonly property color accent: root.page.kindColor(root.trigger.kind)
	readonly property bool on: root.trigger.on !== false
	readonly property bool withKey: root.trigger.kind === "press" || root.trigger.kind === "click"
	readonly property bool withUnless: ["change", "press", "red", "bright", "dark"].includes(root.trigger.kind)
	readonly property bool withLevel: root.withUnless
	readonly property bool withCalm: root.trigger.kind === "change" || root.trigger.kind === "press"
	readonly property var steps: Mouse.hudStepsOf(root.trigger)
	readonly property bool recordingKey: root.page.recordingKey === root.index
	property bool tuning: false
	// 0 → 1 as it comes in
	property real appear: 0

	function change(values, label) {
		Mouse.hudChangeTrigger(root.zoneId, root.index, values, label);
	}

	implicitHeight: body.implicitHeight + 22
	radius: Theme.radius.large
	color: cardHover.hovered ? Theme.layer3 : Theme.layer2
	opacity: root.appear * (root.carried ? 0.35 : (root.on ? 1 : 0.6))
	scale: (root.carried ? 0.97 : 1) * (0.92 + 0.08 * root.appear)
	Component.onCompleted: appearAnim.start()

	NumberAnimation {
		id: appearAnim

		target: root
		property: "appear"
		to: 1
		duration: Motion.long
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.spatial
	}

	Behavior on color {
		ColorAnim {}
	}
	Behavior on opacity {
		Anim {}
	}
	Behavior on scale {
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on implicitHeight {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	HoverHandler {
		id: cardHover
	}

	// the kind's colour down the left edge
	Rectangle {
		x: 0
		y: 14
		width: 3
		height: parent.height - 28
		radius: 2
		color: root.accent
		opacity: root.on ? 0.9 : 0.3
	}

	ColumnLayout {
		id: body

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.leftMargin: 12
		anchors.rightMargin: 10
		anchors.topMargin: 11
		spacing: 8

		// ── when … ──
		RowLayout {
			Layout.fillWidth: true
			spacing: 4

			// the grip: carry it
			Item {
				Layout.preferredWidth: 14
				Layout.preferredHeight: 30

				Glyph {
					anchors.centerIn: parent
					icon: "drag_vertical"
					size: 16
					color: Theme.textMuted
					opacity: cardHover.hovered || grip.pressed ? 1 : 0.25

					Behavior on opacity {
						Anim {}
					}
				}

				CarryArea {
					id: grip

					anchors.fill: parent
					anchors.margins: -4
					page: root.page
					cursorShape: Qt.OpenHandCursor
					payload: () => ({ type: "reaction", zoneId: root.zoneId, index: root.index, label: root.kind.label, icon: root.kind.icon })
				}
			}

			Rectangle {
				Layout.preferredWidth: 30
				Layout.preferredHeight: 30
				radius: 9
				color: Qt.alpha(root.accent, 0.18)

				Glyph {
					anchors.centerIn: parent
					icon: root.kind.icon
					size: 16
					color: root.accent
				}
			}

			Pick {
				entries: Mouse.hudKinds
				current: String(root.trigger.kind ?? "change")
				accent: Theme.text
				fontSize: Theme.size.body
				listWidth: 240
				onPicked: value => root.change({ kind: String(value), key: "", keyName: "" }, "the reaction's kind")
			}

			Pick {
				id: keyPick

				visible: root.withKey
				entries: root.page.keyEntries(root.trigger, root.recordingKey)
				current: root.recordingKey ? "record" : String(root.trigger.key ?? "")
				icon: root.trigger.kind === "click" ? "mouse" : "keyboard_outline"
				accent: root.recordingKey ? Theme.warning : Theme.textMuted
				fallback: root.page.keyLabel(root.trigger)
				onPicked: value => {
					if (String(value) === "record") {
						root.page.recordKey(root.zoneId, root.index);
						return;
					}
					root.page.recordKey("", -1);
					root.change({ key: String(value), keyName: "" }, "the reaction's key");
				}

				SequentialAnimation on opacity {
					running: root.recordingKey
					loops: Animation.Infinite
					onStopped: keyPick.opacity = 1

					NumberAnimation {
						to: 0.4
						duration: 450
					}
					NumberAnimation {
						to: 1
						duration: 450
					}
				}
			}

			Item {
				Layout.fillWidth: true
			}

			Toggle {
				checked: root.on
				scale: 0.85
				onToggled: on => root.change({ on }, on ? "a reaction on" : "a reaction off")
			}

			IconButton {
				Layout.preferredWidth: 28
				Layout.preferredHeight: 28
				icon: "dots_vertical"
				onClicked: menu.open()

				PickList {
					id: menu

					y: parent.height + 4
					x: parent.width - width
					width: 220
					current: ""
					entries: [{ value: "copy", label: "Copy", icon: "content_copy" }, { value: "duplicate", label: "Duplicate", icon: "content_duplicate" }, { value: "keep", label: "Keep as sequence", icon: "bookmark_plus_outline" }, { value: "remove", label: "Remove", icon: "delete_outline" }]
					onPicked: value => root.page.reactionAction(root.zoneId, root.index, String(value))
				}
			}
		}

		// ── feels … unless … ──
		Flow {
			Layout.fillWidth: true
			Layout.leftMargin: 52
			spacing: 6

			FeelChip {
				feel: String(root.trigger.feel ?? "")
				accent: root.accent
				onPicked: value => root.change({ feel: value }, "the reaction's pattern")
			}

			Pick {
				visible: root.withUnless
				height: 30
				entries: root.page.unlessEntries
				current: String(root.trigger.unless ?? "")
				icon: "cursor_default_outline"
				accent: String(root.trigger.unless ?? "") !== "" ? Theme.secondary : Theme.textSubtle
				listWidth: 280
				onPicked: value => root.change({ unless: String(value) }, "the reaction's exception")
			}

			// the fine-tuning, folded
			Clickable {
				height: 30
				width: tuneRow.implicitWidth + 16
				radius: 8
				color: root.tuning ? Qt.alpha(Theme.text, 0.1) : (hovered ? Qt.alpha(Theme.text, 0.06) : "transparent")
				onClicked: root.tuning = !root.tuning

				RowLayout {
					id: tuneRow

					anchors.centerIn: parent
					spacing: 5

					Glyph {
						icon: "tune_variant"
						size: 14
						color: root.tuning ? Theme.text : Theme.textSubtle
					}

					StyledText {
						text: `${Number(root.trigger.every ?? 150)} ms`
						font.pixelSize: Theme.size.small
						tone: root.tuning ? Theme.text : Theme.textSubtle
						tabular: true
					}
				}

				Tip {
					text: "Strength, pace and calm"
				}
			}
		}

		// the numbers, when wanted
		Flow {
			Layout.fillWidth: true
			Layout.leftMargin: 52
			spacing: 12
			visible: root.tuning
			opacity: root.tuning ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			Repeater {
				model: [
					{ key: "level", label: "needs", shown: root.withLevel, from: 0, to: 60, step: 1, unit: "", value: Number(root.trigger.level ?? 0), tip: "How strong a change has to be – 0 decides by itself" },
					{ key: "every", label: "every", shown: true, from: 30, to: 1000, step: 10, unit: " ms", value: Number(root.trigger.every ?? 150), tip: "At most one pulse this often" },
					{ key: "calm", label: "calm", shown: root.withCalm, from: 0, to: 2000, step: 50, unit: " ms", value: Number(root.trigger.calm ?? 250), tip: "Quiet this long before it counts again" }
				]

				delegate: RowLayout {
					id: tune

					required property var modelData

					visible: tune.modelData.shown
					spacing: 6

					StyledText {
						text: tune.modelData.label
						font.pixelSize: Theme.size.small
						tone: Theme.textSubtle
					}

					NumberScrub {
						from: tune.modelData.from
						to: tune.modelData.to
						step: tune.modelData.step
						unit: tune.modelData.unit
						value: tune.modelData.value
						onMoved: v => root.change({ [tune.modelData.key]: Math.round(v) }, `the reaction's ${tune.modelData.label}`)

						Tip {
							text: tune.modelData.tip
						}
					}
				}
			}
		}

		// ── then … – a chain ──
		Repeater {
			model: root.steps.length

			delegate: Item {
				id: step

				required property int index

				readonly property var info: root.steps[step.index] ?? ({})
				readonly property bool withKey: ["clickAnywhere", "clickOutside", "clickHere", "press"].includes(step.info.when)
				readonly property var whenEntry: Mouse.hudSteps.find(s => s.value === step.info.when) ?? Mouse.hudSteps[0]

				Layout.fillWidth: true
				implicitHeight: stepFlow.implicitHeight + 6
				opacity: 0
				Component.onCompleted: stepIn.start()

				NumberAnimation {
					id: stepIn

					target: step
					property: "opacity"
					to: 1
					duration: Motion.medium
				}

				HoverHandler {
					id: stepHover
				}

				// the chain: a line down from the one before, a knot at this step
				Rectangle {
					x: 32
					y: -10
					width: 2
					height: 10 + 15
					color: Qt.alpha(root.accent, 0.4)
				}

				Rectangle {
					x: 27
					y: 10
					width: 12
					height: 12
					radius: 6
					color: Theme.layer2
					border.width: 2
					border.color: root.accent
				}

				Flow {
					id: stepFlow

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.leftMargin: 52
					anchors.rightMargin: 26
					spacing: 4

					StyledText {
						height: 30
						verticalAlignment: Text.AlignVCenter
						text: "then"
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.label
					}

					Pick {
						height: 30
						entries: Mouse.hudSteps
						current: String(step.info.when ?? "clickAnywhere")
						icon: step.whenEntry.icon
						accent: Theme.text
						onPicked: value => Mouse.hudChangeStep(root.zoneId, root.index, step.index, { when: String(value) })
					}

					Pick {
						visible: step.withKey
						height: 30
						entries: step.info.when === "press" ? root.page.pressKeys : root.page.clickKeys
						current: String(step.info.key ?? "")
						accent: Theme.textMuted
						onPicked: value => Mouse.hudChangeStep(root.zoneId, root.index, step.index, { key: String(value) })
					}

					Pick {
						height: 30
						entries: step.info.when === "delay" ? root.page.delayEntries(step.info) : root.page.withinEntries(step.info)
						current: String(Number(step.info.when === "delay" ? (step.info.delay ?? 500) : (step.info.within ?? 5000)))
						icon: step.info.when === "delay" ? "timer_sand" : "timer_outline"
						accent: Theme.textMuted
						onPicked: value => Mouse.hudChangeStep(root.zoneId, root.index, step.index, step.info.when === "delay" ? { delay: Number(value) } : { within: Number(value) })

						Tip {
							text: step.info.when === "delay" ? "Waits this long" : "Only if it comes within this time"
						}
					}

					Glyph {
						height: 30
						icon: "arrow_right_thin"
						size: 16
						color: Theme.textFaint
					}

					FeelChip {
						feel: String(step.info.feel ?? "")
						accent: root.accent
						onPicked: value => Mouse.hudChangeStep(root.zoneId, root.index, step.index, { feel: value })
					}
				}

				IconButton {
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.topMargin: 3
					width: 24
					height: 24
					icon: "close"
					opacity: stepHover.hovered ? 1 : 0
					onClicked: Mouse.hudRemoveStep(root.zoneId, root.index, step.index)

					Behavior on opacity {
						Anim {}
					}
				}
			}
		}

		// a step more
		Clickable {
			Layout.leftMargin: 46
			implicitHeight: 26
			implicitWidth: thenRow.implicitWidth + 16
			radius: 13
			color: hovered ? Qt.alpha(root.accent, 0.14) : "transparent"
			opacity: cardHover.hovered || root.steps.length === 0 ? 1 : 0.55
			onClicked: Mouse.hudAddStep(root.zoneId, root.index, "clickAnywhere")

			Behavior on opacity {
				Anim {}
			}

			RowLayout {
				id: thenRow

				anchors.centerIn: parent
				spacing: 5

				Glyph {
					icon: "link_variant"
					size: 13
					color: root.accent
				}

				StyledText {
					text: "then…"
					font.pixelSize: Theme.size.label
					font.weight: Font.Medium
					tone: root.accent
				}
			}

			Tip {
				text: "Something that follows, with a pattern of its own"
			}
		}
	}
}
