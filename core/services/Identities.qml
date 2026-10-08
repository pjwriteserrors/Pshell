pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Made-up people to sign up with where an account is asked for and the real
// data is nobody's business (plugin `identities`). scripts/identity.py makes
// one: a person (randomuser.me), a mailbox (mail.tm) and a public phone
// number whose SMS can be read. What both receive is shown and kept, so it
// can still be read when the mailbox or the number is no longer there –
// then it says so and offers a new one.
//
// A new identity is a draft until it is saved, with a title that says what
// it was for; the next new one takes its place. Like Messages it hangs under
// the bar or lives in a window of its own (identities.json remembers which).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("identities")
	// whose names and addresses: a nationality of randomuser.me
	readonly property string nat: String(Host.profile.identities?.nat || "de")

	// [{ id, title, saved, created, first, last, username, password, birthday,
	//    street, postcode, city, state, country, picture,
	//    mail: { address, password, token, gone, messages: [{ id, from, address, subject, text, body, at, seen }] } | null,
	//    phone: { number, provider, url, country, gone, messages: [{ id, from, text, at }] } | null }]
	// newest first; at most one of them is not saved
	property var identities: []
	property string currentId: ""
	readonly property var current: root.identities.find(identity => identity.id === root.currentId) ?? null
	readonly property var saved: root.identities.filter(identity => identity.saved)

	// "card" (the current one) or "list" (the saved ones)
	property string view: "card"
	// the identity being made, and which of its parts are still on their way
	property string creatingId: ""
	property var pending: ({})
	readonly property bool creating: root.creatingId !== ""
	property bool failed: false
	// { "<id>:mail" | "<id>:phone": true } while a new one is fetched
	property var renewing: ({})
	readonly property bool renewBusy: Object.keys(root.renewing).length > 0
	// the identity whose inboxes are being read right now
	property string reading: ""
	property var queue: []
	property int ticks: 0
	// mail is looked for a while after the surface was closed: that is when
	// the sign-up form is being filled in
	property real awakeUntil: 0

	// a window of its own instead of the panel, and whether that window is up
	property bool windowed: false
	property bool windowOpen: false
	readonly property bool shown: root.windowed ? root.windowOpen : Popups.current === "identity"

	onShownChanged: {
		root.awakeUntil = Date.now() + 600000;
		if (!root.shown) return;
		root.check();
		root.poll(true);
	}

	// ── surface ───────────────────────────────────────────────────────────
	function open(view) {
		if (!root.enabled) return;
		root.view = view || (root.current ? "card" : "list");
		if (root.windowed) root.windowOpen = true;
		else Popups.withFocusedScreen(screen => Popups.open("identity", screen));
	}

	function close() {
		if (root.windowed) root.windowOpen = false;
		else if (Popups.current === "identity") Popups.close();
	}

	function toggle() {
		if (root.shown) root.close();
		else root.open("");
	}

	function popOut() {
		if (Popups.current === "identity") Popups.close();
		root.windowed = true;
		root.windowOpen = true;
		root.save();
	}

	function dock() {
		root.windowOpen = false;
		root.windowed = false;
		root.save();
		root.open(root.view);
	}

	// ── identities ────────────────────────────────────────────────────────
	function name(identity) {
		return identity ? `${identity.first ?? ""} ${identity.last ?? ""}`.trim() : "";
	}

	function label(identity) {
		return identity?.title || root.name(identity);
	}

	function patch(id, change) {
		root.identities = root.identities.map(identity => {
			if (identity.id !== id) return identity;
			const next = Object.assign({}, identity);
			change(next);
			return next;
		});
		root.save();
	}

	function show(id) {
		root.currentId = id;
		root.view = "card";
		root.save();
		root.poll(true);
	}

	// opens with a new one
	function create() {
		if (!root.enabled) return;
		root.open("card");
		if (root.creating) return;
		// the draft before it makes room
		for (const identity of root.identities)
			if (!identity.saved) root.forget(identity);
		const id = Date.now().toString(36);
		root.identities = [{ id: id, title: "", saved: false, created: Date.now(), first: "", last: "", mail: null, phone: null }].concat(root.saved);
		root.currentId = id;
		root.creatingId = id;
		root.failed = false;
		root.pending = { person: true, mail: true, phone: true };
		creator.exec(["python3", `${Paths.scripts}/identity.py`, "new", "--nat", root.nat, "--exclude", root.numbers()]);
	}

	function setTitle(id, title) {
		root.patch(id, identity => identity.title = title);
	}

	function setSaved(id, on) {
		root.patch(id, identity => identity.saved = on);
	}

	function remove(id) {
		const identity = root.identities.find(entry => entry.id === id);
		if (!identity) return;
		root.forget(identity);
		root.identities = root.identities.filter(entry => entry.id !== id);
		if (root.currentId === id) root.currentId = "";
		root.save();
	}

	// the mailbox is given back
	function forget(identity) {
		if (!identity.mail || identity.mail.gone) return;
		const asked = JSON.stringify({ address: identity.mail.address, password: identity.mail.password });
		Quickshell.execDetached(["sh", "-c", 'printf "%s\\n" "$1" | python3 "$2" forget', "sh", asked, `${Paths.scripts}/identity.py`]);
	}

	// numbers that are taken already
	function numbers() {
		return root.identities.filter(identity => identity.phone).map(identity => identity.phone.number).join(",");
	}

	function received(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		const id = root.creatingId;
		const left = Object.assign({}, root.pending);
		if (data.step === "person") {
			if (!data.ok) {
				// nobody to give a mailbox to
				root.identities = root.identities.filter(identity => identity.id !== id);
				root.currentId = root.saved[0]?.id ?? "";
				root.failed = true;
				return;
			}
			root.patch(id, identity => Object.assign(identity, data.person));
			left.person = false;
		} else if (data.step === "mail") {
			if (data.ok) root.patch(id, identity => identity.mail = Object.assign({ gone: false, messages: [] }, data.mail));
			left.mail = false;
		} else if (data.step === "phone") {
			if (data.ok) root.patch(id, identity => identity.phone = Object.assign({ gone: false, messages: [] }, data.phone));
			left.phone = false;
		}
		root.pending = left;
	}

	// a new mailbox or number for one whose old one is gone
	function renew(id, kind) {
		const identity = root.identities.find(entry => entry.id === id);
		const key = `${id}:${kind}`;
		if (!identity || root.renewing[key] || renewer.running) return;
		root.renewing = Object.assign({}, root.renewing, { [key]: true });
		renewer.target = id;
		renewer.kind = kind;
		if (kind === "mail") renewer.exec(["python3", `${Paths.scripts}/identity.py`, "mail", "--name", `${identity.first}.${identity.last}`]);
		else renewer.exec(["python3", `${Paths.scripts}/identity.py`, "phone", "--nat", root.nat, "--exclude", root.numbers()]);
	}

	function renewed(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (!data.ok || data.step !== renewer.kind) return;
		root.patch(renewer.target, identity => identity[data.step] = Object.assign({ gone: false, messages: [] }, data[data.step]));
	}

	// ── inboxes ───────────────────────────────────────────────────────────
	// what the current identity received; `now` also asks the number, which
	// is otherwise asked every other time (its site is not ours to hammer)
	function poll(now) {
		if (!root.enabled || !root.current || root.creating) return;
		root.ticks += 1;
		root.ask(root.currentId, root.shown && (now === true || root.ticks % 2 === 0));
	}

	// every saved one, now and then: is its mailbox, its number still there?
	function check() {
		const due = Date.now() - 6 * 3600000;
		for (const identity of root.saved)
			if (identity.id !== root.currentId && !(identity.checked > due)) root.ask(identity.id, true);
	}

	function ask(id, phone) {
		if (root.queue.some(entry => entry.id === id)) return;
		root.queue = root.queue.concat([{ id: id, phone: phone }]);
		root.next();
	}

	function next() {
		if (reader.running || root.queue.length === 0) return;
		const entry = root.queue[0];
		root.queue = root.queue.slice(1);
		const identity = root.identities.find(candidate => candidate.id === entry.id);
		const asked = {};
		if (identity?.mail && !identity.mail.gone) asked.mail = { address: identity.mail.address, password: identity.mail.password, token: identity.mail.token || "" };
		if (entry.phone && identity?.phone && !identity.phone.gone) asked.phone = { number: identity.phone.number, provider: identity.phone.provider, url: identity.phone.url };
		if (!asked.mail && !asked.phone) {
			root.next();
			return;
		}
		root.reading = entry.id;
		reader.asked = JSON.stringify(asked);
		reader.address = asked.mail?.address ?? "";
		reader.number = asked.phone?.number ?? "";
		reader.exec(["python3", `${Paths.scripts}/identity.py`, "inbox"]);
	}

	function answered(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		const id = root.reading;
		const fresh = [];
		root.patch(id, identity => {
			identity.checked = Date.now();
			// a mailbox or number that was replaced meanwhile is not this one
			if (data.mail && identity.mail?.address === reader.address) {
				const mail = Object.assign({}, identity.mail);
				if (data.mail.state === "gone") mail.gone = true;
				if (data.mail.state === "ok") {
					mail.token = data.mail.token;
					const known = {};
					for (const message of mail.messages) known[message.id] = message;
					for (const message of data.mail.messages)
						if (!known[message.id]) fresh.push(message);
					// what the mailbox no longer holds stays
					const there = data.mail.messages.map(message => known[message.id] ?? Object.assign({ seen: false, body: "" }, message));
					const ids = {};
					for (const message of there) ids[message.id] = true;
					mail.messages = there.concat(mail.messages.filter(message => !ids[message.id])).sort((a, b) => b.at - a.at).slice(0, 100);
				}
				identity.mail = mail;
			}
			if (data.phone && identity.phone?.number === reader.number) {
				const phone = Object.assign({}, identity.phone);
				if (data.phone.state === "gone") phone.gone = true;
				if (data.phone.state === "ok") {
					// an SMS has no time of its own, only "5 minutes ago": the
					// first time it is seen says when it came
					const known = {};
					for (const message of phone.messages) known[message.id] = message;
					const there = data.phone.messages.map(message => known[message.id] ?? message);
					const ids = {};
					for (const message of there) ids[message.id] = true;
					phone.messages = there.concat(phone.messages.filter(message => !ids[message.id])).sort((a, b) => b.at - a.at).slice(0, 40);
				}
				identity.phone = phone;
			}
		});
		if (!root.shown && id === root.currentId) root.announce(fresh);
	}

	// mail that came while the surface was closed
	function announce(messages) {
		for (const message of messages.slice(0, 3)) {
			const code = root.code(`${message.subject} ${message.text}`);
			Notifs.pushInternal("done", message.from || message.address, message.subject || message.text, {
				icon: "email_outline",
				duration: 15000,
				actions: (code !== "" ? [{ label: code, icon: "content_copy", run: () => root.copy(code) }] : []).concat([{ label: "Open", icon: "open_in_new", run: () => root.open("card") }])
			});
		}
	}

	// opens a mail: it is read, and its whole text fetched
	function read(id, mail) {
		const identity = root.identities.find(entry => entry.id === id);
		const message = identity?.mail?.messages.find(entry => entry.id === mail);
		if (!message) return;
		if (!message.seen) root.patch(id, entry => entry.mail = Object.assign({}, entry.mail, { messages: entry.mail.messages.map(candidate => candidate.id === mail ? Object.assign({}, candidate, { seen: true }) : candidate) }));
		if (message.body || identity.mail.gone || !identity.mail.token || opener.running) return;
		opener.target = id;
		opener.asked = JSON.stringify({ token: identity.mail.token, id: mail });
		opener.exec(["python3", `${Paths.scripts}/identity.py`, "message"]);
	}

	function opened(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (!data.id) return;
		// a mail whose text cannot be had is what its first lines say
		root.patch(opener.target, entry => entry.mail = Object.assign({}, entry.mail, { messages: entry.mail.messages.map(candidate => candidate.id === data.id ? Object.assign({}, candidate, { body: data.text || candidate.text }) : candidate) }));
	}

	function unread(identity) {
		return (identity?.mail?.messages ?? []).filter(message => !message.seen).length;
	}

	// the code a message is about, if it is about one
	function code(text) {
		if (!/code|kode|pin\b|otp|verif|bestätig|confirm|passw|sicherheit|security/i.test(text)) return "";
		const match = String(text).match(/(?:^|[^\w.,:\/-])(\d{3}[ -]\d{3}|\d{4,8})(?![\w\/-])/);
		return match ? match[1].replace(/[ -]/g, "") : "";
	}

	// "now", "5 min", "3 h", "2 d"
	function ago(at, now) {
		const minutes = Math.round((now - at) / 60000);
		if (minutes < 1) return "now";
		if (minutes < 60) return `${minutes} min`;
		if (minutes < 1440) return `${Math.floor(minutes / 60)} h`;
		return `${Math.floor(minutes / 1440)} d`;
	}

	function copy(text) {
		Quickshell.execDetached(["wl-copy", "--", String(text)]);
	}

	// the picture itself, to be pasted where one is asked for
	function copyPicture(identity) {
		if (!identity?.picture) return;
		Quickshell.execDetached(["sh", "-c", 'curl -fsSL -m 15 "$1" | wl-copy --type image/jpeg', "sh", identity.picture]);
	}

	// ── state ─────────────────────────────────────────────────────────────
	function save() {
		saver.restart();
	}

	Timer {
		id: saver

		interval: 300
		onTriggered: {
			store.setText(JSON.stringify({ windowed: root.windowed, current: root.currentId, identities: root.identities }, null, "\t") + "\n");
			// it holds the passwords
			Quickshell.execDetached(["chmod", "600", store.path]);
		}
	}

	FileView {
		id: store

		path: Paths.stateFile("identities.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.windowed = data.windowed === true;
				root.identities = Array.isArray(data.identities) ? data.identities : [];
				root.currentId = String(data.current || "");
			} catch (error) {}
		}
	}

	Process {
		id: creator

		stdout: SplitParser {
			onRead: line => root.received(line)
		}
		onExited: {
			root.creatingId = "";
			root.pending = ({});
			root.poll(true);
		}
	}

	Process {
		id: renewer

		property string target: ""
		property string kind: ""

		stdout: SplitParser {
			onRead: line => root.renewed(line)
		}
		onExited: {
			const left = Object.assign({}, root.renewing);
			delete left[`${renewer.target}:${renewer.kind}`];
			root.renewing = left;
			root.poll(true);
		}
	}

	Process {
		id: reader

		property string asked: ""
		property string address: ""
		property string number: ""

		stdinEnabled: true
		onStarted: reader.write(reader.asked + "\n")
		stdout: SplitParser {
			onRead: line => root.answered(line)
		}
		onExited: {
			root.reading = "";
			root.next();
		}
	}

	Process {
		id: opener

		property string target: ""
		property string asked: ""

		stdinEnabled: true
		onStarted: opener.write(opener.asked + "\n")
		stdout: SplitParser {
			onRead: line => root.opened(line)
		}
	}

	Timer {
		running: root.enabled && root.current !== null && (root.shown || Date.now() < root.awakeUntil)
		repeat: true
		interval: 15000
		onTriggered: {
			// `running` is only looked at again when something it reads changes
			if (!root.shown && Date.now() >= root.awakeUntil) root.awakeUntil = 0;
			else root.poll(false);
		}
	}
}
