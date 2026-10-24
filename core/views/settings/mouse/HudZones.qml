pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// The HUD by hand (gamefeel.Eyes; the model lives in Mouse.qml: hudScenes,
// hudZones). Scenes are pictures of the game as its HUD looks in a fight,
// a dialog, exploring; zones are drawn on them – here on the picture, or on
// the real screen like a screenshot (Screenshot.hud: the frozen game, every
// box clicked or region dragged is a zone, Esc when done). Each zone has
// its own condition – it changes, it changes after a press (any, or one
// key), it turns red, brightens, darkens – and its own pattern. Nothing is
// learned here: a zone fires exactly when its condition holds. The boxes
// on a picture are found (scripts/mouse/hud_guess.py, the screenshot
// tool's smart select) and offered under the cursor; "Suggest" marks the
// ones that look like the HUD, a click takes one.
ColumnLayout {
	id: root

	readonly property string game: Mouse.gameKey
	readonly property int window: Mouse.gameWindow
	readonly property var scenes: Mouse.hudScenes
	readonly property var scene: Mouse.hudScene
	readonly property string sceneId: root.scene?.id ?? ""
	readonly property var allZones: Mouse.hudZones
	readonly property var zones: root.allZones.filter(z => (z.scene ?? "") === root.sceneId || (!z.scene && root.scenes.length <= 1))
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
	readonly property string picture: String(root.scene?.picture ?? "")
	property bool shooting: false
	property bool open: root.allZones.length > 0 || root.scenes.length > 0
	// the zone being edited (its id), the one being redrawn, and the key recorder
	property string selected: ""
	property bool redrawing: false
	property bool recording: false
	// which zone fired last, for a flash
	property string fired: ""
	// the boxes found on the picture (fractions) and the suggested ones
	property var boxes: []
	property var suggested: []
	property bool suggesting: false
	property bool guessing: false
	property string guessedFor: ""

	readonly property var zone: root.allZones.find(z => z.id === root.selected) ?? null

	spacing: 8
	visible: root.game !== "" || root.allZones.length > 0

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

	function add(rect, values) {
		root.selected = Mouse.hudAddZone(rect, values);
	}

	// the smallest found box under a point of the picture (fractions)
	function boxAt(fx, fy) {
		let best = null;
		for (const b of root.boxes) {
			if (fx >= b[0] && fx <= b[0] + b[2] && fy >= b[1] && fy <= b[1] + b[3]) {
				if (!best || b[2] * b[3] < best[2] * best[3]) best = b;
			}
		}
		return best;
	}

	// a picture of the game's window into the scene, once
	function shoot() {
		if (root.window <= 0 || root.shooting) return;
		Mouse.hudSceneForDrawing();
		root.shooting = true;
		shots.running = false;
		shots.running = true;
		giveUp.restart();
	}

	// the boxes on the scene's picture
	function guess() {
		if (root.picture === "" || root.guessing) return;
		root.guessing = true;
		guesser.running = false;
		guesser.command = ["python3", `${Paths.scripts}/mouse/hud_guess.py`, root.picture, JSON.stringify({ grid: Mouse.eyes?.grid ?? [], yours: Mouse.eyes?.hud?.yours ?? [] })];
		guesser.running = true;
	}

	function reload() {
		pictureImage.source = "";
		pictureImage.source = root.picture ? `file://${root.picture}?${Mouse.hudPictureRev}` : "";
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
		Mouse.hudChangeZone(root.zone.id, { key: code, keyName: name });
		root.recording = false;
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

	onOpenChanged: if (root.open && root.picture === "" && root.scenes.length === 0) root.shoot()
	onPictureChanged: {
		root.boxes = [];
		root.suggested = [];
		root.suggesting = false;
		root.reload();
	}
	Component.onCompleted: root.reload()

	Connections {
		target: Mouse

		function onHudPictureRevChanged() {
			root.guessedFor = "";
			root.reload();
		}

		function onFelt(source, kind, strength, wave, label, cluster) {
			if (source !== "eyes" || kind !== "zone") return;
			const hit = root.allZones.find(z => z.name === label);
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

		command: ["python3", `${Paths.scripts}/window_shots.py`, root.shotDir, "1280", "0"]
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
				const scene = Mouse.hudSceneForDrawing();
				if (scene?.picture) {
					copier.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && cp -f "$1" "$2"', "sh", String(data.file), String(scene.picture)];
					copier.running = true;
				}
				root.shooting = false;
				shots.running = false;
			}
		}
	}

	Process {
		id: copier

		onExited: Mouse.hudPictureRev += 1
	}

	Process {
		id: guesser

		stdout: StdioCollector {
			onStreamFinished: {
				root.guessing = false;
				let data = null;
				try {
					data = JSON.parse(this.text);
				} catch (error) {
					return;
				}
				root.guessedFor = root.picture;
				root.boxes = Array.isArray(data?.boxes) ? data.boxes : [];
				root.suggested = Array.isArray(data?.suggested) ? data.suggested : [];
			}
		}
		onExited: root.guessing = false
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
				text: root.allZones.length > 0 ? `${root.allZones.length} zone${root.allZones.length === 1 ? "" : "s"}${root.scenes.length > 1 ? ` in ${root.scenes.length} scenes` : ""} – ${root.game}` : (root.game ? root.game : "")
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

		StyledText {
			Layout.fillWidth: true
			text: root.window > 0 ? `${root.game} – the surest way: "Draw on the screen" brings the game up and freezes it like a screenshot; click the boxes it finds (ammo counter, health bar, cast bar, hit marker) or drag over one, each is a zone, Esc when done. Or draw here on the picture. Each zone has its own condition and its own pattern; the learned part keeps running beside it.` : "No game window – start the game, then come back here (the picture is taken from its window)."
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}

		// ── scenes: a picture each ───────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			StyledText {
				text: "Scene"
				font.pixelSize: Theme.size.small
				tone: Theme.textFaint
			}

			Repeater {
				model: root.scenes

				delegate: Chip {
					id: sceneChip

					required property var modelData

					readonly property int count: root.allZones.filter(z => z.scene === sceneChip.modelData.id).length

					text: sceneChip.count > 0 ? `${sceneChip.modelData.name} · ${sceneChip.count}` : sceneChip.modelData.name
					selected: root.sceneId === sceneChip.modelData.id
					onClicked: {
						Mouse.hudSceneId = sceneChip.modelData.id;
						root.selected = "";
					}
				}
			}

			Chip {
				text: "New scene"
				icon: "plus"
				onClicked: {
					Mouse.hudAddScene("");
					root.selected = "";
				}
			}

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				visible: root.window > 0 && Plugins.on("screenshot")
				text: "Draw on the screen"
				icon: "selection_drag"
				variant: "tonal"
				onActivated: Mouse.hudDraw()
			}

			TextButton {
				visible: root.window > 0
				text: root.shooting ? "Taking…" : (root.picture !== "" ? "New picture" : "Take a picture")
				icon: "camera_outline"
				variant: "text"
				busy: root.shooting
				onActivated: root.shoot()
			}
		}

		// the scene's name and what to do with it
		RowLayout {
			Layout.fillWidth: true
			visible: !!root.scene
			spacing: 8

			Field {
				Layout.preferredWidth: 240
				placeholder: "Scene name – fight, dialog, exploring"
				icon: "image_outline"
				text: root.scene?.name ?? ""
				onEdited: text => {
					if (root.scene && text.trim() !== "") Mouse.hudChangeScene(root.scene.id, { name: text.trim() });
				}
			}

			TextButton {
				text: root.guessing ? "Looking…" : (root.suggesting ? "Hide suggestions" : "Suggest zones")
				icon: "auto_fix"
				variant: "text"
				busy: root.guessing
				enabled: root.picture !== ""
				onActivated: {
					if (root.suggesting) {
						root.suggesting = false;
						return;
					}
					root.suggesting = true;
					if (root.guessedFor !== root.picture) root.guess();
				}
			}

			TextButton {
				visible: root.suggesting && root.suggested.length > 0
				text: `Add all ${root.suggested.length}`
				icon: "plus"
				variant: "text"
				onActivated: {
					for (const s of root.suggested) Mouse.hudAddZone({ x: s.x, y: s.y, w: s.w, h: s.h }, { name: s.name, when: s.when });
					root.suggesting = false;
				}
			}

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				visible: root.scenes.length > 0
				text: "Remove scene"
				icon: "delete_outline"
				variant: "text"
				confirm: true
				onActivated: {
					Mouse.hudRemoveScene(root.sceneId);
					root.selected = "";
				}
			}
		}

		// ── the picture with the zones on it ─────────────────────────────
		Rectangle {
			id: board

			Layout.fillWidth: true
			Layout.preferredHeight: Math.round(width * (pictureImage.implicitHeight > 0 && pictureImage.implicitWidth > 0 ? pictureImage.implicitHeight / pictureImage.implicitWidth : 9 / 16))
			radius: Theme.radius.large
			color: Theme.layer1
			clip: true

			Image {
				id: pictureImage

				anchors.fill: parent
				fillMode: Image.PreserveAspectFit
				cache: false
				asynchronous: true
				smooth: true
				onStatusChanged: if (status === Image.Ready && root.guessedFor !== root.picture && root.picture !== "") root.guess()
			}

			StyledText {
				anchors.centerIn: parent
				visible: pictureImage.status !== Image.Ready
				text: root.window > 0 ? (root.shooting ? "Taking a picture of the game's window…" : "No picture yet – zones can be drawn all the same") : "The game's picture appears here while it runs"
				tone: Theme.textFaint
				font.pixelSize: Theme.size.small
			}

			// where the picture actually is
			Item {
				id: canvas

				readonly property real pw: pictureImage.status === Image.Ready ? pictureImage.paintedWidth : board.width
				readonly property real ph: pictureImage.status === Image.Ready ? pictureImage.paintedHeight : board.height

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
					readonly property bool drawing: pressed && (Math.abs(ex - sx) >= 4 || Math.abs(ey - sy) >= 4)
					// smart select: the smallest found box under the cursor
					readonly property var snap: containsMouse && !pressed ? root.boxAt(mouseX / Math.max(1, width), mouseY / Math.max(1, height)) : null

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
						let rect = null;
						if (x1 - x0 < 6 || y1 - y0 < 6) {
							// a click: the found box under it, else nothing selected
							const best = root.boxAt(x0 / Math.max(1, width), y0 / Math.max(1, height));
							if (!best) {
								if (!root.redrawing) root.selected = "";
								return;
							}
							rect = { x: best[0], y: best[1], w: best[2], h: best[3] };
						} else {
							rect = { x: x0 / width, y: y0 / height, w: (x1 - x0) / width, h: (y1 - y0) / height };
						}
						if (root.redrawing && root.zone) {
							Mouse.hudChangeZone(root.zone.id, rect);
							root.redrawing = false;
						} else {
							root.add(rect);
						}
					}
				}

				// the found box under the cursor
				Rectangle {
					visible: !!drawer.snap && !drawer.drawing
					x: (drawer.snap?.[0] ?? 0) * canvas.width
					y: (drawer.snap?.[1] ?? 0) * canvas.height
					width: (drawer.snap?.[2] ?? 0) * canvas.width
					height: (drawer.snap?.[3] ?? 0) * canvas.height
					color: Qt.alpha(Theme.primary, 0.14)
					border.width: 1.5
					border.color: Theme.primary
					radius: 2
				}

				// the box being drawn
				Rectangle {
					visible: drawer.drawing
					x: Math.min(drawer.sx, drawer.ex)
					y: Math.min(drawer.sy, drawer.ey)
					width: Math.abs(drawer.ex - drawer.sx)
					height: Math.abs(drawer.ey - drawer.sy)
					color: Qt.alpha(Theme.primary, 0.2)
					border.width: 1.5
					border.color: Theme.primary
				}

				// suggested zones, a click takes one
				Repeater {
					model: root.suggesting ? root.suggested : []

					delegate: Rectangle {
						id: hint

						required property var modelData

						x: hint.modelData.x * canvas.width
						y: hint.modelData.y * canvas.height
						width: Math.max(4, hint.modelData.w * canvas.width)
						height: Math.max(4, hint.modelData.h * canvas.height)
						color: Qt.alpha(Theme.tertiary, 0.1)
						border.width: 1.5
						border.color: Theme.tertiary
						radius: 2

						MouseArea {
							anchors.fill: parent
							cursorShape: Qt.PointingHandCursor
							onClicked: {
								root.add({ x: hint.modelData.x, y: hint.modelData.y, w: hint.modelData.w, h: hint.modelData.h }, { name: hint.modelData.name, when: hint.modelData.when });
								root.suggested = root.suggested.filter(s => s !== hint.modelData);
							}
						}

						Rectangle {
							anchors.left: parent.left
							anchors.top: parent.bottom
							anchors.topMargin: 2
							width: hintTag.implicitWidth + 10
							height: 16
							radius: 4
							color: Theme.tertiary

							StyledText {
								id: hintTag

								anchors.centerIn: parent
								text: `${hint.modelData.when === "press" ? "after a press" : "changes"} – take?`
								font.pixelSize: Theme.size.small
								color: Theme.onPrimary
							}
						}
					}
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
			Layout.fillWidth: true
			visible: root.zones.length === 0 || (root.boxes.length > 0 && root.zones.length < 3)
			text: root.boxes.length > 0 ? `${root.boxes.length} boxes found on the picture – one lights up under the cursor, a click takes it; or drag your own.` : "No zones in this scene yet. Drag a box on the picture, or draw on the screen."
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}

		// every zone of the scene, one line each; the chosen one opens below
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
							if (root.zone && text.trim() !== "") Mouse.hudChangeZone(root.zone.id, { name: text.trim() });
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
						onActivated: {
							const id = root.zone.id;
							root.selected = "";
							Mouse.hudRemoveZone(id);
						}
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
					onSelected: value => Mouse.hudChangeZone(root.zone.id, { when: value })
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
								Mouse.hudChangeZone(root.zone.id, { key: modelData.key, keyName: "" });
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
							onClicked: Mouse.hudChangeZone(root.zone.id, { feel: modelData })
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
					onMoved: v => Mouse.hudChangeZone(root.zone.id, { level: Math.round(v) })
				}

				ValueSlider {
					from: 30
					to: 1000
					step: 10
					unit: " ms"
					icon: "timer_outline"
					label: "At most every"
					value: Number(root.zone?.every ?? 150)
					onMoved: v => Mouse.hudChangeZone(root.zone.id, { every: Math.round(v) })
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
