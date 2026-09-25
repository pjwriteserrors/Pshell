pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Mpris

// MPRIS player selection: the playing player wins, otherwise the one the
// user picked or the last one that played.
Singleton {
	id: root

	property var rememberedPlayer: null
	property var selectedPlayer: null

	readonly property var activePlayer: {
		for (const player of Mpris.players.values)
			if (player.isPlaying) return player;
		return null;
	}

	readonly property var player: {
		if (root.selectedPlayer) {
			for (const player of Mpris.players.values)
				if (player === root.selectedPlayer) return player;
		}
		if (root.activePlayer) return root.activePlayer;
		for (const player of Mpris.players.values)
			if (player === root.rememberedPlayer) return player;
		return Mpris.players.values.length > 0 ? Mpris.players.values[0] : null;
	}

	readonly property var players: {
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

	readonly property bool hasPlayer: !!root.player
	readonly property bool playing: root.player?.isPlaying ?? false
	readonly property string title: root.player?.trackTitle || (root.hasPlayer ? (root.player.identity || "Unknown") : "Nothing playing")
	readonly property string artist: root.player?.trackArtist || ""
	readonly property string art: root.player?.trackArtUrl ?? ""
	readonly property real length: Math.max(0, Number(root.player?.length || 0))
	readonly property real position: Math.max(0, Math.min(root.length, Number(root.player?.position || 0)))
	readonly property bool hasProgress: root.hasPlayer && root.length > 0
	readonly property string barText: {
		if (!root.hasPlayer || (root.player.trackTitle || "") === "") return "";
		return root.artist !== "" ? `${root.artist} – ${root.player.trackTitle}` : root.player.trackTitle;
	}

	onActivePlayerChanged: if (activePlayer) root.rememberedPlayer = activePlayer

	function select(player) {
		root.selectedPlayer = player;
		if (player) root.rememberedPlayer = player;
	}

	function formatTime(seconds) {
		const total = Math.max(0, Math.round(Number(seconds) || 0));
		const m = Math.floor(total / 60);
		const s = total % 60;
		return `${m}:${s < 10 ? "0" : ""}${s}`;
	}

	function seek(ratio) {
		if (!root.hasProgress || !(root.player?.canSeek ?? false)) return;
		root.player.position = Math.max(0, Math.min(1, ratio)) * root.length;
	}

	Timer {
		running: root.playing
		repeat: true
		interval: 1000
		triggeredOnStart: true
		onTriggered: root.player?.positionChanged()
	}
}
