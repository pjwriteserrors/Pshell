pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The inside of the game haptics, live (gamefeel.py, while the page
// watches): the detector's numbers, the presses' open windows, every onset
// with its verdict and the reason, and the game's learned sounds. Folded
// until wanted.
ColumnLayout {
	id: root

	property bool open: false
	readonly property var meter: Mouse.meter ?? ({})
	readonly property var gate: Mouse.gate ?? ({ duty: 0, held: [], windows: [] })
	readonly property var clusters: Array.isArray(Mouse.learning?.clusters) ? Mouse.learning.clusters : []
	readonly property var eyes: Mouse.eyes ?? ({})

	spacing: 8

	function stateColor(state) {
		return { yours: Theme.primary, world: Theme.textFaint, muted: Theme.textFaint, "new": Theme.textSubtle }[state] ?? Theme.textSubtle;
	}

	function verdictName(onset) {
		if (onset.felt) return onset.kind === "blast" ? "Blast" : "Felt";
		return { yes: "Yours", no: "World", "new": "New" }[onset.verdict] ?? onset.verdict;
	}

	Clickable {
		Layout.fillWidth: true
		Layout.leftMargin: 10
		implicitHeight: 28
		onClicked: root.open = !root.open

		RowLayout {
			anchors.fill: parent
			spacing: 8

			Glyph {
				icon: root.open ? "chevron_down" : "chevron_right"
				size: 16
				color: Theme.textSubtle
			}

			StyledText {
				text: "Inside – what it hears, and why it decides as it does"
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				tone: Theme.textSubtle
			}

			Item {
				Layout.fillWidth: true
			}

			StyledText {
				visible: !root.open && Mouse.onsets.length > 0
				text: `${Mouse.onsets.length} onsets logged`
				font.pixelSize: Theme.size.small
				tone: Theme.textFaint
			}
		}
	}

	ColumnLayout {
		Layout.fillWidth: true
		Layout.leftMargin: 10
		visible: root.open
		spacing: 10

		// ── the detector's numbers ─────────────────────────────────────
		Flow {
			Layout.fillWidth: true
			spacing: 8

			Repeater {
				model: [
					{ label: "flux now", value: root.meter.flux ?? 0, hint: "rises in the log spectrum against the frame before (steady ≈ 0, far footstep ≈ 7, bullet ≈ 60, shot ≈ 100)" },
					{ label: "bar", value: root.meter.bar ?? 0, hint: "the flux an onset has to cross: 3..12 by sensitivity, × the game's own threshold, raised while the quiet frames are restless" },
					{ label: "level", value: `${root.meter.db ?? 0} dB`, hint: "the last 20 ms" },
					{ label: "loud moments", value: `${root.meter.loud ?? 0} dB`, hint: "the 95th percentile of the last 10 s: strength is measured against it" },
					{ label: "threshold", value: `×${root.meter.gain ?? 1}`, hint: "learned per game: up on an absurd raw rate, down when nothing comes" },
					{ label: "windows open", value: `${Math.round((root.gate.duty ?? 0) * 100)} %`, hint: "share of the time a press of yours is fresh – a known sound must be inside more often than this + 30 %" },
					{ label: "picture moved", value: `${root.eyes.latest?.dx ?? 0}, ${root.eyes.latest?.dy ?? 0} px`, hint: "how far the whole picture shifted against the frame before (192 px wide); a jolt of 1.5 px and back while the mouse rests is a shake" },
					{ label: "red / bright", value: `${root.eyes.latest?.dred ?? 0} / ${root.eyes.latest?.dbright ?? 0}`, hint: "the frame's change in redness and brightness (0..255): +10 red is a hit, +25 bright a flash" },
					{ label: "HUD cells", value: `${root.eyes.hud?.yours?.length ?? 0} of ${root.eyes.hud?.cells ?? 0}`, hint: "cells of the picture seen changing; yours: those that change (nearly) only after a press and not all the time" }
				]

				delegate: Rectangle {
					id: tile

					required property var modelData

					width: tileRow.implicitWidth + 20
					height: 30
					radius: 15
					color: Theme.layer2

					RowLayout {
						id: tileRow

						anchors.centerIn: parent
						spacing: 6

						StyledText {
							text: tile.modelData.label
							font.pixelSize: Theme.size.small
							tone: Theme.textFaint
						}

						StyledText {
							text: String(tile.modelData.value)
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}
					}

					HoverHandler {
						id: hover
					}

					Rectangle {
						visible: hover.hovered
						anchors.top: parent.bottom
						anchors.topMargin: 4
						width: Math.min(360, hintText.implicitWidth + 16)
						height: hintText.implicitHeight + 10
						radius: Theme.radius.small
						color: Theme.layer3
						z: 10

						StyledText {
							id: hintText

							anchors.centerIn: parent
							width: Math.min(344, implicitWidth)
							text: tile.modelData.hint
							font.pixelSize: Theme.size.small
							tone: Theme.textSubtle
							wrapMode: Text.WordWrap
						}
					}
				}
			}
		}

		// ── the presses' windows ───────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				text: "Windows"
				font.pixelSize: Theme.size.small
				tone: Theme.textFaint
			}

			StyledText {
				visible: (root.gate.windows ?? []).length === 0 && (root.gate.held ?? []).length === 0
				text: "none open – a sound now is the world's unless it is a blast"
				font.pixelSize: Theme.size.small
				tone: Theme.textFaint
			}

			Repeater {
				model: root.gate.windows ?? []

				delegate: Rectangle {
					id: win

					required property var modelData

					width: winRow.implicitWidth + 16
					height: 24
					radius: 12
					color: Theme.primarySoft

					RowLayout {
						id: winRow

						anchors.centerIn: parent
						spacing: 4

						StyledText {
							text: win.modelData.key
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
							color: Theme.primary
						}

						StyledText {
							text: `${win.modelData.age} s of ${win.modelData.window} s`
							font.pixelSize: Theme.size.small
							color: Theme.primary
						}
					}
				}
			}

			Repeater {
				model: root.gate.held ?? []

				delegate: Rectangle {
					id: held

					required property var modelData

					width: heldText.implicitWidth + 16
					height: 24
					radius: 12
					color: Theme.primary

					StyledText {
						id: heldText

						anchors.centerIn: parent
						text: `${held.modelData} held`
						font.pixelSize: Theme.size.small
						color: Theme.onPrimary
					}
				}
			}

			Item {
				Layout.fillWidth: true
			}
		}

		// ── every onset, newest first ──────────────────────────────────
		Rectangle {
			Layout.fillWidth: true
			implicitHeight: onsetList.implicitHeight + 16
			radius: Theme.radius.large
			color: Theme.layer1

			ColumnLayout {
				id: onsetList

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 8
				spacing: 2

				StyledText {
					visible: Mouse.onsets.length === 0
					text: Mouse.rumbling ? "Nothing started in the game's sound yet" : "Not listening – game haptics are off, or no game has the focus"
					font.pixelSize: Theme.size.small
					tone: Theme.textFaint
				}

				Repeater {
					model: Mouse.onsets.slice(0, 14)

					delegate: RowLayout {
						id: row

						required property var modelData
						required property int index

						Layout.fillWidth: true
						spacing: 8
						opacity: 1 - row.index * 0.05

						Rectangle {
							Layout.preferredWidth: 8
							Layout.preferredHeight: 8
							radius: 4
							color: row.modelData.felt ? Theme.primary : "transparent"
							border.width: row.modelData.felt ? 0 : 1
							border.color: Theme.outline
						}

						Rectangle {
							Layout.preferredWidth: 52
							Layout.preferredHeight: 20
							radius: 10
							color: row.modelData.felt ? Theme.primarySoft : Theme.layer2

							StyledText {
								anchors.centerIn: parent
								text: root.verdictName(row.modelData)
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
								color: row.modelData.felt ? Theme.primary : Theme.textSubtle
							}
						}

						Glyph {
							icon: row.modelData.source === "eyes" ? "eye_outline" : "volume_high"
							size: 13
							color: Theme.textFaint
						}

						StyledText {
							Layout.preferredWidth: 150
							text: row.modelData.source === "eyes" ? `${row.modelData.kind}${row.modelData.cluster >= 0 ? " · cell " + row.modelData.cluster : ""}` : `${row.modelData.kind} #${row.modelData.cluster} · ${row.modelData.win}/${row.modelData.n} in windows`
							font.pixelSize: Theme.size.small
							tone: Theme.textSubtle
							elide: Text.ElideRight
						}

						StyledText {
							Layout.preferredWidth: 150
							text: `${row.modelData.strength} · ${row.modelData.over > 0 ? "+" : ""}${row.modelData.over} dB · ${Math.round(row.modelData.lowness * 100)} % bass`
							font.pixelSize: Theme.size.small
							tone: Theme.textFaint
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							text: row.modelData.reason + ((row.modelData.fresh ?? []).length > 0 ? " · fresh: " + row.modelData.fresh.map(f => `${f[0]} ${f[1]} s`).join(", ") : "")
							font.pixelSize: Theme.size.small
							tone: row.modelData.felt ? Theme.text : Theme.textSubtle
							elide: Text.ElideRight
						}
					}
				}
			}
		}

		// ── the game's sounds, as learned ──────────────────────────────
		StyledText {
			visible: root.clusters.length > 0
			text: "This game's sounds – the most heard first. Yours: nearly always inside your windows, after a key at a learned delay. World: the rest. Mute what is wrong."
			font.pixelSize: Theme.size.small
			tone: Theme.textFaint
			wrapMode: Text.WordWrap
			Layout.fillWidth: true
		}

		Repeater {
			model: root.clusters

			delegate: RowLayout {
				id: crow

				required property var modelData

				Layout.fillWidth: true
				spacing: 8

				Rectangle {
					Layout.preferredWidth: 58
					Layout.preferredHeight: 20
					radius: 10
					color: crow.modelData.state === "yours" ? Theme.primarySoft : Theme.layer2

					StyledText {
						anchors.centerIn: parent
						text: crow.modelData.state
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
						color: root.stateColor(crow.modelData.state)
					}
				}

				StyledText {
					Layout.preferredWidth: 36
					text: `#${crow.modelData.id}`
					font.pixelSize: Theme.size.small
					tone: Theme.textSubtle
				}

				StyledText {
					Layout.preferredWidth: 210
					text: `${crow.modelData.n}× · ${Math.round(crow.modelData.share * 100)} % in windows · ${crow.modelData.lvl > 0 ? "+" : ""}${crow.modelData.lvl} dB`
					font.pixelSize: Theme.size.small
					tone: Theme.textSubtle
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					text: (crow.modelData.keys ?? []).map(k => `${k.key} +${k.lag} s ×${k.times}`).join("  ·  ") || "after no press"
					font.pixelSize: Theme.size.small
					tone: Theme.text
					elide: Text.ElideRight
				}

				IconButton {
					Layout.preferredWidth: 26
					Layout.preferredHeight: 26
					visible: crow.modelData.state !== "muted"
					icon: "volume_off"
					onClicked: Mouse.muteSound(crow.modelData.id)
				}
			}
		}
	}
}
