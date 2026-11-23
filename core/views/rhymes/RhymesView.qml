pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The rhymes window: the songs on the left, the sheet in the middle, rhymes,
// words, takes and versions on the right, the beat along the bottom. The
// sides slide away when they are not wanted (Ctrl+B, Ctrl+J); the sheet
// stays where the eye is.
FocusScope {
	id: root

	property bool shown: false
	readonly property bool narrow: root.width < 900
	property bool sideOpen: Rhymes.setting("sidebar", true) && !root.narrow
	property bool sideOver: false
	readonly property string panel: Rhymes.setting("panel", "rhymes")
	onPanelChanged: {
		if (root.panel === "words") lookTimer.restart();
		if (root.panel === "versions") Rhymes.loadVersions();
	}
	readonly property bool panelFits: root.width >= 1000
	// too narrow for it beside the sheet: it comes over it when asked
	property bool panelOver: false
	readonly property bool panelOpen: root.panel !== "" && (root.panelFits || root.panelOver)
	property bool karaoke: false
	readonly property bool studioOpen: Rhymes.setting("view", "write") === "studio" && Rhymes.song !== null

	function setStudio(on) {
		Rhymes.setSetting("view", on ? "studio" : "write");
		// in the studio everything recorded plays along
		if (on) Rhymes.withTakes = true;
		Qt.callLater(() => on ? studioLoader.forceActiveFocus() : sheet.takeFocus());
	}
	readonly property bool active: Window.active && root.shown
	onActiveChanged: Rhymes.focused = root.active

	function takeFocus() {
		if (root.karaoke) karaokeStage.forceActiveFocus();
		else sheet.takeFocus();
	}

	function showPanel(name) {
		if (!root.panelFits) {
			root.panelOver = !(root.panelOver && root.panel === name);
			Rhymes.setSetting("panel", name);
			return;
		}
		Rhymes.setSetting("panel", root.panel === name ? "" : name);
	}

	function toggleSide() {
		if (root.narrow) root.sideOver = !root.sideOver;
		else Rhymes.setSetting("sidebar", !Rhymes.setting("sidebar", true));
	}

	// a word from the panel goes in at the cursor, with a space before it when one is missing
	function insertWord(text) {
		root.panelOver = false;
		if (!Rhymes.song) return;
		const row = Math.max(0, Math.min(Rhymes.row, Rhymes.lines.count - 1));
		const line = Rhymes.lines.get(row)?.text ?? "";
		const col = Math.min(Rhymes.column, line.length);
		const before = line.slice(0, col);
		const after = line.slice(col);
		const lead = before !== "" && !/\s$/.test(before) ? " " : "";
		const tail = after !== "" && !/^[\s,.!?;:]/.test(after) ? " " : "";
		Rhymes.insertText(row, col, lead + text + tail);
	}

	// words of the same meaning for the word at the cursor, rhyming with the line above
	function lookUp(word) {
		const row = Rhymes.row;
		const line = Rhymes.lines.get(row)?.text ?? "";
		let target = word || sheet.selectionWord.trim();
		if (!target) {
			const before = line.slice(0, Rhymes.column).match(/[A-Za-z']+$/);
			const after = line.slice(Rhymes.column).match(/^[A-Za-z']*/);
			target = `${before ? before[0] : ""}${after ? after[0] : ""}`;
			if (!target) target = (line.slice(0, Rhymes.column).match(/[A-Za-z']+/g) || []).pop() || "";
		}
		let above = "";
		for (let i = row - 1; i >= 0; i -= 1) {
			const text = Rhymes.lines.get(i).text;
			if (/^\s*\[.*\]\s*$/.test(text)) break;
			if (text.trim() !== "") {
				above = (text.match(/[A-Za-z']+/g) || []).pop() || "";
				break;
			}
		}
		if (target) wordsPane.ask(target, above);
	}

	Timer {
		id: lookTimer

		interval: 300
		onTriggered: if (root.panel === "words" && root.panelOpen) root.lookUp()
	}

	Connections {
		target: Rhymes

		function onRowChanged() {
			lookTimer.restart();
		}

		function onColumnChanged() {
			lookTimer.restart();
		}

		function onSaid(text, icon) {
			toast.show(text, icon);
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Theme.base
	}

	// ── the bar along the top ──────────────────────────────────────────────
	Item {
		id: top

		width: parent.width
		height: 50

		Row {
			x: 10
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4

			IconButton {
				width: 34
				height: 34
				icon: "menu"
				checked: root.narrow ? root.sideOver : root.sideOpen
				onClicked: root.toggleSide()
			}

			// saved: a dot that breathes once
			Item {
				width: 18
				height: 34

				Rectangle {
					id: savedDot

					anchors.centerIn: parent
					width: 7
					height: 7
					radius: 4
					color: Rhymes.dirty ? Theme.textFaint : Theme.success
					opacity: Rhymes.song ? 1 : 0

					Behavior on color {
						ColorAnim {}
					}

					SequentialAnimation {
						id: savedPulse

						SpatialAnim {
							target: savedDot
							property: "scale"
							to: 1.8
							duration: Motion.short
						}

						SpatialAnim {
							target: savedDot
							property: "scale"
							to: 1
						}
					}

					Connections {
						target: Rhymes

						function onSavedAtChanged() {
							savedPulse.restart();
						}
					}
				}
			}
		}

		Row {
			anchors.right: parent.right
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4

			TextButton {
				anchors.verticalCenter: parent.verticalCenter
				visible: Rhymes.song !== null && !Rhymes.hasBeat
				icon: "music_note"
				text: "Beat"
				variant: "ghost"
				onClicked: Rhymes.pickBeat()
			}

			Segmented {
				anchors.verticalCenter: parent.verticalCenter
				visible: Rhymes.song !== null
				options: [{ value: "write", label: "Write", icon: "text_box_outline" }, { value: "studio", label: "Studio", icon: "tune_vertical" }]
				current: root.studioOpen ? "studio" : "write"
				onSelected: value => root.setStudio(value === "studio")
			}

			Item {
				width: 6
				height: 1
			}

			IconButton {
				id: optionsButton

				width: 34
				height: 34
				icon: "tune"
				visible: Rhymes.song !== null
				checked: options.opened
				onClicked: options.opened ? options.close() : options.open()
			}

			IconButton {
				width: 34
				height: 34
				icon: "microphone_variant"
				visible: Rhymes.song !== null
				checked: root.karaoke
				onClicked: root.karaoke = !root.karaoke
			}

			Item {
				width: 8
				height: 1
			}

			// the panels: one at a time, again closes it
			Rectangle {
				anchors.verticalCenter: parent.verticalCenter
				width: tabs.implicitWidth + 8
				height: 38
				radius: 19
				color: Theme.layer1

				Rectangle {
					readonly property Item on: tabs.children[["rhymes", "words", "takes", "versions"].indexOf(root.panel)] ?? null

					x: on ? on.x + 4 : 4
					y: 4
					width: 30
					height: 30
					radius: 15
					color: Theme.primary
					opacity: on && root.panelOpen ? 1 : 0

					Behavior on x {
						SpatialAnim {}
					}

					Behavior on opacity {
						Anim {}
					}
				}

				Row {
					id: tabs

					x: 4
					anchors.verticalCenter: parent.verticalCenter
					spacing: 2

					Repeater {
						model: [{ name: "rhymes", icon: "format_quote_open" }, { name: "words", icon: "book_open_variant" }, { name: "takes", icon: "microphone" }, { name: "versions", icon: "history" }]

						Clickable {
							required property var modelData

							width: 30
							height: 30
							radius: 15
							color: "transparent"
							tint: root.panel === modelData.name ? Theme.onPrimary : Theme.text
							onClicked: root.showPanel(modelData.name)

							Glyph {
								anchors.centerIn: parent
								icon: modelData.icon
								size: 16
								color: root.panel === modelData.name && root.panelOpen ? Theme.onPrimary : Theme.textMuted
							}
						}
					}
				}
			}
		}
	}

	// ── the three columns ──────────────────────────────────────────────────
	Item {
		id: body

		anchors.top: top.bottom
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: beat.top

		Item {
			id: side

			width: root.sideOpen ? 264 : 0
			height: parent.height
			clip: true

			Behavior on width {
				SpatialAnim {}
			}

			SongsPane {
				id: libraryView

				width: 264
				height: parent.height
				x: root.sideOpen ? 0 : -40
				opacity: root.sideOpen ? 1 : 0
				visible: !root.narrow
				onInsert: text => root.insertWord(text)

				Behavior on x {
					SpatialAnim {}
				}

				Behavior on opacity {
					Anim {}
				}
			}
		}

		Item {
			id: middle

			anchors.left: side.right
			anchors.right: root.panelFits ? panelBox.left : parent.right
			height: parent.height

			Sheet {
				id: sheet

				anchors.fill: parent
				visible: Rhymes.song !== null && opacity > 0
				opacity: root.studioOpen ? 0 : 1
				focus: !root.studioOpen
				enabled: !root.studioOpen

				Behavior on opacity {
					Anim {}
				}
			}

			Loader {
				id: studioLoader

				anchors.fill: parent
				active: root.studioOpen || item !== null
				visible: Rhymes.song !== null && opacity > 0
				opacity: root.studioOpen ? 1 : 0
				focus: root.studioOpen
				sourceComponent: StudioView {
					focus: true
				}

				Behavior on opacity {
					Anim {}
				}
			}

			// nothing open
			Column {
				anchors.centerIn: parent
				spacing: 18
				visible: Rhymes.song === null

				Glyph {
					anchors.horizontalCenter: parent.horizontalCenter
					icon: "music_note"
					size: 56
					color: Theme.textFaint
				}

				TextButton {
					anchors.horizontalCenter: parent.horizontalCenter
					icon: "plus"
					text: "New song"
					variant: "filled"
					onClicked: Rhymes.create("")
				}
			}
		}

		Item {
			id: panelBox

			anchors.right: parent.right
			width: root.panelOpen ? Math.min(360, Math.max(280, root.width * 0.3)) : 0
			height: parent.height
			clip: true
			z: 2

			Behavior on width {
				SpatialAnim {}
			}

			Rectangle {
				width: Math.min(360, Math.max(280, root.width * 0.3))
				height: parent.height
				color: Theme.layer1
				radius: Theme.radius.huge

				// the panes slide across when another is chosen
				PaneSlot {
					name: "rhymes"
					order: 0

					RhymesPane {
						anchors.fill: parent
						onPicked: text => {
							root.insertWord(text);
							sheet.takeFocus();
						}
						onLook: word => {
							Rhymes.setSetting("panel", "words");
							root.lookUp(word);
						}
					}
				}

				PaneSlot {
					name: "words"
					order: 1

					WordsPane {
						id: wordsPane

						anchors.fill: parent
						onPicked: text => {
							root.insertWord(text);
							sheet.takeFocus();
						}
					}
				}

				PaneSlot {
					name: "takes"
					order: 2

					Loader {
						anchors.fill: parent
						active: root.panel === "takes" || item !== null
						sourceComponent: TakesPane {}
					}
				}

				PaneSlot {
					name: "versions"
					order: 3

					Loader {
						anchors.fill: parent
						active: root.panel === "versions"
						sourceComponent: VersionsPane {}
					}
				}
			}
		}

		// narrow: the panel comes over the sheet
		Rectangle {
			anchors.fill: parent
			color: Theme.scrim
			z: 1
			opacity: !root.panelFits && root.panelOver ? 1 : 0
			visible: opacity > 0

			Behavior on opacity {
				Anim {}
			}

			MouseArea {
				anchors.fill: parent
				onClicked: root.panelOver = false
			}
		}

		// narrow: the songs come over the sheet
		Rectangle {
			anchors.fill: parent
			color: Theme.scrim
			opacity: root.narrow && root.sideOver ? 1 : 0
			visible: opacity > 0

			Behavior on opacity {
				Anim {}
			}

			MouseArea {
				anchors.fill: parent
				onClicked: root.sideOver = false
			}
		}

		Rectangle {
			width: 280
			height: parent.height
			x: root.narrow && root.sideOver ? 0 : -width - 20
			color: Theme.layer1
			radius: Theme.radius.huge
			visible: root.narrow

			Behavior on x {
				SpatialAnim {}
			}

			SongsPane {
				anchors.fill: parent
				onInsert: text => root.insertWord(text)
			}
		}
	}

	// ── the beat ───────────────────────────────────────────────────────────
	Item {
		id: beat

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: Rhymes.hasBeat ? 96 : 0
		clip: true

		Behavior on height {
			SpatialAnim {}
		}

		Rectangle {
			anchors.fill: parent
			anchors.margins: 6
			anchors.topMargin: 2
			radius: Theme.radius.huge
			color: Theme.layer1

			Loader {
				anchors.fill: parent
				active: Rhymes.hasBeat
				sourceComponent: BeatBar {}
			}
		}
	}

	// ── how it works ───────────────────────────────────────────────────────
	Popup {
		id: options

		parent: root
		x: root.width - width - 12
		y: top.height
		width: 300
		padding: 14
		closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

		enter: Transition {
			ParallelAnimation {
				Anim {
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.short
				}

				SpatialAnim {
					property: "scale"
					from: 0.92
					to: 1
				}
			}
		}

		exit: Transition {
			Anim {
				property: "opacity"
				to: 0
				duration: Motion.micro
			}
		}

		background: Rectangle {
			radius: Theme.radius.huge
			color: Theme.layer2
			border.width: 1
			border.color: Theme.outline
		}

		contentItem: Column {
			spacing: 2

			OptionSwitch {
				label: "Rhymes in colour"
				checked: Rhymes.setting("colours", true)
				onToggled: on => Rhymes.setSetting("colours", on)
			}

			OptionSwitch {
				label: "Stresses"
				checked: Rhymes.setting("stress", true)
				onToggled: on => Rhymes.setSetting("stress", on)
			}

			OptionSwitch {
				label: "Quiet while writing"
				checked: Rhymes.setting("quiet", true)
				onToggled: on => Rhymes.setSetting("quiet", on)
			}

			OptionSwitch {
				label: "Back up to the NAS"
				visible: Rhymes.nasAvailable
				checked: Rhymes.nasOn
				onToggled: on => Rhymes.setNas(on)
			}

			OptionStepper {
				label: "Rhymes across"
				value: Rhymes.setting("window", 4)
				suffix: " lines"
				from: 1
				to: 12
				onMoved: value => {
					Rhymes.setSetting("window", value);
					Rhymes.analyze();
				}
			}

			OptionStepper {
				label: "Recording delay"
				value: Rhymes.setting("latency", 30)
				suffix: " ms"
				from: 0
				to: 300
				step: 5
				onMoved: value => Rhymes.setSetting("latency", value)
			}
		}
	}

	component OptionSwitch: Item {
		id: option

		property string label: ""
		property bool checked: false

		signal toggled(bool on)

		width: 272
		height: visible ? 40 : 0

		StyledText {
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			text: option.label
		}

		Toggle {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			checked: option.checked
			onToggled: on => option.toggled(on)
		}
	}

	component OptionStepper: Item {
		id: stepper

		property string label: ""
		property int value: 0
		property string suffix: ""
		property int from: 0
		property int to: 100
		property int step: 1

		signal moved(int value)

		width: 272
		height: 40

		StyledText {
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			text: stepper.label
		}

		Row {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			IconButton {
				width: 28
				height: 28
				icon: "minus"
				onClicked: stepper.moved(Math.max(stepper.from, stepper.value - stepper.step))
			}

			RollText {
				anchors.verticalCenter: parent.verticalCenter
				text: `${stepper.value}${stepper.suffix}`
				minimumWidth: 58
				alignment: Qt.AlignHCenter
				pixelSize: Theme.size.body
				weight: Font.Medium
			}

			IconButton {
				width: 28
				height: 28
				icon: "plus"
				onClicked: stepper.moved(Math.min(stepper.to, stepper.value + stepper.step))
			}
		}
	}

	// ── rapping along ──────────────────────────────────────────────────────
	Karaoke {
		id: karaokeStage

		anchors.fill: parent
		opacity: root.karaoke ? 1 : 0
		scale: root.karaoke ? 1 : 1.04
		visible: opacity > 0
		enabled: root.karaoke
		onClosed: {
			root.karaoke = false;
			sheet.takeFocus();
		}
		onVisibleChanged: if (root.karaoke) karaokeStage.forceActiveFocus()

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		Behavior on scale {
			SpatialAnim {}
		}
	}

	// ── what is said ───────────────────────────────────────────────────────
	Rectangle {
		id: toast

		function show(text, icon) {
			toastText.text = text;
			toastGlyph.icon = icon;
			toast.opacity = 1;
			toastTimer.restart();
		}

		anchors.horizontalCenter: parent.horizontalCenter
		y: parent.height - beat.height - height - 16 + (toast.opacity < 1 ? 10 : 0)
		width: toastRow.implicitWidth + 32
		height: 40
		radius: 20
		color: Theme.layer3
		opacity: 0
		visible: opacity > 0

		Behavior on opacity {
			Anim {}
		}

		Behavior on y {
			SpatialAnim {}
		}

		Row {
			id: toastRow

			anchors.centerIn: parent
			spacing: 10

			Glyph {
				id: toastGlyph

				anchors.verticalCenter: parent.verticalCenter
				size: 16
				color: Theme.primary
			}

			StyledText {
				id: toastText

				anchors.verticalCenter: parent.verticalCenter
			}
		}

		Timer {
			id: toastTimer

			interval: 2600
			onTriggered: toast.opacity = 0
		}
	}

	// ── keys of the window ─────────────────────────────────────────────────
	Shortcut {
		sequence: "Ctrl+Space"
		autoRepeat: false
		onActivated: Rhymes.hasBeat ? (Rhymes.beatPlaying ? Rhymes.stop() : Rhymes.playFromRow(Rhymes.row)) : null
	}

	Shortcut {
		sequence: "Ctrl+B"
		onActivated: root.toggleSide()
	}

	Shortcut {
		sequence: "Ctrl+J"
		onActivated: Rhymes.setSetting("panel", root.panel === "" ? "rhymes" : "")
	}

	Shortcut {
		sequence: "Ctrl+1"
		onActivated: root.showPanel("rhymes")
	}

	Shortcut {
		sequence: "Ctrl+2"
		onActivated: root.showPanel("words")
	}

	Shortcut {
		sequence: "Ctrl+3"
		onActivated: root.showPanel("takes")
	}

	Shortcut {
		sequence: "Ctrl+4"
		onActivated: root.showPanel("versions")
	}

	Shortcut {
		sequence: "Ctrl+N"
		onActivated: Rhymes.create("")
	}

	Shortcut {
		sequence: "Ctrl+F"
		onActivated: {
			if (root.narrow) root.sideOver = true;
			else if (!root.sideOpen) Rhymes.setSetting("sidebar", true);
			libraryView.searchField.focusInput();
		}
	}

	Shortcut {
		sequence: "Ctrl+S"
		onActivated: Rhymes.keepVersion()
	}

	Shortcut {
		sequence: "Ctrl+R"
		onActivated: Rhymes.record()
	}

	Shortcut {
		sequence: "Ctrl+L"
		onActivated: Rhymes.loopSection(Rhymes.row)
	}

	Shortcut {
		sequence: "Ctrl+K"
		onActivated: {
			root.karaoke = !root.karaoke;
			root.takeFocus();
		}
	}

	Shortcut {
		sequence: "Ctrl+I"
		onActivated: Rhymes.addIdea(Rhymes.lines.get(Rhymes.row)?.text ?? "")
	}

	Shortcut {
		sequence: "Ctrl+M"
		enabled: root.active && Rhymes.hasBeat
		onActivated: Rhymes.toggleMetronome()
	}

	Shortcut {
		sequence: "Ctrl+E"
		enabled: root.active && Rhymes.song !== null
		onActivated: root.setStudio(!root.studioOpen)
	}

	Shortcut {
		sequence: "Ctrl+W"
		onActivated: Rhymes.close()
	}

	component PaneSlot: Item {
		id: slot

		property string name: ""
		property int order: 0
		readonly property bool current: root.panel === slot.name
		readonly property int at: ["rhymes", "words", "takes", "versions"].indexOf(root.panel)

		anchors.fill: parent
		anchors.topMargin: 12
		opacity: slot.current ? 1 : 0
		visible: opacity > 0
		transform: Translate {
			x: slot.current ? 0 : (slot.order < slot.at ? -30 : 30)

			Behavior on x {
				SpatialAnim {}
			}
		}

		Behavior on opacity {
			Anim {}
		}
	}
}
