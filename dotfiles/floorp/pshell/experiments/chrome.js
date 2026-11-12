/* The Pshell extension's part in the browser window itself (an experiment API,
 * allowed while extensions.experiments.enabled is true – floorp_theme.py sets
 * it). docs/browser.md, "Tabs and pages".
 *
 * This file is the API the extension sees (schema.json); the work is done by
 * the parts in experiments/parts/, loaded here into one shared scope:
 *
 *   base     windows, the settings, events to the extension, the page script
 *   rail     the rail's style and width, closing when the pointer leaves
 *   env      Live, Stage, Dev: colour, groups, the frame, Alt+E
 *   marks    states on the icon: a count from the title, a draft
 *   recent   "Recent": the tabs of the last minutes at the top of the rail, Alt+1…9
 *   dock     "Pinned": the pinned tabs at the foot of the rail
 *   filter   typing over the rail filters it
 *   domains  tabs of one site in a group of their own
 *   keys     Ctrl+K, Ctrl+Tab by use
 *   peek     a link in a card over the page
 *   spur     pages as columns side by side in one tab
 *   frame    the script inside every page (hints, clicks, keys, drafts)
 */
"use strict";

/* global ExtensionAPI, ExtensionCommon, Services */

const PART_FILES = ["base", "palette", "rail", "env", "marks", "recent", "dock", "filter", "domains", "keys", "peek", "spur", "frame"];

let shared = null;

// the parts load as resource://pshell-chrome/… (a sub-script may not come
// from a file: or jar: address directly)
const HOST = "pshell-chrome";

function resources() {
	return Services.io.getProtocolHandler("resource").QueryInterface(Components.interfaces.nsIResProtocolHandler);
}

function load(extension) {
	if (shared) return shared;
	resources().setSubstitution(HOST, Services.io.newURI(extension.rootURI.resolve("experiments/")));
	const scope = {
		Services,
		ChromeUtils,
		Ci: Components.interfaces,
		Cu: Components.utils,
		console,
		base: `resource://${HOST}/`,
		PARTS: []
	};
	for (const name of PART_FILES) {
		// never from the startup cache: it would keep a part's old code
		Services.scriptloader.loadSubScriptWithOptions(`resource://${HOST}/parts/${name}.js`, { target: scope, ignoreCache: true });
	}
	shared = scope;
	return scope;
}

this.pshellChrome = class extends ExtensionAPI {
	onStartup() {
		load(this.extension).start();
	}

	onShutdown(isAppShutdown) {
		if (isAppShutdown || !shared) return;
		shared.stop();
		shared = null;
		resources().setSubstitution(HOST, null);
	}

	getAPI(context) {
		const S = load(context.extension);
		const tabManager = context.extension.tabManager;
		S.nativeTab = id => {
			try {
				return tabManager.get(id).nativeTab;
			} catch (error) {
				return null;
			}
		};
		S.tabId = tab => {
			try {
				return tabManager.getWrapper(tab).id;
			} catch (error) {
				return -1;
			}
		};
		return {
			pshellChrome: {
				async setRail(rail) {
					S.setRail(rail);
				},
				async setTabs(tabs) {
					S.setTabs(tabs);
				},
				async command(name, args) {
					return S.command(name, args || {});
				},
				onEvent: new ExtensionCommon.EventManager({
					context,
					name: "pshellChrome.onEvent",
					register: fire => {
						const listener = (name, data) => fire.async(name, data);
						S.listeners.add(listener);
						return () => S.listeners.delete(listener);
					}
				}).api()
			}
		};
	}
};
