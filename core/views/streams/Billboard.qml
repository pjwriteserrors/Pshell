pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The top of the home page: one thing at a time, large. Who is live first, then
// what to go on with. The picture drifts slowly and gives way to the next one.
Item {
	id: root

	// [{ key, kind: "live" | "series", title, kicker, meta, picture, large, colors, accent, source, seriesId, cells, total, done, spoiler }]
	property var items: []
	property string currentKey: ""
	// scrolled down the page: the picture stays behind a little
	property real scrolled: 0
	readonly property int index: Math.max(0, root.items.findIndex(item => item.key === root.currentKey))
	readonly property var current: root.items[root.index] ?? null
	readonly property color accent: root.current?.accent ?? Theme.primary

	signal openSeries(string id, var from)

	function go(delta) {
		if (root.items.length === 0) return;
		root.currentKey = root.items[(root.index + delta + root.items.length) % root.items.length].key;
	}

	onCurrentChanged: {
		if (!root.current) return;
		// the words come in anew only for another thing
		if (root.shownKey !== root.current.key) {
			root.shownKey = root.current.key;
			words.restart();
			run.restart();
			layerSwap();
		}
	}

	property string shownKey: ""
	property bool front: true

	function layerSwap() {
		root.front = !root.front;
		(root.front ? pictureA : pictureB).take(root.current);
	}

	// goes on by itself, not while the pointer is on it
	NumberAnimation {
		id: run

		target: runner
		property: "value"
		from: 0
		to: 1
		duration: 10000
		paused: hover.hovered
		running: root.items.length > 1
		onFinished: root.go(1)
	}

	QtObject {
		id: runner

		property real value: 0
	}

	HoverHandler {
		id: hover
	}

	component Layer: Item {
		id: layer

		required property bool shown
		property string source: ""
		property string large: ""
		property var colors: null

		function take(item) {
			layer.source = item?.picture ?? "";
			layer.large = item?.large ?? "";
			layer.colors = item?.colors ?? null;
			drift.restart();
		}

		anchors.fill: parent
		opacity: layer.shown && picture.ready ? 1 : 0
		clip: true

		Behavior on opacity {
			NumberAnimation {
				duration: 900
				easing.type: Easing.InOutSine
			}
		}

		Thumb {
			id: picture

			anchors.fill: parent
			anchors.bottomMargin: -root.scrolled * 0.25
			y: root.scrolled * 0.35
			radius: 0
			source: layer.source
			large: layer.large
			colors: layer.colors
			transformOrigin: Item.Right
			spoiler: false

			NumberAnimation on scale {
				id: drift

				from: 1.0
				to: 1.08
				duration: 14000
				easing.type: Easing.OutSine
			}
		}
	}

	clip: true

	Rectangle {
		anchors.fill: parent
		color: Streams.pageColor
	}

	Layer {
		id: pictureA

		shown: root.front
	}
	Layer {
		id: pictureB

		shown: !root.front
	}

	// dark from the left for the words, into the page at the bottom
	Rectangle {
		anchors.fill: parent
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop {
				position: 0
				color: Qt.rgba(0, 0, 0, 0.82)
			}
			GradientStop {
				position: 0.42
				color: Qt.rgba(0, 0, 0, 0.42)
			}
			GradientStop {
				position: 0.8
				color: Qt.rgba(0, 0, 0, 0)
			}
		}
	}
	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: parent.height * 0.5
		gradient: Gradient {
			GradientStop {
				position: 0
				color: Qt.alpha(Theme.base, 0)
			}
			GradientStop {
				position: 0.72
				color: Qt.alpha(Theme.base, 0.82)
			}
			GradientStop {
				position: 1
				color: Theme.base
			}
		}
	}
	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		height: 110
		gradient: Gradient {
			GradientStop {
				position: 0
				color: Qt.rgba(0, 0, 0, 0.6)
			}
			GradientStop {
				position: 1
				color: Qt.rgba(0, 0, 0, 0)
			}
		}
	}

	// ── the words ───────────────────────────────────────────────────────
	ColumnLayout {
		id: block

		anchors.left: parent.left
		anchors.bottom: parent.bottom
		anchors.leftMargin: 44
		anchors.bottomMargin: 96
		width: Math.min(parent.width * 0.58, 720)
		spacing: 10
		opacity: words.progress
		transform: Translate {
			x: (1 - words.progress) * -26
		}

		QtObject {
			id: words

			property real progress: 1

			function restart() {
				wordsIn.restart();
			}
		}

		NumberAnimation {
			id: wordsIn

			target: words
			property: "progress"
			from: 0
			to: 1
			duration: Motion.extraLong + 200
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}

		RowLayout {
			spacing: 8

			Rectangle {
				visible: root.current?.kind === "live"
				implicitWidth: liveWord.implicitWidth + 16
				implicitHeight: 22
				radius: 5
				color: "#e5484d"

				Text {
					id: liveWord

					anchors.centerIn: parent
					text: "LIVE"
					color: "white"
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					font.weight: Font.Black
					font.letterSpacing: 1
				}
			}
			Text {
				text: root.current?.kicker ?? ""
				color: Qt.rgba(1, 1, 1, 0.82)
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
			}
		}

		Text {
			Layout.fillWidth: true
			text: root.current?.title ?? ""
			color: "white"
			font.family: Theme.fontFamily
			font.pixelSize: text.length > 34 ? 38 : 58
			font.weight: Font.Black
			lineHeight: 0.95
			wrapMode: Text.Wrap
			maximumLineCount: 2
			elide: Text.ElideRight
		}

		Text {
			Layout.fillWidth: true
			visible: text !== ""
			text: root.current?.spoiler ? "" : (root.current?.subtitle ?? "")
			color: Qt.rgba(1, 1, 1, 0.9)
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.title
			font.weight: Font.Medium
			elide: Text.ElideRight
		}

		EpisodeSteps {
			Layout.fillWidth: true
			Layout.maximumWidth: 460
			Layout.topMargin: 4
			visible: (root.current?.total ?? 0) > 0
			barHeight: 6
			cells: root.current?.cells ?? []
			total: root.current?.total ?? 0
			done: root.current?.done ?? 0
			accent: root.accent
		}

		Text {
			text: root.current?.meta ?? ""
			color: Qt.rgba(1, 1, 1, 0.72)
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.label
			font.weight: Font.Medium
		}

		RowLayout {
			Layout.topMargin: 8
			spacing: 10

			BigButton {
				text: root.current?.kind === "live" ? "Watch live" : (root.current?.resume ? "Continue" : "Play")
				icon: "play"
				onClicked: {
					if (root.current.kind === "live") Streams.playLive(root.current.source);
					else Streams.playNext(root.current.seriesId);
				}
			}
			BigButton {
				visible: root.current?.kind === "series"
				text: "Episodes"
				icon: "playlist_check"
				main: false
				onClicked: root.openSeries(root.current.seriesId, null)
			}
			BigButton {
				visible: root.current?.kind === "live" && Streams.hasMpv
				icon: "picture_in_picture_top_right"
				main: false
				onClicked: Streams.playLive(root.current.source, { pip: true })
			}
		}
	}

	// ── which one, and how long it stays ────────────────────────────────
	Row {
		anchors.right: parent.right
		anchors.rightMargin: 44
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 104
		spacing: 6
		visible: root.items.length > 1

		Repeater {
			model: root.items

			Item {
				id: dash

				required property var modelData
				required property int index
				readonly property bool current: dash.index === root.index

				width: dash.current ? 44 : 18
				height: 16

				Behavior on width {
					SpatialAnim {
						duration: Motion.long
					}
				}

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: parent.width
					height: 4
					radius: 2
					color: Qt.rgba(1, 1, 1, dashArea.containsMouse ? 0.6 : 0.28)
					clip: true

					Rectangle {
						visible: dash.current
						height: parent.height
						radius: 2
						color: "white"
						width: parent.width * runner.value
					}
				}

				MouseArea {
					id: dashArea

					anchors.fill: parent
					hoverEnabled: true
					onClicked: root.currentKey = dash.modelData.key
				}
			}
		}
	}
}
