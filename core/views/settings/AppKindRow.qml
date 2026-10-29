pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One kind of file or link (Default apps): what it is and what opens it now,
// with its icon. A click folds out every program that can, to pick one;
// below, the types of the kind that open with something else, each with a
// way to give it to the one picked, and those nothing opens.
ColumnLayout {
	id: root

	required property var kind
	property bool open: false

	readonly property var current: root.kind.currentApp ?? null
	readonly property bool working: DefaultApps.busy === root.kind.id
	readonly property string currentIcon: AppIcons.forEntry({ icon: root.current?.icon ?? "", id: root.current?.id ?? "" })

	spacing: 0

	Clickable {
		Layout.fillWidth: true
		implicitHeight: 58
		radius: Theme.radius.large
		pressedScale: 0.99
		color: root.open ? Theme.layer2 : (hovered ? Theme.layer2 : "transparent")
		onClicked: root.open = !root.open

		Behavior on color {
			ColorAnim {}
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 10
			anchors.rightMargin: 12
			spacing: 12

			Rectangle {
				Layout.preferredWidth: 34
				Layout.preferredHeight: 34
				radius: Theme.radius.medium
				color: Theme.primarySoft

				Glyph {
					anchors.centerIn: parent
					icon: root.kind.icon
					size: 17
					color: Theme.primary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: root.kind.label
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: {
						const others = root.kind.others.length;
						const unset = root.kind.unset.length;
						if (others === 0 && unset === 0) return `${root.kind.types.length} type${root.kind.types.length === 1 ? "" : "s"}`;
						const parts = [];
						if (others > 0) parts.push(`${others} open${others === 1 ? "s" : ""} elsewhere`);
						if (unset > 0) parts.push(`${unset} with nothing`);
						return parts.join("  ·  ");
					}
					font.pixelSize: Theme.size.small
					tone: root.kind.others.length > 0 ? Theme.warning : Theme.textSubtle
					elide: Text.ElideRight
				}
			}

			// what opens it now
			Rectangle {
				implicitWidth: nowRow.implicitWidth + 20
				implicitHeight: 36
				radius: 18
				color: Theme.layer3

				Behavior on implicitWidth {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				RowLayout {
					id: nowRow

					anchors.centerIn: parent
					spacing: 8

					Item {
						Layout.preferredWidth: 22
						Layout.preferredHeight: 22

						Image {
							id: nowIcon

							anchors.fill: parent
							source: root.currentIcon
							sourceSize: Qt.size(44, 44)
							asynchronous: true
							visible: status === Image.Ready && !root.working
						}

						Glyph {
							anchors.centerIn: parent
							visible: nowIcon.status !== Image.Ready && !root.working
							icon: root.current ? "application_outline" : "help_circle_outline"
							size: 16
							color: Theme.textMuted
						}

						Spinner {
							anchors.fill: parent
							visible: root.working
						}
					}

					StyledText {
						Layout.maximumWidth: 220
						text: root.current ? DefaultApps.nameOf(root.current) : "Nothing"
						elide: Text.ElideRight
						font.weight: Font.Medium
						tone: root.current ? Theme.text : Theme.textSubtle
					}
				}
			}

			Glyph {
				icon: "chevron_down"
				size: 18
				color: Theme.textSubtle
				rotation: root.open ? 180 : 0

				Behavior on rotation {
					SpatialAnim {
						duration: Motion.medium
					}
				}
			}
		}
	}

	// ── folded out ─────────────────────────────────────────────────────────
	Item {
		Layout.fillWidth: true
		Layout.preferredHeight: root.open ? more.implicitHeight + 14 : 0
		opacity: root.open ? 1 : 0
		visible: Layout.preferredHeight > 0.5
		clip: true

		Behavior on Layout.preferredHeight {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on opacity {
			Anim {
				duration: root.open ? Motion.long : Motion.short
			}
		}

		ColumnLayout {
			id: more

			x: 10
			y: 10
			width: parent.width - 20
			spacing: 12

			Flow {
				Layout.fillWidth: true
				spacing: 8

				Repeater {
					model: root.kind.apps

					delegate: AppChoice {
						id: choice

						required property var modelData
						required property int index

						app: choice.modelData
						selected: choice.modelData.id === root.kind.current
						working: root.working && DefaultApps.pending === choice.modelData.id
						note: choice.modelData.share < 1 ? `${choice.modelData.types.length} of ${root.kind.types.length} types` : ""
						opacity: 0
						Component.onCompleted: rise.start()

						// one after the other when folded out
						SequentialAnimation {
							id: rise

							PauseAnimation { duration: Math.min(choice.index, 10) * 28 }
							NumberAnimation { target: choice; property: "opacity"; to: 1; duration: Motion.medium; easing.type: Easing.OutCubic }
						}

						onClicked: {
							if (choice.modelData.id !== root.kind.current) DefaultApps.set(root.kind.id, choice.modelData.id);
						}
					}
				}

				StyledText {
					visible: root.kind.apps.length === 0
					text: "No installed program says it opens these."
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}

			// the types that open with something else
			ColumnLayout {
				Layout.fillWidth: true
				visible: root.kind.others.length > 0 || root.kind.unset.length > 0
				spacing: 4

				RowLayout {
					Layout.fillWidth: true

					StyledText {
						Layout.fillWidth: true
						text: "Some types go their own way"
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
						tone: Theme.textMuted
					}

					// every one of them to the one picked, one after the other
					TextButton {
						visible: root.current !== null && root.kind.others.length + root.kind.unset.length > 1
						implicitHeight: 28
						text: `Use ${DefaultApps.nameOf(root.current)} for all`
						icon: "check_all"
						enabled: !root.working
						onActivated: DefaultApps.setTypes(root.kind.id, root.kind.others.map(other => other.type).concat(root.kind.unset), root.kind.current)
					}
				}

				Repeater {
					model: root.kind.others.concat(root.kind.unset.map(type => ({ type: type, app: "", name: "" })))

					delegate: RowLayout {
						id: other

						required property var modelData

						Layout.fillWidth: true
						spacing: 10

						StyledText {
							Layout.preferredWidth: 280
							text: other.modelData.type
							font.family: Theme.monoFamily
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
							elide: Text.ElideMiddle
						}

						Glyph {
							icon: "arrow_right"
							size: 13
							color: Theme.textFaint
						}

						StyledText {
							Layout.fillWidth: true
							text: other.modelData.app === "" ? "nothing" : other.modelData.name
							font.pixelSize: Theme.size.small
							tone: other.modelData.app === "" ? Theme.textSubtle : Theme.text
							elide: Text.ElideRight
						}

						TextButton {
							visible: root.current !== null
							implicitHeight: 28
							text: `Use ${DefaultApps.nameOf(root.current)}`
							variant: "ghost"
							enabled: !root.working
							onActivated: DefaultApps.setType(root.kind.id, other.modelData.type, root.kind.current)
						}
					}
				}
			}
		}
	}
}
