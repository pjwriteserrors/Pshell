/* Links without tracking parameters (utm_*, fbclid, gclid, …) when copied:
 * the address bar's copy, "Copy Link" of the page's menu and the links the
 * Pshell menu hands to the shell (background/bridge.js). Settings › Browser ›
 * Navigation: Clean links (tabs.cleanLinks).
 *
 * The background page loads this file too (manifest.json): cleanLink is all
 * it uses; the part below is the browser window's. */
"use strict";

/* exported cleanLink */

var TRACKING = /^(utm_[a-z0-9_]+|fbclid|gclid|gclsrc|dclid|gbraid|wbraid|msclkid|mc_eid|mc_cid|igshid|igsh|yclid|twclid|ttclid|li_fat_id|_hsenc|_hsmi|__hssc|__hstc|__hsfp|hsctatracking|mkt_tok|oly_anon_id|oly_enc_id|vero_id|vero_conv|_openstat|wickedid|rb_clickid|s_cid|ref_src|spm|si|srsltid)$/i;

// the link without them; anything that is no web address stays as it is
function cleanLink(text) {
	const value = String(text || "");
	if (!/^https?:\/\/\S+$/i.test(value.trim())) return value;
	const hash = value.indexOf("#");
	const query = value.indexOf("?");
	if (query < 0 || (hash >= 0 && hash < query)) return value;
	const params = value.slice(query + 1, hash > 0 ? hash : undefined).split("&");
	const kept = params.filter(part => part !== "" && !TRACKING.test(part.split("=")[0]));
	if (kept.length === params.length) return value;
	return value.slice(0, query) + (kept.length ? `?${kept.join("&")}` : "") + (hash > 0 ? value.slice(hash) : "");
}

if (typeof PARTS !== "undefined") {
	(function () {
		let menuModule = null;
		let originalCopyLink = null;

		const on = () => tabsConfig().cleanLinks;

		// the page's menu (one module for every window)
		function patchMenu() {
			try {
				menuModule = ChromeUtils.importESModule("chrome://browser/content/nsContextMenu.sys.mjs");
			} catch (error) {
				return;
			}
			const proto = menuModule.nsContextMenu?.prototype;
			if (!proto || originalCopyLink) return;
			originalCopyLink = proto.copyLink;
			proto.copyLink = function (url = this.linkURL) {
				return originalCopyLink.call(this, on() ? cleanLink(url) : url);
			};
		}

		function unpatchMenu() {
			const proto = menuModule?.nsContextMenu?.prototype;
			if (proto && originalCopyLink) proto.copyLink = originalCopyLink;
			originalCopyLink = null;
			menuModule = null;
		}

		PARTS.push({
			name: "clean",
			start: patchMenu,
			stop: unpatchMenu,
			attach(W) {
				// the address bar: copy, cut and the primary selection all ask this
				const bar = W.win.gURLBar;
				if (!bar || typeof bar._getSelectedValueForClipboard !== "function") return;
				const original = bar._getSelectedValueForClipboard;
				bar._getSelectedValueForClipboard = function () {
					const value = original.call(this);
					return on() ? cleanLink(value) : value;
				};
				W.cleanup.push(() => {
					delete bar._getSelectedValueForClipboard;
				});
			}
		});
	})();
}
