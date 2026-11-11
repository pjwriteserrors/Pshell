// Where a site goes that the user agreed to keep away during focus time.
// "Trotzdem öffnen" lifts the block for that site and goes on.
const params = new URLSearchParams(location.search);
const url = params.get("u") || "";
const until = Number(params.get("until") || 0);
let host = "";
try {
	host = new URL(url).host.replace(/^www\./, "");
} catch (error) {}

document.getElementById("host").textContent = host;
document.getElementById("until").textContent = until > Date.now()
	? `Gesperrt bis ${new Date(until).toLocaleTimeString(navigator.language, { hour: "2-digit", minute: "2-digit" })}`
	: "Gesperrt";
document.getElementById("go").addEventListener("click", async () => {
	await browser.runtime.sendMessage({ pshell: "unblock", host });
	location.replace(url);
});
