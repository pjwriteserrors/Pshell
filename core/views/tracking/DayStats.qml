pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The numbers of the chosen day, in quarter hours as they go to Teamwork.
// The long bar is the 8h day, coloured in the order billable and other time
// was tracked; the two below are the 4h each of them should come to. A
// number that changes runs to its new value.
Rectangle {
	id: root

	readonly property int count: Tracking.entries.length
	readonly property int missing: Math.max(0, Tracking.workdayMinutes - Tracking.minutes)
	// what is shown while it runs
	property real total: Tracking.minutes
	property real billable: Tracking.billableMinutes
	property real unbilled: Tracking.minutes - Tracking.billableMinutes
	readonly property color billableTone: Theme.success
	readonly property color unbilledTone: Theme.primary
	// the stretches as parts of the long bar, which holds 8h or what was tracked
	readonly property var marks: {
		const whole = Math.max(Tracking.workdayMinutes, Tracking.stretches.reduce((sum, part) => sum + part.minutes, 0));
		const out = [];
		let at = 0;
		for (const part of Tracking.stretches) {
			out.push({ from: at / whole, size: part.minutes / whole, billable: part.billable });
			at += part.minutes;
		}
		return out;
	}
	readonly property real filled: root.marks.reduce((sum, mark) => sum + mark.size, 0)
	// how much of the bar is uncovered yet
	property real reach: root.filled

	Behavior on reach {
		Anim {
			duration: Motion.extraLong
			easing.bezierCurve: Motion.decel
		}
	}
	Behavior on unbilled {
		Anim {
			duration: Motion.extraLong
			easing.bezierCurve: Motion.decel
		}
	}
	readonly property real remaining: Math.max(0, Tracking.workdayMinutes - root.total)

	Behavior on total {
		Anim {
			duration: Motion.extraLong
			easing.bezierCurve: Motion.decel
		}
	}
	Behavior on billable {
		Anim {
			duration: Motion.extraLong
			easing.bezierCurve: Motion.decel
		}
	}

	implicitHeight: content.implicitHeight + 32
	radius: Theme.radius.large
	color: Theme.layer1

	component Cell: ColumnLayout {
		id: cell

		property string label: ""
		property string value: ""
		property string hint: ""

		Layout.fillWidth: true
		Layout.preferredWidth: 1
		spacing: 1

		SectionLabel {
			Layout.fillWidth: true
			text: cell.label
		}

		StyledText {
			Layout.fillWidth: true
			text: cell.value
			tabular: true
			font.pixelSize: 24
			font.weight: Font.Bold
		}

		StyledText {
			Layout.fillWidth: true
			text: cell.hint
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}
	}

	component Bar: ColumnLayout {
		id: bar

		property string label: ""
		property real minutes: 0
		property real goal: Tracking.workdayMinutes / 2
		property color tone: Theme.primary

		Layout.fillWidth: true
		spacing: 4

		RowLayout {
			Layout.fillWidth: true

			StyledText {
				Layout.fillWidth: true
				text: bar.label
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}

			StyledText {
				text: `${Tracking.formatMinutes(bar.minutes)} / ${bar.goal / 60}h`
				tone: bar.tone
				tabular: true
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}
		}

		Rectangle {
			Layout.fillWidth: true
			implicitHeight: 6
			radius: 3
			color: Theme.layer3

			Rectangle {
				height: parent.height
				width: parent.width * Math.min(1, bar.minutes / bar.goal)
				radius: 3
				color: bar.tone
			}
		}
	}

	ColumnLayout {
		id: content

		x: 18
		y: 16
		width: parent.width - 36
		spacing: 12

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Cell {
				label: "Tracked"
				value: Tracking.formatMinutes(root.total)
				hint: `actual ${Tracking.report?.total_label ?? "--"}`
			}

			Cell {
				label: Tracking.isToday ? "Remaining" : "Of 8h day"
				value: Tracking.isToday ? Tracking.formatMinutes(root.remaining) : `${Math.round(root.total / Tracking.workdayMinutes * 100)}%`
				hint: Tracking.isToday ? "of an 8h day" : (root.missing > 0 ? `${Tracking.formatMinutes(root.missing)} missing` : "day complete")
			}

			Cell {
				label: Tracking.isToday ? "Done at" : "Entries"
				value: Tracking.isToday ? (root.missing > 0 ? Qt.formatTime(new Date(Date.now() + root.remaining * 60000), "HH:mm") : "now") : String(root.count)
				hint: Tracking.isToday ? (root.missing > 0 ? "estimated" : "day complete") : `${Number(Tracking.report?.project_count) || 0} projects`
			}

			Cell {
				label: "Teamwork"
				value: `${Tracking.sent}/${root.count}`
				hint: Tracking.queued > 0 ? `${Tracking.queued} queued` : (root.count > 0 && Tracking.sent === root.count ? "all sent" : "sent")
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 4

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					Layout.fillWidth: true
					text: "Tracked"
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				StyledText {
					text: `${Tracking.formatMinutes(root.total)} / 8h`
					tabular: true
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}
			}

			Rectangle {
				id: track

				Layout.fillWidth: true
				implicitHeight: 8
				radius: 4
				color: Theme.layer3

				Item {
					width: track.width * root.reach
					height: track.height
					clip: true

					Repeater {
						model: root.marks

						delegate: Rectangle {
							id: mark

							required property var modelData
							required property int index

							x: track.width * mark.modelData.from
							width: track.width * mark.modelData.size
							height: track.height
							topLeftRadius: mark.index === 0 ? 4 : 0
							bottomLeftRadius: mark.index === 0 ? 4 : 0
							topRightRadius: mark.index === root.marks.length - 1 ? 4 : 0
							bottomRightRadius: mark.index === root.marks.length - 1 ? 4 : 0
							color: mark.modelData.billable ? root.billableTone : root.unbilledTone
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 16

			Bar {
				Layout.preferredWidth: 1
				label: "Not billable"
				minutes: root.unbilled
				tone: root.unbilledTone
			}

			Bar {
				Layout.preferredWidth: 1
				label: "Billable"
				minutes: root.billable
				tone: root.billableTone
			}
		}
	}
}
