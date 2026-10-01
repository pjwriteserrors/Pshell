pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Everything about one Microsoft event: when, where, who, the description
// and the links to join or open it. Drawn in the panel below the Today panel.
Item {
	id: root

	property var event: null
	readonly property bool open: root.event !== null
	// the last event stays drawn while the card fades out
	property var shown: null

	onEventChanged: if (root.event) root.shown = root.event

	SystemClock {
		id: clock
		precision: SystemClock.Minutes
	}

	function span(event) {
		const start = new Date(event.start);
		const end = new Date(event.end);
		if (event.allDay) {
			const last = new Date(end.getTime() - 1);
			if (Outlook.dayKey(start) === Outlook.dayKey(last)) return "All day";
			return `${Qt.formatDate(start, "ddd, d. MMM")} – ${Qt.formatDate(last, "ddd, d. MMM")}`;
		}
		if (Outlook.dayKey(start) === Outlook.dayKey(end))
			return `${Qt.formatTime(start, "HH:mm")} – ${Qt.formatTime(end, "HH:mm")}`;
		return `${Qt.formatDateTime(start, "ddd HH:mm")} – ${Qt.formatDateTime(end, "ddd HH:mm")}`;
	}

	function duration(event) {
		const minutes = Math.round((Date.parse(event.end) - Date.parse(event.start)) / 60000);
		if (event.allDay) {
			const days = Math.round(minutes / 1440);
			return days > 1 ? `${days} days` : "";
		}
		const h = Math.floor(minutes / 60);
		const m = minutes % 60;
		return h > 0 ? (m > 0 ? `${h} h ${m} min` : `${h} h`) : `${m} min`;
	}

	function relative(event) {
		const now = clock.date.getTime();
		const start = Date.parse(event.start);
		const end = Date.parse(event.end);
		if (event.cancelled) return "Cancelled";
		if (now >= start && now < end) return event.allDay ? "" : `Now · ${Math.ceil((end - now) / 60000)} min left`;
		if (now >= end) return "";
		const minutes = Math.round((start - now) / 60000);
		if (minutes < 60) return `in ${minutes} min`;
		if (minutes < 24 * 60) return `in ${Math.floor(minutes / 60)} h ${minutes % 60} min`;
		return "";
	}

	function responseLabel(response) {
		return ({
			accepted: "Accepted",
			tentativelyAccepted: "Tentative",
			declined: "Declined",
			organizer: "Organizer",
			notResponded: "Not responded",
			none: "Not responded"
		})[response] ?? response;
	}

	function people(event) {
		const all = (event.attendees ?? []).filter(person => person.type !== "resource");
		const accepted = all.filter(person => person.response === "accepted").length;
		const declined = all.filter(person => person.response === "declined").length;
		const parts = [`${all.length} ${all.length === 1 ? "person" : "people"}`];
		if (accepted > 0) parts.push(`${accepted} accepted`);
		if (declined > 0) parts.push(`${declined} declined`);
		return parts.join(" · ");
	}

	function responseGlyph(response) {
		if (response === "accepted" || response === "organizer") return "check";
		if (response === "declined") return "close";
		if (response === "tentativelyAccepted") return "help_circle_outline";
		return "";
	}

	implicitHeight: column.implicitHeight

	Item {
		id: card

		readonly property var event: root.shown ?? ({})

		anchors.fill: parent

		ColumnLayout {
			id: column

			anchors.fill: parent
			spacing: 12

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				StyledText {
					Layout.fillWidth: true
					text: card.event.subject ?? ""
					font.pixelSize: Theme.size.title
					font.weight: Font.Bold
					font.strikeout: card.event.cancelled ?? false
					wrapMode: Text.Wrap
					maximumLineCount: 3
				}

				IconButton {
					Layout.alignment: Qt.AlignTop
					implicitWidth: 28
					implicitHeight: 28
					icon: "close"
					onClicked: Outlook.selected = null
				}
			}

			// when
			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				Glyph {
					Layout.alignment: Qt.AlignTop
					icon: "clock_outline"
					size: 16
					color: Theme.primary
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 1

					StyledText {
						Layout.fillWidth: true
						text: card.event.start ? Qt.formatDate(new Date(card.event.start), "dddd, d. MMMM yyyy") : ""
						font.pixelSize: Theme.size.body
						font.weight: Font.DemiBold
					}

					StyledText {
						Layout.fillWidth: true
						text: {
							if (!card.event.start) return "";
							const parts = [root.span(card.event), root.duration(card.event), root.relative(card.event)].filter(part => part !== "");
							return parts.join(" · ");
						}
						tabular: true
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}

				Glyph {
					visible: card.event.recurring ?? false
					Layout.alignment: Qt.AlignTop
					icon: "repeat"
					size: 14
					color: Theme.textSubtle
				}

				Glyph {
					visible: card.event.private ?? false
					Layout.alignment: Qt.AlignTop
					icon: "lock_outline"
					size: 14
					color: Theme.textSubtle
				}
			}

			// where
			RowLayout {
				visible: (card.event.location ?? "") !== ""
				Layout.fillWidth: true
				spacing: 10

				Glyph {
					icon: "map_marker"
					size: 16
					color: Theme.textMuted
				}

				StyledText {
					Layout.fillWidth: true
					text: card.event.location ?? ""
					font.pixelSize: Theme.size.small
					wrapMode: Text.Wrap
					maximumLineCount: 2
				}
			}

			// who
			RowLayout {
				visible: (card.event.organizer?.name ?? "") !== ""
				Layout.fillWidth: true
				spacing: 10

				Glyph {
					icon: "account"
					size: 16
					color: Theme.textMuted
				}

				StyledText {
					Layout.fillWidth: true
					text: card.event.isOrganizer ? `${card.event.organizer?.name ?? ""} (you)` : (card.event.organizer?.name ?? "")
					font.pixelSize: Theme.size.small
				}

				StyledText {
					visible: !(card.event.isOrganizer ?? true)
					text: root.responseLabel(card.event.response ?? "none")
					tone: card.event.response === "accepted" ? Theme.success : (card.event.response === "declined" ? Theme.danger : Theme.textSubtle)
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}
			}

			ColumnLayout {
				id: attendees

				property bool expanded: false
				readonly property var list: (card.event.attendees ?? []).filter(person => person.type !== "resource")

				visible: attendees.list.length > 0
				Layout.fillWidth: true
				spacing: 4

				Clickable {
					Layout.fillWidth: true
					implicitHeight: 24
					radius: Theme.radius.small
					pressedScale: 0.99
					onClicked: attendees.expanded = !attendees.expanded

					RowLayout {
						anchors.fill: parent
						spacing: 10

						Glyph {
							icon: "account_multiple"
							size: 16
							color: Theme.textMuted
						}

						StyledText {
							Layout.fillWidth: true
							text: card.event.attendees ? root.people(card.event) : ""
							font.pixelSize: Theme.size.small
						}

						Glyph {
							icon: attendees.expanded ? "chevron_up" : "chevron_down"
							size: 14
							color: Theme.textSubtle
						}
					}
				}

				Repeater {
					model: attendees.expanded ? attendees.list : []

					delegate: RowLayout {
						id: person

						required property var modelData

						Layout.fillWidth: true
						Layout.leftMargin: 26
						spacing: 6

						StyledText {
							Layout.fillWidth: true
							text: person.modelData.name
							tone: person.modelData.type === "optional" ? Theme.textMuted : Theme.text
							font.pixelSize: Theme.size.small
						}

						Glyph {
							visible: root.responseGlyph(person.modelData.response) !== ""
							icon: root.responseGlyph(person.modelData.response)
							size: 12
							color: person.modelData.response === "declined" ? Theme.danger : (person.modelData.response === "accepted" ? Theme.success : Theme.textSubtle)
						}
					}
				}
			}

			// description
			Rectangle {
				visible: (card.event.body ?? "") !== ""
				Layout.fillWidth: true
				Layout.fillHeight: true
				Layout.preferredHeight: Math.min(220, description.implicitHeight + 20)
				Layout.minimumHeight: Math.min(60, description.implicitHeight + 20)
				radius: Theme.radius.medium
				color: Theme.layer1

				Flickable {
					anchors.fill: parent
					anchors.margins: 10
					clip: true
					contentHeight: description.implicitHeight
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					TextEdit {
						id: description

						width: parent.width
						text: card.event.body ?? ""
						readOnly: true
						selectByMouse: true
						wrapMode: TextEdit.Wrap
						color: Theme.textMuted
						selectionColor: Theme.primarySoft
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.small
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				TextButton {
					visible: (card.event.joinUrl ?? "") !== ""
					text: "Join"
					icon: "video"
					variant: "filled"
					onActivated: Outlook.open(card.event.joinUrl)
				}

				TextButton {
					visible: (card.event.webLink ?? "") !== ""
					text: "Open in Outlook"
					icon: "open_in_new"
					onActivated: Outlook.open(card.event.webLink)
				}

				Item {
					Layout.fillWidth: true
				}
			}
		}
	}
}
