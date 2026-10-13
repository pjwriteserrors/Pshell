import QtQuick
import Quickshell
import qs.core.services

// sounds: the shell's own sounds – the pack, which kind plays, how loud, and
// every moment on its own. Not the mixer: that is `sound`.
Topic {
	id: topic

	name: "sounds"
	throttle: 150

	onWantedChanged: if (topic.wanted) Sounds.refreshPacks()

	data: topic.wanted ? ({
		mode: Sounds.mode,
		volume: Sounds.volume,
		quietDnd: Sounds.quietDnd,
		pack: Sounds.current?.id ?? Sounds.pack,
		packs: Sounds.packs.map(entry => ({
			id: String(entry.id),
			name: String(entry.name || entry.id),
			author: String(entry.author || "")
		})),
		moments: Sounds.moments.map(moment => ({
			id: moment.id,
			kind: moment.kind,
			title: moment.title,
			icon: moment.icon,
			on: Sounds.enabled(moment.id)
		})),
		modified: Sounds.modified
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "mode":
			if (!["all", "buttons", "system", "off"].includes(String(args.mode))) throw new Error("No such mode");
			Sounds.setMode(String(args.mode));
			return {};
		case "volume":
			Sounds.setVolume(Number(args.volume) || 0);
			return {};
		case "quietDnd":
			Sounds.setQuietDnd(args.on === undefined ? !Sounds.quietDnd : !!args.on);
			return {};
		// the PC plays a few sounds of the pack it switches to
		case "pack":
			if (!Sounds.packs.some(entry => entry.id === String(args.id))) throw new Error("No such pack");
			Sounds.setPack(String(args.id));
			return {};
		case "moment":
			if (!Sounds.byId[String(args.id)]) throw new Error("No such sound");
			Sounds.setEnabled(String(args.id), !!args.on);
			return {};
		case "reset":
			Sounds.resetSwitches();
			return {};
		// heard at the PC, whatever the settings say
		case "preview":
			if (!Sounds.byId[String(args.id || "notification")]) throw new Error("No such sound");
			Sounds.preview(String(args.id || "notification"));
			return {};
		}
		throw new Error("unknown-action");
	}
}
