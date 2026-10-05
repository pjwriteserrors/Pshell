package dev.pshell.app.features

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.double
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.list
import dev.pshell.app.link.present
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Meter
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.Ring
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sparkline
import kotlinx.serialization.json.JsonElement

val SystemFeature = Feature(
	id = "system",
	title = "System",
	icon = "chip",
	plugins = listOf("system-monitor"),
	card = { open -> SystemCard(open) },
	screen = { SystemScreen() },
)

private fun storage(kib: Double): String {
	val gib = kib / 1024.0 / 1024.0
	return if (gib >= 10) "%.0f GB".format(gib) else "%.1f GB".format(gib)
}

@Composable
private fun SystemCard(open: () -> Unit) {
	val system = topic("system") ?: return
	Panel(onClick = open) {
		Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
			Gauge("CPU", system["cpu"].float, Theme.colors.primary)
			Gauge("RAM", system["memory"].float, Theme.colors.secondary)
			Sparkline(system["cpuHistory"].list.map { it.float }, Modifier.weight(1f).height(44.dp))
			Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
		}
	}
}

@Composable
private fun Gauge(name: String, value: Float, color: Color) {
	Row(verticalAlignment = Alignment.CenterVertically) {
		Ring(value, size = 48.dp, thickness = 5.dp, color = color) {
			Label("${Math.round(value * 100)}", style = Theme.Type.label.copy(fontFeatureSettings = "tnum"))
		}
		Spacer(Modifier.width(8.dp))
		Label(name, style = Theme.Type.tiny, color = Theme.colors.textMuted)
	}
}

@Composable
private fun Graph(icon: String, title: String, detail: String, value: Float, history: List<Float>, color: Color) {
	Panel(padding = PaddingValues(0.dp)) {
		Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 18.dp, top = 14.dp), verticalAlignment = Alignment.CenterVertically) {
			Glyph(icon, size = 22.dp, color = color)
			Spacer(Modifier.width(12.dp))
			Column(Modifier.weight(1f)) {
				Label(title, style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold))
				if (detail.isNotEmpty()) Label(detail, style = Theme.Type.small, color = Theme.colors.textMuted)
			}
			Label("${Math.round(value * 100)}%", style = Theme.Type.display.copy(fontFeatureSettings = "tnum"))
		}
		Sparkline(history, Modifier.fillMaxWidth().height(72.dp).padding(top = 8.dp), color = color)
	}
}

@Composable
private fun SystemScreen() {
	val system = topic("system")
	val session = topic("session")
	Screen("System", subtitle = session["host"].string) {
		if (system == null) {
			dev.pshell.app.ui.widgets.EmptyState("chip", "No numbers yet", text = "They arrive while the PC is connected.")
			return@Screen
		}
		Graph("chip", "Processor", system["cores"].int.takeIf { it > 0 }?.let { "$it cores" } ?: "", system["cpu"].float, system["cpuHistory"].list.map { it.float }, Theme.colors.primary)
		Graph("memory", "Memory", "${storage(system["memoryUsed"].double)} / ${storage(system["memoryTotal"].double)}", system["memory"].float, system["memoryHistory"].list.map { it.float }, Theme.colors.secondary)
		val disks = system["disks"].list
		if (disks.isNotEmpty()) {
			SectionLabel("Disks")
			Panel {
				Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
					for (disk in disks) Disk(disk)
				}
			}
		}
		if (system["battery"].present || system["mouse"].present) {
			SectionLabel("Power")
			Panel {
				Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
					system["battery"]?.let { battery ->
						Level(if (battery["charging"].float > 0f) "battery_charging" else "battery", "Battery", "${battery["percent"].int}%", battery["percent"].float / 100f)
					}
					system["mouse"]?.let { mouse -> Level("mouse", mouse["name"].string, mouse["text"].string, mouse["level"].float) }
				}
			}
		}
	}
}

@Composable
private fun Disk(disk: JsonElement) {
	val usage = disk["usage"].float
	Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Glyph("harddisk", size = 18.dp, color = Theme.colors.textMuted)
			Spacer(Modifier.width(8.dp))
			Label(disk["name"].string, Modifier.weight(1f), style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold))
			Label("${disk["freeText"].string} free of ${disk["totalText"].string}", style = Theme.Type.small, color = Theme.colors.textMuted)
		}
		Meter(usage, color = if (usage > 0.9f) Theme.colors.danger else Theme.colors.primary)
	}
}

@Composable
private fun Level(icon: String, title: String, text: String, value: Float) {
	Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Glyph(icon, size = 18.dp, color = Theme.colors.textMuted)
			Spacer(Modifier.width(8.dp))
			Label(title, Modifier.weight(1f), style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold))
			Label(text, style = Theme.Type.small, color = Theme.colors.textMuted)
		}
		Meter(value, color = if (value < 0.2f) Theme.colors.danger else Theme.colors.success)
	}
}
