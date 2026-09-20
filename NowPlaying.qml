pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Controls.impl as QQCImpl
import Quickshell
import Quickshell.Services.Mpris
import "components"

// What is playing: a chalice with the track's progress running round it.
//
// No title, no artist, no bar. The name of what is playing belongs on the panel
// this opens; out here it is one mark, and how far through the track you are is
// the ring that has been drawn around it.
Item {
	id: root

	signal clicked

	property color foreground: Arc.ink
	property color secondaryBoxColor: Arc.veil1
	property color progressColor: Arc.aether

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
	implicitHeight: 30

	readonly property real live: Math.max(interaction.live, root.activePlayer?.isPlaying ? 0.4 : 0)

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

	ArcHalo {
		anchors.centerIn: parent
		width: 78
		height: 78
		color: root.progressColor
		strength: 0.34
		spread: 0.32
		flicker: true
		opacity: root.live
		visible: opacity > 0.01

		Behavior on opacity {
			NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveKindle }
		}
	}

	// How far through, taken round the mark. Nothing is drawn when nothing is
	// playing: an empty ring would be a promise the shell is not keeping.
	ArcDial {
		anchors.centerIn: parent
		width: 30
		height: 30
		seed: 1
		weight: Arc.ruleThin
		beading: false
		lineColor: root.hasMedia ? Qt.alpha(Arc.gold, 0.3) : "transparent"
		liveColor: root.progressColor
		progress: root.hasMedia && root.hasProgress ? root.progressValue : -1
		drawn: root.hasMedia ? 1 : 0

		Behavior on drawn {
			NumberAnimation { duration: Arc.draw; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveInk }
		}
	}

	ArcMark {
		anchors.centerIn: parent
		width: 17
		height: 17
		glyph: "chalice"
		weight: Arc.ruleThin
		lineColor: root.live > 0.25 ? root.progressColor : root.foreground
	}

	// A single mote rising off the chalice while something is playing: the one
	// thing out here that keeps time with the music rather than with the shell.
	ArcMotes {
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.top
		width: 26
		height: 30
		color: root.progressColor
		drifting: root.activePlayer?.isPlaying ?? false
		density: 3
		drift: -14
		span: 2.2
	}

	ArcText {
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.top: parent.bottom
		anchors.topMargin: 2
		role: "label"
		tone: "aether"
		font.pixelSize: 9
		text: "Consort"
		opacity: interaction.containsMouse ? 1 : 0

		Behavior on opacity {
			NumberAnimation { duration: Arc.tick }
		}
	}

	ArcTouch {
		id: interaction
		onClicked: root.clicked()
	}
}
