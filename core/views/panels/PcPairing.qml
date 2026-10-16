pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The other PCs with Pshell paired with this one, what goes between them
// right now, and pairing another: the code it shows (Pair a phone or PC,
// over there) is typed in here, the PC picked from those on the LAN or
// given by its address.
ColumnLayout {
	id: root

	spacing: 8
	visible: Pcs.enabled

	property bool asking: false
	property string picked: ""
	property bool busy: false
	property string problem: ""

	function pair() {
		const target = codeField.text.trim().startsWith("pshell://") ? { link: codeField.text.trim() }
			: addressField.text.trim() !== "" ? { address: addressField.text.trim() }
			: root.picked !== "" ? { nearby: root.picked }
			: null;
		if (!target) {
			root.problem = "Pick the PC, or give its address";
			return;
		}
		root.busy = true;
		root.problem = "";
		Pcs.pair(codeField.text, target, (data, error) => {
			root.busy = false;
			if (error) {
				root.problem = String(error.message || error.code);
				return;
			}
			root.asking = false;
			codeField.text = "";
			addressField.text = "";
			root.picked = "";
		});
	}

	SectionLabel {
		text: "Other PCs"
	}

	Repeater {
		model: Pcs.devices

		delegate: ListItem {
			id: device

			required property var modelData

			Layout.fillWidth: true
			icon: device.modelData.connected ? "laptop" : "laptop_off"
			title: device.modelData.name
			subtitle: device.modelData.connected ? `Connected · ${device.modelData.address}${device.modelData.files ? " · shares its files" : ""}`
				: device.modelData.incoming ? "It reaches this PC, this PC does not reach it"
				: "Not connected"
			selected: device.modelData.connected

			IconButton {
				implicitWidth: 32
				implicitHeight: 32
				visible: device.modelData.connected
				icon: "content_paste"
				onClicked: Pcs.sendClipboard(device.modelData.id)
			}

			TextButton {
				text: "Remove"
				variant: "ghost"
				confirm: true
				onActivated: Pcs.remove(device.modelData.id)
			}
		}
	}

	// what is on its way
	Repeater {
		model: Pcs.transfers

		delegate: RowLayout {
			id: transfer

			required property var modelData

			Layout.fillWidth: true
			spacing: 8

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 4

				StyledText {
					Layout.fillWidth: true
					text: `${transfer.modelData.direction === "out" ? "To" : "From"} ${Pcs.nameOf(transfer.modelData.id)} · ${transfer.modelData.files + 1 > transfer.modelData.count ? transfer.modelData.count : transfer.modelData.files + 1}/${transfer.modelData.count} · ${transfer.modelData.name}`
					elide: Text.ElideMiddle
					font.pixelSize: Theme.size.small
				}

				Rectangle {
					Layout.fillWidth: true
					implicitHeight: 4
					radius: 2
					color: Theme.layer2

					Rectangle {
						width: parent.width * Math.min(1, transfer.modelData.size > 0 ? transfer.modelData.done / transfer.modelData.size : 0)
						height: parent.height
						radius: 2
						color: Theme.primary
					}
				}
			}

			IconButton {
				implicitWidth: 28
				implicitHeight: 28
				icon: "close"
				onClicked: Pcs.cancel(transfer.modelData.transfer)
			}
		}
	}

	Rectangle {
		Layout.fillWidth: true
		visible: root.asking
		implicitHeight: form.implicitHeight + 28
		radius: Theme.radius.large
		color: Theme.layer1

		ColumnLayout {
			id: form

			x: 14
			y: 14
			width: parent.width - 28
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: "On the other PC: Control centre → Phone → Pair a phone or PC shows a code. Pick it here and type the code in."
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}

			Repeater {
				model: Pcs.nearby

				delegate: ListItem {
					id: near

					required property var modelData

					Layout.fillWidth: true
					icon: "lan_connect"
					title: near.modelData.name
					subtitle: (near.modelData.addresses ?? []).join(", ")
					selected: root.picked === near.modelData.id

					TextButton {
						text: root.picked === near.modelData.id ? "Picked" : "Pick"
						variant: "ghost"
						onActivated: {
							root.picked = near.modelData.id;
							addressField.text = "";
							codeField.input.forceActiveFocus();
						}
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				visible: Pcs.nearby.length === 0
				text: "No other PC with Pshell to be seen on this network: give its address."
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}

			Field {
				id: addressField

				Layout.fillWidth: true
				icon: "lan"
				placeholder: "Address (if it is not listed)"
				onEdited: if (text !== "") root.picked = ""
				onAccepted: codeField.input.forceActiveFocus()
			}

			Field {
				id: codeField

				Layout.fillWidth: true
				icon: "key_variant"
				placeholder: "Code, like ABCDE-FGHJK"
				onAccepted: root.pair()
			}

			StyledText {
				Layout.fillWidth: true
				visible: root.problem !== ""
				text: root.problem
				tone: Theme.danger
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}

			TextButton {
				Layout.fillWidth: true
				icon: "link_variant"
				text: "Pair"
				busy: root.busy
				enabled: !root.busy && codeField.text.trim() !== ""
				onActivated: root.pair()
			}
		}
	}

	TextButton {
		Layout.fillWidth: true
		enabled: Phone.connected
		icon: root.asking ? "close" : "laptop"
		text: root.asking ? "Cancel" : "Pair with another PC"
		onActivated: {
			root.asking = !root.asking;
			root.problem = "";
			if (root.asking && Pcs.nearby.length === 1) root.picked = Pcs.nearby[0].id;
		}
	}
}
