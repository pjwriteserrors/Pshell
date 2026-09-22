pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Mpris

// Which player the shell is listening to. The playing one wins; a player
// picked in the media lantern stays picked; the last one heard is
// remembered so a paused track can still be shown.
Item {
	id: root

	readonly property bool hasMedia: mediaText !== ""
	readonly property bool playing: activePlayer?.isPlaying ?? false
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
		return Mpris.players.values.length > 0 ? Mpris.players.values[0] : null;
	}

	// The bead shows the playing player, or the last one heard while it is
	// paused, so a paused track is still one click away.
	readonly property string mediaText: {
		const player = activePlayer || currentPlayer;
		if (!player) return "";
		const artist = player.trackArtist || "";
		const title = player.trackTitle || "";
		if (artist !== "" && title !== "") return `${artist} - ${title}`;
		return title || artist || player.identity || "";
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

	onActivePlayerChanged: {
		if (activePlayer) root.rememberedPlayer = activePlayer;
	}

	// Quickshell's Mpris position only moves when asked.
	Timer {
		running: root.activePlayer?.isPlaying ?? false
		repeat: true
		interval: 1000
		triggeredOnStart: true
		onTriggered: root.activePlayer?.positionChanged()
	}
}
