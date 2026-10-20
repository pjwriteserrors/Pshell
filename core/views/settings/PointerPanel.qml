pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Nodes.js" as Nodes

// The settings of one kind of pointing device (touchpad, mouse, trackpoint,
// trackball) – only the ones niri knows for it. libinput applies them to
// every device of that kind.
ColumnLayout {
	id: root

	property string device: "touchpad"
	property bool active: true
	readonly property bool isTouchpad: root.device === "touchpad"
	readonly property bool hasScrollFactor: root.device === "touchpad" || root.device === "mouse"
	readonly property var section: NiriSettings.node(["input", root.device])

	function p(name) {
		return ["input", root.device].concat([].concat(name));
	}

	function flag(name) {
		return NiriSettings.flag(root.p(name));
	}

	function setFlag(name, on, label) {
		NiriSettings.setFlag(root.p(name), on, `${label} ${on ? "on" : "off"}`);
	}

	readonly property string scrollMethod: String(NiriSettings.arg(root.p("scroll-method"), root.isTouchpad ? "two-finger" : (root.device === "mouse" ? "no-scroll" : "on-button-down")))
	readonly property var scrollFactor: NiriSettings.node(root.p("scroll-factor"))
	readonly property bool splitFactor: !!root.scrollFactor && (root.scrollFactor.props?.horizontal !== undefined || root.scrollFactor.props?.vertical !== undefined)

	spacing: 14

	FlagRow {
		title: "Use it"
		subtitle: root.flag("off") ? "Switched off – it sends nothing" : "Switch off to ignore every device of this kind"
		icon: "power"
		checked: !root.flag("off")
		onToggled: on => root.setFlag("off", !on, root.device)
	}

	ColumnLayout {
		Layout.fillWidth: true
		spacing: 14
		enabled: !root.flag("off")
		opacity: root.flag("off") ? 0.4 : 1

		Behavior on opacity {
			Anim {}
		}

		// speed and acceleration
		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			AccelCurve {
				Layout.preferredWidth: 230
				Layout.preferredHeight: 150
				speed: Number(NiriSettings.arg(root.p("accel-speed"), 0))
				flat: String(NiriSettings.arg(root.p("accel-profile"), "adaptive")) === "flat"
				onMoved: v => NiriSettings.set(root.p("accel-speed"), v, `Pointer speed ${v.toFixed(2)}`, `${root.device}-accel`)
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 10

				StyledText {
					text: "Speed and acceleration"
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: "Drag the curve up for faster, down for slower. Flat moves the pointer as far as the hand, at any pace – what many gamers like."
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}

				Segmented {
					Layout.preferredWidth: 240
					options: [{ value: "adaptive", label: "Adaptive", icon: "chart_bell_curve_cumulative" }, { value: "flat", label: "Flat", icon: "chart_line_variant" }]
					current: String(NiriSettings.arg(root.p("accel-profile"), "adaptive"))
					onSelected: value => value === "adaptive" ? NiriSettings.reset(root.p("accel-profile"), "Adaptive acceleration") : NiriSettings.set(root.p("accel-profile"), value, "Flat acceleration", "")
				}

				ResetPill {
					shown: NiriSettings.has(root.p("accel-speed"))
					text: "Normal speed"
					onClicked: NiriSettings.reset(root.p("accel-speed"))
				}
			}
		}

		FlagRow {
			title: "Natural scrolling"
			subtitle: "The page moves with your fingers, like on a phone"
			checked: root.flag("natural-scroll")
			onToggled: on => root.setFlag("natural-scroll", on, "Natural scrolling")

			ScrollDemo {
				anchors.fill: parent
				natural: root.flag("natural-scroll")
				playing: root.active
			}
		}

		// ── touchpad: tapping and typing ────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			visible: root.isTouchpad
			spacing: 0

			FlagRow {
				title: "Tap to click"
				subtitle: "A light tap is a click"
				checked: root.flag("tap")
				onToggled: on => root.setFlag("tap", on, "Tap to click")

				Item {
					anchors.fill: parent

					Rectangle {
						anchors.centerIn: parent
						width: 56
						height: 38
						radius: 6
						color: Theme.layer2
					}

					Rectangle {
						id: tapDot

						anchors.centerIn: parent
						width: 10
						height: 10
						radius: 5
						color: Theme.primary

						SequentialAnimation on scale {
							running: root.active && root.flag("tap")
							loops: Animation.Infinite

							NumberAnimation {
								from: 1
								to: 2.2
								duration: 380
								easing.type: Easing.OutCubic
							}
							NumberAnimation {
								to: 1
								duration: 300
							}
							PauseAnimation {
								duration: 700
							}
						}
					}
				}
			}

			FlagRow {
				title: "Tap and drag"
				subtitle: "Tap, then keep the finger down to drag"
				checked: NiriSettings.arg(root.p("drag"), true) !== false
				onToggled: on => NiriSettings.setBool(root.p("drag"), on, true, `Tap and drag ${on ? "on" : "off"}`)
			}

			FlagRow {
				title: "Drag lock"
				subtitle: "Lifting the finger for a moment does not drop what you drag"
				checked: root.flag("drag-lock")
				onToggled: on => root.setFlag("drag-lock", on, "Drag lock")
			}

			FlagRow {
				title: "Off while typing"
				subtitle: "The palm on the touchpad does not move the pointer (dwt)"
				icon: "keyboard_outline"
				checked: root.flag("dwt")
				onToggled: on => root.setFlag("dwt", on, "Off while typing")
			}

			FlagRow {
				title: "Off while using the trackpoint"
				subtitle: "dwtp"
				icon: "circle_small"
				checked: root.flag("dwtp")
				onToggled: on => root.setFlag("dwtp", on, "Off while using the trackpoint")
			}

			FlagRow {
				title: "Off while a mouse is plugged in"
				subtitle: "disabled-on-external-mouse"
				icon: "mouse_variant"
				checked: root.flag("disabled-on-external-mouse")
				onToggled: on => root.setFlag("disabled-on-external-mouse", on, "Off with a mouse")
			}
		}

		// which button two and three fingers press
		ColumnLayout {
			Layout.fillWidth: true
			visible: root.isTouchpad
			spacing: 8

			SectionLabel {
				text: "Tapping with more fingers"
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				Repeater {
					model: [
						{ value: "left-right-middle", two: "Right", three: "Middle" },
						{ value: "left-middle-right", two: "Middle", three: "Right" }
					]

					delegate: OptionTile {
						id: mapTile

						required property var modelData

						title: `Two fingers: ${mapTile.modelData.two.toLowerCase()} click`
						selected: String(NiriSettings.arg(root.p("tap-button-map"), "left-right-middle")) === mapTile.modelData.value
						onClicked: NiriSettings.set(root.p("tap-button-map"), mapTile.modelData.value, "Finger buttons changed", "")

						Column {
							anchors.centerIn: parent
							spacing: 6

							Repeater {
								model: [{ n: 1, b: "Left" }, { n: 2, b: mapTile.modelData.two }, { n: 3, b: mapTile.modelData.three }]

								delegate: Row {
									id: fingers

									required property var modelData

									spacing: 8

									Row {
										width: 34
										spacing: 3

										Repeater {
											model: fingers.modelData.n

											delegate: Rectangle {
												width: 8
												height: 12
												radius: 4
												color: Theme.text
											}
										}
									}

									Glyph {
										icon: "arrow_right"
										size: 12
										color: Theme.textSubtle
									}

									StyledText {
										text: fingers.modelData.b
										tone: fingers.modelData.n > 1 ? Theme.primary : Theme.textMuted
										font.pixelSize: Theme.size.small
										font.weight: Font.DemiBold
									}
								}
							}
						}
					}
				}
			}

			SectionLabel {
				Layout.topMargin: 6
				text: "Clicking the pad down"
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				OptionTile {
					title: "Zones"
					subtitle: "Bottom right is right click"
					selected: String(NiriSettings.arg(root.p("click-method"), "button-areas")) === "button-areas"
					onClicked: NiriSettings.set(root.p("click-method"), "button-areas", "Click by zones", "")

					Rectangle {
						anchors.centerIn: parent
						width: 96
						height: 64
						radius: 8
						color: Theme.layer3

						Row {
							anchors.bottom: parent.bottom
							anchors.left: parent.left
							anchors.right: parent.right
							height: 18

							Rectangle {
								width: parent.width / 2
								height: parent.height
								color: Qt.alpha(Theme.text, 0.12)

								StyledText {
									anchors.centerIn: parent
									text: "L"
									font.pixelSize: Theme.size.tiny
								}
							}

							Rectangle {
								width: parent.width / 2
								height: parent.height
								color: Qt.alpha(Theme.primary, 0.5)

								StyledText {
									anchors.centerIn: parent
									text: "R"
									font.pixelSize: Theme.size.tiny
								}
							}
						}
					}
				}

				OptionTile {
					title: "Fingers"
					subtitle: "Two fingers anywhere is right click"
					selected: String(NiriSettings.arg(root.p("click-method"), "button-areas")) === "clickfinger"
					onClicked: NiriSettings.set(root.p("click-method"), "clickfinger", "Click by fingers", "")

					Rectangle {
						anchors.centerIn: parent
						width: 96
						height: 64
						radius: 8
						color: Theme.layer3

						Row {
							anchors.centerIn: parent
							spacing: 4

							Repeater {
								model: 2

								delegate: Rectangle {
									width: 10
									height: 15
									radius: 5
									color: Theme.primary
								}
							}
						}
					}
				}
			}
		}

		// ── scrolling ───────────────────────────────────────────────────
		SectionLabel {
			Layout.topMargin: 6
			text: "Scrolling"
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: [
					{ value: "two-finger", title: "Two fingers", show: root.isTouchpad },
					{ value: "edge", title: "Right edge", show: root.isTouchpad },
					{ value: "on-button-down", title: "Hold a button", show: true },
					{ value: "no-scroll", title: "No scrolling", show: true }
				].filter(entry => entry.show)

				delegate: OptionTile {
					id: methodTile

					required property var modelData

					title: methodTile.modelData.title
					selected: root.scrollMethod === methodTile.modelData.value
					onClicked: NiriSettings.set(root.p("scroll-method"), methodTile.modelData.value, `Scrolling: ${methodTile.modelData.title.toLowerCase()}`, "")

					property real phase: 0

					SequentialAnimation on phase {
						running: methodTile.playing && root.active
						loops: Animation.Infinite

						NumberAnimation {
							from: 0
							to: 1
							duration: 1000
							easing.type: Easing.InOutCubic
						}
						NumberAnimation {
							to: 0
							duration: 700
							easing.type: Easing.InOutCubic
						}
					}

					Rectangle {
						id: pad

						anchors.centerIn: parent
						width: 90
						height: 62
						radius: 8
						color: Theme.layer3

						// the right edge strip
						Rectangle {
							visible: methodTile.modelData.value === "edge"
							anchors.right: parent.right
							width: 14
							height: parent.height
							radius: 8
							color: Qt.alpha(Theme.primary, 0.35)
						}

						Row {
							visible: methodTile.modelData.value !== "no-scroll"
							x: methodTile.modelData.value === "edge" ? pad.width - 11 : (methodTile.modelData.value === "on-button-down" ? 50 : 34)
							y: 40 - methodTile.phase * 22
							spacing: 3

							Repeater {
								model: methodTile.modelData.value === "two-finger" ? 2 : 1

								delegate: Rectangle {
									width: 8
									height: 12
									radius: 4
									color: Theme.primary
								}
							}
						}

						// the held button
						Rectangle {
							visible: methodTile.modelData.value === "on-button-down"
							x: 12
							y: 20
							width: 22
							height: 22
							radius: 11
							color: Theme.primary
							opacity: 0.6 + 0.4 * methodTile.phase

							Glyph {
								anchors.centerIn: parent
								icon: "mouse"
								size: 13
								color: Theme.onPrimary
							}
						}

						Glyph {
							visible: methodTile.modelData.value === "no-scroll"
							anchors.centerIn: parent
							icon: "cursor_default"
							size: 18
							color: Theme.text
							anchors.horizontalCenterOffset: -20 + methodTile.phase * 40
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.scrollMethod === "on-button-down"
			spacing: 14

			ButtonCatcher {
				Layout.preferredWidth: 300
				code: Number(NiriSettings.arg(root.p("scroll-button"), 0))
				onCaught: code => code > 0 && NiriSettings.set(root.p("scroll-button"), code, `Scroll button ${code}`, "")
			}

			FlagRow {
				title: "Press once, not hold"
				subtitle: "One press starts scrolling, the next stops it"
				checked: root.flag("scroll-button-lock")
				onToggled: on => root.setFlag("scroll-button-lock", on, "Scroll button lock")
			}
		}

		// how far a scroll goes
		ColumnLayout {
			Layout.fillWidth: true
			visible: root.hasScrollFactor
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 12

				StyledText {
					Layout.preferredWidth: 110
					text: "Scroll speed"
					tone: Theme.textMuted
					font.weight: Font.Medium
				}

				ValueSlider {
					visible: !root.splitFactor
					from: 0.1
					to: 4
					step: 0.05
					decimals: 2
					icon: "mouse_move_vertical"
					value: Number(root.scrollFactor?.args?.[0] ?? 1)
					format: v => `${Number(v).toFixed(2)}×`
					onMoved: v => NiriSettings.setNode(root.p("scroll-factor"), [v], {}, `Scroll speed ${v.toFixed(2)}×`, `${root.device}-scroll`)
				}

				Chip {
					text: root.splitFactor ? "One speed" : "Across and up apart"
					icon: root.splitFactor ? "link_variant" : "link_variant_off"
					onClicked: {
						const base = Number(root.scrollFactor?.args?.[0] ?? root.scrollFactor?.props?.vertical ?? 1);
						if (root.splitFactor) NiriSettings.setNode(root.p("scroll-factor"), [base], {}, "One scroll speed", "");
						else NiriSettings.setNode(root.p("scroll-factor"), [], { horizontal: base, vertical: base }, "Scroll speeds apart", "");
					}
				}

				ResetPill {
					shown: !!root.scrollFactor
					onClicked: NiriSettings.reset(root.p("scroll-factor"))
				}
			}

			Repeater {
				model: root.splitFactor ? ["vertical", "horizontal"] : []

				delegate: RowLayout {
					id: axis

					required property string modelData

					Layout.fillWidth: true
					spacing: 12

					StyledText {
						Layout.preferredWidth: 110
						Layout.leftMargin: 20
						text: axis.modelData === "vertical" ? "↕ Up and down" : "↔ Across"
						tone: Theme.textSubtle
					}

					ValueSlider {
						from: -4
						to: 4
						step: 0.05
						decimals: 2
						value: Number(root.scrollFactor?.props?.[axis.modelData] ?? 1)
						format: v => `${Number(v).toFixed(2)}×`
						onMoved: v => {
							const props = Object.assign({}, root.scrollFactor?.props || {});
							props[axis.modelData] = v;
							NiriSettings.setNode(root.p("scroll-factor"), [], props, `Scroll speed ${axis.modelData}`, `${root.device}-scroll-${axis.modelData}`);
						}
					}
				}
			}
		}

		// ── buttons ─────────────────────────────────────────────────────
		FlagRow {
			title: "Left-handed"
			subtitle: "Left and right buttons swap"
			checked: root.flag("left-handed")
			onToggled: on => root.setFlag("left-handed", on, "Left-handed")

			Item {
				anchors.fill: parent

				Rectangle {
					anchors.centerIn: parent
					width: 30
					height: 42
					radius: 15
					color: Theme.layer2
					border.width: 1
					border.color: Theme.outline

					Rectangle {
						x: root.flag("left-handed") ? parent.width / 2 : 0
						width: parent.width / 2
						height: 16
						radius: 8
						color: Theme.primary

						Behavior on x {
							SpatialAnim {}
						}
					}
				}
			}
		}

		FlagRow {
			title: "Middle click from left + right"
			subtitle: "Pressing both buttons at once is a middle click"
			icon: "gesture_tap_button"
			checked: root.flag("middle-emulation")
			onToggled: on => root.setFlag("middle-emulation", on, "Middle click emulation")
		}
	}
}
