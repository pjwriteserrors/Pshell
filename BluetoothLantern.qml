pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"

// The radio as a thread. The adapter is a toggle on the wire at the top; a
// scan sends pulses down that wire while the controller listens. Every
// device known hangs from a vertical thread below, its knot lit while it
// is connected and its battery drawn as a short lit wire beside the name.
// The verb for a row (connect, disconnect) surfaces when the light is on it.
// Powered off, the thread goes cold and says so.
FocusScope {
	id: page

	property real reveal: 1
	property bool active: false

	signal connected()

	property bool powered: false
	property bool known: false
	property bool scanning: false
	property var devices: []
	property var deviceStatuses: ({})
	property string pendingConnectAddress: ""
	property string pendingConnectOutput: ""
	property string awaitingAddress: ""
	property int selectedIndex: 0
	readonly property real threadX: 8
	readonly property int rowHeight: 46

	implicitHeight: column.implicitHeight

	// ----------------------------------------------------------------- logic
	function parseStatus(raw) {
		const lines = String(raw || "").split("\n");
		let next = false;
		for (const line of lines) {
			if (line.startsWith("powered=")) next = line.slice("powered=".length).trim() === "yes";
		}
		page.powered = next;
		page.known = true;
		if (!next) page.devices = [];
	}

	function sortDevices(list) {
		list.sort((left, right) => {
			if (left.connected !== right.connected) return left.connected ? -1 : 1;
			if (left.paired !== right.paired) return left.paired ? -1 : 1;
			return String(left.name || left.address).localeCompare(String(right.name || right.address));
		});
		return list;
	}

	function parseDevices(raw) {
		const lines = String(raw || "").split("\n");
		const deviceMap = {};
		for (const device of page.devices) deviceMap[device.address] = Object.assign({}, device);
		const next = [];
		let current = null;
		for (const line of lines) {
			if (line.startsWith("device=")) {
				if (current) next.push(current);
				current = { address: line.slice("device=".length).trim(), name: "", connected: false, paired: false, trusted: false, battery: "" };
				continue;
			}
			if (!current) continue;
			if (line.startsWith("name=")) current.name = line.slice("name=".length).trim();
			else if (line.startsWith("connected=")) current.connected = line.slice("connected=".length).trim() === "yes";
			else if (line.startsWith("paired=")) current.paired = line.slice("paired=".length).trim() === "yes";
			else if (line.startsWith("trusted=")) current.trusted = line.slice("trusted=".length).trim() === "yes";
			else if (line.startsWith("battery=")) current.battery = line.slice("battery=".length).trim();
		}
		if (current) next.push(current);
		for (const device of next) {
			const existing = deviceMap[device.address] || {};
			deviceMap[device.address] = {
				address: device.address,
				name: device.name || existing.name || "",
				connected: device.connected,
				paired: device.paired,
				trusted: device.trusted,
				battery: device.battery || existing.battery || ""
			};
		}
		const filtered = sortDevices(Object.values(deviceMap));
		page.devices = filtered;
		const nextStatuses = Object.assign({}, page.deviceStatuses);
		for (const device of filtered) {
			if (device.connected) nextStatuses[device.address] = "Connected";
			else if (page.pendingConnectAddress === device.address) nextStatuses[device.address] = "Connecting...";
			else if (nextStatuses[device.address] === "Connected") nextStatuses[device.address] = device.paired ? "Paired" : "Available";
			else if (nextStatuses[device.address] !== "Failed") nextStatuses[device.address] = device.paired ? "Paired" : "Available";
		}
		page.deviceStatuses = nextStatuses;
		if (page.awaitingAddress !== "") {
			const waited = filtered.find(item => item.address === page.awaitingAddress);
			if (waited?.connected) { page.awaitingAddress = ""; page.connected(); }
		}
		page.selectedIndex = Math.max(0, Math.min(page.selectedIndex, filtered.length - 1));
	}

	function mergeScannedDevices(raw) {
		const lines = String(raw || "").split("\n");
		const deviceMap = {};
		for (const device of page.devices) deviceMap[device.address] = Object.assign({}, device);
		for (const line of lines) {
			const match = line.match(/Device\s+([0-9A-F:]{17})\s+(.+)$/i);
			if (!match) continue;
			const address = match[1].trim();
			const name = match[2].trim();
			if (name === "" || name === address || /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/i.test(name)) continue;
			const existing = deviceMap[address] || { address, name: "", connected: false, paired: false, trusted: false, battery: "" };
			deviceMap[address] = Object.assign({}, existing, { name });
		}
		page.devices = sortDevices(Object.values(deviceMap));
	}

	function refresh() {
		statusProcess.running = true;
		devicesProcess.running = true;
	}

	function connectStatusFromOutput(outputText) {
		const output = String(outputText || "").toLowerCase();
		if (output.includes("br-connection-key-missing")) return "Re-pair required";
		if (output.includes("host is down")) return "Controller off?";
		if (output.includes("authenticationcanceled") || output.includes("authentication canceled")) return "Pairing canceled";
		if (output.includes("alreadyconnected") || output.includes("already connected")) return "Connected";
		if (output.includes("not available")) return "Unavailable";
		return "Failed";
	}

	function togglePower() {
		Quickshell.execDetached(["sh", "-lc", page.powered ? "bluetoothctl power off" : "bluetoothctl power on && bluetoothctl pairable on"]);
		Qt.callLater(function() { page.refresh(); });
	}

	function startScan() {
		if (page.scanning || !page.powered) return;
		page.scanning = true;
		page.devices = [];
		scanProcess.running = true;
		page.refresh();
	}

	function connectDevice(address) {
		if (!address) return;
		const device = page.devices.find(item => item.address === address);
		const nextStatuses = Object.assign({}, page.deviceStatuses);
		const disconnecting = !!device?.connected;
		nextStatuses[address] = disconnecting ? "Disconnecting..." : "Connecting...";
		page.deviceStatuses = nextStatuses;
		page.pendingConnectAddress = address;
		page.pendingConnectOutput = "";
		page.awaitingAddress = disconnecting ? "" : address;
		connectProcess.command = [
			"sh", "-lc",
			disconnecting
				? `bluetoothctl disconnect '${address}' 2>&1`
				: (device?.paired
					? `bluetoothctl trust '${address}' >/dev/null 2>&1; bluetoothctl connect '${address}' 2>&1`
					: `bluetoothctl pairable on >/dev/null 2>&1; bluetoothctl agent on >/dev/null 2>&1; bluetoothctl default-agent >/dev/null 2>&1; bluetoothctl pair '${address}' 2>&1 && bluetoothctl trust '${address}' 2>&1 && bluetoothctl connect '${address}' 2>&1`)
		];
		connectProcess.running = true;
	}

	function statusOf(device) {
		return page.deviceStatuses[device.address] || (device.connected ? "Connected" : (device.paired ? "Paired" : "Available"));
	}

	function busy(device) {
		const status = statusOf(device);
		return status === "Connecting..." || status === "Disconnecting...";
	}

	function iconFor(name) {
		const n = String(name || "").toLowerCase();
		if (/bud|head|arctis|wh-|wf-|airpod|speaker|soundcore|jbl/.test(n)) return "/usr/share/icons/Adwaita/symbolic/devices/audio-headphones-symbolic.svg";
		if (n.includes("mouse")) return "/usr/share/icons/Adwaita/symbolic/devices/input-mouse-symbolic.svg";
		if (n.includes("keyboard") || n.includes("keychron")) return "/usr/share/icons/Adwaita/symbolic/devices/input-keyboard-symbolic.svg";
		if (/phone|pixel|galaxy|iphone/.test(n)) return "/usr/share/icons/Adwaita/symbolic/devices/phone-symbolic.svg";
		if (/tv|cast/.test(n)) return "/usr/share/icons/Adwaita/symbolic/devices/tv-symbolic.svg";
		return "/usr/share/icons/Adwaita/symbolic/status/bluetooth-active-symbolic.svg";
	}

	function batteryLevel(text) {
		const match = String(text || "").match(/(\d+)/);
		return match ? Math.max(0, Math.min(1, Number(match[1]) / 100)) : -1;
	}

	function moveSelection(delta) {
		if (page.devices.length === 0) return;
		page.selectedIndex = Math.max(0, Math.min(page.selectedIndex + delta, page.devices.length - 1));
		list.positionViewAtIndex(page.selectedIndex, ListView.Contain);
	}

	function activateSelection() {
		if (page.devices.length === 0) return;
		const device = page.devices[Math.max(0, Math.min(page.selectedIndex, page.devices.length - 1))];
		if (device && !busy(device)) connectDevice(device.address);
	}

	onActiveChanged: {
		if (active) Qt.callLater(function() { page.forceActiveFocus(); });
	}

	Keys.onDownPressed: event => { event.accepted = true; moveSelection(1); }
	Keys.onUpPressed: event => { event.accepted = true; moveSelection(-1); }
	Keys.onReturnPressed: event => { event.accepted = true; activateSelection(); }
	Keys.onEnterPressed: event => { event.accepted = true; activateSelection(); }
	Keys.onSpacePressed: event => { event.accepted = true; activateSelection(); }
	Keys.onPressed: event => {
		if (event.key === Qt.Key_S || event.key === Qt.Key_R) { event.accepted = true; startScan(); }
		else if (event.key === Qt.Key_P) { event.accepted = true; togglePower(); }
	}

	// -------------------------------------------------------------- processes
	Timer {
		running: page.active
		repeat: true
		interval: 3000
		triggeredOnStart: true
		onTriggered: page.refresh()
	}

	Timer {
		id: connectRefreshTimer
		interval: 2000
		repeat: false
		onTriggered: page.refresh()
	}

	// While the controller listens, light runs down the wire again and again.
	Timer {
		running: page.scanning && page.active
		repeat: true
		interval: 900
		triggeredOnStart: true
		onTriggered: topWire.pulse()
	}

	Process {
		id: scanProcess
		command: ["sh", "-lc", "bluetoothctl power on >/dev/null 2>&1; bluetoothctl pairable on >/dev/null 2>&1; bluetoothctl --timeout 8 scan on 2>/dev/null"]
		stdout: StdioCollector {
			onStreamFinished: {
				page.scanning = false;
				page.mergeScannedDevices(text);
				page.refresh();
			}
		}
	}

	Process {
		id: statusProcess
		command: ["sh", "-lc", "bluetoothctl show | awk '/Powered:/ {print \"powered=\" tolower($2)}'"]
		stdout: StdioCollector {
			onStreamFinished: page.parseStatus(text)
		}
	}

	Process {
		id: devicesProcess
		command: [
			"sh", "-lc",
			`bluetoothctl devices | while read -r _ address name; do
  [ -n "$address" ] || continue
  printf 'device=%s\n' "$address"
  info="$(bluetoothctl info "$address" 2>/dev/null)"
  alias_name="$(printf '%s\n' "$info" | awk -F': ' '/^\tAlias: / {print $2; exit}')"
  pretty_name="$(printf '%s\n' "$info" | awk -F': ' '/^\tName: / {print $2; exit}')"
  final_name="$alias_name"
  [ -n "$final_name" ] || final_name="$pretty_name"
  [ -n "$final_name" ] || final_name="$name"
  printf 'name=%s\n' "$final_name"
  printf '%s\n' "$info" | awk '
    /Connected:/ {print "connected=" tolower($2)}
    /Paired:/ {print "paired=" tolower($2)}
    /Trusted:/ {print "trusted=" tolower($2)}
    /Battery Percentage:/ {
      value=$0
      if (match(value, /\\(([0-9]+)%?\\)/, percent)) {
        print "battery=" percent[1] "%"
      } else {
        sub(/^.*Battery Percentage:[[:space:]]*/, "", value)
        split(value, parts, " ")
        if (parts[1] != "") print "battery=" parts[1]
      }
    }
  '
done`
		]
		stdout: StdioCollector {
			onStreamFinished: page.parseDevices(text)
		}
	}

	Process {
		id: connectProcess
		command: ["sh", "-lc", ":"]
		stdout: StdioCollector {
			onStreamFinished: page.pendingConnectOutput = text
		}
		onExited: exitCode => {
			const address = page.pendingConnectAddress;
			const outputText = page.pendingConnectOutput;
			page.pendingConnectAddress = "";
			page.pendingConnectOutput = "";
			if (address !== "") {
				const device = page.devices.find(item => item.address === address);
				const nextStatuses = Object.assign({}, page.deviceStatuses);
				if (exitCode === 0) {
					nextStatuses[address] = device?.connected ? "Disconnecting..." : "Connecting...";
					if (page.awaitingAddress === address) { page.awaitingAddress = ""; page.connected(); }
				} else {
					const status = page.connectStatusFromOutput(outputText);
					nextStatuses[address] = status;
					if (status === "Connected" && page.awaitingAddress === address) { page.awaitingAddress = ""; page.connected(); }
					else page.awaitingAddress = "";
				}
				page.deviceStatuses = nextStatuses;
			}
			connectRefreshTimer.restart();
		}
	}

	// ------------------------------------------------------------------ view
	Column {
		id: column
		width: parent.width
		spacing: 10

		// The adapter on the wire.
		Band {
			reveal: page.reveal; order: 0
			width: parent.width; height: 40

			FIcon {
				id: bigIcon
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				name: page.powered ? "bluetooth-active-symbolic" : "bluetooth-disabled-symbolic"
				size: 24
				color: page.powered ? Filament.charge : Filament.inkMute
				Behavior on color { ColorAnimation { duration: Filament.settle } }
			}
			Column {
				anchors.left: bigIcon.right
				anchors.leftMargin: 12
				anchors.verticalCenter: parent.verticalCenter
				spacing: 1
				FText { text: "Bluetooth"; font.pixelSize: Filament.textLg; font.weight: Font.DemiBold }
				FText {
					text: !page.known ? "listening for the controller"
						: !page.powered ? "the adapter is off"
						: page.scanning ? "scanning"
						: (page.devices.filter(d => d.connected).length > 0
							? `${page.devices.filter(d => d.connected).length} connected  ·  ${page.devices.length} known`
							: `${page.devices.length} known`)
					mono: true
					tone: "mute"
					font.pixelSize: Filament.textXs
				}
			}
			FToggle {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				checked: page.powered
				enabled: page.known
				onToggled: page.togglePower()
			}
		}

		// The wire the scan runs along, with the verb sitting on it.
		Band {
			reveal: page.reveal; order: 1
			width: parent.width; height: 28

			Wire {
				id: topWire
				anchors.left: parent.left
				anchors.right: scanButton.left
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				height: 2
				cold: page.powered ? Filament.wire : Filament.wireDim
				hot: Filament.charge
				lit: 0
				pulseWidth: 70
				Behavior on cold { ColorAnimation { duration: Filament.settle } }
			}
			FButton {
				id: scanButton
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				text: page.scanning ? "listening" : "scan"
				icon: "view-refresh-symbolic"
				iconSize: 12
				kind: page.scanning ? "charge" : "bead"
				compact: true
				enabled: page.powered && !page.scanning
				onClicked: page.startScan()
			}
		}

		// Cold: the thread hangs with nothing lit.
		Band {
			reveal: page.reveal; order: 2
			width: parent.width; height: 72
			visible: page.known && !page.powered
			Wire {
				vertical: true
				x: page.threadX - 1; y: 0; width: 2; height: 44
				cold: Filament.wireDim
			}
			Rectangle { x: page.threadX - 4; y: 41; width: 6; height: 6; radius: 3; color: Filament.wireDim }
			FText {
				x: page.threadX + 16; y: 26
				text: "the thread is cold"
				tone: "mute"
				font.pixelSize: Filament.textSm
			}
			FText {
				x: page.threadX + 16; y: 44
				text: "turn the adapter on to hang devices here"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}

		// Nothing hung yet.
		Band {
			reveal: page.reveal; order: 2
			width: parent.width; height: 72
			visible: page.known && page.powered && page.devices.length === 0
			Wire {
				vertical: true
				x: page.threadX - 1; y: 0; width: 2; height: 44
				cold: Filament.wireDim
				lit: 0.3; litFrom: 0.7; hot: Filament.charge; animateLit: false
			}
			Spark { x: page.threadX - 4; y: 40; size: 7; breathing: true }
			FText {
				x: page.threadX + 16; y: 26
				text: page.scanning ? "listening for devices" : "No devices found yet"
				tone: "mute"
				font.pixelSize: Filament.textSm
			}
			FText {
				x: page.threadX + 16; y: 44
				text: page.scanning ? "put the device in pairing mode" : "scan to look for nearby devices"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}

		// The devices, hung from the thread.
		Item {
			width: parent.width
			height: page.powered && page.devices.length > 0 ? Math.min(page.devices.length * page.rowHeight, page.rowHeight * 7) : 0
			visible: page.powered && page.devices.length > 0
			clip: true

			ThreadLine {
				x: page.threadX - 1
				y: 0
				height: parent.height
				litY: list.currentItem ? list.currentItem.y - list.contentY + list.currentItem.height / 2 : -1
				litLength: 36
				opacity: Filament.band(page.reveal, 2)
			}

			ListView {
				id: list
				x: page.threadX
				width: parent.width - page.threadX
				height: parent.height
				clip: true
				spacing: 0
				model: page.devices
				currentIndex: page.devices.length > 0 ? page.selectedIndex : -1
				boundsBehavior: Flickable.StopAtBounds
				highlightFollowsCurrentItem: false
				keyNavigationEnabled: false

				delegate: ThreadRow {
					id: row
					required property var modelData
					required property int index
					readonly property bool current: index === page.selectedIndex
					readonly property bool isConnected: modelData?.connected ?? false
					readonly property string status: page.statusOf(modelData ?? ({}))
					readonly property bool isBusy: page.busy(modelData ?? ({}))
					readonly property real battery: page.batteryLevel(modelData?.battery)
					readonly property bool hot: hovered || current

					width: ListView.view.width
					height: page.rowHeight
					inset: 18
					selected: current
					opacity: Filament.band(page.reveal, 2 + Math.min(index, 6))

					onEntered: page.selectedIndex = index
					onClicked: if (!isBusy) page.connectDevice(modelData?.address)

					// The knot glows on its own while the device is connected.
					Spark {
						x: -row.inset - 3
						anchors.verticalCenter: parent.verticalCenter
						size: 6
						visible: row.isConnected
						breathing: row.isConnected && !row.current
					}

					FIcon {
						id: kindIcon
						anchors.left: parent.left
						anchors.verticalCenter: parent.verticalCenter
						name: page.iconFor(row.modelData?.name)
						size: 16
						color: row.isConnected ? Filament.charge : (row.hot ? Filament.ink : Filament.inkMute)
						Behavior on color { ColorAnimation { duration: Filament.quick } }
					}

					Column {
						anchors.left: kindIcon.right
						anchors.leftMargin: 12
						anchors.right: verb.visible ? verb.left : parent.right
						anchors.rightMargin: 10
						anchors.verticalCenter: parent.verticalCenter
						spacing: 3
						FText {
							width: parent.width
							text: row.modelData?.name || row.modelData?.address || ""
							font.pixelSize: Filament.textMd
							font.weight: row.isConnected ? Font.DemiBold : Font.Medium
							color: row.isConnected || row.hot ? Filament.ink : Filament.inkSoft
							Behavior on color { ColorAnimation { duration: Filament.quick } }
						}
						Row {
							spacing: 8
							FText {
								anchors.verticalCenter: parent.verticalCenter
								text: row.status
								mono: true
								font.pixelSize: Filament.textXs
								color: row.status === "Failed" || row.status === "Re-pair required" || row.status === "Controller off?" || row.status === "Unavailable" || row.status === "Pairing canceled"
									? Filament.alert
									: (row.isConnected ? Filament.charge : (row.isBusy ? Filament.inkSoft : Filament.inkMute))
							}
							// The battery: a short wire, lit as far as the charge goes.
							Wire {
								visible: row.isConnected && row.battery >= 0
								anchors.verticalCenter: parent.verticalCenter
								width: 36; height: 2
								cold: Filament.wireDim
								hot: row.battery < 0.2 ? Filament.alert : Filament.charge2
								lit: row.battery
							}
							FText {
								visible: row.isConnected && row.battery >= 0
								anchors.verticalCenter: parent.verticalCenter
								text: row.modelData?.battery ?? ""
								mono: true
								tone: "soft"
								font.pixelSize: Filament.textXs
							}
						}
					}

					// The verb surfaces when the light is on the row.
					FButton {
						id: verb
						anchors.right: parent.right
						anchors.rightMargin: 4
						anchors.verticalCenter: parent.verticalCenter
						visible: opacity > 0.01
						opacity: row.hot && !row.isBusy ? 1 : 0
						Behavior on opacity { NumberAnimation { duration: Filament.quick } }
						text: row.isConnected ? "disconnect" : (row.modelData?.paired ? "connect" : "pair")
						kind: row.isConnected ? "bead" : "charge"
						compact: true
						onClicked: page.connectDevice(row.modelData?.address)
					}

					// A busy row: a pulse keeps running under the words while it works.
					Wire {
						id: busyWire
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.rightMargin: 4
						y: parent.height - 3
						height: 2
						visible: row.isBusy
						cold: Filament.wireDim
						hot: Filament.charge
						pulseWidth: 60
						Timer {
							running: row.isBusy && page.active
							repeat: true
							interval: 700
							triggeredOnStart: true
							onTriggered: busyWire.pulse()
						}
					}
				}
			}
		}

		Band {
			reveal: page.reveal; order: 3
			width: parent.width; height: 14
			visible: page.powered && page.devices.length > 0
			FText {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				text: "Enter connects  ·  s scans  ·  p toggles power"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}
	}
}
