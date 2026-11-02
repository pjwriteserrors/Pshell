pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// (StreamsView.qml fits this to the window.)
// Everything that is followed, in the manner of a streaming service: the pages
// fill the window under a thin bar that clears over pictures. A series grows out
// of the card that was clicked; the rule workshop and the evening slide up.
Item {
	id: root

	property bool windowed: true
	// now | feed | series | explore | plan | sources | year
	property string page: "now"
	property string lastPage: "now"
	// the opened series and the picture it grows from
	property string openId: ""
	property rect origin: Qt.rect(0, 0, 0, 0)
	property real bloom: 0
	readonly property var pages: [
		{ id: "now", label: "Home", badge: Streams.liveCount, live: true },
		{ id: "feed", label: "Subscriptions", badge: 0, live: false },
		{ id: "series", label: "Series", badge: Streams.freshCount, live: false },
		{ id: "explore", label: "Explore", badge: Streams.shownDiscoveries.length, live: false },
		{ id: "plan", label: "This week", badge: 0, live: false },
		{ id: "sources", label: "Channels", badge: Streams.ownSources.filter(item => item.error).length, live: true },
		{ id: "said", label: "What was said", badge: 0, live: false },
		{ id: "year", label: "Your year", badge: 0, live: false }
	]
	readonly property int pageIndex: root.pages.findIndex(entry => entry.id === root.page)
	readonly property var openItem: Streams.seriesById[root.openId] ?? null
	// the bar clears over the home page's picture
	readonly property bool barClear: root.page === "now" && homePage.contentY < 180 && Streams.ownSources.length > 0
	readonly property bool covered: workshop.shown || tonight.shown || partsSheet.shown

	function takeFocus() {
		keys.forceActiveFocus();
		root.takeWanted();
	}

	function takeWanted() {
		const wanted = Streams.wanted;
		if (!wanted) return;
		Streams.wanted = null;
		if (wanted.said !== undefined) Streams.saidWanted = wanted.said;
		if (wanted.page) root.go(wanted.page);
		if (wanted.series) root.openSeries(wanted.series, null);
		if (wanted.tonight) root.showTonight();
		if (wanted.newSeries) root.showWorkshop(wanted.newSeries);
		if (wanted.add) Qt.callLater(() => sourcesPage.add(wanted.add));
		if (wanted.parts) root.showParts(wanted.parts);
	}

	function go(id) {
		root.closeSeries();
		workshop.shown = false;
		tonight.shown = false;
		partsSheet.shown = false;
		if (root.page !== id) root.lastPage = root.page;
		root.page = id;
	}

	function openSeries(id, from) {
		if (from) {
			const at = from.mapToItem(stage, 0, 0);
			root.origin = Qt.rect(at.x, at.y, from.width, from.height);
		} else {
			const width = stage.width * 0.5;
			root.origin = Qt.rect((stage.width - width) / 2, stage.height * 0.2, width, width * 9 / 16);
		}
		root.openId = id;
		bloomOut.stop();
		bloomIn.restart();
	}

	function closeSeries() {
		if (root.openId === "" || bloomOut.running) return;
		bloomIn.stop();
		bloomOut.restart();
	}

	function showWorkshop(preset) {
		workshop.body.reset(preset);
		workshop.shown = true;
	}

	// the series inside a series: { name, parts, whole: discovery | null }
	function showParts(what) {
		partsSheet.body.show(what);
		partsSheet.shown = true;
	}

	function showTonight() {
		tonight.body.show();
		tonight.shown = true;
	}

	onVisibleChanged: if (visible) root.takeWanted()

	Connections {
		target: Streams

		function onWantedChanged() {
			if (Streams.wanted && root.visible) root.takeWanted();
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Streams.pageColor
	}

	Item {
		id: keys

		anchors.fill: parent
		focus: true
		Keys.onEscapePressed: {
			if (workshop.shown) workshop.shown = false;
			else if (partsSheet.shown) partsSheet.shown = false;
			else if (tonight.shown) tonight.shown = false;
			else if (root.openId !== "") root.closeSeries();
			else Streams.close();
		}
		Keys.onPressed: event => {
			const index = event.key - Qt.Key_1;
			if (index >= 0 && index < root.pages.length && !(event.modifiers & Qt.ControlModifier)) {
				root.go(root.pages[index].id);
				event.accepted = true;
			} else if (event.key === Qt.Key_T) {
				root.showTonight();
				event.accepted = true;
			} else if (event.key === Qt.Key_N) {
				root.showWorkshop(null);
				event.accepted = true;
			}
		}
	}

	Item {
		id: stage

		anchors.fill: parent
		clip: true

		Item {
			id: pagesHolder

			anchors.fill: parent
			// what is underneath steps back as a series opens
			scale: 1 - root.bloom * 0.05
			opacity: 1 - root.bloom * 0.85
			visible: root.bloom < 0.999 && !(workshop.reveal >= 0.999) && !(tonight.reveal >= 0.999) && !(partsSheet.reveal >= 0.999)

			component PageFade: Item {
				id: fade

				required property string name
				required property int order
				default property alias content: fade.data
				readonly property bool current: root.page === fade.name

				anchors.fill: parent
				opacity: fade.current ? 1 : 0
				visible: opacity > 0.01
				// from the side it lies on
				transform: Translate {
					x: fade.current ? 0 : (fade.order < root.pageIndex ? -46 : 46)

					Behavior on x {
						NumberAnimation {
							duration: Motion.extraLong
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.decel
						}
					}
				}

				Behavior on opacity {
					Anim {
						duration: fade.current ? Motion.long : Motion.short
					}
				}
			}

			PageFade {
				name: "now"
				order: 0

				NowPage {
					id: homePage

					anchors.fill: parent
					onOpenSeries: (id, from) => root.openSeries(id, from)
					onOpenTonight: root.showTonight()
					onNewSeries: preset => root.showWorkshop(preset)
				}
			}
			PageFade {
				name: "feed"
				order: 1

				FeedPage {
					anchors.fill: parent
				}
			}
			PageFade {
				name: "series"
				order: 2

				SeriesPage {
					anchors.fill: parent
					onOpenSeries: (id, from) => root.openSeries(id, from)
					onNewSeries: preset => root.showWorkshop(preset)
				}
			}
			PageFade {
				name: "explore"
				order: 3

				ExplorePage {
					anchors.fill: parent
				}
			}
			PageFade {
				name: "plan"
				order: 4

				PlanPage {
					anchors.fill: parent
					onOpenSeries: id => root.openSeries(id, null)
				}
			}
			PageFade {
				name: "sources"
				order: 5

				SourcesPage {
					id: sourcesPage

					anchors.fill: parent
				}
			}
			PageFade {
				name: "said"
				order: 6

				Loader {
					anchors.fill: parent
					active: root.page === "said"
					sourceComponent: SaidPage {}
				}
			}
			PageFade {
				name: "year"
				order: 7

				Loader {
					anchors.fill: parent
					active: root.page === "year"
					sourceComponent: ReviewPage {}
				}
			}
		}

		// ── the bar ─────────────────────────────────────────────────────
		Item {
			id: bar

			anchors.left: parent.left
			anchors.right: parent.right
			height: 64
			opacity: 1 - root.bloom
			visible: opacity > 0.01 && !root.covered

			Rectangle {
				anchors.fill: parent
				color: Theme.base
				opacity: root.barClear ? 0 : 0.92

				Behavior on opacity {
					Anim {
						duration: Motion.long
					}
				}
			}

			Row {
				anchors.left: parent.left
				anchors.leftMargin: 44
				anchors.verticalCenter: parent.verticalCenter
				spacing: 30

				Text {
					anchors.verticalCenter: parent.verticalCenter
					text: "STREAMS"
					color: root.barClear ? "white" : Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: 20
					font.weight: Font.Black
					font.letterSpacing: 2.4

					Behavior on color {
						ColorAnim {}
					}
				}

				Item {
					id: nav

					width: navRow.width
					height: 40
					anchors.verticalCenter: parent.verticalCenter

					Row {
						id: navRow

						spacing: 22
						height: parent.height

						Repeater {
							id: navItems

							model: root.pages

							Item {
								id: navItem

								required property var modelData
								readonly property bool current: root.page === navItem.modelData.id

								width: navWord.implicitWidth + (navDot.visible ? 12 : 0)
								height: parent.height

								Text {
									id: navWord

									anchors.left: parent.left
									anchors.verticalCenter: parent.verticalCenter
									text: navItem.modelData.label
									color: root.barClear ? Qt.rgba(1, 1, 1, navItem.current || navArea.containsMouse ? 1 : 0.72) : (navItem.current || navArea.containsMouse ? Theme.text : Theme.textMuted)
									font.family: Theme.fontFamily
									font.pixelSize: Theme.size.title
									font.weight: navItem.current ? Font.Bold : Font.Medium
								}
								Rectangle {
									id: navDot

									anchors.left: navWord.right
									anchors.leftMargin: 5
									anchors.verticalCenter: parent.verticalCenter
									visible: navItem.modelData.badge > 0
									width: 7
									height: 7
									radius: 4
									color: navItem.modelData.live ? "#e5484d" : Theme.primary
								}
								MouseArea {
									id: navArea

									anchors.fill: parent
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onClicked: root.go(navItem.modelData.id)
								}
							}
						}
					}

					// slides under the page that is open
					Rectangle {
						readonly property Item target: navItems.count > 0 && root.pageIndex >= 0 ? navItems.itemAt(root.pageIndex) : null

						y: parent.height - 5
						height: 3
						radius: 2
						color: root.barClear ? "white" : Theme.text
						x: target?.x ?? 0
						width: target?.width ?? 0

						Behavior on x {
							SpatialAnim {
								duration: Motion.long
							}
						}
						Behavior on width {
							SpatialAnim {
								duration: Motion.long
							}
						}
					}
				}
			}

			Row {
				anchors.right: parent.right
				anchors.rightMargin: 28
				anchors.verticalCenter: parent.verticalCenter
				spacing: 8

				Spinner {
					anchors.verticalCenter: parent.verticalCenter
					width: 16
					height: 16
					visible: !Streams.connected
				}
				BigButton {
					implicitHeight: 38
					text: "Tonight"
					icon: "weather_night"
					main: false
					onClicked: root.showTonight()
				}
				BigButton {
					implicitHeight: 38
					text: "New series"
					icon: "plus"
					onClicked: root.showWorkshop(null)
				}
				BigButton {
					implicitHeight: 38
					implicitWidth: 38
					visible: Plugins.on("streams-bar")
					icon: root.windowed ? "arrow_up_bold" : "open_in_new"
					main: false
					onClicked: root.windowed ? Streams.dock() : Streams.popOut()
				}
			}
		}

		// what plays, in a corner
		NowPlayingStrip {
			anchors.left: parent.left
			anchors.bottom: parent.bottom
			anchors.margins: 20
			width: 330
			z: 5
			visible: root.openId === "" && !root.covered && !Streams.player
		}

		// ── a series grows out of its picture ───────────────────────────
		Loader {
			id: detail

			anchors.fill: parent
			active: root.openId !== ""
			opacity: Math.max(0, Math.min(1, (root.bloom - 0.55) / 0.35))
			visible: opacity > 0
			sourceComponent: SeriesDetail {
				seriesId: root.openId
				onCloseRequested: root.closeSeries()
				onEditRule: item => root.showWorkshop(item)
			}
		}

		// the flying picture, from the card to the top of the series
		Thumb {
			id: flyer

			readonly property real toHeight: Math.max(400, Math.min(stage.height * 0.62, 620))

			visible: root.openId !== "" && root.bloom < 0.92
			x: root.origin.x * (1 - root.bloom)
			y: root.origin.y * (1 - root.bloom)
			width: root.origin.width + (stage.width - root.origin.width) * root.bloom
			height: root.origin.height + (flyer.toHeight - root.origin.height) * root.bloom
			radius: Theme.radius.large * (1 - root.bloom)
			source: root.openItem?.picture ?? ""
			colors: root.openItem?.colors ?? null
			spoiler: root.openItem?.spoiler ?? false
			opacity: root.bloom > 0.7 ? (0.92 - root.bloom) / 0.22 : 1
		}

		NumberAnimation {
			id: bloomIn

			target: root
			property: "bloom"
			to: 1
			duration: Motion.extraLong + 120
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}

		SequentialAnimation {
			id: bloomOut

			NumberAnimation {
				target: root
				property: "bloom"
				to: 0
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.emphasized
			}
			ScriptAction {
				script: root.openId = ""
			}
		}

		// ── sheets that slide up ─────────────────────────────────────────
		component Sheet: Item {
			id: sheet

			property bool shown: false
			property alias body: sheetLoader.item
			property alias sourceComponent: sheetLoader.sourceComponent
			property real reveal: sheet.shown ? 1 : 0

			anchors.fill: parent
			visible: sheet.reveal > 0.001
			opacity: Math.min(1, sheet.reveal * 1.6)
			scale: 0.97 + 0.03 * sheet.reveal
			transform: Translate {
				y: (1 - sheet.reveal) * 70
			}

			onShownChanged: if (!sheet.shown) keys.forceActiveFocus()

			Behavior on reveal {
				NumberAnimation {
					duration: sheet.shown ? Motion.extraLong : Motion.medium
					easing.type: Easing.BezierSpline
					easing.bezierCurve: sheet.shown ? Motion.decel : Motion.accel
				}
			}

			MouseArea {
				anchors.fill: parent
				hoverEnabled: true
			}

			Loader {
				id: sheetLoader

				anchors.fill: parent
			}
		}

		Sheet {
			id: tonight

			sourceComponent: TonightSheet {
				onClose: tonight.shown = false
			}
		}

		Sheet {
			id: partsSheet

			sourceComponent: PartsSheet {
				onClose: partsSheet.shown = false
				onOpenSeries: id => {
					partsSheet.shown = false;
					root.page = "series";
					root.openSeries(id, null);
				}
			}
		}

		Sheet {
			id: workshop

			sourceComponent: Workshop {
				onClose: workshop.shown = false
				onCreated: id => {
					workshop.shown = false;
					root.page = "series";
					root.openSeries(id, null);
				}
			}
		}

		// the player, over everything in here or small in a corner
		Item {
			id: playerHost

			readonly property bool mini: Streams.playerMini
			readonly property real miniWidth: 500

			z: 20
			visible: !!Streams.player && Streams.playerInside
			x: playerHost.mini ? stage.width - playerHost.miniWidth - 24 : 0
			y: playerHost.mini ? stage.height - playerHost.miniWidth * 9 / 16 - 24 : 0
			width: playerHost.mini ? playerHost.miniWidth : stage.width
			height: playerHost.mini ? playerHost.miniWidth * 9 / 16 : stage.height

			Behavior on x {
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
			Behavior on y {
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
			Behavior on width {
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
			Behavior on height {
				SpatialAnim {
					duration: Motion.extraLong
				}
			}

			onMiniChanged: {
				if (mini) keys.forceActiveFocus();
				else if (playerLoader.item) playerLoader.item.takeFocus();
			}

			Loader {
				id: playerLoader

				anchors.fill: parent
				active: !!Streams.player && Streams.playerInside
				sourceComponent: PlayerView {
					canMini: true
				}
				onLoaded: item.takeFocus()
				onActiveChanged: if (!active) keys.forceActiveFocus()
			}
		}
	}
}
