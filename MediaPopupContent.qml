pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import "components"

// What is playing, hung under the media bead. The cover is a small plane;
// beside it the title and, under the title, a wire with forty filaments
// hanging from it that fall with the sound (the rain of light). Progress is
// a wire with a spark you can drag. The transport is three beads, play the
// largest: pressing it lets a spark out that climbs to the top edge and on
// to the clock. Volume is a wire with a spark and a mute bead; the outputs
// hang from a small thread with the light on the one in use; the players
// are chips that light.
Item {
	id: page

	property real reveal: 1
	required property var media
	property bool popupActive: false

	signal sparkToClock()

	readonly property var player: media?.currentPlayer ?? null
	readonly property bool hasPlayer: !!player
	readonly property string titleText: player?.trackTitle || (hasPlayer ? (player?.identity || "Untitled") : "Nothing playing")
	readonly property string artistText: player?.trackArtist || (player?.identity || "")
	readonly property string coverSource: player?.trackArtUrl ?? ""
	readonly property bool playing: player?.isPlaying ?? false
	readonly property real trackLength: Math.max(1, Number(player?.length || 0))
	readonly property real trackPosition: Math.max(0, Math.min(trackLength, Number(player?.position || 0)))
	readonly property bool hasProgress: hasPlayer && Number(player?.length || 0) > 0
	readonly property bool canSeek: hasProgress && (player?.canSeek ?? false)
	readonly property var players: media?.uniquePlayers ?? []

	// ------------------------------------------------------------------ audio
	property real sinkVolume: 0
	property bool sinkMuted: false
	property var sinks: []

	function refreshAudio() {
		volumeReadProc.running = true;
		sinkListProc.running = true;
	}

	function setSinkVolume(value) {
		const v = Math.max(0, Math.min(1, value));
		page.sinkVolume = v;
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
		return n.length > 38 ? n.slice(0, 38) + "…" : n;
	}

	function formatTime(seconds) {
		const total = Math.max(0, Math.round(Number(seconds) || 0));
		const m = Math.floor(total / 60);
		const sec = total % 60;
		return `${m}:${sec < 10 ? "0" : ""}${sec}`;
	}

	function pressPlay() {
		if (!page.hasPlayer) return;
		const starting = !page.playing;
		page.player.togglePlaying();
		if (starting) rise.launch();
	}

	onPopupActiveChanged: {
		if (popupActive) refreshAudio();
		else { rise.stop(); flyingSpark.visible = false; }
	}

	Process {
		id: volumeReadProc
		command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
		stdout: StdioCollector {
			onStreamFinished: {
				const raw = String(text || "");
				const match = raw.match(/Volume:\s*([0-9.]+)/);
				if (match) page.sinkVolume = Math.max(0, Math.min(1.5, Number(match[1])));
				page.sinkMuted = raw.includes("[MUTED]");
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
					for (const sink of JSON.parse(raw.slice(0, sep)))
						next.push({ active: sink.name === defaultName, name: sink.name, description: sink.description || sink.name });
				} catch (e) {
					return;
				}
				page.sinks = next;
			}
		}
	}

	Timer { id: audioRefreshTimer; interval: 250; repeat: false; onTriggered: page.refreshAudio() }
	Timer { running: page.popupActive; repeat: true; interval: 3000; onTriggered: page.refreshAudio() }
	Timer { running: page.popupActive && page.playing; repeat: true; interval: 500; onTriggered: page.player?.positionChanged() }

	ExternalCava {
		id: cava
		bars: 40
		active: page.popupActive
	}

	implicitHeight: column.implicitHeight

	Column {
		id: column
		width: parent.width
		spacing: 12

		// ------------------------------------------------ cover, title, rain
		Band {
			reveal: page.reveal; order: 0
			width: parent.width; height: 84

			ClippingRectangle {
				id: cover
				anchors.left: parent.left
				anchors.top: parent.top
				width: 84; height: 84
				radius: Filament.radius
				color: Filament.well
				Image {
					anchors.fill: parent
					source: page.coverSource
					visible: page.coverSource !== ""
					fillMode: Image.PreserveAspectCrop
					smooth: true
					mipmap: true
					asynchronous: true
				}
				FIcon {
					anchors.centerIn: parent
					visible: page.coverSource === ""
					name: "audio-x-generic-symbolic"
					size: 28
					color: Filament.inkFaint
				}
			}

			Item {
				id: words
				anchors.left: cover.right
				anchors.leftMargin: 14
				anchors.right: parent.right
				anchors.top: parent.top
				height: parent.height

				FText {
					id: title
					anchors.left: parent.left
					anchors.right: parent.right
					y: 0
					text: page.titleText
					font.pixelSize: Filament.textLg
					font.weight: Font.DemiBold
					color: page.hasPlayer ? Filament.ink : Filament.inkMute
				}
				FText {
					anchors.left: parent.left
					anchors.right: parent.right
					y: 21
					text: page.hasPlayer ? page.artistText : "open a player and it will hang here"
					tone: page.hasPlayer ? "soft" : "faint"
					font.pixelSize: Filament.textSm
				}

				// The rain: forty filaments hanging from a wire, each as long as its band is loud.
				Wire {
					id: rainWire
					anchors.left: parent.left
					anchors.right: parent.right
					y: 44
					height: 2
					cold: Filament.wireDim
					hot: Filament.charge
					lit: page.playing ? 1 : 0
					glow: false
				}
				Item {
					id: rain
					anchors.left: parent.left
					anchors.right: parent.right
					y: 45
					height: 39
					readonly property real pitch: width / cava.bars
					Repeater {
						model: cava.bars
						Rectangle {
							id: drop
							required property int index
							readonly property real level: cava.values[index] || 0
							x: Math.round(index * rain.pitch + rain.pitch / 2 - 1)
							y: 0
							width: 2
							height: Math.max(2, Math.round(level * rain.height))
							radius: 1
							color: Qt.alpha(Filament.charge, 0.25 + 0.75 * level)
							Behavior on height { NumberAnimation { duration: 70; easing.type: Easing.OutQuad } }
						}
					}
				}
			}
		}

		// ------------------------------------------------------- progress
		Band {
			reveal: page.reveal; order: 1
			width: parent.width; height: 24

			FText {
				id: posLabel
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				width: 38
				text: page.formatTime(seek.dragging ? seek.value * page.trackLength : page.trackPosition)
				mono: true
				tone: page.hasProgress ? "soft" : "faint"
				font.pixelSize: Filament.textXs
			}
			FSlider {
				id: seek
				anchors.left: posLabel.right
				anchors.right: lenLabel.left
				anchors.leftMargin: 4
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				value: page.hasProgress ? page.trackPosition / page.trackLength : 0
				step: 0.02
				enabled: page.canSeek
				muted: !page.hasProgress
				opacity: page.hasProgress ? 1 : 0.5
				labelFor: v => page.formatTime(v * page.trackLength)
				onReleased: v => {
					if (page.canSeek) page.player.position = v * page.trackLength;
					value = Qt.binding(() => page.hasProgress ? page.trackPosition / page.trackLength : 0);
				}
			}
			FText {
				id: lenLabel
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				width: 38
				horizontalAlignment: Text.AlignRight
				text: page.hasProgress ? page.formatTime(page.trackLength) : "--:--"
				mono: true
				tone: page.hasProgress ? "soft" : "faint"
				font.pixelSize: Filament.textXs
			}
		}

		// ------------------------------------------------ transport, volume
		Band {
			reveal: page.reveal; order: 2
			width: parent.width; height: 44

			// The volume: a mute bead and a wire with a spark.
			FButton {
				id: muteButton
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				icon: page.sinkMuted ? "audio-volume-muted-symbolic"
					: (page.sinkVolume < 0.34 ? "audio-volume-low-symbolic" : (page.sinkVolume < 0.67 ? "audio-volume-medium-symbolic" : "audio-volume-high-symbolic"))
				iconSize: 14
				kind: page.sinkMuted ? "alert" : "ghost"
				square: true
				compact: true
				onClicked: page.toggleSinkMute()
			}
			FSlider {
				id: volume
				anchors.left: muteButton.right
				anchors.leftMargin: 6
				anchors.verticalCenter: parent.verticalCenter
				width: 112
				value: Math.min(1, page.sinkVolume)
				step: 0.05
				muted: page.sinkMuted
				onMoved: v => page.setSinkVolume(v)
				onReleased: v => {
					page.setSinkVolume(v);
					audioRefreshTimer.restart();
					value = Qt.binding(() => Math.min(1, page.sinkVolume));
				}
			}
			FText {
				anchors.left: volume.right
				anchors.leftMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				text: page.sinkMuted ? "mute" : `${Math.round(page.sinkVolume * 100)}%`
				mono: true
				tone: page.sinkMuted ? "alert" : "mute"
				font.pixelSize: Filament.textXs
			}

			// The transport: three beads, play the largest.
			Row {
				id: transport
				anchors.right: parent.right
				anchors.rightMargin: 6
				anchors.verticalCenter: parent.verticalCenter
				spacing: 10
				opacity: page.hasPlayer ? 1 : 0.4

				Bead {
					anchors.verticalCenter: parent.verticalCenter
					beadHeight: 30
					padding: 9
					interactive: page.hasPlayer
					onClicked: page.player?.previous()
					FIcon { name: "media-skip-backward-symbolic"; size: 13; color: Filament.inkSoft }
				}
				Bead {
					id: playBead
					anchors.verticalCenter: parent.verticalCenter
					beadHeight: 40
					padding: 12
					lit: page.playing
					interactive: page.hasPlayer
					fill: page.playing ? Filament.charge : Filament.planeSolid
					onClicked: page.pressPlay()
					FIcon {
						name: page.playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"
						size: 18
						color: page.playing ? Filament.onCharge : Filament.ink
					}
				}
				Bead {
					anchors.verticalCenter: parent.verticalCenter
					beadHeight: 30
					padding: 9
					interactive: page.hasPlayer
					onClicked: page.player?.next()
					FIcon { name: "media-skip-forward-symbolic"; size: 13; color: Filament.inkSoft }
				}
			}
		}

		// ------------------------------------------------- outputs, players
		Item {
			width: parent.width
			height: sinkList.y + sinkList.height
			visible: page.sinks.length > 0 || page.players.length > 1

			Band {
				id: outputHead
				reveal: page.reveal; order: 3
				width: parent.width; height: 20
				FText {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					text: "output"
					caps: true
					tone: "mute"
					font.pixelSize: Filament.textXs
					visible: page.sinks.length > 0
				}
				// The players, as chips that light.
				Row {
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					spacing: 6
					visible: page.players.length > 1
					Repeater {
						model: page.players
						Item {
							id: chipSlot
							required property var modelData
							readonly property bool active: modelData === page.player
							width: chip.implicitWidth
							height: chip.implicitHeight
							MouseArea {
								anchors.fill: parent
								cursorShape: Qt.PointingHandCursor
								onClicked: page.media.setCurrentPlayer(chipSlot.modelData)
							}
							Chip {
								id: chip
								text: chipSlot.modelData?.identity || "Player"
								mono: false
								lit: chipSlot.active
							}
						}
					}
				}
			}

			ThreadLine {
				x: 7
				y: sinkList.y
				height: sinkList.height
				litY: {
					const i = page.sinks.findIndex(s => s.active);
					return i >= 0 ? i * 26 + 13 : -1;
				}
				litLength: 22
				visible: page.sinks.length > 0
				opacity: Filament.band(page.reveal, 4)
			}

			Column {
				id: sinkList
				x: 8
				y: outputHead.height + 6
				width: parent.width - 8
				spacing: 0
				Repeater {
					model: page.sinks
					ThreadRow {
						id: sinkRow
						required property var modelData
						required property int index
						width: sinkList.width
						height: 26
						inset: 14
						selected: modelData?.active ?? false
						opacity: Filament.band(page.reveal, 4 + Math.min(index, 4))
						onClicked: page.setDefaultSink(modelData?.name)
						FText {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							text: page.shortSinkName(sinkRow.modelData?.description)
							font.pixelSize: Filament.textSm
							color: sinkRow.selected ? Filament.ink : (sinkRow.hovered ? Filament.inkSoft : Filament.inkMute)
							font.weight: sinkRow.selected ? Font.DemiBold : Font.Normal
							Behavior on color { ColorAnimation { duration: Filament.quick } }
						}
					}
				}
			}
		}
	}

	// The spark play lets out: it leaves the play bead and climbs to the top edge.
	Spark {
		id: flyingSpark
		size: 9
		visible: false
		z: 10
	}

	SequentialAnimation {
		id: rise
		function launch() {
			stop();
			const at = playBead.mapToItem(page, playBead.width / 2, 0);
			flyingSpark.x = at.x - flyingSpark.size / 2;
			flyingSpark.y = at.y - flyingSpark.size / 2;
			flyingSpark.visible = true;
			start();
		}
		NumberAnimation {
			target: flyingSpark; property: "y"; to: -Filament.pad - flyingSpark.size / 2
			duration: Filament.travelTime(flyingSpark.y + Filament.pad)
			easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeTravel
		}
		ScriptAction { script: { flyingSpark.visible = false; page.sparkToClock(); } }
	}
}
