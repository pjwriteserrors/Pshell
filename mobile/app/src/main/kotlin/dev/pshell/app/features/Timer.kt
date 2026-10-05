package dev.pshell.app.features

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sheet
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonElement

val TimerFeature = Feature(
	id = "timer",
	title = "Timer",
	icon = "timer_outline",
	plugins = listOf("qtrack"),
	card = { open -> TimerCard(open) },
	screen = { TimerScreen() },
)

/** The running time, counted on from the moment the PC says it started. */
@Composable
fun runningClock(timer: JsonElement?): String {
	val link = link
	val startedAt = timer["startedAt"].long
	var now by remember { mutableLongStateOf(link.pcNow()) }
	LaunchedEffect(startedAt, timer["paused"].bool) {
		while (true) {
			now = link.pcNow()
			delay(1000)
		}
	}
	if (!timer["tracking"].bool || startedAt <= 0) return timer["last"].string.ifEmpty { "0:00" }
	val seconds = ((now - startedAt) / 1000).coerceAtLeast(0)
	return "%d:%02d:%02d".format(seconds / 3600, seconds % 3600 / 60, seconds % 60)
}

@Composable
private fun TimerCard(open: () -> Unit) {
	val timer = topic("timer") ?: return
	val link = link
	val tracking = timer["tracking"].bool
	if (!tracking && !timer["paused"].bool && !timer["canResume"].bool) return
	Panel(onClick = open, color = if (tracking) Theme.colors.primaryContainer else Theme.colors.layer1, padding = PaddingValues(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 12.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Column(Modifier.weight(1f)) {
				Label(if (tracking) "TRACKING" else "PAUSED", style = Theme.Type.tiny.copy(letterSpacing = 1.sp), color = if (tracking) Theme.colors.primary else Theme.colors.textSubtle)
				Label(runningClock(timer), style = Theme.Type.display.copy(fontFeatureSettings = "tnum"))
				Label(listOf(timer["project"].string, timer["description"].string).filter { it.isNotEmpty() }.joinToString(" · "), style = Theme.Type.small, color = Theme.colors.textMuted)
			}
			IconButton(if (tracking) "pause" else "play", size = 56.dp, iconSize = 28.dp, color = Theme.colors.primary, tint = Theme.colors.onPrimary) {
				link.run("timer", if (tracking) "pause" else "resume")
			}
		}
	}
}

@Composable
private fun TimerScreen() {
	val timer = topic("timer")
	val link = link
	var starting by remember { mutableStateOf(false) }
	Screen("Timer", subtitle = "Today ${timer["todayTotal"].string}") {
		val tracking = timer["tracking"].bool
		Panel(color = if (tracking) Theme.colors.primaryContainer else Theme.colors.layer1, padding = PaddingValues(20.dp)) {
			Label(
				when {
					tracking -> "TRACKING"
					timer["paused"].bool -> "PAUSED"
					else -> "IDLE"
				},
				style = Theme.Type.tiny.copy(letterSpacing = 1.2.sp), color = if (tracking) Theme.colors.primary else Theme.colors.textSubtle,
			)
			Label(runningClock(timer), style = Theme.Type.hero.copy(fontFeatureSettings = "tnum"))
			if (timer["project"].string.isNotEmpty()) Label(timer["project"].string, style = Theme.Type.title, maxLines = 2)
			if (timer["description"].string.isNotEmpty()) Label(timer["description"].string, color = Theme.colors.textMuted, maxLines = 3)
			Spacer(Modifier.height(16.dp))
			Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
				if (tracking) PrimaryButton("Pause", Modifier.weight(1f), icon = "pause") { link.run("timer", "pause") }
				else if (timer["canResume"].bool || timer["paused"].bool) PrimaryButton("Resume", Modifier.weight(1f), icon = "play") { link.run("timer", "resume") }
				if (!tracking) PrimaryButton("New", Modifier.weight(1f), icon = "plus") {
					link.run("timer", "refreshTeamwork")
					starting = true
				}
			}
		}
		val tasks = timer["tasks"].list
		if (tasks.isNotEmpty()) {
			SectionLabel("Today")
			Panel(padding = PaddingValues(6.dp)) {
				for (task in tasks) {
					val current = task["current"].bool
					ListRow(
						task["description"].string.ifEmpty { task["project"].string },
						icon = if (current && tracking) "pause" else "play",
						subtitle = task["project"].string,
						iconBackground = if (current) Theme.colors.primary else Theme.colors.layer3,
						iconTint = if (current) Theme.colors.onPrimary else Theme.colors.text,
						onClick = {
							if (current && tracking) link.run("timer", "pause")
							else link.run("timer", "switch", json("project" to task["project"].string, "description" to task["description"].string))
						},
					) {
						Label(task["duration"].string, style = Theme.Type.label.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
					}
				}
			}
		} else if (timer != null && !tracking) {
			EmptyState("timer_outline", "Nothing tracked today")
		}
	}
	if (starting) StartSheet(timer) { starting = false }
}

/** A new timer: a Teamwork task and what is being done. */
@Composable
private fun StartSheet(timer: JsonElement?, onDismiss: () -> Unit) {
	val link = link
	var search by remember { mutableStateOf("") }
	var chosen by remember { mutableStateOf<JsonElement?>(null) }
	var description by remember { mutableStateOf("") }
	Sheet(onDismiss, "New timer") { close ->
		val picked = chosen
		if (picked == null) {
			Field(search, placeholder = "Search tasks", icon = "magnify") { search = it }
			val matches = timer["teamwork"].list.filter { search.isBlank() || "${it["name"].string} ${it["project"].string}".contains(search, ignoreCase = true) }.take(8)
			if (matches.isEmpty()) Label("No Teamwork tasks. They load on the PC.", color = Theme.colors.textMuted, maxLines = 2)
			for (task in matches) ListRow(task["name"].string, icon = "checkbox_marked_circle_outline", subtitle = task["project"].string, onClick = { chosen = task })
		} else {
			ListRow(picked["name"].string, icon = "checkbox_marked_circle_outline", subtitle = picked["project"].string, onClick = { chosen = null }) {
				Glyph("close", size = 18.dp, color = Theme.colors.textSubtle)
			}
			Field(description, placeholder = "What are you doing?", icon = "pencil") { description = it }
			PrimaryButton("Start", Modifier.fillMaxWidth(), icon = "play", enabled = description.isNotBlank()) {
				link.run("timer", "start", json("id" to picked["id"].string, "description" to description))
				close()
			}
		}
	}
}
