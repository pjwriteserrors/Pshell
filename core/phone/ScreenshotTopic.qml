import QtQuick
import Quickshell
import qs.core.services

// screenshot: the PC's capture modes, started from the phone (they run with
// their own UI on the PC), and the history of this session's shots.
Topic {
	id: topic

	name: "screenshot"

	data: topic.wanted ? ({
		history: Plugins.on("screenshot-history") ? Screenshot.shots.map(shot => ({ id: shot.id, time: shot.time, image: { "$blob": shot.path }, path: shot.path })) : null,
		modes: [
			{ id: "region", label: "Region", icon: "selection_drag" },
			{ id: "screen", label: "Screen", icon: "monitor" },
			{ id: "window", label: "Window", icon: "application_outline" },
			Plugins.on("color-picker") ? { id: "picker", label: "Colour", icon: "eyedropper" } : null,
			Plugins.on("ocr") ? { id: "ocr", label: "Text", icon: "text_recognition" } : null,
			Plugins.on("qr") ? { id: "qr", label: "QR", icon: "qrcode_scan" } : null,
			Plugins.on("pins") ? { id: "pin", label: "Pin", icon: "pin_outline" } : null,
			Plugins.on("scroll-screenshot") ? { id: "scroll", label: "Scroll", icon: "arrow_expand_vertical" } : null,
			Plugins.on("delayed-screenshot") ? { id: "delayed", label: "In 5 s", icon: "timer_outline" } : null
		].filter(mode => mode !== null)
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "region": Screenshot.region(); return {};
		case "screen": Screenshot.screen(); return {};
		case "window": Screenshot.window(); return {};
		case "picker": Screenshot.picker(); return {};
		case "ocr": Screenshot.ocr(); return {};
		case "qr": Screenshot.qr(); return {};
		case "pin": Screenshot.pinMode(); return {};
		case "scroll": Screenshot.scroll(); return {};
		case "delayed": Screenshot.delayed(Number(args.seconds || 5)); return {};
		case "cancel": Screenshot.cancel(); return {};
		case "forget": Screenshot.forgetShot(Number(args.id)); return {};
		case "copy": {
			const shot = Screenshot.shots.find(s => s.id === Number(args.id));
			if (!shot) throw new Error("That shot is gone");
			Screenshot.copyShot(shot.path);
			return {};
		}
		}
		throw new Error("unknown-action");
	}
}
