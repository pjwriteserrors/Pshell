pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The world in a window of its own: the land, and when wanted the days along the
// bottom; a day or a ticket as a small world of its own on the left. Whatever
// happens in the shell, the camera goes there for a moment and comes back.
FloatingWindow {
	id: root

	readonly property var world: World.scene
	readonly property var days: root.world?.days ?? []
	readonly property var plots: root.world?.plots ?? []
	property int pickedDay: -1
	property int pickedPlot: -1
	readonly property var day: root.pickedDay >= 0 ? root.days[root.pickedDay] ?? null : null
	readonly property var plot: root.pickedPlot >= 0 ? root.plots[root.pickedPlot] ?? null : null
	property bool opened: false
	property bool playing: false
	property string toast: ""
	// where the camera was before something called it away
	property var home: null
	property bool daysShown: false

	title: "World"
	implicitWidth: 1500
	implicitHeight: 940
	minimumSize: Qt.size(900, 600)
	color: "#0f4560"
	visible: World.windowVisible
	onClosed: World.hide()

	function hours(minutes) {
		const h = Math.floor(minutes / 60), m = Math.round(minutes % 60);
		return h > 0 ? (m > 0 ? `${h} h ${m} min` : `${h} h`) : `${m} min`;
	}

	function dayLabel(day, withYear) {
		const date = new Date(`${day}T00:00:00`);
		return date.toLocaleDateString(Qt.locale("de_DE"), withYear ? "dddd, d. MMMM yyyy" : "ddd d. MMM");
	}

	function pickDay(index) {
		root.stopPlaying();
		root.pickedDay = index;
		root.pickedPlot = -1;
		scene.focusDay = index;
		if (index >= 0) {
			const focus = root.days[index]?.focus;
			if (focus) scene.flyTo(focus[0], focus[1], Math.max(scene.fitZoom * 1.6, Math.min(scene.targetZoom, 1.2)));
		}
		if (index >= 0) strip.positionViewAtIndex(index, ListView.Center);
	}

	function pickDayByName(name) {
		const index = root.days.findIndex(day => day.day === name);
		if (index >= 0) root.pickDay(index);
	}

	function pickPlot(index) {
		root.stopPlaying();
		root.pickedPlot = index;
		if (index >= 0) root.pickedDay = -1;
		if (index >= 0) scene.focusDay = -1;
	}

	function welcome() {
		if (root.opened || !root.world || !World.folder || root.width <= 0 || scene.width <= 0) return;
		root.opened = true;
		scene.targetX = root.world.width / 2;
		scene.targetY = root.world.height / 2;
		scene.targetZoom = scene.fitZoom * 0.92;
		scene.jump();
		scene.fit();
		if (World.pickedDay !== "") root.pickDayByName(World.pickedDay);
	}

	function stopPlaying() {
		timelapse.stop();
		scene.until = 100000;
		root.playing = false;
	}

	function play() {
		root.pickDay(-1);
		root.pickPlot(-1);
		scene.fit();
		scene.until = -1;
		root.playing = true;
		timelapse.restart();
	}

	onWorldChanged: root.welcome()
	onWidthChanged: root.welcome()

	Connections {
		target: World
		function onFolderChanged() {
			root.welcome();
		}
		function onPickedDayChanged() {
			if (World.pickedDay !== "") root.pickDayByName(World.pickedDay);
		}
		function onPlayRequested() {
			root.play();
		}
		function onHappened(x, z, text) {
			if (root.playing) return;
			if (!root.home) root.home = { x: scene.targetX, y: scene.targetY, zoom: scene.targetZoom };
			root.toast = text;
			scene.flyTo(x, z, Math.max(scene.targetZoom, 2.6));
			dwell.restart();
		}
	}

	Timer {
		id: dwell

		interval: 7000
		onTriggered: {
			root.toast = "";
			if (root.home) scene.flyTo(root.home.x, root.home.y, root.home.zoom);
			root.home = null;
		}
	}

	SequentialAnimation {
		id: timelapse

		NumberAnimation {
			target: scene
			property: "until"
			from: -1
			to: Math.max(0, root.days.length - 1) + 1.5
			duration: Math.max(6000, root.days.length * 260)
			easing.type: Easing.InOutSine
		}
		ScriptAction {
			script: root.stopPlaying()
		}
	}

	WorldMap {
		id: scene

		anchors.fill: parent
		world: root.world
		folder: World.folder
		onPlotClicked: index => root.pickPlot(index)
		onEmptyClicked: {
			root.pickPlot(-1);
			root.pickDay(-1);
		}
	}

	Spinner {
		anchors.centerIn: parent
		visible: !root.world
	}

	StyledText {
		anchors.centerIn: parent
		visible: !root.world && World.error !== ""
		text: World.error
	}

	// ── the buttons ───────────────────────────────────────────────────────
	Rectangle {
		anchors.top: parent.top
		anchors.right: parent.right
		anchors.margins: Theme.gap.lg
		width: bar.implicitWidth + Theme.gap.md * 2
		height: 46
		radius: Theme.radius.large
		color: Qt.alpha(Theme.bg, 0.82)
		visible: root.world !== null

		Row {
			id: bar

			anchors.centerIn: parent
			spacing: Theme.gap.md

			Spinner {
				anchors.verticalCenter: parent.verticalCenter
				visible: World.building
				width: 18
				height: 18
			}
			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				icon: root.playing ? "stop" : "play"
				onClicked: root.playing ? root.stopPlaying() : root.play()
			}
			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				icon: "calendar"
				checked: root.daysShown
				onClicked: root.daysShown = !root.daysShown
			}
			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				icon: "earth"
				onClicked: {
					root.pickDay(-1);
					root.pickPlot(-1);
					scene.fit();
				}
			}
			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				icon: "wallpaper"
				checked: World.wallpaper
				onClicked: Plugins.toggle("world-wallpaper")
			}
		}
	}

	// ── what just happened ────────────────────────────────────────────────
	Rectangle {
		anchors.horizontalCenter: parent.horizontalCenter
		y: root.toast !== "" ? Theme.gap.lg * 2 + 46 : -height - Theme.gap.lg
		width: Math.min(toastText.implicitWidth + Theme.gap.lg * 2, 520)
		height: 40
		radius: 20
		color: Qt.alpha(Theme.primary, 0.94)

		Behavior on y {
			SpatialAnim {}
		}

		StyledText {
			id: toastText

			anchors.centerIn: parent
			width: Math.min(implicitWidth, parent.width - Theme.gap.lg * 2)
			elide: Text.ElideRight
			text: root.toast
			color: Theme.onPrimary
		}
	}

	// ── a day or a ticket, as its own small world ─────────────────────────
	Rectangle {
		id: card

		readonly property bool shown: root.day !== null || root.plot !== null
		readonly property string number: root.plot ? `plot-${root.pickedPlot}` : `day-${root.pickedDay}`
		readonly property bool isLive: root.plot ? root.plot === World.activePlot : (root.pickedDay >= 0 && root.pickedDay === root.days.length - 1 && World.activePlot !== null)

		anchors.left: parent.left
		anchors.top: parent.top
		anchors.margins: Theme.gap.lg
		width: 360
		height: Math.min(cardColumn.implicitHeight + Theme.gap.lg * 2, parent.height - strip.height - Theme.gap.lg * 3)
		radius: Theme.radius.large
		color: Qt.alpha(Theme.bg, 0.88)
		clip: true
		opacity: card.shown ? 1 : 0
		visible: opacity > 0
		transform: Translate { x: card.shown ? 0 : -36; Behavior on x { SpatialAnim {} } }

		Behavior on opacity {
			Anim {}
		}

		Column {
			id: cardColumn

			x: Theme.gap.lg
			y: Theme.gap.lg
			width: parent.width - Theme.gap.lg * 2
			spacing: Theme.gap.sm

			StyledText {
				width: parent.width
				text: root.plot ? root.plot.name : root.day ? root.dayLabel(root.day.day, true) : ""
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
				wrapMode: Text.Wrap
			}
			StyledText {
				width: parent.width
				visible: root.plot !== null
				text: root.plot ? root.world?.realms?.[root.plot.realm]?.name ?? "" : ""
				color: Theme.textMuted
				elide: Text.ElideRight
			}

			WorldMini {
				width: parent.width
				height: 230
				visible: card.shown
				source: card.shown && World.folder ? `file://${World.folder}/mini/${card.number}.png` : ""
			}

			Item {
				readonly property var source: root.plot ?? root.day

				width: parent.width
				height: 8

				Rectangle {
					anchors.fill: parent
					radius: 4
					color: WorldPalette.grass
				}
				Rectangle {
					height: parent.height
					radius: 4
					color: WorldPalette.roof
					width: parent.source && parent.source.bill + parent.source.other > 0 ? parent.width * parent.source.bill / (parent.source.bill + parent.source.other) : 0
					Behavior on width { SpatialAnim {} }
				}
			}

			Row {
				spacing: Theme.gap.lg

				StyledText { text: `Abrechenbar ${root.hours((root.plot ?? root.day)?.bill ?? 0)}` }
				StyledText { text: `Sonstig ${root.hours((root.plot ?? root.day)?.other ?? 0)}`; color: Theme.textMuted }
			}

			Row {
				spacing: Theme.gap.lg
				visible: root.day !== null && (root.day.ml > 0 || root.day.breaks > 0)

				StyledText { text: root.day ? `${(root.day.ml / 1000).toFixed(2).replace(".", ",")} l Wasser` : "" }
				StyledText { text: root.day ? `${root.day.breaks} Pausen` : ""; color: Theme.textMuted }
			}

			StyledText {
				width: parent.width
				visible: root.plot !== null && (root.plot.persons ?? []).length > 0
				text: (root.plot?.persons ?? []).join(", ")
				color: Theme.textMuted
				font.pixelSize: Theme.size.small
				wrapMode: Text.Wrap
			}

			Repeater {
				model: root.day?.plots ?? []

				Clickable {
					id: row

					required property var modelData
					readonly property var ticket: root.plots[row.modelData.plot] ?? null

					width: cardColumn.width
					height: rowColumn.implicitHeight + Theme.gap.sm * 2
					radius: Theme.radius.medium
					onClicked: root.pickPlot(row.modelData.plot)

					Column {
						id: rowColumn

						anchors.verticalCenter: parent.verticalCenter
						x: Theme.gap.sm
						width: parent.width - Theme.gap.sm * 2

						StyledText {
							width: parent.width
							text: row.ticket?.name ?? ""
							elide: Text.ElideRight
						}
						StyledText {
							width: parent.width
							color: Theme.textMuted
							font.pixelSize: Theme.size.small
							elide: Text.ElideRight
							text: {
								const parts = [root.world?.realms?.[row.ticket?.realm ?? 0]?.name ?? ""];
								if (row.modelData.houses > 0) parts.push(`${row.modelData.houses} Häuser`);
								if (row.modelData.trees > 0) parts.push(`${row.modelData.trees} Bäume`);
								return parts.join("  ·  ");
							}
						}
					}
				}
			}
		}
	}

	// ── what the pointer is on ────────────────────────────────────────────
	Rectangle {
		id: tip

		readonly property var ticket: !root.playing && scene.hovered >= 0 && scene.hovered !== root.pickedPlot ? root.plots[scene.hovered] ?? null : null

		x: Math.min(root.width - width - 8, scene.pointer.x + 16)
		y: Math.min(root.height - height - 8, scene.pointer.y + 16)
		width: 280
		height: tipColumn.implicitHeight + Theme.gap.md * 2
		radius: Theme.radius.medium
		color: Qt.alpha(Theme.bg, 0.9)
		opacity: tip.ticket ? 1 : 0
		visible: opacity > 0

		Behavior on opacity {
			Anim {}
		}

		Column {
			id: tipColumn

			x: Theme.gap.md
			y: Theme.gap.md
			width: parent.width - Theme.gap.md * 2
			spacing: 2

			StyledText {
				width: parent.width
				wrapMode: Text.Wrap
				font.weight: Font.DemiBold
				text: tip.ticket?.name ?? ""
			}
			StyledText {
				width: parent.width
				color: Theme.textMuted
				font.pixelSize: Theme.size.small
				text: root.world?.realms?.[tip.ticket?.realm ?? 0]?.name ?? ""
			}
		}
	}

	// ── the days ──────────────────────────────────────────────────────────
	ListView {
		id: strip

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: Theme.gap.lg
		height: root.daysShown ? 72 : 0
		opacity: root.daysShown ? 1 : 0
		orientation: ListView.Horizontal
		spacing: Theme.gap.sm
		clip: true
		model: root.days
		boundsBehavior: Flickable.StopAtBounds
		highlightMoveDuration: 500
		visible: root.world !== null && strip.opacity > 0
		Behavior on height { SpatialAnim {} }
		Behavior on opacity { Anim {} }
		Component.onCompleted: positionViewAtEnd()
		onCountChanged: positionViewAtEnd()
		onWidthChanged: positionViewAtEnd()

		delegate: Clickable {
			id: tile

			required property var modelData
			required property int index
			readonly property bool current: root.pickedDay === tile.index
			readonly property bool reached: scene.until >= tile.index
			readonly property real total: Math.max(1, tile.modelData.bill + tile.modelData.other)

			width: 112
			height: strip.height
			radius: Theme.radius.medium
			color: tile.current ? Qt.alpha(Theme.primary, 0.92) : Qt.alpha(Theme.bg, tile.reached ? 0.82 : 0.4)
			onClicked: root.pickDay(tile.current ? -1 : tile.index)

			Behavior on color {
				ColorAnim {}
			}

			Column {
				anchors.fill: parent
				anchors.margins: Theme.gap.sm
				spacing: 4

				StyledText {
					text: root.dayLabel(tile.modelData.day, false)
					font.pixelSize: Theme.size.small
					color: tile.current ? Theme.onPrimary : Theme.text
				}
				Item {
					width: parent.width
					height: 5

					Rectangle { anchors.fill: parent; radius: 2.5; color: WorldPalette.grass; opacity: tile.modelData.other > 0 ? 1 : 0.2 }
					Rectangle { height: parent.height; radius: 2.5; color: WorldPalette.roof; width: parent.width * tile.modelData.bill / tile.total }
				}
				StyledText {
					text: root.hours(tile.modelData.bill + tile.modelData.other)
					font.pixelSize: Theme.size.small
					color: tile.current ? Theme.onPrimary : Theme.textMuted
				}
			}
		}
	}

	Component.onCompleted: root.welcome()
}
