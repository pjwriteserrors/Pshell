pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// What an identity's mailbox and number received, newest first. Messages
// are kept with the identity, so they stay when their inbox is gone.
ColumnLayout {
	id: root

	property var identity: null
	property string tab: "mail"
	// the mail that is open
	property string expanded: ""
	property real now: Date.now()

	readonly property var box: root.tab === "mail" ? root.identity?.mail : root.identity?.phone
	readonly property var messages: root.box?.messages ?? []
	readonly property int unread: Identities.unread(root.identity)
	readonly property bool reading: Identities.reading !== "" && Identities.reading === root.identity?.id

	spacing: 10

	onMessagesChanged: root.sync()
	Component.onCompleted: root.sync()

	function row(message) {
		return {
			mid: String(message.id), from: String(message.from || ""), subject: String(message.subject || ""), text: String(message.text || ""),
			body: String(message.body || ""), at: Number(message.at) || 0, seen: root.tab !== "mail" || message.seen === true
		};
	}

	// rows come and go one by one, so the list can show it
	function sync() {
		const list = root.messages;
		const ids = {};
		for (const message of list) ids[String(message.id)] = true;
		for (let i = rows.count - 1; i >= 0; i -= 1)
			if (!ids[rows.get(i).mid]) rows.remove(i);
		for (let i = 0; i < list.length; i += 1) {
			const next = root.row(list[i]);
			let at = -1;
			for (let j = i; j < rows.count && at < 0; j += 1)
				if (rows.get(j).mid === next.mid) at = j;
			if (at < 0) {
				rows.insert(i, next);
				continue;
			}
			if (at !== i) rows.move(at, i, 1);
			rows.set(i, next);
		}
	}

	ListModel {
		id: rows
	}

	Timer {
		running: root.visible
		repeat: true
		interval: 30000
		onTriggered: root.now = Date.now()
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 8

		Segmented {
			Layout.fillWidth: true
			options: [
				{ value: "mail", label: root.unread > 0 ? `Mail · ${root.unread}` : "Mail", icon: "email_outline" },
				{ value: "sms", label: "SMS", icon: "message_outline" }
			]
			current: root.tab
			onSelected: value => {
				root.tab = value;
				root.expanded = "";
			}
		}

		IconButton {
			id: refresh

			icon: "refresh"
			variant: "tonal"
			enabled: root.identity !== null && !Identities.creating
			onClicked: Identities.poll(true)

			RotationAnimator {
				target: refresh
				running: root.reading
				loops: Animation.Infinite
				from: 0
				to: 360
				duration: 900
				onRunningChanged: if (!running) refresh.rotation = 0
			}
		}
	}

	Item {
		Layout.fillWidth: true
		Layout.fillHeight: true

		ListView {
			id: list

			anchors.fill: parent
			clip: true
			spacing: 2
			model: rows
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			delegate: MessageRow {
				required property string mid
				required property bool seen
				required from
				required subject
				required text
				required body
				required at

				width: list.width
				now: root.now
				unseen: !seen
				expandable: root.tab === "mail"
				expanded: root.expanded === mid
				loading: root.identity?.mail?.gone !== true
				onClicked: {
					root.expanded = expanded ? "" : mid;
					if (root.expanded !== "") Identities.read(root.identity.id, mid);
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
						from: 0.92
						to: 1
						duration: Motion.medium
					}
				}
			}
			populate: Transition {
				Anim {
					property: "opacity"
					from: 0
					to: 1
				}
			}
			remove: Transition {
				Anim {
					property: "opacity"
					to: 0
					duration: Motion.short
				}
			}
			displaced: Transition {
				SpatialAnim {
					properties: "x,y"
					duration: Motion.medium
				}
			}
		}

		EmptyState {
			anchors.centerIn: parent
			visible: opacity > 0.01
			opacity: rows.count === 0 ? 1 : 0
			icon: root.tab === "mail" ? "email_open_outline" : "message_outline"
			title: root.tab === "mail" ? "No mail yet" : "No SMS yet"

			Behavior on opacity {
				Anim {}
			}
		}
	}
}
