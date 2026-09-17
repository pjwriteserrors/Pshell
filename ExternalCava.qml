pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Item {
	id: root
	visible: false

	// Only run while something is drawing the spectrum. cava at 75 fps holds a
	// capture stream open and hands over a frame 75 times a second; doing that
	// for a graph nobody is looking at was most of this shell's idle CPU.
	property bool active: true
	property int bars: 28
	property var values: []
	property string inputMethod: "pipewire"

	function normalizedValues(frame) {
		const parts = String(frame).trim().split(/[;,\s]+/).filter(Boolean);
		if (parts.length === 0) return [];

		const parsed = [];
		for (const part of parts) {
			const value = Number(part);
			if (!Number.isNaN(value)) {
				const normalized = Math.max(0, Math.min(1, value / 100));
				parsed.push(Math.max(0, Math.min(1, Math.pow(normalized, 0.7) * 1.18)));
			}
		}
		return parsed;
	}

	function rebuildValues() {
		const next = [];
		for (let i = 0; i < root.bars; i += 1) {
			next.push(0);
		}
		root.values = next;
	}

	function applyFrame(frame) {
		const parsed = root.normalizedValues(frame);
		if (parsed.length > 0) root.values = parsed;
	}

	// Restart by dipping a property the `running` binding reads, never by
	// assigning to `running` itself: an imperative assignment replaces the
	// binding, and then the process stops following `active` for good.
	property bool restarting: false

	function restartProcess() {
		root.restarting = true;
		Qt.callLater(function() {
			root.restarting = false;
		});
	}

	function buildCommand(method) {
		const configLines = [
			"[general]",
			"framerate = 75",
			`bars = ${root.bars}`,
			"autosens = 1",
			"[input]",
			`method = ${method}`,
			"[output]",
			"method = raw",
			"raw_target = /dev/stdout",
			"data_format = ascii",
			"ascii_max_range = 100",
			"channels = mono",
			"mono_option = average"
		];

		const escaped = configLines
			.map(line => `'${line.replace(/'/g, `'\"'\"'`)}'`)
			.join(" ");

		return [
			"sh",
			"-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; printf '%s\n' ${escaped} > "$tmp"; exec cava -p "$tmp"`
		];
	}

	Component.onCompleted: root.rebuildValues()
	onBarsChanged: {
		root.rebuildValues();
		root.restartProcess();
	}
	onActiveChanged: {
		if (root.active) return;
		// Leave the bars where they were rather than collapsing them: the popup
		// is closing, and an animated slump on the way out is just noise.
		restartTimer.stop();
	}

	Process {
		id: cavaProcess
		running: root.active && !root.restarting
		command: root.buildCommand(root.inputMethod)

		stdout: SplitParser {
			onRead: data => root.applyFrame(data)
		}

		onExited: (exitCode, exitStatus) => {
			if (!root.active) return;
			if (root.inputMethod === "pipewire") {
				root.inputMethod = "pulse";
				root.restartProcess();
				return;
			}

			restartTimer.restart();
		}
	}

	Timer {
		id: restartTimer
		interval: 1200
		repeat: false
		onTriggered: {
			root.inputMethod = "pipewire";
			root.restartProcess();
		}
	}
}
