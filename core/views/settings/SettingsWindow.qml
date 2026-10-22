pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
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
		root.go(NiriSettings.page || root.current || "displays", "");
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
		{ id: "keyboard", label: "Keyboard", icon: "keyboard_settings", hint: "Special keys, backlight, Fn keys", plugin: "keyboard" },
		{ id: "apex", label: "Apex Pro", icon: "keyboard_variant", hint: "Actuation, Rapid Trigger, keys, OLED", plugin: "apex" },
		{ id: "multicursor", label: "Multicursor", icon: "cursor_text", hint: "Lines and cursors in every text field", plugin: "multicursor" },
		{ id: "rules", label: "Window rules", icon: "application_cog_outline", hint: "Per app: size, place, look" },
		{ id: "workspaces", label: "Workspaces", icon: "view_grid_outline", hint: "Named workspaces" },
		{ id: "overview", label: "Overview & gestures", icon: "gesture_swipe", hint: "Overview, hot corners, Alt-Tab" },
		{ id: "system", label: "System", icon: "cog_outline", hint: "Startup, environment, screenshots, blur" },
		{ id: "bar", label: "Desktop", icon: "dock_window", hint: "Bar, wallpaper, game mode", plugin: "bar" },
		{ id: "sounds", label: "Sounds", icon: "volume_high", hint: "Clicks, notifications, devices", plugin: "sounds" },
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
		{ page: "input", anchor: "mod", title: "Mod key", words: "mod-key mod-key-nested super alt", take: ["input/mod-key", "input/mod-key-nested"] },
		{ page: "input", anchor: "input-more", title: "Power key, workspace back and forth, cursor", words: "disable-power-key-handling workspace-auto-back-and-forth hide-when-typing hide-after-inactive-ms cursor", take: ["input/disable-power-key-handling", "input/workspace-auto-back-and-forth", "cursor/hide-when-typing", "cursor/hide-after-inactive-ms"] },
		{ page: "keys", anchor: "binds", title: "Key binds", words: "keys shortcuts binds hotkeys", take: ["@binds"] },
		{ page: "keys", anchor: "switches", title: "Lid and tablet mode", words: "switch-events lid-close lid-open tablet-mode", take: ["switch-events"] },
		{ page: "devices", anchor: "devices-list", title: "Connected devices", words: "hid usb bluetooth device mouse keyboard receiver unknown reverse engineer claude" },
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
		{ page: "mouse", anchor: "mouse-buttons", title: "Mouse buttons and gestures", words: "logitech mx master button remap gesture swipe thumb wheel per app solaar rule action ring", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-rules", title: "Mouse rules", words: "rule editor condition modifier ctrl shift app hold double click solaar", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-pointer", title: "Mouse DPI", words: "dpi speed sensitivity pointer precision sniper shift", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-scroll", title: "Mouse wheel", words: "smartshift ratchet free spin torque wheel natural scrolling hires thumb wheel", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-haptics", title: "Mouse haptics", words: "haptic vibration feedback strength waveform pulse", plugin: "mouse" },
		{ page: "mouse", anchor: "mouse-force", title: "Haptic sense panel", words: "force sensing button pressure panel thumb", plugin: "mouse" },
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
		{ page: "bar", anchor: "bar-items", title: "Bar items", words: "bar panel widgets order drag customize customise plugins buttons tray clock" },
		{ page: "bar", anchor: "popup-motion", title: "Popup animation", words: "popup panel animation motion open liquid glass pop curtain speed" },
		{ page: "bar", anchor: "wallpaper-change", title: "Wallpaper transition", words: "wallpaper animation transition fade bloom change" },
		{ page: "bar", anchor: "wallpaper-backdrop", title: "Overview backdrop", words: "wallpaper overview backdrop blur dim workspaces" },
		{ page: "bar", anchor: "game-mode", title: "Game mode", words: "game mode gaming find mouse shake notifications quiet" },
		{ page: "sounds", anchor: "sound-pack", title: "Sound pack", words: "sound pack theme cosy cozy install zip" },
		{ page: "sounds", anchor: "sounds", title: "Sounds", words: "sound audio click volume mute quiet feedback do not disturb" },
		{ page: "sounds", anchor: "sounds-list", title: "Every sound", words: "sound notification usb drive display monitor bluetooth error battery charger lock workspace screenshot" },
		{ page: "lighting", anchor: "lighting", title: "Lighting", words: "lighting rgb openrgb led leds keyboard gpu fans argb wallpaper live screen ambient off dark" },
		{ page: "lighting", anchor: "lighting-live", title: "Live lighting", words: "live screen mirror ambient monitor fps frames smoothing openrgb effects screen copy" },
		{ page: "phone", anchor: "notification-apps", title: "Notifications", words: "notifications programs apps mute hide off silence benachrichtigungen ausschalten" },
		{ page: "phone", anchor: "phone-apps", title: "Phone notifications", words: "phone handy notifications apps whatsapp mail mute hide off android benachrichtigungen" },
		{ page: "phone", anchor: "phone-pc-apps", title: "Notifications to the phone", words: "phone handy notifications programs apps mirror send mute off pc benachrichtigungen" },
		{ page: "debug", anchor: "debug", title: "Debug options", words: "debug preview-render drm overlay planes scanout", take: ["debug"] }
	]

	// a page of the shell's own: no niri file behind it, nothing to undo
	readonly property bool shellPage: ["bar", "multicursor", "sounds", "lighting", "phone", "mouse"].includes(root.current)

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
			if (root.shown && NiriSettings.page !== "" && NiriSettings.page !== root.current) root.go(NiriSettings.page, "");
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

						// the pages
						Item {
							anchors.fill: parent
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

								readonly property Item target: navRepeater.itemAt(root.pages.findIndex(page => page.id === root.current))

								width: parent.width
								height: 44
								y: marker.target ? marker.target.y : 0
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

								width: parent.width
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
										height: 44
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
									visible: root.current !== "bar" && root.current !== "sounds" && root.current !== "lighting" && root.current !== "phone" && root.current !== "mouse"
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
							case "keyboard": return keyboardPage;
							case "apex": return apexPage;
							case "multicursor": return multicursorPage;
							case "rules": return rulesPage;
							case "workspaces": return workspacesPage;
							case "overview": return overviewPage;
							case "system": return systemPage;
							case "bar": return barPage;
							case "sounds": return soundsPage;
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
		id: barPage

		BarPage {}
	}

	Component {
		id: soundsPage

		SoundsPage {}
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
}
