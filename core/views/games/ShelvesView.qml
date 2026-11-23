pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views
import "../../lib/GameText.js" as GameText

// The library as shelves under the picked game (the library's own details
// stand above): the user's own shelves first (Games.shelves, in their
// order), then one per genre (Steam's store), the games without one last.
//
// The shelf walked stays at the top and is big, its picked cover grown;
// the shelves after it wait small below, each where it was left. A shelf
// moves along only as far as the picked cover and its neighbours need. A
// click picks a cover; the wheel walks the shelves, sideways (tilt, touchpad)
// the covers of the shelf walked. The rail at the right names them
// all: a click goes there, a cover dropped on it goes onto that shelf.
//
// A cover is dragged onto a shelf of the user's: from another of theirs it
// moves (Ctrl keeps it there as well), within one it changes place, from a
// genre it is put there too; dragged off a shelf of the user's it leaves
// it. Dropped on "New shelf" it starts one.
Item {
	id: root

	// what the library shows (filters, search, sort)
	property var list: []
	property string selectedId: ""
	property color accent: Theme.primary
	property real side: 48
	property real cell: 150
	property bool active: false

	// the row walked, and the cover each row was left on
	property string currentRow: ""
	property var picks: ({})
	// the user's shelf whose name is being typed
	property string renaming: ""

	signal picked(string id)
	signal activated(var game)
	signal menuAsked(var game, string shelfId, real x, real y)
	signal shelfMenuAsked(string shelfId, real x, real y)

	readonly property real headH: 46
	readonly property real smallCell: Math.round(Math.max(88, Math.min(130, root.cell * 0.62)))
	readonly property real smallH: root.headH + root.smallCell * 1.5 + 22
	// the shelf walked takes what is left above one small shelf
	readonly property real bigCell: Math.round(Math.max(104, Math.min(root.cell, (flick.height - root.headH - 34 - root.smallH * 0.7) / 1.5 / 1.22)))
	readonly property real grow: 1.22
	readonly property real bigH: root.headH + root.bigCell * root.grow * 1.5 + 34
	readonly property real railW: root.width >= 1300 ? 240 : 0

	readonly property var byId: {
		const map = {};
		for (const game of root.list)
			map[game.id] = game;
		return map;
	}

	readonly property var rows: {
		const out = [];
		for (const shelf of Games.shelves)
			out.push({ key: `own:${shelf.id}`, own: true, shelfId: shelf.id, name: shelf.name, icon: "bookmark_multiple_outline", games: shelf.games.filter(id => root.byId[id]) });
		const genres = {};
		for (const game of root.list)
			for (const genre of game.genres ?? [])
				(genres[genre] = genres[genre] ?? []).push(game.id);
		for (const genre of Object.keys(genres).sort((a, b) => genres[b].length - genres[a].length || a.localeCompare(b)))
			out.push({ key: `genre:${genre}`, name: genre, icon: root.genreIcon(genre), games: genres[genre] });
		const none = root.list.filter(game => !(game.genres?.length > 0)).map(game => game.id);
		if (none.length > 0) out.push({ key: "genre:", name: "Other", icon: "shape_outline", games: none });
		return out;
	}

	readonly property var walkable: root.rows.filter(row => row.games.length > 0)
	readonly property var current: root.rows.find(row => row.key === root.currentRow) ?? null

	function genreIcon(genre) {
		return ({
				"Action": "sword",
				"Adventure": "map_outline",
				"RPG": "magic_staff",
				"Strategy": "brain",
				"Simulation": "cog_outline",
				"Casual": "puzzle",
				"Racing": "flag_checkered",
				"Sports": "trophy_outline"
			})[genre] ?? "gamepad_variant";
	}

	// a shelf's colour: the one of the game it was left on
	function rowAccent(row) {
		const id = row.key === root.currentRow ? root.selectedId : (root.picks[row.key] ?? row.games[0]);
		return GameText.accent(root.byId[id], root.accent);
	}

	SyncedModel {
		id: rowModel
	}

	onRowsChanged: {
		rowModel.sync(root.rows);
		root.keepCurrent();
	}
	onSelectedIdChanged: root.keepCurrent()

	// the picked game stays in its row when it is there, else the first row with it
	function keepCurrent() {
		const row = root.rows.find(each => each.key === root.currentRow);
		if (!row || row.games.indexOf(root.selectedId) < 0) {
			const other = root.rows.find(each => each.games.indexOf(root.selectedId) >= 0);
			root.currentRow = other ? other.key : "";
		}
		root.remember();
	}

	function remember() {
		if (root.currentRow === "" || root.picks[root.currentRow] === root.selectedId) return;
		const next = Object.assign({}, root.picks);
		next[root.currentRow] = root.selectedId;
		root.picks = next;
	}

	function rowItem(key) {
		for (let i = 0; i < rowRepeater.count; i++) {
			const item = rowRepeater.itemAt(i);
			if (item && item.rowKey === key) return item;
		}
		return null;
	}

	function pick(rowKey, id) {
		if (rowKey !== root.currentRow) Sounds.play("navigate");
		root.currentRow = rowKey;
		root.picked(id);
		root.remember();
	}

	// the top shelf from its first cover, as on opening
	function goTop() {
		root.picks = {};
		const row = root.walkable[0];
		if (!row) return;
		root.currentRow = row.key;
		root.picked(row.games[0]);
		root.remember();
	}

	// a row, on the cover it was left on
	function goRow(key) {
		const row = root.rows.find(each => each.key === key);
		if (!row || row.games.length === 0) return;
		const kept = root.picks[key];
		root.pick(key, row.games.indexOf(kept) >= 0 ? kept : row.games[0]);
	}

	// left / right within the row
	function step(delta) {
		const row = root.current ?? root.walkable[0];
		if (!row) return;
		const at = row.games.indexOf(root.selectedId);
		const next = Math.max(0, Math.min(row.games.length - 1, at + delta));
		if (row.games[next] !== root.selectedId) Sounds.play("select");
		root.pick(row.key, row.games[next]);
	}

	function edge(last) {
		const row = root.current;
		if (row) root.pick(row.key, row.games[last ? row.games.length - 1 : 0]);
	}

	// up / down to the next row with games
	function stepRow(delta) {
		if (root.walkable.length === 0) return false;
		const at = root.walkable.findIndex(each => each.key === root.currentRow);
		if (at < 0) {
			root.goRow(root.walkable[0].key);
			return true;
		}
		const to = Math.max(0, Math.min(root.walkable.length - 1, at + delta));
		if (to === at) return false;
		root.goRow(root.walkable[to].key);
		return true;
	}

	readonly property bool atFirst: root.walkable.length === 0 || root.walkable[0].key === root.currentRow

	// the card of the picked game, for the launch to fly from
	function currentCard() {
		return root.rowItem(root.currentRow)?.cardOf(root.selectedId) ?? null;
	}

	function reveal() {
		root.keepCurrent();
	}

	function startRename(shelfId) {
		root.renaming = shelfId;
		const row = root.rows.find(each => each.key === `own:${shelfId}`);
		if (row && row.games.length > 0) root.goRow(row.key);
		else root.currentRow = `own:${shelfId}`;
		Qt.callLater(() => root.rowItem(`own:${shelfId}`)?.focusName());
	}

	function newShelf(gameIds) {
		const id = Games.newShelf("New shelf", gameIds, Games.shelves.length > 0 ? Games.shelves[Games.shelves.length - 1].id : "");
		Sounds.play("toggleOn");
		Qt.callLater(() => root.startRename(id));
		return id;
	}

	// a step along a row, which becomes the one walked
	function stepIn(key, delta) {
		const row = root.rows.find(each => each.key === key);
		if (!row || row.games.length === 0) return;
		const from = key === root.currentRow ? root.selectedId : (root.picks[key] ?? row.games[0]);
		const at = Math.max(0, row.games.indexOf(from));
		const next = key === root.currentRow ? Math.max(0, Math.min(row.games.length - 1, at + delta)) : at;
		if (row.games[next] !== root.selectedId) Sounds.play("select");
		root.pick(key, row.games[next]);
	}

	// ── the wheel: up and down the shelves, sideways (a tilt or a touchpad)
	// the covers of the shelf walked
	property real wheelX: 0
	property real wheelY: 0

	// a WheelHandler takes one axis; a touchpad's swipe goes the way it goes most
	WheelHandler {
		acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
		orientation: Qt.Vertical
		onWheel: event => {
			if (Math.abs(event.angleDelta.x) > Math.abs(event.angleDelta.y)) return;
			root.wheelX = 0;
			root.wheelY += event.angleDelta.y;
			if (Math.abs(root.wheelY) < 120) return;
			const steps = Math.trunc(root.wheelY / 120);
			root.wheelY -= steps * 120;
			for (let i = 0; i < Math.abs(steps); i++)
				root.stepRow(steps > 0 ? -1 : 1);
		}
	}

	WheelHandler {
		acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
		orientation: Qt.Horizontal
		onWheel: event => {
			if (Math.abs(event.angleDelta.x) <= Math.abs(event.angleDelta.y)) return;
			root.wheelY = 0;
			root.wheelX += event.angleDelta.x;
			if (Math.abs(root.wheelX) < 120) return;
			const steps = Math.trunc(root.wheelX / 120);
			root.wheelX -= steps * 120;
			for (let i = 0; i < Math.abs(steps); i++)
				root.stepIn(root.currentRow, steps > 0 ? -1 : 1);
		}
	}

	// ── dragging a cover ───────────────────────────────────────────────────
	property var dragGame: null
	property string dragFrom: ""
	property string dropRow: ""
	property int dropIndex: -1
	property bool dropNew: false
	property bool dragCopy: false
	property point dragAt: Qt.point(0, 0)
	property point grabOffset: Qt.point(0, 0)
	property real dragW: root.bigCell
	readonly property bool dragging: root.dragGame !== null
	// a cover from a shelf of the user's dropped elsewhere leaves it
	readonly property bool dragLeaves: root.dragging && root.dragFrom.startsWith("own:") && root.dropRow === "" && !root.dropNew && !root.dragCopy

	function beginDrag(game, rowKey, card, scene) {
		const local = card.mapFromItem(null, scene.x, scene.y);
		root.grabOffset = Qt.point(local.x, local.y);
		root.dragW = card.width;
		root.dragGame = game;
		root.dragFrom = rowKey;
		root.moveDrag(scene, 0);
		Sounds.play("select");
	}

	function moveDrag(scene, modifiers) {
		if (!root.dragging) return;
		root.dragCopy = !!(modifiers & Qt.ControlModifier);
		const at = root.mapFromItem(null, scene.x, scene.y);
		root.dragAt = at;
		let row = "", index = -1, adding = false;
		// the rail: a shelf's name takes it at its end
		const onRail = rail.hit(at);
		if (onRail === "new") adding = true;
		else if (onRail.startsWith("own:")) row = onRail;
		else if (onRail === "") {
			for (let i = 0; i < rowRepeater.count; i++) {
				const item = rowRepeater.itemAt(i);
				if (!item) continue;
				const local = item.mapFromItem(root, at.x, at.y);
				if (local.y < 0 || local.y > item.height || local.x > item.width) continue;
				if (item.own) {
					row = item.rowKey;
					index = item.indexAt(local.x);
				}
				break;
			}
		}
		root.dropRow = row;
		root.dropIndex = index;
		root.dropNew = adding;
	}

	function endDrag(apply) {
		const game = root.dragGame;
		const fromShelf = root.dragFrom.startsWith("own:") ? root.dragFrom.slice(4) : "";
		const row = root.dropRow;
		const index = root.dropIndex;
		const adding = root.dropNew;
		const copy = root.dragCopy;
		root.dragGame = null;
		root.dropRow = "";
		root.dropIndex = -1;
		root.dropNew = false;
		if (!apply || !game) return;
		// after the drag handler is done: the card it sits on may go
		Qt.callLater(() => root.drop(game, fromShelf, row, index, adding, copy));
	}

	function drop(game, fromShelf, row, index, adding, copy) {
		if (adding) {
			root.newShelf([game.id]);
			if (fromShelf !== "" && !copy) Games.unshelve(fromShelf, game.id);
			return;
		}
		if (row !== "") {
			const to = row.slice(4);
			if (fromShelf !== "" && fromShelf !== to && !copy) Games.moveBetween(fromShelf, to, game.id, index);
			else Games.shelve(to, game.id, index);
			Sounds.play(fromShelf === to ? "select" : "toggleOn");
			return;
		}
		if (fromShelf !== "" && !copy) {
			Games.unshelve(fromShelf, game.id);
			Sounds.play("toggleOff");
		}
	}

	// held at the bottom or the top while dragging: the shelves move along
	Timer {
		interval: 700
		repeat: true
		running: root.dragging
		onTriggered: {
			if (root.dragAt.x > flick.width) return;
			if (root.dragAt.y > flick.height - 60) root.stepRow(1);
			else if (root.dragAt.y < 30) root.stepRow(-1);
		}
	}

	// the shelves below read on the picture: it darkens towards the bottom
	Rectangle {
		anchors.fill: parent
		anchors.topMargin: root.bigH * 0.6
		anchors.bottomMargin: -80
		gradient: Gradient {
			GradientStop {
				position: 0
				color: Qt.rgba(0, 0, 0, 0)
			}
			GradientStop {
				position: 1
				color: Qt.rgba(0, 0, 0, 0.6)
			}
		}
	}

	// ── the shelves ────────────────────────────────────────────────────────
	Flickable {
		id: flick

		property real target: 0

		x: 0
		width: root.width - root.railW - (root.railW > 0 ? 24 : 0)
		height: root.height
		contentWidth: width
		contentHeight: column.height + root.height
		interactive: false
		clip: true
		contentY: flick.target

		Behavior on contentY {
			SpatialAnim {
				duration: Motion.long
			}
		}

		Column {
			id: column

			width: flick.width

			onHeightChanged: root.rowItem(root.currentRow)?.follow()

			Repeater {
				id: rowRepeater

				model: rowModel

				delegate: Item {
					id: shelfRow

					required property string json
					required property int index
					readonly property var row: JSON.parse(shelfRow.json)
					readonly property string rowKey: shelfRow.row.key
					readonly property bool own: !!shelfRow.row.own
					readonly property string shelfId: shelfRow.row.shelfId ?? ""
					readonly property bool focused: root.currentRow === shelfRow.rowKey
					readonly property bool target: root.dropRow === shelfRow.rowKey
					// the rows passed are out of sight above
					readonly property bool passed: shelfRow.y + 2 < flick.contentY
					readonly property string pickedId: shelfRow.focused ? root.selectedId : (root.picks[shelfRow.rowKey] ?? "")
					readonly property int pickedIndex: Math.max(0, shelfRow.row.games.indexOf(shelfRow.pickedId))
					readonly property real c: shelfRow.focused ? root.bigCell : root.smallCell
					readonly property real gap: shelfRow.focused ? 22 : 14
					readonly property color tint: root.rowAccent(shelfRow.row)
					readonly property int minutes: shelfRow.row.games.reduce((sum, id) => sum + (root.byId[id]?.playtime ?? 0), 0)
					property real appear: 0

					width: column.width
					height: shelfRow.focused ? root.bigH : root.smallH
					opacity: shelfRow.appear * (shelfRow.passed ? 0 : 1)

					Behavior on height {
						SpatialAnim {
							duration: Motion.long
						}
					}
					Behavior on opacity {
						Anim {
							duration: Motion.medium
						}
					}

					// the walked shelf is where the shelves scroll to; the last ones
					// do not leave the space under them empty
					function follow() {
						if (shelfRow.focused) flick.target = Math.max(0, Math.min(shelfRow.y, column.height - flick.height));
					}

					onYChanged: shelfRow.follow()
					onFocusedChanged: shelfRow.follow()
					onHeightChanged: shelfRow.follow()

					Component.onCompleted: {
						appearAnim.start();
						shelfRow.syncCards();
						shelfRow.follow();
					}

					SequentialAnimation {
						id: appearAnim

						PauseAnimation {
							duration: Math.max(0, Math.min(shelfRow.index, 6)) * 60
						}
						NumberAnimation {
							target: shelfRow
							property: "appear"
							to: 1
							duration: Motion.long
							easing.type: Easing.OutCubic
						}
					}

					function cardOf(id) {
						const at = shelfRow.row.games.indexOf(id);
						return at >= 0 ? cards.itemAtIndex(at)?.card ?? null : null;
					}

					// where a cover dropped at x (in the row) goes
					function indexAt(x) {
						const inList = x + cards.contentX - cards.originX;
						return Math.max(0, Math.min(shelfRow.row.games.length, Math.floor((inList - shelfRow.c / 2) / (shelfRow.c + shelfRow.gap)) + 1));
					}

					// from the json itself: `row` may not have followed it yet
					function syncCards() {
						cardModel.sync(JSON.parse(shelfRow.json).games.map(id => Object.assign({ key: id }, root.byId[id])));
					}

					function focusName() {
						nameField.input.forceActiveFocus();
						nameField.input.selectAll();
					}

					onJsonChanged: shelfRow.syncCards()

					Connections {
						target: root

						function onByIdChanged() {
							shelfRow.syncCards();
						}
					}

					// ── its name ───────────────────────────────────────────
					Item {
						id: head

						x: root.side
						width: shelfRow.width - root.side
						height: root.headH

						Row {
							anchors.verticalCenter: parent.verticalCenter
							spacing: 12
							visible: !(shelfRow.own && root.renaming === shelfRow.shelfId)

							Rectangle {
								anchors.verticalCenter: parent.verticalCenter
								width: shelfRow.focused ? 34 : 28
								height: width
								radius: width / 2
								color: Qt.alpha(shelfRow.tint, shelfRow.focused ? 0.28 : 0.14)
								border.width: 1
								border.color: Qt.alpha(shelfRow.tint, shelfRow.focused ? 0.6 : 0.25)

								Behavior on width {
									SpatialAnim {
										duration: Motion.medium
									}
								}
								Behavior on color {
									ColorAnim {}
								}

								Glyph {
									anchors.centerIn: parent
									icon: shelfRow.row.icon
									size: parent.width * 0.52
									color: shelfRow.focused ? shelfRow.tint : Qt.rgba(1, 1, 1, 0.7)
									surface: "transparent"
								}
							}

							StyledText {
								id: nameText

								anchors.verticalCenter: parent.verticalCenter
								text: shelfRow.row.name
								tone: shelfRow.focused ? "white" : Qt.rgba(1, 1, 1, 0.7)
								surface: "transparent"
								font.pixelSize: shelfRow.focused ? Theme.size.title + 6 : Theme.size.title
								font.weight: shelfRow.focused ? Font.Black : Font.Bold

								MouseArea {
									anchors.fill: parent
									acceptedButtons: Qt.LeftButton | Qt.RightButton
									cursorShape: Qt.PointingHandCursor
									onClicked: event => {
										if (event.button === Qt.RightButton && shelfRow.own) {
											const at = mapToItem(null, event.x, event.y);
											root.shelfMenuAsked(shelfRow.shelfId, at.x, at.y);
										} else {
											root.goRow(shelfRow.rowKey);
										}
									}
									onDoubleClicked: if (shelfRow.own) root.startRename(shelfRow.shelfId)
								}
							}

							// how many, how long
							Rectangle {
								anchors.verticalCenter: parent.verticalCenter
								width: countText.implicitWidth + 16
								height: 22
								radius: 11
								color: shelfRow.target ? Qt.alpha(root.accent, 0.35) : Qt.rgba(1, 1, 1, 0.08)

								StyledText {
									id: countText

									anchors.centerIn: parent
									text: shelfRow.minutes >= 60 ? `${shelfRow.row.games.length} · ${GameText.short(shelfRow.minutes)}` : `${shelfRow.row.games.length}`
									tone: Qt.rgba(1, 1, 1, 0.75)
									surface: "transparent"
									font.pixelSize: Theme.size.small
									font.weight: Font.Bold
								}
							}

							IconButton {
								anchors.verticalCenter: parent.verticalCenter
								visible: shelfRow.own
								implicitWidth: 30
								implicitHeight: 30
								icon: "dots_horizontal"
								iconColor: Qt.rgba(1, 1, 1, 0.6)
								onClicked: {
									const at = mapToItem(null, 0, height + 6);
									root.shelfMenuAsked(shelfRow.shelfId, at.x, at.y);
								}
							}
						}

						Field {
							id: nameField

							anchors.verticalCenter: parent.verticalCenter
							visible: shelfRow.own && root.renaming === shelfRow.shelfId
							width: 360
							implicitHeight: 40
							icon: "pencil_outline"
							color: Qt.rgba(1, 1, 1, 0.12)
							text: shelfRow.row.name
							clearable: false
							onVisibleChanged: if (visible) nameField.text = shelfRow.row.name
							onAccepted: {
								Games.renameShelf(shelfRow.shelfId, nameField.text);
								root.renaming = "";
							}
							onEscapePressed: root.renaming = ""
							onFocusedChanged: if (!nameField.focused && root.renaming === shelfRow.shelfId) {
								Games.renameShelf(shelfRow.shelfId, nameField.text);
								root.renaming = "";
							}
						}
					}

					// where a dragged cover would land: the shelf lights up
					Rectangle {
						visible: shelfRow.own && root.dragging
						x: root.side - 16
						y: root.headH - 4
						width: shelfRow.width - root.side + 8
						height: shelfRow.height - root.headH - 4
						radius: Theme.radius.large + 6
						color: Qt.alpha(root.accent, shelfRow.target ? 0.14 : 0.03)
						border.width: shelfRow.target ? 1.5 : 1
						border.color: shelfRow.target ? root.accent : Qt.rgba(1, 1, 1, 0.12)

						Behavior on color {
							ColorAnim {}
						}
					}

					// an empty shelf of the user's: where a cover would stand
					Rectangle {
						visible: shelfRow.own && shelfRow.row.games.length === 0 && !shelfRow.target
						x: root.side
						y: root.headH + 8
						width: shelfRow.c
						height: shelfRow.c * 1.5
						radius: Theme.radius.large
						color: Qt.rgba(1, 1, 1, 0.03)
						border.width: 1.5
						border.color: Qt.rgba(1, 1, 1, 0.16)

						Glyph {
							anchors.centerIn: parent
							icon: "drag"
							size: 28
							color: Qt.rgba(1, 1, 1, 0.3)
							surface: "transparent"
						}
					}

					// the board the walked shelf's covers stand on
					Item {
						x: root.side - 10
						y: cards.y + cards.height - 12
						width: shelfRow.width - root.side
						height: 24
						opacity: shelfRow.focused ? 1 : 0

						Behavior on opacity {
							Anim {
								duration: Motion.long
							}
						}

						Rectangle {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							height: 18
							radius: 9
							opacity: 0.5
							gradient: Gradient {
								orientation: Gradient.Horizontal
								GradientStop {
									position: 0
									color: Qt.alpha(shelfRow.tint, 0.55)
								}
								GradientStop {
									position: 0.6
									color: Qt.alpha(shelfRow.tint, 0.12)
								}
								GradientStop {
									position: 1
									color: Qt.alpha(shelfRow.tint, 0)
								}
							}
							layer.enabled: true
							layer.effect: MultiEffect {
								blurEnabled: true
								blur: 1
								blurMax: 24
							}
						}

						Rectangle {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							height: 1.5
							gradient: Gradient {
								orientation: Gradient.Horizontal
								GradientStop {
									position: 0
									color: Qt.alpha(Qt.lighter(shelfRow.tint, 1.3), 0.9)
								}
								GradientStop {
									position: 0.7
									color: Qt.alpha(shelfRow.tint, 0.2)
								}
								GradientStop {
									position: 1
									color: Qt.alpha(shelfRow.tint, 0)
								}
							}
						}
					}

					SyncedModel {
						id: cardModel
					}

					ListView {
						id: cards

						// where the row is moved to: as little as the picked cover and
						// its neighbours need to be seen
						property real wanted: -root.side

						function keep() {
							const n = shelfRow.row.games.length;
							const unit = shelfRow.c + shelfRow.gap;
							const extra = shelfRow.focused ? shelfRow.c * (root.grow - 1) : 0;
							const left = Math.max(0, shelfRow.pickedIndex - 1) * unit;
							const last = Math.min(n - 1, shelfRow.pickedIndex + 1);
							const right = last * unit + shelfRow.c + extra;
							let x = cards.wanted;
							if (left - root.side < x) x = left - root.side;
							else if (right + root.side > x + cards.width) x = right + root.side - cards.width;
							const most = Math.max(-root.side, n * unit + extra + root.side - cards.width);
							cards.wanted = Math.max(-root.side, Math.min(most, x));
						}

						Connections {
							target: shelfRow

							// after the sizes followed
							function onPickedIndexChanged() {
								Qt.callLater(cards.keep);
							}
							function onFocusedChanged() {
								Qt.callLater(cards.keep);
							}
						}
						onWidthChanged: cards.keep()
						onCountChanged: cards.keep()
						Component.onCompleted: cards.keep()

						y: root.headH
						width: shelfRow.width
						height: shelfRow.height - root.headH - (shelfRow.focused ? 14 : 8)
						orientation: ListView.Horizontal
						spacing: shelfRow.gap
						leftMargin: root.side
						rightMargin: root.side
						model: cardModel
						interactive: false
						cacheBuffer: shelfRow.c * 6
						contentX: cards.wanted

						Behavior on contentX {
							enabled: shelfRow.appear >= 1
							SpatialAnim {
								duration: Motion.long
							}
						}

						add: Transition {
							ParallelAnimation {
								Anim {
									property: "opacity"
									from: 0
									to: 1
									duration: Motion.long
								}
								SpatialAnim {
									property: "scale"
									from: 0.7
									to: 1
									duration: Motion.long
								}
							}
						}
						remove: Transition {
							ParallelAnimation {
								Anim {
									property: "opacity"
									to: 0
									duration: Motion.medium
								}
								Anim {
									property: "scale"
									to: 0.7
									duration: Motion.medium
								}
							}
						}
						displaced: Transition {
							SpatialAnim {
								property: "x"
								duration: Motion.long
							}
						}

						delegate: Item {
							id: slot

							required property string json
							required property int index
							readonly property var modelData: JSON.parse(slot.json)
							readonly property bool picked: slot.index === shelfRow.pickedIndex
							readonly property bool lifted: root.dragging && root.dragGame?.id === slot.modelData.id && root.dragFrom === shelfRow.rowKey
							// the covers after the place a dragged one would go make room
							readonly property real room: shelfRow.target && root.dropIndex >= 0 && slot.index >= root.dropIndex ? shelfRow.c + shelfRow.gap : 0
							property alias card: card

							width: shelfRow.focused && slot.picked ? shelfRow.c * root.grow : shelfRow.c
							height: cards.height
							opacity: cardHover.hovered ? 1 : (shelfRow.focused ? (slot.picked ? 1 : 0.8) : 0.6)

							Behavior on width {
								SpatialAnim {
									duration: Motion.long
								}
							}
							Behavior on opacity {
								Anim {
									duration: Motion.long
								}
							}

							HoverHandler {
								id: cardHover
							}

							GameCard {
								id: card

								x: slot.room
								anchors.bottom: parent.bottom
								width: slot.width
								height: slot.width * 1.5
								game: slot.modelData
								current: root.active && shelfRow.focused && slot.picked
								floats: true
								clicks: false
								opacity: slot.lifted ? (root.dragLeaves ? 0.15 : 0.35) : 1
								onPicked: root.pick(shelfRow.rowKey, slot.modelData.id)
								onActivated: root.activated(slot.modelData)
								onMenuAsked: (x, y) => root.menuAsked(slot.modelData, shelfRow.shelfId, x, y)

								Behavior on x {
									SpatialAnim {
										duration: Motion.medium
									}
								}
								Behavior on opacity {
									Anim {}
								}
							}

							// on top of the card: a click picks it (the picked one plays), a drag moves it
							Item {
								anchors.fill: card

								TapHandler {
									acceptedButtons: Qt.LeftButton | Qt.RightButton
									gesturePolicy: TapHandler.DragThreshold
									onTapped: (point, button) => {
										if (button === Qt.RightButton) {
											root.pick(shelfRow.rowKey, slot.modelData.id);
											const at = parent.mapToItem(null, point.position.x, point.position.y);
											root.menuAsked(slot.modelData, shelfRow.shelfId, at.x, at.y);
										} else if (card.current) {
											root.activated(slot.modelData);
										} else {
											root.pick(shelfRow.rowKey, slot.modelData.id);
										}
									}
								}

								DragHandler {
									id: dragger

									target: null
									dragThreshold: 12
									onActiveChanged: {
										if (dragger.active) root.beginDrag(slot.modelData, shelfRow.rowKey, card, dragger.centroid.scenePosition);
										else root.endDrag(true);
									}
									onCentroidChanged: if (dragger.active) root.moveDrag(dragger.centroid.scenePosition, dragger.centroid.modifiers)
								}
							}
						}
					}
				}
			}
		}
	}

	// ── the rail: every shelf by name ──────────────────────────────────────
	Item {
		id: rail

		readonly property var items: {
			const out = [];
			for (const row of root.rows.filter(each => each.own))
				out.push(row);
			out.push({ key: "new", name: "New shelf", icon: "plus", games: [] });
			const rest = root.rows.filter(each => !each.own);
			if (rest.length > 0) out.push({ key: "line" });
			for (const row of rest)
				out.push(row);
			return out;
		}

		// the entry under a point of the view: its key, "" for none
		function hit(at) {
			if (!rail.visible) return "";
			const local = railColumn.mapFromItem(root, at.x, at.y);
			if (local.x < -12 || local.x > railColumn.width + 12) return "";
			for (let i = 0; i < railRepeater.count; i++) {
				const item = railRepeater.itemAt(i);
				if (item && item.key !== "line" && local.y >= item.y && local.y <= item.y + item.height) return item.key;
			}
			return "";
		}

		visible: root.railW > 0
		anchors.right: parent.right
		anchors.rightMargin: root.side - 12
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: root.railW - root.side + 12

		Flickable {
			anchors.fill: parent
			contentHeight: railColumn.height
			boundsBehavior: Flickable.StopAtBounds
			clip: true

			Column {
				id: railColumn

				width: parent.width
				spacing: 2

				Repeater {
					id: railRepeater

					model: rail.items

					delegate: Item {
						id: entry

						required property var modelData
						readonly property string key: entry.modelData.key
						readonly property bool on: entry.key === root.currentRow
						readonly property bool target: (entry.key === "new" && root.dropNew) || (entry.key !== "new" && root.dropRow === entry.key && rail.hit(root.dragAt) === entry.key)

						width: railColumn.width
						height: entry.key === "line" ? 17 : 38

						Rectangle {
							visible: entry.key === "line"
							anchors.centerIn: parent
							width: parent.width - 24
							height: 1
							color: Qt.rgba(1, 1, 1, 0.1)
						}

						Clickable {
							visible: entry.key !== "line"
							anchors.fill: parent
							radius: 12
							color: entry.target ? Qt.alpha(root.accent, 0.3) : (entry.on ? Qt.rgba(1, 1, 1, 0.1) : "transparent")
							tint: "white"
							sound: ""
							scale: entry.target ? 1.04 : 1
							onClicked: {
								if (entry.key === "new") root.newShelf([]);
								else root.goRow(entry.key);
							}

							Behavior on color {
								ColorAnim {}
							}
							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							// the shelf walked: a line in its colour
							Rectangle {
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								width: 3
								height: entry.on ? 18 : 0
								radius: 1.5
								color: root.accent

								Behavior on height {
									SpatialAnim {
										duration: Motion.medium
									}
								}
							}

							Row {
								anchors.left: parent.left
								anchors.leftMargin: 14
								anchors.right: parent.right
								anchors.rightMargin: 12
								anchors.verticalCenter: parent.verticalCenter
								spacing: 10

								Glyph {
									anchors.verticalCenter: parent.verticalCenter
									icon: entry.modelData.icon ?? "shape_outline"
									size: 17
									color: entry.on ? root.accent : Qt.rgba(1, 1, 1, entry.key === "new" ? 0.75 : 0.5)
									surface: "transparent"
								}

								StyledText {
									anchors.verticalCenter: parent.verticalCenter
									width: parent.width - 27 - railCount.width - 10
									text: entry.modelData.name ?? ""
									tone: entry.on ? "white" : Qt.rgba(1, 1, 1, entry.key === "new" ? 0.75 : 0.6)
									surface: "transparent"
									elide: Text.ElideRight
									font.pixelSize: Theme.size.body
									font.weight: entry.on ? Font.Bold : Font.Medium
								}

								StyledText {
									id: railCount

									anchors.verticalCenter: parent.verticalCenter
									visible: entry.key !== "new"
									text: entry.modelData.games?.length ?? 0
									tone: Qt.rgba(1, 1, 1, 0.35)
									surface: "transparent"
									font.pixelSize: Theme.size.small
									font.weight: Font.Bold
								}
							}
						}
					}
				}
			}
		}
	}

	// ── the cover being dragged ────────────────────────────────────────────
	Item {
		id: ghost

		visible: root.dragging
		x: root.dragAt.x - root.grabOffset.x
		y: root.dragAt.y - root.grabOffset.y
		width: root.dragW
		height: root.dragW * 1.5
		z: 10
		scale: root.dragLeaves ? 0.85 : ((root.dropNew || root.dropRow !== "") && rail.hit(root.dragAt) !== "" ? 0.6 : 1.06)
		rotation: root.dragLeaves ? -6 : 3
		opacity: root.dragLeaves ? 0.6 : 1

		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on rotation {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {}
		}

		GameCard {
			anchors.fill: parent
			game: root.dragGame
			current: true
			enabled: false
		}

		// what the drop does: + to a shelf as well, − off the one it was on
		Rectangle {
			readonly property string what: root.dragLeaves ? "minus" : ((root.dropRow !== "" && root.dropRow !== root.dragFrom) || root.dropNew ? "plus" : "")

			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: -10
			width: 34
			height: 34
			radius: 17
			visible: what !== ""
			color: root.dragLeaves ? Theme.danger : root.accent

			Glyph {
				anchors.centerIn: parent
				icon: parent.what
				size: 20
				color: root.dragLeaves ? "white" : GameText.onColor(root.accent)
				surface: "transparent"
			}
		}
	}
}
