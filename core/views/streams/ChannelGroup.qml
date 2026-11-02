pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Channels of one maker (merged, source.group) as one card: their faces and
// one name on the left, each channel in a line of its own on the right, where
// it can be split off or removed. What is set here is set for all of them.
Item {
	id: card

	required property string key
	required property var page
	readonly property string group: card.key.replace(/^group:/, "")
	readonly property var members: Streams.ownSources.filter(item => item.group === card.group).sort((a, b) => (a.kind === "twitch") - (b.kind === "twitch") || (b.videos ?? 0) - (a.videos ?? 0))
	readonly property string name: Streams.makerName(card.members)
	readonly property bool waiting: card.members.some(item => item.id === card.page.mergingFrom)
	readonly property bool canTake: card.page.mergingFrom !== "" && !card.waiting
	readonly property bool anyLive: card.members.some(item => item.live)
	readonly property bool favorite: card.members.some(item => item.favorite)
	readonly property string notify: card.members.length > 0 && card.members.every(item => item.notify === card.members[0].notify) ? card.members[0].notify : ""

	HoverHandler {
		id: cardHover
	}

	Rectangle {
		id: body

		anchors.fill: parent
		anchors.margins: 6
		radius: Theme.radius.huge
		color: card.waiting ? Theme.primaryContainer : (cardHover.hovered ? Theme.layer2 : Theme.layer1)
		opacity: card.page.mergingFrom !== "" && !card.waiting && !card.canTake ? 0.4 : 1
		border.width: card.canTake && cardHover.hovered ? 2 : 0
		border.color: Theme.primary

		Behavior on color {
			ColorAnim {}
		}

		RowLayout {
			anchors.fill: parent
			anchors.margins: 14
			spacing: 14

			// ── the maker ────────────────────────────────────────────────
			ColumnLayout {
				// its texts fill it; it must not fill the card
				Layout.fillWidth: false
				Layout.preferredWidth: Math.max(150, body.width * 0.36)
				Layout.maximumWidth: Layout.preferredWidth
				Layout.fillHeight: true
				spacing: 6

				// the faces, fanned out; the one with the most videos in front
				Item {
					id: faces

					readonly property int shown: Math.min(3, card.members.length)
					readonly property int size: 72
					readonly property int step: 30

					Layout.alignment: Qt.AlignHCenter
					Layout.preferredWidth: faces.size + (faces.shown - 1) * faces.step
					Layout.preferredHeight: faces.size + 12
					scale: cardHover.hovered ? 1.05 : 1

					Behavior on scale {
						SpatialAnim {
							duration: Motion.long
						}
					}

					Repeater {
						model: faces.shown

						delegate: Item {
							id: face

							required property int index
							readonly property var item: card.members[faces.shown - 1 - face.index] ?? null

							x: face.index * faces.step
							y: 6
							z: face.index
							width: faces.size
							height: faces.size

							Rectangle {
								anchors.centerIn: parent
								width: parent.width + 6
								height: width
								radius: width / 2
								color: body.color
							}
							Avatar {
								anchors.fill: parent
								source: face.item?.avatar ?? ""
								name: face.item?.name ?? ""
								colors: face.item?.colors ?? null
								live: face.item?.live ?? false
							}
						}
					}
				}
				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignHCenter
					text: card.name
					font.pixelSize: Theme.size.title
					font.weight: Font.Bold
					elide: Text.ElideRight
				}
				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignHCenter
					text: {
						const videos = card.members.reduce((sum, item) => sum + (item.kind === "twitch" ? 0 : (item.videos ?? 0)), 0);
						return `${card.members.length} channels${videos ? ` · ${videos} videos` : ""}${card.anyLive ? " · live" : ""}`;
					}
					font.pixelSize: Theme.size.small
					color: card.anyLive ? Theme.danger : Theme.textMuted
					elide: Text.ElideRight
				}
				Item {
					Layout.fillHeight: true
				}
				Segmented {
					Layout.fillWidth: true
					Layout.preferredHeight: 28
					options: [{ value: "all", label: "All" }, { value: "live", label: "Live" }, { value: "silent", label: "Silent" }]
					current: card.notify
					onSelected: value => card.members.forEach(item => Streams.updateSource(item.id, { notify: value }))
				}
			}

			Rectangle {
				Layout.fillHeight: true
				Layout.preferredWidth: 1
				color: Theme.outline
				opacity: 0.5
			}

			// ── its channels ─────────────────────────────────────────────
			ColumnLayout {
				Layout.fillWidth: true
				Layout.fillHeight: true
				Layout.topMargin: 26
				spacing: 2

				Repeater {
					model: card.members

					delegate: Rectangle {
						id: line

						required property var modelData
						readonly property var item: line.modelData

						Layout.fillWidth: true
						Layout.preferredHeight: Math.min(44, (body.height - 54) / Math.max(1, card.members.length))
						radius: Theme.radius.large
						color: lineHover.hovered && card.page.mergingFrom === "" ? Theme.layer3 : "transparent"

						Behavior on color {
							ColorAnim {}
						}

						HoverHandler {
							id: lineHover
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 6
							anchors.rightMargin: 4
							spacing: 10

							Avatar {
								Layout.preferredWidth: Math.min(30, line.height - 8)
								Layout.preferredHeight: Layout.preferredWidth
								source: line.item.avatar ?? ""
								name: line.item.name ?? ""
								colors: line.item.colors ?? null
								live: line.item.live ?? false
							}
							ColumnLayout {
								Layout.fillWidth: true
								spacing: -2

								StyledText {
									Layout.fillWidth: true
									text: line.item.name ?? ""
									font.pixelSize: Theme.size.body
									font.weight: Font.DemiBold
									elide: Text.ElideRight
								}
								StyledText {
									Layout.fillWidth: true
									visible: line.height >= 36
									text: line.item.error || line.item.loading || (line.item.live ? `${Streams.sourceKind(line.item)} · live now` : Streams.sourceKind(line.item))
									font.pixelSize: Theme.size.small
									color: line.item.error ? Theme.warning : (line.item.live ? Theme.danger : Theme.textMuted)
									elide: Text.ElideRight
								}
							}
							Glyph {
								icon: line.item.kind === "youtube" ? "youtube" : (line.item.kind === "twitch" ? "cast" : "format_list_bulleted")
								size: 16
								color: Theme.textMuted
								visible: !lineHover.hovered || card.page.mergingFrom !== ""
							}
							IconButton {
								Layout.preferredWidth: 28
								Layout.preferredHeight: 28
								visible: lineHover.hovered && card.page.mergingFrom === ""
								icon: "call_split"
								onClicked: Streams.call("unmergeSource", { id: line.item.id })
							}
							TextButton {
								visible: lineHover.hovered && card.page.mergingFrom === ""
								text: ""
								icon: "delete_outline"
								variant: "ghost"
								confirm: true
								confirmText: "Remove?"
								onActivated: Streams.call("removeSource", { id: line.item.id })
							}
						}
					}
				}
				Item {
					Layout.fillHeight: true
				}
			}
		}

		IconButton {
			anchors.left: parent.left
			anchors.top: parent.top
			anchors.margins: 8
			width: 30
			height: 30
			icon: card.favorite ? "star" : "star_outline"
			checked: card.favorite
			visible: cardHover.hovered || card.favorite
			onClicked: {
				const value = !card.favorite;
				card.members.forEach(item => Streams.updateSource(item.id, { favorite: value }));
			}
		}
		// one more channel of this maker
		IconButton {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 8
			width: 30
			height: 30
			visible: cardHover.hovered && card.page.mergingFrom === ""
			icon: "account_multiple_plus"
			onClicked: card.page.mergingFrom = card.members[0]?.id ?? ""
		}
		MouseArea {
			anchors.fill: parent
			visible: card.canTake
			cursorShape: Qt.PointingHandCursor
			onClicked: card.page.mergeInto(card.members[0].id)
		}
	}
}
