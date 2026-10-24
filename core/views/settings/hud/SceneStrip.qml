pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// The scenes of the game side by side: the one drawn on stands out, those
// the game shows now glow with how alike they look. Drag one sideways to
// put it elsewhere, double-click to rename, right-click for more; drop a
// sequence or a reaction on one for every zone of it.
Item {
	id: root

	property var page: null
	readonly property int cardW: 164
	readonly property int cardH: 92
	readonly property int gap: 10
	// a card dragged sideways: its id, where it was, where it is (px), where it goes
	property string dragId: ""
	property int dragFrom: -1
	property real dragX: 0
	readonly property int dragTo: root.dragId === "" ? -1 : Math.max(0, Math.min(root.page.scenes.length - 1, Math.round(root.dragX / (root.cardW + root.gap))))
	property string renaming: ""
	property string menuFor: ""

	function slot(index) {
		if (root.dragId === "" || root.dragFrom < 0) return index;
		if (root.dragFrom < root.dragTo && index > root.dragFrom && index <= root.dragTo) return index - 1;
		if (root.dragFrom > root.dragTo && index >= root.dragTo && index < root.dragFrom) return index + 1;
		return index;
	}

	implicitHeight: root.cardH + 8

	Flickable {
		id: flick

		anchors.fill: parent
		contentWidth: strip.width
		contentHeight: height
		flickableDirection: Flickable.HorizontalFlick
		boundsBehavior: Flickable.StopAtBounds
		interactive: root.dragId === ""
		clip: true

		Item {
			id: strip

			width: (root.page.scenes.length + 1) * (root.cardW + root.gap)
			height: flick.height

			Repeater {
				model: root.page.scenes

				delegate: Item {
					id: card

					required property var modelData
					required property int index

					readonly property string sceneId: card.modelData.id
					readonly property bool chosen: root.page.sceneId === card.sceneId
					readonly property bool up: root.page.liveScenes.includes(card.sceneId)
					readonly property real score: Number(root.page.scores[card.sceneId] ?? 0)
					readonly property real bar: Number(card.modelData.similar ?? 0.55)
					readonly property int count: root.page.allZones.filter(z => z.scene === card.sceneId).length
					readonly property bool dragged: root.dragId === card.sceneId
					readonly property bool target: drop.containsDrag && root.page.carry !== null

					x: card.dragged ? root.dragX : root.slot(card.index) * (root.cardW + root.gap)
					y: 4
					z: card.dragged ? 10 : 1
					width: root.cardW
					height: root.cardH
					scale: card.dragged ? 1.06 : (card.target ? 1.05 : (cardArea.pressed ? 0.97 : 1))
					opacity: 0
					Component.onCompleted: cardIn.start()

					Behavior on x {
						enabled: !card.dragged
						SpatialAnim {
							duration: Motion.long
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					SequentialAnimation {
						id: cardIn

						PauseAnimation {
							duration: card.index * 40
						}
						NumberAnimation {
							target: card
							property: "opacity"
							to: 1
							duration: Motion.medium
						}
					}

					// the glow of a scene the game shows now
					Rectangle {
						anchors.fill: parent
						anchors.margins: -4
						radius: Theme.radius.large + 4
						color: "transparent"
						border.width: 2.5
						border.color: Theme.primary
						opacity: 0
						visible: card.up

						SequentialAnimation on opacity {
							running: card.up
							loops: Animation.Infinite

							NumberAnimation {
								to: 0.9
								duration: 900
								easing.type: Easing.InOutSine
							}
							NumberAnimation {
								to: 0.3
								duration: 900
								easing.type: Easing.InOutSine
							}
						}
					}

					RoundClip {
						anchors.fill: parent
						radius: Theme.radius.large

						Rectangle {
							anchors.fill: parent
							color: Theme.layer2
						}

						Image {
							anchors.fill: parent
							source: card.modelData.picture ? `file://${card.modelData.picture}?${Mouse.hudPictureRev}` : ""
							fillMode: Image.PreserveAspectCrop
							asynchronous: true
							cache: false
							sourceSize.width: 336
							opacity: status === Image.Ready ? (card.chosen || cardArea.containsMouse ? 1 : 0.62) : 0

							Behavior on opacity {
								Anim {
									duration: Motion.medium
								}
							}
						}

						Glyph {
							anchors.centerIn: parent
							anchors.verticalCenterOffset: -10
							visible: !card.modelData.picture
							icon: "image_off_outline"
							size: 22
							color: Theme.textFaint
						}

						// the name over a shade
						Rectangle {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							height: 42
							gradient: Gradient {
								GradientStop {
									position: 0
									color: Qt.rgba(0, 0, 0, 0)
								}
								GradientStop {
									position: 1
									color: Qt.rgba(0, 0, 0, 0.72)
								}
							}
						}

						// how alike the game looks now, and the bar it has to cross
						Item {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							height: 3
							visible: root.page.watching

							Rectangle {
								anchors.fill: parent
								color: Qt.rgba(1, 1, 1, 0.15)
							}

							Rectangle {
								width: parent.width * Math.max(0, Math.min(1, card.score))
								height: parent.height
								color: card.up ? Theme.primary : Qt.rgba(1, 1, 1, 0.6)

								Behavior on width {
									Anim {
										duration: Motion.medium
									}
								}
							}

							Rectangle {
								x: parent.width * card.bar - 1
								y: -3
								width: 2
								height: 6
								color: "white"
							}
						}

						// dropped on: for every zone
						Rectangle {
							anchors.fill: parent
							color: Qt.alpha(Theme.primary, 0.82)
							opacity: card.target ? 1 : 0

							Behavior on opacity {
								Anim {}
							}

							ColumnLayout {
								anchors.centerIn: parent
								spacing: 2

								Glyph {
									Layout.alignment: Qt.AlignHCenter
									icon: "plus"
									size: 18
									color: Theme.onPrimary
								}

								StyledText {
									Layout.alignment: Qt.AlignHCenter
									text: `every zone · ${card.count}`
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
									color: Theme.onPrimary
								}
							}
						}
					}

					// chosen: an outline
					Rectangle {
						anchors.fill: parent
						radius: Theme.radius.large
						color: "transparent"
						border.width: card.chosen ? 2 : 1
						border.color: card.chosen ? Theme.primary : Theme.outline

						Behavior on border.color {
							ColorAnim {}
						}
					}

					RowLayout {
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						anchors.margins: 9
						anchors.bottomMargin: 8
						spacing: 6

						Rectangle {
							visible: card.up
							Layout.preferredWidth: 7
							Layout.preferredHeight: 7
							radius: 4
							color: Theme.primary
						}

						StyledText {
							Layout.fillWidth: true
							visible: root.renaming !== card.sceneId
							text: card.modelData.name
							color: "white"
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
							elide: Text.ElideRight
						}

						TextInput {
							id: nameInput

							Layout.fillWidth: true
							visible: root.renaming === card.sceneId
							color: "white"
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
							selectByMouse: true
							selectionColor: Theme.primary
							onVisibleChanged: if (visible) {
								text = card.modelData.name;
								forceActiveFocus();
								selectAll();
							}
							onAccepted: {
								if (text.trim() !== "") Mouse.hudChangeScene(card.sceneId, { name: text.trim() });
								root.renaming = "";
							}
							onActiveFocusChanged: if (!activeFocus && root.renaming === card.sceneId) accepted()
							Keys.onEscapePressed: root.renaming = ""
						}

						Rectangle {
							Layout.preferredHeight: 18
							Layout.preferredWidth: countText.implicitWidth + 12
							radius: 9
							color: Qt.rgba(0, 0, 0, 0.45)
							visible: root.renaming !== card.sceneId

							StyledText {
								id: countText

								anchors.centerIn: parent
								text: root.page.watching ? `${Math.round(card.score * 100)} %` : String(card.count)
								color: "white"
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
								tabular: true
							}
						}
					}

					DropArea {
						id: drop

						anchors.fill: parent
						keys: ["hud"]
						onDropped: root.page.dropOn("scene", card.sceneId, -1)
					}

					MouseArea {
						id: cardArea

						property real px: 0
						property real ox: 0

						anchors.fill: parent
						hoverEnabled: true
						preventStealing: true
						enabled: root.renaming !== card.sceneId
						acceptedButtons: Qt.LeftButton | Qt.RightButton
						cursorShape: card.dragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
						onPressed: mouse => {
							cardArea.px = cardArea.mapToItem(strip, mouse.x, 0).x;
							cardArea.ox = card.x;
							if (mouse.button === Qt.RightButton) {
								root.menuFor = card.sceneId;
								const p = cardArea.mapToItem(root, mouse.x, mouse.y);
								menu.x = p.x;
								menu.y = p.y + 6;
								menu.open();
							}
						}
						onPositionChanged: mouse => {
							if (!cardArea.pressed || !(cardArea.pressedButtons & Qt.LeftButton)) return;
							const nx = cardArea.mapToItem(strip, mouse.x, 0).x;
							if (root.dragId === "" && Math.abs(nx - cardArea.px) < 8) return;
							if (root.dragId === "") {
								root.dragFrom = card.index;
								root.dragId = card.sceneId;
							}
							root.dragX = Math.max(0, Math.min(strip.width - root.cardW * 2, cardArea.ox + nx - cardArea.px));
						}
						onReleased: {
							if (root.dragId !== card.sceneId) return;
							const ids = root.page.scenes.map(s => s.id);
							const to = root.dragTo;
							root.dragId = "";
							if (to !== root.dragFrom && to >= 0) {
								ids.splice(to, 0, ids.splice(root.dragFrom, 1)[0]);
								Mouse.hudOrderScenes(ids);
							}
							root.dragFrom = -1;
						}
						onClicked: mouse => {
							if (mouse.button === Qt.LeftButton) root.page.chooseScene(card.sceneId);
						}
						onDoubleClicked: mouse => {
							if (mouse.button === Qt.LeftButton) root.renaming = card.sceneId;
						}
					}

					Tip {
						below: true
						text: card.up ? "The game shows this now" : ""
					}
				}
			}

			// a new scene: a picture of what the game shows now
			Clickable {
				id: adder

				x: root.page.scenes.length * (root.cardW + root.gap)
				y: 4
				width: root.page.scenes.length > 0 ? 92 : root.cardW
				height: root.cardH
				radius: Theme.radius.large
				color: adder.hovered ? Theme.primarySoft : "transparent"
				border.width: 1.5
				border.color: adder.hovered ? Theme.primary : Theme.outline
				onClicked: root.page.newScene()

				Behavior on x {
					SpatialAnim {
						duration: Motion.long
					}
				}
				Behavior on color {
					ColorAnim {}
				}

				ColumnLayout {
					anchors.centerIn: parent
					spacing: 4

					Glyph {
						Layout.alignment: Qt.AlignHCenter
						icon: root.page.window > 0 ? "camera_outline" : "plus"
						size: 20
						color: adder.hovered ? Theme.primary : Theme.textSubtle
						rotation: adder.hovered && root.page.window <= 0 ? 90 : 0

						Behavior on rotation {
							SpatialAnim {
								duration: Motion.long
							}
						}
					}

					StyledText {
						Layout.alignment: Qt.AlignHCenter
						text: "New scene"
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
						tone: adder.hovered ? Theme.primary : Theme.textSubtle
					}
				}

				Tip {
					below: true
					text: root.page.window > 0 ? "Takes a picture of what the game shows now" : ""
				}
			}
		}
	}

	PickList {
		id: menu

		width: 220
		current: ""
		entries: [{ value: "rename", label: "Rename", icon: "pencil_outline" }, { value: "shoot", label: "New picture", icon: "camera_outline" }, { value: "remove", label: "Remove", icon: "delete_outline" }]
		onPicked: value => {
			const id = root.menuFor;
			if (value === "rename") root.renaming = id;
			else root.page.sceneAction(id, String(value));
		}
	}
}
