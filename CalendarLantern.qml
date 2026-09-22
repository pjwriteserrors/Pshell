pragma ComponentBehavior: Bound

import QtQuick
import "components"

// The month as weeks strung on wires. Each week is a filament, each day a
// knot on it; today is the spark. The wheel or the two beads at the top
// move a month at a time, and "today" slides the light back home.
Item {
	id: calendar

	property real reveal: 1
	property var now: new Date()
	property var viewDate: new Date()
	readonly property var weekdayNames: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
	readonly property int monthOffset: (new Date(viewDate.getFullYear(), viewDate.getMonth(), 1).getDay() + 6) % 7
	readonly property int daysInMonth: new Date(viewDate.getFullYear(), viewDate.getMonth() + 1, 0).getDate()
	readonly property bool viewingToday: viewDate.getFullYear() === now.getFullYear() && viewDate.getMonth() === now.getMonth()
	readonly property int weekCount: Math.ceil((monthOffset + daysInMonth) / 7)

	implicitHeight: column.implicitHeight

	function shiftMonths(delta) {
		calendar.viewDate = new Date(viewDate.getFullYear(), viewDate.getMonth() + delta, 1);
	}

	function dayNumber(index) {
		const day = index - monthOffset + 1;
		return day >= 1 && day <= daysInMonth ? day : 0;
	}

	Timer {
		interval: 30000; running: true; repeat: true; triggeredOnStart: true
		onTriggered: calendar.now = new Date()
	}

	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.NoButton
		onWheel: wheel => calendar.shiftMonths(wheel.angleDelta.y < 0 ? 1 : -1)
	}

	Column {
		id: column
		width: parent.width
		spacing: 10

		Band {
			reveal: calendar.reveal
			order: 0
			width: parent.width
			height: 34

			FButton {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				icon: "go-previous-symbolic"
				kind: "ghost"
				square: true
				compact: true
				onClicked: calendar.shiftMonths(-1)
			}

			Column {
				anchors.centerIn: parent
				spacing: 1
				FText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: Qt.formatDate(calendar.viewDate, "MMMM yyyy")
					font.pixelSize: Filament.textLg
					font.weight: Font.DemiBold
				}
				FText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: Qt.formatDate(calendar.now, "dddd, d MMMM")
					tone: "mute"
					font.pixelSize: Filament.textXs
				}
			}

			FButton {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				icon: "go-next-symbolic"
				kind: "ghost"
				square: true
				compact: true
				onClicked: calendar.shiftMonths(1)
			}
		}

		Band {
			reveal: calendar.reveal
			order: 1
			width: parent.width
			height: 16
			Row {
				width: parent.width
				Repeater {
					model: calendar.weekdayNames
					FText {
						required property string modelData
						required property int index
						width: parent.width / 7
						text: modelData
						horizontalAlignment: Text.AlignHCenter
						tone: index >= 5 ? "faint" : "mute"
						font.pixelSize: Filament.textXs
						caps: true
					}
				}
			}
		}

		Repeater {
			model: calendar.weekCount
			Band {
				id: week
				required property int index
				reveal: calendar.reveal
				order: 2 + index
				width: column.width
				height: 34

				Wire {
					anchors.verticalCenter: parent.verticalCenter
					x: parent.width / 14
					width: parent.width - parent.width / 7
					height: 2
					cold: Filament.wireDim
				}

				Row {
					width: parent.width
					height: parent.height
					Repeater {
						model: 7
						Item {
							id: day
							required property int index
							readonly property int number: calendar.dayNumber(week.index * 7 + index)
							readonly property bool isToday: calendar.viewingToday && number === calendar.now.getDate()
							readonly property bool weekend: index >= 5
							readonly property bool hovered: dayTouch.containsMouse && number > 0
							width: parent.width / 7
							height: parent.height

							MouseArea {
								id: dayTouch
								anchors.fill: parent
								hoverEnabled: true
							}

							Rectangle {
								anchors.centerIn: parent
								width: day.isToday ? 26 : (day.hovered ? 22 : (day.number > 0 ? 8 : 4))
								height: width
								radius: width / 2
								color: day.isToday ? Filament.charge
									: (day.hovered ? Filament.planeRaised : (day.number > 0 ? Filament.planeSolid : Filament.wireDim))
								border.width: day.isToday ? 0 : (day.number > 0 ? 1 : 0)
								border.color: day.hovered ? Filament.charge : (day.weekend ? Filament.wireDim : Filament.wire)
								Behavior on width { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.05 } }
								Behavior on color { ColorAnimation { duration: Filament.quick } }

								Rectangle {
									anchors.centerIn: parent
									width: 40; height: 40; radius: 20
									color: Qt.alpha(Filament.charge, 0.18)
									visible: day.isToday
									z: -1
								}
							}

							FText {
								anchors.centerIn: parent
								anchors.verticalCenterOffset: day.isToday || day.hovered ? 0 : -14
								text: day.number > 0 ? String(day.number) : ""
								mono: true
								font.pixelSize: Filament.textXs
								font.weight: day.isToday ? Font.Bold : Font.Medium
								color: day.isToday ? Filament.onCharge : (day.hovered ? Filament.ink : (day.weekend ? Filament.inkFaint : Filament.inkMute))
								Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: Filament.quick; easing.type: Easing.OutCubic } }
							}
						}
					}
				}
			}
		}

		Band {
			reveal: calendar.reveal
			order: 2 + calendar.weekCount
			width: parent.width
			height: 28
			FButton {
				anchors.horizontalCenter: parent.horizontalCenter
				text: calendar.viewingToday ? Qt.formatDate(calendar.now, "'Week' %1").arg(calendar.weekOfYear(calendar.now)) : "Back to today"
				kind: "ghost"
				compact: true
				enabled: !calendar.viewingToday
				opacity: 1
				onClicked: calendar.viewDate = new Date(calendar.now.getFullYear(), calendar.now.getMonth(), 1)
			}
		}
	}

	function weekOfYear(date) {
		const target = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
		const dayNum = target.getUTCDay() || 7;
		target.setUTCDate(target.getUTCDate() + 4 - dayNum);
		const yearStart = new Date(Date.UTC(target.getUTCFullYear(), 0, 1));
		return Math.ceil((((target - yearStart) / 86400000) + 1) / 7);
	}
}
