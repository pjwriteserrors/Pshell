pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Controls.impl as QQCImpl
import Quickshell
import Quickshell.Services.Mpris
import "components"

// What is playing, hung on the right limb of the chain.
//
// A dial with how far through the track it is taken round its rim, and under
// it a beat of three marks that light in turn while something is playing. The
// name of the track belongs in the scroll this opens; there is no room for it
// on the chain and no reason to put it there.
Item {
	id: root

	signal clicked

	property color foreground: Arc.ink
	property color secondaryBoxColor: Arc.leaf1
	property color progressColor: Arc.aether

	// The chain this is hung from: where on screen this item starts, and the
	// curve to read a height off.
	property real originX: 0
	property var chainAt: null

	function heightAt(centreX) {
		return root.chainAt ? root.chainAt(centreX) : Arc.chainY(0.7);
	}
	readonly property bool hasMedia: mediaText !== ""
	readonly property bool hasProgress: !!root.activePlayer && Number(root.activePlayer.length || 0) > 0
	readonly property real progressValue: root.hasProgress
		? Math.max(0, Math.min(1, Number(root.activePlayer.position || 0) / Number(root.activePlayer.length || 1)))
		: 0
	property var rememberedPlayer: null
	property var selectedPlayer: null

	readonly property var activePlayer: {
		const players = Mpris.players.values;
		for (const player of players) {
			if (player.isPlaying) return player;
		}
		return null;
	}

	readonly property var currentPlayer: {
		if (root.selectedPlayer) {
			for (const player of Mpris.players.values) {
				if (player === root.selectedPlayer) return player;
			}
		}

		if (root.activePlayer) return root.activePlayer;

		for (const player of Mpris.players.values) {
			if (player === root.rememberedPlayer) return player;
		}

		return null;
	}

	readonly property string mediaText: {
		const player = activePlayer;
		if (!player) return "";

		const artist = player.trackArtist || "";
		const title = player.trackTitle || "";
		if (artist !== "" && title !== "") return `${artist} - ${title}`;
		return title || artist || player.identity || "";
	}

	function iconSource(primary, fallbacks) {
		const names = [primary].concat(fallbacks || []);
		for (const name of names) {
			if (!name) continue;
			const path = Quickshell.iconPath(name, true);
			if (path !== "") return path;
		}
		return "";
	}

	function idleIconSource() {
		return root.iconSource("audio-x-generic-symbolic", ["audio-x-generic"])
			|| "/usr/share/icons/Adwaita/symbolic/mimetypes/audio-x-generic-symbolic.svg";
	}

	function setCurrentPlayer(player) {
		root.selectedPlayer = player;
		if (player) root.rememberedPlayer = player;
	}

	readonly property var availablePlayers: Mpris.players.values
	readonly property var uniquePlayers: {
		const seen = {};
		const unique = [];

		for (const player of Mpris.players.values) {
			const key = String(player?.identity || player?.dbusName || "");
			if (key === "" || seen[key]) continue;
			seen[key] = true;
			unique.push(player);
		}

		return unique;
	}

	implicitWidth: 30
	implicitHeight: Arc.gantryDepth

	readonly property real live: Math.max(interaction.live, root.activePlayer?.isPlaying ? 0.35 : 0)
	readonly property real restY: root.heightAt(root.originX + root.x + width / 2)

	onActivePlayerChanged: {
		if (activePlayer) root.rememberedPlayer = activePlayer;
	}

	Timer {
		running: root.activePlayer?.isPlaying ?? false
		repeat: true
		interval: 1000
		triggeredOnStart: true
		onTriggered: root.activePlayer?.positionChanged()
	}

	ArcDial {
		id: transport
		anchors.horizontalCenter: parent.horizontalCenter
		y: Math.round(root.restY - height / 2)
		width: 28
		height: 28
		seed: 1
		intensity: root.live
		liveColor: root.progressColor
		progress: root.hasMedia && root.hasProgress ? root.progressValue : -1

		QQCImpl.IconImage {
			anchors.centerIn: parent
			width: 13
			height: 13
			source: root.idleIconSource()
			sourceSize: Qt.size(width, height)
			color: root.live > 0.3 ? root.progressColor : root.foreground
		}
	}

	// The beat: three marks struck in turn under the dial while something is
	// playing. It is the one thing on the chain that moves to its own time.
	Row {
		visible: root.hasMedia
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.top: transport.bottom
		anchors.topMargin: Arc.s1
		spacing: 4

		Repeater {
			model: 3

			delegate: Rectangle {
				required property int index

				width: 3
				height: 3
				rotation: 45
				color: root.progressColor
				opacity: root.activePlayer?.isPlaying ? 0.22 : 0.16

				SequentialAnimation on opacity {
					running: root.activePlayer?.isPlaying ?? false
					loops: Animation.Infinite

					PauseAnimation { duration: index * 170 }
					NumberAnimation { to: 1; duration: 180; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveKindle }
					NumberAnimation { to: 0.22; duration: 520; easing.type: Easing.InOutSine }
					PauseAnimation { duration: 520 - index * 170 }
				}
			}
		}
	}

	ArcTouch {
		id: interaction
		onClicked: root.clicked()
	}
}
