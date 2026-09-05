pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Controls.impl as QQCImpl
import Quickshell
import Quickshell.Services.Mpris
import "components"

ThemedRectangle {
	id: root

	signal clicked

	required property color foreground
	required property color secondaryBoxColor
	property color progressColor: foreground
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

	radius: ThemeEngine.radiusMedium
	color: "transparent"
	clip: !ThemeEngine.shadowEnabled
	implicitHeight: 30
	implicitWidth: hasMedia ? nowPlayingLabel.implicitWidth + 32 : 30

	Behavior on implicitWidth {
		Anim {}
	}

	HoverLayer {
		id: interaction
		tint: root.foreground
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

	QQCImpl.IconImage {
		anchors.centerIn: parent
		width: 16
		height: 16
		source: root.idleIconSource()
		visible: !root.hasMedia
		sourceSize: Qt.size(width, height)
		color: root.foreground
	}

	AtelierText {
		id: nowPlayingLabel
		anchors.verticalCenter: parent.verticalCenter
		anchors.left: parent.left
		anchors.leftMargin: 16
		anchors.right: parent.right
		anchors.rightMargin: 16
		color: root.foreground
		font.pixelSize: 12
		font.weight: Font.Medium
		text: root.mediaText
		visible: root.hasMedia
		elide: Text.ElideRight
		maximumLineCount: 1
	}

	ThemedRectangle {
		id: progressTrack
		visible: root.hasMedia && root.hasProgress
		x: 12
		y: parent.height - height - 3
		width: parent.width - 24
		height: 3
		radius: ThemeEngine.radiusTiny
		color: Qt.alpha(root.foreground, 0.12)

		ThemedRectangle {
			width: parent.width * root.progressValue
			height: parent.height
			radius: ThemeEngine.radiusTiny
			color: root.progressColor

			Behavior on width {
				Anim {}
			}
		}
	}
}
