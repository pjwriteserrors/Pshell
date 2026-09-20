pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"
import "components/ArcInk.js" as Ink

// THE REALMS.
//
// Not a taskbar and not a row of numbers. The workspaces on this output are
// drawn as a chart of places: each realm a node on a ley line, the one you are
// standing in larger and alight, and the windows in it as marks set around it
// like holdings around a keep. Realms you are not in are dark nodes with a
// count beside them.
//
// Moving between realms sends a light down the ley from the node you left to
// the node you arrived at, which is the only way this shell ever shows that
// two things are connected.
Item {
	id: root

	required property var niriState
	required property string outputName

	readonly property var realms: root.niriState.realmsForOutput(root.outputName)
	readonly property int activeIndex: {
		for (let index = 0; index < root.realms.length; index++)
			if (root.realms[index].active) return index;
		return 0;
	}
	readonly property var held: root.realms.length > 0
		? root.niriState.windowsInRealm(root.realms[root.activeIndex]?.id)
		: []

	// Where each realm's node sits. They rise gently west to east so the chart
	// reads as a landscape rather than as a list.
	readonly property real spread: Math.min(58, Math.max(34, (width - 30) / Math.max(1, root.realms.length)))
	readonly property real baseY: height * 0.44

	function nodeX(index) { return 16 + index * root.spread; }
	function nodeY(index) { return root.baseY + Math.sin(index * 1.1) * 7; }

	// The light travelling the ley when you change realm.
	property real travel: 1
	property int travelFrom: 0

	onActiveIndexChanged: {
		travelJourney.stop();
		root.travel = 0;
		travelJourney.start();
	}

	NumberAnimation {
		id: travelJourney
		target: root
		property: "travel"
		from: 0
		to: 1
		duration: Arc.draw
		easing.type: Easing.Bezier
		easing.bezierCurve: Arc.curveInk
	}

	// The chart: the leys between the realms and the dark nodes on them.
	Canvas {
		id: chart
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		readonly property int count: root.realms.length
		readonly property int here: root.activeIndex
		readonly property real journey: root.travel

		onCountChanged: requestPaint()
		onHereChanged: requestPaint()
		onJourneyChanged: requestPaint()

		Connections {
			target: Arc
			function onGoldChanged() { chart.requestPaint(); }
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width < 30 || chart.count === 0) return;

			for (let index = 0; index + 1 < chart.count; index++) {
				Ink.leyCurve(ctx, root.nodeX(index), root.nodeY(index),
					root.nodeX(index + 1), root.nodeY(index + 1),
					index % 2 === 0 ? 7 : -7, Arc.ruleThin,
					Qt.alpha(Arc.gold, 0.34));
			}

			for (let index = 0; index < chart.count; index++) {
				const here = index === chart.here;
				const x = root.nodeX(index), y = root.nodeY(index);
				if (here) continue;
				Ink.ring(ctx, x, y, 6.5, Arc.ruleThin, Qt.alpha(Arc.gold, 0.6), 1);
				if (root.realms[index] && root.realms[index].urgent)
					Ink.mote(ctx, x, y, 3, Arc.bane);
			}

			// the light going down the ley to where you are now
			if (chart.journey < 0.999 && chart.count > 1) {
				const from = Math.max(0, Math.min(chart.count - 1, chart.here - 1));
				const t = chart.journey;
				const x = root.nodeX(from) + (root.nodeX(chart.here) - root.nodeX(from)) * t;
				const y = root.nodeY(from) + (root.nodeY(chart.here) - root.nodeY(from)) * t;
				Ink.mote(ctx, x, y, 4.2, Arc.aether);
			}
		}
	}

	// The realm you are standing in: a drawn ring with the holdings set round
	// it. Everything about it is bigger and alight; nothing about the others is.
	Item {
		id: keep

		width: 36
		height: 36
		x: Math.round(root.nodeX(root.activeIndex) - width / 2)
		y: Math.round(root.nodeY(root.activeIndex) - height / 2)

		Behavior on x {
			NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveSnap }
		}
		Behavior on y {
			NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveSnap }
		}

		ArcHalo {
			anchors.centerIn: parent
			width: 70
			height: 70
			color: Arc.aether
			strength: 0.28
			spread: 0.3
			flicker: true
		}

		ArcDial {
			anchors.fill: parent
			lineColor: Qt.alpha(Arc.aether, 0.6)
			liveColor: Arc.aether
			weight: Arc.rule
			seed: root.activeIndex
			beading: false
			intensity: 0.7
			drawn: root.travel
		}

		ArcText {
			anchors.centerIn: parent
			role: "display"
			tone: "aether"
			font.pixelSize: 12
			font.letterSpacing: 0
			text: root.realms.length > 0 ? String(root.realms[root.activeIndex]?.idx ?? "") : ""
		}
	}

	// The holdings: the windows in the realm you are in, set on an arc above
	// it. The one in front is a filled mark; the rest are open ones.
	Repeater {
		model: root.held.slice(0, 7)

		delegate: Item {
			id: holding

			required property var modelData
			required property int index

			readonly property int total: Math.min(7, root.held.length)
			readonly property real angle: Math.PI * (1.18 - 0.36 * (holding.total === 1 ? 0.5 : holding.index / (holding.total - 1)))
			readonly property real orbit: 26

			width: 18
			height: 18
			x: Math.round(root.nodeX(root.activeIndex) + Math.cos(holding.angle) * holding.orbit - width / 2)
			y: Math.round(root.nodeY(root.activeIndex) - Math.abs(Math.sin(holding.angle)) * holding.orbit * 0.62 - height / 2)

			opacity: root.travel

			ArcHalo {
				anchors.centerIn: parent
				width: 38
				height: 38
				color: holding.modelData.isUrgent ? Arc.bane : Arc.aether
				strength: 0.30
				spread: 0.3
				opacity: holding.modelData.isFocused || touch.containsMouse ? 1 : 0
				visible: opacity > 0.01

				Behavior on opacity {
					NumberAnimation { duration: Arc.turn }
				}
			}

			Image {
				anchors.centerIn: parent
				width: 13
				height: 13
				source: root.niriState ? Quickshell.iconPath(holding.modelData.appId || "application-x-executable", true) : ""
				fillMode: Image.PreserveAspectFit
				smooth: true
				mipmap: true
				asynchronous: true
				opacity: holding.modelData.isFocused || touch.containsMouse ? 1 : 0.42

				Behavior on opacity {
					NumberAnimation { duration: Arc.tick }
				}
			}

			ArcTouch {
				id: touch
				acceptedButtons: Qt.LeftButton | Qt.MiddleButton
				onClicked: event => {
					if (event.button === Qt.MiddleButton)
						root.niriState.closeWindow(holding.modelData.id);
					else
						root.niriState.focusWindow(holding.modelData.id);
				}
			}
		}
	}

	// The dark realms answer to the pointer too.
	Repeater {
		model: root.realms

		delegate: ArcTouch {
			id: realmTouch

			required property var modelData
			required property int index

			anchors.fill: undefined
			x: Math.round(root.nodeX(realmTouch.index) - 13)
			y: Math.round(root.nodeY(realmTouch.index) - 13)
			width: 26
			height: 26
			visible: realmTouch.index !== root.activeIndex
			onClicked: root.niriState.focusRealm(realmTouch.modelData.idx)
		}
	}
}
