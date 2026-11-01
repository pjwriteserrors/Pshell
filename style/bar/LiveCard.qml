import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The card under a live status of the bar while the pointer rests on it:
// the name, the value large, what else there is to know, the curve of the
// last minute or how full it is, and what a click does. It drops out of
// the bar and its lines follow one after another.
PopupWindow {
	id: root

	required property var bar
	required property Item target
	required property string key
	property bool shown: false
	readonly property var src: Live.source(root.key)
	readonly property color toneColor: Theme.toneColor(root.src?.tone ?? "normal")
	readonly property color accent: root.src?.tone === "normal" || root.src?.tone === "muted" ? Theme.primary : root.toneColor
	readonly property string hint: {
		if (!root.src) return "";
		if (root.src.hint !== "") return root.src.hint;
		return root.src.panel !== "" || root.src.act ? "Click to open" : "";
	}

	// each line comes a little after the one above
	component Line: Item {
		id: line

		property int order: 0
		default property alias content: holder.data

		width: body.width
		height: holder.childrenRect.height
		visible: holder.visibleChildren.length > 0
		opacity: 0
		transform: Translate {
			id: shift
		}

		Item {
			id: holder

			width: parent.width
		}

		states: State {
			name: "in"
			when: root.shown
			PropertyChanges {
				line.opacity: 1
				shift.y: 0
			}
		}
		transitions: [
			Transition {
				to: "in"
				SequentialAnimation {
					PropertyAction {
						target: shift
						property: "y"
						value: 8
					}
					PauseAnimation {
						duration: 40 + line.order * 45
					}
					ParallelAnimation {
						NumberAnimation {
							target: line
							property: "opacity"
							duration: 220
						}
						NumberAnimation {
							target: shift
							property: "y"
							duration: 420
							easing.type: Easing.OutBack
						}
					}
				}
			},
			Transition {
				from: "in"
				NumberAnimation {
					target: line
					property: "opacity"
					duration: 90
				}
			}
		]
	}

	anchor.window: root.bar
	anchor.rect.x: {
		if (!root.target) return 0;
		const p = root.target.mapToItem(null, root.target.width / 2, 0);
		return Math.round(p.x - root.implicitWidth / 2);
	}
	anchor.rect.y: Theme.barHeight + 4
	anchor.adjustment: PopupAdjustment.SlideX
	implicitWidth: 284
	implicitHeight: body.implicitHeight + 28
	color: "transparent"
	visible: root.shown || card.opacity > 0.01

	Rectangle {
		id: card

		anchors.fill: parent
		anchors.margins: 4
		radius: Theme.radius.large
		color: Theme.layer2
		border.width: 1
		border.color: Qt.alpha(root.accent, 0.25)
		opacity: root.shown ? 1 : 0
		scale: root.shown ? 1 : 0.92
		transformOrigin: Item.Top
		transform: Translate {
			y: root.shown ? 0 : -8

			Behavior on y {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on border.color {
			ColorAnim {}
		}

		// a soft light of the tone from the top
		Rectangle {
			anchors.fill: parent
			radius: parent.radius
			opacity: 0.5
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.alpha(root.accent, 0.16)
				}
				GradientStop {
					position: 0.6
					color: "transparent"
				}
			}
		}

		Column {
			id: body

			x: 14
			y: 14
			width: parent.width - 28
			spacing: 10

			Line {
				order: 0

				Item {
					width: parent.width
					height: 40

					Rectangle {
						id: tile

						width: 40
						height: 40
						radius: 12
						color: Qt.alpha(root.accent, 0.16)

						Glyph {
							anchors.centerIn: parent
							icon: root.src?.glyph ?? "help"
							size: 21
							color: root.accent
						}
					}

					Column {
						anchors.left: tile.right
						anchors.leftMargin: 10
						anchors.right: big.left
						anchors.rightMargin: 8
						anchors.verticalCenter: parent.verticalCenter
						spacing: 0

						StyledText {
							width: parent.width
							text: root.src?.name ?? ""
							font.weight: Font.DemiBold
						}

						StyledText {
							width: parent.width
							text: (Live.groups.find(each => each.id === root.src?.group)?.name ?? "")
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}

					RollText {
						id: big

						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						text: root.src?.text ?? ""
						tone: ["warn", "bad", "good"].includes(root.src?.tone) ? root.toneColor : Theme.text
						pixelSize: Theme.size.heading + 2
						weight: Font.Bold
						maximumWidth: 130
						alignment: Qt.AlignRight
					}
				}
			}

			Line {
				order: 1

				StyledText {
					visible: (root.src?.detail ?? "") !== ""
					width: parent.width
					text: root.src?.detail ?? ""
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			Line {
				order: 2

				Rectangle {
					visible: !!root.src?.history
					width: parent.width
					height: 62
					radius: 10
					color: Theme.layer1
					clip: true

					Sparkline {
						anchors.fill: parent
						anchors.topMargin: 8
						values: root.shown ? (root.src?.history ?? []) : []
						maximum: root.src?.maximum ?? 0
						color: root.accent
					}
				}
			}

			Line {
				order: 2

				Item {
					visible: !root.src?.history && (root.src?.level ?? -1) >= 0
					width: parent.width
					height: 8

					Rectangle {
						anchors.fill: parent
						radius: 4
						color: Theme.layer3
					}

					Rectangle {
						id: fill

						width: root.shown ? parent.width * Math.max(0.02, Math.min(1, root.src?.level ?? 0)) : 0
						height: parent.height
						radius: 4
						gradient: Gradient {
							orientation: Gradient.Horizontal
							GradientStop {
								position: 0
								color: Qt.alpha(root.accent, 0.6)
							}
							GradientStop {
								position: 1
								color: root.accent
							}
						}

						Behavior on width {
							NumberAnimation {
								duration: 700
								easing.type: Easing.OutCubic
							}
						}

						// a sheen running over it while it moves
						Rectangle {
							id: sheen

							visible: root.src?.pulse ?? false
							width: 28
							height: parent.height
							radius: parent.radius
							opacity: 0.5
							gradient: Gradient {
								orientation: Gradient.Horizontal
								GradientStop {
									position: 0
									color: "transparent"
								}
								GradientStop {
									position: 0.5
									color: Qt.alpha("white", 0.7)
								}
								GradientStop {
									position: 1
									color: "transparent"
								}
							}

							NumberAnimation on x {
								running: sheen.visible && root.shown
								loops: Animation.Infinite
								from: -28
								to: fill.width
								duration: 1400
								easing.type: Easing.InOutQuad
							}
						}
					}
				}
			}

			Line {
				order: 3

				Row {
					visible: root.hint !== ""
					spacing: 6

					Glyph {
						anchors.verticalCenter: parent.verticalCenter
						icon: "cursor_default_click_outline"
						size: 13
						color: Theme.textSubtle
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: root.hint
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.tiny
					}
				}
			}
		}
	}
}
