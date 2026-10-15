.pragma library

// The controls of the mouse as the Mouse page shows them, and what each can
// be told to react to. `spot` is where it sits on MouseFigure (0…1 of the
// drawing's width and height), `label` the side the callout goes to.

var controls = [
	{ id: "middle", label: "Wheel click", icon: "mouse", spot: [0.535, 0.2], side: "right", triggers: "button" },
	{ id: "shift", label: "SmartShift button", icon: "cog_transfer", spot: [0.535, 0.335], side: "right", triggers: "button" },
	{ id: "thumb", label: "Thumb wheel", icon: "pan_horizontal", spot: [0.2, 0.47], side: "left", triggers: "thumb" },
	{ id: "forward", label: "Forward button", icon: "arrow_right", spot: [0.185, 0.555], side: "left", triggers: "button" },
	{ id: "back", label: "Back button", icon: "arrow_left", spot: [0.17, 0.625], side: "left", triggers: "button" },
	{ id: "gesture", label: "Gesture button", icon: "gesture_swipe", spot: [0.12, 0.715], side: "left", triggers: "button" },
	{ id: "haptic", label: "Haptic sense panel", icon: "vibrate", spot: [0.135, 0.82], side: "left", triggers: "button" },
	{ id: "left", label: "Left button", icon: "mouse", spot: [0.37, 0.16], side: "left", triggers: "none" },
	{ id: "right", label: "Right button", icon: "mouse", spot: [0.73, 0.18], side: "right", triggers: "none" }
];

var swipes = [
	{ id: "up", label: "Swipe up", icon: "arrow_up" },
	{ id: "down", label: "Swipe down", icon: "arrow_down" },
	{ id: "left", label: "Swipe left", icon: "arrow_left" },
	{ id: "right", label: "Swipe right", icon: "arrow_right" }
];

var extras = [
	{ id: "double", label: "Double click", icon: "gesture_double_tap" },
	{ id: "hold", label: "Hold", icon: "gesture_tap_hold" },
	{ id: "wheel-up", label: "Held + wheel up", icon: "mouse_move_up" },
	{ id: "wheel-down", label: "Held + wheel down", icon: "mouse_move_down" },
	{ id: "thumb-left", label: "Held + thumb wheel back", icon: "chevron_double_left" },
	{ id: "thumb-right", label: "Held + thumb wheel on", icon: "chevron_double_right" }
];

var thumbTriggers = [
	{ id: "left", label: "Turned back", icon: "chevron_double_left" },
	{ id: "right", label: "Turned on", icon: "chevron_double_right" }
];

var triggerLabels = {
	click: "Click", double: "Double click", hold: "Hold",
	up: "Swipe up", down: "Swipe down", left: "Swipe left", right: "Swipe right",
	"wheel-up": "Held + wheel up", "wheel-down": "Held + wheel down",
	"thumb-left": "Held + thumb back", "thumb-right": "Held + thumb on"
};

function byId(id) {
	for (var i = 0; i < controls.length; i += 1)
		if (controls[i].id === id) return controls[i];
	return null;
}

function triggerLabel(control, trigger) {
	if (control === "thumb") return trigger === "left" ? "Turned back" : "Turned on";
	return triggerLabels[trigger] || trigger;
}

function triggersOf(control) {
	var meta = byId(control);
	if (!meta || meta.triggers === "none") return [];
	if (meta.triggers === "thumb") return ["left", "right"];
	return ["click", "up", "down", "left", "right", "double", "hold", "wheel-up", "wheel-down", "thumb-left", "thumb-right"];
}

// ready-made sets for the button the page shows
var presets = [
	{
		id: "workspaces", label: "Workspaces & windows", icon: "view_grid_outline", control: "gesture",
		detail: "Click: overview · up/down: workspaces · left/right: windows",
		rules: [
			{ trigger: "click", action: { kind: "niri", action: "toggle-overview" } },
			{ trigger: "up", action: { kind: "niri", action: "focus-workspace-up" } },
			{ trigger: "down", action: { kind: "niri", action: "focus-workspace-down" } },
			{ trigger: "left", action: { kind: "niri", action: "focus-column-left" } },
			{ trigger: "right", action: { kind: "niri", action: "focus-column-right" } }
		]
	},
	{
		id: "media", label: "Media", icon: "music_note", control: "gesture",
		detail: "Click: play/pause · up/down: volume (again while moving) · left/right: tracks",
		rules: [
			{ trigger: "click", action: { kind: "shell", id: "play" } },
			{ trigger: "up", action: { kind: "shell", id: "volume-up" }, repeat: true },
			{ trigger: "down", action: { kind: "shell", id: "volume-down" }, repeat: true },
			{ trigger: "left", action: { kind: "shell", id: "previous" } },
			{ trigger: "right", action: { kind: "shell", id: "next" } }
		]
	},
	{
		id: "capture", label: "Screenshots", icon: "selection_drag", control: "gesture",
		detail: "Click: region · up: screen · down: window · left: colour · right: text",
		rules: [
			{ trigger: "click", action: { kind: "shell", id: "shot-region" } },
			{ trigger: "up", action: { kind: "shell", id: "shot-screen" } },
			{ trigger: "down", action: { kind: "shell", id: "shot-window" } },
			{ trigger: "left", action: { kind: "shell", id: "picker" } },
			{ trigger: "right", action: { kind: "shell", id: "ocr" } }
		]
	},
	{
		id: "ring", label: "Action ring", icon: "circle_slice_8", control: "haptic",
		detail: "The haptic panel opens the radial menu, like Options+",
		rules: [
			{ trigger: "click", action: { kind: "shell", id: "radial" } }
		]
	},
	{
		id: "precision", label: "Precision on hold", icon: "crosshairs", control: "shift",
		detail: "Hold the SmartShift button for a slow, precise pointer; a click still switches the wheel",
		rules: [
			{ trigger: "hold", action: { kind: "mouse", op: "dpi-shift" } }
		]
	},
	{
		id: "tabs", label: "Tabs on the thumb wheel", icon: "tab", control: "thumb",
		detail: "Turn the thumb wheel to go through tabs (Ctrl+Tab / Ctrl+Shift+Tab)",
		rules: [
			{ trigger: "right", action: { kind: "keys", keys: ["ctrl", "tab"] } },
			{ trigger: "left", action: { kind: "keys", keys: ["ctrl", "shift", "tab"] } }
		]
	},
	{
		id: "zoom", label: "Zoom with wheel click held", icon: "magnify_plus_outline", control: "middle",
		detail: "Hold the wheel and scroll to zoom (Ctrl + / Ctrl −)",
		rules: [
			{ trigger: "wheel-up", action: { kind: "keys", keys: ["ctrl", "plus"] } },
			{ trigger: "wheel-down", action: { kind: "keys", keys: ["ctrl", "minus"] } }
		]
	}
];
