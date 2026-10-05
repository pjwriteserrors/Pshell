pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell.Widgets
import Quickshell.Services.Mpris
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.media

// Now playing. The blurred cover tints the panel, the live spectrum breathes
// behind the controls, the seek bar thickens under the pointer and shows the
// time you are about to jump to.
Drawer {
	id: root

	property bool showOutputs: false

	panelId: "media"
	panelWidth: 480
	padding: 0
	contentHeight: layout.implicitHeight + Theme.panelPadding * 2

	onPanelOpened: {
		root.showOutputs = false;
		Audio.refreshSinks();
	}

	Binding {
		target: Lyrics
		property: "watching"
		value: root.shown
	}

	Item {
		anchors.fill: parent
		clip: true

		// cover blur, tint and spectrum, cut to the panel silhouette: round
		// bottom corners, and faded out at the top so the panel keeps flowing
		// out of the bar through its fillets
		Item {
			anchors.fill: parent
			layer.enabled: true
			layer.effect: MultiEffect {
				maskEnabled: true
				maskSource: backdropMask
				maskThresholdMin: 0.5
				maskSpreadAtMin: 0.5
			}

			Image {
				id: backdrop

				anchors.fill: parent
				source: Media.art
				fillMode: Image.PreserveAspectCrop
				visible: false
				asynchronous: true
			}

			MultiEffect {
				anchors.fill: parent
				source: backdrop
				visible: Media.art !== "" && backdrop.status === Image.Ready
				blurEnabled: true
				blur: 1
				blurMax: 64
				saturation: 0.2
				opacity: 0.38
			}

			Rectangle {
				anchors.fill: parent
				gradient: Gradient {
					GradientStop { position: 0; color: Qt.alpha(Theme.base, 0.2) }
					GradientStop { position: 0.55; color: Qt.alpha(Theme.base, 0.75) }
					GradientStop { position: 1; color: Theme.base }
				}
			}

			ExternalCava {
				id: cava

				bars: 48
				active: root.shown && Media.playing
			}

			Row {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.topMargin: 60
				height: 150
				spacing: 3
				opacity: 0.55

				Repeater {
					model: cava.bars

					delegate: Item {
						id: slot

						required property int index
						readonly property real level: cava.values[slot.index] || 0

						width: (parent.width - (cava.bars - 1) * 3) / cava.bars
						height: parent.height

						Rectangle {
							anchors.bottom: parent.bottom
							width: parent.width
							height: Math.max(3, slot.level * parent.height)
							radius: width / 2
							color: Qt.alpha(Qt.tint(Theme.primary, Qt.alpha(Theme.secondary, slot.index / cava.bars)), 0.35 + 0.5 * slot.level)

							Behavior on height {
								NumberAnimation {
									duration: 80
									easing.type: Easing.OutQuad
								}
							}
						}
					}
				}
			}
		}

		Rectangle {
			id: backdropMask

			anchors.fill: parent
			visible: false
			layer.enabled: true
			bottomLeftRadius: Theme.panelRadius
			bottomRightRadius: Theme.panelRadius
			gradient: Gradient {
				GradientStop { position: 0; color: "transparent" }
				GradientStop { position: Math.min(0.5, 70 / Math.max(1, backdropMask.height)); color: "white" }
				GradientStop { position: 1; color: "white" }
			}
		}

		ColumnLayout {
			id: layout

			x: Theme.panelPadding
			y: Theme.panelPadding
			width: parent.width - Theme.panelPadding * 2
			spacing: 16

			RowLayout {
				Layout.fillWidth: true
				spacing: 16

				ClippingRectangle {
					Layout.preferredWidth: 112
					Layout.preferredHeight: 112
					radius: Theme.radius.huge
					color: Theme.layer2
					scale: Media.playing ? 1 : 0.92

					Behavior on scale {
						SpatialAnim {
							duration: Motion.long
						}
					}

					Image {
						anchors.fill: parent
						source: Media.art
						visible: Media.art !== ""
						fillMode: Image.PreserveAspectCrop
						asynchronous: true
						smooth: true
						mipmap: true
					}

					Glyph {
						anchors.centerIn: parent
						visible: Media.art === ""
						icon: "music"
						size: 44
						color: Theme.textSubtle
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					Layout.alignment: Qt.AlignBottom
					spacing: 3

					SectionLabel {
						text: Media.player?.identity ?? "No player"
					}

					StyledText {
						Layout.fillWidth: true
						text: Media.title
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
						wrapMode: Text.WordWrap
						maximumLineCount: 2
					}

					StyledText {
						Layout.fillWidth: true
						text: Media.artist
						visible: text !== ""
						tone: Theme.textMuted
						font.pixelSize: Theme.size.body
					}
				}

				ColumnLayout {
					Layout.alignment: Qt.AlignTop
					spacing: 4

					IconButton {
						visible: Plugins.on("song-detection")
						icon: "waveform"
						iconSize: 18
						checked: SongDetect.listening
						onClicked: SongDetect.toggle()
					}

					IconButton {
						visible: Plugins.on("lyrics")
						icon: "microphone_variant"
						iconSize: 18
						checked: Lyrics.open
						onClicked: Lyrics.toggle()
					}
				}
			}

			// seek
			Item {
				id: seek

				Layout.fillWidth: true
				Layout.topMargin: 36
				implicitHeight: 34
				visible: Media.hasPlayer

				readonly property real ratio: Media.hasProgress ? Media.position / Media.length : 0
				readonly property bool engaged: seekMouse.containsMouse || seekMouse.pressed

				Rectangle {
					id: track

					anchors.left: parent.left
					anchors.right: parent.right
					y: 4
					height: seek.engaged ? 10 : 5
					radius: height / 2
					color: Qt.alpha(Theme.text, 0.14)

					Behavior on height {
						SpatialAnim {
							duration: Motion.short
						}
					}

					Rectangle {
						height: parent.height
						radius: parent.radius
						width: parent.width * (seekMouse.pressed ? seekMouse.previewRatio : seek.ratio)
						color: Theme.primary

						Behavior on width {
							enabled: !seekMouse.pressed
							Anim {
								duration: Motion.short
							}
						}
					}

					Rectangle {
						visible: seek.engaged && Media.hasProgress
						x: parent.width * seekMouse.previewRatio - width / 2
						anchors.verticalCenter: parent.verticalCenter
						width: 3
						height: 16
						radius: 1.5
						color: Theme.text
					}
				}

				StyledText {
					anchors.left: parent.left
					anchors.bottom: parent.bottom
					text: Media.formatTime(Media.position)
					tabular: true
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				Rectangle {
					visible: seek.engaged && Media.hasProgress
					x: Math.max(0, Math.min(parent.width - width, parent.width * seekMouse.previewRatio - width / 2))
					anchors.bottom: parent.bottom
					height: 18
					width: previewLabel.implicitWidth + 12
					radius: 9
					color: Theme.primary

					StyledText {
						id: previewLabel

						anchors.centerIn: parent
						text: Media.formatTime(seekMouse.previewRatio * Media.length)
						tabular: true
						tone: Theme.onPrimary
						font.pixelSize: Theme.size.tiny
						font.weight: Font.Bold
					}
				}

				StyledText {
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					text: Media.hasProgress ? Media.formatTime(Media.length) : "--:--"
					tabular: true
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				MouseArea {
					id: seekMouse

					property real previewRatio: 0

					anchors.fill: parent
					hoverEnabled: true
					enabled: Media.hasProgress && (Media.player?.canSeek ?? false)
					cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
					onPositionChanged: event => seekMouse.previewRatio = Math.max(0, Math.min(1, event.x / width))
					onPressed: event => seekMouse.previewRatio = Math.max(0, Math.min(1, event.x / width))
					onReleased: Media.seek(seekMouse.previewRatio)
				}
			}

			// transport
			RowLayout {
				Layout.alignment: Qt.AlignHCenter
				spacing: 14

				IconButton {
					visible: Media.player?.shuffleSupported ?? false
					icon: "shuffle"
					iconSize: 18
					checked: Media.player?.shuffle ?? false
					onClicked: Media.player.shuffle = !Media.player.shuffle
				}

				IconButton {
					implicitWidth: 46
					implicitHeight: 46
					icon: "skip_previous"
					variant: "tonal"
					enabled: Media.player?.canGoPrevious ?? false
					onClicked: Media.player?.previous()
				}

				Clickable {
					implicitWidth: 64
					implicitHeight: 64
					radius: Media.playing ? 22 : 32
					color: Theme.primary
					tint: Theme.onPrimary
					pressedScale: 0.86
					interactive: Media.hasPlayer
					onClicked: Media.player?.togglePlaying()

					Behavior on radius {
						SpatialAnim {
							duration: Motion.long
						}
					}

					Glyph {
						anchors.centerIn: parent
						icon: Media.playing ? "pause" : "play"
						size: 30
						color: Theme.onPrimary
					}
				}

				IconButton {
					implicitWidth: 46
					implicitHeight: 46
					icon: "skip_next"
					variant: "tonal"
					enabled: Media.player?.canGoNext ?? false
					onClicked: Media.player?.next()
				}

				IconButton {
					visible: Media.player?.loopSupported ?? false
					icon: (Media.player?.loopState ?? MprisLoopState.None) === MprisLoopState.Track ? "repeat_once" : "repeat"
					iconSize: 18
					checked: (Media.player?.loopState ?? MprisLoopState.None) !== MprisLoopState.None
					onClicked: {
						const state = Media.player.loopState;
						Media.player.loopState = state === MprisLoopState.None ? MprisLoopState.Playlist
							: (state === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None);
					}
				}
			}

			PillSlider {
				Layout.fillWidth: true
				icon: Audio.icon
				iconInteractive: true
				dimmed: Audio.muted
				value: Audio.volume
				onMoved: value => Audio.setVolume(value)
				onIconClicked: Audio.toggleMute()
			}

			// output device, folded
			Clickable {
				Layout.fillWidth: true
				implicitHeight: 40
				radius: 20
				color: Theme.layer1
				pressedScale: 0.98
				visible: Audio.sinks.length > 1
				onClicked: root.showOutputs = !root.showOutputs

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 14
					anchors.rightMargin: 12
					spacing: 8

					Glyph {
						icon: "speaker"
						size: 16
						color: Theme.textMuted
					}

					StyledText {
						Layout.fillWidth: true
						text: Audio.shortSinkName(Audio.sinkName)
						font.pixelSize: Theme.size.label
						font.weight: Font.Medium
					}

					Glyph {
						icon: "chevron_down"
						size: 16
						color: Theme.textMuted
						rotation: root.showOutputs ? 180 : 0

						Behavior on rotation {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				visible: root.showOutputs
				spacing: 2

				Repeater {
					model: Audio.sinks

					delegate: ListItem {
						id: sinkRow

						required property var modelData

						Layout.fillWidth: true
						implicitHeight: 44
						icon: /headphone|headset|arctis/i.test(sinkRow.modelData.description) ? "headphones" : "speaker"
						title: Audio.shortSinkName(sinkRow.modelData.description)
						selected: sinkRow.modelData.active
						onClicked: Audio.setDefaultSink(sinkRow.modelData.name)
					}
				}
			}

			LyricsView {
				Layout.fillWidth: true
				visible: Lyrics.active
			}

			// what song detection heard
			Rectangle {
				Layout.fillWidth: true
				visible: Plugins.on("song-detection") && SongDetect.state !== ""
				implicitHeight: (SongDetect.listening ? listening.implicitHeight : heard.implicitHeight) + 24
				radius: Theme.radius.large
				color: Theme.layer1

				RowLayout {
					id: heard

					readonly property bool found: SongDetect.state === "found" && !!SongDetect.song

					anchors.fill: parent
					anchors.margins: 12
					spacing: 12
					visible: !SongDetect.listening

					ClippingRectangle {
						Layout.preferredWidth: 72
						Layout.preferredHeight: 72
						Layout.alignment: Qt.AlignTop
						visible: heard.found
						radius: Theme.radius.medium
						color: Theme.layer2

						Glyph {
							anchors.centerIn: parent
							icon: "music"
							size: 28
							color: Theme.textSubtle
						}

						Image {
							anchors.fill: parent
							source: heard.found ? SongDetect.song.cover : ""
							sourceSize.width: 144
							sourceSize.height: 144
							fillMode: Image.PreserveAspectCrop
							asynchronous: true
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 3

						StyledText {
							Layout.fillWidth: true
							text: heard.found ? SongDetect.song.title : SongDetect.message
							font.pixelSize: heard.found ? Theme.size.title : Theme.size.body
							font.weight: heard.found ? Font.Bold : Font.Medium
							wrapMode: Text.WordWrap
							maximumLineCount: 2
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							visible: heard.found && text !== ""
							text: heard.found ? [SongDetect.song.artist, SongDetect.song.album].filter(part => !!part).join(" · ") : ""
							tone: Theme.textMuted
							font.pixelSize: Theme.size.label
							wrapMode: Text.WordWrap
							maximumLineCount: 2
							elide: Text.ElideRight
						}

						Flow {
							Layout.fillWidth: true
							Layout.topMargin: 6
							visible: heard.found
							spacing: 6

							Repeater {
								model: heard.found ? SongDetect.song.links : []

								delegate: Chip {
									required property var modelData
									text: modelData.name
									icon: modelData.icon
									onClicked: SongDetect.open(modelData.url)
								}
							}
						}
					}

					IconButton {
						Layout.alignment: Qt.AlignTop
						implicitWidth: 28
						implicitHeight: 28
						icon: "close"
						onClicked: SongDetect.dismiss()
					}
				}

				SongListening {
					id: listening

					anchors.fill: parent
					anchors.margins: 12
					visible: SongDetect.listening
					active: root.shown && SongDetect.listening
				}
			}

			Flow {
				Layout.fillWidth: true
				visible: Media.players.length > 1
				spacing: 6

				Repeater {
					model: Media.players

					delegate: Chip {
						required property var modelData
						text: modelData?.identity || "Player"
						icon: modelData?.isPlaying ? "play" : "music_note"
						selected: modelData === Media.player
						onClicked: Media.select(modelData)
					}
				}
			}

			Item {
				implicitHeight: 2
			}
		}
	}
}
