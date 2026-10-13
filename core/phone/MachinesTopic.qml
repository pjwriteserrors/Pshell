import QtQuick
import Quickshell
import qs.core.services

// machines: the virtual machines of libvirt and the launch that runs. Looking
// from the phone counts as looking (Machines.remote), so the status is read
// although the popup is closed.
Topic {
	id: topic

	name: "machines"
	throttle: 200

	Binding {
		target: Machines
		property: "remote"
		value: true
		when: topic.wanted
		restoreMode: Binding.RestoreValue
	}

	onWantedChanged: if (topic.wanted) Machines.refresh()

	data: topic.wanted ? ({
		loaded: Machines.loaded,
		error: Machines.error,
		vms: Machines.vms.map(vm => ({
			name: String(vm.name),
			title: String(vm.title || vm.name),
			state: String(vm.state || ""),
			running: !!vm.running,
			family: String(vm.family || ""),
			cpus: Number(vm.cpus) || 0,
			memory: Number(vm.memory) || 0,
			gpu: String(vm.gpu || ""),
			lookingGlass: !!vm.lookingGlass,
			error: String(vm.error || "")
		})),
		target: Machines.target,
		step: Machines.step,
		steps: Machines.steps,
		failedStep: Machines.failedStep,
		failure: Machines.failure,
		remedy: Machines.remedy,
		launching: Machines.launching,
		busy: Machines.busy.map(entry => String(entry.mountpoint || "")),
		pending: Machines.pending,
		authorizing: Machines.authorizing
	}) : null

	function call(action, args, done) {
		const name = String(args.name || "");
		const machine = Machines.vm(name);
		switch (action) {
		case "refresh":
			Machines.refresh();
			return {};
		case "retry":
			Machines.retry();
			return {};
		case "dismiss":
			Machines.dismiss();
			return {};
		}
		if (!["launch", "display", "shutdown", "kill"].includes(action)) throw new Error("unknown-action");
		if (!machine) throw new Error("No such machine");
		switch (action) {
		case "launch":
			if (Machines.launching) throw new Error("A launch is running");
			Machines.launch(name);
			return {};
		// Looking Glass on the PC, for a machine that already runs
		case "display":
			if (!machine.running || !machine.lookingGlass) throw new Error("Nothing to show");
			if (Machines.launching) throw new Error("A launch is running");
			Machines.openDisplay(name);
			return {};
		case "shutdown":
			Machines.shutdown(name);
			return {};
		case "kill":
			Machines.kill(name);
			return {};
		}
		throw new Error("unknown-action");
	}
}
