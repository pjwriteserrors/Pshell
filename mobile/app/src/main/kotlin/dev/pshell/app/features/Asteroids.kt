package dev.pshell.app.features

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import kotlinx.serialization.json.JsonElement

// ── asteroids: what passes the earth this week ─────────────────────────────
val AsteroidsFeature = Feature(
	id = "asteroids",
	title = "Asteroids",
	icon = "meteor",
	group = Group.Work,
	plugins = listOf("asteroids"),
	keywords = listOf("asteroiden", "space", "weltraum", "nasa", "sky", "himmel"),
	summary = { topic("asteroids").let { asteroids -> asteroids["objects"].list.firstOrNull { it["des"].string == asteroids["next"].string }["when"].string } },
	screen = { AsteroidsScreen() },
)

/** What it takes to see something that faint. */
private fun aid(magnitude: Double): String = if (magnitude <= 6) "naked eye" else if (magnitude <= 10) "binoculars" else "telescope"

@Composable
private fun AsteroidsScreen() {
	val asteroids = topic("asteroids")
	val objects = asteroids["objects"].list
	val sightings = asteroids["sightings"].list
	Screen("Asteroids") {
		if (objects.isEmpty()) {
			EmptyState("meteor", if (asteroids == null) "Loading…" else "No asteroids yet")
			return@Screen
		}
		objects.firstOrNull { it["des"].string == asteroids["next"].string }?.let { next ->
			Panel {
				Label(next["name"].string, style = Theme.Type.heading)
				Label("${next["when"].string} · ${next["moment"].string}", style = Theme.Type.body.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
				Spacer(Modifier.height(14.dp))
				Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					for ((icon, value) in listOf("target" to next["distance"].string, "speedometer" to next["speed"].string, "arrow_expand_horizontal" to next["size"].string)) {
						Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
							Glyph(icon, size = 18.dp, color = Theme.colors.textMuted)
							Label(value, style = Theme.Type.small.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
						}
					}
				}
			}
		}
		if (sightings.isNotEmpty()) {
			SectionLabel("In the sky")
			Panel(padding = PaddingValues(6.dp)) {
				for (sighting in sightings) ListRow(
					sighting["name"].string,
					icon = "eye_outline",
					subtitle = listOf(
						"${if (sighting["now"].bool) "Now" else sighting["from"].string} – ${sighting["until"].string}",
						"${sighting["look"].string}, ${sighting["alt"].int}° high",
						if (sighting["moves"].string != sighting["look"].string) "moves ${sighting["moves"].string}" else "",
						"${aid(sighting["mag"].double)} (%.1f mag)".format(sighting["mag"].double),
					).filter { it.isNotEmpty() }.joinToString(" · "),
					iconTint = if (sighting["now"].bool) Theme.colors.primary else Theme.colors.text,
					iconBackground = Theme.colors.layer2,
				)
			}
		}
		SectionLabel("This week")
		Panel(padding = PaddingValues(6.dp)) {
			for (each in objects) Passing(each, next = each["des"].string == asteroids["next"].string, seen = sightings.any { it["des"].string == each["des"].string })
		}
	}
}

@Composable
private fun Passing(each: JsonElement, next: Boolean, seen: Boolean) {
	ListRow(
		each["name"].string,
		icon = "meteor",
		subtitle = "${each["moment"].string} · ${each["when"].string}",
		iconTint = if (next) Theme.colors.primary else if (each["passed"].bool) Theme.colors.textSubtle else Theme.colors.text,
		iconBackground = Theme.colors.layer2,
	) {
		if (seen) {
			Glyph("eye_outline", size = 16.dp, color = Theme.colors.primary)
			Spacer(Modifier.width(10.dp))
		}
		Column(horizontalAlignment = Alignment.End) {
			Label(each["distance"].string, style = Theme.Type.label.copy(fontFeatureSettings = "tnum"))
			Label(each["size"].string, style = Theme.Type.small.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textSubtle)
		}
	}
}
