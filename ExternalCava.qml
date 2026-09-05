pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Item {
	id: root
	visible: false

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

	function restartProcess() {
		cavaProcess.running = false;
		Qt.callLater(function() {
			cavaProcess.command = root.buildCommand(root.inputMethod);
			cavaProcess.running = true;
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

	Process {
		id: cavaProcess
		running: true
		command: root.buildCommand(root.inputMethod)

		stdout: SplitParser {
			onRead: data => root.applyFrame(data)
		}

		onExited: (exitCode, exitStatus) => {
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
