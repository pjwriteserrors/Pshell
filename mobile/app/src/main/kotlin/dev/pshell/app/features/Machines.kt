package dev.pshell.app.features

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Confirm
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SoftButton
import kotlinx.serialization.json.JsonElement

// ── machines: the virtual machines of libvirt on the PC ────────────────────
val MachinesFeature = Feature(
	id = "machines",
	title = "Virtual machines",
	icon = "microsoft_windows",
	group = Group.Pc,
	plugins = listOf("vm-launcher"),
	keywords = listOf("vm", "windows", "libvirt", "qemu", "kvm", "looking glass", "virtuelle maschine", "starten"),
	screen = { MachinesScreen() },
)

private val stepTitles = mapOf("storage" to "Drive", "start" to "Machine", "display" to "Looking Glass")

/** What is asked before a machine goes off. */
private class PowerOff(val machine: JsonElement, val action: String)

private fun specsOf(machine: JsonElement): String = listOf(
	machine["cpus"].int.let { if (it > 0) "$it threads" else "" },
	machine["memory"].double.let { if (it > 0) "${Math.round(it)} GB" else "" },
	machine["gpu"].string.removePrefix("GeForce "),
).filter { it.isNotEmpty() }.joinToString(" · ")

@Composable
private fun MachinesScreen() {
	val machines = topic("machines")
	val link = link
	var asking by remember { mutableStateOf<PowerOff?>(null) }
	val vms = machines["vms"].list
	Screen("Virtual machines") {
		if (machines == null) EmptyState("microsoft_windows", "Loading…")
		else if (!machines["loaded"].bool) EmptyState("microsoft_windows", "Looking for machines")
		else if (vms.isEmpty()) EmptyState("monitor_off", if (machines["error"].string.isNotEmpty()) "libvirt does not answer" else "No virtual machines")
		for (machine in vms) {
			val name = machine["name"].string
			val running = machine["running"].bool
			val pending = machines["pending"][name].string
			// a launch that went through is over: the machine just runs
			val step = if (machines["target"].string == name && machines["step"].string != "done") machines["step"].string else ""
			val failed = step == "failed"
			val launching = step.isNotEmpty() && !failed
			Panel {
				Row(verticalAlignment = Alignment.CenterVertically) {
					Glyph(if (machine["family"].string == "windows") "microsoft_windows" else "monitor", size = 24.dp, color = if (running || launching) Theme.colors.primary else Theme.colors.textMuted)
					Spacer(Modifier.width(12.dp))
					Column(Modifier.weight(1f)) {
						Label(machine["title"].string, style = Theme.Type.title)
						Label(
							when {
								machine["error"].string.isNotEmpty() -> machine["error"].string
								failed -> "Launch stopped"
								launching -> "Launching"
								pending == "shutdown" -> "Shutting down"
								pending == "kill" -> "Turning off"
								running -> if (machine["state"].string == "paused") "Paused" else "Running"
								else -> "Off"
							},
							style = Theme.Type.small, color = if (failed) Theme.colors.danger else Theme.colors.textMuted,
						)
					}
				}
				val specs = specsOf(machine)
				if (specs.isNotEmpty()) {
					Spacer(Modifier.height(8.dp))
					Label(specs, style = Theme.Type.small, color = Theme.colors.textSubtle)
				}
				if (step.isNotEmpty()) {
					val steps = machines["steps"].list.map { it.string }
					val at = steps.indexOf(if (failed) machines["failedStep"].string else step)
					Spacer(Modifier.height(12.dp))
					Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
						steps.forEachIndexed { index, id ->
							Chip(
								stepTitles[id] ?: id,
								icon = if (index < at) "check" else if (index == at && failed) "alert_circle_outline" else null,
								active = index == at && !failed,
								tint = if (index == at && failed) Theme.colors.danger else null,
							)
						}
					}
				}
				if (failed) {
					Spacer(Modifier.height(10.dp))
					Label(machines["failure"].string, color = Theme.colors.danger, maxLines = 4)
					val remedy = when {
						machines["authorizing"].bool -> "Confirm on the PC"
						machines["remedy"].string == "busy" -> machines["busy"].list.joinToString("\n") { "${it.string} has to be unmounted first" }
						else -> ""
					}
					if (remedy.isNotEmpty()) Label(remedy, style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 4)
					Spacer(Modifier.height(12.dp))
					Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
						PrimaryButton("Try again", Modifier.weight(1f), icon = "refresh") { link.run("machines", "retry") }
						SoftButton("Dismiss", Modifier.weight(1f).padding(vertical = 4.dp)) { link.run("machines", "dismiss") }
					}
				} else if (!launching && pending.isEmpty() && machine["error"].string.isEmpty()) {
					Spacer(Modifier.height(12.dp))
					if (!running) PrimaryButton("Start", Modifier.fillMaxWidth(), icon = "play", enabled = !machines["launching"].bool) { link.run("machines", "launch", json("name" to name)) }
					else {
						Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
							SoftButton("Shut down", Modifier.weight(1f), icon = "power") { asking = PowerOff(machine, "shutdown") }
							SoftButton("Force off", Modifier.weight(1f), icon = "power_plug_off", tint = Theme.colors.danger) { asking = PowerOff(machine, "kill") }
						}
						if (machine["lookingGlass"].bool && !machines["launching"].bool) {
							Spacer(Modifier.height(8.dp))
							SoftButton("Show on the PC", Modifier.fillMaxWidth(), icon = "monitor_share") { link.run("machines", "display", json("name" to name)) }
						}
					}
				}
			}
		}
	}
	asking?.let { ask ->
		val title = ask.machine["title"].string
		val kill = ask.action == "kill"
		Confirm(
			if (kill) "Force off" else "Shut down",
			if (kill) "Turn $title off at once? What is not saved in it is lost." else "Shut $title down?",
			confirm = if (kill) "Force off" else "Shut down",
			danger = kill,
			onDismiss = { asking = null },
		) {
			link.run("machines", ask.action, json("name" to ask.machine["name"].string))
		}
	}
}
