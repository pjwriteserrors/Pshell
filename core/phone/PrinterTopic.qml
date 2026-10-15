import QtQuick
import Quickshell
import qs.core.services

// printer: the 3D printer as the panel shows it – what it prints (the part,
// the layer on the nozzle from above), temperatures, the ACE and its drying,
// the jobs from the slicer's inbox with the slot each filament comes from,
// the statistics. The camera is the printer's own stream on the LAN.
Topic {
	id: topic

	name: "printer"
	throttle: 400

	function blob(path) {
		return path ? { "$blob": String(path) } : null;
	}

	function filaments(list) {
		return (list ?? []).map(filament => ({
			tool: Number(filament.tool ?? 0),
			color: filament.color ?? [128, 128, 128],
			type: String(filament.type ?? ""),
			grams: Number(filament.grams ?? 0)
		}));
	}

	function job(entry) {
		const meta = entry.meta ?? null;
		return {
			id: String(entry.id),
			title: Printer.title(entry),
			added: Number(entry.added ?? 0),
			printed: Number(entry.printed ?? 0),
			status: String(entry.status ?? ""),
			rendering: Printer.renders[entry.id] !== undefined || !!entry.rendering,
			sending: entry.status === "uploading" || Printer.uploads[entry.id] !== undefined,
			image: entry.preview ? topic.blob(`${entry.preview}/model.png`) : null,
			thumb: entry.preview ? topic.blob(`${entry.preview}/thumb.png`) : null,
			seconds: Number(meta?.seconds ?? 0),
			grams: Number(meta?.grams ?? 0),
			layers: Number(meta?.layers ?? 0),
			height: Number(meta?.height ?? 0),
			profile: String(meta?.profile ?? ""),
			filaments: topic.filaments(meta?.filaments),
			suggested: meta ? Printer.suggestAll(entry) : []
		};
	}

	data: topic.wanted ? ({
		configured: Printer.configured,
		online: Printer.online,
		error: Printer.error,
		name: Printer.name,
		firmware: Printer.firmware,
		status: Printer.status,
		printing: Printer.printing,
		paused: Printer.paused,
		progress: Printer.progress,
		layer: Printer.layer,
		layers: Printer.layers,
		secondsLeft: Printer.secondsLeft,
		printingTitle: Printer.printing ? Printer.nameOf(Printer.project?.filename ?? "") : "",
		printingJob: Printer.printingJob?.id ?? "",
		// the layer on the nozzle from above; no G-code here, no picture
		frame: Printer.printingJob ? topic.blob(Printer.frameUrl(Printer.printingJob, "top", Printer.frameIndex(Printer.printingJob, Printer.layer)).replace(/^file:\/\//, "")) : null,
		nozzle: Number(Printer.temps.curr_nozzle_temp ?? 0),
		nozzleTarget: Number(Printer.temps.target_nozzle_temp ?? 0),
		bed: Number(Printer.temps.curr_hotbed_temp ?? 0),
		bedTarget: Number(Printer.temps.target_hotbed_temp ?? 0),
		nozzleLog: Printer.nozzleLog,
		speed: Printer.speed,
		light: Printer.light,
		camera: Printer.camera,
		cameraUrl: Printer.cameraUrl,
		options: Printer.options,
		ace: Printer.ace ? {
			loaded: Number(Printer.ace.loaded ?? -1),
			humidity: Number(Printer.ace.humidity ?? 0),
			temp: Number(Printer.ace.temp ?? 0),
			drying: Printer.drying,
			dryTarget: Number(Printer.ace.drying?.target_temp ?? 0),
			dryLeft: Number(Printer.ace.drying?.remain_time ?? 0),
			dryDuration: Number(Printer.ace.drying?.duration ?? 0)
		} : null,
		slots: Printer.slots.map(slot => ({
			slot: Number(slot.slot),
			index: Number(slot.index),
			type: String(slot.type ?? ""),
			color: slot.color ?? [0, 0, 0],
			percent: Number(slot.percent ?? 0),
			sku: String(slot.sku ?? "")
		})),
		dryPresets: Printer.dryPresets,
		jobs: Printer.jobs.map(entry => topic.job(entry)),
		stats: {
			count: Printer.stats.count,
			finished: Printer.stats.finished,
			rate: Printer.stats.rate,
			minutes: Printer.stats.minutes,
			grams: Printer.stats.grams,
			average: Printer.stats.average,
			days: Printer.stats.days,
			colours: Printer.stats.colours.slice(0, 8)
		},
		history: Printer.history.slice(-20).reverse().map(item => ({
			title: Printer.nameOf(item.name),
			ended: Number(item.ended ?? 0),
			minutes: Number(item.minutes ?? 0),
			result: String(item.result ?? ""),
			progress: Number(item.progress ?? 0),
			grams: Number(item.grams ?? 0)
		}))
	}) : null

	function call(action, args, done) {
		if (!Printer.enabled) throw new Error("Switched off on the PC");
		switch (action) {
		case "refresh":
			Printer.refresh();
			return {};
		case "pause":
			Printer.pause();
			return {};
		case "resume":
			Printer.resume();
			return {};
		case "stop":
			if (!Printer.printing) throw new Error("Nothing prints");
			Printer.stop();
			return {};
		case "speed": {
			const mode = Number(args.mode);
			if (![1, 2, 3].includes(mode)) throw new Error("No such speed");
			Printer.setSpeed(mode);
			return {};
		}
		case "light":
			Printer.setLight(!!args.on);
			return {};
		case "camera":
			Printer.setCamera(!!args.on);
			return {};
		case "dry": {
			if (args.on === false) {
				Printer.stopDrying();
				return {};
			}
			const preset = Printer.dryPresets.find(entry => entry.label === String(args.preset));
			if (!preset) throw new Error("No such preset");
			Printer.dry(preset);
			return {};
		}
		case "option":
			if (!["leveling", "flow", "vibration"].includes(String(args.key))) throw new Error("No such option");
			Printer.setOption(String(args.key), !!args.value);
			return {};
		case "print": {
			const entry = Printer.job(String(args.id || ""));
			if (!entry) throw new Error("That job is gone");
			if (Printer.printing) throw new Error("The printer is busy");
			const tools = (entry.meta?.filaments ?? []).map(filament => filament.tool);
			const mapping = (args.mapping ?? []).map(pick => ({ tool: Number(pick.tool), slot: Number(pick.slot) }));
			if (tools.length === 0 || !tools.every(tool => mapping.some(pick => pick.tool === tool && Printer.slot(pick.slot) !== null)))
				throw new Error("Every filament needs a slot");
			Printer.start(entry.id, mapping);
			return {};
		}
		case "forget":
			if (!Printer.job(String(args.id || ""))) throw new Error("That job is gone");
			Printer.forget(String(args.id));
			return {};
		case "show":
			if (args.id && Printer.job(String(args.id))) Printer.show(String(args.id));
			else Printer.open();
			return {};
		}
		throw new Error("unknown-action");
	}
}
