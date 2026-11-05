pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The downloads panel: along the top everything's speed, large, with how
// many run and when the last is through, and the last two minutes as a
// graph; a link can be added (+, or Ctrl+V on the panel). Below *Active*
// (every download as a card that fills), *Finished* and *Statistics*.
ColumnLayout {
	id: root

	property bool shown: false
	property string page: "active"
	property bool adding: false
	property bool settings: false
	// the cards of downloads that just finished, shown green a moment: { key: until }
	property var justDone: ({})
	property real now: Date.now()

	readonly property var activeKeys: Downloads.order.filter(key => {
		const item = Downloads.table[key];
		return item && (item.state === "running" || item.state === "paused" || (item.state === "failed" && item.source === "boost") || (root.justDone[key] ?? 0) > root.now);
	}).sort((a, b) => Downloads.table[a].started - Downloads.table[b].started)
	readonly property var finishedKeys: Downloads.order.filter(key => {
		const item = Downloads.table[key];
		return item && (item.state === "done" || item.state === "failed") && !root.activeKeys.includes(key);
	})
	readonly property bool boosting: Downloads.running.some(item => item.source === "boost" && item.mode === "boost")
	readonly property real listHeight: Math.max(220, Math.min(560, (Window.window?.height ?? 900) - 340))

	spacing: 12

	function takeFocus() {
		keys.forceActiveFocus();
	}

	function addLink(text) {
		const link = String(text || "").trim();
		if (!/^https?:\/\//i.test(link)) return false;
		Boost.add(link);
		root.adding = false;
		root.page = "active";
		return true;
	}

	onShownChanged: {
		if (root.shown) {
			Downloads.seen();
			// what runs first, else what came in last
			if (root.activeKeys.length === 0 && root.finishedKeys.length > 0 && Downloads.unseen > 0) root.page = "finished";
		} else {
			root.settings = false;
			root.adding = false;
		}
	}

	Connections {
		target: Downloads
		function onUnseenChanged() {
			if (root.shown) Downloads.seen();
		}
		function onFinished(item) {
			root.now = Date.now();
			root.justDone = Object.assign({}, root.justDone, { [item.key]: Date.now() + 2600 });
			settle.restart();
		}
	}

	// the green moment is over: the card moves on
	Timer {
		id: settle

		interval: 2700
		onTriggered: {
			root.now = Date.now();
			const next = {};
			for (const key of Object.keys(root.justDone))
				if (root.justDone[key] > root.now) next[key] = root.justDone[key];
			root.justDone = next;
			if (Object.keys(next).length > 0) settle.restart();
		}
	}

	// Ctrl+V on the panel adds the link that was copied
	Item {
		id: keys

		Layout.preferredHeight: 0
		Layout.preferredWidth: 0
		focus: true
		Keys.onPressed: event => {
			if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
				paste.running = true;
				event.accepted = true;
			} else if (event.key === Qt.Key_Escape) {
				if (root.adding || root.settings) {
					root.adding = false;
					root.settings = false;
				} else {
					Downloads.closePanel();
				}
				event.accepted = true;
			} else if (event.key === Qt.Key_Tab) {
				const pages = ["active", "finished", "stats"];
				root.page = pages[(pages.indexOf(root.page) + ((event.modifiers & Qt.ShiftModifier) ? 2 : 1)) % 3];
				event.accepted = true;
			}
		}
	}

	Process {
		id: paste

		command: ["wl-paste", "--no-newline", "--type", "text"]
		stdout: StdioCollector {
			onStreamFinished: {
				if (!root.addLink(text)) {
					root.adding = true;
					field.text = String(text || "").trim().slice(0, 2000);
					field.input.forceActiveFocus();
				}
			}
		}
	}

	// ── the head ───────────────────────────────────────────────────────────
	RowLayout {
		Layout.fillWidth: true
		spacing: 14

		// everything under way as one ring; the arrow falls through it
		Item {
			Layout.preferredWidth: 52
			Layout.preferredHeight: 52

			Rectangle {
				anchors.fill: parent
				radius: width / 2
				color: root.boosting ? Qt.alpha(Theme.primary, 0.16) : Theme.layer1

				Behavior on color {
					ColorAnim {
						duration: Motion.long
					}
				}
			}

			// a halo that breathes while accelerated downloads run
			Rectangle {
				id: halo

				anchors.centerIn: parent
				width: parent.width
				height: width
				radius: width / 2
				color: "transparent"
				border.width: 2
				border.color: Theme.primary
				opacity: 0
				visible: root.boosting

				ParallelAnimation {
					running: root.boosting && root.shown
					loops: Animation.Infinite
					NumberAnimation { target: halo; property: "scale"; from: 1; to: 1.35; duration: 1600; easing.type: Easing.OutCubic }
					NumberAnimation { target: halo; property: "opacity"; from: 0.5; to: 0; duration: 1600; easing.type: Easing.OutCubic }
				}
			}

			Ring {
				anchors.fill: parent
				anchors.margins: 3
				visible: Downloads.active.length > 0
				value: Math.max(0, Downloads.ratio)
				thickness: 3.5
				color: Downloads.running.length > 0 ? Theme.primary : Theme.textMuted
				trackColor: Qt.alpha(Theme.text, 0.12)
			}

			Glyph {
				id: arrow

				property real drop: 0

				anchors.horizontalCenter: parent.horizontalCenter
				y: (parent.height - height) / 2 + arrow.drop
				icon: root.boosting ? "lightning_bolt" : (Downloads.running.length > 0 ? "arrow_down_bold" : (Downloads.active.length > 0 ? "pause" : "download"))
				size: 22
				color: Downloads.running.length > 0 ? Theme.primary : Theme.textMuted

				SequentialAnimation on drop {
					running: Downloads.running.length > 0 && !root.boosting && root.shown
					loops: Animation.Infinite
					onRunningChanged: if (!running) arrow.drop = 0
					NumberAnimation { from: -3; to: 3; duration: 850; easing.type: Easing.InOutSine }
					NumberAnimation { from: 3; to: -3; duration: 0 }
				}
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 0

			RowLayout {
				spacing: 8

				StyledText {
					text: "Downloads"
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				// a browser is connected
				Rectangle {
					implicitWidth: 7
					implicitHeight: 7
					radius: 3.5
					color: Downloads.connected ? Theme.success : Theme.textFaint

					Behavior on color {
						ColorAnim {}
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: {
					const running = Downloads.running.length;
					const paused = Downloads.active.length - running;
					if (Boost.adding > 0) return "Asking the server…";
					if (running === 0 && paused === 0) return Downloads.connected ? "Nothing under way · the browser is connected" : "Nothing under way";
					const parts = [`${running} running`];
					if (paused > 0) parts.push(`${paused} paused`);
					if (Downloads.eta >= 0) parts.push(`done ${Torrents.finishTime(Downloads.eta)}`);
					return parts.join("  ·  ");
				}
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
				elide: Text.ElideRight
			}
		}

		// everything's speed, large
		ColumnLayout {
			spacing: -2
			opacity: Downloads.running.length > 0 ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}

			RollingText {
				Layout.alignment: Qt.AlignRight
				value: Downloads.speed
				duration: 900
				format: value => Format.rate(value)
				font.pixelSize: Theme.size.display - 4
				font.weight: Font.Bold
				tone: Theme.primary
			}

			StyledText {
				Layout.alignment: Qt.AlignRight
				text: Downloads.ratio >= 0 ? `${Math.floor(Downloads.ratio * 100)} % of everything` : ""
				font.pixelSize: Theme.size.tiny
				tone: Theme.textSubtle
				tabular: true
			}
		}

		IconButton {
			implicitWidth: 34
			implicitHeight: 34
			icon: "plus"
			iconSize: 18
			checked: root.adding
			enabled: Boost.enabled
			opacity: Boost.enabled ? 1 : 0.4
			onClicked: {
				root.adding = !root.adding;
				root.settings = false;
				if (root.adding) Qt.callLater(() => field.input.forceActiveFocus());
				else root.takeFocus();
			}
		}

		IconButton {
			implicitWidth: 34
			implicitHeight: 34
			icon: "tune"
			iconSize: 17
			checked: root.settings
			onClicked: {
				root.settings = !root.settings;
				root.adding = false;
			}
		}
	}

	// the last two minutes, everything together
	Item {
		Layout.fillWidth: true
		Layout.preferredHeight: Downloads.live.length > 2 ? 58 : 0
		opacity: Downloads.live.length > 2 ? 1 : 0
		visible: Layout.preferredHeight > 0.5
		clip: true

		Behavior on Layout.preferredHeight {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		Rectangle {
			anchors.fill: parent
			radius: Theme.radius.large
			color: Theme.layer1
		}

		Sparkline {
			anchors.fill: parent
			anchors.topMargin: 10
			values: Downloads.live.length > 1 ? Downloads.live : [0, 0]
			color: Theme.primary
			lineWidth: 2
		}

		StyledText {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 8
			text: `peak ${Format.rate(Math.max(0, ...Downloads.live))}`
			font.pixelSize: Theme.size.tiny
			tone: Theme.textSubtle
			tabular: true
		}
	}

	// ── add a link ─────────────────────────────────────────────────────────
	Item {
		Layout.fillWidth: true
		Layout.preferredHeight: root.adding ? addRow.implicitHeight : 0
		opacity: root.adding ? 1 : 0
		visible: Layout.preferredHeight > 0.5
		clip: true

		Behavior on Layout.preferredHeight {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on opacity {
			Anim {}
		}

		ColumnLayout {
			id: addRow

			width: parent.width
			spacing: 6

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Field {
					id: field

					Layout.fillWidth: true
					icon: "link_variant"
					placeholder: "Paste a link to download…"
					onAccepted: {
						if (root.addLink(field.text)) field.text = "";
					}
					onEscapePressed: {
						root.adding = false;
						root.takeFocus();
					}
				}

				TextButton {
					text: "Download"
					icon: "download"
					variant: "filled"
					enabled: /^https?:\/\//i.test(field.text.trim())
					onActivated: {
						if (root.addLink(field.text)) field.text = "";
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				Layout.leftMargin: 4
				text: `Into ${(Boost.settings.folder || `${Paths.home}/Downloads`).replace(Paths.home, "~")} – over ${Boost.settings.connections} connections where the server allows it.`
				font.pixelSize: Theme.size.tiny
				tone: Theme.textSubtle
				elide: Text.ElideMiddle
			}
		}
	}

	// ── the settings ───────────────────────────────────────────────────────
	Item {
		Layout.fillWidth: true
		Layout.preferredHeight: root.settings ? Math.min(sheet.implicitHeight, root.listHeight + 60) : 0
		opacity: root.settings ? 1 : 0
		visible: Layout.preferredHeight > 0.5
		clip: true

		Behavior on Layout.preferredHeight {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on opacity {
			Anim {}
		}

		Flickable {
			anchors.fill: parent
			contentHeight: sheet.implicitHeight
			boundsBehavior: Flickable.StopAtBounds
			clip: true

			BoostSettings {
				id: sheet

				width: parent.width
			}
		}
	}

	// ── the pages ──────────────────────────────────────────────────────────
	Segmented {
		Layout.fillWidth: true
		current: root.page
		options: [
			{ value: "active", label: root.activeKeys.length > 0 ? `Active  ${root.activeKeys.length}` : "Active", icon: "progress_download" },
			{ value: "finished", label: root.finishedKeys.length > 0 ? `Finished  ${root.finishedKeys.length}` : "Finished", icon: "check_bold" },
			{ value: "stats", label: "Statistics", icon: "chart_bar" }
		]
		onSelected: value => root.page = value
	}

	PageView {
		Layout.fillWidth: true
		current: root.page

		Page {
			pageName: "active"

			ColumnLayout {
				width: parent.width
				spacing: 0

				EmptyState {
					Layout.fillWidth: true
					Layout.topMargin: 34
					Layout.bottomMargin: 34
					visible: root.activeKeys.length === 0
					icon: "download"
					title: "Nothing downloading"
					subtitle: Boost.enabled ? "What the browser downloads shows here – sped up over several connections where the server allows it. Ctrl+V adds a copied link." : "What the browser downloads shows here."
				}

				ListView {
					id: activeList

					Layout.fillWidth: true
					Layout.preferredHeight: Math.min(contentHeight, root.listHeight)
					visible: root.activeKeys.length > 0
					model: activeModel.model
					spacing: 8
					clip: true
					interactive: contentHeight > height
					boundsBehavior: Flickable.StopAtBounds

					Behavior on Layout.preferredHeight {
						SpatialAnim {
							duration: Motion.long
						}
					}

					KeyModel {
						id: activeModel

						keys: root.activeKeys
					}

					delegate: TransferCard {
						width: activeList.width
						justDone: (root.justDone[key] ?? 0) > root.now
						expanded: root.activeKeys.length === 1
					}

					add: Transition {
						ParallelAnimation {
							NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Motion.long; easing.type: Easing.OutCubic }
							NumberAnimation { property: "scale"; from: 0.92; to: 1; duration: Motion.long; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.spatial }
						}
					}
					remove: Transition {
						ParallelAnimation {
							NumberAnimation { property: "opacity"; to: 0; duration: Motion.medium; easing.type: Easing.InCubic }
							NumberAnimation { property: "x"; to: 60; duration: Motion.medium; easing.type: Easing.InCubic }
						}
					}
					displaced: Transition {
						SpatialAnim {
							properties: "x,y"
						}
					}
				}
			}
		}

		Page {
			pageName: "finished"

			ColumnLayout {
				width: parent.width
				spacing: 8

				EmptyState {
					Layout.fillWidth: true
					Layout.topMargin: 34
					Layout.bottomMargin: 34
					visible: root.finishedKeys.length === 0
					icon: "check_bold"
					title: "Nothing finished yet"
					subtitle: "Finished downloads stay here until they are dismissed."
				}

				ListView {
					id: finishedList

					Layout.fillWidth: true
					Layout.preferredHeight: Math.min(contentHeight, root.listHeight - 40)
					visible: root.finishedKeys.length > 0
					model: finishedModel.model
					spacing: 6
					clip: true
					interactive: contentHeight > height
					boundsBehavior: Flickable.StopAtBounds

					KeyModel {
						id: finishedModel

						keys: root.finishedKeys
					}

					delegate: FinishedRow {
						width: finishedList.width
					}

					add: Transition {
						ParallelAnimation {
							NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Motion.long; easing.type: Easing.OutCubic }
							NumberAnimation { property: "y"; from: -20; duration: Motion.long; easing.type: Easing.OutCubic }
						}
					}
					remove: Transition {
						ParallelAnimation {
							NumberAnimation { property: "opacity"; to: 0; duration: Motion.medium; easing.type: Easing.InCubic }
							NumberAnimation { property: "scale"; to: 0.94; duration: Motion.medium; easing.type: Easing.InCubic }
						}
					}
					displaced: Transition {
						SpatialAnim {
							properties: "x,y"
						}
					}
				}

				RowLayout {
					Layout.fillWidth: true
					visible: root.finishedKeys.length > 1

					Item {
						Layout.fillWidth: true
					}

					TextButton {
						text: "Clear all"
						icon: "broom"
						variant: "ghost"
						onActivated: root.finishedKeys.slice().forEach(key => Downloads.dismiss(key))
					}
				}
			}
		}

		Page {
			pageName: "stats"

			StatsPage {
				width: parent.width
				shown: root.shown && root.page === "stats"
			}
		}
	}
}
