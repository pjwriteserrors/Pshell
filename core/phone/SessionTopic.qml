import QtQuick
import Quickshell
import qs.core.services

// session: locked or not, and the power menu's actions.
Topic {
	id: topic

	name: "session"

	data: topic.wanted ? ({
		locked: Session.locked,
		host: Host.hostname,
		canLock: Plugins.on("lock-screen"),
		canPower: Plugins.on("power-menu")
	}) : null

	Timer {
		id: confirmTimeout

		property var callback: null

		interval: 61000
		onTriggered: if (callback) callback()
	}

	function call(action, args, done) {
		switch (action) {
		// from the daemon only, after it checked the phone's signature
		case "unlock":
			if (done.device !== "") throw new Error("Not allowed");
			if (!Plugins.on("phone-unlock")) throw new Error("Unlocking by phone is off");
			Session.unlock();
			return {};
		// the daemon asks whoever sits at the PC
		case "confirm": {
			if (done.device !== "") throw new Error("Not allowed");
			let answered = false;
			const answer = accepted => {
				if (answered) return;
				answered = true;
				done({ accepted: accepted });
			};
			Notifs.pushInternal("running", String(args.title || "Allow?"), String(args.body || ""), {
				icon: "cellphone",
				duration: 60000,
				actions: [
					{ label: String(args.accept || "Allow"), icon: "check", run: () => answer(true) },
					{ label: "No", icon: "close", run: () => answer(false) }
				]
			});
			confirmTimeout.callback = () => answer(false);
			confirmTimeout.restart();
			return topic.link.later;
		}
		// "where is my PC": every screen says so, with a sound
		case "find":
			if (!topic.link.allowed("phone.find")) throw new Error("Finding is off");
			Notifs.pushInternal("running", "Here I am", `${topic.link.name} is looking for this PC`, { icon: "monitor", duration: 15000 });
			Quickshell.execDetached(["sh", "-c", 'for i in 1 2 3; do pw-play /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null; done']);
			return {};
		case "lock":
			if (!Plugins.on("lock-screen")) throw new Error("The lock screen is off");
			Session.lock();
			return {};
		case "suspend":
		case "reboot":
		case "shutdown":
		case "logout":
			if (!Plugins.on("power-menu")) throw new Error("The power menu is off");
			if (action === "suspend") Quickshell.execDetached(["systemctl", "suspend"]);
			else Session.run(action);
			return {};
		}
		throw new Error("unknown-action");
	}
}
