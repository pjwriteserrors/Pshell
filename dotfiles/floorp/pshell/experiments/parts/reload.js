/* A second reload button next to the browser's own: reloads without the
 * cache, like Ctrl+F5. It sits in the reload button's item, so it moves with
 * it (pshell.css orders that item). */
"use strict";

(function () {
	const ID = "pshell-hard-reload-button";

	PARTS.push({
		name: "reload",
		attach(W) {
			const item = W.doc.getElementById("stop-reload-button");
			if (!item || W.doc.getElementById(ID)) return;
			const button = W.doc.createXULElement("toolbarbutton");
			button.id = ID;
			button.className = "toolbarbutton-1";
			button.setAttribute("tooltiptext", "Reload without cache (Ctrl+F5)");
			button.addEventListener("command", () => W.win.BrowserCommands.reloadSkipCache());
			item.appendChild(button);
			W.cleanup.push(() => button.remove());
		}
	});
})();
