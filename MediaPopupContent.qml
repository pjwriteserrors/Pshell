pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as QQCImpl
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import "components"

// Media popup, redesigned around the cava visualizer:
// a full-width spectrum hero with the cover art and track info floating
// on top, a seekable progress bar, pill transport controls and player
// chips. Keeps the same external API as the old implementation.
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

	ExternalCava {
		id: cava
		bars: 40
		active: root.popupActive
	}

	Column {
		id: contentColumn
		width: parent.width
		spacing: 14

		// hero: spectrum with cover + titles floating on top
		Item {
			id: hero
			width: parent.width
			height: 190

			Row {
				id: spectrum
				anchors.fill: parent
				spacing: 3

				readonly property real barWidth: (width - (cava.bars - 1) * 3) / cava.bars

				Repeater {
					model: cava.bars

					delegate: Item {
						id: barSlot
						required property int index
						readonly property real level: cava.values[index] || 0

						width: spectrum.barWidth
						height: spectrum.height

						// Cilia: the sound as a bed of hairs standing up, lit from
						// the organ colour through to its neighbour along the row.
						// Silence has to look like silence, so at rest they all
						// but disappear instead of lying there as a dotted rule.
						Rectangle {
							anchors.bottom: parent.bottom
							anchors.horizontalCenter: parent.horizontalCenter
							width: Math.max(2, parent.width * 0.5)
							height: Math.max(2, barSlot.level * (parent.height - 8))
							radius: width / 2
							color: Qt.alpha(
								Bio.mix(Bio.organ, Bio.organAlt, barSlot.index / cava.bars),
								0.06 + 0.78 * barSlot.level
							)

							Behavior on height {
								NumberAnimation {
									duration: ThemeEngine.duration(70)
									easing.type: Easing.OutQuad
								}
							}
						}
					}
				}
			}

			Row {
				anchors.left: parent.left
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 6
				spacing: 12

				ClippingRectangle {
					width: 78
					height: 78
					radius: 3
					color: Bio.cavity

					BioFrame {
						anchors.fill: parent
						z: 2
						variant: "plate"
						weight: Bio.ribThin
						lineColor: Bio.boneDim
						liveColor: Bio.organ
					}

					Image {
						anchors.fill: parent
						source: root.coverSource
						visible: root.coverSource !== ""
						fillMode: Image.PreserveAspectCrop
						smooth: true
						mipmap: true
					}

					QQCImpl.IconImage {
						anchors.centerIn: parent
						visible: root.coverSource === ""
						width: 30
						height: 30
						source: "/usr/share/icons/Adwaita/symbolic/mimetypes/audio-x-generic-symbolic.svg"
						sourceSize: Qt.size(width, height)
						color: Qt.alpha(root.foreground, 0.65)
					}
				}

				Column {
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 4
					spacing: 2
					width: hero.width - 78 - 12

					BioText {
						width: parent.width
						role: "title"
						font.pixelSize: 17
						text: root.titleText
					}

					BioText {
						width: parent.width
						role: "body"
						tone: "muted"
						text: root.artistText
					}
				}
			}
		}

		// seekable progress
		Item {
			width: parent.width
			height: 26
			visible: root.hasPlayer

			BioText {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				role: "mono"
				tone: "faint"
				font.pixelSize: 10
				text: root.formatTime(root.trackPosition)
			}

			BioText {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				role: "mono"
				tone: "faint"
				font.pixelSize: 10
				text: root.hasProgress ? root.formatTime(root.trackLength) : "--"
			}

			Item {
				id: seekTrack
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.leftMargin: 42
				anchors.rightMargin: 42
				anchors.verticalCenter: parent.verticalCenter
				height: 10

				BioMeter {
					anchors.fill: parent
					value: root.hasProgress ? root.trackPosition / root.trackLength : 0
					fillColor: Bio.organ
					trackColor: Bio.boneGhost
				}

				MouseArea {
					anchors.fill: parent
					anchors.margins: -6
					cursorShape: Qt.PointingHandCursor
					onClicked: mouse => {
						if (!root.hasProgress || !(root.player?.canSeek ?? false))
							return;
						const ratio = Math.max(0, Math.min(1, mouse.x / seekTrack.width));
						root.player.position = ratio * root.trackLength;
					}
				}
			}
		}

		// transport controls
		Row {
			anchors.horizontalCenter: parent.horizontalCenter
			spacing: 18

			BioNode {
				anchors.verticalCenter: parent.verticalCenter
				size: 38
				seed: 0
				iconSource: "/usr/share/icons/Adwaita/symbolic/actions/media-skip-backward-symbolic.svg"
				onClicked: root.player?.previous()
			}

			// The heart: the one control in the chamber that is bigger than
			// the others, and the only one that changes size when it beats.
			BioNode {
				anchors.verticalCenter: parent.verticalCenter
				size: 54
				seed: 2
				lit: root.playing
				iconSize: 20
				iconColor: root.playing ? Bio.organ : Bio.text
				iconSource: root.playing
					? "/usr/share/icons/Adwaita/symbolic/actions/media-playback-pause-symbolic.svg"
					: "/usr/share/icons/Adwaita/symbolic/actions/media-playback-start-symbolic.svg"
				onClicked: root.player?.togglePlaying()

				scale: root.playing ? 1 : 0.94

				Behavior on scale {
					NumberAnimation { duration: Bio.grow; easing.type: Easing.OutBack }
				}
			}

			BioNode {
				anchors.verticalCenter: parent.verticalCenter
				size: 38
				seed: 3
				iconSource: "/usr/share/icons/Adwaita/symbolic/actions/media-skip-forward-symbolic.svg"
				onClicked: root.player?.next()
			}
		}

		// output volume — integrated slider row
		Item {
			width: parent.width
			height: 40

			BioNode {
				id: muteButton
				size: 32
				seed: 1
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				lit: root.sinkMuted
				liveColor: root.sinkMuted ? Bio.necrosis : Bio.organ
				iconColor: root.sinkMuted ? Bio.necrosis : Bio.text
				onClicked: root.toggleSinkMute()

				iconSource: root.sinkMuted
						? "/usr/share/icons/Adwaita/symbolic/status/audio-volume-muted-symbolic.svg"
						: (root.sinkVolume < 0.34
							? "/usr/share/icons/Adwaita/symbolic/status/audio-volume-low-symbolic.svg"
							: (root.sinkVolume < 0.67
								? "/usr/share/icons/Adwaita/symbolic/status/audio-volume-medium-symbolic.svg"
								: "/usr/share/icons/Adwaita/symbolic/status/audio-volume-high-symbolic.svg"))
			}

			Item {
				id: volumeTrack
				anchors.left: muteButton.right
				anchors.leftMargin: 12
				anchors.right: volumeLabel.left
				anchors.rightMargin: 12
				anchors.verticalCenter: parent.verticalCenter
				height: 12

				BioMeter {
					anchors.fill: parent
					value: Math.min(1, root.sinkVolume)
					fillColor: root.sinkMuted ? Bio.boneDim : Bio.organ
					trackColor: Bio.boneGhost
				}

				MouseArea {
					anchors.fill: parent
					anchors.margins: -8
					cursorShape: Qt.PointingHandCursor
					onPressed: mouse => root.setSinkVolume(mouse.x / volumeTrack.width)
					onPositionChanged: mouse => {
						if (pressed) root.setSinkVolume(mouse.x / volumeTrack.width);
					}
				}
			}

			BioText {
				id: volumeLabel
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				width: 34
				horizontalAlignment: Text.AlignRight
				role: "mono"
				tone: "muted"
				font.pixelSize: 11
				font.weight: Font.DemiBold
				text: root.sinkMuted ? "mute" : `${Math.round(root.sinkVolume * 100)}%`
			}
		}

		// output devices — integrated rows
		Column {
			width: parent.width
			spacing: 6
			visible: root.sinks.length > 1

			BioText {
				role: "label"
				tone: "muted"
				text: "Outflow"
			}

			Repeater {
				model: root.sinks

				delegate: BioRow {
					id: sinkRow
					required property var modelData

					width: parent.width
					implicitHeight: 32
					selected: modelData.active
					onClicked: root.setDefaultSink(sinkRow.modelData.name)

					Row {
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						spacing: Bio.s3

						Rectangle {
							anchors.verticalCenter: parent.verticalCenter
							width: Bio.nodule * 2
							height: Bio.nodule * 2
							radius: width / 2
							color: sinkRow.modelData.active ? Bio.organ : Bio.boneFaint
						}

						BioText {
							anchors.verticalCenter: parent.verticalCenter
							width: parent.width - 20
							role: sinkRow.modelData.active ? "bodyStrong" : "body"
							tone: sinkRow.modelData.active ? "default" : "muted"
							text: root.shortSinkName(sinkRow.modelData.description)
						}
					}
				}
			}
		}

		// player chips
		Flow {
			width: parent.width
			spacing: 8
			visible: (root.players?.length ?? 0) > 1

			Repeater {
				model: root.players

				delegate: BioButton {
					id: playerChip
					required property var modelData
					readonly property bool active: modelData === root.player

					implicitHeight: 26
					lit: playerChip.active
					text: playerChip.modelData?.identity || "Player"
					onClicked: root.selectPlayer(playerChip.modelData)
				}
			}
		}
	}
}
