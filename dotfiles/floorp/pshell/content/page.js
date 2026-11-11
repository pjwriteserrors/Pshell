// What the shell does inside a page, only where it is switched on
// (storage "pageConfig", sent by the shell through background/bridge.js):
//
// - forms: next to the e-mail field of a sign-up form a small button offers
//   one of the shell's made-up identities (Identities); nothing is filled in
//   before one is picked.
// - intercept.mailto: mailto: links open in the shell's mail.
// - intercept.calendar: links to .ics files and webcal: go to the shell,
//   which offers to add the events.
//
// The page never sees the identities until one is picked; the button lives
// in a closed shadow root.

(() => {
	if (window.top !== window && !document.querySelector("form")) return;
	let pageConfig = { intercept: { mailto: false, calendar: false }, forms: false };

	browser.storage.local.get("pageConfig").then(kept => {
		if (kept.pageConfig) pageConfig = kept.pageConfig;
		if (pageConfig.forms) watchForms();
	});
	browser.storage.onChanged.addListener((changes, area) => {
		if (area !== "local" || !changes.pageConfig) return;
		const before = pageConfig.forms;
		pageConfig = changes.pageConfig.newValue || pageConfig;
		if (pageConfig.forms && !before) watchForms();
		if (!pageConfig.forms) removeButtons();
	});

	// ── links ──────────────────────────────────────────────────────────────
	document.addEventListener("click", event => {
		if (event.defaultPrevented || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
		const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
		if (!link) return;
		const href = link.href || "";
		if (pageConfig.intercept?.mailto && href.startsWith("mailto:")) {
			event.preventDefault();
			browser.runtime.sendMessage({ pshell: "mailto", url: href });
		} else if (pageConfig.intercept?.calendar && (/^webcals?:/i.test(href) || /\.ics(\?|#|$)/i.test(new URL(href, location.href).pathname))) {
			event.preventDefault();
			browser.runtime.sendMessage({ pshell: "calendar", url: href.replace(/^webcal/i, "https") });
		}
	}, true);

	// ── sign-up forms ──────────────────────────────────────────────────────
	const SIGNUP = /regist|sign.?up|create.?(an.?)?account|join|konto.?(erstellen|anlegen)|anmelden.?und|neu.?hier|registrier|account.?erstellen/i;
	const marked = new WeakSet();
	let observer = null;
	let scanDue = null;

	function visible(field) {
		const box = field.getBoundingClientRect();
		return box.width > 20 && box.height > 10 && getComputedStyle(field).visibility !== "hidden";
	}

	function fieldsOf(form) {
		return [...form.querySelectorAll("input, select")].filter(field => !field.disabled && field.type !== "hidden" && visible(field));
	}

	function looksLikeSignup(form) {
		const fields = fieldsOf(form);
		const passwords = fields.filter(field => field.type === "password");
		const email = fields.find(field => field.type === "email" || /e-?mail/i.test(`${field.name} ${field.id} ${field.autocomplete} ${field.placeholder}`));
		if (!email && !fields.some(field => /user(name)?|login/i.test(`${field.name} ${field.id} ${field.autocomplete}`))) return false;
		if (passwords.length >= 2) return true;
		if (fields.some(field => field.autocomplete === "new-password")) return true;
		const words = `${form.action || ""} ${form.id} ${form.className} ${form.innerText.slice(0, 2000)} ${location.pathname}`;
		return SIGNUP.test(words) && passwords.length >= 1;
	}

	function anchorOf(form) {
		const fields = fieldsOf(form);
		return fields.find(field => field.type === "email" || /e-?mail/i.test(`${field.name} ${field.id} ${field.autocomplete}`))
			|| fields.find(field => /user(name)?/i.test(`${field.name} ${field.id} ${field.autocomplete}`))
			|| fields[0];
	}

	function scan() {
		scanDue = null;
		for (const form of document.querySelectorAll("form")) {
			if (marked.has(form) || !looksLikeSignup(form)) continue;
			const anchor = anchorOf(form);
			if (anchor) {
				marked.add(form);
				addButton(form, anchor);
			}
		}
	}

	function watchForms() {
		scan();
		if (observer) return;
		observer = new MutationObserver(() => {
			if (!scanDue) scanDue = setTimeout(scan, 600);
		});
		observer.observe(document.documentElement, { childList: true, subtree: true });
	}

	const hosts = [];
	function removeButtons() {
		observer?.disconnect();
		observer = null;
		for (const host of hosts.splice(0)) host.remove();
	}

	// the button sits over the right end of the field and follows it
	function addButton(form, anchor) {
		const host = document.createElement("pshell-identity");
		host.style.cssText = "position:absolute;z-index:2147483646;top:0;left:0;";
		const root = host.attachShadow({ mode: "closed" });
		root.innerHTML = `<style>
			:host { all: initial; }
			button { all: unset; cursor: pointer; display: flex; align-items: center; gap: 6px; height: 22px; padding: 0 9px 0 6px;
				border-radius: 999px; font: 600 11.5px system-ui, sans-serif; background: #1d1d1f; color: #f4ede6;
				box-shadow: 0 0 0 1px rgba(255,255,255,.12), 0 4px 14px rgba(0,0,0,.35); opacity: .9; }
			button:hover { opacity: 1; }
			svg { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 1.6; }
			.list { position: absolute; top: 28px; right: 0; min-width: 240px; max-width: 320px; background: #1d1d1f; color: #f4ede6;
				border-radius: 14px; padding: 6px; box-shadow: 0 0 0 1px rgba(255,255,255,.1), 0 16px 40px rgba(0,0,0,.45);
				font: 12.5px system-ui, sans-serif; }
			.item { padding: 7px 9px; border-radius: 9px; cursor: pointer; display: grid; gap: 1px; }
			.item:hover { background: rgba(255,255,255,.08); }
			.item b { font-weight: 600; }
			.item span, .empty { opacity: .62; font-size: 11.5px; }
			.empty { padding: 8px 10px; }
		</style><button title="Pshell"><svg viewBox="0 0 16 16"><circle cx="8" cy="5.5" r="2.6"/><path d="M3 13.5c.6-2.6 2.6-4 5-4s4.4 1.4 5 4"/></svg>Identität</button>`;
		const button = root.querySelector("button");
		let list = null;

		const place = () => {
			if (!anchor.isConnected || !form.isConnected) {
				host.remove();
				return;
			}
			const box = anchor.getBoundingClientRect();
			host.style.display = visible(anchor) ? "block" : "none";
			host.style.transform = `translate(${Math.round(window.scrollX + box.right - button.offsetWidth - 6)}px, ${Math.round(window.scrollY + box.top + (box.height - 22) / 2)}px)`;
		};

		button.addEventListener("click", async event => {
			event.preventDefault();
			event.stopPropagation();
			if (list) {
				list.remove();
				list = null;
				return;
			}
			const identities = await browser.runtime.sendMessage({ pshell: "identities" }).catch(() => []);
			list = document.createElement("div");
			list.className = "list";
			if (!identities || identities.length === 0) {
				list.innerHTML = `<div class="empty">Keine Identitäten</div>`;
			} else {
				for (const identity of identities) {
					const item = document.createElement("div");
					item.className = "item";
					const name = document.createElement("b");
					name.textContent = identity.label || identity.fields?.name || identity.fields?.email || "";
					const line = document.createElement("span");
					line.textContent = identity.fields?.email || identity.fields?.username || "";
					item.append(name, line);
					item.addEventListener("click", () => {
						fill(form, identity);
						browser.runtime.sendMessage({ pshell: "identityUsed", id: identity.id });
						list.remove();
						list = null;
					});
					list.append(item);
				}
			}
			root.append(list);
		});

		document.documentElement.append(host);
		hosts.push(host);
		place();
		const follow = () => requestAnimationFrame(place);
		window.addEventListener("scroll", follow, { passive: true, capture: true });
		window.addEventListener("resize", follow, { passive: true });
		new ResizeObserver(follow).observe(anchor);
	}

	// ── filling ────────────────────────────────────────────────────────────
	// which identity field a form field wants, from what it says of itself
	const KINDS = [
		["email", /e-?mail/i, ["email"]],
		["username", /user.?name|login|benutzer|nickname|handle/i, ["username"]],
		["password", null, ["new-password", "current-password"]],
		["given", /first.?name|given|vorname|fname/i, ["given-name"]],
		["family", /last.?name|family|surname|nachname|lname/i, ["family-name"]],
		["name", /^name$|full.?name|your.?name|dein.?name|ihr.?name/i, ["name"]],
		["phone", /phone|tel|mobil|handy/i, ["tel", "tel-national"]],
		["birthday", /birth|geburt|dob/i, ["bday"]],
		["street", /street|address.?1|addr|straße|strasse|anschrift/i, ["street-address", "address-line1"]],
		["zip", /zip|postal|plz|postcode/i, ["postal-code"]],
		["city", /city|town|ort|stadt/i, ["address-level2"]],
		["country", /country|land/i, ["country", "country-name"]],
		["gender", /gender|geschlecht|anrede|salutation/i, ["sex"]]
	];

	function kindOf(field) {
		if (field.type === "password") return "password";
		if (field.type === "email") return "email";
		const auto = String(field.autocomplete || "").toLowerCase().split(/\s+/).pop();
		for (const [kind, , autos] of KINDS) if (autos.includes(auto)) return kind;
		const label = field.labels && field.labels[0] ? field.labels[0].innerText : "";
		const words = `${field.name} ${field.id} ${field.placeholder} ${field.getAttribute("aria-label") || ""} ${label}`;
		for (const [kind, pattern] of KINDS) if (pattern && pattern.test(words)) return kind;
		return "";
	}

	// set the way a person typing would, so frameworks notice
	function put(field, value) {
		if (value === undefined || value === null || value === "") return;
		value = String(value);
		if (field.tagName === "SELECT") {
			const option = [...field.options].find(item => item.value.toLowerCase() === value.toLowerCase() || item.text.trim().toLowerCase() === value.toLowerCase());
			if (!option) return;
			field.value = option.value;
		} else if (field.type === "date" && /^\d{1,2}\.\d{1,2}\.\d{4}$/.test(value)) {
			const [day, month, year] = value.split(".");
			field.value = `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`;
		} else {
			const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")?.set;
			setter ? setter.call(field, value) : (field.value = value);
		}
		field.dispatchEvent(new Event("input", { bubbles: true }));
		field.dispatchEvent(new Event("change", { bubbles: true }));
	}

	function fill(form, identity) {
		const values = identity.fields || {};
		for (const field of fieldsOf(form)) {
			if (field.type === "checkbox" || field.type === "radio" || field.type === "submit" || field.type === "button") continue;
			const kind = kindOf(field);
			if (kind && field.value === "") put(field, values[kind]);
		}
	}

	// the shell may also fill the form in front (bridge.js "fill")
	browser.runtime.onMessage.addListener(message => {
		if (!message || message.pshell !== "fill" || !message.identity) return;
		const forms = [...document.querySelectorAll("form")].filter(looksLikeSignup);
		const form = forms.find(item => item.contains(document.activeElement)) || forms[0];
		if (!form) return Promise.resolve(false);
		fill(form, message.identity);
		return Promise.resolve(true);
	});
})();
