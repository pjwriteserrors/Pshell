pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The Microsoft events of one day under the month grid, or the sign-in.
ColumnLayout {
	id: root

	property date day: new Date()
	readonly property var events: MsCalendar.eventsOn(root.day)
	readonly property int rowHeight: 48

	SystemClock {
		id: clock
		precision: SystemClock.Minutes
	}

	function dayTitle() {
		const today = new Date(clock.date.getFullYear(), clock.date.getMonth(), clock.date.getDate());
		const diff = Math.round((new Date(root.day.getFullYear(), root.day.getMonth(), root.day.getDate()) - today) / 86400000);
		if (diff === 0) return "Today";
		if (diff === 1) return "Tomorrow";
		if (diff === -1) return "Yesterday";
		return Qt.formatDate(root.day, "ddd, d. MMMM");
	}

	function timeLabel(event) {
		if (event.allDay) return "All day";
		const start = new Date(event.start);
		const end = new Date(event.end);
		const key = MsCalendar.dayKey(root.day);
		const from = MsCalendar.dayKey(start) === key ? Qt.formatTime(start, "HH:mm") : "…";
		const to = MsCalendar.dayKey(end) === key ? Qt.formatTime(end, "HH:mm") : "…";
		return `${from} – ${to}`;
	}

	visible: MsCalendar.enabled && MsCalendar.checked
	spacing: 6

	// ── signed out ───────────────────────────────────────────────────────
	TextButton {
		visible: !MsCalendar.signedIn && !MsCalendar.signingIn
		Layout.fillWidth: true
		text: "Sign in to Microsoft"
		icon: "microsoft"
		onActivated: MsCalendar.signIn()
	}

	RowLayout {
		visible: !MsCalendar.signedIn && MsCalendar.signingIn
		Layout.fillWidth: true
		spacing: 8

		Spinner {
			visible: MsCalendar.loginCode === ""
			Layout.preferredWidth: 16
			Layout.preferredHeight: 16
		}

		StyledText {
			visible: MsCalendar.loginCode !== ""
			text: MsCalendar.loginCode
			font.family: Theme.monoFamily
			font.pixelSize: Theme.size.heading
			font.weight: Font.Bold
			font.letterSpacing: 2
		}

		Item {
			Layout.fillWidth: true
		}

		TextButton {
			visible: MsCalendar.loginCode !== ""
			text: "Copy & open"
			icon: "open_in_new"
			variant: "filled"
			onActivated: MsCalendar.openSignInPage()
		}

		IconButton {
			icon: "close"
			onClicked: MsCalendar.cancelSignIn()
		}
	}

	StyledText {
		visible: MsCalendar.error !== ""
		Layout.fillWidth: true
		text: MsCalendar.error
		tone: Theme.danger
		font.pixelSize: Theme.size.small
		wrapMode: Text.Wrap
		maximumLineCount: 3
	}

	// ── signed in ────────────────────────────────────────────────────────
	RowLayout {
		visible: MsCalendar.signedIn
		Layout.fillWidth: true
		spacing: 6

		StyledText {
			Layout.fillWidth: true
			text: root.dayTitle()
			tone: Theme.textMuted
			font.pixelSize: Theme.size.label
			font.weight: Font.Bold
		}

		Spinner {
			visible: MsCalendar.loading
			Layout.preferredWidth: 12
			Layout.preferredHeight: 12
		}

		IconButton {
			implicitWidth: 26
			implicitHeight: 26
			icon: "refresh"
			onClicked: MsCalendar.refresh()
		}

		// two clicks, it sits next to refresh
		IconButton {
			id: signOut

			property bool armed: false

			implicitWidth: 26
			implicitHeight: 26
			icon: signOut.armed ? "alert" : "logout"
			variant: signOut.armed ? "danger" : "ghost"
			onClicked: {
				if (signOut.armed)
					MsCalendar.signOut();
				signOut.armed = !signOut.armed;
				disarm.restart();
			}

			Timer {
				id: disarm
				interval: 2600
				onTriggered: signOut.armed = false
			}
		}
	}

	StyledText {
		visible: MsCalendar.signedIn && root.events.length === 0
		Layout.fillWidth: true
		text: "No events"
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
	}

	ListView {
		id: list

		visible: MsCalendar.signedIn && root.events.length > 0
		Layout.fillWidth: true
		Layout.preferredHeight: Math.min(4, root.events.length) * (root.rowHeight + spacing) - spacing
		clip: true
		spacing: 4
		model: root.events
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: Clickable {
			id: row

			required property var modelData
			readonly property bool running: !modelData.allDay && Date.parse(modelData.start) <= clock.date.getTime() && clock.date.getTime() < Date.parse(modelData.end)
			readonly property bool picked: MsCalendar.selected?.id === modelData.id && MsCalendar.selected?.start === modelData.start
			readonly property bool faded: !MsCalendar.active(modelData) || modelData.showAs === "free"

			width: ListView.view.width
			height: root.rowHeight
			radius: Theme.radius.medium
			pressedScale: 0.98
			color: row.picked ? Theme.primarySoft : (row.hovered ? Theme.layer1 : (row.running ? Qt.alpha(Theme.primary, 0.07) : "transparent"))
			onClicked: MsCalendar.select(modelData)

			Rectangle {
				x: 6
				anchors.verticalCenter: parent.verticalCenter
				width: 3
				height: parent.height - 16
				radius: 2
				color: row.modelData.showAs === "tentative" ? Qt.alpha(Theme.primary, 0.45) : (row.faded ? Theme.textFaint : Theme.primary)
			}

			ColumnLayout {
				anchors.fill: parent
				anchors.leftMargin: 18
				anchors.rightMargin: 10
				spacing: 1

				StyledText {
					Layout.fillWidth: true
					text: row.modelData.subject
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
					font.strikeout: row.modelData.cancelled
					opacity: row.faded ? 0.55 : 1
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					StyledText {
						text: root.timeLabel(row.modelData)
						tabular: true
						tone: row.running ? Theme.primary : Theme.textMuted
						font.pixelSize: Theme.size.small
						font.weight: row.running ? Font.Bold : Font.Normal
					}

					Glyph {
						visible: row.modelData.online
						icon: "video"
						size: 12
						color: Theme.textMuted
					}

					StyledText {
						Layout.fillWidth: true
						visible: row.modelData.location !== ""
						text: row.modelData.location
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}
			}
		}
	}
}
