pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The asteroids of the week (core/services/Asteroids.qml): the radar, what
// is known about the picked one, and the week as a line with a dot where
// each comes closest. Dragging along the line moves the radar through the
// week; let go, it returns to now.
Rectangle {
	id: root

	// the card is on the screen
	property bool shown: false
	// designation of the picked asteroid
	property string selected: ""

	signal closed

	readonly property int index: Asteroids.objects.findIndex(object => object.des === root.selected)
	readonly property var object: root.index >= 0 ? Asteroids.objects[root.index] : null

	function move(by) {
		const count = Asteroids.objects.length;
		if (count === 0) return;
		root.selected = Asteroids.objects[((Math.max(0, root.index) + by) % count + count) % count].des;
	}

	// what is picked passes, or the next one
	function settle() {
		if (root.index < 0) root.selected = Asteroids.next?.des ?? "";
	}

	implicitHeight: column.implicitHeight + 28
	radius: Theme.radius.huge
	color: Theme.layer1

	onShownChanged: if (root.shown) root.selected = Asteroids.next?.des ?? ""
	onObjectChanged: {
		if (!root.object) root.settle();
		else change.restart();
	}

	ColumnLayout {
		id: column

		x: 16
		y: 14
		width: parent.width - 32
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			SectionLabel {
				Layout.fillWidth: true
				text: "Asteroids"
			}

			StyledText {
				text: Qt.formatDateTime(new Date(Math.round(radar.time / 600000) * 600000), "ddd HH:mm")
				tone: Theme.primary
				tabular: true
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				opacity: scrub.pressed && isFinite(radar.held) ? 1 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
			}

			IconButton {
				implicitWidth: 26
				implicitHeight: 26
				icon: "close"
				onClicked: root.closed()
			}
		}

		Radar {
			id: radar

			Layout.fillWidth: true
			Layout.leftMargin: -8
			Layout.rightMargin: -8
			Layout.topMargin: -18
			Layout.bottomMargin: -6
			implicitHeight: 212
			shown: root.shown
			selected: root.selected
			onPicked: des => root.selected = des
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 4

			IconButton {
				implicitWidth: 28
				implicitHeight: 28
				icon: "chevron_left"
				onClicked: root.move(-1)
			}

			ColumnLayout {
				id: facts

				Layout.fillWidth: true
				spacing: 0

				// the one picked last stays readable while it changes
				property string name: ""
				property string moment: ""

				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignHCenter
					text: facts.name
					font.pixelSize: Theme.size.title
					font.weight: Font.Bold
				}

				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignHCenter
					text: root.object ? `${Asteroids.when(root.object.at, radar.time)}  ·  ${facts.moment}` : ""
					tone: Theme.textMuted
					tabular: true
					font.pixelSize: Theme.size.small
				}

				transform: Translate {
					id: shift
				}

				SequentialAnimation {
					id: change

					ParallelAnimation {
						Anim {
							target: facts
							property: "opacity"
							to: 0
							duration: Motion.micro
						}
						Anim {
							target: shift
							property: "y"
							to: 5
							duration: Motion.micro
						}
					}
					ScriptAction {
						script: {
							facts.name = root.object?.name ?? "";
							facts.moment = root.object ? Qt.formatDateTime(new Date(root.object.at), "ddd HH:mm") : "";
							shift.y = -5;
						}
					}
					ParallelAnimation {
						Anim {
							target: facts
							property: "opacity"
							to: 1
							duration: Motion.short
						}
						SpatialAnim {
							target: shift
							property: "y"
							to: 0
							duration: Motion.medium
						}
					}
				}
			}

			IconButton {
				implicitWidth: 28
				implicitHeight: 28
				icon: "chevron_right"
				onClicked: root.move(1)
			}
		}

		Row {
			Layout.alignment: Qt.AlignHCenter
			spacing: 6

			Repeater {
				model: [
					{ icon: "target", text: root.object ? Asteroids.distance(root.object.dist) : "--" },
					{ icon: "speedometer", text: root.object ? `${root.object.speed.toFixed(1)} km/s` : "--" },
					{ icon: "arrow_expand_horizontal", text: Asteroids.size(root.object) }
				]

				delegate: Rectangle {
					id: pill

					required property var modelData

					height: 26
					width: metric.implicitWidth + 18
					radius: 13
					color: Theme.layer2

					Behavior on width {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					RowLayout {
						id: metric

						anchors.centerIn: parent
						spacing: 4
						Glyph { icon: pill.modelData.icon; size: 13; color: Theme.textMuted }
						StyledText { text: pill.modelData.text; tabular: true; font.pixelSize: Theme.size.small; font.weight: Font.Medium }
					}
				}
			}
		}

		// the week
		Item {
			id: week

			Layout.fillWidth: true
			Layout.topMargin: 2
			implicitHeight: 36

			readonly property real inset: 7
			readonly property real span: Math.max(1, Asteroids.until - Asteroids.from)
			// the middle of every day the week touches
			readonly property var days: {
				const out = [];
				const day = new Date(Asteroids.from);
				day.setHours(12, 0, 0, 0);
				for (; day.getTime() - 43200000 < Asteroids.until; day.setDate(day.getDate() + 1)) {
					if (day.getTime() < Asteroids.from + 21600000 || day.getTime() > Asteroids.until - 21600000) continue;
					out.push({ at: day.getTime(), label: Qt.formatDateTime(day, "ddd"), today: day.toDateString() === new Date(Asteroids.clock).toDateString() });
				}
				return out;
			}

			function place(time) {
				return week.inset + (week.width - week.inset * 2) * (time - Asteroids.from) / week.span;
			}

			function timeAt(x) {
				return Asteroids.from + week.span * Math.max(0, Math.min(1, (x - week.inset) / (week.width - week.inset * 2)));
			}

			// designation of the dot at x
			function dotAt(x) {
				let best = "";
				let reach = 7;
				for (const object of Asteroids.objects) {
					const distance = Math.abs(week.place(object.at) - x);
					if (distance < reach) {
						reach = distance;
						best = object.des;
					}
				}
				return best;
			}

			Rectangle {
				x: week.inset
				y: 9
				width: parent.width - week.inset * 2
				height: 2
				radius: 1
				color: Theme.layer3
			}

			Rectangle {
				x: week.inset
				y: 9
				width: Math.max(0, hand.x + hand.width / 2 - week.inset)
				height: 2
				radius: 1
				color: Qt.alpha(Theme.primary, 0.55)
			}

			Repeater {
				model: week.days

				delegate: StyledText {
					required property var modelData

					x: week.place(modelData.at) - width / 2
					y: 21
					text: modelData.label
					tone: modelData.today ? Theme.primary : Theme.textSubtle
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
				}
			}

			Repeater {
				model: Asteroids.objects

				delegate: Rectangle {
					id: dot

					required property var modelData
					readonly property bool chosen: dot.modelData.des === root.selected
					readonly property bool pointed: dot.modelData.des === radar.hovered

					x: week.place(dot.modelData.at) - width / 2
					y: 10 - height / 2
					z: dot.chosen ? 2 : 1
					width: dot.chosen ? 10 : (dot.pointed ? 8 : 6)
					height: width
					radius: width / 2
					color: dot.chosen ? Theme.primary : Qt.tint(Theme.layer1, Qt.alpha(dot.modelData.dist < 1 ? Theme.warning : Theme.text, dot.pointed ? 0.95 : 0.6))
					border.width: dot.chosen ? 2 : 0
					border.color: Theme.layer1

					Behavior on width {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}
			}

			Rectangle {
				id: hand

				x: week.place(radar.time) - width / 2
				y: 10 - height / 2
				z: 3
				width: 3
				height: scrub.pressed ? 20 : 14
				radius: 1.5
				color: Theme.text

				Behavior on height {
					SpatialAnim {
						duration: Motion.short
					}
				}
			}

			MouseArea {
				id: scrub

				// the dot the press began on, as long as it has not moved
				property string dot: ""
				property real pressedAt: 0

				anchors.fill: parent
				anchors.margins: -4
				hoverEnabled: true
				preventStealing: true
				cursorShape: Qt.PointingHandCursor

				onPressed: mouse => {
					scrub.pressedAt = mouse.x;
					scrub.dot = week.dotAt(mouse.x - 4);
					if (scrub.dot === "") radar.held = week.timeAt(mouse.x - 4);
				}
				onPositionChanged: mouse => {
					if (!scrub.pressed) {
						radar.hovered = week.dotAt(mouse.x - 4);
						return;
					}
					if (scrub.dot !== "" && Math.abs(mouse.x - scrub.pressedAt) < 4) return;
					scrub.dot = "";
					radar.hovered = "";
					radar.held = week.timeAt(mouse.x - 4);
				}
				onReleased: {
					if (scrub.dot !== "") root.selected = scrub.dot;
					scrub.dot = "";
					radar.held = Number.NaN;
				}
				onCanceled: {
					scrub.dot = "";
					radar.held = Number.NaN;
				}
				onExited: radar.hovered = ""
			}
		}
	}
}
