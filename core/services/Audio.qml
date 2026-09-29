pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Output / input volume. Live values come from PipeWire; keybinds use wpctl
// (proven with every sink here) and report through the OSD. Default sink
// switching uses pactl because wpctl refuses some internal sinks (EVO4).
// `streams` are the apps playing right now, for the per-app mixer.
// headphonesLost fires when the output moves from headphones (a headset,
// Bluetooth, the headphone jack) to anything else.
Singleton {
	id: root

	readonly property PwNode sink: Pipewire.defaultAudioSink
	readonly property PwNode source: Pipewire.defaultAudioSource
	readonly property real volume: root.sink?.audio?.volume ?? 0
	readonly property bool muted: !!root.sink?.audio?.muted
	readonly property real micVolume: root.source?.audio?.volume ?? 0
	readonly property bool micMuted: !!root.source?.audio?.muted
	readonly property string sinkName: root.sink?.description || root.sink?.nickname || root.sink?.name || "Output"

	property var sinks: []
	property string requestKind: "volume"
	property bool onHeadphones: false
	property bool sinksKnown: false

	signal headphonesLost

	PwObjectTracker {
		objects: [root.sink, root.source]
	}

	// app playback streams (media.class Stream/Output/Audio)
	readonly property var streams: (Pipewire.nodes?.values ?? []).filter(node => node.isStream && node.audio
		&& String(node.properties?.["media.class"] ?? "") === "Stream/Output/Audio")

	PwObjectTracker {
		objects: root.streams
	}

	function streamName(node) {
		const props = node?.properties ?? {};
		return String(props["application.name"] || node?.description || node?.nickname || node?.name || "App");
	}

	function streamTitle(node) {
		const props = node?.properties ?? {};
		const title = String(props["media.name"] || "");
		return title === root.streamName(node) ? "" : title;
	}

	function streamIcon(node) {
		const props = node?.properties ?? {};
		const candidates = [props["application.icon-name"], props["application.process.binary"], props["application.name"]]
			.filter(v => !!v).map(v => String(v).toLowerCase());
		for (const candidate of candidates) {
			const icon = AppIcons.papirus(candidate);
			if (icon !== "") return icon;
		}
		return AppIcons.forAppId(candidates[0] || "");
	}

	function volumeIcon(volume, muted) {
		if (muted || volume <= 0.001) return "volume_off";
		if (volume < 0.34) return "volume_low";
		if (volume < 0.67) return "volume_medium";
		return "volume_high";
	}

	readonly property string icon: root.volumeIcon(root.volume, root.muted)
	readonly property string micIcon: root.micMuted ? "microphone_off" : "microphone"

	function setVolume(value) {
		const v = Math.max(0, Math.min(1, value));
		if (root.sink?.audio) {
			root.sink.audio.muted = false;
			root.sink.audio.volume = v;
		} else {
			Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", v.toFixed(2)]);
		}
	}

	function setMicVolume(value) {
		const v = Math.max(0, Math.min(1, value));
		if (root.source?.audio) root.source.audio.volume = v;
	}

	function adjust(delta) {
		Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", delta > 0 ? "5%+" : "5%-"]);
		root.scheduleOsd("volume");
	}

	function toggleMute() {
		Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]);
		root.scheduleOsd("volume");
	}

	function toggleMicMute() {
		Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]);
		root.scheduleOsd("microphone");
	}

	function scheduleOsd(kind) {
		root.requestKind = kind;
		osdTimer.restart();
	}

	function refreshSinks() {
		if (!sinkListProc.running) sinkListProc.running = true;
	}

	function setDefaultSink(name) {
		Quickshell.execDetached(["pactl", "set-default-sink", String(name)]);
		sinkRefresh.restart();
	}

	function isHeadphones(sink) {
		const props = sink.properties ?? {};
		const factor = String(props["device.form_factor"] ?? "");
		const port = String(sink.active_port ?? "");
		return factor === "headphone" || factor === "headset" || String(props["device.bus"] ?? "") === "bluetooth"
			|| /headphone|headset/i.test(port) || /headphone|headset/i.test(String(sink.description ?? ""));
	}

	function shortSinkName(name) {
		const n = String(name || "").replace(/ Analog Stereo| Digital Stereo.*| Pro \d+.*/g, "");
		return n.length > 40 ? n.slice(0, 40) + "…" : n;
	}

	Timer {
		id: osdTimer
		interval: 90
		onTriggered: {
			readProc.command = ["wpctl", "get-volume", root.requestKind === "microphone" ? "@DEFAULT_AUDIO_SOURCE@" : "@DEFAULT_AUDIO_SINK@"];
			readProc.running = true;
		}
	}

	Timer {
		id: sinkRefresh
		interval: 250
		onTriggered: root.refreshSinks()
	}

	Process {
		id: readProc
		command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
		stdout: StdioCollector {
			onStreamFinished: {
				const raw = String(text || "");
				const match = raw.match(/Volume:\s*([0-9.]+)/);
				const volume = match ? Number(match[1]) : 0;
				const muted = raw.includes("[MUTED]");
				const mic = root.requestKind === "microphone";
				Osd.show(root.requestKind, mic ? "Microphone" : "Volume", muted ? 0 : volume,
					muted ? "Muted" : `${Math.round(volume * 100)}%`,
					mic ? (muted ? "microphone_off" : "microphone") : root.volumeIcon(volume, muted));
			}
		}
	}

	Process {
		id: sinkListProc
		command: ["sh", "-lc", "pactl --format=json list sinks; printf '@@@%s' \"$(pactl get-default-sink)\""]
		stdout: StdioCollector {
			onStreamFinished: {
				const raw = String(text || "");
				const sep = raw.lastIndexOf("@@@");
				if (sep < 0) return;
				const defaultName = raw.slice(sep + 3).trim();
				const next = [];
				try {
					for (const sink of JSON.parse(raw.slice(0, sep)))
						next.push({ active: sink.name === defaultName, name: sink.name, description: sink.description || sink.name, headphones: root.isHeadphones(sink) });
				} catch (e) {
					return;
				}
				root.sinks = next;
				const active = next.find(sink => sink.active);
				const headphones = !!active && active.headphones;
				if (root.sinksKnown && root.onHeadphones && !headphones) root.headphonesLost();
				root.onHeadphones = headphones;
				root.sinksKnown = true;
			}
		}
	}

	Connections {
		target: Pipewire
		function onDefaultAudioSinkChanged() {
			sinkRefresh.restart();
		}
	}

	// a plug pulled from the jack only switches the port of the same sink
	Process {
		id: sinkEvents

		running: true
		command: ["pactl", "subscribe"]
		stdout: SplitParser {
			onRead: line => {
				if (/ on (sink|card|server) /.test(line)) sinkRefresh.restart();
			}
		}
		onExited: sinkEventsRestart.restart()
	}

	Timer {
		id: sinkEventsRestart
		interval: 5000
		onTriggered: sinkEvents.running = true
	}

	Component.onCompleted: root.refreshSinks()
}
