import QtQuick
import Quickshell
import qs.core.services

// quick: the quick settings: do not disturb, keep awake, power profile,
// brightness and monitor inputs, Bluetooth, the network, autocorrect.
Topic {
	id: topic

	name: "quick"
	throttle: 150

	Binding {
		target: Bluetooth
		property: "watchers"
		value: 1
		when: topic.wanted && Plugins.on("bluetooth")
		restoreMode: Binding.RestoreValue
	}

	onWantedChanged: if (topic.wanted) {
		Ddc.refresh();
		PowerProfile.refresh();
		if (Plugins.on("backlight")) Brightness.refresh(false);
	}

	data: topic.wanted ? ({
		dnd: Plugins.on("dnd") ? { on: Notifs.dnd, manual: Notifs.dndManual, reason: Notifs.dndReason } : null,
		keepAwake: KeepAwake.available ? { on: KeepAwake.active } : null,
		power: PowerProfile.available ? {
			current: PowerProfile.current,
			profiles: PowerProfile.profiles.map(profile => ({ id: profile, label: PowerProfile.label(profile), icon: PowerProfile.icon(profile) }))
		} : null,
		backlight: Brightness.available ? { value: Brightness.value } : null,
		monitors: Ddc.available ? Ddc.monitors.map(monitor => ({
			bus: monitor.bus,
			label: Ddc.label(monitor),
			value: monitor.value,
			known: !!monitor.known,
			input: monitor.input || "",
			inputs: monitor.inputs || []
		})) : null,
		bluetooth: Plugins.on("bluetooth") && Bluetooth.available ? {
			powered: Bluetooth.powered,
			summary: Bluetooth.summary,
			devices: Bluetooth.devices.filter(device => device.paired || device.connected).map(device => ({
				address: device.address,
				name: device.name,
				icon: Bluetooth.deviceIcon(device.name, device.icon),
				connected: device.connected,
				battery: device.battery
			}))
		} : null,
		network: Plugins.on("network") ? { label: Network.label, icon: Network.icon, ip: Network.ip, online: Network.online, signal: Network.signal } : null,
		autocorrect: Autocorrect.available ? { on: Autocorrect.on, active: Autocorrect.active, failed: Autocorrect.failed } : null
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "dnd":
			Notifs.setDnd(args.on === undefined ? !Notifs.dnd : !!args.on);
			return {};
		case "keepAwake":
			if (KeepAwake.active !== (args.on === undefined ? !KeepAwake.active : !!args.on)) KeepAwake.toggle();
			return {};
		case "power":
			PowerProfile.set(String(args.profile));
			return {};
		case "backlight":
			Brightness.set(Number(args.value));
			return {};
		case "monitor":
			if (args.value !== undefined) Ddc.set(args.bus, Number(args.value));
			if (args.input !== undefined) Ddc.setInput(args.bus, String(args.input));
			return {};
		case "bluetooth":
			if (args.address !== undefined) Bluetooth.toggleDevice(String(args.address));
			else Bluetooth.togglePower();
			return {};
		case "autocorrect":
			if (!Autocorrect.available) throw new Error("Autocorrect is off");
			if (args.on === undefined || !!args.on !== Autocorrect.on) Autocorrect.toggle();
			return {};
		}
		throw new Error("unknown-action");
	}
}
