pragma Singleton

import QtQuick
import Quickshell

// What the Messages panel can show. Each provider is a plugin of its own,
// with a second one for its notifications.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("messages")

	// [{ id, name, icon, notifications, unread }]
	readonly property var providers: [
		{ id: "mail", name: "Mail", icon: "email_outline", notifications: "mail-notifications", unread: Mail.unread }
	].filter(provider => Plugins.on(provider.id))
	readonly property int unread: root.enabled ? root.providers.reduce((sum, provider) => sum + provider.unread, 0) : 0

	property string current: "mail"
	readonly property var provider: root.providers.find(provider => provider.id === root.current) ?? root.providers[0] ?? null
}
