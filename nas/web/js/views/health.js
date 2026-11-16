// Health: the Pi's temperature and power, the SD card's wear, the SSD's
// SMART, the disk, memory and load, the containers.
import { h, icon, clear, size as fmtSize, uptime, plural, when } from "../util.js";
import * as api from "../api.js";
import { ring, rollText, stagger, animate } from "../motion.js";
import { toast, errorToast } from "../ui.js";

const history = [];

export default function health(route, app) {
	const warnings = h("div.health-warnings");
	const grid = h("div.health-grid");
	const refreshBtn = h("button.btn.small.ghost", icon("refresh"), "Read again");
	const stamp = h("span.subtle");
	const page = h("div.page",
		h("div.page-head", h("div", h("h1", "Health"), h("div.subtle", "How the Pi and its disks are doing.")), h("div.page-tools", stamp, refreshBtn)),
		warnings,
		grid);
	const root = h("div.page-scroll", page);
	let built = false;
	const cards = {};

	function card(key, title, iconName) {
		if (cards[key]) return cards[key];
		const body = h("div.health-body");
		const el = h("div.health-card", h("h3", icon(iconName), title), body);
		el.body = body;
		cards[key] = el;
		grid.appendChild(el);
		return el;
	}

	function kv(rows) {
		return h("div.kv-list", rows.filter(Boolean).map(([k, v, tone]) => h(`div.kv-row${tone ? "." + tone : ""}`, h("span.subtle", k), h("span", v))));
	}

	async function load(fresh) {
		refreshBtn.classList.add("busy");
		try {
			const data = await api.get("/api/health", { fresh: fresh ? 1 : undefined });
			if (data.temp !== null && data.temp !== undefined) {
				history.push({ t: Date.now(), v: data.temp });
				while (history.length > 120) history.shift();
			}
			render(data);
			stamp.textContent = data.at ? `as of ${when(data.at)}` : "";
		} catch (error) {
			clear(grid).appendChild(h("div.empty", icon("heart_pulse"), h("h3", "No health data"), h("p", error.message)));
		} finally {
			refreshBtn.classList.remove("busy");
		}
	}

	function render(d) {
		clear(warnings);
		for (const w of d.warnings || []) warnings.appendChild(h("div.warn-box.danger-box", { style: { marginBottom: "10px" } }, icon("alert_outline"), h("div", h("strong", w))));
		if (!d.warnings?.length) warnings.appendChild(h("div.warn-box", { style: { marginBottom: "14px", background: "var(--success-soft)" } }, icon("check_circle_outline"), h("div", "All good – nothing to worry about.")));
		warnings.querySelectorAll(".warn-box > .i").forEach(i => d.warnings?.length || (i.style.color = "var(--success)"));

		// temperature: a gauge from 30 to 85 °C and the last readings
		const temp = card("temp", "Temperature", "thermometer");
		if (!temp.ring) {
			temp.ring = ring(0, { size: 150, stroke: 12 });
			temp.value = h("strong", "–");
			temp.spark = h("div.spark-wrap");
			temp.body.append(h("div.gauge", temp.ring, h("div.gauge-value", temp.value, h("span", "°C"))), temp.spark);
		}
		if (d.temp !== null && d.temp !== undefined) {
			const p = Math.max(0, Math.min(1, (d.temp - 30) / 55));
			temp.ring.set(p, d.temp >= 75 ? "var(--danger)" : d.temp >= 62 ? "var(--warning)" : "var(--success)");
			rollText(temp.value, d.temp.toFixed(1));
			temp.classList.toggle("bad", d.temp >= 75);
			temp.classList.toggle("warn", d.temp >= 62 && d.temp < 75);
		} else {
			temp.value.textContent = "–";
		}
		clear(temp.spark).appendChild(sparkline(history.map(x => x.v)));

		// power and throttling
		const t = d.throttled;
		const power = card("power", "Power", "flash");
		clear(power.body).appendChild(t ? h("div.flag-row",
			flag("Undervoltage now", t.undervoltage),
			flag("Throttled now", t.throttled),
			flag("Frequency capped", t.capped),
			flag("Soft temperature limit", t.soft_temp),
			flag("Undervoltage since boot", t.undervoltage_past),
			flag("Throttled since boot", t.throttled_past)) : h("div.subtle", "Not a Raspberry Pi here (dev mode) – no power flags."));
		power.classList.toggle("bad", !!t?.undervoltage);
		if (t?.raw) power.body.appendChild(h("div.subtle", { style: { fontSize: "var(--fs-small)" } }, `get_throttled = ${t.raw}`));

		// the SD card
		const sd = d.sd || {};
		const sdCard = card("sd", "SD card", "usb_flash_drive_outline");
		if (!sdCard.ring) {
			sdCard.ring = ring(0, { size: 80, stroke: 8 });
			sdCard.value = h("strong", "–");
			sdCard.facts = h("div");
			sdCard.body.append(h("div", { style: { display: "flex", alignItems: "center", gap: "16px" } }, h("div.gauge", sdCard.ring, h("div.gauge-value", sdCard.value, h("span", "used"))), sdCard.facts));
		}
		if (sd.life_used !== null && sd.life_used !== undefined) {
			sdCard.ring.set(sd.life_used / 100, sd.life_used >= 80 ? "var(--danger)" : sd.life_used >= 50 ? "var(--warning)" : "var(--primary)");
			rollText(sdCard.value, `${sd.life_used}%`);
		}
		clear(sdCard.facts).appendChild(kv([
			["Present", sd.present === false ? "No" : "Yes"],
			["Wear", sd.life_used !== null && sd.life_used !== undefined ? `${sd.life_used} % of its life` : "unknown"],
			["Pre-EOL", sd.pre_eol || "unknown", sd.pre_eol === "normal" ? "good" : sd.pre_eol ? "bad" : ""]
		]));

		// the SSD
		const ssd = d.ssd || {};
		const ssdCard = card("ssd", "SSD", "harddisk");
		ssdCard.classList.toggle("bad", ssd.passed === false || ssd.present === false);
		const smart = ssd.smart || {};
		clear(ssdCard.body).appendChild(kv([
			["Model", ssd.model || (ssd.present === false ? "Gone!" : "unknown")],
			ssd.device ? ["Device", ssd.device] : null,
			["SMART", ssd.passed === true ? "Passed" : ssd.passed === false ? "FAILED" : "not read", ssd.passed === true ? "good" : ssd.passed === false ? "bad" : ""],
			ssd.temp ? ["Temperature", `${ssd.temp} °C`, ssd.temp > 60 ? "bad" : ""] : null,
			ssd.hours ? ["Powered on", `${Number(ssd.hours).toLocaleString("en-US")} h`] : null,
			smart.reallocated !== undefined ? ["Reallocated sectors", String(smart.reallocated), smart.reallocated > 0 ? "bad" : "good"] : null,
			smart.pending !== undefined ? ["Pending sectors", String(smart.pending), smart.pending > 0 ? "bad" : "good"] : null,
			smart.wear_level !== undefined ? ["Wear level", String(smart.wear_level)] : null,
			smart.percent_used !== undefined ? ["Life used", `${smart.percent_used} %`] : null,
			smart.media_errors !== undefined ? ["Media errors", String(smart.media_errors), smart.media_errors > 0 ? "bad" : "good"] : null
		]));

		// the data disk
		const disk = d.disk || {};
		const diskCard = card("disk", "Data disk", "database_outline");
		const used = disk.total ? (disk.used ?? disk.total - disk.free) / disk.total : 0;
		clear(diskCard.body).append(
			h("div.stat-line", h("span.stat-big", fmtSize(disk.free)), h("span.stat-unit", "free")),
			h(`div.bar${used > 0.9 ? ".bad" : used > 0.75 ? ".warn" : ""}`, h("i", { style: { width: `${Math.round(used * 100)}%` } })),
			h("div.subtle", `${fmtSize(disk.used ?? disk.total - disk.free)} of ${fmtSize(disk.total)} used (${Math.round(used * 100)} %)`));

		// memory, load, uptime
		const sys = card("sys", "System", "memory");
		const mem = d.mem || {};
		const memUsed = mem.total ? (mem.total - mem.available) / mem.total : 0;
		clear(sys.body).append(
			h("div.subtle", "Memory"),
			h(`div.bar${memUsed > 0.9 ? ".bad" : memUsed > 0.75 ? ".warn" : ""}`, h("i", { style: { width: `${Math.round(memUsed * 100)}%` } })),
			kv([
				mem.total ? ["Memory", `${fmtSize(mem.total - mem.available)} of ${fmtSize(mem.total)}`] : null,
				d.load ? ["Load", d.load.map(x => x.toFixed(2)).join(" · ")] : null,
				d.uptime ? ["Up for", uptime(d.uptime)] : null
			]));

		// containers
		const box = card("containers", "Containers", "docker");
		clear(box.body);
		if (!d.containers?.length) box.body.appendChild(h("div.subtle", "No docker here (or no socket)."));
		for (const c of d.containers || []) box.body.appendChild(h("div.container-row", h(`span.live-dot.${c.state === "running" ? "running" : "exited"}`), h("div.grow", h("div.ellipsis", h("strong", c.name)), h("div.subtle.ellipsis", c.image)), h("span.subtle", c.status)));

		if (!built) {
			built = true;
			stagger(grid.children, { step: 50, distance: 16 });
		}
	}

	function flag(label, on) {
		return h(`span.chip${on ? ".bad" : ".good"}`, icon(on ? "alert_circle_outline" : "check"), label);
	}

	refreshBtn.addEventListener("click", () => load(true));
	const off = api.on("health", () => load());
	const timer = setInterval(() => document.visibilityState === "visible" && load(), 20000);
	load();
	return { el: root, title: "Health", icon: "heart_pulse", unmount() {
		off();
		clearInterval(timer);
	} };
}

function sparkline(values) {
	const W = 260;
	const H = 48;
	const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
	svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
	svg.setAttribute("preserveAspectRatio", "none");
	svg.setAttribute("class", "spark");
	if (values.length < 2) return h("div.subtle", { style: { fontSize: "var(--fs-small)", textAlign: "center" } }, "The line grows while this page is open");
	const min = Math.min(...values) - 1;
	const max = Math.max(...values) + 1;
	const pts = values.map((v, i) => [(i / (values.length - 1)) * W, H - ((v - min) / (max - min)) * (H - 4) - 2]);
	const d = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(" ");
	svg.innerHTML = `<defs><linearGradient id="spark-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="var(--primary)" stop-opacity=".5"/><stop offset="1" stop-color="var(--primary)" stop-opacity="0"/></linearGradient></defs><path class="area" d="${d} L${W} ${H} L0 ${H} Z"/><path class="line" d="${d}"/>`;
	return svg;
}
