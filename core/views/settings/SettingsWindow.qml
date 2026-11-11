pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// >settings, the Pshell settings: every setting niri has, but the ones Studio
// looks after (cursor theme, animations), and those of the shell's own
// (multicursor, sounds). The pages are on the left; typing finds a setting
// on any page and jumps to it. Every change is live at once (niri reloads
// the file); Ctrl+Z takes it back. core/services/NiriSettings.qml does the
// rest. A window of its own (Popups.settingsOpen): niri places it like any
// other, it stays while other panels come and go.
FloatingWindow {
	id: root

	readonly property bool shown: Popups.settingsOpen
	title: Popups.settingsTitle
	visible: false
	implicitWidth: 1440
	implicitHeight: 920
	minimumSize: Qt.size(960, 600)
	color: Theme.base

	onShownChanged: root.follow()
	Component.onCompleted: root.follow()

	function follow() {
		root.visible = root.shown;
		if (root.shown) root.opened();
	}
	// closed with the compositor's own means
	onVisibleChanged: if (!root.visible && Popups.settingsOpen) Popups.closeSettings()

	Shortcut {
		sequences: ["Ctrl+W", "Ctrl+Q"]
		enabled: root.shown
		onActivated: Popups.closeSettings()
	}

	function opened() {
		NiriSettings.prepare();
		Keybinds.load();
		Keybinds.loadCatalogs();
		NiriSettings.error = "";
		Keybinds.error = "";
		search.text = "";
		root.exportError = "";
		exportSheet.close();
		root.go(NiriSettings.page || root.current || "displays", NiriSettings.anchor);
	}

	property string current: "displays"
	property var visited: ({})
	property string exportError: ""
	readonly property string query: search.text.trim().toLowerCase()

	readonly property var pages: [
		{ id: "displays", label: "Displays", icon: "monitor_multiple", hint: "Arrangement, modes, setups" },
		{ id: "layout", label: "Layout", icon: "view_column_outline", hint: "Gaps, columns, struts" },
		{ id: "looks", label: "Borders & shadows", icon: "border_style", hint: "Focus ring, border, shadow, tabs" },
		{ id: "input", label: "Input", icon: "mouse", hint: "Keyboard, mouse, touchpad, tablet" },
		{ id: "keys", label: "Key binds", icon: "keyboard", hint: "Shortcuts and switches" },
		{ id: "devices", label: "Devices", icon: "devices", hint: "Mice, keyboards and other HID devices" },
		{ id: "mouse", label: "Mouse", icon: "mouse_variant", hint: "Buttons, gestures, scrolling, haptics", plugin: "mouse" },
		{ id: "hud", label: "HUD haptics", icon: "crosshairs_gps", hint: "Zones on the game's HUD the mouse feels", plugin: "mouse" },
		{ id: "keyboard", label: "Keyboard", icon: "keyboard_settings", hint: "Special keys, backlight, Fn keys", plugin: "keyboard" },
		{ id: "apex", label: "Apex Pro", icon: "keyboard_variant", hint: "Actuation, Rapid Trigger, keys, OLED", plugin: "apex" },
		{ id: "ultimate", label: "Controller", icon: "gamepad_variant", hint: "8BitDo: buttons, sticks, light, macros", plugin: "ultimate" },
		{ id: "headset", label: "Headset", icon: "headset", hint: "Sidetone, microphone, buttons", plugin: "headset" },
		{ id: "fingerprint", label: "Fingerprint", icon: "fingerprint", hint: "Fingers, where they unlock", plugin: "fingerprint" },
		{ id: "btadapter", label: "Bluetooth adapter", icon: "bluetooth_settings", hint: "Radio, channels, modes, timing, bluetoothd", plugin: "bt-adapter" },
		{ id: "webcam", label: "Webcam", icon: "video", hint: "Picture, Enhance, virtual camera, light, microphone", plugin: "webcam" },
		{ id: "hpcamera", label: "HP camera", icon: "video", hint: "Picture, exposure spot, IR, face unlock, virtual camera", plugin: "hp-camera" },
		{ id: "as50", label: "Avantree AS50", icon: "headphones", hint: "Codec, microphone, buttons, battery", plugin: "as50" },
		{ id: "amazfit", label: "Amazfit watch", icon: "watch", hint: "Zepp OS settings, alarms, keys, notifications", plugin: "amazfit" },
		{ id: "multicursor", label: "Multicursor", icon: "cursor_text", hint: "Lines and cursors in every text field", plugin: "multicursor" },
		{ id: "rules", label: "Window rules", icon: "application_cog_outline", hint: "Per app: size, place, look" },
		{ id: "workspaces", label: "Workspaces", icon: "view_grid_outline", hint: "Named workspaces" },
		{ id: "overview", label: "Overview & gestures", icon: "gesture_swipe", hint: "Overview, hot corners, Alt-Tab" },
		{ id: "system", label: "System", icon: "cog_outline", hint: "Startup, environment, screenshots, blur" },
		{ id: "apps", label: "Default apps", icon: "apps", hint: "Which program opens what, the terminal" },
		{ id: "browser", label: "Browser", icon: "web", hint: "Extension, look, what the shell does in it" },
		{ id: "bar", label: "Desktop", icon: "dock_window", hint: "Bar, wallpaper, game mode", plugin: "bar" },
		{ id: "tray", label: "App tray", icon: "dock_left", hint: "Apps and commands on a screen edge", plugin: "app-tray" },
		{ id: "sounds", label: "Sounds", icon: "volume_high", hint: "Clicks, notifications, devices", plugin: "sounds" },
		{ id: "colours", label: "Colours", icon: "palette", hint: "Wallpaper colours: engine, style, tuning" },
		{ id: "lighting", label: "Lighting", icon: "led_strip_variant", hint: "Keyboard and LEDs: wallpaper or screen", shown: Lighting.enabled },
		{ id: "phone", label: "Notifications", icon: "bell_outline", hint: "Which programs notify, here and on the phone", plugin: "notifications" },
		{ id: "debug", label: "Debug", icon: "bug_outline", hint: "Rendering and driver switches" }
	].filter(page => (!page.plugin || Plugins.on(page.plugin)) && page.shown !== false)

	// what search finds: a card on a page. `take` is what an export of the card
	// holds: paths in settings.kdl, `output:<setting>` of every monitor,
	// `@binds` (keybinds.kdl), `@corners` (the window rule without a match)
	readonly property var index: [
		{ page: "displays", anchor: "arrangement", title: "Monitor arrangement", words: "position drag monitors outputs place", take: ["output:position", "output:off"] },
		{ page: "displays", anchor: "mode", title: "Resolution and refresh rate", words: "mode hz refresh resolution custom modeline", take: ["output:mode", "output:modeline"] },
		{ page: "displays", anchor: "scale", title: "Scale", words: "scale hidpi zoom size", take: ["output:scale"] },
		{ page: "displays", anchor: "rotation", title: "Rotation", words: "transform rotate flip portrait", take: ["output:transform"] },
		{ page: "displays", anchor: "vrr", title: "Variable refresh rate", words: "vrr freesync gsync adaptive sync", take: ["output:variable-refresh-rate"] },
		{ page: "displays", anchor: "monitor-extras", title: "Startup focus, backdrop, hot corners of a monitor", words: "focus-at-startup backdrop color hot corners", take: ["output:focus-at-startup", "output:backdrop-color", "output:background-color", "output:hot-corners", "output:layout"] },
		{ page: "displays", anchor: "setups", title: "Display setups", words: "profile setup save home office" },
		{ page: "layout", anchor: "gaps", title: "Gaps", words: "gaps spacing margin", take: ["layout/gaps"] },
		{ page: "layout", anchor: "struts", title: "Struts", words: "struts outer gaps edge", take: ["layout/struts"] },
		{ page: "layout", anchor: "centering", title: "Centering columns", words: "center-focused-column always-center-single-column", take: ["layout/center-focused-column", "layout/always-center-single-column"] },
		{ page: "layout", anchor: "widths", title: "Column widths", words: "preset-column-widths default-column-width proportion fixed", take: ["layout/preset-column-widths", "layout/default-column-width"] },
		{ page: "layout", anchor: "heights", title: "Window heights", words: "preset-window-heights default height", take: ["layout/preset-window-heights"] },
		{ page: "layout", anchor: "columns", title: "New columns and workspaces", words: "default-column-display tabbed empty-workspace-above-first", take: ["layout/default-column-display", "layout/empty-workspace-above-first"] },
		{ page: "layout", anchor: "background", title: "Workspace background", words: "background-color", take: ["layout/background-color"] },
		{ page: "looks", anchor: "focus-ring", title: "Focus ring", words: "focus ring active color gradient", take: ["layout/focus-ring"] },
		{ page: "looks", anchor: "border", title: "Border", words: "border width color gradient", take: ["layout/border"] },
		{ page: "looks", anchor: "shadow", title: "Shadow", words: "shadow softness spread offset", take: ["layout/shadow"] },
		{ page: "looks", anchor: "tab-indicator", title: "Tab indicator", words: "tab indicator tabbed column", take: ["layout/tab-indicator"] },
		{ page: "looks", anchor: "insert-hint", title: "Insert hint", words: "insert hint drag move", take: ["layout/insert-hint"] },
		{ page: "looks", anchor: "corners", title: "Window corners", words: "geometry-corner-radius rounded clip-to-geometry", take: ["@corners"] },
		{ page: "looks", anchor: "screen-frame", title: "Screen frame", words: "frame screen corners bottom edges thickness", plugin: "bottom-corners" },
		{ page: "input", anchor: "layouts", title: "Keyboard layouts", words: "xkb layout variant language", take: ["input/keyboard/xkb/layout", "input/keyboard/xkb/variant", "input/keyboard/xkb/model", "input/keyboard/xkb/rules", "input/keyboard/xkb/file"] },
		{ page: "input", anchor: "xkb-options", title: "Keyboard options", words: "xkb options compose caps ctrl", take: ["input/keyboard/xkb/options"] },
		{ page: "input", anchor: "repeat", title: "Key repeat", words: "repeat-delay repeat-rate", take: ["input/keyboard/repeat-delay", "input/keyboard/repeat-rate"] },
		{ page: "input", anchor: "keyboard-more", title: "Num Lock, layout per window", words: "numlock track-layout", take: ["input/keyboard/numlock", "input/keyboard/track-layout"] },
		{ page: "input", anchor: "pointer", title: "Mouse, touchpad, trackpoint, trackball", words: "accel speed natural scroll tap dwt left-handed middle-emulation scroll-factor", take: ["input/mouse", "input/touchpad", "input/trackpoint", "input/trackball"] },
		{ page: "input", anchor: "tablet", title: "Tablet and touch screen", words: "tablet touch map-to-output calibration", take: ["input/tablet", "input/touch"] },
		{ page: "input", anchor: "focus", title: "Focus follows mouse", words: "focus-follows-mouse warp-mouse-to-focus", take: ["input/focus-follows-mouse", "input/warp-mouse-to-focus"] },
		{ page: "input", anchor: "mouse-capture", title: "Capture the mouse in a window", words: "mouse capture confine lock trap pointer game window monitor page down", plugin: "mouse-capture" },
		{ page: "input", anchor: "mod", title: "Mod key", words: "mod-key mod-key-nested super alt", take: ["input/mod-key", "input/mod-key-nested"] },
		{ page: "input", anchor: "input-more", title: "Power key, workspace back and forth, cursor", words: "disable-power-key-handling workspace-auto-back-and-forth hide-when-typing hide-after-inactive-ms cursor", take: ["input/disable-power-key-handling", "input/workspace-auto-back-and-forth", "cursor/hide-when-typing", "cursor/hide-after-inactive-ms"] },
		{ page: "keys", anchor: "binds", title: "Key binds", words: "keys shortcuts binds hotkeys", take: ["@binds"] },
		{ page: "keys", anchor: "switches", title: "Lid and tablet mode", words: "switch-events lid-close lid-open tablet-mode", take: ["switch-events"] },
		{ page: "devices", anchor: "devices-list", title: "Connected devices", words: "hid usb bluetooth device mouse keyboard receiver unknown reverse engineer claude" },
		{ page: "devices", anchor: "devices-bluetooth", title: "Paired Bluetooth devices", words: "bluetooth paired headphones headset watch speaker gatt reverse engineer claude" },
		{ page: "devices", anchor: "devices-network", title: "Devices on the network", words: "network lan wifi wlan scan tv speaker printer mdns upnp ssdp smart home reverse engineer claude" },
		{ page: "devices", anchor: "devices-own", title: "Your own devices", words: "custom add device app appimage exe windows linux vendor protocol reverse engineer claude" },
		{ page: "keyboard", anchor: "keyboard-keys", title: "Keyboard keys", words: "logitech mx keys special key emoji screenshot lock calculator dictation media remap per app", plugin: "keyboard" },
		{ page: "keyboard", anchor: "keyboard-light", title: "Keyboard backlight", words: "backlight lighting illumination brightness flash notification hands proximity", plugin: "keyboard" },
		{ page: "keyboard", anchor: "keyboard-fn", title: "Fn keys and locked keys", words: "fn lock swap f1 f12 caps lock num lock insert super disable platform os layout", plugin: "keyboard" },
		{ page: "keyboard", anchor: "keyboard-hosts", title: "Keyboard Easy-Switch", words: "easy switch host channel computer", plugin: "keyboard" },
		{ page: "keyboard", anchor: "keyboard-battery", title: "Keyboard battery", words: "battery charge firmware", plugin: "keyboard" },
		{ page: "apex", anchor: "apex-keys", title: "Apex keyboard", words: "steelseries apex pro tkl gen 3 keyboard config profile", plugin: "apex" },
		{ page: "apex", anchor: "apex-actuation", title: "Actuation and Rapid Trigger", words: "steelseries apex actuation point depth omnipoint hall rapid trigger sensitivity protection mode", plugin: "apex" },
		{ page: "apex", anchor: "apex-dual", title: "2-in-1 action", words: "steelseries apex dual actuation second point two in one deeper press", plugin: "apex" },
		{ page: "apex", anchor: "apex-bindings", title: "Apex keys", words: "steelseries apex remap key binding macro media mouse fn layer steelseries key per app double press hold", plugin: "apex" },
		{ page: "apex", anchor: "apex-macros", title: "Ultra macros", words: "steelseries apex macro record play repeat mouse clicks keys sequence automation", plugin: "apex" },
		{ page: "apex", anchor: "apex-rapidtap", title: "Rapid Tap", words: "steelseries apex rapid tap socd snap tap last input priority", plugin: "apex" },
		{ page: "apex", anchor: "apex-oled", title: "Apex display", words: "steelseries apex oled screen display clock media notification picture text", plugin: "apex" },
		{ page: "apex", anchor: "apex-light", title: "Apex light", words: "steelseries apex brightness light rgb", plugin: "apex" },
		{ page: "apex", anchor: "apex-configs", title: "Apex configs", words: "steelseries apex onboard config profile slot rename copy backup restore", plugin: "apex" },
		{ page: "headset", anchor: "headset-device", title: "Headset", words: "sennheiser epos pc 8.2 usb headset headphones", plugin: "headset" },
		{ page: "headset", anchor: "headset-sound", title: "Headset sound", words: "sennheiser headset volume balance left right mute", plugin: "headset" },
		{ page: "headset", anchor: "headset-mic", title: "Headset microphone", words: "sennheiser headset microphone mic gain level mute cable switch", plugin: "headset" },
		{ page: "headset", anchor: "headset-sidetone", title: "Sidetone", words: "sennheiser headset sidetone hear yourself own voice monitoring", plugin: "headset" },
		{ page: "headset", anchor: "headset-buttons", title: "Headset buttons", words: "sennheiser headset buttons volume up down remote press double hold per app", plugin: "headset" },
		{ page: "fingerprint", anchor: "fingerprint-device", title: "Fingerprint reader", words: "fingerprint finger reader sensor elan enroll test delete fprintd", plugin: "fingerprint" },
		{ page: "fingerprint", anchor: "fingerprint-use", title: "Unlock with the finger", words: "fingerprint unlock lock screen sudo polkit admin login sddm swaylock su pam tries timeout", plugin: "fingerprint" },
		{ page: "fingerprint", anchor: "fingerprint-reader", title: "Fingerprint reader details", words: "fingerprint wake sleep suspend touch firmware usb delete all", plugin: "fingerprint" },
		{ page: "btadapter", anchor: "btadapter-device", title: "Bluetooth adapter", words: "bluetooth adapter intel ax201 name alias visible discoverable pairable connectable rfkill power root helper", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-links", title: "Bluetooth connections", words: "bluetooth link rssi signal quality transmit power afh channel map paired wake trusted blocked disconnect", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-radio", title: "Bluetooth radio", words: "bluetooth phy le 2m coded edr slots channels afh wifi coexistence avoid link policy sniff role switch central", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-modes", title: "Bluetooth modes", words: "bluetooth classic le dual fast connectable secure connections ssp link security wide band speech privacy random address debug keys", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-identity", title: "Bluetooth identity", words: "bluetooth address mac public static class of device appearance device id did", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-advertising", title: "Bluetooth advertising", words: "bluetooth advertising beacon ibeacon eddystone url manufacturer data transmit power broadcast", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-timing", title: "Bluetooth timing", words: "bluetooth page scan inquiry scan interval window sniff supervision timeout le scan connection interval latency advertising monitor", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-security", title: "Bluetooth security", words: "bluetooth key size encryption mitm just works repairing bonded gatt security", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-experimental", title: "Bluetooth experimental", words: "bluetooth experimental quality report iso le audio mesh central peripheral kernel", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-bluez", title: "bluetoothd settings", words: "bluetooth bluetoothd main.conf auto enable reconnect gatt cache mtu eatt avdtp avrcp absolute volume hid restart", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-power", title: "Bluetooth power and driver", words: "bluetooth usb autosuspend sleep wake btusb module parameters ertm esco reset adapter", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-debug", title: "Bluetooth debug", words: "bluetooth debugfs advertising channels dut device under test intel diagnostics quirk", plugin: "bt-adapter" },
		{ page: "btadapter", anchor: "btadapter-about", title: "About the Bluetooth adapter", words: "bluetooth firmware version intel chip codecs features buffers secure boot", plugin: "bt-adapter" },
		{ page: "webcam", anchor: "webcam-device", title: "Webcam", words: "webcam camera logitech c310 preview photo raw dng picture", plugin: "webcam" },
		{ page: "webcam", anchor: "webcam-enhance", title: "Enhance the webcam", words: "webcam enhance auto tune improve picture ai ollama model local", plugin: "webcam" },
		{ page: "webcam", anchor: "webcam-picture", title: "Webcam picture", words: "webcam brightness contrast saturation sharpness gain white balance temperature backlight compensation anti flicker power line 50 60 hz", plugin: "webcam" },
		{ page: "webcam", anchor: "webcam-exposure", title: "Webcam exposure", words: "webcam exposure automatic manual time low light frame rate rightlight sensor boost gain", plugin: "webcam" },
		{ page: "webcam", anchor: "webcam-processing", title: "Webcam processing", words: "webcam color boost gamma lens shading pixel defect correction tde mjpeg resync markers logitech extension unit", plugin: "webcam" },
		{ page: "webcam", anchor: "webcam-virtual", title: "Virtual camera", words: "webcam virtual camera v4l2loopback zoom pan digital follow face tracking frame mirror output resolution", plugin: "webcam" },
		{ page: "webcam", anchor: "webcam-led", title: "Webcam light", words: "webcam led light off on blink auto privacy", plugin: "webcam" },
		{ page: "webcam", anchor: "webcam-mic", title: "Webcam microphone", words: "webcam microphone mic gain mute level default", plugin: "webcam" },
		{ page: "hpcamera", anchor: "hpcamera-device", title: "HP camera", words: "hp hd camera built in laptop probook sunplus spca2650 preview photo picture", plugin: "hp-camera" },
		{ page: "hpcamera", anchor: "hpcamera-enhance", title: "Enhance the HP camera", words: "hp camera enhance auto tune improve picture ai ollama model local", plugin: "hp-camera" },
		{ page: "hpcamera", anchor: "hpcamera-picture", title: "HP camera picture", words: "hp camera brightness contrast saturation hue gamma sharpness gain white balance temperature backlight compensation anti flicker power line 50 60 hz", plugin: "hp-camera" },
		{ page: "hpcamera", anchor: "hpcamera-exposure", title: "HP camera exposure", words: "hp camera exposure automatic manual time low light frame rate spot region of interest roi aim", plugin: "hp-camera" },
		{ page: "hpcamera", anchor: "hpcamera-vendor", title: "HP camera Sunplus unit", words: "hp camera sunplus extension unit vendor selector", plugin: "hp-camera" },
		{ page: "hpcamera", anchor: "hpcamera-ir", title: "IR camera", words: "hp ir infrared camera emitter windows hello lit dark difference metadata photo", plugin: "hp-camera" },
		{ page: "hpcamera", anchor: "hpcamera-face", title: "Unlock with the face", words: "face unlock recognition enroll add test lock screen windows hello ir tries", plugin: "hp-camera" },
		{ page: "hpcamera", anchor: "hpcamera-virtual", title: "HP virtual camera", words: "hp camera virtual camera v4l2loopback zoom pan digital follow face tracking frame mirror output resolution", plugin: "hp-camera" },
		{ page: "hpcamera", anchor: "hpcamera-about", title: "About the HP camera", words: "hp camera chip firmware formats usb power nodes reset defaults", plugin: "hp-camera" },
		{ page: "webcam", anchor: "webcam-about", title: "About the webcam", words: "webcam firmware sensor lens field of view formats usb power reset defaults", plugin: "webcam" },
		{ page: "as50", anchor: "as50-device", title: "Avantree AS50", words: "avantree as50 ensemble bluetooth headphones headset battery connect disconnect", plugin: "as50" },
		{ page: "as50", anchor: "as50-sound", title: "AS50 sound", words: "avantree as50 bluetooth headphones volume absolute avrcp mute", plugin: "as50" },
		{ page: "as50", anchor: "as50-codec", title: "AS50 codec", words: "avantree as50 bluetooth codec aac sbc sbc-xq faststream latency lip sync delay a2dp", plugin: "as50" },
		{ page: "as50", anchor: "as50-mic", title: "AS50 microphone", words: "avantree as50 bluetooth microphone mic hfp call faststream duplex gain mute autoswitch", plugin: "as50" },
		{ page: "as50", anchor: "as50-buttons", title: "AS50 buttons", words: "avantree as50 buttons play pause next previous redial double press per app media keys", plugin: "as50" },
		{ page: "as50", anchor: "as50-eq", title: "AS50 sound mode", words: "avantree as50 eq equalizer clear voice balanced mode", plugin: "as50" },
		{ page: "as50", anchor: "as50-connection", title: "AS50 connection", words: "avantree as50 bluetooth name rename trusted auto connect take over ensemble transmitter battery warning", plugin: "as50" },
		{ page: "as50", anchor: "as50-info", title: "AS50 profiles", words: "avantree as50 sdp profiles hfp a2dp avrcp versions codecs", plugin: "as50" },
		{ page: "amazfit", anchor: "amazfit-device", title: "Amazfit watch", words: "amazfit zepp watch active 2 battery connect disconnect clock heart rate steps find vibrate", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-zepp", title: "Watch auth key", words: "amazfit zepp watch active 2 zepp os auth key gadgetbridge huafetcher pairing encryption", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-keys", title: "Watch keys", words: "amazfit zepp watch active 2 media keys music remote camera shutter hid buttons per app hidden report", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-display", title: "Watch display", words: "amazfit zepp watch active 2 brightness always on display aod raise wrist screen timeout", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-sound", title: "Watch sound and vibration", words: "amazfit zepp watch active 2 volume vibration strength crown alert tone", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-health", title: "Watch health", words: "amazfit zepp watch active 2 heart rate stress spo2 blood oxygen sleep inactivity goals steps", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-system", title: "Watch system", words: "amazfit zepp watch active 2 do not disturb night mode time format date units buttons camera remote", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-workout", title: "Watch workouts", words: "amazfit zepp watch active 2 gps band satellites detection heart rate zones", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-alarms", title: "Watch alarms", words: "amazfit zepp watch active 2 alarm smart wake", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-faces", title: "Watch faces", words: "amazfit zepp watch active 2 watchface face", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-apps", title: "Watch apps", words: "amazfit zepp watch active 2 apps installed remove", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-menu", title: "Watch menus", words: "amazfit zepp watch active 2 apps menu shortcuts control centre order", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-notifications", title: "Watch notifications", words: "amazfit zepp watch active 2 notifications music weather do not disturb find phone", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-canned", title: "Watch quick replies", words: "amazfit zepp watch active 2 canned replies messages", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-reminders", title: "Watch reminders", words: "amazfit zepp watch active 2 reminders todo", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-calendar", title: "Watch calendar", words: "amazfit zepp watch active 2 calendar events", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-clocks", title: "Watch world clocks", words: "amazfit zepp watch active 2 world clocks time zones", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-vibration", title: "Watch vibration patterns", words: "amazfit zepp watch active 2 vibration patterns alerts", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-user", title: "Watch body data", words: "amazfit zepp watch active 2 height weight age gender", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-connection", title: "Watch connection", words: "amazfit zepp watch active 2 auto connect time sync battery warning", plugin: "amazfit" },
		{ page: "amazfit", anchor: "amazfit-info", title: "This watch", words: "amazfit zepp watch active 2 serial firmware hardware services gatt", plugin: "amazfit" },
		{ page: "headset", anchor: "headset-profile", title: "Headset profile", words: "sennheiser headset audio profile duplex output input pro audio off", plugin: "headset" },
		{ page: "ultimate", anchor: "ultimate-pad", title: "8BitDo controller", words: "8bitdo ultimate 2 wireless controller gamepad pad profile battery", plugin: "ultimate" },
		{ page: "ultimate", anchor: "ultimate-buttons", title: "Controller buttons", words: "8bitdo gamepad remap buttons paddles pl pr l4 r4 back buttons turbo", plugin: "ultimate" },
		{ page: "ultimate", anchor: "ultimate-sticks", title: "Controller sticks", words: "8bitdo gamepad stick dead zone invert swap d-pad", plugin: "ultimate" },
		{ page: "ultimate", anchor: "ultimate-triggers", title: "Controller triggers", words: "8bitdo gamepad trigger hall range swap", plugin: "ultimate" },
		{ page: "ultimate", anchor: "ultimate-rumble", title: "Controller vibration", words: "8bitdo gamepad rumble vibration motors trigger vibration", plugin: "ultimate" },
		{ page: "ultimate", anchor: "ultimate-motion", title: "Controller motion", words: "8bitdo gamepad gyro motion six axis tilt aim", plugin: "ultimate" },
		{ page: "ultimate", anchor: "ultimate-light", title: "Controller light", words: "8bitdo gamepad led ring light colour rgb hotwheel", plugin: "ultimate" },
		{ page: "ultimate", anchor: "ultimate-macros", title: "Controller macros", words: "8bitdo gamepad macro record sequence", plugin: "ultimate" },
		{ page: "ultimate", anchor: "ultimate-profiles", title: "Controller profiles", words: "8bitdo gamepad profile star button copy", plugin: "ultimate" },
		{ page: "mouse", anchor: "mouse-buttons", title: "Mouse buttons and gestures", words: "logitech mx master button remap gesture swipe thumb wheel per app solaar rule action ring", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-rules", title: "Mouse rules", words: "rule editor condition modifier ctrl shift app hold double click solaar", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-pointer", title: "Mouse DPI", words: "dpi speed sensitivity pointer precision sniper shift", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-scroll", title: "Mouse wheel", words: "smartshift ratchet free spin torque wheel natural scrolling hires thumb wheel", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-haptics", title: "Mouse haptics", words: "haptic vibration feedback strength waveform pulse", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-force", title: "Haptic sense panel", words: "force sensing button pressure panel thumb", plugin: "mouse" },
		{ page: "hud", anchor: "hud-scenes", title: "HUD zones – scenes of the game", words: "hud zone game haptics rumble feel picture scene fight dialog draw screen", plugin: "mouse" },
		{ page: "hud", anchor: "hud-picture", title: "HUD zones – the picture, drawing and reactions", words: "hud zone draw box click hover change red bright dark pattern vibration", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-hosts", title: "Easy-Switch", words: "easy switch host channel computer bluetooth pair", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-stats", title: "Mouse statistics", words: "distance clicks scroll odometer statistics", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-device", title: "Mouse battery and firmware", words: "battery firmware serial receiver bolt unifying hid++ features", plugin: "mouse" },
		{ page: "multicursor", anchor: "multicursor", title: "Multicursor shortcuts", words: "move copy duplicate line add cursor above below click multi" },
		{ page: "multicursor", anchor: "multicursor-apps", title: "Multicursor: excluded apps", words: "apps exclude leave alone" },
		{ page: "rules", anchor: "rules", title: "Window rules", words: "window-rule match app-id title open-floating opacity", take: ["window-rule"] },
		{ page: "rules", anchor: "layer-rules", title: "Layer rules", words: "layer-rule namespace bar notifications", take: ["layer-rule"] },
		{ page: "workspaces", anchor: "workspaces", title: "Named workspaces", words: "workspace named open-on-output", take: ["workspace"] },
		{ page: "overview", anchor: "overview", title: "Overview", words: "overview zoom backdrop workspace-shadow", take: ["overview"] },
		{ page: "overview", anchor: "overview-cards", title: "Overview panel cards", words: "overview panel cards corners radius round workspaces" },
		{ page: "overview", anchor: "hot-corners", title: "Hot corners", words: "hot-corners corner overview", take: ["gestures/hot-corners"] },
		{ page: "overview", anchor: "dnd-edge", title: "Scrolling while dragging", words: "dnd-edge-view-scroll dnd-edge-workspace-switch trigger", take: ["gestures/dnd-edge-view-scroll", "gestures/dnd-edge-workspace-switch"] },
		{ page: "overview", anchor: "recent", title: "Window switcher (Alt-Tab)", words: "recent-windows alt tab switcher debounce previews highlight layout carousel grid live blur", take: ["recent-windows"] },
		{ page: "system", anchor: "startup", title: "Startup programs", words: "spawn-at-startup autostart", take: ["spawn-at-startup", "spawn-sh-at-startup"] },
		{ page: "system", anchor: "environment", title: "Environment variables", words: "environment variables env", take: ["environment"] },
		{ page: "system", anchor: "screenshots", title: "Screenshot path", words: "screenshot-path pictures", take: ["screenshot-path"] },
		{ page: "system", anchor: "decorations", title: "Title bars (CSD)", words: "prefer-no-csd decorations title bar", take: ["prefer-no-csd"] },
		{ page: "system", anchor: "blur", title: "Blur", words: "blur passes offset noise saturation", take: ["blur"] },
		{ page: "system", anchor: "system-more", title: "Clipboard, hotkey overlay, notifications, Xwayland", words: "clipboard disable-primary hotkey-overlay config-notification xwayland-satellite", take: ["clipboard", "hotkey-overlay", "config-notification", "xwayland-satellite"] },
		{ page: "apps", anchor: "apps-web", title: "Default browser and mail", words: "default apps browser web links mail mailto standard programm firefox floorp chromium thunderbird", },
		{ page: "apps", anchor: "apps-files", title: "Default file manager and archives", words: "default apps file manager folder directory archive zip rar 7z unpack standard programm" },
		{ page: "apps", anchor: "apps-media", title: "Default image viewer, video and music player", words: "default apps image picture photo viewer video player music audio mpv vlc standard programm" },
		{ page: "apps", anchor: "apps-documents", title: "Default text editor, PDF viewer, office", words: "default apps text editor pdf office document word excel ebook epub calendar standard programm" },
		{ page: "apps", anchor: "apps-more", title: "Default torrent client, 3D models", words: "default apps torrent magnet 3d model stl 3mf slicer standard programm" },
		{ page: "apps", anchor: "apps-terminal", title: "Terminal", words: "default terminal kitty alacritty foot console shell standard" },
		{ page: "bar", anchor: "bar-items", title: "Bar items", words: "bar panel widgets order drag customize customise plugins buttons tray clock" },
		{ page: "bar", anchor: "live-status", title: "Live status", words: "live status bar tray cpu memory network download upload battery volume timer meeting phone watch printer recording sharing notifications updates ring curve sparkline values" },
		{ page: "bar", anchor: "popup-motion", title: "Popup animation", words: "popup panel animation motion open liquid glass pop curtain speed" },
		{ page: "bar", anchor: "wallpaper-change", title: "Wallpaper transition", words: "wallpaper animation transition fade bloom change" },
		{ page: "bar", anchor: "wallpaper-backdrop", title: "Overview backdrop", words: "wallpaper overview backdrop blur dim workspaces" },
		{ page: "bar", anchor: "game-mode", title: "Game mode", words: "game mode gaming find mouse shake notifications quiet" },
		{ page: "tray", anchor: "trays", title: "App trays", words: "tray dock apps launcher edge new remove" },
		{ page: "tray", anchor: "tray-place", title: "Where the tray sits", words: "tray dock edge screen monitor position place left right top bottom" },
		{ page: "tray", anchor: "tray-reveal", title: "When the tray shows", words: "tray dock hide autohide hover click key always reserve" },
		{ page: "tray", anchor: "tray-look", title: "Tray look", words: "tray dock icons size magnify grow glass labels dots" },
		{ page: "tray", anchor: "tray-items", title: "What is in the tray", words: "tray dock apps commands plugins shell folder link add drag drop" },
		{ page: "sounds", anchor: "sound-pack", title: "Sound pack", words: "sound pack theme cosy cozy install zip" },
		{ page: "sounds", anchor: "sounds", title: "Sounds", words: "sound audio click volume mute quiet feedback do not disturb" },
		{ page: "sounds", anchor: "sounds-list", title: "Every sound", words: "sound notification usb drive display monitor bluetooth error battery charger lock workspace screenshot" },
		{ page: "colours", anchor: "colours-engine", title: "Colour engine", words: "colours colors palette wallust pshell engine wallpaper theme" },
		{ page: "colours", anchor: "colours-style", title: "Colour style", words: "colours colors palette style vivid muted pastel professional pro mono dark light mode" },
		{ page: "colours", anchor: "colours-tuning", title: "Colour tuning", words: "colours colors palette saturation brightness background depth tint grey gray contrast variety hue terminal ansi" },
		{ page: "lighting", anchor: "lighting", title: "Lighting", words: "lighting rgb openrgb led leds keyboard gpu fans argb wallpaper live screen ambient off dark" },
		{ page: "lighting", anchor: "lighting-live", title: "Live lighting", words: "live screen mirror ambient monitor fps frames smoothing openrgb effects screen copy" },
		{ page: "phone", anchor: "notification-style", title: "Notification look", words: "notifications toasts look style design card accent compact floating aussehen" },
		{ page: "phone", anchor: "notification-apps", title: "Notifications", words: "notifications programs apps mute hide off silence benachrichtigungen ausschalten" },
		{ page: "phone", anchor: "phone-apps", title: "Phone notifications", words: "phone handy notifications apps whatsapp mail mute hide off android benachrichtigungen" },
		{ page: "phone", anchor: "phone-pc-apps", title: "Notifications to the phone", words: "phone handy notifications programs apps mirror send mute off pc benachrichtigungen" },
		{ page: "browser", anchor: "browser-link", title: "Browser extension", words: "browser floorp firefox extension pshell xpi native host link install status" },
		{ page: "browser", anchor: "browser-look", title: "Browser look", words: "browser floorp theme css userchrome look layout install remove settle" },
		{ page: "browser", anchor: "browser-tabs", title: "Browser tabs", words: "browser floorp tabs rail sidebar vertical hover open icons top width recent pinned dock ctrl tab filter states leiste seitenleiste gerade fest" },
		{ page: "browser", anchor: "browser-envs", title: "Browser environments", words: "browser floorp live stage staging dev development environment groups colours colors umgebung gruppen" },
		{ page: "browser", anchor: "browser-navigation", title: "Browser navigation", words: "browser floorp hints keyboard peek spur columns links from outside" },
		{ page: "browser", anchor: "browser-cleanup", title: "Browser archive", words: "browser floorp archive old tabs cleanup untouched aufräumen archiv" },
		{ page: "browser", anchor: "browser-plugins", title: "Browser plugins", words: "browser floorp tabs launcher alt-tab workspaces menu newtab forms mail focus media privacy capture qtrack" },
		{ page: "browser", anchor: "browser-breaks", title: "Browser media in breaks", words: "browser media pause break stretch eye rest video music tabs" },
		{ page: "browser", anchor: "browser-focus", title: "Sites kept away", words: "browser focus block sites websites distraction" },
		{ page: "debug", anchor: "debug", title: "Debug options", words: "debug preview-render drm overlay planes scanout", take: ["debug"] }
	]

	// a page of the shell's own: no niri file behind it, nothing to undo
	readonly property bool shellPage: ["bar", "tray", "multicursor", "sounds", "colours", "lighting", "phone", "mouse", "hud", "apps", "browser"].includes(root.current)

	readonly property var results: {
		if (root.query === "") return [];
		const words = root.query.split(/\s+/);
		return root.index.filter(entry => {
			if (!root.pages.some(page => page.id === entry.page)) return false;
			if (entry.plugin && !Plugins.on(entry.plugin)) return false;
			const hay = `${entry.title} ${entry.words} ${root.pageOf(entry.page).label}`.toLowerCase();
			return words.every(word => hay.includes(word));
		}).slice(0, 9);
	}
	property int resultIndex: 0
	onResultsChanged: root.resultIndex = 0

	function pageOf(id) {
		return root.pages.find(page => page.id === id) ?? root.pages[0];
	}

	function go(id, anchor) {
		NiriSettings.anchor = "";
		const visited = Object.assign({}, root.visited);
		visited[id] = true;
		root.visited = visited;
		root.current = id;
		NiriSettings.page = id;
		if (anchor) Qt.callLater(() => {
			const item = pageRepeater.itemAt(root.pages.findIndex(page => page.id === id))?.item;
			if (item && item.reveal) item.reveal(anchor);
		});
	}

	function step(delta) {
		const at = root.pages.findIndex(page => page.id === root.current);
		root.go(root.pages[(at + delta + root.pages.length) % root.pages.length].id, "");
	}

	function openResult(entry) {
		if (!entry) return;
		search.text = "";
		root.go(entry.page, entry.anchor);
	}

	readonly property Item currentPage: pageRepeater.itemAt(root.pages.findIndex(page => page.id === root.current))?.item ?? null

	// `niri open <page>` while it is open goes to that page
	Connections {
		target: NiriSettings

		function onPageChanged() {
			if (root.shown && NiriSettings.page !== "" && NiriSettings.page !== root.current) root.go(NiriSettings.page, NiriSettings.anchor);
		}

		function onAnchorChanged() {
			if (root.shown && NiriSettings.anchor !== "" && NiriSettings.page === root.current) root.go(root.current, NiriSettings.anchor);
		}
	}

	// niri hands over its own shortcuts while key binds record keys
	ShortcutInhibitor {
		window: root
		enabled: root.shown && !!root.currentPage && !!root.currentPage.recording
	}

	Shortcut {
		sequence: "Ctrl+Z"
		enabled: root.shown && !root.shellPage && !(root.currentPage && root.currentPage.recording)
		onActivated: root.current === "keys" ? Keybinds.undo() : NiriSettings.undo()
	}

	Shortcut {
		sequence: "Ctrl+F"
		enabled: root.shown
		onActivated: search.focusInput()
	}

	Shortcut {
		sequences: ["Ctrl+PgDown", "Ctrl+Tab"]
		enabled: root.shown
		onActivated: root.step(1)
	}

	Shortcut {
		sequences: ["Ctrl+PgUp", "Ctrl+Shift+Tab", "Ctrl+Backtab"]
		enabled: root.shown
		onActivated: root.step(-1)
	}

	Rectangle {
		id: frame

		anchors.fill: parent
		color: Theme.base
		clip: true

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		RowLayout {
			anchors.fill: parent
			spacing: 0

			// ── pages ──────────────────────────────────────────────────
			Rectangle {
				Layout.preferredWidth: 262
				Layout.fillHeight: true
				color: Theme.layer1

				ColumnLayout {
					anchors.fill: parent
					anchors.margins: 18
					spacing: 14

					RowLayout {
						Layout.fillWidth: true
						spacing: 12

						Rectangle {
							id: badge

							Layout.preferredWidth: 44
							Layout.preferredHeight: 44
							radius: Theme.radius.large
							color: Theme.primaryContainer

							Glyph {
								anchors.centerIn: parent
								icon: "tune_variant"
								size: 22
								color: Theme.primary
								spin: NiriSettings.saving ? 8 : 0

								Behavior on spin {
									SpatialAnim {}
								}
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								Layout.fillWidth: true
								text: Words.of("settings.title", "Pshell settings")
								font.pixelSize: Theme.size.heading
								font.weight: Font.Bold
							}

							StyledText {
								Layout.fillWidth: true
								text: !NiriSettings.loaded ? "Reading the config…" : (NiriSettings.saving ? "Saving…" : (NiriSettings.adopted ? "Live – changes apply at once" : "Taking over your settings…"))
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
							}
						}
					}

					Field {
						id: search

						Layout.fillWidth: true
						icon: "magnify"
						placeholder: "Find a setting"
						onUpPressed: root.resultIndex = Math.max(0, root.resultIndex - 1)
						onDownPressed: root.resultIndex = Math.min(root.results.length - 1, root.resultIndex + 1)
						onAccepted: root.openResult(root.results[root.resultIndex])
						onEscapePressed: search.text = ""
					}

					Item {
						Layout.fillWidth: true
						Layout.fillHeight: true

						// the pages: closer together when the window is short, and
						// scrolled when even that is not enough – never under the box below
						Flickable {
							id: navFlick

							readonly property real tabHeight: Math.max(34, Math.min(44, (navFlick.height - (root.pages.length - 1) * 2) / Math.max(1, root.pages.length)))

							anchors.fill: parent
							contentHeight: nav.height
							clip: true
							boundsBehavior: Flickable.StopAtBounds
							interactive: navFlick.contentHeight > navFlick.height + 1
							ScrollBar.vertical: ThinScrollBar {}
							opacity: root.query === "" ? 1 : 0
							visible: opacity > 0.01
							scale: root.query === "" ? 1 : 0.97

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Rectangle {
								id: marker

								// asked again once the tabs are made (opened straight on a page)
								readonly property Item target: navRepeater.count >= 0 ? navRepeater.itemAt(root.pages.findIndex(page => page.id === root.current)) : null

								width: nav.width
								height: navFlick.tabHeight
								y: marker.target ? marker.target.y : 0

								// the picked page stays in sight
								onYChanged: {
									if (marker.y < navFlick.contentY) navFlick.contentY = marker.y;
									else if (marker.y + marker.height > navFlick.contentY + navFlick.height)
										navFlick.contentY = marker.y + marker.height - navFlick.height;
								}
								radius: Theme.radius.large
								color: Theme.primaryContainer

								Behavior on y {
									SpatialAnim {
										duration: Motion.medium
									}
								}

								Rectangle {
									x: 0
									anchors.verticalCenter: parent.verticalCenter
									width: 3
									height: 20
									radius: 1.5
									color: Theme.primary
								}
							}

							Column {
								id: nav

								width: navFlick.width - (navFlick.interactive ? 8 : 0)
								spacing: 2

								Repeater {
									id: navRepeater

									model: root.pages

									delegate: Clickable {
										id: tab

										required property var modelData
										required property int index
										readonly property bool picked: root.current === tab.modelData.id

										width: nav.width
										height: navFlick.tabHeight
										radius: Theme.radius.large
										pressedScale: 0.97
										onClicked: root.go(tab.modelData.id, "")

										RowLayout {
											anchors.fill: parent
											anchors.leftMargin: 14
											anchors.rightMargin: 12
											spacing: 12

											Glyph {
												icon: tab.modelData.icon
												size: 18
												color: tab.picked ? Theme.primary : Theme.textMuted
												scale: tab.picked ? 1.1 : 1

												Behavior on scale {
													SpatialAnim {
														duration: Motion.medium
													}
												}
											}

											StyledText {
												Layout.fillWidth: true
												text: tab.modelData.label
												tone: tab.picked ? Theme.primary : Theme.text
												font.weight: tab.picked ? Font.DemiBold : Font.Medium
											}

											StyledText {
												visible: tab.hovered && !tab.picked && tab.index < 9
												text: `^${tab.index + 1}`
												tone: Theme.textFaint
												font.pixelSize: Theme.size.tiny
											}
										}

										Shortcut {
											sequence: `Ctrl+${tab.index + 1}`
											enabled: root.shown && tab.index < 9
											onActivated: root.go(tab.modelData.id, "")
										}
									}
								}
							}
						}

						// what search found
						Column {
							anchors.fill: parent
							spacing: 2
							opacity: root.query === "" ? 0 : 1
							visible: opacity > 0.01

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}

							Repeater {
								model: root.results

								delegate: Clickable {
									id: hit

									required property var modelData
									required property int index
									readonly property bool picked: root.resultIndex === hit.index

									width: parent.width
									height: 52
									radius: Theme.radius.large
									color: hit.picked ? Theme.primaryContainer : "transparent"
									onClicked: root.openResult(hit.modelData)
									onPointed: root.resultIndex = hit.index

									RowLayout {
										anchors.fill: parent
										anchors.leftMargin: 12
										anchors.rightMargin: 12
										spacing: 10

										Glyph {
											icon: root.pageOf(hit.modelData.page).icon
											size: 16
											color: hit.picked ? Theme.primary : Theme.textMuted
										}

										ColumnLayout {
											Layout.fillWidth: true
											spacing: 0

											StyledText {
												Layout.fillWidth: true
												text: hit.modelData.title
												font.weight: Font.Medium
											}

											StyledText {
												Layout.fillWidth: true
												text: root.pageOf(hit.modelData.page).label
												tone: Theme.textSubtle
												font.pixelSize: Theme.size.small
											}
										}

										Glyph {
											visible: hit.picked
											icon: "keyboard_return"
											size: 14
											color: Theme.primary
										}
									}
								}
							}

							EmptyState {
								width: parent.width
								visible: root.results.length === 0
								icon: "magnify"
								title: "Nothing fits"
								subtitle: "Try what it does: gaps, blur, tap"
							}
						}
					}

					// where it lives, and the way back
					Rectangle {
						Layout.fillWidth: true
						implicitHeight: where.implicitHeight + 24
						radius: Theme.radius.large
						color: Theme.layer2

						ColumnLayout {
							id: where

							anchors.left: parent.left
							anchors.right: parent.right
							anchors.top: parent.top
							anchors.margins: 12
							spacing: 6

							RowLayout {
								spacing: 8

								Glyph {
									icon: NiriSettings.adopted ? "check_circle" : "progress_clock"
									size: 15
									color: NiriSettings.adopted ? Theme.success : Theme.textMuted
								}

								StyledText {
									text: ({ keys: "keybinds.kdl", displays: "display-profile.kdl", multicursor: "multicursor.json", sounds: "sounds.json", lighting: "lighting.json", mouse: "mouse.json" })[root.current] ?? "settings.kdl"
									font.weight: Font.DemiBold
									font.pixelSize: Theme.size.label
								}
							}

							StyledText {
								Layout.fillWidth: true
								visible: !root.shellPage
								text: "niri takes every change at once. What it would not accept is never written."
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
								wrapMode: Text.WordWrap
							}

							RowLayout {
								Layout.topMargin: 2
								spacing: 2

								TextButton {
									implicitHeight: 28
									variant: "ghost"
									icon: "undo"
									text: "Undo"
									visible: !root.shellPage
									enabled: root.current === "keys" ? Keybinds.history.length > 0 : NiriSettings.history.length > 0
									onActivated: root.current === "keys" ? Keybinds.undo() : NiriSettings.undo()
								}

								TextButton {
									implicitHeight: 28
									variant: "ghost"
									icon: "tray_arrow_down"
									text: "Export"
									visible: root.current !== "bar" && root.current !== "tray" && root.current !== "sounds" && root.current !== "lighting" && root.current !== "colours" && root.current !== "phone" && root.current !== "mouse" && root.current !== "hud" && root.current !== "apps"
									enabled: NiriSettings.loaded
									onActivated: exportSheet.show(root.current)
								}
							}
						}
					}
				}
			}

			// ── the page ───────────────────────────────────────────────
			Item {
				id: stage

				Layout.fillWidth: true
				Layout.fillHeight: true

				Repeater {
					id: pageRepeater

					model: root.pages

					delegate: Loader {
						id: holder

						required property var modelData
						required property int index
						readonly property bool picked: root.current === holder.modelData.id
						readonly property int order: holder.index - root.pages.findIndex(page => page.id === root.current)

						anchors.fill: parent
						active: !!root.visited[holder.modelData.id]
						asynchronous: false
						visible: opacity > 0.01
						opacity: holder.picked ? 1 : 0
						enabled: holder.picked
						z: holder.picked ? 1 : 0
						transform: Translate {
							y: holder.picked ? 0 : (holder.order > 0 ? 36 : -36)

							Behavior on y {
								SpatialAnim {
									duration: Motion.long
								}
							}
						}
						sourceComponent: {
							switch (holder.modelData.id) {
							case "displays": return displaysPage;
							case "layout": return layoutPage;
							case "looks": return looksPage;
							case "input": return inputPage;
							case "keys": return keysPage;
							case "devices": return devicesPage;
							case "mouse": return mousePage;
							case "hud": return hudPage;
							case "keyboard": return keyboardPage;
							case "apex": return apexPage;
							case "ultimate": return ultimatePage;
							case "headset": return headsetPage;
						case "fingerprint": return fingerprintPage;
						case "btadapter": return btAdapterPage;
						case "webcam": return webcamPage;
						case "hpcamera": return hpCameraPage;
						case "as50": return as50Page;
						case "amazfit": return amazfitPage;
							case "multicursor": return multicursorPage;
							case "rules": return rulesPage;
							case "workspaces": return workspacesPage;
							case "overview": return overviewPage;
							case "system": return systemPage;
							case "apps": return defaultAppsPage;
							case "browser": return browserPage;
							case "bar": return barPage;
						case "tray": return trayPage;
							case "sounds": return soundsPage;
							case "colours": return coloursPage;
							case "lighting": return lightingPage;
							case "phone": return phonePage;
							default: return debugPage;
							}
						}
						onLoaded: if (holder.item && "active" in holder.item) holder.item.active = Qt.binding(() => holder.picked && root.shown)

						Behavior on opacity {
							Anim {
								duration: holder.picked ? Motion.medium : Motion.short
							}
						}
					}
				}
			}
		}

		ExportSheet {
			id: exportSheet

			anchors.fill: parent
			pages: root.pages
			index: root.index
		}

		// what the last change did, with a way back
		Rectangle {
			id: note

			property bool up: false
			property string text: ""
			property bool keys: false
			property bool undo: true

			anchors.horizontalCenter: parent.horizontalCenter
			anchors.horizontalCenterOffset: 131
			y: parent.height - (note.up ? height + 22 : 0)
			opacity: note.up ? 1 : 0
			visible: opacity > 0.01
			width: noteRow.implicitWidth + 28
			height: 46
			radius: height / 2
			color: Theme.layer3
			border.width: 1
			border.color: Theme.outline

			Behavior on y {
				SpatialAnim {}
			}
			Behavior on opacity {
				Anim {}
			}

			Connections {
				target: NiriSettings

				function onSavedCountChanged() {
					note.text = NiriSettings.savedNote;
					note.keys = false;
					note.undo = true;
					note.up = true;
					hide.restart();
				}
				function onErrorChanged() {
					if (NiriSettings.error !== "") note.up = false;
				}
				function onExported(file) {
					root.exportError = "";
					note.text = file === "" ? "Copied" : `Exported to ${file.replace(Paths.home, "~")}`;
					note.undo = false;
					note.up = true;
					hide.restart();
				}
				function onExportFailed(message) {
					note.up = false;
					root.exportError = message;
				}
			}

			Connections {
				target: Keybinds

				function onSavedCountChanged() {
					note.text = Keybinds.savedNote;
					note.keys = true;
					note.undo = true;
					note.up = true;
					hide.restart();
				}
				function onErrorChanged() {
					if (Keybinds.error !== "") note.up = false;
				}
			}

			Timer {
				id: hide

				interval: 3600
				onTriggered: note.up = false
			}

			RowLayout {
				id: noteRow

				anchors.centerIn: parent
				spacing: 10

				Glyph {
					icon: "check_circle"
					size: 17
					color: Theme.success
				}

				StyledText {
					text: note.text
					font.weight: Font.Medium
				}

				TextButton {
					visible: note.undo && (note.keys ? Keybinds.history.length > 0 : NiriSettings.history.length > 0)
					implicitHeight: 30
					variant: "ghost"
					icon: "undo"
					text: "Undo"
					onActivated: {
						if (note.keys) Keybinds.undo();
						else NiriSettings.undo();
						hide.restart();
					}
				}
			}
		}

		// what niri said no to
		Rectangle {
			id: failure

			readonly property bool refused: NiriSettings.error !== "" || Keybinds.error !== ""
			readonly property string message: NiriSettings.error !== "" ? NiriSettings.error : (Keybinds.error !== "" ? Keybinds.error : root.exportError)
			readonly property bool up: failure.message !== ""

			anchors.horizontalCenter: parent.horizontalCenter
			anchors.horizontalCenterOffset: 131
			width: Math.min(parent.width - 340, 720)
			y: parent.height - (failure.up ? height + 22 : 0)
			height: failureColumn.implicitHeight + 24
			opacity: failure.up ? 1 : 0
			visible: opacity > 0.01
			radius: Theme.radius.large
			color: Theme.dangerContainer
			border.width: 1
			border.color: Qt.alpha(Theme.danger, 0.4)

			Behavior on y {
				SpatialAnim {}
			}
			Behavior on opacity {
				Anim {}
			}

			RowLayout {
				anchors.fill: parent
				anchors.margins: 12
				spacing: 12

				Glyph {
					Layout.alignment: Qt.AlignTop
					icon: "alert_circle"
					size: 20
					color: Theme.danger
				}

				ColumnLayout {
					id: failureColumn

					Layout.fillWidth: true
					spacing: 4

					StyledText {
						Layout.fillWidth: true
						text: failure.refused ? "niri said no – the last working settings are back" : "Could not export"
						tone: Theme.danger
						font.weight: Font.DemiBold
					}

					StyledText {
						Layout.fillWidth: true
						text: failure.message
						tone: Theme.text
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.small
						wrapMode: Text.WrapAnywhere
					}
				}

				IconButton {
					Layout.alignment: Qt.AlignTop
					icon: "close"
					implicitWidth: 28
					implicitHeight: 28
					onClicked: {
						NiriSettings.error = "";
						Keybinds.error = "";
						root.exportError = "";
					}
				}
			}
		}
	}

	Component {
		id: displaysPage

		DisplaysPage {}
	}

	Component {
		id: layoutPage

		LayoutPage {}
	}

	Component {
		id: looksPage

		LooksPage {}
	}

	Component {
		id: inputPage

		InputPage {}
	}

	Component {
		id: keysPage

		KeysPage {}
	}

	Component {
		id: devicesPage

		DevicesPage {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: mousePage

		MousePage {}
	}

	Component {
		id: hudPage

		HudPage {}
	}

	Component {
		id: keyboardPage

		KeyboardPage {}
	}

	Component {
		id: apexPage

		ApexPage {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: headsetPage

		HeadsetPage {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: fingerprintPage

		FingerprintPage {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: btAdapterPage

		BtAdapterPage {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: hpCameraPage

		HpCameraPage {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: webcamPage

		WebcamPage {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: amazfitPage

		AmazfitPage {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: as50Page

		As50Page {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: ultimatePage

		UltimatePage {
			onOpen: page => root.go(page, "")
		}
	}

	Component {
		id: multicursorPage

		MulticursorPage {}
	}

	Component {
		id: rulesPage

		RulesPage {}
	}

	Component {
		id: workspacesPage

		WorkspacesPage {}
	}

	Component {
		id: overviewPage

		OverviewPage {}
	}

	Component {
		id: systemPage

		SystemPage {}
	}

	Component {
		id: defaultAppsPage

		DefaultAppsPage {}
	}

	Component {
		id: barPage

		BarPage {}
	}

	Component {
		id: trayPage

		TrayPage {}
	}

	Component {
		id: soundsPage

		SoundsPage {}
	}

	Component {
		id: coloursPage

		ColoursPage {}
	}

	Component {
		id: lightingPage

		LightingPage {}
	}

	Component {
		id: phonePage

		PhonePage {}
	}

	Component {
		id: debugPage

		DebugPage {}
	}

	// Settings › Browser (docs/browser.md): the link, the look, the plugins.
	// Inline: a new page type would wait for the shell's next start.
	Component {
		id: browserPage

		SettingsPage {
			id: browser

			readonly property string scripts: `${Quickshell.shellDir}/scripts`
			readonly property var link: {
				const sources = Object.keys(WebLink.links);
				return sources.length > 0 ? WebLink.links[sources[sources.length - 1]] : null;
			}
			readonly property var plugins: ["browser-link", "browser-launcher", "browser-switcher", "browser-workspaces", "browser-menu", "browser-newtab", "browser-forms", "browser-mail", "browser-focus", "browser-media", "browser-privacy", "browser-capture", "browser-qtrack"]
			// [{ ok, text }] from browser_host.py status and floorp_theme.py status
			property var hostLines: []
			property var themeLines: []
			property string packed: ""
			property bool mapExists: false
			readonly property bool canFocus: typeof WebPage.setFocusSites === "function"
			readonly property var focusSites: browser.canFocus ? (WebPage.focusSites || []) : []

			function home(path) {
				return String(path).replace(Quickshell.env("HOME"), "~");
			}

			function refresh() {
				hostStatus.running = true;
				themeStatus.running = true;
				mapCheck.running = true;
			}

			function run(command, done) {
				if (job.running) return;
				job.done = done || null;
				job.command = command;
				job.running = true;
			}

			title: "Browser"
			onActiveChanged: if (browser.active) browser.refresh()
			Component.onCompleted: browser.refresh()

			Process {
				id: hostStatus

				command: ["python3", `${browser.scripts}/browser_host.py`, "status"]
				stdout: StdioCollector {
					onStreamFinished: browser.hostLines = text.split("\n").filter(line => line.trim() !== "").map(line => ({ ok: line.startsWith("ok"), text: browser.home(line.replace(/^(ok|missing)\s+/, "").replace(/\s+\(.*\)$/, "")) }))
				}
			}

			Process {
				id: themeStatus

				command: ["python3", `${browser.scripts}/floorp_theme.py`, "status"]
				stdout: StdioCollector {
					onStreamFinished: browser.themeLines = text.split("\n").filter(line => line.trim() !== "").map(line => ({ ok: /: installed/.test(line), text: browser.home(line) }))
				}
			}

			Process {
				id: mapCheck

				command: ["test", "-f", `${Quickshell.shellDir}/core/views/settings/browser/WorkspaceMap.qml`]
				onExited: code => browser.mapExists = code === 0
			}

			Process {
				id: job

				property var done: null
				stdout: StdioCollector {
					id: jobOut
				}
				stderr: StdioCollector {
					id: jobErr
				}
				onExited: code => {
					if (job.done) job.done(code, jobOut.text);
					if (code !== 0) Notifs.pushInternal("error", "Browser", String(jobErr.text || "").trim().split("\n").pop() || `exit ${code}`, { icon: "web" });
					browser.refresh();
				}
			}

			SettingCard {
				anchor: "browser-link"
				title: browser.link ? `${browser.link.browser || "Browser"} ${browser.link.version}`.trim() : "Not connected"
				subtitle: WebLink.connected ? `${WebLink.tabs.length} tabs` : ""
				icon: "web"

				trailing: TextButton {
					variant: "filled"
					icon: "puzzle"
					text: "Install extension"
					busy: job.running
					onActivated: browser.run(["python3", `${browser.scripts}/browser_host.py`, "install"], (code, out) => {
						const line = String(out).split("\n").find(each => each.startsWith("extension: "));
						if (code === 0 && line) browser.packed = line.slice(11).trim();
					})
				}

				Repeater {
					model: browser.hostLines

					delegate: RowLayout {
						required property var modelData

						Layout.fillWidth: true
						spacing: 10

						Glyph {
							icon: modelData.ok ? "check_circle_outline" : "close_circle_outline"
							size: 16
							color: modelData.ok ? Theme.success : Theme.textSubtle
						}

						StyledText {
							Layout.fillWidth: true
							text: modelData.text
							tone: modelData.ok ? Theme.text : Theme.textMuted
							font.pixelSize: Theme.size.label
							elide: Text.ElideMiddle
						}
					}
				}

				RowLayout {
					Layout.fillWidth: true
					visible: browser.packed !== ""
					spacing: 10

					Glyph {
						icon: "package_variant_closed"
						size: 16
						color: Theme.primary
					}

					StyledText {
						Layout.fillWidth: true
						text: browser.home(browser.packed)
						font.pixelSize: Theme.size.label
						font.weight: Font.Medium
						elide: Text.ElideMiddle
					}

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						iconSize: 16
						icon: "content_copy"
						onClicked: Quickshell.execDetached(["wl-copy", "--", browser.packed])
					}
				}
			}

			SettingCard {
				anchor: "browser-look"
				title: "Look"
				icon: "palette_outline"

				trailing: RowLayout {
					spacing: 4

					TextButton {
						variant: "ghost"
						icon: "delete_outline"
						text: "Remove"
						confirm: true
						enabled: !job.running && browser.themeLines.some(line => line.ok)
						onActivated: browser.run(["python3", `${browser.scripts}/floorp_theme.py`, "remove"])
					}

					TextButton {
						variant: "ghost"
						icon: "check_all"
						text: "Settle"
						enabled: !job.running && browser.themeLines.some(line => line.ok)
						onActivated: browser.run(["python3", `${browser.scripts}/floorp_theme.py`, "settle"])
					}

					TextButton {
						variant: "filled"
						icon: "download"
						text: "Install theme"
						busy: job.running
						onActivated: browser.run(["python3", `${browser.scripts}/floorp_theme.py`, "install"])
					}
				}

				Repeater {
					model: browser.themeLines

					delegate: RowLayout {
						required property var modelData

						Layout.fillWidth: true
						spacing: 10

						Glyph {
							icon: modelData.ok ? "check_circle_outline" : "circle_outline"
							size: 16
							color: modelData.ok ? Theme.success : Theme.textSubtle
						}

						StyledText {
							Layout.fillWidth: true
							text: modelData.text
							tone: modelData.ok ? Theme.text : Theme.textMuted
							font.pixelSize: Theme.size.label
							elide: Text.ElideMiddle
						}
					}
				}
			}

			SettingCard {
				anchor: "browser-tabs"
				title: "Tabs"
				icon: "tab"
				visible: Plugins.on("browser-link")

				Segmented {
					Layout.fillWidth: true
					options: [
						{ value: "hover", label: "Hover", icon: "cursor_default_outline" },
						{ value: "open", label: "Open", icon: "dock_left" },
						{ value: "icons", label: "Icons", icon: "view_sequential_outline" },
						{ value: "top", label: "Top", icon: "dock_top" }
					]
					current: WebPage.rail.style
					onSelected: value => WebPage.setRail({ style: value })
				}

				ValueSlider {
					visible: ["hover", "open"].includes(WebPage.rail.style)
					from: 200
					to: 480
					step: 10
					icon: "arrow_expand_horizontal"
					label: "Width"
					unit: " px"
					value: WebPage.rail.width
					onMoved: v => WebPage.setRail({ width: v })
				}

				FlagRow {
					title: "Recent"
					icon: "history"
					checked: WebPage.tabs.recent.on
					onToggled: on => WebPage.setTabs({ recent: { on: on } })
				}

				ValueSlider {
					visible: WebPage.tabs.recent.on
					from: 5
					to: 15
					step: 1
					icon: "timer_outline"
					label: "Recent window"
					unit: " min"
					value: WebPage.tabs.recent.minutes
					onMoved: v => WebPage.setTabs({ recent: { minutes: v } })
				}

				FlagRow {
					title: "Pinned at the foot"
					icon: "pin_outline"
					checked: WebPage.tabs.dock
					onToggled: on => WebPage.setTabs({ dock: on })
				}

				FlagRow {
					title: "Group by site"
					icon: "web"
					checked: WebPage.tabs.bySite
					onToggled: on => WebPage.setTabs({ bySite: on })
				}

				FlagRow {
					title: "Ctrl+Tab by use"
					icon: "keyboard_tab"
					checked: WebPage.tabs.ctrlTab
					onToggled: on => WebPage.setTabs({ ctrlTab: on })
				}

				FlagRow {
					title: "Typing filters the rail"
					icon: "filter_outline"
					checked: WebPage.tabs.filter
					onToggled: on => WebPage.setTabs({ filter: on })
				}

				FlagRow {
					title: "States on icons"
					icon: "tab"
					checked: WebPage.tabs.states
					onToggled: on => WebPage.setTabs({ states: on })
				}

				FlagRow {
					title: "Ctrl+K opens the launcher"
					icon: "magnify"
					checked: WebPage.tabs.launcherKey
					onToggled: on => WebPage.setTabs({ launcherKey: on })
				}
			}

			SettingCard {
				anchor: "browser-envs"
				title: "Environments"
				icon: "layers_outline"
				visible: Plugins.on("browser-link")

				FlagRow {
					title: "Colours"
					icon: "palette_outline"
					checked: WebPage.tabs.envs.on
					onToggled: on => WebPage.setTabs({ envs: { on: on } })
				}

				FlagRow {
					visible: WebPage.tabs.envs.on
					title: "Group"
					icon: "tab"
					checked: WebPage.tabs.envs.group
					onToggled: on => WebPage.setTabs({ envs: { group: on } })
				}

				Repeater {
					model: WebPage.tabs.envs.on ? WebPage.tabs.envs.list : []

					delegate: ColumnLayout {
						id: envRow

						required property var modelData
						required property int index
						readonly property string savedPatterns: (envRow.modelData.patterns || []).join(", ")

						Layout.fillWidth: true
						Layout.topMargin: envRow.index > 0 ? 6 : 0
						spacing: 4

						RowLayout {
							Layout.fillWidth: true
							spacing: 6

							ColorWell {
								size: 20
								alpha: false
								showHex: false
								value: envRow.modelData.color
								onPicked: css => WebPage.changeEnv(envRow.modelData.id, { color: String(css).slice(0, 7) })
							}

							Field {
								id: nameField

								Layout.preferredWidth: 160
								clearable: false
								placeholder: "Name"
								text: envRow.modelData.name
								function commit() {
									if (nameField.text.trim() !== "" && nameField.text.trim() !== envRow.modelData.name) WebPage.changeEnv(envRow.modelData.id, { name: nameField.text.trim() });
									nameField.text = Qt.binding(() => envRow.modelData.name);
								}
								onAccepted: nameField.commit()
								onFocusedChanged: if (!nameField.focused) nameField.commit()
							}

							Item {
								Layout.fillWidth: true
							}

							TextButton {
								implicitHeight: 28
								variant: envRow.modelData.cycle ? "tonal" : "ghost"
								text: "Alt+E"
								onClicked: WebPage.changeEnv(envRow.modelData.id, { cycle: !envRow.modelData.cycle })
							}

							IconButton {
								implicitWidth: 28
								implicitHeight: 28
								icon: "chevron_up"
								enabled: envRow.index > 0
								opacity: enabled ? 1 : 0.35
								onClicked: WebPage.moveEnv(envRow.modelData.id, -1)
							}

							IconButton {
								implicitWidth: 28
								implicitHeight: 28
								icon: "chevron_down"
								enabled: envRow.index < WebPage.tabs.envs.list.length - 1
								opacity: enabled ? 1 : 0.35
								onClicked: WebPage.moveEnv(envRow.modelData.id, 1)
							}

							IconButton {
								implicitWidth: 28
								implicitHeight: 28
								icon: "delete_outline"
								onClicked: WebPage.removeEnv(envRow.modelData.id)
							}
						}

						Field {
							id: envField

							Layout.fillWidth: true
							placeholder: "example.com, *.example.com, /regex/"
							text: envRow.savedPatterns
							function commit() {
								if (envField.text.trim() !== envRow.savedPatterns) WebPage.changeEnv(envRow.modelData.id, { patterns: envField.text });
								envField.text = Qt.binding(() => envRow.savedPatterns);
							}
							onAccepted: envField.commit()
							onFocusedChanged: if (!envField.focused) envField.commit()
						}
					}
				}

				TextButton {
					visible: WebPage.tabs.envs.on && WebPage.tabs.envs.list.length < 12
					implicitHeight: 30
					variant: "ghost"
					icon: "plus"
					text: "Add group"
					onClicked: WebPage.addEnv()
				}
			}

			SettingCard {
				anchor: "browser-navigation"
				title: "Navigation"
				icon: "cursor_default_click_outline"
				visible: Plugins.on("browser-link")

				FlagRow {
					title: "Hints"
					icon: "keyboard_outline"
					checked: WebPage.tabs.hints.on
					onToggled: on => WebPage.setTabs({ hints: { on: on } })
				}

				RowLayout {
					visible: WebPage.tabs.hints.on
					Layout.fillWidth: true
					spacing: 12

					StyledText {
						text: "Hint keys"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.body
					}

					Field {
						id: hintField

						Layout.fillWidth: true
						text: WebPage.tabs.hints.chars
						clearable: false
						function commit() {
							if (hintField.text.trim() !== WebPage.tabs.hints.chars) WebPage.setTabs({ hints: { chars: hintField.text.trim() } });
							hintField.text = Qt.binding(() => WebPage.tabs.hints.chars);
						}
						onAccepted: hintField.commit()
						onFocusedChanged: if (!hintField.focused) hintField.commit()
					}
				}

				FlagRow {
					title: "Peek"
					icon: "eye_outline"
					checked: WebPage.tabs.peek.on
					onToggled: on => WebPage.setTabs({ peek: { on: on } })
				}

				RowLayout {
					visible: WebPage.tabs.peek.on
					Layout.fillWidth: true
					spacing: 12

					StyledText {
						text: "Links from the shell"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.body
					}

					Segmented {
						Layout.fillWidth: true
						options: [
							{ value: "peek", label: "Peek", icon: "eye_outline" },
							{ value: "tab", label: "Tab", icon: "tab" }
						]
						current: WebPage.tabs.peek.external
						onSelected: value => WebPage.setTabs({ peek: { external: value } })
					}
				}

				FlagRow {
					title: "Spur"
					icon: "view_column_outline"
					checked: WebPage.tabs.spur.on
					onToggled: on => WebPage.setTabs({ spur: { on: on } })
				}

				ValueSlider {
					visible: WebPage.tabs.spur.on
					from: 2
					to: 4
					step: 1
					icon: "view_column_outline"
					label: "Columns"
					value: WebPage.tabs.spur.columns
					onMoved: v => WebPage.setTabs({ spur: { columns: v } })
				}
			}

			SettingCard {
				anchor: "browser-cleanup"
				title: "Archive"
				subtitle: WebPage.archive.length > 0 ? `${WebPage.archive.length} tabs` : ""
				icon: "archive_outline"
				visible: Plugins.on("browser-link")

				FlagRow {
					title: "Offer to archive old tabs"
					icon: "archive_outline"
					checked: WebPage.tabs.archive.on
					onToggled: on => WebPage.setTabs({ archive: { on: on } })
				}

				ValueSlider {
					visible: WebPage.tabs.archive.on
					from: 6
					to: 168
					step: 6
					icon: "timer_outline"
					label: "Untouched for"
					unit: " h"
					value: WebPage.tabs.archive.after
					onMoved: v => WebPage.setTabs({ archive: { after: v } })
				}

				ValueSlider {
					from: 1
					to: 365
					step: 1
					icon: "calendar_outline"
					label: "Keep archive"
					unit: " days"
					value: WebPage.tabs.archive.keep
					onMoved: v => WebPage.setTabs({ archive: { keep: v } })
				}
			}

			SettingCard {
				anchor: "browser-plugins"
				title: "In the shell"
				icon: "puzzle"

				Repeater {
					model: browser.plugins

					delegate: FlagRow {
						required property string modelData

						title: Plugins.byId[modelData]?.name ?? modelData
						icon: Plugins.byId[modelData]?.icon ?? ""
						enabled: modelData === "browser-link" || Plugins.on("browser-link")
						opacity: enabled ? 1 : 0.5
						checked: Plugins.wanted(modelData)
						onToggled: on => Plugins.set(modelData, on)
					}
				}
			}

			SettingCard {
				anchor: "browser-breaks"
				title: "Breaks"
				icon: "coffee_outline"
				visible: Plugins.on("browser-media")

				FlagRow {
					title: "Pause what plays in the browser during a break"
					checked: Breaks.pauseBrowser
					onToggled: on => Breaks.setPauseBrowser(on)
				}
			}

			SettingCard {
				anchor: "browser-workspaces"
				title: "Workspaces"
				icon: "monitor_dashboard"
				visible: Plugins.on("browser-workspaces") && browser.mapExists

				Loader {
					Layout.fillWidth: true
					active: browser.mapExists
					source: browser.mapExists ? Qt.resolvedUrl("browser/WorkspaceMap.qml") : ""
				}
			}

			SettingCard {
				anchor: "browser-focus"
				title: "Sites kept away"
				subtitle: browser.focusSites.length > 0 ? `${browser.focusSites.length} sites` : ""
				icon: "block_helper"
				visible: Plugins.on("browser-focus") && browser.canFocus

				Repeater {
					model: browser.focusSites

					delegate: RowLayout {
						required property var modelData
						readonly property string host: typeof modelData === "string" ? modelData : String(modelData?.host ?? "")

						Layout.fillWidth: true
						spacing: 10

						Glyph {
							icon: "web"
							size: 16
							color: Theme.textMuted
						}

						StyledText {
							Layout.fillWidth: true
							text: parent.host
							font.pixelSize: Theme.size.body
							elide: Text.ElideRight
						}

						IconButton {
							implicitWidth: 28
							implicitHeight: 28
							iconSize: 16
							icon: "close"
							onClicked: WebPage.setFocusSites(browser.focusSites.filter(site => site !== parent.modelData))
						}
					}
				}

				Field {
					id: siteField

					Layout.fillWidth: true
					icon: "plus"
					placeholder: "example.com"
					onAccepted: {
						const host = siteField.text.trim().toLowerCase().replace(/^[a-z]+:\/\//, "").replace(/\/.*$/, "").replace(/^www\./, "");
						if (host === "") return;
						const sample = browser.focusSites[0];
						const entry = sample !== undefined && typeof sample !== "string" ? Object.assign({}, sample, { host: host }) : host;
						if (!browser.focusSites.some(site => (typeof site === "string" ? site : site?.host) === host)) WebPage.setFocusSites(browser.focusSites.concat([entry]));
						siteField.text = "";
					}
				}
			}
		}
	}
}
