pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl as QQCImpl
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import "components"

// Media popup: a turning record with the cover art at its centre, the track
// underneath, then seek, transport, volume, players and outputs. Keeps the same
// external API as every other style's media popup.
Item {
	id: root

	required property var activePlayer
	required property var players
	required property color foreground
	required property color secondaryBoxColor
	required property color secondaryInsetColor
	required property color accent
	property color primary: accent
	property color onPrimaryColor: "#101010"
	property bool popupActive: false
	signal selectPlayer(var player)

	readonly property var player: root.activePlayer
	readonly property bool hasPlayer: !!player
	readonly property string titleText: player?.trackTitle || "Nothing playing"
	readonly property string artistText: player?.trackArtist || (player?.identity || "")
	readonly property string coverSource: player?.trackArtUrl ?? ""
	readonly property bool playing: player?.isPlaying ?? false
	readonly property real trackLength: Math.max(1, Number(player?.length || 0))
	readonly property real trackPosition: Math.max(0, Math.min(trackLength, Number(player?.position || 0)))
	readonly property bool hasProgress: hasPlayer && Number(player.length || 0) > 0

	// output volume / sink selection (wpctl-based)
	property real sinkVolume: 0
	property bool sinkMuted: false
	property var sinks: []

	function refreshAudio() {
		volumeReadProc.running = true;
		sinkListProc.running = true;
	}

	function setSinkVolume(value) {
		const v = Math.max(0, Math.min(1, value));
		root.sinkVolume = v;
		Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", `${v.toFixed(2)}`]);
	}

	function toggleSinkMute() {
		Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]);
		audioRefreshTimer.restart();
	}

	function setDefaultSink(name) {
		Quickshell.execDetached(["pactl", "set-default-sink", String(name)]);
		audioRefreshTimer.restart();
	}

	function shortSinkName(name) {
		let n = String(name || "");
		n = n.replace(/ Analog Stereo| Digital Stereo.*| Pro \d+.*/g, "");
		return n.length > 38 ? n.slice(0, 38) + "\u2026" : n;
	}

	onPopupActiveChanged: {
		if (popupActive) refreshAudio();
	}

	Process {
		id: volumeReadProc
		command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
		stdout: StdioCollector {
			onStreamFinished: {
				const raw = String(text || "");
				const match = raw.match(/Volume:\s*([0-9.]+)/);
				if (match) root.sinkVolume = Math.max(0, Math.min(1.5, Number(match[1])));
				root.sinkMuted = raw.includes("[MUTED]");
			}
		}
	}

	Process {
		id: sinkListProc
		command: ["sh", "-lc", "pactl --format=json list sinks; printf '@@@%s' \"$(pactl get-default-sink)\""]
		stdout: StdioCollector {
			onStreamFinished: {
				const raw = String(text || "");
				const sep = raw.lastIndexOf("@@@");
				if (sep < 0) return;
				const defaultName = raw.slice(sep + 3).trim();
				const next = [];
				try {
					for (const sink of JSON.parse(raw.slice(0, sep))) {
						next.push({
							active: sink.name === defaultName,
							name: sink.name,
							description: sink.description || sink.name
						});
					}
				} catch (e) {
					return;
				}
				root.sinks = next;
			}
		}
	}

	Timer {
		id: audioRefreshTimer
		interval: 250
		repeat: false
		onTriggered: root.refreshAudio()
	}

	Timer {
		running: root.popupActive
		repeat: true
		interval: 3000
		onTriggered: root.refreshAudio()
	}

	implicitWidth: 492
	implicitHeight: contentColumn.implicitHeight

	function formatTime(seconds) {
		const total = Math.max(0, Math.round(Number(seconds) || 0));
		const m = Math.floor(total / 60);
		const sec = total % 60;
		return `${m}:${sec < 10 ? "0" : ""}${sec}`;
	}

	Timer {
		running: root.popupActive && root.playing
		repeat: true
		interval: 500
		onTriggered: root.player?.positionChanged()
	}

    Column {
        id: contentColumn
        width: parent.width
        spacing: 22
        Item {
            width: parent.width; height: 238
            Rectangle {
                id: record
                width: 220; height: 220; radius: 110; anchors.centerIn: parent
                color: Atelier.text
                Repeater {
                    model: 8
                    delegate: Rectangle {
                        required property int index
                        anchors.centerIn: parent
                        width: 202 - index * 10; height: width; radius: width / 2
                        color: "transparent"; border.color: "#48504a"; border.width: 1
                    }
                }
                ClippingRectangle {
                    anchors.centerIn: parent; width: 104; height: 104; radius: 52; color: Atelier.accent
                    Image { anchors.fill: parent; source: root.coverSource; fillMode: Image.PreserveAspectCrop }
                }
                Rectangle { anchors.centerIn: parent; width: 12; height: 12; radius: 6; color: Atelier.canvas }
                RotationAnimator on rotation { from: 0; to: 360; duration: 24000; loops: Animation.Infinite; running: root.playing && root.popupActive }
            }
        }
        Column {
            width: parent.width; spacing: 4
            AtelierText { width: parent.width; text: root.titleText; display: true; font.pixelSize: 28; maximumLineCount: 2; wrapMode: Text.WordWrap; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter }
            AtelierText { width: parent.width; text: root.artistText || "Your next interlude awaits."; color: Atelier.muted; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
        }
        Slider {
            id: seek
            width: parent.width; height: 18
            from: 0; to: root.trackLength; value: root.trackPosition
            enabled: root.hasProgress
            onMoved: if(root.player && root.player.canSeek) root.player.position = value
            background: Rectangle {
                x: seek.leftPadding; y: (seek.height - height) / 2; width: seek.availableWidth; height: 2; color: Atelier.rule
                Rectangle { width: parent.width * seek.visualPosition; height: 2; color: Atelier.accent }
            }
            handle: Rectangle { x: seek.leftPadding + seek.visualPosition * (seek.availableWidth - width); y: (seek.height - height) / 2; width: 8; height: 8; radius: 4; color: Atelier.accent }
        }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter; spacing: 18
            Repeater {
                model: ["previous", "play", "next"]
                delegate: Rectangle {
                    required property string modelData
                    width: modelData === "play" ? 62 : 42; height: width; radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: modelData === "play" ? Atelier.accent : Atelier.surface
                    QQCImpl.IconImage {
                        anchors.centerIn: parent; width: 20; height: 20
                        source: Atelier.icon(parent.modelData === "play" ? (root.playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic") : parent.modelData === "previous" ? "media-skip-backward-symbolic" : "media-skip-forward-symbolic")
                        color: parent.modelData === "play" ? Atelier.onAccent : Atelier.text
                    }
                    HoverLayer {
                        tint: Atelier.gold
                        onClicked: {
                            if(!root.player) return;
                            if(parent.modelData === "play") root.player.togglePlaying();
                            else if(parent.modelData === "previous") root.player.previous();
                            else root.player.next();
                        }
                    }
                }
            }
        }
        Row {
            width: parent.width; spacing: 14
            Rectangle {
                width: 34; height: 34; radius: 17; color: root.sinkMuted ? Atelier.surface : "transparent"
                QQCImpl.IconImage { anchors.centerIn: parent; width: 16; height: 16; source: Atelier.icon(root.sinkMuted ? "audio-volume-muted-symbolic" : "audio-volume-high-symbolic"); color: Atelier.text }
                HoverLayer { tint: Atelier.accent; onClicked: root.toggleSinkMute() }
            }
            Slider {
                id: volume
                width: parent.width - 100; height: 34; from: 0; to: 1; value: root.sinkVolume
                onMoved: root.setSinkVolume(value)
                background: Rectangle { x: volume.leftPadding; y: 16; width: volume.availableWidth; height: 2; color: Atelier.rule; Rectangle { width: parent.width * volume.visualPosition; height: 2; color: Atelier.text } }
                handle: Rectangle { x: volume.leftPadding + volume.visualPosition * (volume.availableWidth - width); y: 12; width: 10; height: 10; radius: 5; color: Atelier.text }
            }
            AtelierText { anchors.verticalCenter: parent.verticalCenter; text: Math.round(root.sinkVolume * 100) + "%"; font.family: Atelier.mono; font.pixelSize: 11 }
        }
        Flow {
            width: parent.width; spacing: 8
            Repeater {
                model: root.players
                delegate: Rectangle {
                    required property var modelData
                    width: playerName.implicitWidth + 20; height: 28; radius: 14
                    color: modelData === root.player ? Atelier.surface : "transparent"
                    AtelierText { id: playerName; anchors.centerIn: parent; text: parent.modelData.identity || "Player"; font.pixelSize: 11 }
                    HoverLayer { tint: Atelier.accent; onClicked: root.selectPlayer(parent.modelData) }
                }
            }
        }
        Flow {
            width: parent.width; spacing: 8
            Repeater {
                model: root.sinks
                delegate: Rectangle {
                    required property var modelData
                    width: Math.min(outputName.implicitWidth + 20, contentColumn.width); height: 28; radius: 14; color: Atelier.surface
                    AtelierText { id: outputName; anchors.centerIn: parent; text: root.shortSinkName(parent.modelData.description || parent.modelData.name); font.pixelSize: 10; width: Math.min(implicitWidth, parent.width - 20); elide: Text.ElideRight }
                    HoverLayer { tint: Atelier.accent; onClicked: root.setDefaultSink(parent.modelData.name) }
                }
            }
        }
    }
}
