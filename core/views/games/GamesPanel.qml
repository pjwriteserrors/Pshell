pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.games
import qs.core.views.launcher
import "../../lib/GameText.js" as GameText
import qs.core.views

// The game library under the bar (`games-bar`): the picked game as a
// banner – its hero, logo, play time and Play – over the covers of what
// was played last, the favourites or everything. Arrows walk the covers,
// Enter plays, typing searches; the expand button (or Ctrl+Enter) opens the
// full library on the same game. A right click on a cover opens it there
// with its menu.
Drawer {
	id: root

	// recent | favorites | all
	property string filter: "recent"
	property string query: ""
	property string selectedId: ""
	property bool intro: false
	// a launch from here: its cover pulses, the panel goes once it started
	property string starting: ""
	property string startError: ""

	readonly property int columns: 6
	readonly property real cell: Math.floor((root.innerWidth + 12) / root.columns)

	readonly property var list: {
		const recent = game => Math.max(game.lastPlayed || 0, game.added || 0);
		const byName = (a, b) => GameText.sortName(a.name).localeCompare(GameText.sortName(b.name));
		let games = Games.games.filter(game => !game.hidden);
		const query = root.query.trim();
		if (query !== "") {
			return games.map(game => ({ game: game, score: GameText.matches(game, query) })).filter(entry => entry.score > 0).sort((a, b) => b.score - a.score || byName(a.game, b.game)).map(entry => entry.game);
		}
		if (root.filter === "favorites") games = games.filter(game => game.favorite);
		if (root.filter === "all") return games.sort(byName);
		return games.sort((a, b) => (Games.isRunning(b.id) - Games.isRunning(a.id)) || recent(b) - recent(a) || byName(a, b));
	}
	readonly property int index: Math.max(0, root.list.findIndex(game => game.id === root.selectedId))
	readonly property var selected: root.list.length > 0 ? root.list[root.index] : null
	readonly property bool running: !!root.selected && Games.isRunning(root.selected.id)

	panelId: "gamebar"
	panelWidth: 760
	contentHeight: layout.implicitHeight

	function select(i) {
		if (root.list.length === 0) return;
		const next = Math.max(0, Math.min(root.list.length - 1, i));
		if (root.list[next].id === root.selectedId) return;
		root.selectedId = root.list[next].id;
		Sounds.play("select");
	}

	function setFilter(id) {
		if (root.filter === id) return;
		root.filter = id;
		Sounds.play("select");
		Qt.callLater(() => {
			if (root.list.length > 0) root.selectedId = root.list[0].id;
			grid.positionViewAtBeginning();
		});
	}

	// the full library, on this game (and its menu)
	function expand(menu, stats) {
		Games.focusId = root.selected?.id ?? "";
		Games.focusMenu = !!menu;
		Games.focusStats = !!stats;
		const screen = Popups.screen;
		Popups.close();
		Popups.openModal("games", screen);
	}

	function play(game) {
		if (!game || root.starting !== "") return;
		if (Games.isRunning(game.id)) {
			root.expand(false);
			return;
		}
		root.starting = game.id;
		root.startError = "";
		Games.launch(game.id, "");
	}

	onPanelOpened: {
		Games.watched = true;
		Games.refresh();
		root.filter = "recent";
		root.query = "";
		search.text = "";
		root.starting = "";
		root.startError = "";
		root.selectedId = root.list.length > 0 ? root.list[0].id : "";
		root.intro = true;
		introEnd.restart();
		grid.positionViewAtBeginning();
		Qt.callLater(() => keys.forceActiveFocus());
	}
	onPanelClosed: Games.watched = Popups.modal === "games"

	onListChanged: {
		if (root.list.length > 0 && !root.list.some(game => game.id === root.selectedId)) root.selectedId = root.list[0].id;
		games.sync(root.list.map(game => Object.assign({ key: game.id }, game)));
	}
	onIndexChanged: grid.positionViewAtIndex(root.index, GridView.Contain)
	onSelectedChanged: swap.restart()

	Timer {
		id: introEnd

		interval: 900
		onTriggered: root.intro = false
	}

	Connections {
		target: Games

		function onLaunched(id) {
			if (id !== root.starting) return;
			leave.restart();
		}

		function onFailed(id, message) {
			if (id !== root.starting) return;
			root.starting = "";
			root.startError = message;
		}
	}

	// it started: a moment of the pulse, then the panel goes
	Timer {
		id: leave

		interval: 900
		onTriggered: {
			root.starting = "";
			Popups.close();
		}
	}

	SyncedModel {
		id: games
	}

	// what comes in when another game is picked
	property real swapIn: 1

	NumberAnimation {
		id: swap

		target: root
		property: "swapIn"
		from: 0
		to: 1
		duration: Motion.long
		easing.type: Easing.OutCubic
	}

	Item {
		id: keys

		anchors.fill: parent
		focus: true

		Keys.onPressed: event => {
			const ctrl = event.modifiers & Qt.ControlModifier;
			switch (event.key) {
			case Qt.Key_Left:
				root.select(root.index - 1);
				break;
			case Qt.Key_Right:
				root.select(root.index + 1);
				break;
			case Qt.Key_Up:
				if (root.index < root.columns) search.input.forceActiveFocus();
				else root.select(root.index - root.columns);
				break;
			case Qt.Key_Down:
				root.select(root.index + root.columns);
				break;
			case Qt.Key_Return:
			case Qt.Key_Enter:
				if (ctrl) root.expand(false);
				else root.play(root.selected);
				break;
			case Qt.Key_Tab:
			case Qt.Key_Backtab: {
				const order = ["recent", "favorites", "all"];
				const step = event.key === Qt.Key_Backtab ? -1 : 1;
				root.setFilter(order[(order.indexOf(root.filter) + step + order.length) % order.length]);
				break;
			}
			case Qt.Key_Menu:
				root.expand(true);
				break;
			case Qt.Key_Escape:
				if (root.query !== "") {
					root.query = "";
					search.text = "";
				} else {
					Popups.close();
				}
				break;
			default: {
				const text = String(event.text || "");
				if (ctrl || !/^\S$/.test(text)) return;
				search.input.forceActiveFocus();
				search.text = search.text + text;
				root.query = search.text;
			}
			}
			event.accepted = true;
		}
	}

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 14

		// ── the head ───────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Glyph {
				icon: "gamepad_variant"
				size: 20
				color: Theme.primary
			}

			StyledText {
				text: "Games"
				font.pixelSize: Theme.size.heading
				font.weight: Font.Bold
			}

			Field {
				id: search

				Layout.fillWidth: true
				Layout.leftMargin: 8
				icon: "magnify"
				placeholder: `Search ${Games.games.filter(game => !game.hidden).length} games`
				onEdited: text => root.query = text
				onAccepted: {
					keys.forceActiveFocus();
					if (root.query !== "") root.play(root.list[0] ?? null);
				}
				onEscapePressed: {
					if (search.text !== "") {
						search.text = "";
						root.query = "";
					}
					keys.forceActiveFocus();
				}
				onDownPressed: keys.forceActiveFocus()
			}

			IconButton {
				icon: "plus"
				implicitWidth: 36
				implicitHeight: 36
				onClicked: {
					const screen = Popups.screen;
					Popups.close();
					Popups.openModal("games", screen);
					Games.addRequested("");
				}
			}

			IconButton {
				icon: "arrow_expand"
				implicitWidth: 36
				implicitHeight: 36
				onClicked: root.expand(false)
			}
		}

		// ── the picked game ────────────────────────────────────────────────
		Item {
			id: banner

			Layout.fillWidth: true
			Layout.preferredHeight: 250
			visible: root.selected !== null

			RectangularShadow {
				anchors.fill: bannerClip
				radius: Theme.radius.huge
				blur: 30
				offset.y: 10
				color: Qt.rgba(0, 0, 0, 0.45)
			}

			Rounded {
				id: bannerClip

				anchors.fill: parent
				radius: Theme.radius.huge

				Backdrop {
					anchors.fill: parent
					game: root.selected
					active: root.shown
				}
			}

			// the cover pulses while its game starts
			Rectangle {
				anchors.fill: parent
				radius: Theme.radius.huge
				color: "transparent"
				border.width: 3
				border.color: root.startError !== "" ? Theme.danger : Theme.primary
				opacity: root.starting !== "" || root.startError !== "" ? 1 : 0

				Behavior on opacity {
					Anim {}
				}

				SequentialAnimation on border.width {
					running: root.starting !== ""
					loops: Animation.Infinite

					NumberAnimation {
						to: 6
						duration: 500
						easing.type: Easing.InOutSine
					}
					NumberAnimation {
						to: 2
						duration: 500
						easing.type: Easing.InOutSine
					}
				}
			}

			ColumnLayout {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 22
				spacing: 12
				opacity: 0.3 + 0.7 * root.swapIn
				transform: Translate {
					x: 14 * (1 - root.swapIn)
				}

				// logo or name
				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: logo.status === Image.Ready && logo.source != "" ? Math.min(90, logo.paintedHeight) : bannerName.implicitHeight

					Image {
						id: logo

						anchors.left: parent.left
						anchors.bottom: parent.bottom
						width: Math.min(parent.width * 0.6, 380)
						height: 90
						source: root.selected?.art?.logo ? `file://${root.selected.art.logo}` : ""
						fillMode: Image.PreserveAspectFit
						horizontalAlignment: Image.AlignLeft
						verticalAlignment: Image.AlignBottom
						asynchronous: true
						sourceSize.width: 760
						visible: false
					}

					MultiEffect {
						anchors.fill: logo
						source: logo
						visible: logo.status === Image.Ready && logo.source != ""
						shadowEnabled: true
						shadowBlur: 0.7
						shadowOpacity: 0.7
						shadowColor: "black"
					}

					StyledText {
						id: bannerName

						anchors.left: parent.left
						anchors.bottom: parent.bottom
						width: parent.width
						visible: !(logo.status === Image.Ready && logo.source != "")
						text: root.selected?.name ?? ""
						tone: "white"
						surface: "transparent"
						elide: Text.ElideRight
						font.pixelSize: 32
						font.weight: Font.Black
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					// what is known, on one line
					StyledText {
						Layout.fillWidth: true
						text: {
							const game = root.selected;
							if (!game) return "";
							if (root.startError !== "") return root.startError;
							if (root.starting !== "") return "Starting …";
							const parts = [];
							if (root.running) parts.push("Playing now");
							parts.push(Games.steamAdding === game.id ? Games.steamProgress : GameText.runnerLabel(game, Games.runners));
							const time = GameText.playtime(game.playtime);
							if (time) parts.push(time);
							parts.push(GameText.ago(game.lastPlayed) || "Not played yet");
							return parts.join("  ·  ");
						}
						tone: root.startError !== "" ? Theme.danger : (root.running ? Theme.success : Qt.rgba(1, 1, 1, 0.85))
						surface: "transparent"
						elide: Text.ElideRight
						font.pixelSize: Theme.size.body
						font.weight: Font.Medium
					}

					// its landing page, in the library
					IconButton {
						implicitWidth: 40
						implicitHeight: 40
						radius: 20
						variant: "tonal"
						color: Qt.rgba(1, 1, 1, 0.14)
						icon: "chart_bar"
						iconColor: "white"
						visible: root.selected !== null
						onClicked: root.expand(false, true)
					}

					IconButton {
						implicitWidth: 40
						implicitHeight: 40
						radius: 20
						variant: "tonal"
						color: Qt.rgba(1, 1, 1, 0.14)
						icon: root.selected?.favorite ? "heart" : "heart_outline"
						iconColor: root.selected?.favorite ? "#ff5d7a" : "white"
						sound: ""
						onClicked: Games.toggleFavorite(root.selected.id)
					}

					IconButton {
						implicitWidth: 40
						implicitHeight: 40
						radius: 20
						variant: "tonal"
						color: Qt.rgba(1, 1, 1, 0.14)
						icon: "dots_horizontal"
						iconColor: "white"
						onClicked: root.expand(true)
					}

					// Play
					Item {
						Layout.preferredWidth: Math.max(130, playRow.implicitWidth + 40)
						Layout.preferredHeight: 44

						Rectangle {
							id: playFace

							anchors.fill: parent
							radius: height / 2
							color: root.running ? Theme.success : Theme.primary
							scale: playMouse.pressed ? 0.95 : (playMouse.containsMouse ? 1.05 : 1)
							clip: true

							Behavior on color {
								ColorAnim {}
							}
							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							// light runs over it while it starts
							Rectangle {
								id: glint

								property real travel: 0

								visible: root.starting !== ""
								width: 60
								height: parent.height * 2
								y: -parent.height / 2
								rotation: 20
								x: -width + (parent.width + width * 2) * glint.travel
								gradient: Gradient {
									orientation: Gradient.Horizontal
									GradientStop {
										position: 0
										color: Qt.rgba(1, 1, 1, 0)
									}
									GradientStop {
										position: 0.5
										color: Qt.rgba(1, 1, 1, 0.35)
									}
									GradientStop {
										position: 1
										color: Qt.rgba(1, 1, 1, 0)
									}
								}

								NumberAnimation on travel {
									running: glint.visible
									loops: Animation.Infinite
									from: 0
									to: 1
									duration: 900
								}
							}

							RowLayout {
								id: playRow

								anchors.centerIn: parent
								spacing: 8

								Spinner {
									visible: root.starting !== ""
									Layout.preferredWidth: 16
									Layout.preferredHeight: 16
									color: Theme.onPrimary
								}

								Glyph {
									visible: root.starting === ""
									icon: root.running ? "open_in_new" : "play"
									size: 20
									color: Theme.onPrimary
									surface: playFace.color
								}

								StyledText {
									text: root.starting !== "" ? "Starting" : (root.running ? "Playing" : "Play")
									tone: Theme.onPrimary
									surface: playFace.color
									font.pixelSize: Theme.size.title
									font.weight: Font.Black
								}
							}
						}

						MouseArea {
							id: playMouse

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: {
								Sounds.play("click");
								root.play(root.selected);
							}
						}
					}
				}
			}
		}

		// ── which games ────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 6
			visible: root.query === ""

			Repeater {
				model: [
					{ id: "recent", label: "Recent", icon: "history" },
					{ id: "favorites", label: "Favourites", icon: "heart_outline" },
					{ id: "all", label: "All", icon: "view_grid_outline" }
				]

				delegate: Chip {
					required property var modelData

					text: modelData.label
					icon: modelData.icon
					selected: root.filter === modelData.id
					onClicked: root.setFilter(modelData.id)
				}
			}

			Item {
				Layout.fillWidth: true
			}

			StyledText {
				text: "↵ Play  ·  Tab Filter  ·  Ctrl+↵ Library"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}

		// ── the covers ─────────────────────────────────────────────────────
		GridView {
			id: grid

			Layout.fillWidth: true
			Layout.leftMargin: -6
			Layout.rightMargin: -6
			Layout.preferredHeight: Math.min(2, Math.ceil(root.list.length / root.columns)) * grid.cellHeight + 8
			cellWidth: root.cell
			cellHeight: (root.cell - 12) * 1.5 + 14
			model: games
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			visible: root.list.length > 0
			topMargin: 6

			Behavior on Layout.preferredHeight {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			add: Transition {
				ParallelAnimation {
					Anim {
						property: "opacity"
						from: 0
						to: 1
					}
					SpatialAnim {
						property: "scale"
						from: 0.8
						to: 1
					}
				}
			}
			displaced: Transition {
				SpatialAnim {
					properties: "x,y"
				}
			}

			delegate: Item {
				id: cell

				required property string json
				required property int index
				readonly property var game: JSON.parse(cell.json)

				width: grid.cellWidth
				height: grid.cellHeight

				GameCard {
					anchors.horizontalCenter: parent.horizontalCenter
					y: 4
					width: grid.cellWidth - 12
					height: width * 1.5
					radius: Theme.radius.medium
					game: cell.game
					current: cell.index === root.index
					currentScale: 1.04
					appearDelay: root.intro ? Math.min(cell.index, 12) * 35 + 80 : -1
					opacity: root.starting !== "" && root.starting !== cell.game.id ? 0.4 : 1
					onPicked: root.select(cell.index)
					onActivated: root.play(cell.game)
					onMenuAsked: () => {
						root.select(cell.index);
						root.expand(true);
					}

					Behavior on opacity {
						Anim {}
					}
				}
			}
		}

		// ── nothing ────────────────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			Layout.topMargin: 20
			Layout.bottomMargin: 20
			visible: root.list.length === 0
			spacing: 8

			Glyph {
				Layout.alignment: Qt.AlignHCenter
				icon: Games.loaded ? (root.query !== "" ? "magnify" : "gamepad_variant") : "gamepad_variant"
				size: 40
				color: Theme.textSubtle
			}

			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: !Games.loaded ? "Looking for games" : (root.query !== "" ? `Nothing called “${root.query}”` : (root.filter === "favorites" ? "No favourites yet" : "No games yet"))
				tone: Theme.textMuted
				font.pixelSize: Theme.size.title
			}
		}
	}
}
