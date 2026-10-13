package dev.pshell.app.features

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PillSlider
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Segmented

// ── lighting: what the OpenRGB devices of the PC show ──────────────────────
val LightingFeature = Feature(
	id = "lighting",
	title = "Lighting",
	icon = "led_strip_variant",
	group = Group.Pc,
	// either of the two brings it; the topic says whether it is there
	anyPlugins = listOf("hook-openrgb", "hook-openrgb-leds"),
	keywords = listOf("openrgb", "rgb", "led", "licht", "beleuchtung", "keyboard", "tastatur", "ambient"),
	screen = { LightingScreen() },
)

private val modeTitles = mapOf("wallpaper" to "Wallpaper", "live" to "Live", "off" to "Off")

private val kindIcons = mapOf(
	"keyboard" to "keyboard", "gpu" to "expansion_card", "fans" to "fan", "strip" to "led_strip_variant",
	"memory" to "memory", "mouse" to "mouse", "headset" to "headphones", "light" to "lightbulb",
)

@Composable
private fun LightingScreen() {
	val lighting = topic("lighting")
	val link = link
	val on = lighting["enabled"].bool
	Screen("Lighting", actions = {
		if (on) IconButton("refresh", color = Theme.colors.layer2, enabled = !lighting["scanning"].bool) { link.run("lighting", "scan") }
	}) {
		if (lighting == null) {
			EmptyState("led_strip_variant", "Loading…")
			return@Screen
		}
		if (!on) {
			EmptyState("toggle_switch_off_outline", "Switched off")
			return@Screen
		}
		val devices = lighting["devices"].list
		val modes = lighting["modeNames"].list.map { it.string to (modeTitles[it.string] ?: it.string) }
		if (devices.isEmpty()) EmptyState(
			"led_strip_variant",
			if (!lighting["scanned"].bool || lighting["scanning"].bool) "Looking for devices…" else if (lighting["server"].bool) "No devices" else "OpenRGB does not answer",
		)
		for (device in devices) {
			val mode = device["mode"].string
			val lit = device["present"].bool && mode != "off"
			Panel {
				Row(verticalAlignment = Alignment.CenterVertically) {
					Glyph(kindIcons[device["kind"].string] ?: "led_strip_variant", size = 20.dp, color = if (lit) Theme.colors.primary else Theme.colors.textMuted)
					Spacer(Modifier.width(10.dp))
					Column(Modifier.weight(1f)) {
						Label(device["name"].string, style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold))
						if (!device["present"].bool) Label("Not plugged in", style = Theme.Type.small, color = Theme.colors.textMuted)
					}
				}
				Spacer(Modifier.height(10.dp))
				Segmented(modes, mode, Modifier.fillMaxWidth()) { link.run("lighting", "mode", json("id" to device["id"].string, "mode" to it)) }
			}
		}

		SectionLabel("Mirrored monitor")
		val output = lighting["output"].string
		Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			Chip("Largest", icon = "monitor", active = output.isEmpty()) { link.run("lighting", "output", json("name" to "")) }
			for (name in lighting["outputs"].list.map { it.string }) {
				Chip(name, active = name.equals(output, ignoreCase = true)) { link.run("lighting", "output", json("name" to name)) }
			}
		}
		SectionLabel("Frames per second")
		Segmented(listOf(5, 10, 15, 30).map { it to it.toString() }, lighting["fps"].int, Modifier.fillMaxWidth()) { link.run("lighting", "fps", json("fps" to it)) }
		// the PC keeps at most 95 %; in steps of five like its own slider
		val smoothing = lighting["smoothing"].float
		PillSlider(smoothing / 0.9f, icon = "blur", label = "Smoothing ${Math.round(smoothing * 100)}%") {
			link.run("lighting", "smoothing", json("value" to Math.round(it * 18) / 20.0))
		}
	}
}
