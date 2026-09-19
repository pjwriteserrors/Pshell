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

	implicitWidth: Bio.spine
	implicitHeight: root.hasMedia ? 44 : 30

	readonly property real live: Math.max(interaction.live, root.activePlayer?.isPlaying ? 0.35 : 0)

	Behavior on implicitHeight {
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

	// In the column there is no room for a title, and no need for one: the
	// track's name belongs in the chamber this opens. What stands on the spine
	// is the organ itself, with how far through the track it is drawn around
	// its own rim.
	BioRing {
		id: transport
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.top: parent.top
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

	// A beat under the organ while something is playing: three beads that
	// brighten in turn, so the column shows life without showing words.
	Row {
		visible: root.hasMedia
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.top: transport.bottom
		anchors.topMargin: Bio.s2
		spacing: 4

		Repeater {
			model: 3

			delegate: Rectangle {
				required property int index

				width: Bio.nodule
				height: Bio.nodule
				radius: Bio.nodule / 2
				color: root.progressColor
				opacity: root.activePlayer?.isPlaying ? 0.25 : 0.18

				SequentialAnimation on opacity {
					running: root.activePlayer?.isPlaying ?? false
					loops: Animation.Infinite

					PauseAnimation { duration: index * 180 }
					NumberAnimation { to: 1; duration: 220; easing.type: Easing.OutCubic }
					NumberAnimation { to: 0.25; duration: 520; easing.type: Easing.InOutSine }
					PauseAnimation { duration: 540 - index * 180 }
				}
			}
		}
	}
}
