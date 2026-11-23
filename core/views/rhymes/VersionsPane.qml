pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Earlier states of the words: kept by hand (Ctrl+S), by themselves while
// writing (one every quarter of an hour at most) and before one was brought
// back. One picked shows what it has that the words now lack, and back.
Item {
	id: pane

	Component.onCompleted: Rhymes.loadVersions()

	Column {
		id: top

		x: 16
		y: 4
		width: parent.width - 32
		spacing: 10

		TextButton {
			width: parent.width
			icon: "bookmark_outline"
			text: "Keep this version"
			onClicked: Rhymes.keepVersion()
		}
	}

	ListView {
		id: list

		anchors.top: top.bottom
		anchors.topMargin: 12
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		clip: true
		spacing: 6
		model: Rhymes.versions
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		add: Transition {
			Anim {
				property: "opacity"
				from: 0
				to: 1
			}
		}

		delegate: Item {
			id: entry

			required property var modelData
			readonly property bool open: Rhymes.preview?.name === entry.modelData.name

			width: list.width
			height: card.height

			Clickable {
				id: card

				x: 16
				width: parent.width - 32
				height: entry.open ? 66 + diff.height + 52 : 66
				radius: Theme.radius.large
				color: entry.open ? Theme.layer2 : Theme.layer1
				clip: true
				onClicked: entry.open ? (Rhymes.preview = null) : Rhymes.showVersion(entry.modelData.name)

				Behavior on height {
					SpatialAnim {}
				}

				Behavior on color {
					ColorAnim {}
				}

				Column {
					x: 14
					y: 12
					width: parent.width - 28
					spacing: 2

					Row {
						spacing: 8

						StyledText {
							text: Format.ago(entry.modelData.at * 1000)
							font.weight: Font.Medium
						}

						Rectangle {
							anchors.verticalCenter: parent.verticalCenter
							width: why.implicitWidth + 12
							height: 18
							radius: 9
							color: entry.modelData.why === "kept" ? Theme.primarySoft : Theme.layer3
							visible: why.text !== ""

							StyledText {
								id: why

								anchors.centerIn: parent
								text: ({ auto: "auto", kept: "kept", before: "before restoring" })[entry.modelData.why] ?? entry.modelData.why
								font.pixelSize: Theme.size.tiny
								tone: entry.modelData.why === "kept" ? Theme.primary : Theme.textMuted
							}
						}
					}

					StyledText {
						width: parent.width
						text: entry.modelData.first
						elide: Text.ElideRight
						font.pixelSize: Theme.size.small
						tone: Theme.textSubtle
					}
				}

				Column {
					id: diff

					x: 14
					y: 66
					width: parent.width - 28
					spacing: 1
					opacity: entry.open ? 1 : 0

					Behavior on opacity {
						Anim {}
					}

					Repeater {
						model: entry.open ? (Rhymes.preview?.diff ?? []).filter(d => d.t.trim() !== "" || d.k !== "same").slice(0, 80) : []

						Rectangle {
							required property var modelData

							width: diff.width
							height: line.implicitHeight + 4
							radius: 4
							color: modelData.k === "add" ? Qt.alpha(Theme.success, 0.16) : (modelData.k === "drop" ? Qt.alpha(Theme.danger, 0.14) : "transparent")

							StyledText {
								id: line

								x: 6
								y: 2
								width: parent.width - 12
								text: modelData.t || " "
								wrapMode: Text.Wrap
								font.pixelSize: Theme.size.small
								font.strikeout: modelData.k === "drop"
								tone: modelData.k === "same" ? Theme.textSubtle : Theme.text
							}
						}
					}
				}

				Row {
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 10
					x: 14
					spacing: 8
					visible: entry.open

					TextButton {
						text: "Restore"
						icon: "restore"
						variant: "filled"
						confirm: true
						confirmText: "Restore?"
						onActivated: Rhymes.restoreVersion(entry.modelData.name)
					}

					TextButton {
						text: "Delete"
						variant: "ghost"
						confirm: true
						onActivated: Rhymes.dropVersion(entry.modelData.name)
					}
				}
			}
		}
	}

	Glyph {
		anchors.centerIn: parent
		visible: Rhymes.versions.length === 0
		icon: "history"
		size: 48
		color: Theme.textFaint
	}
}
