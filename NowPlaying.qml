pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Controls.impl as QQCImpl
import Quickshell
import Quickshell.Services.Mpris
import "components"

// What is playing, as a specimen label.
//
// A ring that is the transport indicator, the track engraved next to it, and
// the position running underneath as a vein rather than a bar. With nothing
// playing it collapses to the ring alone.
Item {
	id: root

	signal clicked

	property color foreground: Bio.text
	property color secondaryBoxColor: Bio.tissue1
	property color progressColor: Bio.organ
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

	implicitHeight: Bio.spine
	implicitWidth: root.hasMedia ? Math.min(nowPlayingLabel.implicitWidth + 58, 380) : 30

	readonly property real live: Math.max(interaction.live, root.activePlayer?.isPlaying ? 0.35 : 0)

	Behavior on implicitWidth {
		NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
	}

	BioTouch {
		id: interaction
		onClicked: root.clicked()
	}

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

	BioRing {
		id: transport
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		width: 26
		height: 26
		seed: 1
		intensity: root.live
		liveColor: root.progressColor

		QQCImpl.IconImage {
			anchors.centerIn: parent
			width: 13
			height: 13
			source: root.idleIconSource()
			sourceSize: Qt.size(width, height)
			color: root.live > 0.3 ? root.progressColor : root.foreground
		}
	}

	BioText {
		id: nowPlayingLabel
		anchors.verticalCenter: parent.verticalCenter
		anchors.left: transport.right
		anchors.leftMargin: Bio.s3
		anchors.right: parent.right
		anchors.rightMargin: Bio.s3
		role: "caption"
		text: root.mediaText
		visible: root.hasMedia
		maximumLineCount: 1
	}

	// The position, as a vein under the title.
	BioMeter {
		visible: root.hasMedia && root.hasProgress
		anchors.left: nowPlayingLabel.left
		anchors.right: nowPlayingLabel.right
		anchors.top: nowPlayingLabel.bottom
		anchors.topMargin: 1
		height: 6
		weight: Bio.ribThin
		value: root.progressValue
		fillColor: root.progressColor
		trackColor: Bio.boneGhost
	}
}
