import QtQuick
import Quickshell
import qs.core.services

// breaks: how long since the eyes, the legs and the bottle had their turn,
// the water of today, the week, the headache log.
Topic {
	id: topic

	name: "breaks"

	data: topic.wanted ? ({
		enabled: Breaks.enabled,
		quiet: Breaks.quiet,
		eyes: Plugins.on("eye-rest") ? { since: Breaks.sinceEyes, every: Breaks.eyesSeconds } : null,
		move: Plugins.on("stretch") ? { since: Breaks.sinceMove, every: Breaks.moveSeconds } : null,
		water: Plugins.on("water") ? {
			since: Breaks.sinceWater,
			every: Breaks.waterSeconds,
			ml: Breaks.waterMl,
			goal: Breaks.goalMl,
			pace: Breaks.paceMl,
			glasses: Breaks.glasses,
			glass: Breaks.glassSize,
			bottle: Breaks.bottleSize,
			bottleLeft: Breaks.bottleLeft,
			bottleSizes: Breaks.bottleSizes,
			canUncount: Breaks.canUncount
		} : null,
		headaches: Plugins.on("headache-log") ? (Breaks.todayEntry.headaches || []).map(entry => ({ at: entry.at, ml: entry.ml, screen: entry.screen })) : null,
		screen: Breaks.screenSeconds,
		taken: Breaks.todayEntry.breaks || 0,
		week: Breaks.week.map(day => ({ key: day.key, ahead: day.ahead, ml: day.ml, screen: day.screen, breaks: day.breaks, headaches: (day.headaches || []).length }))
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "enable":
			Breaks.setEnabled(!!args.on);
			return {};
		case "took":
			Breaks.tookBreak();
			return {};
		case "glass":
			Breaks.drinkGlass();
			return {};
		case "removeGlass":
			Breaks.removeGlass();
			return {};
		case "bottle":
			return { drunk: Breaks.setBottleLevel(Number(args.left)) };
		case "bottleSize":
			Breaks.setBottleSize(Number(args.ml));
			return {};
		case "refill":
			Breaks.refill();
			return {};
		case "uncount":
			Breaks.uncount();
			return {};
		case "headache":
			Breaks.logHeadache();
			return {};
		case "stretch":
			Breaks.startStretch();
			return {};
		case "eyeRest":
			Breaks.startEyeRest();
			return {};
		}
		throw new Error("unknown-action");
	}
}
