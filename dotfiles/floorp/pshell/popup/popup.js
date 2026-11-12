// The toolbar button: the style editor for the page in front and its styles
// on and off (background/styles.js).

const send = (op, data) => browser.runtime.sendMessage(Object.assign({ pshell: "styles", op }, data || {}));

async function show() {
	const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
	const url = tab ? tab.url || "" : "";
	const state = await send("state", { url });
	for (const role of state.palette) document.body.style.setProperty(`--${role.name}`, role.value.replace(/var\(--pshell-/g, "var(--"));
	document.documentElement.style.colorScheme = state.dark ? "dark" : "light";

	const restyle = document.getElementById("restyle");
	restyle.disabled = !/^(https?|file):/.test(url);
	restyle.addEventListener("click", async () => {
		await send("open");
		window.close();
	});

	const list = document.getElementById("styles");
	for (const style of state.styles.filter(style => style.matches)) {
		const row = document.createElement("button");
		row.className = `style ${style.on !== false ? "on" : "off"}`;
		const name = document.createElement("span");
		name.textContent = style.name;
		const toggle = document.createElement("i");
		toggle.className = "toggle";
		row.append(name, toggle);
		row.addEventListener("click", async () => {
			style.on = style.on === false;
			row.className = `style ${style.on ? "on" : "off"}`;
			await send("toggle", { id: style.id, on: style.on });
		});
		list.appendChild(row);
	}
}

show();
