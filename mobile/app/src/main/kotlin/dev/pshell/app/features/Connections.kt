package dev.pshell.app.features

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.Sheet
import kotlinx.serialization.json.JsonElement
import kotlin.math.roundToInt

// ── connections: where the PC's connections go ─────────────────────────────
// No summary and no card: the PC samples its sockets for as long as the
// topic is looked at, and the home screen is looked at all day.
val ConnectionsFeature = Feature(
	id = "connections",
	title = "Connections",
	icon = "earth",
	group = Group.Pc,
	plugins = listOf("connections"),
	keywords = listOf("verbindungen", "network", "netzwerk", "outbound", "traffic", "places", "orte"),
	screen = { ConnectionsScreen() },
)

private fun town(place: JsonElement?): String = place["city"].string.ifEmpty { place["country"].string.ifEmpty { "Unknown" } }

private fun appIcon(id: String): String = if (id == "System") "server" else "application"

/** "Frankfurt, Dublin +3" */
private fun few(names: List<String>): String = if (names.size > 2) "${names.take(2).joinToString(", ")} +${names.size - 2}" else names.joinToString(", ")

/** What moves, or with nothing moving how many connections there are. */
@Composable
private fun Rate(entry: JsonElement?) {
	val down = entry["down"].long
	val up = entry["up"].long
	val busy = down >= 1024 || up >= 1024
	val tone = if (!busy) Theme.colors.textMuted else if (down >= up) Theme.colors.primary else Theme.colors.secondary
	Spacer(Modifier.width(10.dp))
	if (busy) {
		Glyph(if (down >= up) "arrow_down" else "arrow_up", size = 14.dp, color = tone)
		Spacer(Modifier.width(4.dp))
	}
	Label(if (busy) "${bytesSaid(maxOf(down, up))}/s" else "${entry["conns"].int}", style = Theme.Type.label.copy(fontFeatureSettings = "tnum"), color = tone)
}

@Composable
private fun ConnectionsScreen() {
	val connections = topic("connections")
	var mode by remember { mutableStateOf("apps") }
	// what was tapped: an app's id or a place's key; the sheet follows the samples
	var app by remember { mutableStateOf("") }
	var place by remember { mutableStateOf("") }
	val apps = connections["apps"].list
	val places = connections["places"].list
	val placeOf = places.associateBy { it["key"].string }
	val geo = connections["geo"].string
	Screen("Connections", subtitle = when {
		!connections["ready"].bool || geo == "ready" -> ""
		geo == "failed" -> "No location data"
		else -> "Loading locations · ${(connections["progress"].double * 100).roundToInt()}%"
	}) {
		Segmented(listOf("apps" to "Apps", "places" to "Places"), mode, Modifier.fillMaxWidth()) { mode = it }
		if (!connections["ready"].bool) {
			EmptyState("earth", "Loading…")
			return@Screen
		}
		if (apps.isEmpty() && places.isEmpty()) {
			EmptyState("earth", "No connections")
			return@Screen
		}
		Panel(padding = PaddingValues(6.dp)) {
			if (mode == "apps") for (each in apps) ListRow(
				each["title"].string,
				icon = appIcon(each["id"].string),
				subtitle = few(each["places"].list.mapNotNull { placeOf[it.string] }.map { town(it) }.distinct()),
				iconBackground = Theme.colors.layer2,
				onClick = { app = each["id"].string },
			) { Rate(each) }
			else for (each in places) ListRow(
				town(each),
				icon = "map_marker",
				subtitle = listOf(if (each["city"].string.isNotEmpty()) each["country"].string else "", few(each["apps"].list.map { it["title"].string })).filter { it.isNotEmpty() }.joinToString(" · "),
				iconBackground = Theme.colors.layer2,
				onClick = { place = each["key"].string },
			) { Rate(each) }
		}
	}
	if (app.isNotEmpty()) {
		val entry = apps.firstOrNull { it["id"].string == app }
		Sheet({ app = "" }, entry["title"].string.ifEmpty { app }) {
			Column(Modifier.fillMaxWidth().heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
				// the app's share of each place
				for (each in entry["places"].list.mapNotNull { placeOf[it.string] }) ListRow(
					town(each),
					icon = "map_marker",
					subtitle = if (each["city"].string.isNotEmpty()) each["country"].string else "",
				) { Rate(each["apps"].list.firstOrNull { it["id"].string == app } ?: each) }
			}
		}
	}
	if (place.isNotEmpty()) {
		val entry = placeOf[place]
		Sheet({ place = "" }, if (entry == null) "" else town(entry)) {
			if (entry["city"].string.isNotEmpty()) Label(entry["country"].string, style = Theme.Type.small, color = Theme.colors.textMuted)
			Column(Modifier.fillMaxWidth().heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
				for (each in entry["apps"].list) ListRow(each["title"].string, icon = appIcon(each["id"].string)) { Rate(each) }
			}
		}
	}
}
