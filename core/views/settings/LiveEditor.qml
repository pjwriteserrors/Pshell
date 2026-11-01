pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Every live status of the shell (Live), by kind, each with a preview that
// moves like the real thing: put it on the bar or into a tray with one
// click; opened, it shows how it looks – value, ring, curve, bar or the
// icon alone – whether it hides while nothing happens and whether its
// name stands in front.
ColumnLayout {
	id: root

	// the one that is open
	property string opened: ""
	property string filter: "all"
	readonly property var firstTray: AppTray.trays[0] ?? null

	spacing: 14

	function onBar(key) {
		const id = `live-${key}`;
		return BarLayout.left.includes(id) || BarLayout.center.includes(id) || BarLayout.right.includes(id);
	}
	function trayItems(key) {
		const out = [];
		for (const tray of AppTray.trays)
			for (const item of tray.items ?? [])
				if (item.kind === "widget" && item.widget === `live:${key}`) out.push({ tray: tray.id, item: item.id });
		return out;
	}

	Segmented {
		Layout.fillWidth: true
		options: [{ value: "all", label: "All" }].concat(Live.groups.map(group => ({ value: group.id, label: group.name })))
		current: root.filter
		onSelected: value => root.filter = value
	}

	Repeater {
		model: Live.groups.filter(group => root.filter === "all" || root.filter === group.id)

		delegate: ColumnLayout {
			id: section

			required property var modelData

			Layout.fillWidth: true
			spacing: 8

			SectionLabel {
				text: section.modelData.name
			}

			GridLayout {
				Layout.fillWidth: true
				columns: root.width > 640 ? 2 : 1
				columnSpacing: 8
				rowSpacing: 8

				Repeater {
					model: Live.sources.filter(src => src.group === section.modelData.id)

					delegate: Tile {
						required property var modelData

						src: modelData
					}
				}
			}
		}
	}

	StyledText {
		Layout.fillWidth: true
		text: "Values roll as they change; a ring fills, a curve shows the last minute. Rest on one in the bar for a card with more, click it for its panel, turn the wheel where it changes something."
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}

	// ── one source ──────────────────────────────────────────────────────
	component Tile: Rectangle {
		id: tile

		required property var src
		readonly property string key: tile.src.key
		readonly property bool open: root.opened === tile.key
		readonly property bool there: tile.src.available
		readonly property bool barred: root.onBar(tile.key)
		readonly property var trayed: root.trayItems(tile.key)
		readonly property var option: Live.optionOf(tile.key)
		readonly property bool pluginOff: tile.src.plugin !== "" && !Plugins.on(tile.src.plugin)

		Layout.fillWidth: true
		Layout.alignment: Qt.AlignTop
		implicitHeight: column.implicitHeight + 20
		radius: Theme.radius.large
		color: tile.open ? Theme.layer2 : (hover.hovered ? Theme.layer1 : "transparent")
		border.width: 1
		border.color: tile.open ? Qt.alpha(Theme.primary, 0.35) : Theme.outline
		clip: true

		Behavior on implicitHeight {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on color {
			ColorAnim {}
		}
		Behavior on border.color {
			ColorAnim {}
		}

		HoverHandler {
			id: hover
		}

		ColumnLayout {
			id: column

			x: 10
			y: 10
			width: parent.width - 20
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				// the preview, on a piece of bar
				Rectangle {
					Layout.preferredWidth: Math.max(58, Math.min(150, face.implicitWidth + 20))
					Layout.preferredHeight: 34
					radius: 17
					color: Theme.glass
					border.width: 1
					border.color: Theme.outline
					opacity: tile.there ? 1 : 0.45
					clip: true

					Behavior on Layout.preferredWidth {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					LiveFace {
						id: face

						anchors.centerIn: parent
						key: tile.key
						// nothing to show: the glyph alone
						style: tile.there ? "" : "icon"
					}

					Component.onCompleted: Live.hold(tile.key, 1)
					Component.onDestruction: Live.hold(tile.key, -1)
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						Layout.fillWidth: true
						text: tile.src.name
						font.weight: Font.DemiBold
					}

					StyledText {
						Layout.fillWidth: true
						text: tile.pluginOff ? `Needs ${Plugins.byId[tile.src.plugin]?.name ?? tile.src.plugin}` : (tile.there ? tile.src.about : "Nothing to show here")
						tone: tile.pluginOff ? Theme.warning : Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}

				Place {
					visible: !tile.pluginOff
					icon: "page_layout_header"
					text: "Bar"
					on: tile.barred
					onPicked: {
						if (tile.barred) BarLayout.remove(`live-${tile.key}`);
						else BarLayout.place(`live-${tile.key}`, "right", 0);
						Sounds.play(tile.barred ? "toggleOff" : "toggleOn");
					}
				}

				Place {
					visible: !tile.pluginOff && root.firstTray !== null
					icon: "dock_window"
					text: "Tray"
					on: tile.trayed.length > 0
					onPicked: {
						if (tile.trayed.length > 0) {
							for (const each of tile.trayed) AppTray.removeItem(each.tray, each.item, true);
							Sounds.play("toggleOff");
						} else {
							AppTray.addItems(root.firstTray.id, [{ kind: "widget", widget: `live:${tile.key}` }], -1);
							Sounds.play("toggleOn");
						}
					}
				}

				TextButton {
					visible: tile.pluginOff
					text: "Turn on"
					icon: "power"
					variant: "tonal"
					onActivated: Plugins.set(tile.src.plugin, true)
				}

				IconButton {
					visible: !tile.pluginOff
					icon: "chevron_down"
					rotation: tile.open ? 180 : 0
					onClicked: root.opened = tile.open ? "" : tile.key

					Behavior on rotation {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}
			}

			// ── how it looks ─────────────────────────────────────────────
			ColumnLayout {
				Layout.fillWidth: true
				visible: tile.open
				spacing: 10
				opacity: tile.open ? 1 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.medium
					}
				}

				Segmented {
					Layout.fillWidth: true
					options: Live.styles.map(each => ({ value: each.value, label: each.label }))
					current: tile.option.style
					onSelected: value => Live.setOption(tile.key, { style: value })
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 12

					StyledText {
						Layout.fillWidth: true
						text: "Hide while nothing happens"
						font.pixelSize: Theme.size.small
					}

					Toggle {
						checked: tile.option.hide
						onToggled: on => Live.setOption(tile.key, { hide: on })
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 12

					StyledText {
						Layout.fillWidth: true
						text: "Name in front of the value"
						font.pixelSize: Theme.size.small
					}

					Toggle {
						checked: tile.option.label
						onToggled: on => Live.setOption(tile.key, { label: on })
					}
				}

				StyledText {
					Layout.fillWidth: true
					visible: tile.src.detail !== ""
					text: `Now: ${tile.src.detail}`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}
		}
	}

	// a pill that is on or off: on the bar, in a tray
	component Place: Rectangle {
		id: place

		property string icon: ""
		property string text: ""
		property bool on: false
		signal picked

		implicitWidth: placeRow.implicitWidth + 18
		implicitHeight: 30
		radius: 15
		color: place.on ? Theme.primary : (placeHover.hovered ? Theme.layer3 : Theme.layer2)

		Behavior on color {
			ColorAnim {}
		}

		// it pops when it changes
		onOnChanged: popAnim.restart()

		SequentialAnimation {
			id: popAnim

			NumberAnimation {
				target: place
				property: "scale"
				to: 1.12
				duration: 110
				easing.type: Easing.OutQuad
			}
			NumberAnimation {
				target: place
				property: "scale"
				to: 1
				duration: 380
				easing.type: Easing.OutBack
			}
		}

		Row {
			id: placeRow

			anchors.centerIn: parent
			spacing: 5

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: place.on ? "check" : place.icon
				size: 14
				color: place.on ? Theme.onPrimary : Theme.text
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: place.text
				tone: place.on ? Theme.onPrimary : Theme.text
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}
		}

		HoverHandler {
			id: placeHover

			cursorShape: Qt.PointingHandCursor
		}

		TapHandler {
			onTapped: place.picked()
		}
	}
}
