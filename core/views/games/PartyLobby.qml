pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A party of a co-op game with PartyDeck (core/services/Party.qml): the
// controllers that are on, live (one switched on later shows up at once),
// each a player when it presses A or is clicked; the screens as they stand,
// each player's window a part of one. A tile dragged onto another swaps the
// two, onto another screen moves it there; each screen splits its players by
// a layout of its own. On a controller: A joins, B leaves, left/right swaps
// with the neighbour, LB/RB walks the screens, Y turns the screen's layout,
// Start starts.
Item {
	id: root

	property bool open: false
	property var game: null
	// [{padId, path, profile, output}] – the order on a screen is the order here
	property var players: []
	// screen name: layout name
	property var layouts: ({})
	property string exec: ""
	property bool goldberg: false
	// pad id: when it was pressed last (the tile and the card light up)
	property var lit: ({})
	property real clock: 0

	readonly property var colors: ["#4fc3f7", "#ff8a65", "#aed581", "#ce93d8", "#ffd54f", "#4db6ac", "#f48fb1", "#90a4ae"]
	readonly property var info: Party.infoFor === root.game?.id ? Party.info : null
	readonly property var screens: Quickshell.screens.slice().sort((a, b) => a.x - b.x || a.y - b.y)
	readonly property var padsById: {
		const out = {};
		for (const pad of Party.pads)
			out[pad.id] = pad;
		return out;
	}
	readonly property bool allThere: root.players.length > 0 && root.players.every(player => !!root.padsById[player.padId])
	readonly property bool canStart: root.allThere && !!root.info && root.exec !== "" && (root.info.missing ?? []).length === 0 && !Party.starting

	function begin(game) {
		root.game = game;
		root.players = [];
		root.layouts = {};
		root.exec = "";
		root.open = true;
		Party.watching = true;
		Party.load(game);
		card.forceActiveFocus();
	}

	function close() {
		root.open = false;
		Party.watching = false;
	}

	onInfoChanged: {
		if (!root.info) return;
		root.exec = root.info.exec || "";
		root.goldberg = !!root.info.goldberg;
		root.layouts = Object.assign({}, root.info.remembered?.layouts ?? {});
	}

	function colorOf(padId) {
		const at = root.players.findIndex(player => player.padId === padId);
		return at < 0 ? Theme.textSubtle : root.colors[at % root.colors.length];
	}

	function numberOf(padId) {
		return root.players.findIndex(player => player.padId === padId) + 1;
	}

	function homeScreen() {
		return (Popups.modalScreen ?? Popups.primaryScreen ?? root.screens[0])?.name ?? "";
	}

	function join(pad) {
		if (root.numberOf(pad.id) > 0 || root.players.length >= 8) return;
		const names = root.info?.remembered?.names ?? {};
		let name = names[pad.id] || `Player ${root.players.length + 1}`;
		while (root.players.some(player => player.profile === name))
			name += "+";
		root.players = root.players.concat([{ padId: pad.id, path: pad.path, profile: name, output: root.homeScreen() }]);
		Party.rumble(pad.id);
		Sounds.play("select");
	}

	function leave(padId) {
		root.players = root.players.filter(player => player.padId !== padId);
	}

	function setProfile(padId, name) {
		root.players = root.players.map(player => player.padId === padId ? Object.assign({}, player, { profile: name }) : player);
	}

	function playersOn(output) {
		return root.players.filter(player => player.output === output);
	}

	// ── layouts ────────────────────────────────────────────────────────────
	function presets(count) {
		if (count === 2) return ["columns", "rows"];
		if (count === 3) return ["main", "columns", "top"];
		if (count === 4) return ["grid", "columns"];
		return ["grid"];
	}

	function layoutOf(output, count) {
		const kept = root.layouts[`${output}:${count}`];
		const list = root.presets(count);
		return list.includes(kept) ? kept : list[0];
	}

	function cycleLayout(output) {
		const count = root.playersOn(output).length;
		const list = root.presets(count);
		if (list.length < 2) return;
		const next = Object.assign({}, root.layouts);
		next[`${output}:${count}`] = list[(list.indexOf(root.layoutOf(output, count)) + 1) % list.length];
		root.layouts = next;
		Sounds.play("click");
	}

	// [x, y, w, h] of each of count players, 0…1 of the screen's free area
	function rects(count, layout) {
		if (count <= 1) return [[0, 0, 1, 1]];
		const out = [];
		if (layout === "columns") {
			for (let i = 0; i < count; i++)
				out.push([i / count, 0, 1 / count, 1]);
			return out;
		}
		if (layout === "rows") {
			for (let i = 0; i < count; i++)
				out.push([0, i / count, 1, 1 / count]);
			return out;
		}
		if (count === 3 && layout === "main") return [[0, 0, 0.5, 1], [0.5, 0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]];
		if (count === 3 && layout === "top") return [[0, 0, 1, 0.5], [0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]];
		const columns = Math.ceil(Math.sqrt(count));
		const rows = Math.ceil(count / columns);
		for (let i = 0; i < count; i++) {
			const row = Math.floor(i / columns);
			// a last row that is not full is spread over the width
			const inRow = row === rows - 1 ? count - row * columns : columns;
			const column = i - row * columns;
			out.push([column / inRow, row / rows, 1 / inRow, 1 / rows]);
		}
		return out;
	}

	function rectOf(player) {
		const on = root.playersOn(player.output);
		const at = on.findIndex(each => each.padId === player.padId);
		return root.rects(on.length, root.layoutOf(player.output, on.length))[Math.max(0, at)];
	}

	// ── moving players ─────────────────────────────────────────────────────
	function swap(a, b) {
		const list = root.players.slice();
		const i = list.findIndex(player => player.padId === a);
		const j = list.findIndex(player => player.padId === b);
		if (i < 0 || j < 0 || i === j) return;
		const first = Object.assign({}, list[i], { output: list[j].output });
		const second = Object.assign({}, list[j], { output: list[i].output });
		list[i] = second;
		list[j] = first;
		root.players = list;
	}

	function moveTo(padId, output) {
		const player = root.players.find(each => each.padId === padId);
		if (!player || player.output === output) return;
		root.players = root.players.filter(each => each.padId !== padId).concat([Object.assign({}, player, { output: output })]);
	}

	function step(padId, delta) {
		const player = root.players.find(each => each.padId === padId);
		if (!player) return;
		const on = root.playersOn(player.output);
		const at = on.findIndex(each => each.padId === padId);
		const other = on[at + delta];
		if (other) root.swap(padId, other.padId);
	}

	function stepScreen(padId, delta) {
		const player = root.players.find(each => each.padId === padId);
		if (!player || root.screens.length < 2) return;
		const at = Math.max(0, root.screens.findIndex(screen => screen.name === player.output));
		root.moveTo(padId, root.screens[(at + delta + root.screens.length) % root.screens.length].name);
	}

	// ── starting ───────────────────────────────────────────────────────────
	function start() {
		// a name still being typed is taken first
		card.forceActiveFocus();
		if (!root.canStart) {
			Sounds.play("attention");
			return;
		}
		const layouts = {};
		for (const screen of root.screens) {
			const count = root.playersOn(screen.name).length;
			if (count > 1) layouts[`${screen.name}:${count}`] = root.layoutOf(screen.name, count);
		}
		Party.launch({
			game: Party.gameOf(root.game),
			exec: root.exec,
			goldberg: root.goldberg,
			layouts: layouts,
			players: root.players.map(player => ({
				pad: root.padsById[player.padId].path,
				padId: player.padId,
				profile: player.profile,
				output: player.output,
				rect: root.rectOf(player)
			}))
		}, answer => {
			if (answer.error) return;
			root.close();
			Popups.closeModal();
		});
	}

	// a controller's own say
	Connections {
		target: Party
		enabled: root.open

		function onPress(padId, button) {
			const lit = Object.assign({}, root.lit);
			lit[padId] = Date.now();
			root.lit = lit;
			const pad = root.padsById[padId];
			const joined = root.numberOf(padId) > 0;
			const player = root.players.find(each => each.padId === padId);
			switch (button) {
			case "a":
				if (pad && !joined) root.join(pad);
				break;
			case "b":
				if (joined) root.leave(padId);
				else if (root.players.length === 0) root.close();
				break;
			case "left":
			case "up":
				if (joined) root.step(padId, -1);
				break;
			case "right":
			case "down":
				if (joined) root.step(padId, 1);
				break;
			case "lb":
				if (joined) root.stepScreen(padId, -1);
				break;
			case "rb":
				if (joined) root.stepScreen(padId, 1);
				break;
			case "y":
				if (player) root.cycleLayout(player.output);
				break;
			case "start":
				root.start();
				break;
			}
		}
	}

	// a joined controller that went (switched off) and came back has a new node
	Connections {
		target: Party

		function onPadsChanged() {
			let changed = false;
			const next = root.players.map(player => {
				const pad = root.padsById[player.padId];
				if (pad && pad.path !== player.path) {
					changed = true;
					return Object.assign({}, player, { path: pad.path });
				}
				return player;
			});
			if (changed) root.players = next;
		}
	}

	// the light of a press fades
	Timer {
		interval: 50
		repeat: true
		running: root.open
		onTriggered: root.clock = Date.now()
	}

	function glow(padId) {
		const at = root.lit[padId];
		return at ? Math.max(0, 1 - (root.clock - at) / 600) : 0;
	}

	anchors.fill: parent
	visible: card.opacity > 0.01
	z: 40

	Rectangle {
		anchors.fill: parent
		color: Qt.rgba(0, 0, 0, 0.6)
		opacity: root.open ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
			enabled: root.open
			onClicked: root.close()
		}
	}

	RectangularShadow {
		anchors.fill: card
		radius: card.radius
		blur: 60
		offset.y: 24
		color: Qt.rgba(0, 0, 0, 0.65)
		opacity: card.opacity
	}

	Rectangle {
		id: card

		property real rise: root.open ? 1 : 0

		anchors.horizontalCenter: parent.horizontalCenter
		y: (parent.height - height) / 2 + 60 * (1 - card.rise)
		width: Math.min(parent.width - 64, 1180)
		height: Math.min(parent.height - 64, content.implicitHeight + 48)
		radius: Theme.radius.huge
		color: Qt.tint(Theme.bg, Qt.rgba(1, 1, 1, 0.04))
		border.width: 1
		border.color: Qt.rgba(1, 1, 1, 0.08)
		opacity: card.rise
		scale: 0.96 + 0.04 * card.rise
		focus: root.open

		Behavior on rise {
			NumberAnimation {
				duration: root.open ? Motion.extraLong : Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: root.open ? Motion.spatial : Motion.accel
			}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: card.forceActiveFocus()
		}

		Keys.onEscapePressed: root.close()
		Keys.onReturnPressed: root.start()

		ColumnLayout {
			id: content

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 24
			spacing: 18

			// ── title ──────────────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 12

				Glyph {
					icon: "account_multiple"
					size: 22
					color: Theme.primary
					surface: "transparent"
				}

				StyledText {
					Layout.fillWidth: true
					text: `Party · ${root.game?.name ?? ""}`
					tone: Theme.text
					surface: "transparent"
					elide: Text.ElideRight
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				IconButton {
					implicitWidth: 34
					implicitHeight: 34
					icon: "close"
					onClicked: root.close()
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 24

				// ── the controllers ────────────────────────────────────────
				ColumnLayout {
					Layout.preferredWidth: 300
					Layout.maximumWidth: 300
					Layout.alignment: Qt.AlignTop
					spacing: 8

					SectionLabel {
						text: "Controllers"
					}

					StyledText {
						Layout.fillWidth: true
						Layout.topMargin: 6
						visible: Party.pads.length === 0
						text: "No controller"
						tone: Theme.textSubtle
						surface: "transparent"
						font.pixelSize: Theme.size.body
					}

					Repeater {
						model: Party.pads

						delegate: Clickable {
							id: padCard

							required property var modelData
							readonly property int number: root.numberOf(padCard.modelData.id)
							readonly property color tone: root.colorOf(padCard.modelData.id)
							readonly property real glow: root.glow(padCard.modelData.id)

							Layout.fillWidth: true
							implicitHeight: 58
							radius: Theme.radius.large
							color: Qt.tint(Theme.layer1, Qt.alpha(padCard.tone, padCard.number > 0 ? 0.14 + 0.25 * padCard.glow : 0.18 * padCard.glow))
							border.width: padCard.number > 0 ? 2 : 1
							border.color: padCard.number > 0 ? padCard.tone : Theme.outline
							onClicked: padCard.number > 0 ? root.leave(padCard.modelData.id) : root.join(padCard.modelData)

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 12
								anchors.rightMargin: 8
								spacing: 10

								Rectangle {
									Layout.preferredWidth: 34
									Layout.preferredHeight: 34
									radius: 17
									color: padCard.number > 0 ? padCard.tone : Theme.layer2

									Glyph {
										anchors.centerIn: parent
										visible: padCard.number === 0
										icon: "gamepad_variant"
										size: 18
										color: Theme.textMuted
										surface: parent.color
									}

									StyledText {
										anchors.centerIn: parent
										visible: padCard.number > 0
										text: `P${padCard.number}`
										tone: "#101418"
										surface: parent.color
										font.pixelSize: Theme.size.body
										font.weight: Font.Black
									}
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 1

									StyledText {
										Layout.fillWidth: true
										text: padCard.modelData.name
										tone: Theme.text
										surface: "transparent"
										elide: Text.ElideRight
										font.pixelSize: Theme.size.body
										font.weight: Font.DemiBold
									}

									StyledText {
										Layout.fillWidth: true
										text: padCard.number > 0 ? (root.players[padCard.number - 1]?.profile ?? "") : "A to join"
										tone: Theme.textSubtle
										surface: "transparent"
										elide: Text.ElideRight
										font.pixelSize: Theme.size.small
									}
								}

								StyledText {
									visible: padCard.modelData.battery >= 0
									text: `${padCard.modelData.battery}%`
									tone: padCard.modelData.battery <= 15 ? Theme.danger : Theme.textSubtle
									surface: "transparent"
									font.pixelSize: Theme.size.small
								}

								IconButton {
									implicitWidth: 32
									implicitHeight: 32
									visible: !!padCard.modelData.rumble
									icon: "vibrate"
									onClicked: Party.rumble(padCard.modelData.id)
								}
							}
						}
					}
				}

				// ── the screens ────────────────────────────────────────────
				ColumnLayout {
					Layout.fillWidth: true
					Layout.alignment: Qt.AlignTop
					spacing: 10

					SectionLabel {
						text: "Screens"
					}

					Item {
						id: map

						readonly property real minX: Math.min(...root.screens.map(screen => screen.x))
						readonly property real minY: Math.min(...root.screens.map(screen => screen.y))
						readonly property real spanX: Math.max(1, Math.max(...root.screens.map(screen => screen.x + screen.width)) - map.minX)
						readonly property real spanY: Math.max(1, Math.max(...root.screens.map(screen => screen.y + screen.height)) - map.minY)
						readonly property real factor: Math.min(map.width / map.spanX, 300 / map.spanY)
						readonly property real offsetX: (map.width - map.spanX * map.factor) / 2
						// the tile carried by the pointer: {padId, x, y}
						property var carried: null

						Layout.fillWidth: true
						Layout.preferredHeight: map.spanY * map.factor + 8

						// where a point of the map falls: {screen, padId}
						function hit(x, y) {
							for (let i = 0; i < screenTiles.count; i++) {
								const tile = screenTiles.itemAt(i);
								if (!tile || x < tile.x || y < tile.y || x > tile.x + tile.width || y > tile.y + tile.height) continue;
								const on = root.playersOn(tile.name);
								const rects = root.rects(on.length, root.layoutOf(tile.name, on.length));
								const fx = (x - tile.x) / tile.width;
								const fy = (y - tile.y) / tile.height;
								for (let j = 0; j < on.length; j++) {
									const r = rects[j];
									if (fx >= r[0] && fx <= r[0] + r[2] && fy >= r[1] && fy <= r[1] + r[3]) return { screen: tile.name, padId: on[j].padId };
								}
								return { screen: tile.name, padId: "" };
							}
							return null;
						}

						Repeater {
							id: screenTiles

							model: root.screens

							delegate: Rectangle {
								id: screenTile

								required property var modelData
								readonly property string name: screenTile.modelData.name
								readonly property var on: root.playersOn(screenTile.name)
								readonly property var rects: root.rects(screenTile.on.length, root.layoutOf(screenTile.name, screenTile.on.length))
								readonly property bool target: !!map.carried && map.carried.screen === screenTile.name

								x: map.offsetX + (screenTile.modelData.x - map.minX) * map.factor + 4
								y: (screenTile.modelData.y - map.minY) * map.factor + 4
								width: screenTile.modelData.width * map.factor - 8
								height: screenTile.modelData.height * map.factor - 8
								radius: Theme.radius.medium
								color: Theme.layer1
								border.width: screenTile.target ? 2 : 1
								border.color: screenTile.target ? Theme.primary : Theme.outline

								StyledText {
									anchors.left: parent.left
									anchors.bottom: parent.bottom
									anchors.margins: 8
									visible: screenTile.on.length === 0
									text: screenTile.name
									tone: Theme.textSubtle
									surface: screenTile.color
									font.pixelSize: Theme.size.small
								}

								// the players' windows
								Repeater {
									model: screenTile.on

									delegate: Rectangle {
										id: tile

										required property var modelData
										required property int index
										readonly property var r: screenTile.rects[tile.index] ?? [0, 0, 1, 1]
										readonly property color tone: root.colorOf(tile.modelData.padId)
										readonly property bool gone: !root.padsById[tile.modelData.padId]
										readonly property bool carried: !!map.carried && map.carried.padId === tile.modelData.padId
										readonly property real glow: root.glow(tile.modelData.padId)

										x: tile.r[0] * screenTile.width + 3
										y: tile.r[1] * screenTile.height + 3
										width: tile.r[2] * screenTile.width - 6
										height: tile.r[3] * screenTile.height - 6
										radius: Theme.radius.small
										color: Qt.alpha(tile.tone, tile.gone ? 0.12 : 0.3 + 0.35 * tile.glow)
										border.width: 2
										border.color: tile.gone ? Theme.textFaint : tile.tone
										opacity: tile.carried ? 0.35 : 1

										Behavior on x {
											SpatialAnim {
												duration: Motion.medium
											}
										}
										Behavior on y {
											SpatialAnim {
												duration: Motion.medium
											}
										}
										Behavior on width {
											SpatialAnim {
												duration: Motion.medium
											}
										}
										Behavior on height {
											SpatialAnim {
												duration: Motion.medium
											}
										}

										ColumnLayout {
											anchors.centerIn: parent
											width: parent.width - 12
											spacing: 0

											StyledText {
												Layout.fillWidth: true
												horizontalAlignment: Text.AlignHCenter
												text: `P${root.numberOf(tile.modelData.padId)}`
												tone: Theme.text
												surface: "transparent"
												font.pixelSize: Math.max(12, Math.min(26, tile.height * 0.3))
												font.weight: Font.Black
											}

											StyledText {
												Layout.fillWidth: true
												visible: tile.height > 46
												horizontalAlignment: Text.AlignHCenter
												text: tile.gone ? "Controller off" : tile.modelData.profile
												tone: tile.gone ? Theme.danger : Theme.textMuted
												surface: "transparent"
												elide: Text.ElideRight
												font.pixelSize: Theme.size.small
											}
										}

										MouseArea {
											anchors.fill: parent
											cursorShape: map.carried ? Qt.ClosedHandCursor : Qt.OpenHandCursor
											property point from

											onPressed: mouse => from = Qt.point(mouse.x, mouse.y)
											onPositionChanged: mouse => {
												const point = mapToItem(map, mouse.x, mouse.y);
												if (!map.carried && Math.hypot(mouse.x - from.x, mouse.y - from.y) < 6) return;
												const at = map.hit(point.x, point.y);
												map.carried = { padId: tile.modelData.padId, x: point.x, y: point.y, w: tile.width, h: tile.height, screen: at?.screen ?? "" };
											}
											onReleased: mouse => {
												if (!map.carried) return;
												const point = mapToItem(map, mouse.x, mouse.y);
												const at = map.hit(point.x, point.y);
												const padId = tile.modelData.padId;
												map.carried = null;
												if (!at) return;
												if (at.padId && at.padId !== padId) root.swap(padId, at.padId);
												else if (!at.padId || at.screen !== screenTile.name) root.moveTo(padId, at.screen);
												Sounds.play("click");
											}
										}
									}
								}

								// the screen's layout, when it has players to lay out
								IconButton {
									anchors.right: parent.right
									anchors.bottom: parent.bottom
									anchors.margins: 4
									implicitWidth: 28
									implicitHeight: 28
									visible: root.presets(screenTile.on.length).length > 1
									variant: "tonal"
									icon: "view_grid_outline"
									onClicked: root.cycleLayout(screenTile.name)
								}
							}
						}

						// the carried tile under the pointer
						Rectangle {
							visible: !!map.carried
							x: (map.carried?.x ?? 0) - width / 2
							y: (map.carried?.y ?? 0) - height / 2
							width: Math.max(40, (map.carried?.w ?? 0) * 0.8)
							height: Math.max(28, (map.carried?.h ?? 0) * 0.8)
							radius: Theme.radius.small
							color: Qt.alpha(root.colorOf(map.carried?.padId ?? ""), 0.55)
							border.width: 2
							border.color: root.colorOf(map.carried?.padId ?? "")

							StyledText {
								anchors.centerIn: parent
								text: `P${root.numberOf(map.carried?.padId ?? "")}`
								tone: Theme.text
								surface: "transparent"
								font.weight: Font.Black
							}
						}
					}

					// the players' names: PartyDeck's profiles, their saves kept per name
					Flow {
						Layout.fillWidth: true
						Layout.topMargin: 4
						spacing: 10
						visible: root.players.length > 0

						Repeater {
							model: root.players

							delegate: RowLayout {
								id: nameRow

								required property var modelData
								required property int index

								spacing: 6

								Rectangle {
									Layout.preferredWidth: 26
									Layout.preferredHeight: 26
									radius: 13
									color: root.colors[nameRow.index % root.colors.length]

									StyledText {
										anchors.centerIn: parent
										text: `${nameRow.index + 1}`
										tone: "#101418"
										surface: parent.color
										font.pixelSize: Theme.size.small
										font.weight: Font.Black
									}
								}

								Field {
									id: nameField

									Layout.preferredWidth: 150
									text: nameRow.modelData.profile
									clearable: false

									// taken when the field is left: the list is not rebuilt under the typing
									Connections {
										target: nameField.input

										function onEditingFinished() {
											const name = nameField.text.trim();
											if (name !== "" && name !== nameRow.modelData.profile) root.setProfile(nameRow.modelData.padId, name);
										}
									}
								}
							}
						}
					}
				}
			}

			// ── what went wrong ────────────────────────────────────────────
			StyledText {
				Layout.fillWidth: true
				visible: text !== ""
				text: Party.error !== "" ? Party.error : ((root.info?.missing ?? []).length > 0 ? `Missing: ${root.info.missing.join(", ")}` : "")
				tone: Theme.danger
				surface: "transparent"
				wrapMode: Text.WordWrap
				font.pixelSize: Theme.size.body
			}

			// ── how it starts, and start ───────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				Chip {
					visible: (root.info?.programs ?? []).length > 1
					icon: "application_outline"
					text: root.exec
					onClicked: {
						const list = root.info.programs;
						root.exec = list[(list.indexOf(root.exec) + 1) % list.length];
					}
				}

				RowLayout {
					visible: !!root.info?.steamApi
					spacing: 8

					Toggle {
						checked: root.goldberg
						onToggled: checked => root.goldberg = checked
					}

					StyledText {
						text: "Goldberg"
						tone: Theme.textMuted
						surface: "transparent"
						font.pixelSize: Theme.size.body
					}
				}

				Item {
					Layout.fillWidth: true
				}

				Spinner {
					implicitWidth: 22
					implicitHeight: 22
					visible: Party.loading
				}

				TextButton {
					variant: "ghost"
					text: "PartyDeck"
					visible: !!root.info?.partydeck
					onClicked: {
						Quickshell.execDetached(["partydeck"]);
						root.close();
						Popups.closeModal();
					}
				}

				TextButton {
					variant: "filled"
					implicitHeight: 40
					text: Party.starting ? "Starting" : "Start"
					icon: "play"
					busy: Party.starting
					enabled: root.canStart
					onClicked: root.start()
				}
			}
		}
	}
}
