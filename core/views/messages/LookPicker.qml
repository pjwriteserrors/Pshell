pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// How the chats look, picked, in three parts. Background: a tile for each
// kind of backdrop – the picture of one's own is asked for with the desktop's
// file chooser – and how far it is blurred, dimmed and tinted. Bubbles: their
// corners, the colour of one's own, how far the others' let the backdrop
// through and the size of the words. Motion: how a new message comes up,
// shown by a bubble that does it. Everything shows in the chat at once.
Rectangle {
	id: root

	property bool open: false
	readonly property var look: Messages.backdrop
	readonly property bool pictured: root.look.kind === "wallpaper" || root.look.kind === "image"
	readonly property var kinds: [
		{ kind: "none", icon: "cancel" },
		{ kind: "aurora", icon: "" },
		{ kind: "waves", icon: "" },
		{ kind: "dots", icon: "" },
		{ kind: "wallpaper", icon: "wallpaper" },
		{ kind: "image", icon: "image_plus" }
	]

	// "background" | "bubbles" | "motion"
	property string tab: "background"
	readonly property var style: Messages.style

	signal done

	function choose() {
		if (!chooser.running) chooser.running = true;
	}

	implicitWidth: 320
	implicitHeight: column.implicitHeight + 24
	clip: true

	Behavior on implicitHeight {
		enabled: root.open
		SpatialAnim {
			duration: Motion.medium
		}
	}
	radius: Theme.radius.large
	color: Theme.layer1
	border.width: 1
	border.color: Theme.outline
	transformOrigin: Item.TopRight
	scale: root.open ? 1 : 0.9
	opacity: root.open ? 1 : 0
	visible: opacity > 0.01
	enabled: root.open

	Behavior on scale {
		SpatialAnim {
			duration: root.open ? Motion.medium : Motion.short
		}
	}
	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}

	// nothing under it is clicked through it
	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		onWheel: wheel => wheel.accepted = true
	}

	ColumnLayout {
		id: column

		x: 12
		y: 12
		width: parent.width - 24
		spacing: 10

		Segmented {
			Layout.fillWidth: true
			implicitHeight: 34
			current: root.tab
			options: [
				{ value: "background", label: "Background" },
				{ value: "bubbles", label: "Bubbles" },
				{ value: "motion", label: "Motion" }
			]
			onSelected: value => root.tab = value
		}

		GridLayout {
			Layout.fillWidth: true
			visible: root.tab === "background"
			columns: 3
			rowSpacing: 8
			columnSpacing: 8

			Repeater {
				model: root.kinds

				delegate: Clickable {
					id: tile

					required property var modelData
					readonly property string kind: tile.modelData.kind
					readonly property bool chosen: root.look.kind === tile.kind
					// its own picture, whatever is on the screen
					readonly property var look: Object.assign({}, root.look, { kind: tile.kind, dim: 0, tint: 0 })
					readonly property bool blank: tile.kind === "none" || (tile.kind === "image" && String(root.look.image ?? "") === "") || sample.missing

					Layout.fillWidth: true
					implicitHeight: 58
					radius: Theme.radius.medium
					pressedScale: 0.95
					color: Theme.layer2
					onClicked: {
						if (tile.kind === "image" && (tile.chosen || tile.blank)) root.choose();
						else Messages.setBackdrop({ kind: tile.kind });
					}

					ClippingRectangle {
						anchors.fill: parent
						radius: tile.radius
						color: "transparent"

						Backdrop {
							id: sample

							anchors.fill: parent
							visible: !tile.blank
							sample: true
							live: root.open
							look: tile.look
						}
					}

					Glyph {
						anchors.centerIn: parent
						visible: tile.blank
						icon: tile.modelData.icon
						size: 20
						color: Theme.textSubtle
					}

					// another picture than this one
					Rectangle {
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						anchors.margins: 5
						visible: tile.kind === "image" && tile.chosen && !tile.blank
						width: 22
						height: 22
						radius: 11
						color: Qt.rgba(0, 0, 0, 0.55)

						Glyph {
							anchors.centerIn: parent
							icon: "folder_open_outline"
							size: 13
							color: "white"
							surface: "transparent"
						}
					}

					Rectangle {
						anchors.fill: parent
						radius: tile.radius
						color: "transparent"
						border.width: 2
						border.color: Theme.primary
						opacity: tile.chosen ? 1 : 0
						scale: tile.chosen ? 1 : 1.08

						Behavior on opacity {
							Anim {
								duration: Motion.short
							}
						}
						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}
				}
			}
		}

		PillSlider {
			Layout.fillWidth: true
			implicitHeight: 36
			visible: root.tab === "background" && root.pictured
			icon: "blur"
			label: "Blur"
			value: root.look.blur ?? 0
			onMoved: value => Messages.setBackdrop({ blur: Math.round(value * 100) / 100 })
		}

		PillSlider {
			Layout.fillWidth: true
			implicitHeight: 36
			visible: root.tab === "background" && root.look.kind !== "none"
			icon: "brightness_6"
			label: "Dim"
			value: root.look.dim ?? 0
			onMoved: value => Messages.setBackdrop({ dim: Math.round(value * 100) / 100 })
		}

		PillSlider {
			Layout.fillWidth: true
			implicitHeight: 36
			visible: root.tab === "background" && root.look.kind !== "none"
			icon: "palette"
			label: "Tint"
			value: root.look.tint ?? 0
			onMoved: value => Messages.setBackdrop({ tint: Math.round(value * 100) / 100 })
		}

		// ── bubbles ──────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			visible: root.tab === "bubbles"
			spacing: 8

			Repeater {
				model: [
					{ shape: "round", radius: Theme.radius.large },
					{ shape: "soft", radius: 10 },
					{ shape: "sharp", radius: 4 }
				]

				delegate: Clickable {
					id: shape

					required property var modelData
					readonly property bool chosen: root.style.shape === shape.modelData.shape

					Layout.fillWidth: true
					implicitHeight: 58
					radius: Theme.radius.medium
					pressedScale: 0.95
					color: Theme.layer2
					border.width: 2
					border.color: shape.chosen ? Theme.primary : "transparent"
					onClicked: Messages.setStyle({ shape: shape.modelData.shape })

					Behavior on border.color {
						ColorAnim {}
					}

					Rectangle {
						x: 12
						y: 11
						width: parent.width * 0.5
						height: 15
						radius: Math.min(shape.modelData.radius, height / 2)
						color: Theme.layer3
					}

					Rectangle {
						anchors.right: parent.right
						anchors.rightMargin: 12
						y: 31
						width: parent.width * 0.42
						height: 15
						radius: Math.min(shape.modelData.radius, height / 2)
						color: Messages.accent
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.tab === "bubbles"
			spacing: 8

			Repeater {
				model: [
					{ accent: "primary", color: Theme.primary },
					{ accent: "secondary", color: Theme.secondary },
					{ accent: "tertiary", color: Theme.tertiary }
				]

				delegate: Clickable {
					id: swatch

					required property var modelData
					readonly property bool chosen: root.style.accent === swatch.modelData.accent

					implicitWidth: 36
					implicitHeight: 36
					radius: swatch.chosen ? Theme.radius.medium : 18
					pressedScale: 0.9
					color: swatch.modelData.color
					onClicked: Messages.setStyle({ accent: swatch.modelData.accent })

					Behavior on radius {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Glyph {
						anchors.centerIn: parent
						icon: "check"
						size: 18
						color: Theme.bg
						surface: swatch.color
						scale: swatch.chosen ? 1 : 0

						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}
				}
			}

			Item {
				Layout.fillWidth: true
			}

			Chip {
				implicitHeight: 34
				icon: "gradient_horizontal"
				text: "Gradient"
				selected: root.style.gradient ?? false
				accent: Messages.accent
				onClicked: Messages.setStyle({ gradient: !root.style.gradient })
			}
		}

		PillSlider {
			Layout.fillWidth: true
			implicitHeight: 36
			visible: root.tab === "bubbles"
			icon: "palette"
			label: "Colour"
			accent: Messages.accent
			value: root.style.colour ?? 0.45
			onMoved: value => Messages.setStyle({ colour: Math.round(value * 100) / 100 })
		}

		PillSlider {
			Layout.fillWidth: true
			implicitHeight: 36
			visible: root.tab === "bubbles"
			icon: "opacity"
			label: "Glass"
			value: root.style.glass ?? 0
			onMoved: value => Messages.setStyle({ glass: Math.round(value * 100) / 100 })
		}

		Segmented {
			Layout.fillWidth: true
			implicitHeight: 34
			visible: root.tab === "bubbles"
			current: root.style.size ?? "medium"
			options: [
				{ value: "small", label: "Small", icon: "format_size" },
				{ value: "medium", label: "Medium" },
				{ value: "large", label: "Large" }
			]
			onSelected: value => Messages.setStyle({ size: value })
		}

		// ── motion ───────────────────────────────────────────────────────
		// a bubble that comes up the way that is picked
		Rectangle {
			Layout.fillWidth: true
			visible: root.tab === "motion"
			implicitHeight: 64
			radius: Theme.radius.medium
			color: Theme.layer2
			clip: true

			Rectangle {
				id: sampleBubble

				anchors.verticalCenter: parent.verticalCenter
				x: parent.width - width - 14
				width: 150
				height: 34
				radius: Math.min(Messages.bubbleRadius, height / 2)
				color: Messages.accent
				transformOrigin: Item.BottomRight
				transform: Translate {
					id: sampleSlide
				}

				TypingDots {
					anchors.centerIn: parent
					tone: Theme.bg
					running: root.open && root.tab === "motion"
				}
			}

			SequentialAnimation {
				id: sampleRun

				running: root.open && root.tab === "motion"
				loops: Animation.Infinite

				ParallelAnimation {
					Anim {
						target: sampleBubble
						property: "opacity"
						from: root.style.arrival === "none" ? 1 : 0
						to: 1
						duration: root.style.arrival === "fade" ? Motion.long : Motion.short
					}
					SpatialAnim {
						target: sampleBubble
						property: "scale"
						from: root.style.arrival === "pop" ? 0.7 : 1
						to: 1
					}
					SpatialAnim {
						target: sampleSlide
						property: "x"
						from: root.style.arrival === "slide" ? 60 : 0
						to: 0
					}
				}
				PauseAnimation {
					duration: 1400
				}
			}
		}

		Segmented {
			Layout.fillWidth: true
			implicitHeight: 34
			visible: root.tab === "motion"
			current: root.style.arrival ?? "pop"
			options: [
				{ value: "pop", label: "Pop" },
				{ value: "slide", label: "Slide" },
				{ value: "fade", label: "Fade" },
				{ value: "none", label: "None" }
			]
			onSelected: value => {
				Messages.setStyle({ arrival: value });
				sampleRun.restart();
			}
		}

		SettingSwitch {
			visible: root.tab === "motion"
			icon: "party_popper"
			text: "Emoji effects"
			checked: root.style.effects ?? true
			onToggled: checked => Messages.setStyle({ effects: checked })
		}

		SettingSwitch {
			visible: root.tab === "motion" && root.look.kind !== "none"
			icon: "animation"
			text: "Moving background"
			checked: root.look.motion ?? true
			onToggled: checked => Messages.setBackdrop({ motion: checked })
		}
	}

	Shortcut {
		sequence: "Escape"
		enabled: root.open
		onActivated: root.done()
	}

	// the desktop's own file chooser
	Process {
		id: chooser

		command: ["python3", `${Paths.scripts}/pick_files.py`, "Chat background"]
		stdout: SplitParser {
			onRead: line => {
				if (/\.(png|jpe?g|webp|bmp|gif|avif|svg)$/i.test(line)) Messages.setBackdrop({ kind: "image", image: line });
			}
		}
	}
}
