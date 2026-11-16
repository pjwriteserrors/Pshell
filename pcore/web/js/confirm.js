// Critical actions (docs/core.md › Recent confirmation): one sheet that says
// what is about to happen, asks "really?" for critical services, and – when
// this session has not given the password in the last five minutes – asks
// for it (and the TOTP code) right there, then POST /api/auth/confirm first.
import { h, icon } from "./util.js";
import * as api from "./api.js";
import { state, confirmedUntil, hasTotp, refreshMe, user } from "./store.js";
import { openDialog, shake, toast } from "./ui.js";
import { animate, EASE } from "./motion.js";

const fresh = () => confirmedUntil() > Date.now() + 8000;
export const needsConfirm = error => error?.status === 403 && /confirm/.test(String(error.code || ""));

// run(): the call itself; a thrown confirm_needed opens the password once more
export async function critical({ title, body, confirmLabel = "Go on", danger = true, icon: iconName = "shield_alert_outline", really, details, run, success } = {}) {
	try {
		await refreshMe();
	} catch (error) {}
	const isUser = !!user();
	const content = h("div.confirm-body.crit");
	if (body) content.appendChild(typeof body === "string" ? h("p", body) : body);
	if (details?.length) content.appendChild(h("ul.confirm-list", details.map(d => h("li.ellipsis", d))));

	// "really": a second, deliberate switch for critical services
	let reallyOn = false;
	let reallyRow = null;
	if (really) {
		const sw = h("button.toggle", { type: "button", role: "switch", "aria-checked": "false" });
		reallyRow = h("label.really-row", sw, h("div", h("strong", "Yes, really"), h("div.form-hint", typeof really === "string" ? really : "This one is marked critical.")));
		const flip = () => {
			reallyOn = !reallyOn;
			sw.classList.toggle("on", reallyOn);
			sw.setAttribute("aria-checked", String(reallyOn));
			reallyRow.classList.toggle("on", reallyOn);
		};
		sw.addEventListener("click", event => {
			event.preventDefault();
			flip();
		});
		content.appendChild(reallyRow);
	}

	// the password (and code) when the session is not confirmed
	const password = h("input", { type: "password", autocomplete: "current-password", placeholder: "Your password", "aria-label": "Your password" });
	const code = h("input.code-input", { inputmode: "numeric", maxlength: 6, autocomplete: "one-time-code", placeholder: "123456", "aria-label": "Code from your authenticator" });
	const ask = h("div.sudo", { hidden: true },
		h("div.sudo-head", icon("shield_lock_outline"), h("div", h("strong", "Confirm it is you"), h("div.form-hint", "Critical changes need your password from the last five minutes."))),
		h("label.field", icon("key_outline"), password),
		hasTotp() ? h("label.field", icon("shield_key_outline"), code) : null);
	content.appendChild(ask);
	const showAsk = () => {
		if (!ask.hidden) return;
		ask.hidden = false;
		animate(ask, [{ opacity: 0, transform: "translateY(8px)" }, { opacity: 1, transform: "none" }], { duration: 420, easing: EASE.spring, fill: "none" });
		setTimeout(() => password.focus(), 30);
	};
	if (isUser && !fresh()) showAsk();

	return new Promise(resolve => {
		let result;
		let ok = false;
		const dialog = openDialog({
			title,
			icon: iconName,
			tone: danger ? "var(--danger)" : "var(--warning)",
			body: content,
			className: "crit-sheet",
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: confirmLabel, danger, primary: !danger, run: async () => {
					if (really && !reallyOn) {
						shake(reallyRow);
						return false;
					}
					if (!ask.hidden) {
						if (!password.value) {
							shake(password.parentElement);
							password.focus();
							return false;
						}
						try {
							const answer = await api.post("/api/auth/confirm", { password: password.value, code: code.value.trim() || undefined }, { quiet: true });
							if (state.me) state.me.confirmed_until = answer?.confirmed_until ?? Date.now() / 1000 + 300;
						} catch (error) {
							shake(ask);
							password.select();
							toast(error.message || "Not confirmed", { tone: "bad", icon: "shield_alert_outline" });
							return false;
						}
					}
					try {
						result = await run?.();
						ok = true;
					} catch (error) {
						if (needsConfirm(error) && isUser) {
							if (state.me) state.me.confirmed_until = 0;
							password.value = "";
							showAsk();
							return false;
						}
						throw error;
					}
					if (success) toast(success, { icon: "check", tone: "good", timeout: 2200 });
				} }
			],
			onClose: () => resolve(ok ? result ?? true : false)
		});
		const button = dialog.buttons[1];
		if (danger) button.classList.add("solid");
		code.addEventListener("input", () => {
			code.value = code.value.replace(/\D/g, "").slice(0, 6);
			if (code.value.length === 6 && password.value) button.click();
		});
	});
}
