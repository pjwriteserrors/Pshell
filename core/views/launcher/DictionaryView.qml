pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >d: a word explained and shown. The word, how it is said and
// split, a sentence about the thing, its meanings, an example, words like
// it (a click looks them up); beside it the pictures of it, one large that
// slowly drifts and changes by itself, the others below. `>d en word` asks
// the English dictionary. Enter copies the meanings, ↑/↓ change the
// picture, Ctrl+P says the word, Ctrl+O opens Wiktionary.
Item {
	id: root

	property string argument: ""
	property bool active: false
	signal closeRequested
	// replaces the text after ">d "
	signal argumentRequested(string text)

	// `en word` → { lang: "en", text: "word" }
	readonly property var parsed: {
		const value = String(root.argument || "").trim();
		const match = /^(de|en)\s+([\s\S]+)$/i.exec(value);
		return match ? { lang: match[1].toLowerCase(), text: match[2].trim() } : { lang: "auto", text: value };
	}
	readonly property var entry: root.shown
	readonly property bool german: root.entry?.lang === "de"
	readonly property var senses: (root.entry?.senses ?? []).slice(0, root.expanded ? 8 : 4)
	readonly property int hiddenSenses: Math.max(0, (root.entry?.senses ?? []).length - root.senses.length)
	readonly property bool hasPictures: Dictionary.images.length > 0 || Dictionary.picturesComing
	property bool expanded: false
	property bool copyWhenReady: false
	property int heroIndex: 0
	// the entry on screen: swapped by the transition, not the instant it arrives
	property var shown: null
	// counts the entries shown, so their parts come in again
	property int generation: 0

	onParsedChanged: if (root.active) Dictionary.request(root.parsed.text, root.parsed.lang)
	onActiveChanged: {
		root.copyWhenReady = false;
		if (root.active) Dictionary.request(root.parsed.text, root.parsed.lang);
	}
	Component.onCompleted: if (Dictionary.entry && Dictionary.state === "found") root.shown = Dictionary.entry

	function move(delta) {
		const count = Dictionary.images.length;
		if (count > 0) root.showPicture((root.heroIndex + delta + count) % count);
	}

	function handleKey(event) {
		if (!(event.modifiers & Qt.ControlModifier)) return false;
		if (event.key === Qt.Key_P) Dictionary.speak();
		else if (event.key === Qt.Key_O) root.openSource();
		else return false;
		return true;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		if (root.parsed.text === "") return;
		if (Dictionary.loading) {
			root.copyWhenReady = true;
			Dictionary.flush();
			return;
		}
		root.copy();
	}

	function copy() {
		root.copyWhenReady = false;
		const text = Dictionary.plainText();
		if (text === "") return;
		Quickshell.execDetached(["wl-copy", "--", text]);
		Haptics.play("copied");
		root.closeRequested();
	}

	function lookUp(word) {
		root.argumentRequested(root.parsed.lang === "auto" ? word : `${root.parsed.lang} ${word}`);
	}

	function pickLang(code) {
		root.argumentRequested(code === "auto" ? root.parsed.text : `${code} ${root.parsed.text}`);
	}

	function openSource() {
		const url = String(root.entry?.url || "");
		if (url === "") return;
		Quickshell.execDetached(["xdg-open", url]);
		root.closeRequested();
	}

	function showPicture(index) {
		if (index === root.heroIndex) return;
		root.heroIndex = index;
		slideshow.restart();
	}

	function openPicture(index) {
		const paths = Dictionary.images.map(image => image.path);
		if (!paths[index]) return;
		root.closeRequested();
		later.path = paths[index];
		later.list = paths;
		later.restart();
	}

	Timer {
		id: later

		property string path: ""
		property var list: []
		interval: Motion.medium
		onTriggered: Viewer.open(later.path, { list: later.list })
	}

	Connections {
		target: Dictionary

		function onEntryChanged() {
			if (Dictionary.entry === root.shown) return;
			if (Dictionary.entry === null) {
				root.shown = null;
				return;
			}
			swap.restart();
		}

		function onStateChanged() {
			if (Dictionary.state === "found" && root.copyWhenReady) root.copy();
			if (Dictionary.state === "none" || Dictionary.state === "idle") root.copyWhenReady = false;
		}

		function onImagesChanged() {
			if (Dictionary.images.length === 0) root.heroIndex = 0;
		}
	}

	// the old word steps back, the new one comes in part by part
	SequentialAnimation {
		id: swap

		Anim {
			target: page
			property: "opacity"
			to: 0
			duration: root.shown ? Motion.micro : 0
		}
		ScriptAction {
			script: {
				root.shown = Dictionary.entry;
				root.expanded = false;
				root.heroIndex = 0;
				senseFlick.contentY = 0;
				root.generation += 1;
				page.opacity = 1;
			}
		}
	}

	// ── a part that comes in after the ones above it ────────────────────
	component Reveal: Item {
		id: reveal

		property int order: 0
		property real rise: 10
		default property alias content: holder.data

		implicitWidth: holder.childrenRect.width
		implicitHeight: holder.childrenRect.height
		opacity: 0

		Item {
			id: holder

			width: reveal.width
			height: reveal.height
			transform: Translate {
				id: lift
			}
		}

		Connections {
			target: root

			function onGenerationChanged() {
				enter.restart();
			}
		}

		Component.onCompleted: enter.restart()

		SequentialAnimation {
			id: enter

			ScriptAction {
				script: {
					reveal.opacity = 0;
					lift.y = reveal.rise;
				}
			}
			PauseAnimation {
				duration: 40 + reveal.order * 55
			}
			ParallelAnimation {
				Anim {
					target: reveal
					property: "opacity"
					to: 1
					duration: Motion.long
				}
				SpatialAnim {
					target: lift
					property: "y"
					to: 0
					duration: Motion.extraLong
				}
			}
		}
	}

	// a soft light running over placeholders
	component Shimmer: Rectangle {
		id: shimmer

		radius: Theme.radius.small
		color: Theme.layer2
		clip: true

		Rectangle {
			id: sweep

			width: shimmer.width * 0.6
			height: shimmer.height
			x: -width
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop { position: 0; color: "transparent" }
				GradientStop { position: 0.5; color: Qt.alpha(Theme.text, 0.07) }
				GradientStop { position: 1; color: "transparent" }
			}

			NumberAnimation on x {
				from: -sweep.width
				to: shimmer.width
				duration: 1300
				loops: Animation.Infinite
				running: shimmer.visible
				easing.type: Easing.InOutQuad
			}
		}
	}

	// ── nothing typed yet ───────────────────────────────────────────────
	Item {
		id: welcome

		anchors.fill: parent
		opacity: root.parsed.text === "" ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {}
		}

		ColumnLayout {
			anchors.centerIn: parent
			width: Math.min(parent.width - 40, 440)
			spacing: 14

			Item {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 92
				Layout.preferredHeight: 92

				Rectangle {
					id: halo

					anchors.centerIn: parent
					width: 92
					height: 92
					radius: 46
					color: Theme.primarySoft

					SequentialAnimation on scale {
						running: welcome.visible
						loops: Animation.Infinite
						NumberAnimation { to: 1.08; duration: 1800; easing.type: Easing.InOutSine }
						NumberAnimation { to: 1.0; duration: 1800; easing.type: Easing.InOutSine }
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: "book_open_page_variant"
					size: 40
					color: Theme.primary

					SequentialAnimation on rotation {
						running: welcome.visible
						loops: Animation.Infinite
						NumberAnimation { to: -5; duration: 2400; easing.type: Easing.InOutSine }
						NumberAnimation { to: 5; duration: 2400; easing.type: Easing.InOutSine }
					}
				}
			}

			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: "Look up a word"
				font.pixelSize: Theme.size.heading
				font.weight: Font.DemiBold
			}

			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: "What it means, how it sounds, what it looks like"
				tone: Theme.textMuted
			}

			Flow {
				Layout.fillWidth: true
				Layout.topMargin: 10
				visible: Dictionary.recent.length > 0
				spacing: 6

				Repeater {
					model: Dictionary.recent

					delegate: Chip {
						id: recentChip

						required property string modelData
						required property int index

						text: modelData
						icon: "history"
						opacity: 0
						onClicked: root.argumentRequested(recentChip.modelData)

						SequentialAnimation on opacity {
							running: welcome.visible
							PauseAnimation { duration: 120 + recentChip.index * 45 }
							Anim { to: 1; duration: Motion.long }
						}
					}
				}
			}
		}
	}

	// ── looking, the first time ─────────────────────────────────────────
	RowLayout {
		id: skeleton

		anchors.fill: parent
		spacing: 18
		opacity: root.parsed.text !== "" && root.shown === null && Dictionary.loading ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {}
		}

		ColumnLayout {
			Layout.fillWidth: true
			Layout.alignment: Qt.AlignTop
			Layout.topMargin: 8
			spacing: 12

			Shimmer { Layout.preferredWidth: 220; Layout.preferredHeight: 38; radius: Theme.radius.medium }
			Shimmer { Layout.preferredWidth: 160; Layout.preferredHeight: 14 }
			Item { Layout.preferredHeight: 6 }
			Shimmer { Layout.fillWidth: true; Layout.preferredHeight: 12 }
			Shimmer { Layout.fillWidth: true; Layout.rightMargin: 40; Layout.preferredHeight: 12 }
			Shimmer { Layout.fillWidth: true; Layout.rightMargin: 110; Layout.preferredHeight: 12 }
			Item { Layout.preferredHeight: 8 }
			Repeater {
				model: 3

				delegate: RowLayout {
					required property int index

					Layout.fillWidth: true
					spacing: 10

					Shimmer { Layout.preferredWidth: 22; Layout.preferredHeight: 22; radius: 11 }
					Shimmer { Layout.fillWidth: true; Layout.rightMargin: 30 + parent.index * 50; Layout.preferredHeight: 12 }
				}
			}
		}

		Shimmer {
			Layout.preferredWidth: Math.round(root.width * 0.4)
			Layout.fillHeight: true
			radius: Theme.radius.huge
		}
	}

	// ── nothing found, or no answer ─────────────────────────────────────
	EmptyState {
		anchors.centerIn: parent
		opacity: root.parsed.text !== "" && !Dictionary.loading && (Dictionary.state === "none" || Dictionary.state === "error") ? 1 : 0
		visible: opacity > 0.01
		icon: Dictionary.state === "error" ? "wifi_off" : "book_open_variant"
		title: Dictionary.state === "error" ? "No answer" : `No entry for „${root.parsed.text}“`
		subtitle: Dictionary.state === "error" ? Dictionary.error : "Check the spelling, or try >t to translate it"

		Behavior on opacity {
			Anim {}
		}
	}

	// ── the word ────────────────────────────────────────────────────────
	Item {
		id: page

		anchors.fill: parent
		visible: root.shown !== null && root.parsed.text !== ""
		// a word being typed over the shown one: it waits a little dimmer
		readonly property bool stale: Dictionary.loading && root.shown !== null

		RowLayout {
			anchors.fill: parent
			spacing: root.hasPictures ? 18 : 0
			opacity: page.stale ? 0.55 : 1

			Behavior on opacity {
				Anim {}
			}

			// what it means
			Flickable {
				id: senseFlick

				Layout.fillWidth: true
				Layout.fillHeight: true
				contentHeight: textColumn.implicitHeight + 8
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				ColumnLayout {
					id: textColumn

					width: senseFlick.width - 10
					spacing: 0

					Reveal {
						order: 0
						rise: 14
						Layout.fillWidth: true
						Layout.preferredHeight: wordRow.implicitHeight

						RowLayout {
							id: wordRow

							width: parent.width
							spacing: 10

							StyledText {
								Layout.fillWidth: true
								text: root.entry?.word ?? ""
								font.pixelSize: text.length > 16 ? 28 : 36
								font.weight: Font.Bold
								font.letterSpacing: -0.6
								fontSizeMode: Text.HorizontalFit
								minimumPixelSize: 20
							}

							Row {
								Layout.alignment: Qt.AlignVCenter
								spacing: 4
								visible: (root.entry?.langs ?? []).length > 1 || root.parsed.lang !== "auto"

								Repeater {
									model: ["de", "en"]

									delegate: Chip {
										required property string modelData

										implicitHeight: 24
										text: modelData.toUpperCase()
										selected: root.entry?.lang === modelData
										onClicked: root.pickLang(modelData)
									}
								}
							}

							IconButton {
								Layout.alignment: Qt.AlignVCenter
								width: 30
								height: 30
								icon: "content_copy"
								iconSize: 15
								onClicked: root.copy()
							}

							IconButton {
								Layout.alignment: Qt.AlignVCenter
								width: 30
								height: 30
								icon: "open_in_new"
								iconSize: 15
								onClicked: root.openSource()
							}
						}
					}

					// how it is said and split, what kind of word it is
					Reveal {
						order: 1
						Layout.fillWidth: true
						Layout.topMargin: 4
						Layout.preferredHeight: soundRow.implicitHeight

						RowLayout {
							id: soundRow

							width: parent.width
							spacing: 8

							Clickable {
								id: speakButton

								visible: (root.entry?.audio ?? "") !== ""
								implicitWidth: 28
								implicitHeight: 28
								radius: 14
								color: Dictionary.speaking ? Theme.primary : Theme.primarySoft
								sound: ""
								onClicked: Dictionary.speak()

								// rings going out while it speaks
								Repeater {
									model: 2

									delegate: Rectangle {
										id: ring

										required property int index

										anchors.centerIn: parent
										width: parent.width
										height: width
										radius: width / 2
										color: "transparent"
										border.width: 1.5
										border.color: Theme.primary
										opacity: 0

										ParallelAnimation {
											running: Dictionary.speaking
											loops: Animation.Infinite
											onRunningChanged: if (!running) ring.opacity = 0

											SequentialAnimation {
												PauseAnimation { duration: ring.index * 450 }
												NumberAnimation { target: ring; property: "scale"; from: 1; to: 1.9; duration: 900; easing.type: Easing.OutCubic }
											}
											SequentialAnimation {
												PauseAnimation { duration: ring.index * 450 }
												NumberAnimation { target: ring; property: "opacity"; from: 0.7; to: 0; duration: 900; easing.type: Easing.OutCubic }
											}
										}
									}
								}

								Glyph {
									anchors.centerIn: parent
									icon: "volume_high"
									size: 15
									color: Dictionary.speaking ? Theme.onPrimary : Theme.primary
								}
							}

							StyledText {
								visible: text !== ""
								text: root.entry?.ipa ?? ""
								tone: Theme.textMuted
								font.pixelSize: Theme.size.title
								font.family: Theme.monoFamily
							}

							StyledText {
								readonly property string syllables: root.entry?.syllables ?? ""

								visible: syllables.includes("·")
								text: "·  " + syllables
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.title
							}

							Item {
								Layout.fillWidth: true
							}

							Rectangle {
								visible: kind.text !== ""
								implicitWidth: kind.implicitWidth + 18
								implicitHeight: 22
								radius: 11
								color: Theme.layer2

								StyledText {
									id: kind

									anchors.centerIn: parent
									text: [root.entry?.pos ?? "", root.entry?.gender ?? ""].filter(part => part !== "").join(" · ")
									tone: Theme.textMuted
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
								}
							}
						}
					}

					// what it is, in a sentence or two
					Reveal {
						order: 2
						visible: summary.text !== ""
						Layout.fillWidth: true
						Layout.topMargin: 14
						Layout.preferredHeight: summary.implicitHeight

						StyledText {
							id: summary

							width: parent.width
							text: root.entry?.summary ?? ""
							wrapMode: Text.Wrap
							maximumLineCount: 3
							lineHeight: 1.18
							tone: Theme.textMuted
							font.pixelSize: Theme.size.body + 1
						}
					}

					Reveal {
						order: 3
						Layout.fillWidth: true
						Layout.topMargin: 18
						Layout.preferredHeight: meaningsLabel.implicitHeight

						SectionLabel {
							id: meaningsLabel

							text: root.german ? "Bedeutungen" : "Meanings"
						}
					}

					Repeater {
						model: root.senses

						delegate: Reveal {
							id: senseItem

							required property var modelData
							required property int index

							order: 4 + index
							Layout.fillWidth: true
							Layout.topMargin: index === 0 ? 8 : 10
							Layout.preferredHeight: senseRow.implicitHeight

							RowLayout {
								id: senseRow

								width: parent.width
								spacing: 10

								Rectangle {
									Layout.alignment: Qt.AlignTop
									Layout.leftMargin: senseItem.modelData.sub ? 30 : 0
									Layout.topMargin: 1
									implicitWidth: Math.max(22, number.implicitWidth + 10)
									implicitHeight: 22
									radius: 11
									color: senseItem.modelData.sub ? "transparent" : Theme.primarySoft
									border.width: senseItem.modelData.sub ? 1 : 0
									border.color: Theme.primarySoft

									StyledText {
										id: number

										anchors.centerIn: parent
										text: senseItem.modelData.n || String(senseItem.index + 1)
										tone: Theme.primary
										font.pixelSize: Theme.size.small
										font.weight: Font.Bold
									}
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 2

									StyledText {
										Layout.fillWidth: true
										visible: (senseItem.modelData.tags ?? []).length > 0
										text: (senseItem.modelData.tags ?? []).join(" · ")
										tone: Theme.primary
										font.pixelSize: Theme.size.tiny
										font.weight: Font.Bold
										font.letterSpacing: 0.6
										font.capitalization: Font.AllUppercase
									}

									StyledText {
										Layout.fillWidth: true
										text: senseItem.modelData.text
										wrapMode: Text.Wrap
										maximumLineCount: 4
										lineHeight: 1.15
										font.pixelSize: Theme.size.body + 1
									}
								}
							}
						}
					}

					Reveal {
						order: 4 + root.senses.length
						visible: root.hiddenSenses > 0 || root.expanded
						Layout.topMargin: 8
						Layout.preferredWidth: moreButton.implicitWidth
						Layout.preferredHeight: moreButton.implicitHeight

						Chip {
							id: moreButton

							implicitHeight: 26
							icon: root.expanded ? "chevron_up" : "chevron_down"
							text: root.expanded ? (root.german ? "Weniger" : "Fewer") : `+${root.hiddenSenses} ${root.german ? "weitere" : "more"}`
							onClicked: root.expanded = !root.expanded
						}
					}

					// a sentence that uses it
					Reveal {
						order: 5 + root.senses.length
						visible: example.text !== ""
						Layout.fillWidth: true
						Layout.topMargin: 18
						Layout.preferredHeight: exampleBox.implicitHeight

						Rectangle {
							id: exampleBox

							width: parent.width
							implicitHeight: example.implicitHeight + 20
							radius: Theme.radius.medium
							color: Theme.layer1

							Rectangle {
								anchors.left: parent.left
								anchors.top: parent.top
								anchors.bottom: parent.bottom
								anchors.margins: 9
								width: 3
								radius: 2
								color: Theme.primary
							}

							StyledText {
								id: example

								anchors.left: parent.left
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								anchors.leftMargin: 22
								anchors.rightMargin: 14
								text: (root.entry?.example ?? "") === "" ? "" : `„${root.entry.example}“`
								wrapMode: Text.Wrap
								maximumLineCount: 3
								font.italic: true
								tone: Theme.textMuted
							}
						}
					}

					// words like it
					Reveal {
						order: 6 + root.senses.length
						visible: (root.entry?.synonyms ?? []).length > 0
						Layout.fillWidth: true
						Layout.topMargin: 18
						Layout.preferredHeight: synonymColumn.implicitHeight

						ColumnLayout {
							id: synonymColumn

							width: parent.width
							spacing: 8

							SectionLabel {
								text: root.german ? "Ähnliche Wörter" : "Similar words"
							}

							Flow {
								Layout.fillWidth: true
								spacing: 6

								Repeater {
									model: (root.entry?.synonyms ?? []).slice(0, 6)

									delegate: Chip {
										required property string modelData

										implicitHeight: 26
										text: modelData
										onClicked: root.lookUp(modelData)
									}
								}
							}
						}
					}

					// where it comes from
					Reveal {
						order: 7 + root.senses.length
						visible: origin.text !== ""
						Layout.fillWidth: true
						Layout.topMargin: 18
						Layout.preferredHeight: origin.implicitHeight

						StyledText {
							id: origin

							width: parent.width
							text: (root.entry?.origin ?? "") === "" ? "" : `${root.german ? "Herkunft" : "Origin"}: ${root.entry.origin}`
							wrapMode: Text.Wrap
							maximumLineCount: 2
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}
				}
			}

			// what it looks like
			Item {
				id: gallery

				Layout.fillHeight: true
				Layout.preferredWidth: root.hasPictures ? Math.round(root.width * 0.42) : 0
				clip: true

				Behavior on Layout.preferredWidth {
					SpatialAnim {
						duration: Motion.extraLong
					}
				}

				readonly property var images: Dictionary.images
				readonly property var hero: gallery.images[Math.min(root.heroIndex, gallery.images.length - 1)] ?? null
				readonly property int thumbCount: Math.min(5, gallery.images.length)

				Item {
					id: galleryBody

					width: Math.round(root.width * 0.42)
					height: parent.height
					anchors.right: parent.right

					// the large picture: two layers so one fades into the next
					ClippingRectangle {
						id: heroFrame

						anchors.left: parent.left
						anchors.right: parent.right
						anchors.top: parent.top
						anchors.bottom: thumbs.visible ? thumbs.top : parent.bottom
						anchors.bottomMargin: thumbs.visible ? 10 : 0
						radius: Theme.radius.huge
						color: Theme.layer1

						property bool showingA: true
						property string current: gallery.hero?.path ?? ""

						onCurrentChanged: {
							if (heroFrame.current === "") {
								heroA.source = "";
								heroB.source = "";
								return;
							}
							const next = "file://" + heroFrame.current;
							if (heroFrame.showingA) heroB.source = next;
							else heroA.source = next;
							heroFrame.showingA = !heroFrame.showingA;
						}

						Shimmer {
							anchors.fill: parent
							radius: heroFrame.radius
							visible: (heroFrame.showingA ? heroA : heroB).status !== Image.Ready
						}

						Image {
							id: heroA

							readonly property bool front: heroFrame.showingA
							readonly property bool shown: heroA.front && heroA.status === Image.Ready
							// settles in from a little closer, then drifts with the rest
							property real settle: heroA.shown ? 1 : 1.1

							anchors.fill: parent
							asynchronous: true
							fillMode: Image.PreserveAspectCrop
							sourceSize.width: 900
							smooth: true
							mipmap: true
							opacity: heroA.shown ? 1 : 0
							scale: heroA.settle * (heroA.front ? drift.zoom : 1)

							Behavior on opacity {
								Anim {
									duration: Motion.extraLong
								}
							}
							Behavior on settle {
								SpatialAnim {
									duration: 1400
								}
							}
						}

						Image {
							id: heroB

							readonly property bool front: !heroFrame.showingA
							readonly property bool shown: heroB.front && heroB.status === Image.Ready
							// settles in from a little closer, then drifts with the rest
							property real settle: heroB.shown ? 1 : 1.1

							anchors.fill: parent
							asynchronous: true
							fillMode: Image.PreserveAspectCrop
							sourceSize.width: 900
							smooth: true
							mipmap: true
							opacity: heroB.shown ? 1 : 0
							scale: heroB.settle * (heroB.front ? drift.zoom : 1)

							Behavior on opacity {
								Anim {
									duration: Motion.extraLong
								}
							}
							Behavior on settle {
								SpatialAnim {
									duration: 1400
								}
							}
						}

						// a slow drift, as a camera over a photograph
						QtObject {
							id: drift

							property real zoom: 1.0
						}

						SequentialAnimation {
							id: driftAnim

							running: root.active && page.visible && gallery.images.length > 0
							loops: Animation.Infinite

							NumberAnimation { target: drift; property: "zoom"; from: 1.0; to: 1.07; duration: 9000; easing.type: Easing.InOutSine }
							NumberAnimation { target: drift; property: "zoom"; from: 1.07; to: 1.0; duration: 9000; easing.type: Easing.InOutSine }
						}

						// what the picture shows and whose it is
						Rectangle {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							height: captionColumn.implicitHeight + 46
							visible: gallery.hero !== null
							gradient: Gradient {
								GradientStop { position: 0; color: "transparent" }
								GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.62) }
							}

							ColumnLayout {
								id: captionColumn

								anchors.left: parent.left
								anchors.right: parent.right
								anchors.bottom: parent.bottom
								anchors.margins: 14
								spacing: 1

								StyledText {
									Layout.fillWidth: true
									visible: text !== ""
									text: gallery.hero?.caption ?? ""
									surface: "transparent"
									tone: "white"
									wrapMode: Text.Wrap
									maximumLineCount: 2
									font.pixelSize: Theme.size.label
									font.weight: Font.DemiBold
								}

								StyledText {
									Layout.fillWidth: true
									text: gallery.hero?.credit ?? ""
									surface: "transparent"
									tone: Qt.rgba(1, 1, 1, 0.66)
									font.pixelSize: Theme.size.tiny
								}
							}
						}

						// which picture of how many, as dots
						Rectangle {
							anchors.top: parent.top
							anchors.right: parent.right
							anchors.margins: 12
							width: dots.implicitWidth + 14
							height: 16
							radius: 8
							color: Qt.rgba(0, 0, 0, 0.32)
							visible: gallery.images.length > 1
						}

						Row {
							id: dots

							anchors.top: parent.top
							anchors.right: parent.right
							anchors.topMargin: 17
							anchors.rightMargin: 19
							spacing: 4
							visible: gallery.images.length > 1

							Repeater {
								model: gallery.images.length

								delegate: Rectangle {
									required property int index

									width: index === root.heroIndex ? 16 : 6
									height: 6
									radius: 3
									color: index === root.heroIndex ? "white" : Qt.rgba(1, 1, 1, 0.5)

									Behavior on width {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}
							}
						}

						HoverHandler {
							id: heroHover
						}

						MouseArea {
							anchors.fill: parent
							cursorShape: Qt.PointingHandCursor
							onClicked: root.openPicture(root.heroIndex)
						}
					}

					// the others, small
					Row {
						id: thumbs

						anchors.left: parent.left
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						height: 62
						spacing: 8
						visible: gallery.images.length > 1 || Dictionary.picturesComing

						Repeater {
							model: Math.max(gallery.thumbCount, Dictionary.picturesComing ? 4 : 0)

							delegate: Item {
								id: thumb

								required property int index
								readonly property var image: gallery.images[thumb.index] ?? null
								readonly property bool selected: thumb.index === root.heroIndex

								width: (thumbs.width - thumbs.spacing * (Math.max(4, gallery.thumbCount) - 1)) / Math.max(4, gallery.thumbCount)
								height: thumbs.height

								Shimmer {
									anchors.fill: parent
									radius: Theme.radius.medium
									visible: thumbImage.status !== Image.Ready
								}

								ClippingRectangle {
									id: thumbFrame

									anchors.fill: parent
									radius: Theme.radius.medium
									color: "transparent"
									opacity: thumbImage.status === Image.Ready ? (thumb.selected || thumbArea.containsMouse ? 1 : 0.62) : 0
									scale: thumbImage.status === Image.Ready ? (thumbArea.pressed ? 0.94 : 1) : 0.82

									Behavior on opacity {
										Anim {}
									}
									Behavior on scale {
										SpatialAnim {}
									}

									Image {
										id: thumbImage

										anchors.fill: parent
										source: thumb.image ? "file://" + thumb.image.path : ""
										asynchronous: true
										fillMode: Image.PreserveAspectCrop
										sourceSize.width: 220
										smooth: true
									}
								}

								Rectangle {
									anchors.fill: parent
									radius: Theme.radius.medium
									color: "transparent"
									border.width: 2
									border.color: Theme.primary
									opacity: thumb.selected && thumbImage.status === Image.Ready ? 1 : 0

									Behavior on opacity {
										Anim {}
									}
								}

								MouseArea {
									id: thumbArea

									anchors.fill: parent
									enabled: thumb.image !== null
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onContainsMouseChanged: if (containsMouse && Pointer.moved(thumb, mouseX, mouseY)) root.showPicture(thumb.index)
									onClicked: root.openPicture(thumb.index)
								}
							}
						}
					}

					// the large picture changes by itself while the pointer is elsewhere
					Timer {
						id: slideshow

						interval: 6500
						repeat: true
						running: root.active && page.visible && gallery.images.length > 1 && !heroHover.hovered
						onTriggered: root.heroIndex = (root.heroIndex + 1) % gallery.images.length
					}
				}
			}
		}
	}
}
