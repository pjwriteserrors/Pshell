pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// In the player's side panel: who is talked about, questions, clips and the loud
// moments. All of it knows only what was seen, and of this episode what came
// before the position.
ColumnLayout {
	id: root

	property string mode: ""
	property string seriesId: ""
	property string video: ""
	property real position: 0
	property real ui: 1
	property var digest: []
	// what listening found
	property var moments: []
	property bool momentsPending: false
	property var people: []
	property bool reading: false
	property bool hasSheets: false
	property var nameHits: []
	property string nameAsked: ""
	property var answer: null
	property bool asking: false
	property var clips: []

	signal jump(string video, real at)
	signal digestWanted(var moments)
	signal done

	spacing: 10 * root.ui

	function refresh() {
		if (root.mode === "who") root.askWho();
		else if (root.mode === "clips") root.loadClips();
		else if (root.mode === "highlights") root.loadMoments();
	}

	function askWho() {
		if (!root.seriesId) return;
		Streams.call("whoNow", { series: root.seriesId, video: root.video, at: root.position }, data => {
			root.people = data?.people ?? [];
			root.reading = data?.reading ?? false;
			root.hasSheets = data?.sheets ?? false;
		});
	}

	function loadClips() {
		Streams.call("clips", root.seriesId ? { series: root.seriesId } : {}, data => root.clips = (data ?? []).filter(clip => root.seriesId || clip.video === root.video));
	}

	function loadMoments() {
		if (!root.video) return;
		Streams.call("highlights", { video: root.video }, data => {
			root.moments = data?.moments ?? [];
			root.momentsPending = data?.pending ?? false;
		});
	}

	onModeChanged: {
		root.refresh();
		// what is typed here is a question, not the player's keys
		if (root.mode === "ask") askField.input.forceActiveFocus();
	}
	onVideoChanged: {
		root.moments = [];
		root.refresh();
	}

	Timer {
		interval: 8000
		repeat: true
		running: root.visible && (root.mode === "who" || (root.mode === "highlights" && root.momentsPending))
		onTriggered: root.refresh()
	}

	component Word: Text {
		Layout.fillWidth: true
		color: Qt.rgba(1, 1, 1, 0.66)
		wrapMode: Text.Wrap
		font.family: Theme.fontFamily
		font.pixelSize: 13 * root.ui
	}

	component Hit: Rectangle {
		id: hit

		property string body: ""
		property string under: ""
		signal picked

		width: parent?.width ?? 0
		height: hitColumn.implicitHeight + 16
		radius: 8
		color: hitArea.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06)

		ColumnLayout {
			id: hitColumn

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 8
			spacing: 2

			Text {
				Layout.fillWidth: true
				text: hit.body
				color: "white"
				wrapMode: Text.Wrap
				font.family: Theme.fontFamily
				font.pixelSize: 13 * root.ui
			}
			Text {
				Layout.fillWidth: true
				text: hit.under
				color: Qt.rgba(1, 1, 1, 0.56)
				elide: Text.ElideRight
				font.family: Theme.fontFamily
				font.pixelSize: 12 * root.ui
			}
		}
		MouseArea {
			id: hitArea

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: hit.picked()
		}
	}

	// ── who is this? ────────────────────────────────────────────────────
	Word {
		visible: root.mode === "who" && root.people.length === 0
		text: root.reading ? "Reading this episode's subtitles…" : (root.hasSheets ? "Nobody from the character sheets was named in the last minute and a half." : "This series has no character sheets yet. A name below still finds where it was said.")
	}
	Repeater {
		model: root.mode === "who" ? root.people : []

		ColumnLayout {
			id: person

			required property var modelData

			Layout.fillWidth: true
			spacing: 2

			Text {
				Layout.fillWidth: true
				text: person.modelData.player ? `${person.modelData.name} · ${person.modelData.player}` : person.modelData.name
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: 16 * root.ui
				font.weight: Font.Bold
			}
			Repeater {
				model: person.modelData.facts

				Word {
					required property var modelData

					text: `${modelData.label}: ${modelData.value}`
				}
			}
		}
	}
	Field {
		Layout.fillWidth: true
		visible: root.mode === "who"
		icon: "magnify"
		placeholder: "Who was that again? A name"
		onEdited: text => {
			root.nameAsked = text;
			nameTimer.restart();
		}
		onEscapePressed: root.done()
	}
	Timer {
		id: nameTimer

		interval: 240
		onTriggered: Streams.call("whoWas", { series: root.seriesId, name: root.nameAsked, video: root.video, at: root.position }, data => root.nameHits = data?.hits ?? [])
	}
	ListView {
		id: nameList

		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: root.mode === "who"
		clip: true
		spacing: 6
		model: root.mode === "who" ? root.nameHits : []

		delegate: Hit {
			required property var modelData

			width: nameList.width
			body: modelData.text
			under: `Episode ${modelData.n} · ${Streams.clock(modelData.at)}`
			onPicked: root.jump(modelData.video, modelData.at)
		}
	}

	// ── ask ─────────────────────────────────────────────────────────────
	Field {
		id: askField

		Layout.fillWidth: true
		visible: root.mode === "ask"
		icon: "help_circle_outline"
		placeholder: "Why did they lose the ship?"
		onAccepted: {
			if (askField.text.trim() === "" || root.asking) return;
			root.asking = true;
			root.answer = null;
			Streams.call("askSeries", { series: root.seriesId, question: askField.text, video: root.video, at: root.position }, (data, error) => {
				root.asking = false;
				root.answer = error ? { answer: "", why: error, lines: [] } : data;
			});
		}
		onEscapePressed: root.done()
	}
	Word {
		visible: root.mode === "ask" && !root.answer && !root.asking
		text: "Answers come from the subtitles of what you have seen. If the proof is not in them, you get no answer."
	}
	Spinner {
		Layout.alignment: Qt.AlignHCenter
		visible: root.mode === "ask" && root.asking
		color: "white"
		Layout.preferredWidth: 28
		Layout.preferredHeight: 28
	}
	Text {
		Layout.fillWidth: true
		visible: root.mode === "ask" && !!root.answer?.answer
		text: root.answer?.answer ?? ""
		color: "white"
		wrapMode: Text.Wrap
		font.family: Theme.fontFamily
		font.pixelSize: 16 * root.ui
	}
	Hit {
		Layout.fillWidth: true
		visible: root.mode === "ask" && !!root.answer?.answer
		body: `“${root.answer?.quote ?? ""}”`
		under: `${Streams.clock(root.answer?.at ?? 0)} · ${root.answer?.title ?? ""}`
		onPicked: root.jump(root.answer.video, root.answer.at)
	}
	Word {
		visible: root.mode === "ask" && !!root.answer && !root.answer.answer
		text: root.answer?.why ?? ""
	}
	ListView {
		id: closeList

		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: root.mode === "ask"
		clip: true
		spacing: 6
		model: root.mode === "ask" ? (root.answer?.lines ?? []) : []

		delegate: Hit {
			required property var modelData

			width: closeList.width
			body: modelData.text
			under: `${Streams.clock(modelData.at)} · ${modelData.title}`
			onPicked: root.jump(modelData.video, modelData.at)
		}
	}

	// ── clips ───────────────────────────────────────────────────────────
	Word {
		visible: root.mode === "clips" && clipList.count === 0
		text: "Press X to keep the last 30 seconds. Only the time is kept; a file is made when you ask for one."
	}
	ListView {
		id: clipList

		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: root.mode === "clips"
		clip: true
		spacing: 6
		model: root.mode === "clips" ? root.clips : []

		delegate: Rectangle {
			id: clipRow

			required property var modelData
			property bool cutting: false

			width: clipList.width
			height: clipColumn.implicitHeight + 16
			radius: 8
			color: Qt.rgba(1, 1, 1, 0.06)

			ColumnLayout {
				id: clipColumn

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 8
				spacing: 4

				Text {
					Layout.fillWidth: true
					text: clipRow.modelData.title
					color: "white"
					elide: Text.ElideRight
					font.family: Theme.fontFamily
					font.pixelSize: 13 * root.ui
				}
				RowLayout {
					Layout.fillWidth: true

					Text {
						Layout.fillWidth: true
						text: `${Streams.clock(clipRow.modelData.at)} – ${Streams.clock(clipRow.modelData.end)}`
						color: Qt.rgba(1, 1, 1, 0.56)
						font.family: Theme.fontFamily
						font.pixelSize: 12 * root.ui
					}
					TextButton {
						text: "Watch"
						onActivated: root.jump(clipRow.modelData.video, clipRow.modelData.at)
					}
					TextButton {
						text: clipRow.cutting ? "Cutting…" : "Save file"
						enabled: !clipRow.cutting
						onActivated: {
							clipRow.cutting = true;
							Streams.call("clipExport", { id: clipRow.modelData.id }, Streams.report((data, error) => {
								clipRow.cutting = false;
								if (data?.file) Notifs.pushInternal("done", "Clip saved", data.file, { icon: "check" });
							}));
						}
					}
					TextButton {
						icon: "close"
						text: ""
						onActivated: Streams.call("clipRemove", { id: clipRow.modelData.id }, () => root.loadClips())
					}
				}
			}
		}
	}

	// ── the loud moments ────────────────────────────────────────────────
	Word {
		visible: root.mode === "highlights" && root.momentsPending
		text: "Listening to this episode. That goes about 80 times as fast as watching."
	}
	Word {
		visible: root.mode === "highlights" && !root.momentsPending && root.moments.length === 0
		text: "Nothing stands out from the talk around it."
	}
	TextButton {
		Layout.fillWidth: true
		visible: root.mode === "highlights" && root.moments.length > 0
		text: root.digest.length > 0 ? "Back to the whole video" : `Watch only these (${Streams.span(root.moments.reduce((sum, part) => sum + part.end - part.at, 0))})`
		onActivated: root.digestWanted(root.digest.length > 0 ? [] : root.moments)
	}
	ListView {
		id: momentList

		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: root.mode === "highlights"
		clip: true
		spacing: 6
		model: root.mode === "highlights" ? root.moments : []

		delegate: Hit {
			required property var modelData

			width: momentList.width
			body: modelData.said || "Without words"
			under: `${Streams.clock(modelData.at)} · ${Streams.span(modelData.end - modelData.at)}`
			onPicked: root.jump(root.video, modelData.at)
		}
	}
}
