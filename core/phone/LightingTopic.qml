import QtQuick
import Quickshell
import qs.core.services

// lighting: the OpenRGB devices and what each shows, and how live runs. Either
// of two plugins brings it, so the topic names none and says `enabled`.
Topic {
	id: topic

	name: "lighting"
	throttle: 150

	// the monitors by name; the one that is picked stays while it is unplugged
	readonly property var outputs: {
		const names = Quickshell.screens.map(screen => String(screen.name));
		if (Lighting.output !== "" && !names.includes(Lighting.output)) names.push(Lighting.output);
		return names;
	}

	onWantedChanged: if (topic.wanted) Lighting.scan()

	data: topic.wanted ? ({
		enabled: Lighting.enabled,
		devices: Lighting.devices.map(device => ({
			id: String(device.id),
			name: String(device.name || device.id),
			kind: String(device.kind || ""),
			present: !!device.present,
			mode: Lighting.modeOf(device.id)
		})),
		modeNames: Lighting.modeNames,
		output: Lighting.output,
		outputs: topic.outputs,
		fps: Lighting.fps,
		smoothing: Lighting.smoothing,
		scanning: Lighting.scanning,
		scanned: Lighting.scanned,
		server: Lighting.server,
		liveRunning: Lighting.liveRunning
	}) : null

	function call(action, args, done) {
		if (!Lighting.enabled) throw new Error("plugin-off");
		switch (action) {
		case "mode":
			if (!Lighting.modeNames.includes(String(args.mode))) throw new Error("No such mode");
			Lighting.setMode(String(args.id || ""), String(args.mode));
			return {};
		// "" is the largest monitor
		case "output":
			Lighting.setOutput(String(args.name || ""));
			return {};
		case "fps":
			Lighting.setFps(Number(args.fps) || 15);
			return {};
		case "smoothing":
			Lighting.setSmoothing(Number(args.value) || 0);
			return {};
		case "scan":
			Lighting.scan();
			return {};
		}
		throw new Error("unknown-action");
	}
}
