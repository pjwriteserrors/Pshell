pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Every device the PC can reach and who looks after it (core/devices.json,
// scripts/devices/devices.py): the HID devices and paired Bluetooth devices,
// what the local network and the Wi-Fi around show, and devices the user adds
// by hand – with the vendor's app to learn the protocol from. A known one
// opens its page; an unknown one – or a model a page fits only partly –
// starts a Claude session in the repo that reverse engineers it and builds
// its page.
SettingsPage {
	id: root

	title: "Devices"
	description: ""

	signal open(string page)

	property var devices: []
	property bool scanned: false
	property var hidden: []
	// added by hand: { id, name, connection, app, address, notes }
	property var custom: []
	property var network: ({ time: 0, devices: [], wifi: [] })
	property bool adding: false

	onActiveChanged: if (root.active && !scanner.running) scanner.running = true

	function shownOf(list) {
		return list.filter(d => d.role !== "receiver" && d.handler?.role !== "receiver" && !root.hidden.includes(d.id));
	}

	// known first, then partly known, then unknown
	function sorted(list) {
		const rank = d => !d.handler?.page ? 2 : (d.handler.partial ? 1 : 0);
		return list.map((d, i) => [d, i]).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map(pair => pair[0]);
	}

	readonly property var hid: root.sorted(root.shownOf(root.devices.filter(d => !d.source)))
	readonly property var bluetooth: root.sorted(root.shownOf(root.devices.filter(d => d.source === "bluetooth")))
	readonly property var own: root.sorted(root.devices.filter(d => d.source === "custom"))
	readonly property var lan: root.sorted(root.shownOf(root.network.devices ?? []))
	readonly property var wifi: root.shownOf(root.network.wifi ?? [])

	function where(device) {
		if (device.bus === "receiver") return device.via;
		return ({ usb: "USB", bluetooth: "Bluetooth", i2c: "Built in" })[device.bus] ?? device.bus;
	}

	function line(device) {
		switch (device.source) {
		case "bluetooth":
			return ["Bluetooth", device.mac, device.online ? "connected" : "not connected"].join(" · ");
		case "network":
			return [device.ip, device.model || (device.maker !== device.name ? device.maker : ""), device.mac].filter(s => s).join(" · ");
		case "wifi":
			return [`${device.signal} %`, device.security || "open", device.mac, device.connected ? "connected" : ""].filter(s => s).join(" · ");
		case "custom":
			return [({ usb: "USB", bluetooth: "Bluetooth", network: "Network", other: "" })[device.connection] ?? "", device.address, device.app ? device.app.split("/").pop() : ""].filter(s => s).join(" · ");
		default:
			return [root.where(device), `${device.vendor}:${device.product}`, device.online === false ? "asleep" : ""].filter(s => s).join(" · ");
		}
	}

	function teach(device) {
		teacher.device = device;
		teacher.running = true;
	}

	function save() {
		stateFile.setText(JSON.stringify({ hidden: root.hidden, custom: root.custom }, null, 1) + "\n");
	}

	function hide(id) {
		root.hidden = root.hidden.concat([id]);
		root.save();
	}

	function addCustom() {
		const name = nameField.text.trim();
		if (!name) return;
		let slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "device";
		while (root.custom.some(c => c.id === slug)) slug += "-2";
		root.custom = root.custom.concat([{ id: slug, name: name, connection: connection.current, app: appField.text.trim(), address: addressField.text.trim(), notes: notesField.text.trim() }]);
		root.save();
		nameField.text = appField.text = addressField.text = notesField.text = "";
		root.adding = false;
		scanner.running = true;
	}

	function removeCustom(id) {
		root.custom = root.custom.filter(c => `custom:${c.id}` !== id);
		root.save();
		scanner.running = true;
	}

	Process {
		id: scanner

		command: ["python3", `${Paths.scripts}/devices/devices.py`]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.devices = JSON.parse(this.text).devices ?? [];
				} catch (error) {
					console.warn("Devices: scan failed");
				}
				root.scanned = true;
			}
		}
	}

	// plugged in or out: again, while the page is open
	Timer {
		interval: 8000
		repeat: true
		running: root.active
		onTriggered: if (!scanner.running) scanner.running = true
	}

	// the network takes seconds and wakes every address: only when asked
	Process {
		id: netScanner

		command: ["python3", `${Paths.scripts}/devices/devices.py`, "network"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.network = JSON.parse(this.text);
				} catch (error) {
					console.warn("Devices: network scan failed");
				}
			}
		}
	}

	// the last network scan, until the next one
	FileView {
		path: Paths.stateFile("devices/network.json")
		printErrors: false
		onLoaded: {
			try {
				if (!root.network.time) root.network = JSON.parse(text() || "{}");
			} catch (error) {}
		}
	}

	Process {
		id: teacher

		property var device: null

		command: ["python3", `${Paths.scripts}/devices/devices.py`, "prompt", teacher.device?.id ?? ""]
		stdout: StdioCollector {
			onStreamFinished: {
				const file = this.text.trim();
				if (!file) return;
				Quickshell.execDetached(Terminal.shellCommand({ title: `Claude: ${teacher.device?.name ?? "device"}`, dir: Paths.shell }, `claude "$(cat '${file}')"`));
			}
		}
	}

	FileView {
		id: stateFile

		path: Paths.stateFile("devices.json")
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.hidden = data.hidden ?? [];
				root.custom = data.custom ?? [];
			} catch (error) {
				root.hidden = [];
				root.custom = [];
			}
		}
	}

	Component {
		id: tile

		DeviceTile {
			required property var modelData

			device: modelData
			line: root.line(modelData)
			busy: teacher.running
			dropIcon: modelData.source === "custom" ? "delete_outline" : "eye_off_outline"
			onOpen: page => root.open(page)
			onTeach: root.teach(modelData)
			onDrop: modelData.source === "custom" ? root.removeCustom(modelData.id) : root.hide(modelData.id)
		}
	}

	SettingCard {
		anchor: "devices-list"
		title: root.scanned ? `${root.hid.length} ${root.hid.length === 1 ? "device" : "devices"}` : "Looking …"
		icon: "devices"

		trailing: IconButton {
			implicitWidth: 32
			implicitHeight: 32
			icon: "refresh"
			variant: "ghost"
			enabled: !scanner.running
			onClicked: scanner.running = true
		}

		Repeater {
			model: root.hid
			delegate: tile
		}

		TextButton {
			visible: root.hidden.length > 0
			variant: "ghost"
			icon: "eye_outline"
			text: `${root.hidden.length} hidden`
			onActivated: {
				root.hidden = [];
				root.save();
			}
		}
	}

	SettingCard {
		anchor: "devices-bluetooth"
		title: "Bluetooth"
		subtitle: "Paired devices – headphones, watches, speakers … Their settings usually hide in vendor services."
		icon: "bluetooth"
		visible: root.bluetooth.length > 0

		Repeater {
			model: root.bluetooth
			delegate: tile
		}
	}

	SettingCard {
		anchor: "devices-network"
		title: "Network"
		subtitle: root.network.time ? `${root.lan.length} on the local network, ${root.wifi.length} Wi-Fi networks in reach · scanned ${new Date(root.network.time * 1000).toLocaleString(Qt.locale(), "d MMM, HH:mm")}` : "TVs, speakers, plugs, printers … found over ARP, mDNS and UPnP, and the Wi-Fi networks devices open"
		icon: "lan"

		trailing: TextButton {
			variant: "tonal"
			icon: "refresh"
			text: netScanner.running ? "Scanning …" : "Scan"
			busy: netScanner.running
			enabled: !netScanner.running
			onActivated: netScanner.running = true
		}

		Repeater {
			model: root.lan
			delegate: tile
		}

		SectionLabel {
			visible: root.wifi.length > 0
			text: "Wi-Fi in reach"
		}

		Repeater {
			model: root.wifi
			delegate: tile
		}
	}

	SettingCard {
		anchor: "devices-own"
		title: "Your own devices"
		subtitle: "Something the scans do not find, or that is best learned from its app: add it with the vendor's Linux or Windows program (AppImage, .exe, .msi …) and Claude takes the protocol from there."
		icon: "package_variant_closed"

		trailing: TextButton {
			variant: root.adding ? "ghost" : "tonal"
			icon: root.adding ? "close" : "plus"
			text: root.adding ? "Cancel" : "Add"
			onActivated: root.adding = !root.adding
		}

		Repeater {
			model: root.own
			delegate: tile
		}

		ColumnLayout {
			Layout.fillWidth: true
			visible: root.adding
			spacing: 10

			Field {
				id: nameField

				Layout.fillWidth: true
				icon: "devices"
				placeholder: "Name – e.g. LG TV (webOS)"
				onAccepted: root.addCustom()
			}

			Segmented {
				id: connection

				Layout.fillWidth: true
				current: "network"
				options: [
					{ value: "usb", label: "USB", icon: "usb" },
					{ value: "bluetooth", label: "Bluetooth", icon: "bluetooth" },
					{ value: "network", label: "Network", icon: "lan" },
					{ value: "other", label: "Other" }
				]
				onSelected: value => connection.current = value
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Field {
					id: appField

					Layout.fillWidth: true
					icon: "application_outline"
					placeholder: "The vendor's app (optional) – a path"
				}

				TextButton {
					variant: "tonal"
					icon: "folder_open"
					text: "Choose …"
					onActivated: Files.pick({ title: "The device's app", acceptLabel: "Choose" }, paths => {
						if (paths.length > 0) appField.text = String(paths[0]).replace(/^file:\/\//, "");
					})
				}
			}

			Field {
				id: addressField

				Layout.fillWidth: true
				icon: "lan_connect"
				placeholder: "Where it is (optional) – IP, MAC, USB id …"
			}

			AreaField {
				id: notesField

				Layout.fillWidth: true
				Layout.preferredHeight: 72
				placeholder: "What it is and what you want from it (optional)"
			}

			TextButton {
				Layout.alignment: Qt.AlignRight
				variant: "filled"
				icon: "plus"
				text: "Add device"
				enabled: nameField.text.trim() !== ""
				onActivated: root.addCustom()
			}
		}
	}
}
