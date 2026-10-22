pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Polkit

// The shell as the session's polkit agent (plugin `polkit`): when a program
// asks for an administrator's password (pkexec, a mount, a system setting),
// the shell asks for it (views/overlays/PolkitDialog.qml). Only one agent can
// be registered per session: with another one running (lxqt-policykit-agent
// and the like) this one stays unregistered.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("polkit")
	property var agent: null
	readonly property var flow: root.agent?.flow ?? null
	readonly property bool active: !!root.agent && root.agent.isActive && root.flow !== null
	readonly property bool registered: !!root.agent && root.agent.isRegistered

	function sync() {
		if (root.enabled && !root.agent) root.agent = agentComponent.createObject(root);
		else if (!root.enabled && root.agent) {
			root.agent.destroy();
			root.agent = null;
		}
	}

	function submit(password) {
		if (root.flow && root.flow.isResponseRequired) root.flow.submit(String(password));
	}

	function cancel() {
		if (root.flow) root.flow.cancelAuthenticationRequest();
	}

	onEnabledChanged: root.sync()
	Component.onCompleted: root.sync()

	Component {
		id: agentComponent

		PolkitAgent {
			onAuthenticationRequestStarted: Sounds.play("attention")
		}
	}
}
