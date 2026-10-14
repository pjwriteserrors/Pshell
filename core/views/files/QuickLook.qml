pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Pdf
import QtMultimedia
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "FileKinds.js" as Kinds

// A file large without opening it (Space): pictures (the wheel zooms, a
// drag moves), videos and music that play, PDFs page by page, text and code
// highlighted, folders with what is in them. ← and → walk the files, Space
// or Escape close it, Enter opens it.
Item {
	id: root

	required property var view
	property var pane: null
	property var rows: []
	property int index: 0
	property bool shown: false
	// the direction of the last step, for the slide
	property int stepDirection: 0
	readonly property var row: root.rows[root.index] ?? null
	readonly property string kind: root.row ? Kinds.kindOf(root.row) : "other"
	signal closed

	// what was looked at before a file of an archive was opened: [{ rows, index }]
	property var outer: []
	// the file of the archive that is being taken out
	property string entering: ""

	// a file inside the archive, taken out into the cache and shown here
	function enter(name) {
		const row = root.row;
		if (!row || root.entering !== "") return;
		root.entering = name;
		Files.request("archivemember", { path: row.path, name: name }, (data, error) => {
			root.entering = "";
			if (!root.shown || root.row?.path !== row.path) return;
			if (error || !data?.entry) {
				Files.fail(error || "This file cannot be read");
				return;
			}
			root.outer = root.outer.concat([{ rows: root.rows, index: root.index }]);
			root.stepDirection = 0;
			root.rows = [data.entry];
			root.index = 0;
			root.load();
		});
	}

	// back to the archive
	function leave() {
		if (root.outer.length === 0) return;
		const before = root.outer[root.outer.length - 1];
		root.outer = root.outer.slice(0, -1);
		root.stepDirection = 0;
		root.rows = before.rows;
		root.index = before.index;
		root.load();
	}

	function open(pane, rows, index) {
		root.outer = [];
		root.entering = "";
		root.pane = pane;
		root.rows = rows;
		root.index = index;
		root.stepDirection = 0;
		root.shown = true;
		root.load();
		Sounds.play("open");
		keys.forceActiveFocus();
	}

	function close() {
		if (!root.shown) return;
		root.shown = false;
		player.stop();
		Sounds.play("close");
		root.closed();
	}

	function takeKeys() {
		keys.forceActiveFocus();
	}

	function go(delta) {
		if (root.rows.length < 2) return;
		root.stepDirection = delta;
		root.index = (root.index + delta + root.rows.length) % root.rows.length;
		// the pane follows, so closing leaves the cursor on what was looked at
		const i = root.pane.rows.findIndex(row => row.path === root.row.path);
		if (i >= 0 && root.pane.selectionCount <= 1) root.pane.pick(i, "only");
		root.load();
		slide.restart();
	}

	property string text: ""
	property bool truncated: false
	property var folderRows: []
	property var info: null
	// what an archive holds: { entries, files, folders, size, packed, error }
	property var archive: null
	readonly property bool isArchive: root.kind === "archive"
	readonly property bool isWeblink: Kinds.isWeblink(root.row)
	readonly property string weblink: String(root.info?.url ?? "")

	// the words of a song: [{ t, text }] (t -1 without timing)
	property var lyrics: []
	property bool lyricsSynced: false
	readonly property int lyricLine: {
		if (!root.lyricsSynced) return -1;
		const seconds = player.position / 1000;
		let at = -1;
		for (let i = 0; i < root.lyrics.length; i += 1) if (root.lyrics[i].t >= 0 && root.lyrics[i].t <= seconds + 0.25) at = i;
		return at;
	}

	function findLyrics(path) {
		Files.request("mediatags", { path: path }, data => {
			if (root.row?.path !== path || !data?.tags?.title) return;
			const tags = data.tags;
			lyricsProc.path = path;
			lyricsProc.command = ["python3", `${Paths.scripts}/lyrics.py`, "--title", String(tags.title), "--artist", String(tags.artist ?? tags.album_artist ?? ""), "--album", String(tags.album ?? ""), "--duration", String(Math.round(Number(data.duration) || 0))];
			lyricsProc.running = true;
		});
	}

	Process {
		id: lyricsProc

		property string path: ""

		stdout: StdioCollector {
			onStreamFinished: {
				if (root.row?.path !== lyricsProc.path) return;
				try {
					const answer = JSON.parse(text);
					root.lyrics = answer.state === "found" ? (answer.lines ?? []) : [];
					root.lyricsSynced = !!answer.synced;
				} catch (error) {
					root.lyrics = [];
				}
			}
		}
	}

	function load() {
		const row = root.row;
		root.lyrics = [];
		root.lyricsSynced = false;
		root.text = "";
		root.folderRows = [];
		root.info = null;
		root.archive = null;
		zoom.reset();
		player.stop();
		if (!row) return;
		if (root.isArchive) {
			Files.request("archive", { path: row.path, limit: 3000 }, (data, error) => {
				if (root.row?.path === row.path) root.archive = data ?? { entries: [], error: error };
			});
		} else if (row.text && !row.dir) {
			Files.request("read", { path: row.path, limit: 200000 }, data => {
				if (root.row?.path !== row.path) return;
				root.text = data?.binary ? "" : String(data?.text ?? "");
				root.truncated = !!data?.truncated;
			});
		} else if (row.dir) {
			Files.request("list", { path: row.path }, data => {
				if (root.row?.path !== row.path) return;
				root.folderRows = (data?.entries ?? []).filter(entry => !entry.hidden).sort((a, b) => (b.dir - a.dir) || (a.key < b.key ? -1 : 1)).slice(0, 60);
			});
		}
		Files.request("info", { path: row.path }, data => {
			if (root.row?.path === row.path) root.info = data;
		});
		if (root.kind === "video" || root.kind === "audio") {
			player.source = Files.uri(row.path);
			player.play();
		}
		if (root.kind === "audio" && Plugins.on("lyrics")) root.findLyrics(row.path);
	}

	visible: scrim.opacity > 0.01

	Item {
		id: keys

		focus: root.shown
		Keys.onPressed: event => {
			switch (event.key) {
			case Qt.Key_Escape:
				if (root.outer.length > 0) root.leave();
				else root.close();
				break;
			case Qt.Key_Backspace:
				root.leave();
				break;
			case Qt.Key_Space:
				root.close();
				break;
			case Qt.Key_Left:
			case Qt.Key_Up:
				root.go(-1);
				break;
			case Qt.Key_Right:
			case Qt.Key_Down:
				root.go(1);
				break;
			case Qt.Key_Return:
			case Qt.Key_Enter:
				root.close();
				root.view.openRow(root.pane, root.row, false);
				break;
			case Qt.Key_K:
			case Qt.Key_P:
				if (player.playbackState === MediaPlayer.PlayingState) player.pause();
				else player.play();
				break;
			case Qt.Key_Plus:
			case Qt.Key_Equal:
				zoom.by(1.25);
				break;
			case Qt.Key_Minus:
				zoom.by(0.8);
				break;
			case Qt.Key_0:
				zoom.reset();
				break;
			default:
				return;
			}
			event.accepted = true;
		}
	}

	Rectangle {
		id: scrim

		anchors.fill: parent
		color: Qt.rgba(0, 0, 0, Theme.dark ? 0.62 : 0.45)
		opacity: root.shown ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			// the files behind do not light up under it
			hoverEnabled: true
			onClicked: root.close()
			onWheel: wheel => wheel.accepted = true
		}
	}

	Rectangle {
		id: card

		anchors.centerIn: parent
		width: Math.min(parent.width - 80, 1180)
		height: Math.min(parent.height - 60, 860)
		radius: Theme.radius.huge
		color: Theme.base
		border.width: 1
		border.color: Theme.outline
		clip: true
		scale: root.shown ? 1 : 0.9
		opacity: root.shown ? 1 : 0

		Behavior on scale {
			SpatialAnim {
				duration: root.shown ? Motion.long : Motion.short
			}
		}
		Behavior on opacity {
			Anim {
				duration: root.shown ? Motion.medium : Motion.short
			}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		// ── the head ───────────────────────────────────────────────────────
		Item {
			id: head

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			height: 56

			IconButton {
				id: back

				visible: root.outer.length > 0
				x: 12
				anchors.verticalCenter: parent.verticalCenter
				width: 32
				height: 32
				iconSize: 18
				icon: "arrow_left"
				onClicked: root.leave()
			}

			FileThumb {
				id: icon

				x: back.visible ? 54 : 18
				anchors.verticalCenter: parent.verticalCenter
				width: 30
				height: 30
				compact: true
				radius: 8
				path: root.row?.path ?? ""
				name: root.row?.name ?? ""
				mime: root.row?.mime ?? ""
				dir: !!root.row?.dir
				kind: root.kind
				thumb: root.row?.thumb ?? ""
				canThumb: !!root.row?.canThumb
			}

			Column {
				anchors.left: icon.right
				anchors.leftMargin: 12
				anchors.right: actions.left
				anchors.rightMargin: 12
				anchors.verticalCenter: parent.verticalCenter

				Text {
					width: parent.width
					text: root.row?.name ?? ""
					color: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
					elide: Text.ElideMiddle
				}

				Text {
					width: parent.width
					text: {
						const parts = [];
						if (root.rows.length > 1) parts.push(`${root.index + 1} of ${root.rows.length}`);
						if (root.info?.kind) parts.push(root.info.kind);
						if (root.row && !root.row.dir) parts.push(Files.sizeText(root.row.size));
						for (const fact of (root.info?.facts ?? []).slice(0, 2)) parts.push(fact[1]);
						return parts.join("  ·  ");
					}
					color: Theme.textSubtle
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			Row {
				id: actions

				anchors.right: parent.right
				anchors.rightMargin: 12
				anchors.verticalCenter: parent.verticalCenter
				spacing: 4

				TextButton {
					height: 32
					variant: "filled"
					text: root.row?.dir ? "Open" : "Open"
					icon: "open_in_app"
					onClicked: {
						const row = root.row;
						root.close();
						root.view.openRow(root.pane, row, false);
					}
				}
				TextButton {
					id: kindButton

					// not for a file taken out of an archive: changes would land in the cache
					readonly property var menu: root.shown && root.row && root.outer.length === 0 ? root.view.kindMenu(root.pane, [root.row]) : null

					visible: !!kindButton.menu
					height: 32
					text: kindButton.menu?.short ?? ""
					icon: kindButton.menu?.icon ?? ""
					onClicked: {
						const at = mapToItem(root.view, 0, height + 4);
						root.view.showKindMenu(root.pane, [root.row], at.x, at.y);
					}
				}
				IconButton {
					visible: root.pane?.virtual ?? false
					width: 32
					height: 32
					iconSize: 16
					icon: "folder_search_outline"
					onClicked: {
						const path = root.row.path;
						root.close();
						root.view.revealIn(root.pane, [path]);
					}
				}
				IconButton {
					width: 32
					height: 32
					iconSize: 16
					icon: "close"
					onClicked: root.close()
				}
			}
		}

		// ── the file ───────────────────────────────────────────────────────
		Item {
			id: stage

			anchors.top: head.bottom
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 14
			anchors.topMargin: 0
			clip: true

			ParallelAnimation {
				id: slide

				NumberAnimation {
					target: stage
					property: "opacity"
					from: 0.2
					to: 1
					duration: Motion.medium
				}
				NumberAnimation {
					target: stageShift
					property: "x"
					from: root.stepDirection * 40
					to: 0
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.decel
				}
			}

			transform: Translate {
				id: stageShift
			}

			Rectangle {
				anchors.fill: parent
				radius: Theme.radius.large
				color: Theme.layer1
			}

			// a picture: fit, then the wheel zooms where the pointer is
			Flickable {
				id: zoom

				property real factor: 1
				readonly property real fit: photo.implicitWidth > 0 ? Math.min(1, Math.min(zoom.width / photo.implicitWidth, zoom.height / photo.implicitHeight)) : 1

				function reset() {
					zoom.factor = 1;
					zoom.contentX = 0;
					zoom.contentY = 0;
				}

				function by(step, x, y) {
					const before = zoom.factor;
					const next = Math.max(1, Math.min(12, before * step));
					const px = x ?? zoom.width / 2;
					const py = y ?? zoom.height / 2;
					const fx = (zoom.contentX + px) / Math.max(1, zoom.contentWidth);
					const fy = (zoom.contentY + py) / Math.max(1, zoom.contentHeight);
					zoom.factor = next;
					zoom.contentX = Math.max(0, fx * zoom.contentWidth - px);
					zoom.contentY = Math.max(0, fy * zoom.contentHeight - py);
				}

				anchors.fill: parent
				visible: root.kind === "image"
				contentWidth: Math.max(zoom.width, photo.implicitWidth * zoom.fit * zoom.factor)
				contentHeight: Math.max(zoom.height, photo.implicitHeight * zoom.fit * zoom.factor)
				interactive: zoom.factor > 1
				clip: true
				boundsBehavior: Flickable.StopAtBounds

				Image {
					id: photo

					anchors.centerIn: parent
					width: implicitWidth * zoom.fit * zoom.factor
					height: implicitHeight * zoom.fit * zoom.factor
					source: root.shown && root.kind === "image" && root.row ? Files.uri(root.row.path) : ""
					asynchronous: true
					autoTransform: true
					smooth: true
					mipmap: true
					sourceSize.width: Math.max(zoom.width, 1) * 3
					opacity: status === Image.Ready ? 1 : 0

					Behavior on opacity {
						Anim {}
					}
				}

				MouseArea {
					anchors.fill: parent
					acceptedButtons: Qt.NoButton
					onWheel: wheel => zoom.by(wheel.angleDelta.y > 0 ? 1.2 : 1 / 1.2, wheel.x - zoom.contentX, wheel.y - zoom.contentY)
				}
			}

			Spinner {
				anchors.centerIn: parent
				visible: root.kind === "image" && photo.status === Image.Loading
				width: 30
				height: 30
			}

			// a video, music: they play
			MediaPlayer {
				id: player

				audioOutput: AudioOutput {}
				videoOutput: video
			}

			VideoOutput {
				id: video

				anchors.fill: parent
				anchors.bottomMargin: 56
				visible: root.kind === "video"
			}

			// music: the cover (to the left when the words are there)
			FileThumb {
				visible: root.kind === "audio"
				anchors.centerIn: parent
				anchors.horizontalCenterOffset: root.lyrics.length > 0 ? -parent.width * 0.22 : 0
				anchors.verticalCenterOffset: -30

				Behavior on anchors.horizontalCenterOffset {
					SpatialAnim {
						duration: Motion.long
					}
				}
				width: Math.min(parent.width, parent.height) * 0.5
				height: width
				radius: Theme.radius.huge
				size: "x-large"
				path: root.row?.path ?? ""
				name: root.row?.name ?? ""
				mime: root.row?.mime ?? ""
				kind: "audio"
				thumb: root.row?.thumb ?? ""
				canThumb: !!root.row?.canThumb
			}

			// the words of the song, the line that is sung lit
			ListView {
				id: lyricList

				visible: root.kind === "audio" && root.lyrics.length > 0
				x: parent.width * 0.5
				y: 20
				width: parent.width * 0.46
				height: parent.height - 96
				clip: true
				model: root.lyrics
				spacing: 6
				boundsBehavior: Flickable.StopAtBounds
				highlightRangeMode: root.lyricsSynced ? ListView.ApplyRange : ListView.NoHighlightRange
				preferredHighlightBegin: height * 0.35
				preferredHighlightEnd: height * 0.45
				highlightMoveDuration: 400
				currentIndex: Math.max(0, root.lyricLine)
				opacity: visible ? 1 : 0

				Behavior on opacity {
					Anim {}
				}

				delegate: Text {
					required property var modelData
					required property int index
					readonly property bool sung: index === root.lyricLine

					width: lyricList.width
					text: String(modelData.text || "·")
					color: !root.lyricsSynced || sung ? Theme.text : Theme.textSubtle
					font.family: Theme.fontFamily
					font.pixelSize: sung ? Theme.size.title : Theme.size.body
					font.weight: sung ? Font.Bold : Font.Medium
					wrapMode: Text.WordWrap

					Behavior on font.pixelSize {
						Anim {}
					}

					MouseArea {
						anchors.fill: parent
						enabled: root.lyricsSynced && parent.modelData.t >= 0
						cursorShape: Qt.PointingHandCursor
						onClicked: player.position = parent.modelData.t * 1000
					}
				}
			}

			Item {
				id: controls

				visible: root.kind === "video" || root.kind === "audio"
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				height: 56

				IconButton {
					id: playButton

					x: 12
					anchors.verticalCenter: parent.verticalCenter
					width: 38
					height: 38
					variant: "filled"
					icon: player.playbackState === MediaPlayer.PlayingState ? "pause" : "play"
					onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
				}

				Text {
					id: elapsed

					anchors.left: playButton.right
					anchors.leftMargin: 12
					anchors.verticalCenter: parent.verticalCenter
					text: `${Qt.formatTime(new Date(player.position), player.duration >= 3600000 ? "h:mm:ss" : "m:ss")} / ${Qt.formatTime(new Date(player.duration), player.duration >= 3600000 ? "h:mm:ss" : "m:ss")}`
					color: Theme.textMuted
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					font.features: { "tnum": 1 }
				}

				Rectangle {
					id: track

					anchors.left: elapsed.right
					anchors.leftMargin: 14
					anchors.right: parent.right
					anchors.rightMargin: 16
					anchors.verticalCenter: parent.verticalCenter
					height: seek.containsMouse || seek.pressed ? 8 : 5
					radius: height / 2
					color: Theme.layer3

					Behavior on height {
						Anim {
							duration: Motion.short
						}
					}

					Rectangle {
						width: player.duration > 0 ? parent.width * player.position / player.duration : 0
						height: parent.height
						radius: parent.radius
						color: Theme.primary
					}

					MouseArea {
						id: seek

						anchors.fill: parent
						anchors.margins: -8
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onPressed: mouse => player.position = Math.max(0, Math.min(1, (mouse.x - 8) / track.width)) * player.duration
						onPositionChanged: mouse => {
							if (pressed) player.position = Math.max(0, Math.min(1, (mouse.x - 8) / track.width)) * player.duration;
						}
					}
				}
			}

			// a PDF: its pages, one under the other (built only for one)
			Loader {
				id: pages

				anchors.fill: parent
				anchors.margins: 6
				active: root.shown && root.row?.mime === "application/pdf"
				visible: pages.active

				sourceComponent: Item {
					PdfDocument {
						id: pdf

						source: Files.uri(root.row.path)
					}

					ListView {
						id: pageList

						anchors.fill: parent
						model: pdf.status === PdfDocument.Ready ? pdf.pageCount : 0
						spacing: 14
						clip: true
						cacheBuffer: 1200
						boundsBehavior: Flickable.StopAtBounds

						ScrollBar.vertical: ThinScrollBar {}

						delegate: Item {
							id: pageItem

							required property int index
							readonly property size pageSize: pdf.pagePointSize(pageItem.index)

							width: pageList.width
							height: pageList.width * 0.8 * (pageItem.pageSize.height / Math.max(1, pageItem.pageSize.width))

							Rectangle {
								anchors.horizontalCenter: parent.horizontalCenter
								width: parent.width * 0.8
								height: parent.height
								color: "white"
								radius: 3

								PdfPageImage {
									anchors.fill: parent
									document: pdf
									currentFrame: pageItem.index
									asynchronous: true
									sourceSize.width: width * 1.5
								}
							}
						}
					}
				}
			}

			// a link file: where it leads
			Column {
				id: linkView

				anchors.centerIn: parent
				width: Math.min(parent.width - 80, 560)
				visible: root.isWeblink && root.weblink !== ""
				spacing: 14

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 84
					height: 84
					radius: 28
					color: Theme.primarySoft
					scale: linkView.visible ? 1 : 0.7

					Behavior on scale {
						SpatialAnim {
							duration: Motion.long
						}
					}

					Glyph {
						anchors.centerIn: parent
						icon: "web"
						size: 40
						color: Theme.primary
					}
				}

				StyledText {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					text: root.weblink.replace(/^https?:\/\//, "").split(/[/?#]/)[0]
					font.pixelSize: Theme.size.title + 4
					font.weight: Font.DemiBold
					elide: Text.ElideMiddle
				}

				StyledText {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					text: root.weblink
					tone: Theme.textMuted
					font.family: Theme.monoFamily
					font.pixelSize: Theme.size.small
					wrapMode: Text.WrapAnywhere
					maximumLineCount: 4
					elide: Text.ElideRight
				}

				Row {
					anchors.horizontalCenter: parent.horizontalCenter
					spacing: 8

					TextButton {
						variant: "filled"
						text: "Open in the browser"
						icon: "open_in_new"
						onClicked: {
							Qt.openUrlExternally(root.weblink);
							root.close();
						}
					}

					TextButton {
						variant: "tonal"
						text: "Copy"
						icon: "content_copy"
						onClicked: Files.copyText(root.weblink, "Link copied")
					}
				}
			}

			// an archive: what is in it, as a tree
			Item {
				id: archiveView

				anchors.fill: parent
				anchors.margins: 14
				visible: root.isArchive

				Spinner {
					anchors.centerIn: parent
					visible: !root.archive
					width: 28
					height: 28
				}

				Column {
					anchors.centerIn: parent
					visible: !!root.archive && (root.archive.entries ?? []).length === 0
					spacing: 10

					Glyph {
						anchors.horizontalCenter: parent.horizontalCenter
						icon: root.archive?.encrypted ? "lock_outline" : "package_variant_closed"
						size: 44
						color: Theme.textMuted
					}

					StyledText {
						text: root.archive?.error || "Nothing is in it"
						tone: Theme.textMuted
					}
				}

				RowLayout {
					id: archiveHead

					visible: (root.archive?.entries ?? []).length > 0
					width: parent.width
					spacing: 10

					Repeater {
						model: [
							{ icon: "file_outline", text: `${root.archive?.files ?? 0} file${root.archive?.files === 1 ? "" : "s"}` },
							{ icon: "folder_outline", text: `${root.archive?.folders ?? 0} folder${root.archive?.folders === 1 ? "" : "s"}` },
							{ icon: "arrow_expand_all", text: `${Files.sizeText(root.archive?.size ?? 0)} unpacked` },
							{ icon: "package_variant_closed", text: root.archive?.size > 0 ? `packed to ${Math.min(100, Math.round((root.archive?.packed ?? 0) * 100 / root.archive.size))} %` : "" }
						].filter(item => item.text !== "")

						delegate: Rectangle {
							required property var modelData

							height: 28
							width: chipRow.implicitWidth + 20
							radius: 14
							color: Theme.layer2

							Row {
								id: chipRow

								anchors.centerIn: parent
								spacing: 6

								Glyph {
									anchors.verticalCenter: parent.verticalCenter
									icon: parent.parent.modelData.icon
									size: 14
									color: Theme.textMuted
								}

								StyledText {
									anchors.verticalCenter: parent.verticalCenter
									text: parent.parent.modelData.text
									font.pixelSize: Theme.size.small
								}
							}
						}
					}

					Item {
						Layout.fillWidth: true
					}

					TextButton {
						height: 32
						variant: "tonal"
						text: "Extract here"
						icon: "package_variant"
						onClicked: {
							const row = root.row;
							root.close();
							Files.extract(row.path, root.pane.isFolder ? root.pane.location.path : Files.parentOf(row.path));
						}
					}
				}

				ListView {
					id: archiveList

					anchors.top: archiveHead.bottom
					anchors.topMargin: 12
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					visible: (root.archive?.entries ?? []).length > 0
					model: root.archive?.entries ?? []
					clip: true
					boundsBehavior: Flickable.StopAtBounds
					cacheBuffer: 600

					ScrollBar.vertical: ThinScrollBar {}

					delegate: Item {
						id: archived

						required property var modelData
						required property int index
						readonly property int depth: archived.modelData.name.split("/").length - 1
						readonly property string leaf: archived.modelData.name.split("/").pop()

						width: archiveList.width
						height: 30

						Rectangle {
							anchors.fill: parent
							radius: 6
							color: archivedArea.containsMouse ? Theme.primarySoft : Qt.alpha(Theme.layer2, archived.index % 2 === 1 ? 0.5 : 0)
						}

						// the lines that show what is inside what
						Repeater {
							model: archived.depth

							delegate: Rectangle {
								required property int index

								x: 18 + index * 18
								width: 1
								height: archived.height
								color: Theme.outline
							}
						}

						Glyph {
							id: archivedIcon

							x: 10 + archived.depth * 18
							anchors.verticalCenter: parent.verticalCenter
							icon: archived.modelData.dir ? "folder" : Kinds.glyphOf({ dir: false, name: archived.leaf, mime: "" })
							size: 16
							color: archived.modelData.dir ? Theme.primary : Theme.textMuted
							animated: false
						}

						StyledText {
							anchors.left: archivedIcon.right
							anchors.leftMargin: 8
							anchors.right: archivedSize.left
							anchors.rightMargin: 10
							anchors.verticalCenter: parent.verticalCenter
							text: archived.leaf
							font.weight: archived.modelData.dir ? Font.DemiBold : Font.Normal
							elide: Text.ElideMiddle
						}

						StyledText {
							id: archivedSize

							anchors.right: parent.right
							anchors.rightMargin: 14
							anchors.verticalCenter: parent.verticalCenter
							text: archived.modelData.dir ? "" : Files.sizeText(archived.modelData.size)
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
							font.features: { "tnum": 1 }
							visible: root.entering !== archived.modelData.name
						}

						Spinner {
							anchors.right: parent.right
							anchors.rightMargin: 14
							anchors.verticalCenter: parent.verticalCenter
							visible: root.entering === archived.modelData.name
							width: 16
							height: 16
						}

						// a file opens here, in the quick look
						MouseArea {
							id: archivedArea

							anchors.fill: parent
							enabled: !archived.modelData.dir
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: root.enter(archived.modelData.name)
						}
					}
				}
			}

			// text and code
			Flickable {
				id: textView

				anchors.fill: parent
				anchors.margins: 18
				visible: !!root.row?.text && !root.row?.dir && root.row?.mime !== "application/pdf" && root.text !== "" && !linkView.visible && !root.isArchive
				contentWidth: Math.max(width, textBody.implicitWidth)
				contentHeight: textBody.implicitHeight + 30
				clip: true
				boundsBehavior: Flickable.StopAtBounds

				ScrollBar.vertical: ThinScrollBar {}

				TextEdit {
					id: textBody

					readonly property string lang: Peek.langOfPath(root.row?.name ?? "")
					readonly property bool code: textBody.lang !== "" && textBody.lang !== "markdown"

					width: Math.max(textView.width, implicitWidth)
					readOnly: true
					selectByMouse: true
					textFormat: textBody.code ? TextEdit.RichText : (textBody.lang === "markdown" ? TextEdit.MarkdownText : TextEdit.PlainText)
					text: textBody.code ? Peek.highlight(root.text, textBody.lang, 120000) : root.text
					color: Theme.text
					selectionColor: Qt.alpha(Theme.primary, 0.4)
					font.family: textBody.lang === "markdown" ? Theme.fontFamily : Theme.monoFamily
					font.pixelSize: textBody.lang === "markdown" ? Theme.size.body + 1 : Theme.size.label
					wrapMode: textBody.code ? TextEdit.NoWrap : TextEdit.Wrap
				}
			}

			// a folder: what is in it
			GridView {
				id: folderView

				anchors.fill: parent
				anchors.margins: 14
				visible: !!root.row?.dir
				model: root.folderRows
				cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 130)))
				cellHeight: 130
				clip: true
				interactive: true
				boundsBehavior: Flickable.StopAtBounds

				delegate: Item {
					id: child

					required property var modelData

					width: folderView.cellWidth
					height: folderView.cellHeight

					FileThumb {
						anchors.horizontalCenter: parent.horizontalCenter
						y: 6
						width: parent.width - 30
						height: 80
						path: child.modelData.path
						name: child.modelData.name
						mime: child.modelData.mime
						dir: child.modelData.dir
						kind: Kinds.kindOf(child.modelData)
						thumb: child.modelData.thumb
						canThumb: child.modelData.canThumb
						isText: child.modelData.text
					}

					Text {
						anchors.bottom: parent.bottom
						anchors.bottomMargin: 10
						x: 8
						width: parent.width - 16
						horizontalAlignment: Text.AlignHCenter
						text: child.modelData.name
						color: Theme.textMuted
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.small
						elide: Text.ElideMiddle
					}
				}
			}

			// anything else: big, with what is known
			Column {
				anchors.centerIn: parent
				visible: !zoom.visible && !video.visible && !controls.visible && !pages.visible && !textView.visible && !folderView.visible && !linkView.visible && !archiveView.visible
				spacing: 16

				FileThumb {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 220
					height: 180
					size: "x-large"
					path: root.row?.path ?? ""
					name: root.row?.name ?? ""
					mime: root.row?.mime ?? ""
					kind: root.kind
					thumb: root.row?.thumb ?? ""
					canThumb: !!root.row?.canThumb
				}

				Repeater {
					model: root.info?.facts ?? []

					delegate: Text {
						required property var modelData

						anchors.horizontalCenter: parent.horizontalCenter
						text: `${modelData[0]}: ${modelData[1]}`
						color: Theme.textMuted
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.label
					}
				}
			}
		}

		// ← and → at the sides
		IconButton {
			visible: root.rows.length > 1
			anchors.left: parent.left
			anchors.leftMargin: 22
			anchors.verticalCenter: parent.verticalCenter
			width: 40
			height: 40
			variant: "tonal"
			icon: "chevron_left"
			opacity: sides.containsMouse ? 0.95 : 0
			onClicked: root.go(-1)

			Behavior on opacity {
				Anim {}
			}
		}

		IconButton {
			visible: root.rows.length > 1
			anchors.right: parent.right
			anchors.rightMargin: 22
			anchors.verticalCenter: parent.verticalCenter
			width: 40
			height: 40
			variant: "tonal"
			icon: "chevron_right"
			opacity: sides.containsMouse ? 0.95 : 0
			onClicked: root.go(1)

			Behavior on opacity {
				Anim {}
			}
		}

		MouseArea {
			id: sides

			anchors.fill: parent
			anchors.topMargin: head.height
			hoverEnabled: true
			acceptedButtons: Qt.NoButton
			z: -1
		}
	}
}
