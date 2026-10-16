.pragma library

// The controls of the mouse as the Mouse page shows them, and what each can
// be told to react to. `spot` is where it sits on MouseFigure (0…1 of the
// drawing's width and height), `label` the side the callout goes to.

var controls = [
	{ id: "middle", label: "Wheel click", icon: "mouse", spot: [0.563, 0.205], side: "right", triggers: "button" },
	{ id: "shift", label: "SmartShift button", icon: "cog_transfer", spot: [0.563, 0.336], side: "right", triggers: "button" },
	{ id: "thumb", label: "Thumb wheel", icon: "pan_horizontal", spot: [0.2, 0.488], side: "left", triggers: "thumb" },
	{ id: "forward", label: "Forward button", icon: "arrow_right", spot: [0.19, 0.57], side: "left", triggers: "button" },
	{ id: "back", label: "Back button", icon: "arrow_left", spot: [0.17, 0.632], side: "left", triggers: "button" },
	{ id: "gesture", label: "Gesture button", icon: "gesture_swipe", spot: [0.133, 0.714], side: "left", triggers: "button" },
	{ id: "haptic", label: "Haptic sense panel", icon: "vibrate", spot: [0.18, 0.824], side: "left", triggers: "button" },
	{ id: "left", label: "Left button", icon: "mouse", spot: [0.42, 0.2], side: "left", triggers: "none" },
	{ id: "right", label: "Right button", icon: "mouse", spot: [0.72, 0.2], side: "right", triggers: "none" }
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

// ready-made sets for the control the page shows: `for` "button" (any
// button) or "thumb" (the thumb wheel); they always go onto the control that
// is picked, in the place that is picked
var presets = [
	{
		id: "workspaces", for: "button", label: "Workspaces & windows", icon: "view_grid_outline",
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
		id: "media", for: "button", label: "Media", icon: "music_note",
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
		id: "capture", for: "button", label: "Screenshots", icon: "selection_drag",
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
		id: "edit", for: "button", label: "Undo & redo", icon: "undo",
		detail: "Swipe left: undo · swipe right: redo · click stays",
		rules: [
			{ trigger: "left", action: { kind: "keys", keys: ["ctrl", "z"], label: "Ctrl + Z" } },
			{ trigger: "right", action: { kind: "keys", keys: ["ctrl", "shift", "z"], label: "Ctrl + Shift + Z" } }
		]
	},
	{
		id: "browse", for: "button", label: "Browser", icon: "web",
		detail: "Left/right: back and forward · up: new tab · down: close the tab",
		rules: [
			{ trigger: "left", action: { kind: "keys", keys: ["alt", "left"], label: "Alt + ←" } },
			{ trigger: "right", action: { kind: "keys", keys: ["alt", "right"], label: "Alt + →" } },
			{ trigger: "up", action: { kind: "keys", keys: ["ctrl", "t"], label: "Ctrl + T" } },
			{ trigger: "down", action: { kind: "keys", keys: ["ctrl", "w"], label: "Ctrl + W" } }
		]
	},
	{
		id: "ring", for: "button", label: "Action ring", icon: "circle_slice_8",
		detail: "Click: the radial menu at the pointer, like Options+",
		rules: [
			{ trigger: "click", action: { kind: "shell", id: "radial" } }
		]
	},
	{
		id: "precision", for: "button", label: "Precision on hold", icon: "crosshairs",
		detail: "Hold: a slow, precise pointer while it is down; a click does what it did",
		rules: [
			{ trigger: "hold", action: { kind: "mouse", op: "dpi-shift" } }
		]
	},
	{
		id: "zoom", for: "button", label: "Zoom while held", icon: "magnify_plus_outline",
		detail: "Hold it and turn the wheel to zoom (Ctrl + / Ctrl −)",
		rules: [
			{ trigger: "wheel-up", action: { kind: "keys", keys: ["ctrl", "plus"], label: "Ctrl + +" } },
			{ trigger: "wheel-down", action: { kind: "keys", keys: ["ctrl", "minus"], label: "Ctrl + −" } }
		]
	},
	{
		id: "volume-held", for: "button", label: "Volume while held", icon: "volume_high",
		detail: "Hold it and turn the wheel for the volume",
		rules: [
			{ trigger: "wheel-up", action: { kind: "shell", id: "volume-up" } },
			{ trigger: "wheel-down", action: { kind: "shell", id: "volume-down" } }
		]
	},
	{
		id: "tabs", for: "thumb", label: "Tabs", icon: "tab",
		detail: "Turn to go through tabs (Ctrl+Tab / Ctrl+Shift+Tab)",
		rules: [
			{ trigger: "right", action: { kind: "keys", keys: ["ctrl", "tab"], label: "Ctrl + Tab" } },
			{ trigger: "left", action: { kind: "keys", keys: ["ctrl", "shift", "tab"], label: "Ctrl + Shift + Tab" } }
		]
	},
	{
		id: "thumb-volume", for: "thumb", label: "Volume", icon: "volume_high",
		detail: "Turn for louder and quieter",
		rules: [
			{ trigger: "right", action: { kind: "shell", id: "volume-up" } },
			{ trigger: "left", action: { kind: "shell", id: "volume-down" } }
		]
	},
	{
		id: "thumb-workspaces", for: "thumb", label: "Workspaces", icon: "view_grid_outline",
		detail: "Turn to go from workspace to workspace",
		rules: [
			{ trigger: "right", action: { kind: "niri", action: "focus-workspace-down" } },
			{ trigger: "left", action: { kind: "niri", action: "focus-workspace-up" } }
		]
	},
	{
		id: "thumb-columns", for: "thumb", label: "Windows", icon: "view_column_outline",
		detail: "Turn to go from window to window",
		rules: [
			{ trigger: "right", action: { kind: "niri", action: "focus-column-right" } },
			{ trigger: "left", action: { kind: "niri", action: "focus-column-left" } }
		]
	},
	{
		id: "thumb-zoom", for: "thumb", label: "Zoom", icon: "magnify_plus_outline",
		detail: "Turn to zoom in and out",
		rules: [
			{ trigger: "right", action: { kind: "keys", keys: ["ctrl", "plus"], label: "Ctrl + +" } },
			{ trigger: "left", action: { kind: "keys", keys: ["ctrl", "minus"], label: "Ctrl + −" } }
		]
	}
];

function presetsFor(control) {
	var meta = byId(control);
	if (!meta || meta.triggers === "none") return [];
	var kind = meta.triggers === "thumb" ? "thumb" : "button";
	return presets.filter(function (p) { return p.for === kind; });
}
