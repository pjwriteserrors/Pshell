pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../../lib/GameText.js" as GameText

// Adding a game, changing one, or only its cover: a card that rises over
// the library. The name looks for covers as it is typed (Steam's store,
// SteamGridDB with a key); the first that fits is taken until another is
// picked. A program of Windows starts with Proton (the newest GE unless
// another is picked) or Wine, and can go into Steam as well.
Item {
	id: root

	// "add" | "edit" | "cover"
	property string mode: "add"
	property var game: null
	property bool open: false

	property string exe: ""
	property string name: ""
	property string runner: "proton"
	property string args: ""
	property bool toSteam: false
	// the cover picked: a result's id, "none", or "" for what it has
	property string art: ""
	property bool artPicked: false
	property string error: ""
	property bool saving: false
	property bool keyOpen: false

	readonly property bool custom: root.mode === "add" || root.game?.kind === "custom"
	readonly property bool windowsProgram: /\.(exe|msi|bat|cmd|lnk)$/i.test(root.exe)
	readonly property var picked: Games.searchResults.find(entry => entry.id === root.art) ?? null
	readonly property var protons: Games.runners.filter(each => each.kind === "proton")
	readonly property string runnerKind: root.runner.startsWith("proton") ? "proton" : root.runner
	readonly property bool canSave: !root.saving && root.name.trim() !== "" && (!root.custom || root.exe !== "")

	// what the preview shows
	readonly property var preview: {
		if (root.art === "none") return { name: root.name, art: {} };
		if (root.picked) return { name: root.name, art: root.picked.wide ? { header: root.picked.preview } : { cover: root.picked.preview } };
		return { name: root.name || "?", art: root.game?.art ?? {} };
	}

	signal done(string id)

	function begin(mode, game, path) {
		root.mode = mode;
		root.game = game ?? null;
		root.exe = path ?? game?.exe ?? "";
		root.name = game?.name ?? "";
		root.runner = game?.runner && game.runner !== "steam" ? game.runner : (game?.inSteam ? "steam" : "proton");
		if (game?.inSteam) root.runner = "steam";
		root.args = game?.args ?? "";
		nameField.text = root.name;
		argsField.text = root.args;
		root.toSteam = false;
		root.art = "";
		root.artPicked = false;
		root.error = "";
		root.saving = false;
		root.keyOpen = false;
		Games.clearSearch();
		root.open = true;
		Sounds.play("open");
		if (root.exe !== "" && root.name === "") root.guess(root.exe);
		else if (root.name !== "") Games.search(root.name);
		Qt.callLater(() => {
			if (root.mode === "add" && root.exe === "") programRow.forceActiveFocus();
			else nameField.input.forceActiveFocus();
		});
	}

	function close() {
		if (!root.open) return;
		root.open = false;
		Games.clearSearch();
		Sounds.play("close");
	}

	function guess(path) {
		Games.guess(path, answer => {
			if (answer.name && root.name === "") {
				root.name = answer.name;
				nameField.text = answer.name;
				Games.search(answer.name);
			}
			if (answer.runner && root.mode === "add") root.runner = answer.runner;
			nameField.input.forceActiveFocus();
		});
	}

	function setProgram(path) {
		const clean = String(path || "").replace(/^file:\/\//, "");
		if (clean === "") return;
		root.exe = decodeURIComponent(clean);
		root.error = "";
		if (root.mode === "add") {
			root.name = "";
			nameField.text = "";
			root.guess(root.exe);
		}
	}

	function pickArt(id) {
		root.art = id;
		root.artPicked = true;
		Sounds.play("select");
		previewFlip.restart();
	}

	function save() {
		if (!root.canSave) return;
		root.error = "";
		const artChange = root.artPicked || (root.mode === "add" && root.art !== "") ? root.art : undefined;
		if (root.mode === "add") {
			root.saving = true;
			const request = { exe: root.exe, name: root.name.trim(), runner: root.runner, args: root.args };
			if (artChange !== undefined && artChange !== "") request.art = artChange;
			const steam = root.toSteam;
			Games.add(request, (game, error) => {
				root.saving = false;
				if (!game) {
					root.error = error || "It could not be added";
					return;
				}
				if (steam) Games.addToSteam(game.id);
				root.close();
				root.done(game.id);
			});
			return;
		}
		const id = root.game.id;
		const change = {};
		if (root.name.trim() !== root.game.name) change.name = root.name.trim();
		if (root.custom && root.mode === "edit") {
			if (root.runner !== root.game.runner) change.runner = root.runner;
			if (root.args !== (root.game.args ?? "")) change.args = root.args;
		}
		if (artChange !== undefined && artChange !== "") change.art = artChange;
		if (Object.keys(change).length > 0) Games.update(id, change);
		root.close();
		root.done(id);
	}

	// the name looks for covers while it is typed
	onNameChanged: if (root.open && root.name.trim().length >= 2) Games.search(root.name)

	// the first result that comes is taken until one is picked
	Connections {
		target: Games

		function onSearchResultsChanged() {
			if (!root.open || root.artPicked) return;
			if (root.mode === "add" || !root.game?.art?.cover) root.art = Games.searchResults.length > 0 ? Games.searchResults[0].id : "";
		}
	}

	anchors.fill: parent
	visible: card.opacity > 0.01
	z: 40

	// the library steps back
	Rectangle {
		anchors.fill: parent
		color: Qt.rgba(0, 0, 0, 0.55)
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

	// a program dropped anywhere on the card
	DropArea {
		anchors.fill: card
		enabled: root.open && root.custom
		onDropped: drop => {
			if (drop.hasUrls && drop.urls.length > 0) root.setProgram(String(drop.urls[0]));
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

		anchors.horizontalCenter: parent.horizontalCenter
		y: (parent.height - height) / 2 + 60 * (1 - card.rise)
		width: Math.min(parent.width - 64, 900)
		height: content.implicitHeight + 48
		radius: Theme.radius.huge
		color: Qt.tint(Theme.bg, Qt.rgba(1, 1, 1, 0.04))
		border.width: 1
		border.color: Qt.rgba(1, 1, 1, 0.08)
		property real rise: root.open ? 1 : 0
		opacity: card.rise
		scale: 0.96 + 0.04 * card.rise

		Behavior on rise {
			NumberAnimation {
				duration: root.open ? Motion.extraLong : Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: root.open ? Motion.spatial : Motion.accel
			}
		}
		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
		}

		Keys.onEscapePressed: root.close()

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
					icon: root.mode === "add" ? "plus" : (root.mode === "cover" ? "image_outline" : "pencil_outline")
					size: 22
					color: Theme.primary
					surface: "transparent"
				}

				StyledText {
					Layout.fillWidth: true
					text: root.mode === "add" ? "Add a game" : (root.mode === "cover" ? `A cover for ${root.game?.name ?? ""}` : `Edit ${root.game?.name ?? ""}`)
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

				// ── the cover as it will be ────────────────────────────────
				Item {
					Layout.preferredWidth: 200
					Layout.preferredHeight: 300
					Layout.alignment: Qt.AlignTop

					RectangularShadow {
						anchors.fill: previewArt
						radius: Theme.radius.large
						blur: 36
						offset.y: 14
						color: Qt.alpha(Theme.primary, 0.35)
					}

					CoverArt {
						id: previewArt

						property real turn: 0

						anchors.fill: parent
						game: root.preview
						radius: Theme.radius.large
						transform: Rotation {
							origin.x: previewArt.width / 2
							origin.y: previewArt.height / 2
							axis {
								x: 0
								y: 1
								z: 0
							}
							angle: previewArt.turn
						}
					}

					// a new cover turns in
					SequentialAnimation {
						id: previewFlip

						NumberAnimation {
							target: previewArt
							property: "turn"
							from: -70
							to: 0
							duration: Motion.extraLong
							easing.type: Easing.OutBack
						}
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					Layout.alignment: Qt.AlignTop
					spacing: 14

					// ── the program ────────────────────────────────────────
					ColumnLayout {
						Layout.fillWidth: true
						visible: root.custom && root.mode !== "cover"
						spacing: 6

						SectionLabel {
							text: "Program"
						}

						Clickable {
							id: programRow

							Layout.fillWidth: true
							Layout.preferredHeight: 58
							radius: Theme.radius.large
							color: programDrop.containsDrag ? Qt.alpha(Theme.primary, 0.16) : Theme.layer1
							border.width: 1.5
							border.color: programDrop.containsDrag ? Theme.primary : (root.exe === "" ? Qt.alpha(Theme.primary, 0.35) : Theme.outline)
							activeFocusOnTab: true
							onClicked: Games.pickProgram(path => root.setProgram(path))
							Keys.onReturnPressed: Games.pickProgram(path => root.setProgram(path))

							Behavior on color {
								ColorAnim {}
							}

							DropArea {
								id: programDrop

								anchors.fill: parent
								onDropped: drop => {
									if (drop.hasUrls && drop.urls.length > 0) root.setProgram(String(drop.urls[0]));
								}
							}

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 14
								anchors.rightMargin: 10
								spacing: 12

								Glyph {
									icon: root.exe === "" ? "upload_outline" : (root.windowsProgram ? "microsoft_windows" : "linux")
									size: 22
									color: Theme.primary
									surface: "transparent"
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 1

									StyledText {
										Layout.fillWidth: true
										text: root.exe === "" ? "Drop the game's program here" : root.exe.split("/").pop()
										tone: Theme.text
										surface: "transparent"
										elide: Text.ElideMiddle
										font.pixelSize: Theme.size.body
										font.weight: Font.DemiBold
									}

									StyledText {
										Layout.fillWidth: true
										text: root.exe === "" ? "or click to choose it – an .exe, a script, a Linux program" : root.exe.split("/").slice(0, -1).join("/")
										tone: Theme.textSubtle
										surface: "transparent"
										elide: Text.ElideMiddle
										font.pixelSize: Theme.size.small
									}
								}

								TextButton {
									text: Games.picking ? "Choosing" : (root.exe === "" ? "Choose" : "Change")
									icon: "folder_open_outline"
									busy: Games.picking
									onClicked: Games.pickProgram(path => root.setProgram(path))
								}
							}
						}
					}

					// ── the name ───────────────────────────────────────────
					ColumnLayout {
						Layout.fillWidth: true
						spacing: 6

						SectionLabel {
							text: root.mode === "cover" ? "Look for" : "Name"
						}

						Field {
							id: nameField

							Layout.fillWidth: true
							implicitHeight: 44
							icon: root.mode === "cover" ? "magnify" : "gamepad_variant"
							placeholder: "What the game is called"
							fontSize: Theme.size.title
							onEdited: text => root.name = text
							onAccepted: root.save()
							onEscapePressed: root.close()
						}
					}

					// ── how it starts ──────────────────────────────────────
					ColumnLayout {
						Layout.fillWidth: true
						visible: root.custom && root.mode !== "cover" && root.exe !== ""
						spacing: 8

						SectionLabel {
							text: "Starts with"
						}

						Segmented {
							Layout.fillWidth: true
							options: [
								{ value: "proton", label: "Proton", icon: "microsoft_windows" },
								{ value: "wine", label: "Wine", icon: "glass_wine" },
								{ value: "native", label: "Linux", icon: "linux" }
							].concat(root.game?.inSteam ? [{ value: "steam", label: "Steam", icon: "steam" }] : [])
							current: root.runnerKind
							onSelected: value => root.runner = value
						}

						// which Proton
						Flow {
							Layout.fillWidth: true
							visible: root.runnerKind === "proton" && root.protons.length > 1
							spacing: 6

							Repeater {
								model: [{ id: "proton", name: "Newest" }].concat(root.protons.slice(0, 6))

								delegate: Chip {
									required property var modelData

									text: modelData.name
									selected: root.runner === modelData.id
									onClicked: root.runner = modelData.id
								}
							}
						}

						Field {
							id: argsField

							Layout.fillWidth: true
							icon: "console"
							placeholder: "Launch options (-dx11 -skipintro)"
							onEdited: text => root.args = text
							onAccepted: root.save()
						}

						// into Steam as well
						RowLayout {
							Layout.fillWidth: true
							visible: root.mode === "add" && Games.steam
							spacing: 12

							Glyph {
								icon: "steam"
								size: 20
								color: root.toSteam ? Theme.primary : Theme.textMuted
								surface: "transparent"
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0

								StyledText {
									text: "Add to Steam as well"
									tone: Theme.text
									surface: "transparent"
									font.pixelSize: Theme.size.body
									font.weight: Font.DemiBold
								}

								StyledText {
									Layout.fillWidth: true
									text: Games.steamRunning ? "As a non-Steam game with this cover; Steam restarts for it" : "As a non-Steam game with this cover"
									tone: Theme.textSubtle
									surface: "transparent"
									wrapMode: Text.WordWrap
									font.pixelSize: Theme.size.small
								}
							}

							Toggle {
								checked: root.toSteam
								onToggled: checked => root.toSteam = checked
							}
						}
					}
				}
			}

			// ── covers ─────────────────────────────────────────────────────
			ColumnLayout {
				Layout.fillWidth: true
				spacing: 8

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					SectionLabel {
						text: "Cover"
					}

					Spinner {
						visible: Games.searching
						Layout.preferredWidth: 14
						Layout.preferredHeight: 14
					}

					Item {
						Layout.fillWidth: true
					}

					StyledText {
						text: Games.gridKey ? "Steam · SteamGridDB" : "From Steam's store"
						tone: Theme.textSubtle
						surface: "transparent"
						font.pixelSize: Theme.size.small
					}

					TextButton {
						visible: !Games.gridKey
						variant: "ghost"
						implicitHeight: 28
						text: "More with SteamGridDB"
						onClicked: root.keyOpen = !root.keyOpen
					}
				}

				// a SteamGridDB key
				RowLayout {
					Layout.fillWidth: true
					visible: root.keyOpen && !Games.gridKey
					spacing: 8

					Field {
						id: keyField

						Layout.fillWidth: true
						icon: "key_variant"
						password: true
						placeholder: "API key from steamgriddb.com/profile/preferences/api"
						onAccepted: keySave.clicked(null)
					}

					TextButton {
						id: keySave

						variant: "filled"
						text: "Keep"
						onClicked: Games.setKey(keyField.text, answer => {
							if (answer.error) root.error = answer.error;
							else {
								root.keyOpen = false;
								if (root.name.trim() !== "") Games.search(root.name);
							}
						})
					}
				}

				Flickable {
					id: strip

					Layout.fillWidth: true
					Layout.preferredHeight: 172
					contentWidth: covers.implicitWidth
					contentHeight: height
					flickableDirection: Flickable.HorizontalFlick
					boundsBehavior: Flickable.StopAtBounds
					clip: true

					WheelHandler {
						onWheel: event => strip.contentX = Math.max(0, Math.min(strip.contentWidth - strip.width, strip.contentX - (event.angleDelta.y || event.angleDelta.x)))
					}

					Row {
						id: covers

						y: 8
						spacing: 10

						// no cover at all
						Clickable {
							width: 104
							height: 156
							radius: Theme.radius.medium
							color: Theme.layer1
							border.width: root.art === "none" ? 2.5 : 1
							border.color: root.art === "none" ? Theme.primary : Theme.outline
							onClicked: root.pickArt("none")

							ColumnLayout {
								anchors.centerIn: parent
								spacing: 6

								Glyph {
									Layout.alignment: Qt.AlignHCenter
									icon: "image_off_outline"
									size: 26
									color: Theme.textMuted
									surface: "transparent"
								}

								StyledText {
									Layout.alignment: Qt.AlignHCenter
									text: "No cover"
									tone: Theme.textMuted
									surface: "transparent"
									font.pixelSize: Theme.size.small
								}
							}
						}

						// while it looks: placeholders that shimmer
						Repeater {
							model: Games.searching && Games.searchResults.length === 0 ? 5 : 0

							delegate: Rectangle {
								id: ghost

								required property int index

								width: 104
								height: 156
								radius: Theme.radius.medium
								color: Theme.layer2

								SequentialAnimation on opacity {
									loops: Animation.Infinite
									running: ghost.visible

									PauseAnimation {
										duration: ghost.index * 90
									}
									NumberAnimation {
										to: 0.35
										duration: 600
										easing.type: Easing.InOutSine
									}
									NumberAnimation {
										to: 1
										duration: 600
										easing.type: Easing.InOutSine
									}
								}
							}
						}

						Repeater {
							model: Games.searchResults

							delegate: Item {
								id: result

								required property var modelData
								required property int index
								readonly property bool chosen: root.art === result.modelData.id
								property real pop: 0

								width: 104
								height: 156
								opacity: result.pop
								scale: (0.8 + 0.2 * result.pop) * (resultMouse.containsMouse ? 1.05 : 1)

								Behavior on scale {
									SpatialAnim {
										duration: Motion.medium
									}
								}

								Component.onCompleted: popping.start()

								SequentialAnimation {
									id: popping

									PauseAnimation {
										duration: 40 * result.index
									}
									NumberAnimation {
										target: result
										property: "pop"
										to: 1
										duration: Motion.long
										easing.type: Easing.OutBack
									}
								}

								CoverArt {
									anchors.fill: parent
									radius: Theme.radius.medium
									game: ({ name: result.modelData.name, art: result.modelData.wide ? { header: result.modelData.preview } : { cover: result.modelData.preview } })
									sheen: resultMouse.containsMouse ? 0.6 : 0
								}

								Rectangle {
									anchors.fill: parent
									anchors.margins: -4
									radius: Theme.radius.medium + 4
									color: "transparent"
									border.width: 2.5
									border.color: Theme.primary
									opacity: result.chosen ? 1 : 0

									Behavior on opacity {
										Anim {}
									}
								}

								Rectangle {
									anchors.right: parent.right
									anchors.top: parent.top
									anchors.margins: 6
									width: 22
									height: 22
									radius: 11
									color: Theme.primary
									scale: result.chosen ? 1 : 0

									Behavior on scale {
										SpatialAnim {
											duration: Motion.medium
										}
									}

									Glyph {
										anchors.centerIn: parent
										icon: "check_bold"
										size: 13
										color: Theme.onPrimary
										surface: Theme.primary
									}
								}

								// where it comes from, and what it is called there
								Rectangle {
									anchors.left: parent.left
									anchors.right: parent.right
									anchors.bottom: parent.bottom
									height: 30
									radius: Theme.radius.medium
									color: Qt.rgba(0, 0, 0, 0.7)
									opacity: resultMouse.containsMouse ? 1 : 0

									Behavior on opacity {
										Anim {}
									}

									StyledText {
										anchors.fill: parent
										anchors.margins: 6
										text: result.modelData.name
										tone: "white"
										surface: "transparent"
										elide: Text.ElideRight
										verticalAlignment: Text.AlignVCenter
										font.pixelSize: Theme.size.tiny
									}
								}

								MouseArea {
									id: resultMouse

									anchors.fill: parent
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onClicked: root.pickArt(result.modelData.id)
								}
							}
						}

						// nothing found
						StyledText {
							height: 156
							visible: !Games.searching && Games.searchResults.length === 0 && Games.searchQuery !== ""
							verticalAlignment: Text.AlignVCenter
							leftPadding: 8
							text: "No cover found for that name – try it shorter or in English"
							tone: Theme.textMuted
							surface: "transparent"
							font.pixelSize: Theme.size.body
						}
					}
				}
			}

			// ── what went wrong ────────────────────────────────────────────
			StyledText {
				Layout.fillWidth: true
				visible: root.error !== ""
				text: root.error
				tone: Theme.danger
				surface: "transparent"
				wrapMode: Text.WordWrap
				font.pixelSize: Theme.size.body
			}

			// ── done ───────────────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				StyledText {
					Layout.fillWidth: true
					text: root.mode === "add" && root.exe !== "" ? GameText.runnerLabel({ kind: "custom", runner: root.runner }, Games.runners) : ""
					tone: Theme.textSubtle
					surface: "transparent"
					elide: Text.ElideRight
					font.pixelSize: Theme.size.small
				}

				TextButton {
					variant: "ghost"
					text: "Cancel"
					onClicked: root.close()
				}

				TextButton {
					variant: "filled"
					implicitHeight: 40
					text: root.mode === "add" ? (root.saving ? "Adding" : "Add game") : "Save"
					icon: root.mode === "add" ? "plus" : "check"
					busy: root.saving
					enabled: root.canSave
					onClicked: root.save()
				}
			}
		}
	}
}
