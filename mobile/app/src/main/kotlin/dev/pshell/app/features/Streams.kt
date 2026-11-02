package dev.pshell.app.features

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.double
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel

// ── streams: what could go on, and who is live ─────────────────────────────
val StreamsFeature = Feature(
	id = "streams",
	title = "Streams",
	icon = "play_circle",
	group = Group.Media,
	plugins = listOf("streams"),
	keywords = listOf("youtube", "twitch", "serie", "series", "folge", "episode", "weiterschauen", "live"),
	screen = { StreamsScreen() },
)

@Composable
private fun StreamsScreen() {
	val streams = topic("streams")
	val link = link
	val context = LocalContext.current
	val series = streams["series"].list
	val live = streams["live"].list
	// on the phone: the address, at the place it was left
	fun here(url: String, position: Double) {
		val at = position.toInt()
		val joined = if (at > 0) url + (if ("?" in url) "&" else "?") + "t=$at" else url
		runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(joined))) }
	}
	Screen("Streams", scroll = false) {
		if (series.isEmpty() && live.isEmpty()) {
			EmptyState("play_circle", "Nothing to go on with")
			return@Screen
		}
		LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = BottomSpace + 24.dp)) {
			if (live.isNotEmpty()) item { SectionLabel("Live") }
			items(live) { item ->
				ListRow(
					title = item["name"].string,
					subtitle = item["title"].string,
					icon = "cast",
					onClick = { link.run("streams", "live", json("source" to item["source"].string)) },
				) {
					IconButton("cellphone") { here(item["url"].string, 0.0) }
				}
			}
			if (series.isNotEmpty()) item { SectionLabel("Go on") }
			items(series) { item ->
				ListRow(
					title = item["name"].string,
					subtitle = "${item["n"].int} of ${item["total"].int} · ${item["title"].string}",
					icon = "play",
					onClick = { link.run("streams", "play", json("video" to item["video"].string)) },
				) {
					IconButton("cellphone") { here(item["url"].string, item["position"].double) }
				}
			}
		}
	}
}
