pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// One video of the subscriptions: play it, and which series it is in. The ones
// followed open, the suggestions and the channel's own playlists it is in can be
// followed from here.
Rectangle {
	id: root

	property var video: null
	property var found: null
	property var followed: []
	readonly property var channel: Streams.sourceById[root.video?.source] ?? null
	readonly property var held: root.found?.followed ?? []
	readonly property var suggested: root.found?.suggested ?? []
	readonly property var playlists: root.found?.playlists ?? []

	signal close
	signal openSeries(string id)

	color: Streams.pageColor

	function show(video) {
		root.video = video;
		root.found = null;
		root.followed = [];
		root.load();
	}

	function load() {
		const asked = root.video?.id;
		if (!asked) return;
		Streams.call("videoSeries", { video: asked }, data => {
			if (asked !== root.video?.id) return;
			root.found = data ?? { followed: [], suggested: [], playlists: [] };
			// opened by its id alone
			if (data?.video && !root.video.title) root.video = data.video;
		});
	}

	// key: what the button shows as followed; ask: the call, given what to do after
	function follow(key, ask) {
		ask(data => {
			if (data) root.followed = root.followed.concat([key]);
		});
	}

	// the picture, large behind everything
	Thumb {
		anchors.left: parent.left
		anchors.right: parent.right
		height: parent.height * 0.62
		radius: 0
		source: root.video?.thumb ?? ""
		large: Streams.large(root.video?.id ?? "")
		colors: root.channel?.colors ?? null

		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: 0
					color: Qt.rgba(0, 0, 0, 0.85)
				}
				GradientStop {
					position: 0.85
					color: Qt.rgba(0, 0, 0, 0.1)
				}
			}
		}
		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				GradientStop {
					position: 0.15
					color: Qt.alpha(Theme.base, 0)
				}
				GradientStop {
					position: 0.92
					color: Theme.base
				}
			}
		}
	}

	component SeriesRow: Rectangle {
		id: row

		property string name: ""
		property string detail: ""
		property string glyph: "playlist_check"
		property bool opens: false
		default property alias actions: actionRow.data

		signal opened

		Layout.fillWidth: true
		implicitHeight: 76
		radius: Theme.radius.large
		color: rowArea.containsMouse ? Theme.layer2 : Theme.layer1

		Behavior on color {
			ColorAnim {}
		}

		MouseArea {
			id: rowArea

			anchors.fill: parent
			enabled: row.opens
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: row.opened()
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 20
			anchors.rightMargin: 16
			spacing: 16

			Glyph {
				icon: row.glyph
				size: 26
				color: Theme.text
			}
			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					Layout.fillWidth: true
					text: row.name
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
					elide: Text.ElideRight
				}
				StyledText {
					Layout.fillWidth: true
					visible: row.detail !== ""
					text: row.detail
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
					elide: Text.ElideRight
				}
			}
			Row {
				id: actionRow

				spacing: 8
			}
			Glyph {
				visible: row.opens
				icon: "chevron_right"
				size: 24
				color: Theme.textMuted
			}
		}
	}

	component FollowButton: BigButton {
		property bool done: false

		implicitHeight: 38
		main: !done
		enabled: !done
		text: done ? "Following" : "Follow"
		icon: done ? "check" : "plus"
	}

	Flickable {
		anchors.fill: parent
		contentHeight: column.implicitHeight + 40
		boundsBehavior: Flickable.StopAtBounds
		clip: true
		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: column

			x: 44
			width: root.width - 88
			spacing: 14

			Rectangle {
				Layout.topMargin: 16
				Layout.leftMargin: -24
				width: 44
				height: 44
				radius: 22
				color: Qt.rgba(0, 0, 0, backArea.containsMouse ? 0.75 : 0.45)

				Glyph {
					anchors.centerIn: parent
					icon: "arrow_left"
					size: 24
					color: "white"
					surface: "black"
				}
				MouseArea {
					id: backArea

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: root.close()
				}
			}

			Item {
				Layout.preferredHeight: Math.max(30, root.height * 0.2)
			}

			Text {
				Layout.fillWidth: true
				text: [root.channel?.name, Streams.ago(root.video?.published), (root.video?.duration ?? 0) > 0 ? Streams.clock(root.video.duration) : ""].filter(word => !!word).join(" · ")
				color: Qt.rgba(1, 1, 1, 0.82)
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.heading
				font.weight: Font.Medium
				elide: Text.ElideRight
			}
			Text {
				Layout.fillWidth: true
				Layout.maximumWidth: 1100
				text: root.video?.title ?? ""
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: 48
				font.weight: Font.Black
				wrapMode: Text.Wrap
				maximumLineCount: 2
				elide: Text.ElideRight
			}
			RowLayout {
				spacing: 12

				BigButton {
					text: (root.video?.position ?? 0) > 0 && !root.video?.watched ? `Resume at ${Streams.clock(root.video.position)}` : "Play"
					icon: "play"
					onClicked: {
						Streams.play(root.video.id);
						root.close();
					}
				}
				BigButton {
					main: false
					text: root.video?.watched ? "Watched" : "Mark watched"
					icon: root.video?.watched ? "check_bold" : "check"
					onClicked: {
						Streams.mark(root.video.id, !root.video.watched);
						root.video = Object.assign({}, root.video, { watched: !root.video.watched });
					}
				}
			}

			// ── what it is in ───────────────────────────────────────────
			SectionHeading {
				Layout.topMargin: 26
				visible: root.held.length > 0
				text: "In your series"
			}
			Repeater {
				model: root.held

				SeriesRow {
					required property var modelData

					name: modelData.name
					detail: modelData.state === "maybe" ? "Maybe: waiting for you to say" : ""
					glyph: "playlist_check"
					opens: true
					onOpened: root.openSeries(modelData.id)
				}
			}

			SectionHeading {
				Layout.topMargin: 26
				visible: root.suggested.length > 0 || root.playlists.length > 0
				text: root.held.length > 0 ? "Also in" : "Series it could be in"
			}
			Repeater {
				model: root.suggested

				SeriesRow {
					id: suggestion

					required property var modelData
					readonly property bool done: root.followed.includes(`s:${modelData.key}`)

					name: modelData.name
					// a suggestion of another channel: a collaboration, say so
					detail: [(modelData.sources ?? []).includes(root.video?.source) ? "" : `on ${modelData.sourceName}`, `${modelData.count} episodes`, modelData.seconds ? Streams.span(modelData.seconds) : "", modelData.why].filter(word => !!word).join(" · ")
					glyph: "playlist_plus"

					BigButton {
						visible: !!suggestion.modelData.part && !suggestion.done
						implicitHeight: 38
						main: false
						readonly property bool done: root.followed.includes(`p:${suggestion.modelData.key}`)
						enabled: !done
						text: done ? "Following" : `Only “${suggestion.modelData.part?.name ?? ""}”`
						icon: done ? "check" : "plus"
						onClicked: root.follow(`p:${suggestion.modelData.key}`, after => Streams.followPart(suggestion.modelData.part, after))
					}
					FollowButton {
						done: suggestion.done
						onClicked: root.follow(`s:${suggestion.modelData.key}`, after => Streams.followDiscovery(suggestion.modelData.key, after))
					}
				}
			}
			Repeater {
				model: root.playlists

				SeriesRow {
					id: playlist

					required property var modelData

					name: modelData.name
					detail: `${modelData.channel === root.video?.source ? "The channel's" : `${modelData.channelName}'s`} playlist · ${modelData.count} videos`
					glyph: "format_list_bulleted"

					FollowButton {
						done: root.followed.includes(`l:${playlist.modelData.id}`)
						onClicked: root.follow(`l:${playlist.modelData.id}`, after => Streams.call("followPlaylist", { id: playlist.modelData.id }, Streams.report(after)))
					}
				}
			}

			// asked, and nothing
			StyledText {
				Layout.topMargin: 26
				visible: !root.found
				text: "Looking for its series…"
				font.pixelSize: Theme.size.title
				tone: Theme.textMuted
			}
			ColumnLayout {
				Layout.topMargin: 26
				visible: !!root.found && root.held.length === 0 && root.suggested.length === 0 && root.playlists.length === 0
				spacing: 6

				Text {
					text: "In no series yet"
					color: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: 30
					font.weight: Font.Black
				}
				StyledText {
					text: "Explore reads the channels in the background; what it finds shows up here."
					font.pixelSize: Theme.size.title
					tone: Theme.textMuted
				}
			}
		}
	}
}
