package dev.pshell.app.features

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Meter
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import kotlinx.serialization.json.JsonElement

// ── downloads: what the browser on the PC fetches ──────────────────────────
val DownloadsFeature = Feature(
	id = "downloads",
	title = "Downloads",
	icon = "download",
	group = Group.Work,
	plugins = listOf("downloads"),
	keywords = listOf("browser", "floorp", "firefox", "herunterladen", "files", "dateien", "progress"),
	summary = {
		val downloads = topic("downloads")
		val running = downloads["items"].list.count { it["state"].string == "running" }
		if (running > 0) "$running running" else ""
	},
	card = { open -> DownloadsCard(open) },
	screen = { DownloadsScreen() },
)

fun bytesSaid(bytes: Long): String = when {
	bytes >= 1_000_000_000 -> "%.2f GB".format(bytes / 1_000_000_000.0)
	bytes >= 1_000_000 -> "%.1f MB".format(bytes / 1_000_000.0)
	bytes >= 1_000 -> "%d kB".format(bytes / 1_000)
	else -> "$bytes B"
}

private fun etaSaid(seconds: Double): String = when {
	seconds < 0 -> ""
	seconds < 60 -> "${seconds.toInt()} s left"
	seconds < 3600 -> "${(seconds / 60).toInt()} min left"
	else -> "%d:%02d h left".format((seconds / 3600).toInt(), ((seconds % 3600) / 60).toInt())
}

private fun progressOf(item: JsonElement): Float {
	val total = item["total"].long
	return if (total > 0) (item["received"].long.toFloat() / total).coerceIn(0f, 1f) else 0f
}

/** On the home screen while something downloads: the files and their progress. */
@Composable
private fun DownloadsCard(open: () -> Unit) {
	val downloads = topic("downloads") ?: return
	val active = downloads["items"].list.filter { it["state"].string == "running" || it["state"].string == "paused" }
	if (active.isEmpty()) return
	Panel(onClick = open, padding = PaddingValues(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 12.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Glyph("download", size = 20.dp, color = Theme.colors.primary)
			Spacer(Modifier.width(10.dp))
			Label(if (active.size == 1) "Downloading" else "${active.size} downloads", style = Theme.Type.title, modifier = Modifier.weight(1f))
			val speed = downloads["speed"].long
			if (speed > 0) Label("${bytesSaid(speed)}/s", style = Theme.Type.small.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
		}
		for (item in active.take(3)) {
			Spacer(Modifier.height(8.dp))
			Label(item["name"].string, style = Theme.Type.small)
			Spacer(Modifier.height(4.dp))
			Meter(progressOf(item), color = if (item["state"].string == "paused") Theme.colors.textSubtle else Theme.colors.primary)
		}
	}
}

@Composable
private fun DownloadsScreen() {
	val downloads = topic("downloads")
	val link = link
	var chosen by remember { mutableStateOf<JsonElement?>(null) }
	val items = downloads["items"].list
	val active = items.filter { it["state"].string == "running" || it["state"].string == "paused" }
	val finished = items.filter { it["state"].string == "done" || it["state"].string == "failed" }
	Screen("Downloads", subtitle = if (downloads["connected"].bool) "The browser on the PC" else "The browser is not connected to the shell") {
		if (downloads == null) EmptyState("download", "Loading…")
		else if (items.isEmpty()) EmptyState("download_off_outline", "No downloads", text = "What the browser on the PC downloads shows up here, with its progress.")
		if (active.isNotEmpty()) {
			SectionLabel("Running")
			for (item in active) {
				val paused = item["state"].string == "paused"
				Panel(onClick = { chosen = item }) {
					Row(verticalAlignment = Alignment.CenterVertically) {
						Column(Modifier.weight(1f)) {
							Label(item["name"].string, style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold), maxLines = 2)
							val total = item["total"].long
							Label(
								listOf(
									if (total > 0) "${bytesSaid(item["received"].long)} of ${bytesSaid(total)}" else bytesSaid(item["received"].long),
									if (paused) "paused" else if (item["speed"].long > 0) "${bytesSaid(item["speed"].long)}/s" else "",
									if (paused) "" else etaSaid(item["eta"].double),
								).filter { it.isNotEmpty() }.joinToString(" · "),
								style = Theme.Type.small, color = Theme.colors.textMuted,
							)
						}
						Spacer(Modifier.width(8.dp))
						IconButton(if (paused) "play" else "pause", color = Theme.colors.layer2, enabled = !paused || item["canResume"].bool) { link.run("downloads", if (paused) "resume" else "pause", json("key" to item["key"].string)) }
						IconButton("close", color = Theme.colors.layer2) { link.run("downloads", "cancel", json("key" to item["key"].string)) }
					}
					Spacer(Modifier.height(10.dp))
					Meter(progressOf(item), color = if (paused) Theme.colors.textSubtle else Theme.colors.primary)
				}
			}
		}
		if (finished.isNotEmpty()) {
			SectionLabel("Finished")
			Panel(padding = PaddingValues(6.dp)) {
				for (item in finished) {
					val failed = item["state"].string == "failed"
					ListRow(
						item["name"].string,
						icon = if (failed) "alert_circle_outline" else "file_outline",
						subtitle = if (failed) item["error"].string.ifEmpty { "Failed" } else bytesSaid(item["total"].long.takeIf { it > 0 } ?: item["received"].long),
						iconTint = if (failed) Theme.colors.danger else Theme.colors.text,
						onClick = { chosen = item },
					) {
						Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
					}
				}
			}
		}
	}
	chosen?.let { item ->
		val done = item["state"].string == "done"
		Sheet({ chosen = null }, item["name"].string) { close ->
			if (item["url"].string.isNotEmpty()) Label(item["url"].string, style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 2)
			if (done) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				SoftButton("Open on the PC", Modifier.weight(1f).padding(vertical = 4.dp), icon = "open_in_new") { link.run("downloads", "open", json("key" to item["key"].string)); close() }
				SoftButton("Show folder", Modifier.weight(1f).padding(vertical = 4.dp), icon = "folder_outline") { link.run("downloads", "reveal", json("key" to item["key"].string)); close() }
			}
			if (done) PrimaryButton("To the phone", Modifier.fillMaxWidth(), icon = "cellphone_arrow_down") {
				link.run("downloads", "send", json("key" to item["key"].string))
				link.toast("Fetching ${item["name"].string}")
				close()
			}
			if (item["state"].string == "running" || item["state"].string == "paused") SoftButton("Cancel the download", Modifier.fillMaxWidth().padding(vertical = 4.dp), icon = "close", tint = Theme.colors.danger) { link.run("downloads", "cancel", json("key" to item["key"].string)); close() }
			else SoftButton("Remove from the list", Modifier.fillMaxWidth().padding(vertical = 4.dp), icon = "delete_outline") { link.run("downloads", "dismiss", json("key" to item["key"].string)); close() }
		}
	}
}
