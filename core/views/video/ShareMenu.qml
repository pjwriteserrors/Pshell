pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.core.services
import qs.core.views.files

// Where the video goes: the shell's one list of places (ShareTargets, as the
// picture viewer and Files have it) – only WhatsApp is its own here, since a
// video over 16 MB would not get through: it is made smaller first, beside
// the original, and that one is sent. Fill the window with it, then
// popup(x, y) under the button.
FileMenu {
	id: root

	property string path: ""
	// what WhatsApp still takes
	readonly property int whatsAppMb: 16

	function popup(x, y) {
		if (root.path === "") return;
		root.show(root.entries(), x, y);
	}

	function entries() {
		const path = root.path;
		const out = [];
		if (Files.recentChats.length > 0) out.push({ label: "Send in WhatsApp", icon: "whatsapp", children: () => Files.recentChats.map(chat => ({
			label: chat.name,
			icon: "account_outline",
			run: () => root.sendToChat(chat, path)
		})) });
		// the rest as everywhere: mail, the phone, other PCs, the clipboard
		for (const entry of ShareTargets.entries([path]))
			if (entry.label !== "WhatsApp") out.push(entry);
		out.push({ label: "Show in Files", icon: "folder_open_outline", run: () => Files.reveal([path]) });
		return out;
	}

	// small enough as it is, or made so first (the job shows how far it is)
	function sendToChat(chat, path) {
		const size = Video.metas[path]?.size ?? 0;
		const send = bytes => {
			if (bytes > 0 && bytes <= root.whatsAppMb * 1e6) return Files.sendToChat(chat, [path]);
			Video.say(`Making it smaller for WhatsApp first – then it goes to ${chat.name}`, "whatsapp");
			Video.shrink(path, root.whatsAppMb, file => {
				if (file) Files.sendToChat(chat, [file]);
				else Video.say("It could not be made small enough for WhatsApp", "alert_circle_outline");
			});
		};
		if (size > 0) return send(size);
		Video.probe(path, data => send(data?.size ?? 0));
	}
}
