/* The shell's terminal colours (color0–15 of its palette) as --pshell-color0…15
 * on every window's root, as the bridge hands them over (command "palette",
 * with each theme). pshell.css dresses Firefox's tab group colours in them,
 * so every group – an environment's, a site's, one made by hand – wears the
 * shell's colours. */
"use strict";

(function () {
	let colors = [];

	function paint(W) {
		const style = W.doc.documentElement.style;
		for (let i = 0; i < 16; i++) {
			if (colors[i]) style.setProperty(`--pshell-color${i}`, colors[i]);
			else style.removeProperty(`--pshell-color${i}`);
		}
	}

	COMMANDS.palette = async args => {
		const list = Array.isArray(args.colors) ? args.colors : [];
		colors = list.slice(0, 16).map(c => (/^#[0-9a-f]{6}$/i.test(String(c)) ? String(c) : ""));
		for (const W of attached) paint(W);
		return true;
	};

	PARTS.push({
		name: "palette",
		attach: paint,
		detach(W) {
			colors.forEach((c, i) => W.doc.documentElement.style.removeProperty(`--pshell-color${i}`));
		}
	});
})();
