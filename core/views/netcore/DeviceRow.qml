pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A device of every service on the Server page: what it is, where it was
// last seen, what it may do in each service (chips: a click gives or takes
// a cap), and renaming, a new token (shown once) and revoking. Rotating and
// revoking ask first; revoking the device this PC uses says so.
Rectangle {
	id: root

	required property var device
	property int index: 0
	// { service: [caps it may get] }
	property var choices: ({})

	readonly property string deviceId: String(root.device?.id ?? "")
	readonly property string name: String(root.device?.name ?? root.deviceId)
	readonly property var scopes: root.device?.scopes ?? ({})
	readonly property bool online: !!root.device?.online
	readonly property bool mine: Netcore.me?.device?.id !== undefined && Netcore.me.device.id === root.deviceId
	property bool editing: false
	// rotate | revoke while it asks
	property string asking: ""
	property bool busy: false
	property string token: ""
	property real enter: 0

	Layout.fillWidth: true
	implicitHeight: column.implicitHeight + 24
	radius: Theme.radius.large
	color: hover.hovered ? Theme.layer2 : "transparent"
	opacity: root.enter
	transform: Translate {
		x: (1 - root.enter) * -12
	}

	Behavior on color {
		ColorAnim {}
	}

	SequentialAnimation {
		running: true

		PauseAnimation {
			duration: Math.min(root.index, 12) * 35
		}
		NumberAnimation {
			target: root
			property: "enter"
			to: 1
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
	}

	HoverHandler {
		id: hover
	}

	function has(service, cap) {
		return (root.scopes[service] ?? []).includes(cap);
	}

	function toggle(service, cap) {
		const next = JSON.parse(JSON.stringify(root.scopes));
		const caps = next[service] ?? [];
		next[service] = caps.includes(cap) ? caps.filter(c => c !== cap) : caps.concat([cap]);
		if (next[service].length === 0) delete next[service];
		Netcore.setScopes(root.deviceId, next);
	}

	ColumnLayout {
		id: column

		x: 10
		y: 12
		width: parent.width - 20
		spacing: 8

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Rectangle {
				Layout.preferredWidth: 36
				Layout.preferredHeight: 36
				radius: 18
				color: root.mine ? Theme.primarySoft : Theme.layer2

				Glyph {
					anchors.centerIn: parent
					icon: Netcore.kindIcon(root.device?.kind)
					size: 18
					color: root.mine ? Theme.primary : Theme.text
				}

				Rectangle {
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					width: 11
					height: 11
					radius: 5.5
					color: root.online ? Theme.success : Theme.textFaint
					border.width: 2
					border.color: Theme.layer1
					scale: root.online ? 1 : 0.7

					Behavior on scale {
						SpatialAnim {}
					}
					Behavior on color {
						ColorAnim {}
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1
				visible: !root.editing

				StyledText {
					Layout.fillWidth: true
					text: root.mine ? `${root.name}  ·  this PC` : root.name
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					text: {
						const d = root.device ?? {};
						const seen = root.online ? "online" : (d.last_seen ? `seen ${Netcore.ago(d.last_seen)}` : "never seen");
						return [d.kind ?? "", seen, d.last_service ? `via ${d.last_service}` : "", d.last_ip ?? "", d.by ? `added by ${d.by}` : ""].filter(s => s).join(" · ");
					}
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			Field {
				id: nameField

				Layout.fillWidth: true
				visible: root.editing
				text: root.name
				placeholder: "Name"
				onAccepted: {
					if (nameField.text.trim() !== "" && nameField.text.trim() !== root.name) Netcore.renameDevice(root.deviceId, nameField.text.trim());
					root.editing = false;
				}
				onEscapePressed: root.editing = false
			}

			IconButton {
				visible: Netcore.admin && !root.editing && (hover.hovered || root.asking !== "")
				implicitWidth: 30
				implicitHeight: 30
				icon: "pencil_outline"
				onClicked: {
					nameField.text = root.name;
					root.editing = true;
					nameField.input.forceActiveFocus();
				}
			}

			IconButton {
				visible: root.editing
				implicitWidth: 30
				implicitHeight: 30
				icon: "check"
				onClicked: nameField.accepted()
			}

			IconButton {
				visible: Netcore.admin && !root.editing && (hover.hovered || root.asking !== "")
				implicitWidth: 30
				implicitHeight: 30
				icon: "key_variant"
				onClicked: root.asking = "rotate"
			}

			IconButton {
				visible: Netcore.admin && !root.editing && (hover.hovered || root.asking !== "")
				implicitWidth: 30
				implicitHeight: 30
				icon: "delete_outline"
				variant: "danger"
				onClicked: root.asking = "revoke"
			}
		}

		// what it may do, per service
		Flow {
			Layout.fillWidth: true
			Layout.leftMargin: 48
			spacing: 6

			Repeater {
				model: Object.keys(root.choices).filter(service => (root.choices[service] ?? []).length > 0 || (root.scopes[service] ?? []).length > 0)

				delegate: Row {
					id: group

					required property string modelData

					spacing: 4

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: group.modelData
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
						rightPadding: 2
					}

					Repeater {
						model: {
							const caps = (root.choices[group.modelData] ?? []).slice();
							for (const cap of root.scopes[group.modelData] ?? []) if (!caps.includes(cap)) caps.push(cap);
							return caps;
						}

						delegate: Chip {
							required property string modelData

							implicitHeight: 24
							text: modelData
							selected: root.has(group.modelData, modelData)
							accent: modelData === "admin" ? Theme.warning : Theme.primary
							interactive: Netcore.admin
							onClicked: root.toggle(group.modelData, modelData)
						}
					}

					Item {
						width: 8
						height: 1
					}
				}
			}
		}

		Ask {
			open: root.asking !== ""
			busy: root.busy
			icon: root.asking === "rotate" ? "key_variant" : "delete_outline"
			title: root.asking === "rotate" ? `A new token for ${root.name}?` : `Revoke ${root.name}?`
			detail: {
				if (root.asking === "rotate") return root.mine ? "This PC's own token: nas.json has to get the new one, or the NAS and core stop answering this PC." : "The old token stops working at once; the new one is shown here once.";
				return root.mine ? "This is the device this PC signs in with – the NAS, the mount and this page stop working here." : "It cannot reach any service anymore; a new token has to be made to bring it back.";
			}
			confirmText: root.asking === "rotate" ? "New token" : "Revoke"
			onAccepted: {
				root.busy = true;
				if (root.asking === "rotate") {
					Netcore.rotateDevice(root.deviceId, token => {
						root.busy = false;
						root.asking = "";
						root.token = token;
					});
				} else {
					Netcore.revokeDevice(root.deviceId, () => {
						root.busy = false;
						root.asking = "";
					});
				}
			}
			onCancelled: root.asking = ""
		}

		// the new token, once
		Rectangle {
			Layout.fillWidth: true
			visible: root.token !== ""
			implicitHeight: tokenColumn.implicitHeight + 20
			radius: Theme.radius.large
			color: Theme.primaryContainer

			ColumnLayout {
				id: tokenColumn

				x: 12
				y: 10
				width: parent.width - 24
				spacing: 6

				StyledText {
					Layout.fillWidth: true
					text: "Shown once – put it into the device now"
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: `device ${root.deviceId}\ntoken ${root.token}`
					font.family: Theme.monoFamily
					font.pixelSize: Theme.size.small
					wrapMode: Text.WrapAnywhere
				}

				RowLayout {
					Layout.fillWidth: true

					Item {
						Layout.fillWidth: true
					}

					TextButton {
						text: "Copy"
						icon: "content_copy"
						onActivated: Quickshell.execDetached(["wl-copy", "--", root.token])
					}

					TextButton {
						text: "Done"
						variant: "ghost"
						onActivated: root.token = ""
					}
				}
			}
		}
	}
}
