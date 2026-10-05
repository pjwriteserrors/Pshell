import QtQuick
import Quickshell
import qs.core.services

// recording: whether the screen is being recorded; the phone can start a
// recording of a whole output and stop any.
Topic {
	id: topic

	name: "recording"

	data: topic.wanted ? ({
		active: Recorder.active,
		startedAt: Recorder.startedAt,
		file: Recorder.file,
		outputs: Quickshell.screens.map(screen => String(screen.name))
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "stop":
			Recorder.stop();
			return {};
		case "start": {
			if (Recorder.active) throw new Error("A recording is running");
			const output = String(args.output || Host.primaryOutput || Quickshell.screens[0]?.name || "");
			if (!Quickshell.screens.some(screen => String(screen.name) === output)) throw new Error("No such output");
			Quickshell.execDetached(["sh", "-c",
				'dir="$(xdg-user-dir VIDEOS 2>/dev/null || echo "$HOME/Videos")/Recordings"; mkdir -p "$dir"; file="$dir/Recording_$(date +%Y-%m-%d_%H-%M-%S).mp4"; '
				+ '"$1" recording started "$file" >/dev/null 2>&1; wf-recorder -o "$2" -f "$file" >/dev/null 2>&1; "$1" recording stopped "$file" >/dev/null 2>&1',
				"sh", `${Paths.scripts}/ipc.sh`, output]);
			return {};
		}
		}
		throw new Error("unknown-action");
	}
}
