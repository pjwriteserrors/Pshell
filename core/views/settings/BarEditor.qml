pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The bar, drawn as a strip with its three zones, and a shelf of everything
// else the plugins that are on can put there (BarLayout). An item is dragged
// by itself: it lifts, the zone it is over lights up and its items make
// room where it would land, and it pops into place when let go – the real
// bar follows at once. Dropped on the shelf (or its × clicked) it leaves
// the bar; a click on the shelf puts it at the end of the right zone.
Item {
	id: root

	// the item being dragged, where it came from, where the pointer is (in root)
	property string dragId: ""
	property string dragFrom: ""
	property point dragAt: Qt.point(0, 0)
	property point grabOffset: Qt.point(0, 0)
	// where it would land
	property string overZone: ""
	property int overIndex: -1
	// the one that just landed: it pops
	property string landed: ""

	readonly property var zoneRows: ({ left: leftRow, center: centerRow, right: rightRow })
	readonly property real chipSize: 40

	implicitHeight: column.implicitHeight

	function itemOf(id) {
		return BarLayout.byId[id] ?? ({ name: id, icon: "help" });
	}

	function begin(id, from, chip, mouse) {
		const at = chip.mapToItem(root, mouse.x, mouse.y);
		root.grabOffset = Qt.point(mouse.x, mouse.y);
		root.dragId = id;
		root.dragFrom = from;
		root.dragAt = at;
		root.follow(at);
		Sounds.play("click");
	}

	// which zone and which place under the pointer
	function follow(at) {
		root.dragAt = at;
		const shelfAt = shelfBox.mapFromItem(root, at.x, at.y);
		if (shelfAt.y >= -20 && shelfAt.y <= shelfBox.height + 20 && shelfAt.x >= 0 && shelfAt.x <= shelfBox.width) {
			root.overZone = "shelf";
			root.overIndex = -1;
			return;
		}
		const barAt = strip.mapFromItem(root, at.x, at.y);
		if (barAt.y < -36 || barAt.y > strip.height + 36) {
			root.overZone = "";
			root.overIndex = -1;
			return;
		}
		const zone = barAt.x < strip.width * 0.36 ? "left" : (barAt.x > strip.width * 0.64 ? "right" : "center");
		const row = root.zoneRows[zone];
		const local = row.mapFromItem(root, at.x, at.y);
		let index = 0;
		for (let i = 0; i < row.children.length; i += 1) {
			const child = row.children[i];
			if (!child.chipId || child.chipId === root.dragId) continue;
			if (child.x + child.width / 2 < local.x) index += 1;
		}
		root.overZone = zone;
		root.overIndex = index;
	}

	function drop() {
		const id = root.dragId;
		if (id !== "" && root.overZone !== "") {
			BarLayout.place(id, root.overZone, root.overZone === "shelf" ? -1 : root.overIndex);
			root.landed = id;
			landedTimer.restart();
			Sounds.play(root.overZone === "shelf" ? "toggleOff" : "toggleOn");
		}
		root.dragId = "";
		root.overZone = "";
		root.overIndex = -1;
	}

	Timer {
		id: landedTimer

		interval: 700
		onTriggered: root.landed = ""
	}

	// ── one item ─────────────────────────────────────────────────────────
	component Chip: Rectangle {
		id: chip

		required property string chipId
		property string zone: ""
		property int place: 0
		property bool wide: false
		readonly property var entry: root.itemOf(chip.chipId)
		readonly property bool lifted: root.dragId === chip.chipId
		readonly property bool hovered: hover.hovered
		// the items around the place it would land make room: away from the
		// edge the zone hangs from (the centre parts both ways)
		readonly property real makeRoom: {
			if (root.dragId === "" || chip.lifted || root.overZone !== chip.zone || chip.zone === "shelf") return 0;
			const gap = root.chipSize * 0.7;
			const after = chip.place >= root.overIndex;
			if (chip.zone === "left") return after ? gap : 0;
			if (chip.zone === "right") return after ? 0 : -gap;
			return after ? gap / 2 : -gap / 2;
		}

		width: chip.wide ? wideRow.implicitWidth + 26 : root.chipSize
		height: root.chipSize
		radius: chip.wide ? height / 2 : Theme.radius.medium
		color: chip.hovered && root.dragId === "" ? Theme.layer3 : (chip.wide ? Theme.layer2 : "transparent")
		opacity: chip.lifted ? 0.25 : 1
		transform: Translate {
			x: chip.makeRoom
			Behavior on x {
				SpatialAnim {
					duration: Motion.short + 40
				}
			}
		}

		Behavior on color {
			ColorAnim {}
		}
		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		// it pops into place
		Component.onCompleted: if (root.landed === chip.chipId) pop.start()

		SequentialAnimation {
			id: pop

			NumberAnimation {
				target: chip
				property: "scale"
				from: 0.6
				to: 1.18
				duration: 160
				easing.type: Easing.OutQuad
			}
			NumberAnimation {
				target: chip
				property: "scale"
				to: 1
				duration: 360
				easing.type: Easing.OutBack
			}
		}

		Glyph {
			anchors.centerIn: parent
			visible: !chip.wide
			icon: chip.entry.icon
			size: 19
			color: chip.hovered ? Theme.primary : Theme.text
		}

		RowLayout {
			id: wideRow

			anchors.centerIn: parent
			visible: chip.wide
			spacing: 8

			Glyph {
				icon: chip.entry.icon
				size: 17
				color: Theme.primary
			}

			StyledText {
				text: chip.entry.name
				font.pixelSize: Theme.size.body
				font.weight: Font.Medium
			}
		}

		HoverHandler {
			id: hover

			cursorShape: root.dragId !== "" ? Qt.ClosedHandCursor : Qt.OpenHandCursor
		}

		MouseArea {
			anchors.fill: parent
			preventStealing: true
			property bool moved: false
			property point start

			onPressed: mouse => {
				moved = false;
				start = Qt.point(mouse.x, mouse.y);
			}
			onPositionChanged: mouse => {
				if (!moved && Math.hypot(mouse.x - start.x, mouse.y - start.y) > 4) {
					moved = true;
					root.begin(chip.chipId, chip.zone, chip, mouse);
				}
				if (moved) root.follow(chip.mapToItem(root, mouse.x, mouse.y));
			}
			onReleased: {
				if (moved) root.drop();
				else if (chip.zone === "shelf") {
					root.landed = chip.chipId;
					landedTimer.restart();
					BarLayout.place(chip.chipId, "right", -1);
					Sounds.play("toggleOn");
				}
			}
			onCanceled: root.drop()
		}

		// the name, over an item of the bar
		Rectangle {
			anchors.bottom: parent.top
			anchors.bottomMargin: 6
			anchors.horizontalCenter: parent.horizontalCenter
			visible: !chip.wide && chip.hovered && root.dragId === ""
			width: tipText.implicitWidth + 16
			height: 24
			radius: 12
			color: Theme.layer4 ?? Theme.layer3
			z: 10

			StyledText {
				id: tipText

				anchors.centerIn: parent
				text: chip.entry.name
				font.pixelSize: Theme.size.small
			}
		}

		// off the bar
		Rectangle {
			anchors.top: parent.top
			anchors.right: parent.right
			anchors.margins: -5
			width: 18
			height: 18
			radius: 9
			visible: !chip.wide && chip.hovered && root.dragId === ""
			color: removeHover.hovered ? Theme.danger : Theme.layer4 ?? Theme.layer3
			z: 11

			Glyph {
				anchors.centerIn: parent
				icon: "close"
				size: 11
				color: removeHover.hovered ? Theme.onPrimary : Theme.text
			}

			HoverHandler {
				id: removeHover
			}

			TapHandler {
				onTapped: {
					BarLayout.remove(chip.chipId);
					Sounds.play("toggleOff");
				}
			}
		}
	}

	// ── a zone of the strip ──────────────────────────────────────────────
	component ZoneRow: Row {
		id: zoneRow

		required property string zone
		readonly property var ids: BarLayout.ids(zoneRow.zone)

		spacing: 2

		Repeater {
			model: zoneRow.ids

			delegate: Chip {
				required property string modelData
				required property int index

				chipId: modelData
				zone: zoneRow.zone
				place: index
			}
		}
	}

	ColumnLayout {
		id: column

		width: parent.width
		spacing: 18

		// ── the strip ────────────────────────────────────────────────────
		Rectangle {
			id: strip

			Layout.fillWidth: true
			Layout.preferredHeight: 56
			Layout.topMargin: 26
			radius: Theme.radius.large
			color: Theme.glass
			border.width: 1
			border.color: root.dragId !== "" && root.overZone !== "" && root.overZone !== "shelf" ? Qt.alpha(Theme.primary, 0.6) : Theme.outline

			Behavior on border.color {
				ColorAnim {}
			}

			// the zone it would land in lights up
			Repeater {
				model: ["left", "center", "right"]

				delegate: Rectangle {
					id: glow

					required property string modelData
					required property int index
					readonly property bool on: root.dragId !== "" && root.overZone === glow.modelData

					x: strip.width * [0, 0.36, 0.64][glow.index] + 4
					y: 4
					width: strip.width * [0.36, 0.28, 0.36][glow.index] - 8
					height: strip.height - 8
					radius: Theme.radius.medium
					color: Theme.primary
					opacity: glow.on ? 0.14 : (root.dragId !== "" ? 0.04 : 0)

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}

					StyledText {
						anchors.top: parent.bottom
						anchors.topMargin: 8
						anchors.horizontalCenter: parent.horizontalCenter
						text: ({ left: "Left", center: "Centre", right: "Right" })[glow.modelData]
						tone: glow.on ? Theme.primary : Theme.textFaint
						font.pixelSize: Theme.size.tiny
						font.weight: Font.DemiBold
						opacity: root.dragId !== "" ? 1 : 0

						Behavior on opacity {
							Anim {}
						}
					}
				}
			}

			ZoneRow {
				id: leftRow

				zone: "left"
				anchors.left: parent.left
				anchors.leftMargin: 10
				anchors.verticalCenter: parent.verticalCenter
			}

			ZoneRow {
				id: centerRow

				zone: "center"
				anchors.centerIn: parent
			}

			ZoneRow {
				id: rightRow

				zone: "right"
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.topMargin: 8
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "Drag items to place them – your bar changes as you go. Hover one to take it off."
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}

			TextButton {
				visible: BarLayout.custom
				text: "As it comes"
				icon: "restore"
				variant: "text"
				onActivated: BarLayout.reset()
			}
		}

		// ── the shelf ────────────────────────────────────────────────────
		Rectangle {
			id: shelfBox

			readonly property bool on: root.dragId !== "" && root.overZone === "shelf"

			Layout.fillWidth: true
			Layout.preferredHeight: Math.max(76, shelfFlow.implicitHeight + 28)
			radius: Theme.radius.large
			color: shelfBox.on ? Qt.alpha(Theme.danger, 0.08) : Theme.layer1
			border.width: 1.5
			border.color: shelfBox.on ? Qt.alpha(Theme.danger, 0.5) : (root.dragId !== "" ? Theme.outline : "transparent")

			Behavior on color {
				ColorAnim {}
			}
			Behavior on border.color {
				ColorAnim {}
			}
			Behavior on Layout.preferredHeight {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Flow {
				id: shelfFlow

				x: 14
				y: 14
				width: shelfBox.width - 28
				spacing: 8

				move: Transition {
					SpatialAnim {
						properties: "x,y"
						duration: Motion.medium
					}
				}

				Repeater {
					model: BarLayout.shelf

					delegate: Chip {
						required property string modelData

						chipId: modelData
						zone: "shelf"
						wide: true
					}
				}
			}

			StyledText {
				anchors.centerIn: parent
				visible: BarLayout.shelf.length === 0 || shelfBox.on
				text: shelfBox.on ? "Let go to take it off the bar" : "Everything is on the bar"
				tone: shelfBox.on ? Theme.danger : Theme.textFaint
				font.pixelSize: Theme.size.small
			}
		}
	}

	// ── what is dragged ──────────────────────────────────────────────────
	Rectangle {
		id: ghost

		readonly property var entry: root.itemOf(root.dragId)

		visible: root.dragId !== ""
		x: root.dragAt.x - root.grabOffset.x
		y: root.dragAt.y - root.grabOffset.y
		z: 100
		width: ghostRow.implicitWidth + 26
		height: root.chipSize
		radius: height / 2
		color: Theme.primary
		scale: visible ? 1.08 : 0.8
		rotation: root.overZone === "shelf" ? -4 : 0

		Behavior on scale {
			SpatialAnim {
				duration: Motion.short
			}
		}
		Behavior on rotation {
			SpatialAnim {
				duration: Motion.short
			}
		}

		layer.enabled: visible
		layer.effect: MultiEffect {
			shadowEnabled: true
			shadowBlur: 0.9
			shadowVerticalOffset: 6
			shadowOpacity: 0.45
			shadowColor: "black"
		}

		RowLayout {
			id: ghostRow

			anchors.centerIn: parent
			spacing: 8

			Glyph {
				icon: ghost.entry.icon ?? "help"
				size: 18
				color: Theme.onPrimary
			}

			StyledText {
				text: ghost.entry.name ?? ""
				tone: Theme.onPrimary
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
			}
		}
	}
}
