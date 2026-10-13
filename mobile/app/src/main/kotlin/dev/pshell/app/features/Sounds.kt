package dev.pshell.app.features

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Icons
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PillSlider
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Toggle

// ── sounds: the shell's own sounds, not the mixer (that is Sound) ──────────
val SoundsFeature = Feature(
	id = "sounds",
	title = "Sounds",
	icon = "music_note",
	group = Group.Media,
	plugins = listOf("sounds"),
	keywords = listOf("sound pack", "töne", "klänge", "click", "notification", "benachrichtigung", "system sounds"),
	screen = { SoundsScreen() },
)

private val soundModes = listOf("all" to "All", "buttons" to "Buttons", "system" to "Automatic", "off" to "Off")

private val soundKinds = listOf("buttons" to "Buttons", "system" to "Automatic")

@Composable
private fun SoundsScreen() {
	val sounds = topic("sounds")
	val link = link
	var listOpen by remember { mutableStateOf(false) }
	Screen("Sounds") {
		if (sounds == null) {
			EmptyState("music_note", "Loading…")
			return@Screen
		}
		Segmented(soundModes, sounds["mode"].string, Modifier.fillMaxWidth()) { link.run("sounds", "mode", json("mode" to it)) }
		val volume = sounds["volume"].float
		PillSlider(volume, icon = if (volume < 0.01f) "volume_off" else if (volume < 0.5f) "volume_medium" else "volume_high", label = "${Math.round(volume * 100)}%") {
			link.run("sounds", "volume", json("volume" to it))
		}
		SoftButton("Play on the PC", Modifier.fillMaxWidth(), icon = "play") { link.run("sounds", "preview", json("id" to "notification")) }
		Panel(padding = PaddingValues(6.dp)) {
			ListRow("Quiet during do not disturb", icon = "bell_off") {
				Toggle(sounds["quietDnd"].bool) { link.run("sounds", "quietDnd", json("on" to it)) }
			}
		}

		val packs = sounds["packs"].list
		if (packs.isNotEmpty()) {
			SectionLabel("Sound pack")
			Panel(padding = PaddingValues(6.dp)) {
				for (pack in packs) {
					val picked = pack["id"].string == sounds["pack"].string
					ListRow(
						pack["name"].string,
						icon = "music_note",
						subtitle = pack["author"].string,
						iconBackground = if (picked) Theme.colors.primary else Theme.colors.layer3,
						iconTint = if (picked) Theme.colors.onPrimary else Theme.colors.text,
						onClick = { if (!picked) link.run("sounds", "pack", json("id" to pack["id"].string)) },
					) {
						if (picked) Glyph("check", size = 20.dp, color = Theme.colors.primary)
					}
				}
			}
		}

		SectionLabel("Every sound")
		Panel(padding = PaddingValues(6.dp)) {
			ListRow("Single sounds", icon = "tune_variant", onClick = { listOpen = !listOpen }) {
				Glyph(if (listOpen) "chevron_up" else "chevron_down", size = 20.dp, color = Theme.colors.textSubtle)
			}
		}
		if (listOpen) {
			for ((kind, title) in soundKinds) {
				val moments = sounds["moments"].list.filter { it["kind"].string == kind }
				if (moments.isEmpty()) continue
				SectionLabel(title)
				Panel(padding = PaddingValues(6.dp)) {
					for (moment in moments) {
						ListRow(moment["title"].string, icon = moment["icon"].string.takeIf { Icons.has(it) }) {
							Toggle(moment["on"].bool) { link.run("sounds", "moment", json("id" to moment["id"].string, "on" to it)) }
						}
					}
				}
			}
			if (sounds["modified"].bool) SoftButton("Reset", Modifier.fillMaxWidth(), icon = "refresh") { link.run("sounds", "reset") }
		}
	}
}
