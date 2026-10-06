pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A mail before it is sent, as it reaches who it goes to: its recipients and
// subject, and on white paper everything it carries – what was written, the
// signature and every older mail quoted below. It lies over the pane it was
// asked from; `send` sends what is shown.
Rectangle {
	id: root

	property bool open: false
	property var draft: null
	// { to, cc, bcc, subject, page } once it is drawn
	property var mail: null
	property string error: ""
	property int pending: 0
	property bool busy: false
	readonly property var attached: (root.draft?.files ?? []).map(path => String(path).split("/").pop())

	signal send

	function show(draft) {
		root.draft = draft;
		root.mail = null;
		root.error = "";
		root.open = true;
		root.pending = Mail.preview(draft);
	}

	function close() {
		root.open = false;
		root.pending = 0;
	}

	function names(people) {
		return (people ?? []).map(person => {
			const name = person.name !== person.email ? person.name : Mail.nameOf(person.email);
			return name === person.email ? person.email : `${name} <${person.email}>`;
		}).join(", ");
	}

	color: Theme.base
	opacity: root.open ? 1 : 0
	visible: opacity > 0.01
	transform: Translate {
		y: root.open ? 0 : 16

		Behavior on y {
			SpatialAnim {
				duration: Motion.medium
			}
		}
	}

	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}

	Connections {
		target: Mail
		function onPreviewed(request, ok, mail) {
			if (request !== root.pending) return;
			root.pending = 0;
			if (ok) root.mail = mail;
			else root.error = mail.error || "No preview";
		}
	}

	// nothing below is reached while it is up
	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		hoverEnabled: true
		onWheel: wheel => wheel.accepted = true
	}

	Shortcut {
		sequence: "Escape"
		enabled: root.open
		onActivated: root.close()
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			IconButton {
				icon: "arrow_left"
				variant: "tonal"
				onClicked: root.close()
			}

			StyledText {
				Layout.fillWidth: true
				text: "Preview"
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			TextButton {
				text: "Send"
				icon: "send"
				variant: "filled"
				busy: root.busy
				enabled: root.mail !== null && !root.busy
				onActivated: root.send()
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			visible: root.mail !== null
			spacing: 4

			Repeater {
				model: root.mail ? [
					{ label: "To", text: root.names(root.mail.to) },
					{ label: "Cc", text: root.names(root.mail.cc) },
					{ label: "Bcc", text: root.names(root.mail.bcc) },
					{ label: "Subject", text: root.mail.subject },
					{ label: "Files", text: root.attached.join(", ") }
				].filter(line => line.text !== "") : []

				delegate: Item {
					id: line

					required property var modelData

					Layout.fillWidth: true
					implicitHeight: value.implicitHeight

					StyledText {
						width: 56
						text: line.modelData.label
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.label
					}

					StyledText {
						id: value

						x: 62
						width: parent.width - 62
						text: line.modelData.text
						wrapMode: Text.Wrap
						font.pixelSize: Theme.size.label
						font.weight: line.modelData.label === "Subject" ? Font.DemiBold : Font.Normal
					}
				}
			}
		}

		Flickable {
			id: scroll

			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: root.mail !== null
			clip: true
			contentWidth: width
			contentHeight: paper.height + 12
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			Rectangle {
				id: paper

				x: Math.round((scroll.width - width) / 2)
				width: Math.min(scroll.width - 12, root.mail?.page.width ?? 600)
				height: sheet.implicitHeight
				radius: Theme.radius.medium
				color: "white"
				clip: true

				Sheet {
					id: sheet

					width: parent.width
					page: root.mail?.page ?? null
				}
			}
		}

		Item {
			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: root.mail === null

			Spinner {
				anchors.centerIn: parent
				visible: root.error === ""
				width: 26
				height: 26
			}

			EmptyState {
				anchors.centerIn: parent
				visible: root.error !== ""
				icon: "alert_circle"
				title: root.error
			}
		}
	}
}
