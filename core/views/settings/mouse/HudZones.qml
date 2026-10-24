pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// The HUD by hand (gamefeel.Eyes, options.hudZones[game]): zones drawn
// on a picture of the game's window, each with its own condition – it
// changes, it changes after a press (any, or one key), it turns red,
// brightens, darkens – and its own pattern. Nothing is learned here; a
// zone fires exactly when its condition holds. The picture comes from
// window_shots.py (niri's cast of the window, nothing shown or asked);
// the zones glow live with what eyes.py measures in them.
ColumnLayout {
	id: root

	readonly property string game: Mouse.gameKey
	readonly property int window: Mouse.gameWindow
	readonly property var table: Mouse.option("hudZones", null) ?? ({})
	readonly property var zones: Array.isArray(root.table[root.game]) ? root.table[root.game] : []
	readonly property var live: Mouse.eyes?.latest?.zones ?? ({})
	readonly property var feels: ["SHARP COLLISION", "DAMP COLLISION", "SUBTLE COLLISION", "WHISPER COLLISION", "SHARP STATE CHANGE", "DAMP STATE CHANGE", "KNOCK"]
	readonly property var whens: [
		{ value: "change", label: "Changes", icon: "swap_horizontal" },
		{ value: "press", label: "After a press", icon: "mouse" },
		{ value: "red", label: "Turns red", icon: "heart_pulse" },
		{ value: "bright", label: "Brightens", icon: "white_balance_sunny" },
		{ value: "dark", label: "Darkens", icon: "weather_night" }
	]
	readonly property string shotDir: `${Paths.runtime}/hud`
	property string shotFile: ""
	property int shotRev: 0
	property bool shooting: false
	property bool open: root.zones.length > 0
	// the zone being edited (its id), the one being redrawn, and the key recorder
	property string selected: ""
	property bool redrawing: false
	property bool recording: false
	// which zone fired last, for a flash
	property string fired: ""

	readonly property var zone: root.zones.find(z => z.id === root.selected) ?? null

	spacing: 8
	visible: root.game !== "" || root.zones.length > 0

	function save(list) {
		const table = Object.assign({}, root.table);
		if (list.length > 0) table[root.game] = list;
		else delete table[root.game];
		Mouse.setOption("hudZones", table);
	}

	function change(id, values) {
		root.save(root.zones.map(z => z.id === id ? Object.assign({}, z, values) : z));
	}

	function remove(id) {
		if (root.selected === id) root.selected = "";
		root.save(root.zones.filter(z => z.id !== id));
	}

	function add(rect) {
		const id = `z${Date.now().toString(36)}`;
		root.save(root.zones.concat([Object.assign({ id, name: `Zone ${root.zones.length + 1}`, when: "change", key: "", feel: "SUBTLE COLLISION", level: 0, every: 150 }, rect)]));
		root.selected = id;
	}

	function keyLabel(zone) {
		const key = zone?.key ?? "";
		if (key === "" || key === null) return "Any press";
		if (zone.keyName) return zone.keyName;
		const names = { BTN_LEFT: "Left click", BTN_RIGHT: "Right click", BTN_MIDDLE: "Middle click", BTN_SIDE: "Back button", BTN_EXTRA: "Forward button" };
		return names[key] ?? String(key).replace(/^KEY_/, "");
	}

	function whenLabel(zone) {
		return root.whens.find(w => w.value === zone.when)?.label ?? zone.when;
	}

	// a picture of the game's window, once
	function shoot() {
		if (root.window <= 0 || root.shooting) return;
		root.shooting = true;
		shots.running = false;
		shots.running = true;
		giveUp.restart();
	}

	// no picture in time (no cast to be had): zones can still be drawn
	Timer {
		id: giveUp

		interval: 8000
		onTriggered: {
			root.shooting = false;
			shots.running = false;
		}
	}

	function recordKey(event) {
		if (!root.recording || !root.zone) return;
		if (event.key === Qt.Key_Escape) {
			root.recording = false;
			return;
		}
		const code = event.nativeScanCode - 8;
		if (code <= 0) return;
		let name = event.text && event.text.trim().length === 1 ? event.text.toUpperCase() : "";
		if (!name) name = { [Qt.Key_Space]: "Space", [Qt.Key_Shift]: "Shift", [Qt.Key_Control]: "Ctrl", [Qt.Key_Alt]: "Alt", [Qt.Key_Tab]: "Tab" }[event.key] ?? `Key ${code}`;
		root.change(root.zone.id, { key: code, keyName: name });
		root.recording = false;
	}

	onOpenChanged: if (root.open && root.shotFile === "") root.shoot()
	onWindowChanged: if (root.open) root.shoot()

	Connections {
		target: Mouse

		function onFelt(source, kind, strength, wave, label, cluster) {
			if (source !== "eyes" || kind !== "zone") return;
			const hit = root.zones.find(z => z.name === label);
			if (!hit) return;
			root.fired = hit.id;
			firedOff.restart();
		}
	}

	Timer {
		id: firedOff

		interval: 350
		onTriggered: root.fired = ""
	}

	Process {
		id: shots

		command: ["python3", `${Paths.scripts}/window_shots.py`, root.shotDir, "960", "0"]
		stdinEnabled: true
		onStarted: {
			const raw = Niri.windowMap?.[String(root.window)] ?? Niri.windowMap?.[root.window];
			const size = raw?.layout?.window_size ?? [1920, 1080];
			shots.write(`${root.window}:${Math.round(Number(size[0]) || 1920)}:${Math.round(Number(size[1]) || 1080)}\n`);
		}
		onExited: root.shooting = false
		stdout: SplitParser {
			onRead: line => {
				let data = null;
				try {
					data = JSON.parse(line);
				} catch (error) {
					return;
				}
				if (Number(data.id) !== root.window) return;
				root.shotFile = String(data.file);
				root.shotRev += 1;
				root.shooting = false;
				shots.running = false;
			}
		}
	}

	// takes the key while a zone records one
	Item {
		id: catcher

		focus: root.recording
		Keys.onPressed: event => {
			root.recordKey(event);
			event.accepted = true;
		}
		onFocusChanged: if (root.recording) catcher.forceActiveFocus()
	}

	Clickable {
		Layout.fillWidth: true
		Layout.leftMargin: 10
		implicitHeight: 28
		radius: Theme.radius.small
		color: Theme.layer1
		onClicked: root.open = !root.open

		RowLayout {
			anchors.fill: parent
			spacing: 8

			Glyph {
				icon: root.open ? "chevron_down" : "chevron_right"
				size: 16
				color: Theme.textSubtle
			}

			StyledText {
				text: "The HUD by hand – draw where to look, say when to feel what"
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				tone: Theme.textSubtle
			}

			Item {
				Layout.fillWidth: true
			}

			StyledText {
				visible: !root.open
				text: root.zones.length > 0 ? `${root.zones.length} zone${root.zones.length === 1 ? "" : "s"} in ${root.game}` : (root.game ? root.game : "")
				font.pixelSize: Theme.size.small
				tone: Theme.textFaint
				elide: Text.ElideRight
			}
		}
	}

	ColumnLayout {
		Layout.fillWidth: true
		Layout.leftMargin: 10
		visible: root.open
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			StyledText {
				Layout.fillWidth: true
				text: root.window > 0 ? `${root.game} – drag a box on the picture over the ammo counter, the health bar, the cast bar, the hit marker. Each zone has its own condition and its own pattern; the learned part keeps running beside it.` : "No game window – start the game, then come back here (the picture is taken from its window)."
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}

			TextButton {
				visible: root.window > 0
				text: root.shooting ? "Taking…" : "New picture"
				icon: "camera_outline"
				variant: "text"
				busy: root.shooting
				onActivated: root.shoot()
			}
		}

		// the picture with the zones on it
		Rectangle {
			id: board

			Layout.fillWidth: true
			Layout.preferredHeight: Math.round(width * (picture.implicitHeight > 0 && picture.implicitWidth > 0 ? picture.implicitHeight / picture.implicitWidth : 9 / 16))
			radius: Theme.radius.large
			color: Theme.layer1
			clip: true

			Image {
				id: picture

				anchors.fill: parent
				source: root.shotFile ? `file://${root.shotFile}?${root.shotRev}` : ""
				fillMode: Image.PreserveAspectFit
				cache: false
				asynchronous: true
				smooth: true
			}

			StyledText {
				anchors.centerIn: parent
				visible: picture.status !== Image.Ready
				text: root.window > 0 ? (root.shooting ? "Taking a picture of the game's window…" : "No picture yet – zones can be drawn all the same") : "The game's picture appears here while it runs"
				tone: Theme.textFaint
				font.pixelSize: Theme.size.small
			}

			// where the picture actually is
			Item {
				id: canvas

				readonly property real pw: picture.status === Image.Ready ? picture.paintedWidth : board.width
				readonly property real ph: picture.status === Image.Ready ? picture.paintedHeight : board.height

				x: (board.width - canvas.pw) / 2
				y: (board.height - canvas.ph) / 2
				width: canvas.pw
				height: canvas.ph

				MouseArea {
					id: drawer

					property real sx: 0
					property real sy: 0
					property real ex: 0
					property real ey: 0
					readonly property bool drawing: pressed

					anchors.fill: parent
					cursorShape: Qt.CrossCursor
					hoverEnabled: true
					onPressed: mouse => {
						drawer.sx = drawer.ex = Math.max(0, Math.min(width, mouse.x));
						drawer.sy = drawer.ey = Math.max(0, Math.min(height, mouse.y));
					}
					onPositionChanged: mouse => {
						if (!drawer.pressed) return;
						drawer.ex = Math.max(0, Math.min(width, mouse.x));
						drawer.ey = Math.max(0, Math.min(height, mouse.y));
					}
					onReleased: {
						const x0 = Math.min(drawer.sx, drawer.ex), x1 = Math.max(drawer.sx, drawer.ex);
						const y0 = Math.min(drawer.sy, drawer.ey), y1 = Math.max(drawer.sy, drawer.ey);
						if (x1 - x0 < 6 || y1 - y0 < 6) {
							// a click on the picture: nothing selected
							if (!root.redrawing) root.selected = "";
							return;
						}
						const rect = { x: x0 / width, y: y0 / height, w: (x1 - x0) / width, h: (y1 - y0) / height };
						if (root.redrawing && root.zone) {
							root.change(root.zone.id, rect);
							root.redrawing = false;
						} else {
							root.add(rect);
						}
					}
				}

				// the box being drawn
				Rectangle {
					visible: drawer.drawing && Math.abs(drawer.ex - drawer.sx) >= 2
					x: Math.min(drawer.sx, drawer.ex)
					y: Math.min(drawer.sy, drawer.ey)
					width: Math.abs(drawer.ex - drawer.sx)
					height: Math.abs(drawer.ey - drawer.sy)
					color: Qt.alpha(Theme.primary, 0.2)
					border.width: 1.5
					border.color: Theme.primary
				}

				Repeater {
					model: root.zones

					delegate: Rectangle {
						id: box

						required property var modelData

						readonly property bool chosen: root.selected === box.modelData.id
						readonly property var values: root.live[box.modelData.id] ?? null
						// how much it is changing now, 0..1
						readonly property real heat: {
							if (!box.values) return 0;
							const when = box.modelData.when;
							const value = when === "red" ? box.values[1] : (when === "bright" ? box.values[2] : (when === "dark" ? -box.values[2] : box.values[0]));
							return Math.max(0, Math.min(1, value / 40));
						}

						x: box.modelData.x * canvas.width
						y: box.modelData.y * canvas.height
						width: Math.max(4, box.modelData.w * canvas.width)
						height: Math.max(4, box.modelData.h * canvas.height)
						color: root.fired === box.modelData.id ? Qt.alpha(Theme.primary, 0.6) : Qt.alpha(box.chosen ? Theme.primary : Theme.text, 0.12 + box.heat * 0.5)
						border.width: box.chosen ? 2 : 1
						border.color: box.chosen ? Theme.primary : Qt.alpha(Theme.text, 0.7)
						radius: 2

						Behavior on color {
							ColorAnim {
								duration: 120
							}
						}

						MouseArea {
							anchors.fill: parent
							cursorShape: Qt.PointingHandCursor
							onClicked: {
								root.selected = box.modelData.id;
								root.redrawing = false;
							}
						}

						Rectangle {
							anchors.left: parent.left
							anchors.bottom: parent.top
							anchors.bottomMargin: 2
							width: tag.implicitWidth + 10
							height: 18
							radius: 4
							color: box.chosen ? Theme.primary : Theme.layer3

							StyledText {
								id: tag

								anchors.centerIn: parent
								text: box.modelData.name
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
								color: box.chosen ? Theme.onPrimary : Theme.text
							}
						}
					}
				}
			}
		}

		StyledText {
			visible: root.zones.length === 0
			text: "No zones yet. Drag a box on the picture."
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
		}

		// every zone, one line each; the chosen one opens below
		Repeater {
			model: root.zones

			delegate: RowLayout {
				id: row

				required property var modelData

				readonly property bool chosen: root.selected === row.modelData.id
				readonly property var values: root.live[row.modelData.id] ?? null

				Layout.fillWidth: true
				spacing: 8

				Rectangle {
					Layout.preferredWidth: 10
					Layout.preferredHeight: 10
					radius: 5
					color: root.fired === row.modelData.id ? Theme.primary : "transparent"
					border.width: 1
					border.color: row.chosen ? Theme.primary : Theme.outline
				}

				Clickable {
					Layout.fillWidth: true
					implicitHeight: 26
					radius: Theme.radius.small
					color: row.chosen ? Theme.primarySoft : Theme.layer1
					onClicked: {
						root.selected = row.chosen ? "" : row.modelData.id;
						root.redrawing = false;
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 8
						anchors.rightMargin: 8
						spacing: 8

						StyledText {
							Layout.preferredWidth: 140
							text: row.modelData.name
							font.pixelSize: Theme.size.small
							font.weight: row.chosen ? Font.DemiBold : Font.Normal
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							text: `${root.whenLabel(row.modelData)}${row.modelData.when === "press" ? " · " + root.keyLabel(row.modelData) : ""} → ${row.modelData.feel.toLowerCase()}`
							font.pixelSize: Theme.size.small
							tone: Theme.textSubtle
							elide: Text.ElideRight
						}

						StyledText {
							visible: !!row.values
							text: row.values ? `${row.values[0]} · red ${row.values[1] > 0 ? "+" : ""}${row.values[1]} · bright ${row.values[2] > 0 ? "+" : ""}${row.values[2]}` : ""
							font.pixelSize: Theme.size.small
							tone: Theme.textFaint
						}
					}
				}

				IconButton {
					Layout.preferredWidth: 26
					Layout.preferredHeight: 26
					icon: "play"
					onClicked: Mouse.play(row.modelData.feel)
				}
			}
		}

		// the chosen zone
		Rectangle {
			Layout.fillWidth: true
			visible: !!root.zone
			implicitHeight: editor.implicitHeight + 24
			radius: Theme.radius.large
			color: Theme.layer1

			ColumnLayout {
				id: editor

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 12
				spacing: 10

				RowLayout {
					Layout.fillWidth: true
					spacing: 10

					Field {
						Layout.preferredWidth: 220
						placeholder: "Name"
						icon: "tag_outline"
						text: root.zone?.name ?? ""
						onEdited: text => {
							if (root.zone && text.trim() !== "") root.change(root.zone.id, { name: text.trim() });
						}
					}

					Item {
						Layout.fillWidth: true
					}

					TextButton {
						text: root.redrawing ? "Draw it now…" : "Redraw"
						icon: "select_drag"
						variant: root.redrawing ? "tonal" : "text"
						onActivated: root.redrawing = !root.redrawing
					}

					TextButton {
						text: "Remove"
						icon: "delete_outline"
						variant: "text"
						onActivated: root.remove(root.zone.id)
					}
				}

				StyledText {
					text: "When"
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
					tone: Theme.textSubtle
				}

				Segmented {
					Layout.fillWidth: true
					options: root.whens
					current: root.zone?.when ?? "change"
					onSelected: value => root.change(root.zone.id, { when: value })
				}

				RowLayout {
					Layout.fillWidth: true
					visible: root.zone?.when === "press"
					spacing: 8

					StyledText {
						text: "After"
						font.pixelSize: Theme.size.small
						tone: Theme.textSubtle
					}

					Repeater {
						model: [{ key: "", label: "Any press" }, { key: "BTN_LEFT", label: "Left click" }, { key: "BTN_RIGHT", label: "Right click" }]

						delegate: Chip {
							required property var modelData

							text: modelData.label
							selected: !root.recording && String(root.zone?.key ?? "") === modelData.key
							onClicked: {
								root.recording = false;
								root.change(root.zone.id, { key: modelData.key, keyName: "" });
							}
						}
					}

					Chip {
						text: root.recording ? "Press a key…" : (typeof root.zone?.key === "number" ? `Key ${root.keyLabel(root.zone)}` : "A key…")
						icon: "keyboard_outline"
						selected: root.recording || typeof root.zone?.key === "number"
						onClicked: {
							root.recording = !root.recording;
							if (root.recording) catcher.forceActiveFocus();
						}
					}

					Item {
						Layout.fillWidth: true
					}
				}

				StyledText {
					Layout.fillWidth: true
					text: {
						switch (root.zone?.when) {
						case "press":
							return "Fires when the zone changes while a press of yours is fresh (a key keeps its window open up to 2 s, a click 0.45 s – longer once the game taught it). The ammo counter after a shot, the cast bar after a spell.";
						case "red":
							return "Fires when the zone suddenly reddens – a hit marker, blood at the edge, a health bar dropping.";
						case "bright":
							return "Fires when the zone suddenly brightens – a muzzle flash, an icon lighting up, a spell ready.";
						case "dark":
							return "Fires when the zone suddenly darkens – an icon greying out, a charge spent.";
						default:
							return "Fires whenever the zone changes, whoever caused it – not while the whole picture moves (the world behind a see-through HUD). Draw it over opaque HUD.";
						}
					}
					tone: Theme.textFaint
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}

				StyledText {
					text: "Feel"
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
					tone: Theme.textSubtle
				}

				GridLayout {
					Layout.fillWidth: true
					columns: 4
					columnSpacing: 6
					rowSpacing: 6

					Repeater {
						model: root.feels

						delegate: WaveTile {
							required property string modelData

							Layout.fillWidth: true
							waveform: modelData
							chosen: root.zone?.feel === modelData
							onClicked: root.change(root.zone.id, { feel: modelData })
						}
					}
				}

				ValueSlider {
					from: 0
					to: 60
					step: 1
					icon: "tune_variant"
					label: "Needs a change of"
					value: Number(root.zone?.level ?? 0)
					format: v => v <= 0 ? "by itself" : `${Math.round(v)}`
					onMoved: v => root.change(root.zone.id, { level: Math.round(v) })
				}

				ValueSlider {
					from: 30
					to: 1000
					step: 10
					unit: " ms"
					icon: "timer_outline"
					label: "At most every"
					value: Number(root.zone?.every ?? 150)
					onMoved: v => root.change(root.zone.id, { every: Math.round(v) })
				}

				StyledText {
					Layout.fillWidth: true
					visible: !!root.zone
					text: {
						const v = root.live[root.zone?.id ?? ""];
						if (!v) return Mouse.eyes?.on ? "Live: nothing measured in this zone yet" : "Live numbers appear while the game has the focus and the picture is watched";
						return `Live: changing by ${v[0]} · red ${v[1] > 0 ? "+" : ""}${v[1]} · bright ${v[2] > 0 ? "+" : ""}${v[2]} (0..255; by itself: change 14, red 8, bright and dark 20)`;
					}
					tone: Theme.textFaint
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}
		}
	}
}
