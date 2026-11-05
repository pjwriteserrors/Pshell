pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Where a surface's file is, and compiling the surfaces ahead.
//
// A view named by its type in Surfaces.qml is compiled at every start with
// its whole tree, opened or not (Quickshell's qs: URLs never reach Qt's disk
// cache). View and ScreenView load it from its file instead, once it is
// wanted; a while after the start this compiles every surface whose plugin
// is on in the background, one after the other, so the first opening is as
// quick as before.
Singleton {
	id: root

	// the start is over: surfaces that are always built but not needed in
	// the first moment come now
	property bool started: false
	// … and after the start's processes, the compiling ahead
	property bool warming: false
	// name -> style/views replaces it
	property var replaced: ({})
	// view -> its component, compiled or compiling (holding it keeps it compiled)
	property var compiled: ({})
	property var known: []

	function url(view) {
		const name = view.split("/").pop();
		if (root.replaced[name] === undefined) {
			probe.path = `${Quickshell.shellDir}/style/views/${name}.qml`;
			root.replaced[name] = probe.text() !== "";
		}
		return root.replaced[name] ? Qt.resolvedUrl(`../../style/views/${name}.qml`) : Qt.resolvedUrl(`../views/${view}.qml`);
	}

	function register(entry) {
		root.known.push(entry);
		root.wake();
	}

	function wake() {
		if (root.warming && !compiling.running && !next.running) next.restart();
	}

	function compileNext() {
		const entry = root.known.find(item => item && item.available && root.compiled[item.view] === undefined);
		if (!entry) return;
		const component = Qt.createComponent(root.url(entry.view), Component.Asynchronous);
		root.compiled[entry.view] = component;
		if (component.status === Component.Loading) {
			compiling.component = component;
			compiling.running = true;
		} else {
			root.settle(component);
		}
	}

	function settle(component) {
		if (component.status === Component.Error) console.warn(`views: ${component.errorString()}`);
		next.restart();
	}

	FileView {
		id: probe

		blockAllReads: true
		printErrors: false
	}

	Timer {
		running: true
		interval: 2500
		onTriggered: root.started = true
	}

	Timer {
		running: true
		interval: 8000
		onTriggered: {
			root.warming = true;
			next.restart();
		}
	}

	// a breath between two, so the main thread's share of each comes first
	Timer {
		id: next

		interval: 150
		onTriggered: root.compileNext()
	}

	Connections {
		id: compiling

		property var component: null
		property bool running: false

		target: compiling.running ? compiling.component : null

		function onStatusChanged() {
			if (compiling.component.status === Component.Loading) return;
			const component = compiling.component;
			compiling.running = false;
			compiling.component = null;
			root.settle(component);
		}
	}
}
