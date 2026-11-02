pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../../lib/GameText.js" as GameText

// What is known about the picked game at a glance, on glass: the hours it
// was played, when last, how far along (a ring against HowLongToBeat or the
// achievements), the achievements, and the last four weeks a bar a day.
// Numbers roll from the last game's to this one's, the ring turns, the bars
// rise one after another. The stats are asked once the game stays picked.
Rectangle {
	id: root

	property var game: null
	property color accent: Theme.primary
	// the bar's panel: smaller, two weeks of bars, no achievements cell
	property bool compact: false

	readonly property var stats: root.game ? (Games.statsOf(root.game.id)) : null
	readonly property real minutes: Math.max(root.game?.playtime ?? 0, root.stats?.playtime ?? 0)
	readonly property var progress: GameText.progress(root.stats, root.minutes)
	readonly property var trophies: root.stats?.achievements ?? null
	readonly property var days: {
		const all = root.stats?.days ?? [];
		return root.compact ? all.slice(-14) : all;
	}
	readonly property real recent: root.days.reduce((sum, value) => sum + value, 0)
	readonly property real dayMax: Math.max(45, ...root.days)

	signal statsAsked

	onGameChanged: if (root.game) Games.peekStats(root.game.id)

	implicitWidth: row.implicitWidth + (root.compact ? 28 : 36)
	implicitHeight: root.compact ? 64 : 84
	radius: root.compact ? 18 : 22
	color: Qt.rgba(0, 0, 0, 0.32)
	border.width: 1
	border.color: Qt.rgba(1, 1, 1, 0.09)

	// rolls from the number before
	property real minutesShown: root.minutes

	Behavior on minutesShown {
		NumberAnimation {
			duration: 800
			easing.type: Easing.OutCubic
		}
	}

	// a soft line of the accent along the top edge
	Rectangle {
		anchors.top: parent.top
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.topMargin: -0.5
		width: parent.width * 0.6
		height: 1.5
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop {
				position: 0
				color: "transparent"
			}
			GradientStop {
				position: 0.5
				color: Qt.alpha(root.accent, 0.8)
			}
			GradientStop {
				position: 1
				color: "transparent"
			}
		}
	}

	MouseArea {
		anchors.fill: parent
		cursorShape: Qt.PointingHandCursor
		onClicked: root.statsAsked()
	}

	RowLayout {
		id: row

		anchors.centerIn: parent
		spacing: root.compact ? 16 : 22

		// ── played ─────────────────────────────────────────────────────────
		Cell {
			value: GameText.short(root.minutesShown)
			label: root.minutes > 0 ? "played" : "not played yet"
			valueTone: root.minutes > 0 ? "white" : Qt.rgba(1, 1, 1, 0.5)
		}

		Divider {}

		// ── last played ────────────────────────────────────────────────────
		Cell {
			value: Games.isRunning(root.game?.id ?? "") ? "Now" : (GameText.when(root.game?.lastPlayed ?? 0) || "Never")
			label: Games.isRunning(root.game?.id ?? "") ? "playing" : "last played"
			valueTone: Games.isRunning(root.game?.id ?? "") ? Theme.success : "white"
		}

		// ── how far along ──────────────────────────────────────────────────
		Divider {
			visible: root.progress !== null
		}

		RowLayout {
			visible: root.progress !== null
			spacing: 10

			Item {
				id: ring

				readonly property real size: root.compact ? 38 : 50
				property real share: root.progress?.share ?? 0

				Layout.preferredWidth: ring.size
				Layout.preferredHeight: ring.size

				Behavior on share {
					NumberAnimation {
						duration: 900
						easing.type: Easing.OutCubic
					}
				}

				Shape {
					anchors.fill: parent
					preferredRendererType: Shape.CurveRenderer

					ShapePath {
						strokeColor: Qt.rgba(1, 1, 1, 0.1)
						strokeWidth: root.compact ? 4 : 5
						fillColor: "transparent"
						capStyle: ShapePath.RoundCap

						PathAngleArc {
							centerX: ring.size / 2
							centerY: ring.size / 2
							radiusX: ring.size / 2 - 3
							radiusY: ring.size / 2 - 3
							startAngle: 0
							sweepAngle: 360
						}
					}

					ShapePath {
						strokeColor: root.progress?.share >= 1 ? Theme.success : root.accent
						strokeWidth: root.compact ? 4 : 5
						fillColor: "transparent"
						capStyle: ShapePath.RoundCap

						PathAngleArc {
							centerX: ring.size / 2
							centerY: ring.size / 2
							radiusX: ring.size / 2 - 3
							radiusY: ring.size / 2 - 3
							startAngle: -90
							sweepAngle: Math.max(0.01, 360 * ring.share)
						}
					}
				}

				StyledText {
					anchors.centerIn: parent
					text: root.progress?.share >= 1 ? "✓" : `${Math.round(ring.share * 100)}`
					tone: "white"
					surface: "transparent"
					tabular: true
					font.pixelSize: root.compact ? 12 : 15
					font.weight: Font.Black
				}
			}

			Cell {
				value: {
					const known = root.progress;
					if (!known) return "";
					if (known.goal === "done") return "Beaten";
					if (known.left < 0) return `${Math.round(known.share * 100)} %`;
					return known.left > 0 ? `${GameText.short(known.left * 60)} to go` : "Past it";
				}
				label: root.progress?.label ?? ""
			}
		}

		// ── achievements ───────────────────────────────────────────────────
		Divider {
			visible: !root.compact && root.trophies !== null && root.progress?.label !== "achievements"
		}

		RowLayout {
			visible: !root.compact && root.trophies !== null && root.progress?.label !== "achievements"
			spacing: 10

			Glyph {
				icon: "trophy"
				size: 24
				color: "#f4c25b"
				surface: "transparent"
			}

			Cell {
				value: root.trophies ? `${root.trophies.got} / ${root.trophies.total}` : ""
				label: "achievements"
			}
		}

		// ── the last weeks ─────────────────────────────────────────────────
		Divider {
			visible: root.recent > 0
		}

		ColumnLayout {
			visible: root.recent > 0
			spacing: 4

			Row {
				id: bars

				Layout.preferredHeight: root.compact ? 22 : 30
				spacing: 2

				Repeater {
					model: root.days.length

					delegate: Rectangle {
						id: bar

						required property int index
						readonly property real minutes: root.days[bar.index] ?? 0

						anchors.bottom: parent.bottom
						width: root.compact ? 5 : 4
						radius: 1.5
						height: Math.max(2, bars.height * Math.min(1, bar.minutes / root.dayMax))
						color: bar.minutes > 0 ? Qt.alpha(root.accent, 0.45 + 0.55 * Math.min(1, bar.minutes / root.dayMax)) : Qt.rgba(1, 1, 1, 0.12)

						Behavior on height {
							NumberAnimation {
								duration: 420 + bar.index * 14
								easing.type: Easing.OutBack
								easing.overshoot: 1.2
							}
						}
					}
				}
			}

			StyledText {
				text: `${GameText.short(root.recent)} · ${root.compact ? "2" : "4"} weeks`
				tone: Qt.rgba(1, 1, 1, 0.55)
				surface: "transparent"
				font.pixelSize: Theme.size.tiny
			}
		}
	}

	component Divider: Rectangle {
		Layout.preferredWidth: 1
		Layout.preferredHeight: root.compact ? 28 : 38
		color: Qt.rgba(1, 1, 1, 0.12)
	}

	component Cell: ColumnLayout {
		property string value: ""
		property string label: ""
		property color valueTone: "white"

		spacing: 0

		StyledText {
			text: parent.value
			tone: parent.valueTone
			surface: "transparent"
			tabular: true
			font.pixelSize: root.compact ? 16 : 21
			font.weight: Font.Black
		}

		StyledText {
			text: parent.label
			tone: Qt.rgba(1, 1, 1, 0.55)
			surface: "transparent"
			font.pixelSize: Theme.size.small
		}
	}
}
