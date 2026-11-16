// The login: a glass card over the palette's blobs; name and password, then
// the authenticator code in six boxes when the account has TOTP.
import { h, icon, clear } from "../util.js";
import * as api from "../api.js";
import { animate, EASE, DUR } from "../motion.js";
import { shake } from "../ui.js";
import { set } from "../store.js";

export function showLogin(hello, onDone, { expired = false } = {}) {
	const app = document.getElementById("app");
	document.body.dataset.page = "login";
	clear(app);
	document.getElementById("overlays").textContent = "";

	const name = h("input", { id: "login-user", autocomplete: "username", placeholder: "Name", spellcheck: false, autocapitalize: "off" });
	const password = h("input", { id: "login-password", type: "password", autocomplete: "current-password", placeholder: "Password" });
	try {
		name.value = localStorage.getItem("nas.user") || "";
	} catch (error) {}
	const eye = h("button.icon-btn.small", { type: "button", title: "Show the password", tabindex: -1 }, icon("eye_outline"));
	eye.addEventListener("click", () => {
		const show = password.type === "password";
		password.type = show ? "text" : "password";
		eye.firstChild.replaceWith(icon(show ? "eye_off_outline" : "eye_outline"));
	});
	const error = h("div.login-error", { role: "alert" });
	const submit = h("button.btn.primary.large.login-go", { type: "submit" }, h("span", "Log in"), icon("arrow_right"));

	const stepOne = h("form.login-step", { autocomplete: "on" },
		h("label.field.login-field", icon("account_outline"), name),
		h("label.field.login-field", icon("key_outline"), password, eye),
		submit);

	const boxes = [...Array(6)].map((_, i) => h("input.code-box", { inputmode: "numeric", maxlength: 1, autocomplete: i === 0 ? "one-time-code" : "off", "aria-label": `Digit ${i + 1}` }));
	const back = h("button.btn.ghost", { type: "button" }, icon("arrow_left"), "Back");
	const stepTwo = h("form.login-step.code", { hidden: true },
		h("div.code-title", icon("shield_key_outline"), h("div", h("strong", "Two-step check"), h("div.subtle", "The code from your authenticator app"))),
		h("div.code-row", boxes),
		h("div.code-actions", back));

	const logo = h("div.login-logo",
		h("div.logo-disk", h("i"), h("i"), h("i")),
		h("div.logo-glow"));
	const card = h("div.login-card",
		logo,
		h("h1.login-name", hello?.name || "NAS"),
		h("div.login-sub", hello?.offline ? "The NAS does not answer right now" : expired ? "Your session ended – log in again" : "pshell NAS"),
		h("div.login-steps", stepOne, stepTwo),
		error);
	const page = h("div.login-page", card, h("div.login-foot", hello?.version ? `pshell-nas ${hello.version}` : ""));
	app.appendChild(page);

	animate(card, [{ opacity: 0, transform: "translateY(26px) scale(0.94)" }, { opacity: 1, transform: "none" }], { duration: 700, easing: EASE.spring, fill: "none" });
	[...card.children].forEach((child, i) => animate(child, [{ opacity: 0, transform: "translateY(10px)" }, { opacity: 1, transform: "none" }], { duration: 500, delay: 120 + i * 60, easing: EASE.spatial, fill: "backwards" }));
	setTimeout(() => (name.value ? password : name).focus(), 60);

	const showError = text => {
		error.textContent = text;
		error.classList.toggle("on", !!text);
	};

	let busy = false;
	const attempt = async totp => {
		if (busy) return;
		busy = true;
		showError("");
		submit.classList.add("busy");
		try {
			const result = await api.post("/api/login", { user: name.value.trim(), password: password.value, totp }, { quiet: true });
			try {
				localStorage.setItem("nas.user", name.value.trim());
			} catch (e) {}
			set("me", null);
			await success(result);
		} catch (err) {
			if (err.code === "totp" && !totp) {
				toCode();
			} else {
				showError(err.message || "Could not log in");
				shake(totp ? stepTwo : stepOne);
				if (totp) {
					boxes.forEach(b => (b.value = ""));
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
		stepOne.hidden = false;
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
		animate(stepOne, [{ opacity: 0, transform: "translateX(-40px)" }, { opacity: 1, transform: "none" }], { duration: DUR.long, easing: EASE.spatial, fill: "none" });
		password.focus();
	});

	boxes.forEach((box, i) => {
		box.addEventListener("input", () => {
			const digits = box.value.replace(/\D/g, "");
			if (digits.length > 1) {
				// a pasted code fills the row
				[...digits.slice(0, 6)].forEach((d, k) => boxes[k] && (boxes[k].value = d));
			} else {
				box.value = digits;
				if (digits && boxes[i + 1]) boxes[i + 1].focus();
			}
			box.classList.toggle("filled", !!box.value);
			const code = boxes.map(b => b.value).join("");
			if (code.length === 6) attempt(code);
		});
		box.addEventListener("keydown", event => {
			if (event.key === "Backspace" && !box.value && boxes[i - 1]) {
				boxes[i - 1].value = "";
				boxes[i - 1].classList.remove("filled");
				boxes[i - 1].focus();
			}
			if (event.key === "ArrowLeft" && boxes[i - 1]) boxes[i - 1].focus();
			if (event.key === "ArrowRight" && boxes[i + 1]) boxes[i + 1].focus();
		});
		box.addEventListener("paste", event => {
			const text = (event.clipboardData?.getData("text") || "").replace(/\D/g, "");
			if (text.length >= 6) {
				event.preventDefault();
				[...text.slice(0, 6)].forEach((d, k) => {
					boxes[k].value = d;
					boxes[k].classList.add("filled");
				});
				attempt(text.slice(0, 6));
			}
		});
	});

	stepOne.addEventListener("submit", event => {
		event.preventDefault();
		if (!name.value.trim()) {
			shake(name.parentElement);
			name.focus();
			return;
		}
		attempt();
	});
	stepTwo.addEventListener("submit", event => event.preventDefault());

	async function success(result) {
		card.classList.add("done");
		await animate(card, [{ opacity: 1, transform: "none", filter: "blur(0)" }, { opacity: 0, transform: "scale(1.06)", filter: "blur(6px)" }], { duration: 380, easing: EASE.accel }).finished;
		document.body.dataset.page = "";
		page.remove();
		if (result?.totp_setup) sessionStorage.setItem("nas.totpSetup", "1");
		onDone();
	}
}
