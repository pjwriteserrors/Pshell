// The sign-in: a glass card over the palette's blobs; name and password, then
// the authenticator code in six boxes when the account has TOTP. One sign-in
// here is the sign-in of every pshell service on this host.
import { h, icon, clear } from "../util.js";
import * as api from "../api.js";
import { animate, EASE, DUR } from "../motion.js";
import { shake } from "../ui.js";
import { set } from "../store.js";

// minutes until a lock ends, from what the server says (retry_after s, until ts)
function lockMinutes(error) {
	const d = error?.data || {};
	let seconds = Number(d.retry_after ?? d.retry ?? 0);
	if (!seconds && d.until) {
		const until = typeof d.until === "number" ? (d.until < 1e12 ? d.until * 1000 : d.until) : Date.parse(d.until);
		seconds = (until - Date.now()) / 1000;
	}
	if (!seconds) {
		const m = /(\d+)\s*min/.exec(error?.message || "");
		seconds = m ? Number(m[1]) * 60 : 15 * 60;
	}
	return Math.max(1, Math.ceil(seconds / 60));
}

export function showLogin(options, onDone) {
	const { next, expired, offline, signedOut } = options || {};
	const app = document.getElementById("app");
	document.body.dataset.page = "login";
	clear(app);
	document.getElementById("overlays").textContent = "";
	document.title = "Sign in · netcore";

	const name = h("input", { id: "login-user", name: "username", autocomplete: "username", placeholder: "Name", spellcheck: false, autocapitalize: "off", "aria-label": "Name" });
	const password = h("input", { id: "login-password", name: "password", type: "password", autocomplete: "current-password", placeholder: "Password", "aria-label": "Password" });
	try {
		name.value = localStorage.getItem("core.user") || "";
	} catch (error) {}
	const eye = h("button.icon-btn.small", { type: "button", title: "Show the password", "aria-label": "Show the password" }, icon("eye_outline"));
	eye.addEventListener("click", () => {
		const show = password.type === "password";
		password.type = show ? "text" : "password";
		eye.replaceChildren(icon(show ? "eye_off_outline" : "eye_outline"));
	});
	const error = h("div.login-error", { role: "alert" });
	const submit = h("button.btn.primary.large.login-go", { type: "submit" }, h("span", "Sign in"), icon("arrow_right"));

	const stepOne = h("form.login-step", { autocomplete: "on" },
		h("label.field.login-field", icon("account_outline"), name),
		h("label.field.login-field", icon("key_outline"), password, eye),
		submit);

	const boxes = [...Array(6)].map((_, i) => h("input.code-box", { inputmode: "numeric", maxlength: 1, autocomplete: i === 0 ? "one-time-code" : "off", "aria-label": `Digit ${i + 1}` }));
	const back = h("button.btn.ghost", { type: "button" }, icon("arrow_left"), "Back");
	const stepTwo = h("form.login-step.code", { hidden: true },
		h("div.code-title", icon("shield_key_outline"), h("div", h("strong", "Two-step check"), h("div.subtle", "The code from your authenticator app"))),
		h("div.code-row", { role: "group", "aria-label": "Six-digit code" }, boxes),
		h("div.code-actions", back));

	// locked: a calm panel with the minutes counting down
	const lockText = h("strong", "");
	const lockPanel = h("div.lock-panel", { hidden: true, role: "status" },
		h("div.lock-icon", icon("lock_outline")),
		h("div", lockText, h("div.subtle", "Too many wrong tries for this name from here. Nothing is lost – just wait.")));

	let target = "";
	if (next) {
		try {
			const url = new URL(next);
			target = url.origin === location.origin ? "" : url.host;
		} catch (e) {}
	}

	const logo = h("div.login-logo", h("div.logo-core", h("i.core-center"), h("i.core-orbit", h("b"), h("b"), h("b"))), h("div.logo-glow"));
	const sub = offline ? "netcore does not answer right now"
		: expired ? "Your session ended – sign in again"
		: signedOut ? "Signed out of every pshell service here"
		: "One sign-in for every pshell service";
	const card = h("div.login-card",
		logo,
		h("h1.login-name", "netcore"),
		h("div.login-sub", sub),
		target ? h("div.login-next", icon("open_in_new"), h("span", "Then on to "), h("strong", target)) : null,
		h("div.login-steps", stepOne, stepTwo, lockPanel),
		error);
	const page = h("main.login-page", card, h("div.login-foot", "pshell core"));
	app.appendChild(page);

	animate(card, [{ opacity: 0, transform: "translateY(26px) scale(0.94)" }, { opacity: 1, transform: "none" }], { duration: 700, easing: EASE.spring, fill: "none" });
	[...card.children].forEach((child, i) => animate(child, [{ opacity: 0, transform: "translateY(10px)" }, { opacity: 1, transform: "none" }], { duration: 500, delay: 120 + i * 60, easing: EASE.spatial, fill: "backwards" }));
	setTimeout(() => (name.value ? password : name).focus(), 60);

	const showError = text => {
		error.textContent = text;
		error.classList.toggle("on", !!text);
	};

	let lockTimer = 0;
	const showLock = minutes => {
		let left = minutes;
		const paint = () => (lockText.textContent = left <= 1 ? "Locked – try again in a minute" : `Locked – try again in ${left} min`);
		paint();
		clearInterval(lockTimer);
		lockTimer = setInterval(() => {
			left -= 1;
			if (left <= 0) {
				clearInterval(lockTimer);
				unlock();
				return;
			}
			paint();
		}, 60000);
		showError("");
		stepOne.hidden = true;
		stepTwo.hidden = true;
		lockPanel.hidden = false;
		animate(lockPanel, [{ opacity: 0, transform: "scale(0.94)" }, { opacity: 1, transform: "none" }], { duration: DUR.xlong, easing: EASE.spring, fill: "none" });
	};
	const unlock = () => {
		lockPanel.hidden = true;
		stepOne.hidden = false;
		animate(stepOne, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.long, fill: "none" });
		password.value = "";
		password.focus();
	};

	let busy = false;
	const attempt = async code => {
		if (busy) return;
		busy = true;
		showError("");
		submit.classList.add("busy");
		try {
			const result = await api.post("/api/auth/login", { name: name.value.trim(), password: password.value, code, next: next || undefined }, { quiet: true });
			if (result?.need === "totp") {
				toCode();
				return;
			}
			try {
				localStorage.setItem("core.user", name.value.trim());
			} catch (e) {}
			set("me", null);
			await success(result);
		} catch (err) {
			if (err.data?.need === "totp" && !code) {
				toCode();
			} else if (err.status === 429 || err.code === "locked") {
				showLock(lockMinutes(err));
			} else {
				showError(err.status === 401 ? (code ? "That code did not fit" : "Name or password is wrong") : err.message || "Could not sign in");
				shake(code ? stepTwo : stepOne);
				if (code) {
					boxes.forEach(b => {
						b.value = "";
						b.classList.remove("filled");
					});
					boxes[0].focus();
				} else {
					password.select();
				}
			}
		} finally {
			busy = false;
			submit.classList.remove("busy");
		}
	};

	const toCode = () => {
		animate(stepOne, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateX(-40px)" }], { duration: DUR.medium, easing: EASE.accel }).finished.then(() => {
			stepOne.hidden = true;
			stepTwo.hidden = false;
			animate(stepTwo, [{ opacity: 0, transform: "translateX(40px)" }, { opacity: 1, transform: "none" }], { duration: DUR.xlong, easing: EASE.spring, fill: "none" });
			boxes.forEach((b, i) => animate(b, [{ opacity: 0, transform: "translateY(10px) scale(0.8)" }, { opacity: 1, transform: "none" }], { duration: 420, delay: i * 40, easing: EASE.spring, fill: "backwards" }));
			boxes[0].focus();
		});
	};

	back.addEventListener("click", () => {
		stepTwo.hidden = true;
		stepOne.hidden = false;
		stepOne.getAnimations().forEach(a => a.cancel());
		animate(stepOne, [{ opacity: 0, transform: "translateX(-40px)" }, { opacity: 1, transform: "none" }], { duration: DUR.long, easing: EASE.spatial, fill: "none" });
		password.focus();
	});

	const fill = text => {
		[...text.slice(0, 6)].forEach((d, k) => {
			boxes[k].value = d;
			boxes[k].classList.add("filled");
		});
		if (text.length >= 6) attempt(text.slice(0, 6));
		else boxes[Math.min(text.length, 5)].focus();
	};
	boxes.forEach((box, i) => {
		box.addEventListener("input", () => {
			const digits = box.value.replace(/\D/g, "");
			if (digits.length > 1) {
				fill(digits);
				return;
			}
			box.value = digits;
			box.classList.toggle("filled", !!box.value);
			if (digits && boxes[i + 1]) boxes[i + 1].focus();
			const all = boxes.map(b => b.value).join("");
			if (all.length === 6) attempt(all);
		});
		box.addEventListener("keydown", event => {
			if (event.key === "Backspace" && !box.value && boxes[i - 1]) {
				boxes[i - 1].value = "";
				boxes[i - 1].classList.remove("filled");
				boxes[i - 1].focus();
			}
			if (event.key === "ArrowLeft" && boxes[i - 1]) boxes[i - 1].focus();
			if (event.key === "ArrowRight" && boxes[i + 1]) boxes[i + 1].focus();
			if (event.key === "Escape") back.click();
		});
		box.addEventListener("paste", event => {
			const text = (event.clipboardData?.getData("text") || "").replace(/\D/g, "");
			if (!text) return;
			event.preventDefault();
			fill(text);
		});
	});

	stepOne.addEventListener("submit", event => {
		event.preventDefault();
		if (!name.value.trim()) {
			shake(name.parentElement);
			name.focus();
			return;
		}
		if (!password.value) {
			shake(password.parentElement);
			password.focus();
			return;
		}
		attempt();
	});
	stepTwo.addEventListener("submit", event => event.preventDefault());

	async function success(result) {
		clearInterval(lockTimer);
		card.classList.add("done");
		await animate(card, [{ opacity: 1, transform: "none", filter: "blur(0)" }, { opacity: 0, transform: "scale(1.06)", filter: "blur(6px)" }], { duration: 380, easing: EASE.accel }).finished;
		document.body.dataset.page = "";
		page.remove();
		onDone(result);
	}
}
