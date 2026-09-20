pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as QQCImpl
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import "components"
import "components/ArcInk.js" as Ink

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

		// THE CONSORT.
		//
		// What is playing is a disc, and it turns while it is playing. The
		// artwork is cut round; the position is a ring drawn round that; and
		// the sound itself stands off the rim as rays rather than as a row of
		// bars along the bottom — so the whole thing is one object with the
		// music coming out of it, which is what a consort is.
		Item {
			id: hero
			width: parent.width
			height: 250

			readonly property real discSize: 132

			// The sound, thrown off the rim.
			Canvas {
				id: rays
				anchors.centerIn: disc
				width: hero.discSize * 2.4
				height: hero.discSize * 2.4
				renderStrategy: Canvas.Cooperative

				property int tick: 0

				Connections {
					target: cava
					function onValuesChanged() { rays.tick += 1; rays.requestPaint(); }
				}

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					const cx = width / 2, cy = height / 2;
					const inner = hero.discSize / 2 + 12;
					const count = cava.bars;
					if (!count) return;
					for (let index = 0; index < count; index++) {
						const level = cava.values[index] || 0;
						const angle = -Math.PI / 2 + Math.PI * 2 * index / count;
						const outer = inner + 6 + level * (width / 2 - inner - 10);
						const tint = Arc.mix(Arc.aether, Arc.aetherAlt, index / count);
						Ink.ley(ctx,
							cx + Math.cos(angle) * inner, cy + Math.sin(angle) * inner,
							cx + Math.cos(angle) * outer, cy + Math.sin(angle) * outer,
							2.0, Qt.alpha(tint, 0.10 + level * 0.8), null, -1);
					}
				}
			}

			ArcHalo {
				anchors.centerIn: disc
				width: hero.discSize * 2.1
				height: hero.discSize * 2.1
				color: Arc.aether
				strength: 0.20
				spread: 0.32
				flicker: true
			}

			// The disc.
			Item {
				id: disc
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.top: parent.top
				width: hero.discSize
				height: hero.discSize

				property real spin: 0

				NumberAnimation on spin {
					running: root.isPlaying
					loops: Animation.Infinite
					from: 0
					to: 360
					duration: 24000
				}

				ClippingRectangle {
					anchors.fill: parent
					anchors.margins: 9
					radius: width / 2
					color: Arc.depth
					rotation: disc.spin

					Image {
						anchors.fill: parent
						source: root.coverSource
						visible: root.coverSource !== ""
						fillMode: Image.PreserveAspectCrop
						smooth: true
						mipmap: true
					}

					ArcMark {
						anchors.centerIn: parent
						visible: root.coverSource === ""
						width: 40
						height: 40
						glyph: "chalice"
						lineColor: Arc.goldDim
					}
				}

				// The spindle hole, so it reads as a disc and not as a badge.
				Rectangle {
					anchors.centerIn: parent
					width: 14
					height: 14
					radius: 7
					color: Arc.depth
					border.width: Arc.ruleThin
					border.color: Arc.goldFaint
				}

				// How far through, taken round the rim.
				ArcDial {
					id: seekRing
					anchors.fill: parent
					lineColor: Qt.alpha(Arc.gold, 0.26)
					liveColor: Arc.aether
					weight: Arc.rule * 1.6
					seed: 1
					beading: false
					progress: root.hasProgress ? root.trackPosition / root.trackLength : -1

					MouseArea {
						anchors.fill: parent
						cursorShape: root.hasProgress ? Qt.PointingHandCursor : Qt.ArrowCursor
						acceptedButtons: Qt.LeftButton
						onClicked: mouse => {
							if (!root.hasProgress || !(root.player?.canSeek ?? false)) return;
							// Seeking is turning the disc: the angle you press
							// at from the twelve is the place in the track.
							const dx = mouse.x - width / 2, dy = mouse.y - height / 2;
							if (Math.sqrt(dx * dx + dy * dy) < width / 2 - 18) return;
							let angle = Math.atan2(dy, dx) + Math.PI / 2;
							if (angle < 0) angle += Math.PI * 2;
							root.player.position = angle / (Math.PI * 2) * root.trackLength;
						}
					}
				}
			}

			Column {
				anchors.top: disc.bottom
				anchors.topMargin: Arc.s4
				anchors.left: parent.left
				anchors.right: parent.right
				spacing: -1

				ArcText {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					role: "display"
					font.pixelSize: 19
					text: root.titleText
				}

				ArcText {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					role: "hand"
					tone: "muted"
					font.pixelSize: 15
					text: root.artistText
				}

				ArcText {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					role: "mono"
					tone: "faint"
					font.pixelSize: 10
					visible: root.hasPlayer
					text: root.hasProgress
						? `${root.formatTime(root.trackPosition)} · ${root.formatTime(root.trackLength)}`
						: root.formatTime(root.trackPosition)
				}
			}
		}

		// transport controls
		Row {
			anchors.horizontalCenter: parent.horizontalCenter
			spacing: 18

			ArcSeat {
				anchors.verticalCenter: parent.verticalCenter
				size: 38
				seed: 0
				iconSource: "/usr/share/icons/Adwaita/symbolic/actions/media-skip-backward-symbolic.svg"
				onClicked: root.player?.previous()
			}

			// The heart: the one control in the chamber that is bigger than
			// the others, and the only one that changes size when it beats.
			ArcSeat {
				anchors.verticalCenter: parent.verticalCenter
				size: 54
				seed: 2
				lit: root.playing
				iconSize: 20
				iconColor: root.playing ? Arc.aether : Arc.ink
				iconSource: root.playing
					? "/usr/share/icons/Adwaita/symbolic/actions/media-playback-pause-symbolic.svg"
					: "/usr/share/icons/Adwaita/symbolic/actions/media-playback-start-symbolic.svg"
				onClicked: root.player?.togglePlaying()

				scale: root.playing ? 1 : 0.94

				Behavior on scale {
					NumberAnimation { duration: Arc.turn; easing.type: Easing.OutBack }
				}
			}

			ArcSeat {
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

			ArcSeat {
				id: muteButton
				size: 32
				seed: 1
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				lit: root.sinkMuted
				liveColor: root.sinkMuted ? Arc.bane : Arc.aether
				iconColor: root.sinkMuted ? Arc.bane : Arc.ink
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

				ArcPhial {
					anchors.fill: parent
					value: Math.min(1, root.sinkVolume)
					fillColor: root.sinkMuted ? Arc.goldDim : Arc.aether
					trackColor: Arc.goldGhost
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

			ArcText {
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

			ArcText {
				role: "label"
				tone: "muted"
				text: "Outflow"
			}

			Repeater {
				model: root.sinks

				delegate: ArcEntry {
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
						spacing: Arc.s3

						Rectangle {
							anchors.verticalCenter: parent.verticalCenter
							width: Arc.mote * 2
							height: Arc.mote * 2
							radius: width / 2
							color: sinkRow.modelData.active ? Arc.aether : Arc.goldFaint
						}

						ArcText {
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

				delegate: ArcButton {
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
