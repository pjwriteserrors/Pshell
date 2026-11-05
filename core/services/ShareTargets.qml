pragma Singleton

import QtQuick
import Quickshell

// Where files can go from the shell, as menu entries (FileMenu's shape):
// mail, WhatsApp chats, the phone, other PCs, the clipboard. The file
// manager, the picture viewer and the screenshot editor offer the same
// list. `entries(paths)` for files that exist; with `prepare(done)` the
// file is made first (an edited picture rendered) and handed to done.
Singleton {
	id: root

	function entries(paths, prepare) {
		const out = [];
		// the file once it is there
		const withFiles = run => () => prepare ? prepare(path => run([path])) : run(paths);
		if (Plugins.on("mail") && Mail.accounts.length > 0) out.push({ label: "Mail", icon: "email_outline", run: withFiles(files => Files.mailFiles(files)) });
		if (Files.recentChats.length > 0) out.push({ label: "WhatsApp", icon: "whatsapp", children: () => Files.recentChats.map(chat => ({
			label: chat.name,
			icon: "account_outline",
			run: withFiles(files => Files.sendToChat(chat, files))
		})) });
		if (Phone.available) out.push({ label: Phone.name, icon: "cellphone_arrow_down", enabled: Phone.reachable, run: withFiles(files => files.forEach(path => Phone.shareFile(path))) });
		for (const pc of Pcs.reachable) out.push({ label: pc.name, icon: "laptop", run: withFiles(files => Pcs.sendFiles(pc.id, files)) });
		if (out.length > 0) out.push({ separator: true });
		out.push({ label: "Copy the file", icon: "content_copy", run: withFiles(files => {
			Quickshell.execDetached(["sh", "-c", 'printf "%s\\n" "$@" | sed "s|^|file://|" | wl-copy --type text/uri-list', "sh"].concat(files));
		}) });
		out.push({ label: "Copy the path", icon: "link_variant", enabled: !prepare, run: () => Quickshell.execDetached(["wl-copy", paths.join("\n")]) });
		return out;
	}
}
