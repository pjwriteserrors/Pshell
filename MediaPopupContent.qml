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
	}

	Column {
		id: contentColumn
		width: parent.width
		spacing: 14

		// hero: spectrum with cover + titles floating on top
		Item {
			id: hero
			width: parent.width
			height: 148

			Row {
				id: spectrum
				anchors.fill: parent
				opacity: 0.2
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

						ThemedRectangle {
							anchors.bottom: parent.bottom
							width: parent.width
							height: Math.max(5, barSlot.level * (parent.height - 8))
							radius: width / 2
							color: Qt.alpha(
								Qt.tint(root.primary, Qt.alpha(root.accent, barSlot.index / cava.bars)),
								0.3 + 0.55 * barSlot.level
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
					radius: ThemeEngine.radiusMedium
					color: root.secondaryBoxColor

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

					AtelierText {
						width: parent.width
						color: root.foreground
						display: true
    font.pixelSize: 24
						font.weight: Font.DemiBold
						elide: Text.ElideRight
						text: root.titleText

						// soft backdrop so the title stays readable over the bars
						ThemedRectangle {
							anchors.fill: parent
							anchors.margins: -4
							z: -1
							radius: ThemeEngine.radiusLarge
							color: Qt.alpha(root.secondaryBoxColor, 0.001)
						}
					}

					AtelierText {
						width: parent.width
						color: Qt.alpha(root.foreground, 0.7)
						font.pixelSize: 12
						elide: Text.ElideRight
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

			AtelierText {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				color: Qt.alpha(root.foreground, 0.65)
				font.pixelSize: 10
				font.weight: Font.Medium
				text: root.formatTime(root.trackPosition)
			}

			AtelierText {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				color: Qt.alpha(root.foreground, 0.65)
				font.pixelSize: 10
				font.weight: Font.Medium
				text: root.hasProgress ? root.formatTime(root.trackLength) : "--"
			}

			ThemedRectangle {
				id: seekTrack
				themeStyle: "inset"
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.leftMargin: 42
				anchors.rightMargin: 42
				anchors.verticalCenter: parent.verticalCenter
				height: 6
				radius: ThemeEngine.radiusTiny
				color: Qt.alpha(root.foreground, 0.15)

				ThemedRectangle {
					themeStyle: "flat"
					width: parent.width * (root.hasProgress ? root.trackPosition / root.trackLength : 0)
					height: parent.height
					radius: parent.radius
					color: root.primary

					Behavior on width {
						Anim {
							duration: Motion.fast
						}
					}

					ThemedRectangle {
						themeStyle: "raised"
						visible: root.hasProgress
						width: 12
						height: 12
						radius: ThemeEngine.radiusSmall
						anchors.verticalCenter: parent.verticalCenter
						anchors.right: parent.right
						anchors.rightMargin: -6
						color: root.foreground
					}
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

			ThemedRectangle {
				width: 42
				height: 42
				radius: ThemeEngine.radiusMedium
				color: root.secondaryBoxColor
				anchors.verticalCenter: parent.verticalCenter

				QQCImpl.IconImage {
					anchors.centerIn: parent
					width: 16
					height: 16
					source: "/usr/share/icons/Adwaita/symbolic/actions/media-skip-backward-symbolic.svg"
					sourceSize: Qt.size(width, height)
					color: root.foreground
				}

				HoverLayer {
					tint: root.primary
					onClicked: root.player?.previous()
				}
			}

			ThemedRectangle {
				width: 56
				height: 56
				radius: ThemeEngine.radiusMedium
				color: root.primary
				scale: root.playing ? 1 : 0.94

				Behavior on scale {
					SpatialAnim {}
				}

				QQCImpl.IconImage {
					anchors.centerIn: parent
					width: 22
					height: 22
					source: root.playing
						? "/usr/share/icons/Adwaita/symbolic/actions/media-playback-pause-symbolic.svg"
						: "/usr/share/icons/Adwaita/symbolic/actions/media-playback-start-symbolic.svg"
					sourceSize: Qt.size(width, height)
					color: root.onPrimaryColor
				}

				HoverLayer {
					tint: root.onPrimaryColor
					onClicked: root.player?.togglePlaying()
				}
			}

			ThemedRectangle {
				width: 42
				height: 42
				radius: ThemeEngine.radiusMedium
				color: root.secondaryBoxColor
				anchors.verticalCenter: parent.verticalCenter

				QQCImpl.IconImage {
					anchors.centerIn: parent
					width: 16
					height: 16
					source: "/usr/share/icons/Adwaita/symbolic/actions/media-skip-forward-symbolic.svg"
					sourceSize: Qt.size(width, height)
					color: root.foreground
				}

				HoverLayer {
					tint: root.primary
					onClicked: root.player?.next()
				}
			}
		}

		// output volume — integrated slider row
		Item {
			width: parent.width
			height: 40

			ThemedRectangle {
				id: muteButton
				width: 34
				height: 34
				radius: ThemeEngine.radiusMedium
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				color: root.sinkMuted ? Qt.alpha(root.accent, 0.35) : root.secondaryBoxColor

				Behavior on color {
					CAnim {}
				}

				QQCImpl.IconImage {
					anchors.centerIn: parent
					width: 15
					height: 15
					source: root.sinkMuted
						? "/usr/share/icons/Adwaita/symbolic/status/audio-volume-muted-symbolic.svg"
						: (root.sinkVolume < 0.34
							? "/usr/share/icons/Adwaita/symbolic/status/audio-volume-low-symbolic.svg"
							: (root.sinkVolume < 0.67
								? "/usr/share/icons/Adwaita/symbolic/status/audio-volume-medium-symbolic.svg"
								: "/usr/share/icons/Adwaita/symbolic/status/audio-volume-high-symbolic.svg"))
					sourceSize: Qt.size(width, height)
					color: root.foreground
				}

				HoverLayer {
					tint: root.foreground
					onClicked: root.toggleSinkMute()
				}
			}

			ThemedRectangle {
				id: volumeTrack
				themeStyle: "inset"
				anchors.left: muteButton.right
				anchors.leftMargin: 12
				anchors.right: volumeLabel.left
				anchors.rightMargin: 12
				anchors.verticalCenter: parent.verticalCenter
				height: 3
				radius: ThemeEngine.radiusSmall
				color: Qt.alpha(root.foreground, 0.2)

				ThemedRectangle {
					themeStyle: "flat"
					width: parent.width * Math.min(1, root.sinkVolume)
					height: parent.height
					radius: parent.radius
					color: root.sinkMuted ? Qt.alpha(root.foreground, 0.3) : root.primary

					Behavior on width {
						Anim {
							duration: Motion.fast
						}
					}

					Behavior on color {
						CAnim {}
					}

					ThemedRectangle {
						themeStyle: "raised"
						width: 14
						height: 14
						radius: height / 2
						anchors.verticalCenter: parent.verticalCenter
						anchors.right: parent.right
						anchors.rightMargin: -7
						color: root.foreground
					}
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

			AtelierText {
				id: volumeLabel
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				width: 34
				horizontalAlignment: Text.AlignRight
				color: Qt.alpha(root.foreground, 0.75)
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

			AtelierText {
				color: Qt.alpha(root.primary, 0.95)
				font.pixelSize: 9
				font.weight: Font.DemiBold
				font.letterSpacing: 1
				text: "OUTPUT"
			}

			Repeater {
				model: root.sinks

				delegate: ThemedRectangle {
					id: sinkRow
					required property var modelData

					width: parent.width
					height: 36
					radius: ThemeEngine.radiusMedium
					color: modelData.active ? Qt.alpha(root.primary, 0.24) : root.secondaryBoxColor
					border.width: modelData.active ? 1 : 0
					border.color: Qt.alpha(root.primary, 0.5)

					Behavior on color {
						CAnim {}
					}

					Row {
						anchors.left: parent.left
						anchors.leftMargin: 12
						anchors.right: parent.right
						anchors.rightMargin: 12
						anchors.verticalCenter: parent.verticalCenter
						spacing: 10

						ThemedRectangle {
							width: 10
							height: 10
							radius: height / 2
							anchors.verticalCenter: parent.verticalCenter
							color: sinkRow.modelData.active ? root.primary : "transparent"
							border.width: 1.4
							border.color: sinkRow.modelData.active ? root.primary : Qt.alpha(root.foreground, 0.4)

							Behavior on color {
								CAnim {}
							}
						}

						AtelierText {
							anchors.verticalCenter: parent.verticalCenter
							width: parent.width - 20
							color: root.foreground
							font.pixelSize: 11
							font.weight: sinkRow.modelData.active ? Font.DemiBold : Font.Normal
							elide: Text.ElideRight
							text: root.shortSinkName(sinkRow.modelData.description)
						}
					}

					HoverLayer {
						tint: root.foreground
						onClicked: root.setDefaultSink(sinkRow.modelData.name)
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

				delegate: ThemedRectangle {
					id: playerChip
					required property var modelData
					readonly property bool active: modelData === root.player

					width: chipLabel.implicitWidth + 26
					height: 28
					radius: ThemeEngine.radiusMedium
					color: active ? root.primary : root.secondaryBoxColor

					Behavior on color {
						CAnim {}
					}

					AtelierText {
						id: chipLabel
						anchors.centerIn: parent
						color: playerChip.active ? root.onPrimaryColor : root.foreground
						font.pixelSize: 11
						font.weight: Font.Medium
						text: playerChip.modelData?.identity || "Player"
					}

					HoverLayer {
						tint: playerChip.active ? root.onPrimaryColor : root.foreground
						onClicked: root.selectPlayer(playerChip.modelData)
					}
				}
			}
		}
	}
}
