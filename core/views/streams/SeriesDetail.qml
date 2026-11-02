pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views
import qs.core.views.games

// A series opened: its colours as a light behind it, how far it is, what to
// do next, every episode. It grows out of the card that was clicked and goes
// back into it (StreamsView sets `origin`).
Item {
	id: root

	required property string seriesId
	readonly property var item: Streams.seriesById[root.seriesId] ?? null
	readonly property color accent: Streams.accent(root.item?.colors)
	property var episodes: []
	property var episodeById: ({})
	property var shownOrder: []
	// the series inside this one, once asked
	property var parts: null
	property bool showBook: false
	readonly property real rowHeight: 116
	readonly property var ranges: {
		const out = [];
		const size = root.episodes.length > 120 ? 50 : 25;
		if (root.episodes.length <= 40) return out;
		for (let start = 0; start < root.episodes.length; start += size) out.push({ from: start + 1, to: Math.min(root.episodes.length, start + size) });
		return out;
	}
	property var maybes: []
	property bool showSettings: false
	property string askUpTo: ""     // a check on a later episode asks about those before it
	property var recap: null        // { episode, text, error, busy }
	property bool finished: false

	signal closeRequested
	signal editRule(var item)

	function refresh() {
		Streams.call("series", { id: root.seriesId }, data => {
			if (!data) return;
			const byId = {};
			for (const episode of data.episodes) byId[episode.id] = episode;
			root.episodeById = byId;
			root.episodes = data.episodes;
			root.maybes = data.maybe;
			// what comes next on top, in watching order; what was watched below, the last one first
			const open = data.episodes.filter(episode => !episode.watched);
			const seen = data.episodes.filter(episode => episode.watched).reverse();
			root.shownOrder = open.concat(seen);
			if (root.parts === null) Streams.call("seriesParts", { id: root.seriesId }, parts => root.parts = parts ?? []);
			rows.sync(root.shownOrder.map(episode => ({ key: episode.id })));
		});
	}

	// to an episode by its number, wherever the list has it now
	function scrollToEpisode(n) {
		root.scrollTo(Math.max(0, root.shownOrder.findIndex(episode => episode.n === n)));
	}

	function scrollTo(index) {
		glide.to = Math.max(0, Math.min(list.contentHeight - list.height, list.headerItem.height + index * root.rowHeight - 90));
		glide.restart();
	}

	function clicked(episode) {
		if (episode.watched) return Streams.mark(episode.id, false);
		Streams.mark(episode.id, true);
		const before = root.episodes.filter(other => other.n < episode.n && !other.watched).length;
		root.askUpTo = before > 0 ? episode.id : "";
	}

	function wantRecap(episode) {
		root.recap = { episode: episode, text: "", error: "", busy: true };
		Streams.call("recap", { video: episode.id, model: AiActions.model || AiChat.selectedAiModel }, (data, error) => {
			if (root.recap?.episode.id !== episode.id) return;
			root.recap = { episode: episode, text: data?.text ?? "", error: error, busy: false, video: data?.video ?? null };
		});
	}

	onSeriesIdChanged: refresh()
	Connections {
		target: Streams

		function onBookTabWantedChanged() {
			if (Streams.bookTabWanted) root.showBook = true;
		}
	}
	onItemChanged: if (root.item?.next) Streams.prefetch([root.item.next.id])
	Component.onCompleted: refresh()

	Connections {
		target: Streams

		function onSeriesChanged() {
			debounce.restart();
		}
		function onSeriesCompleted(id) {
			if (id === root.seriesId) celebrate.restart();
		}
	}

	Timer {
		id: debounce

		interval: 120
		onTriggered: root.refresh()
	}

	SyncedModel {
		id: rows
	}

	NumberAnimation {
		id: glide

		target: list
		property: "contentY"
		duration: 700
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.emphasized
	}

	Rectangle {
		anchors.fill: parent
		color: Streams.pageColor
	}

	// the picture, large, staying behind as the list scrolls
	Item {
		id: backdrop

		anchors.left: parent.left
		anchors.right: parent.right
		height: root.heroHeight
		y: -Math.max(0, list.contentY + list.originY0) * 0.5
		opacity: 1 - Math.min(1, Math.max(0, list.contentY + list.originY0) / root.heroHeight)

		Thumb {
			anchors.fill: parent
			radius: 0
			source: root.item?.picture ?? ""
			large: root.item?.spoiler ? "" : Streams.large(root.item?.pictureId ?? "")
			colors: root.item?.colors ?? null
			spoiler: root.item?.spoiler ?? false
		}
		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: 0
					color: Qt.rgba(0, 0, 0, 0.8)
				}
				GradientStop {
					position: 0.75
					color: Qt.rgba(0, 0, 0, 0)
				}
			}
		}
		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				GradientStop {
					position: 0.3
					color: Qt.alpha(Theme.base, 0)
				}
				GradientStop {
					position: 0.92
					color: Theme.base
				}
			}
		}
	}

	readonly property real heroHeight: Math.max(400, Math.min(root.height * 0.62, 620))

	ListView {
		id: list

		// how far it scrolled, whatever the header's size
		readonly property real originY0: -originY

		anchors.fill: parent
		model: rows
		spacing: 0
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}
		bottomMargin: 18

		cacheBuffer: 1200
		add: Transition {
			ParallelAnimation {
				Anim {
					property: "opacity"
					from: 0
					to: 1
				}
				SpatialAnim {
					property: "scale"
					from: 0.96
					to: 1
					duration: Motion.long
				}
			}
		}
		displaced: Transition {
			SpatialAnim {
				property: "y"
				duration: Motion.long
			}
		}
		move: Transition {
			SpatialAnim {
				property: "y"
				duration: Motion.extraLong
			}
		}
		remove: Transition {
			Anim {
				property: "opacity"
				to: 0
				duration: Motion.short
			}
		}

		header: ColumnLayout {
			width: list.width
			spacing: 12

			Item {
				Layout.fillWidth: true
				Layout.preferredHeight: Math.max(16, root.heroHeight - top.implicitHeight - 12)

				Rectangle {
					x: 20
					y: 16
					width: 44
					height: 44
					radius: 22
					color: Qt.rgba(0, 0, 0, backArea.containsMouse ? 0.75 : 0.45)
					scale: backArea.containsMouse ? 1.08 : 1

					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

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
						onClicked: root.closeRequested()
					}
				}
			}

			// ── the top ─────────────────────────────────────────────────
			ColumnLayout {
				id: top

				Layout.fillWidth: true
				Layout.leftMargin: 44
				Layout.rightMargin: 44
				spacing: 8

				Text {
					Layout.fillWidth: true
					Layout.maximumWidth: 820
					text: root.item?.name ?? ""
					color: Theme.dark ? "white" : Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: text.length > 30 ? 44 : 62
					font.weight: Font.Black
					wrapMode: Text.Wrap
					maximumLineCount: 2
					elide: Text.ElideRight
				}
				RowLayout {
					spacing: 10

					Avatar {
						Layout.preferredWidth: 28
						Layout.preferredHeight: 28
						visible: (root.item?.avatar ?? "") !== ""
						source: root.item?.avatar ?? ""
						name: root.item?.sourceNames?.[0] ?? ""
						colors: root.item?.colors ?? null
					}
					StyledText {
						text: (root.item?.sourceNames ?? []).join(", ")
						font.pixelSize: Theme.size.title
						font.weight: Font.Medium
					}
				}

				EpisodeSteps {
					Layout.fillWidth: true
					Layout.topMargin: 10
					barHeight: 10
					cells: root.item?.cells ?? []
					total: root.item?.total ?? 0
					done: root.item?.partial ?? 0
					accent: root.accent
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 16

					StyledText {
						text: `${root.item?.watched ?? 0} of ${root.item?.total ?? 0} watched`
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
						tabular: true
					}
					StyledText {
						visible: (root.item?.left ?? 0) > 0
						text: `${root.item?.left ?? 0} left · ${Streams.span(root.item?.remaining ?? 0)}`
						font.pixelSize: Theme.size.title
						tone: Theme.textMuted
						tabular: true
					}
					Item {
						Layout.fillWidth: true
					}
					StyledText {
						text: Streams.forecast(root.item?.forecast)
						font.pixelSize: Theme.size.body
						tone: Theme.textMuted
					}
				}

				RowLayout {
					Layout.topMargin: 10
					spacing: 10

					BigButton {
						visible: !!root.item?.next
						text: (root.item?.next?.position ?? 0) > 0 ? `Continue at ${Streams.clock(root.item.next.position)}` : `Play episode ${root.item?.next?.number ?? root.item?.next?.n ?? ""}`
						icon: "play"
						onClicked: Streams.playNext(root.seriesId)
					}
					BigButton {
						visible: !!root.item?.next && Streams.hasMpv
						text: "mpv"
						icon: "television"
						main: false
						onClicked: Streams.playNext(root.seriesId, "mpv")
					}
					BigButton {
						visible: (root.item?.watched ?? 0) > 0
						text: "What happened?"
						icon: "robot_outline"
						main: false
						onClicked: {
							const last = root.episodes.filter(episode => episode.watched).slice(-1)[0];
							if (last) root.wantRecap(last);
						}
					}
					BigButton {
						text: "Characters & notes"
						icon: "book_open_page_variant"
						main: false
						onClicked: root.showBook = true
					}
					BigButton {
						visible: (root.parts?.length ?? 0) > 0
						text: `${root.parts?.length ?? 0} series inside`
						icon: "playlist_check"
						main: false
						onClicked: Streams.open({ parts: { name: root.item.name, parts: root.parts, whole: null } })
					}
					Item {
						Layout.fillWidth: true
					}
					BigButton {
						implicitWidth: 46
						icon: root.item?.spoiler ? "eye_off_outline" : "eye_outline"
						main: false
						onClicked: Streams.updateSeries(root.seriesId, { spoiler: !root.item.spoiler })
					}
					BigButton {
						implicitWidth: 46
						icon: "tune"
						main: false
						onClicked: root.showSettings = !root.showSettings
					}
				}
			}

			// the way through many episodes
			Flow {
				Layout.fillWidth: true
				Layout.leftMargin: 44
				Layout.rightMargin: 44
				Layout.topMargin: 10
				spacing: 6
				visible: root.ranges.length > 0

				Repeater {
					model: root.ranges

					Chip {
						required property var modelData

						text: `${modelData.from}–${modelData.to}`
						onClicked: root.scrollToEpisode(modelData.from)
					}
				}
			}

			// a check on a later episode
			Rectangle {
				Layout.fillWidth: true
				Layout.leftMargin: 44
				Layout.rightMargin: 44
				Layout.preferredHeight: root.askUpTo !== "" ? 46 : 0
				radius: Theme.radius.medium
				color: Theme.primaryContainer
				clip: true
				opacity: root.askUpTo !== "" ? 1 : 0

				Behavior on Layout.preferredHeight {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					Anim {}
				}

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 14
					anchors.rightMargin: 6

					StyledText {
						Layout.fillWidth: true
						text: "Mark the ones before it as watched too?"
						font.pixelSize: Theme.size.label
					}
					TextButton {
						text: "Yes"
						variant: "tonal"
						onActivated: {
							Streams.mark(root.askUpTo, true, root.seriesId);
							root.askUpTo = "";
						}
					}
					TextButton {
						text: "No"
						variant: "ghost"
						onActivated: root.askUpTo = ""
					}
				}
			}

			// ── settings, unfolding ─────────────────────────────────────
			SeriesSettings {
				Layout.fillWidth: true
				Layout.leftMargin: 44
				Layout.rightMargin: 44
				shown: root.showSettings
				item: root.item
				onEditRule: root.editRule(root.item)
				onDeleted: root.closeRequested()
			}

			// ── maybe ────────────────────────────────────────────────────
			Repeater {
				model: root.maybes.slice(0, 4)

				RowLayout {
					id: maybe

					required property var modelData

					Layout.fillWidth: true
					Layout.leftMargin: 44
					Layout.rightMargin: 44
					spacing: 10

					Glyph {
						icon: "help_circle_outline"
						size: 16
						color: Theme.warning
					}
					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: maybe.modelData.title
							font.pixelSize: Theme.size.label
							elide: Text.ElideRight
						}
						StyledText {
							Layout.fillWidth: true
							text: maybe.modelData.why
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
							elide: Text.ElideRight
						}
					}
					TextButton {
						text: "Belongs"
						variant: "tonal"
						onActivated: Streams.teach(root.seriesId, maybe.modelData.id, "yes")
					}
					TextButton {
						text: "No"
						variant: "ghost"
						onActivated: Streams.teach(root.seriesId, maybe.modelData.id, "no")
					}
				}
			}

			Item {
				Layout.preferredHeight: 4
			}
		}

		delegate: Item {
			id: rowItem

			required property string key
			readonly property var episode: root.episodeById[rowItem.key] ?? null

			width: list.width
			height: root.rowHeight

			EpisodeRow {
				anchors.fill: parent
				anchors.leftMargin: 30
				anchors.rightMargin: 30
				anchors.bottomMargin: 4
				episode: rowItem.episode
				seriesItem: root.item
				onCheckClicked: episode => root.clicked(episode)
				onRecapWanted: episode => root.wantRecap(episode)
			}
		}

		footer: Item {
			width: list.width
			height: rows.count === 0 ? 240 : 8

			EmptyState {
				anchors.centerIn: parent
				visible: rows.count === 0
				icon: "playlist_plus"
				title: "No episodes yet"
				subtitle: "The rule found nothing so far. Change it in the settings above."
			}
		}
	}

	// ── all watched: a moment of glory ─────────────────────────────────────
	Item {
		id: done

		anchors.centerIn: parent
		width: 320
		height: 120
		opacity: 0
		scale: 0.6

		Rectangle {
			anchors.fill: parent
			radius: Theme.radius.huge
			color: root.accent
		}
		ColumnLayout {
			anchors.centerIn: parent
			spacing: 2

			Glyph {
				Layout.alignment: Qt.AlignHCenter
				icon: "trophy"
				size: 30
				color: Theme.contrast(root.accent, "#000000") > 4.5 ? "black" : "white"
			}
			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: `All ${root.item?.total ?? ""} watched`
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
				color: Theme.contrast(root.accent, "#000000") > 4.5 ? "black" : "white"
			}
		}

		SequentialAnimation {
			id: celebrate

			ParallelAnimation {
				SpatialAnim {
					target: done
					property: "scale"
					to: 1
					duration: Motion.extraLong
				}
				Anim {
					target: done
					property: "opacity"
					to: 1
				}
			}
			PauseAnimation {
				duration: 1500
			}
			ParallelAnimation {
				Anim {
					target: done
					property: "opacity"
					to: 0
				}
				Anim {
					target: done
					property: "scale"
					to: 0.9
				}
			}
			ScriptAction {
				script: done.scale = 0.6
			}
		}
	}

	// ── the recap ──────────────────────────────────────────────────────────
	Rectangle {
		anchors.fill: parent
		color: Theme.scrim
		opacity: root.recap ? 1 : 0
		visible: opacity > 0

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: root.recap = null
		}

		Rectangle {
			anchors.centerIn: parent
			width: Math.min(parent.width - 60, 560)
			height: Math.min(parent.height - 60, recapColumn.implicitHeight + 44)
			radius: Theme.radius.huge
			color: Theme.layer2
			scale: root.recap ? 1 : 0.9

			Behavior on scale {
				SpatialAnim {}
			}
			Behavior on height {
				SpatialAnim {}
			}

			MouseArea {
				anchors.fill: parent
			}

			ColumnLayout {
				id: recapColumn

				anchors.fill: parent
				anchors.margins: 22
				spacing: 10

				StyledText {
					Layout.fillWidth: true
					text: "What happened"
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}
				StyledText {
					Layout.fillWidth: true
					text: root.recap?.episode.title ?? ""
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
					elide: Text.ElideRight
				}
				RowLayout {
					visible: root.recap?.busy ?? false
					spacing: 10
					Spinner {
						Layout.preferredWidth: 18
						Layout.preferredHeight: 18
					}
					StyledText {
						text: "Reading the subtitles…"
						tone: Theme.textMuted
					}
				}
				StyledText {
					Layout.fillWidth: true
					Layout.fillHeight: true
					visible: !(root.recap?.busy ?? false)
					text: root.recap?.error || root.recap?.text || ""
					tone: root.recap?.error ? Theme.warning : Theme.text
					font.pixelSize: Theme.size.body
					wrapMode: Text.Wrap
				}
				StyledText {
					Layout.fillWidth: true
					visible: !(root.recap?.busy ?? false) && !root.recap?.error
					text: "Written by a local AI from the subtitles. It can be wrong."
					font.pixelSize: Theme.size.tiny
					tone: Theme.textSubtle
				}
				RowLayout {
					id: recapVideoRow

					readonly property var job: Streams.recapJob?.video === root.recap?.episode.id ? Streams.recapJob : null
					readonly property bool cutting: !!recapVideoRow.job && !recapVideoRow.job.over
					readonly property var info: recapVideoRow.job?.over && recapVideoRow.job.ready ? recapVideoRow.job : (root.recap?.video ?? null)

					Layout.fillWidth: true
					Layout.topMargin: 6
					visible: !(root.recap?.busy ?? false) && !root.recap?.error
					spacing: 10

					Spinner {
						visible: recapVideoRow.cutting
						Layout.preferredWidth: 18
						Layout.preferredHeight: 18
					}
					StyledText {
						Layout.fillWidth: true
						wrapMode: Text.Wrap
						font.pixelSize: Theme.size.small
						tone: recapVideoRow.job?.error ? Theme.warning : Theme.textMuted
						text: {
							if (recapVideoRow.cutting) return recapVideoRow.job.step;
							if (recapVideoRow.job?.error) return recapVideoRow.job.error;
							if (recapVideoRow.info?.ready) return `A video of ${Streams.clock(recapVideoRow.info.seconds)} (${Math.max(1, Math.round(recapVideoRow.info.bytes / 1000000))} MB) plays before the next episode. It goes away once that episode is watched.`;
							return "A short video from the passages this recap talks about, before the next episode.";
						}
					}
					TextButton {
						visible: !recapVideoRow.cutting && !recapVideoRow.info?.ready
						text: "Make a video"
						onActivated: Streams.call("recapVideo", { video: root.recap.episode.id }, Streams.report())
					}
					// back after long: more than the one episode, as long as wanted
					Repeater {
						model: root.recap && root.recap.episode.n > 1 ? [[3, 60, "1 min"], [3, 180, "3 min"], [5, 300, "5 min"]] : []

						TextButton {
							required property var modelData

							visible: !recapVideoRow.cutting
							text: `Last ${modelData[0]}: ${modelData[2]}`
							onActivated: Streams.call("recapVideo", { video: root.recap.episode.id, episodes: modelData[0], seconds: modelData[1] }, Streams.report())
						}
					}
				}
			}
		}
	}

	// ── what was noted, and what was said in the episodes ──────────────────
	Rectangle {
		anchors.fill: parent
		color: Theme.scrim
		opacity: root.showBook ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: root.showBook = false
		}

		SeriesBook {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.bottom: parent.bottom
			width: parent.width
			seriesId: root.seriesId
			shown: root.showBook
			transform: Translate {
				x: root.showBook ? 0 : 80

				Behavior on x {
					SpatialAnim {
						duration: Motion.long
					}
				}
			}
			onCloseRequested: root.showBook = false
		}
	}
}
