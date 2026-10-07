package dev.pshell.app.features

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.pshell.app.link.bool
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
import dev.pshell.app.ui.widgets.Field
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
import dev.pshell.app.ui.widgets.Toggle
import dev.pshell.app.ui.widgets.pressable
import kotlinx.serialization.json.JsonElement
import java.text.SimpleDateFormat
import java.util.Locale

// ── tracking: the day board of the time tracker ────────────────────────────
val TrackingFeature = Feature(
	id = "tracking",
	title = "Days",
	icon = "calendar_clock",
	group = Group.Work,
	plugins = listOf("qtrack"),
	keywords = listOf("tracking", "zeiterfassung", "teamwork", "tage", "board", "report", "hours", "stunden", "billable"),
	summary = {
		val tracking = topic("tracking")
		val queued = tracking["queued"].int
		if (queued > 0) "$queued to send" else ""
	},
	screen = { TrackingScreen() },
)

fun minutesSaid(minutes: Int): String = if (minutes >= 60) "%d:%02d h".format(minutes / 60, minutes % 60) else "$minutes min"

private fun daySaid(day: String, today: String): String {
	if (day.isEmpty()) return ""
	if (day == today) return "Today"
	val date = runCatching { SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).parse(day) }.getOrNull() ?: return day
	return SimpleDateFormat("EEE, d MMM", Locale.getDefault()).format(date)
}

@Composable
private fun TrackingScreen() {
	val tracking = topic("tracking")
	val link = link
	var editing by remember { mutableStateOf<JsonElement?>(null) }
	var removing by remember { mutableStateOf<JsonElement?>(null) }
	var picking by remember { mutableStateOf<JsonElement?>(null) }
	var days by remember { mutableStateOf(false) }
	val day = tracking["day"].string
	val today = tracking["today"].string
	val minutes = tracking["minutes"].int
	val workday = tracking["workdayMinutes"].int.coerceAtLeast(1)
	Screen("Days", subtitle = if (tracking["sending"].bool) "Sending to Teamwork…" else tracking["status"].string, actions = {
		IconButton("calendar_month_outline", color = Theme.colors.layer2) { days = true }
	}) {
		if (tracking == null) {
			EmptyState("calendar_clock", "Loading…")
			return@Screen
		}
		// the day, stepped with arrows
		Panel(padding = PaddingValues(start = 8.dp, end = 8.dp, top = 10.dp, bottom = 14.dp)) {
			Row(verticalAlignment = Alignment.CenterVertically) {
				IconButton("chevron_left", color = Theme.colors.layer2) { link.run("tracking", "step", json("delta" to -1)) }
				Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
					Label(daySaid(day, today), style = Theme.Type.title)
					Label(day, style = Theme.Type.tiny, color = Theme.colors.textSubtle)
				}
				IconButton("chevron_right", color = Theme.colors.layer2, enabled = day != today) { link.run("tracking", "step", json("delta" to 1)) }
			}
			Spacer(Modifier.height(8.dp))
			Row(Modifier.padding(horizontal = 8.dp), verticalAlignment = Alignment.Bottom) {
				Label(minutesSaid(minutes), style = Theme.Type.display.copy(fontFeatureSettings = "tnum"))
				Spacer(Modifier.width(10.dp))
				Label("of ${minutesSaid(workday)} · ${minutesSaid(tracking["billableMinutes"].int)} billable", Modifier.padding(bottom = 6.dp), style = Theme.Type.small, color = Theme.colors.textMuted)
			}
			Spacer(Modifier.height(8.dp))
			Meter((minutes.toFloat() / workday).coerceIn(0f, 1f), Modifier.padding(horizontal = 8.dp))
			Spacer(Modifier.height(10.dp))
			Row(Modifier.padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				val queued = tracking["queued"].int
				Chip("${tracking["sent"].int} sent", icon = "check")
				Chip(if (queued > 0) "$queued queued" else "Nothing queued", icon = "tray_arrow_up", active = queued > 0)
			}
		}
		val entries = tracking["entries"].list
		if (entries.isEmpty()) EmptyState("calendar_clock", if (tracking["loading"].bool) "Loading…" else "Nothing tracked this day")
		else {
			// grouped by project, as the drawer does
			for (group in tracking["groups"].list) {
				val project = group["project"].string
				val members = entries.filter { it["project"].string == project }
				if (members.isEmpty()) continue
				Row(verticalAlignment = Alignment.CenterVertically) {
					SectionLabel(project.ifEmpty { "No project" }, Modifier.weight(1f))
					Label(group["duration"].string, Modifier.padding(end = 6.dp), style = Theme.Type.tiny.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textSubtle)
				}
				Panel(padding = PaddingValues(6.dp)) {
					for (entry in members) EntryRow(entry, onEdit = { editing = entry })
				}
			}
			val queued = tracking["queued"].int
			if (queued > 0) PrimaryButton(if (tracking["sending"].bool) "Sending…" else "Send $queued to Teamwork", Modifier.fillMaxWidth(), icon = "send", enabled = !tracking["sending"].bool) { link.run("tracking", "send") }
		}
	}
	editing?.let { entry ->
		var text by remember(entry) { mutableStateOf(entry["description"].string) }
		Sheet({ editing = null }, entry["project"].string.ifEmpty { "Entry" }) { close ->
			Field(text, placeholder = "Description", singleLine = false) { text = it }
			Row(verticalAlignment = Alignment.CenterVertically) {
				Column(Modifier.weight(1f)) {
					Label("Billable", style = Theme.Type.label)
					Label(if (entry["billable"].bool) "Counted towards the customer" else "Not billed", style = Theme.Type.small, color = Theme.colors.textMuted)
				}
				Toggle(entry["billable"].bool) { link.run("tracking", "billable", json("project" to entry["project"].string, "description" to entry["description"].string, "on" to it)) }
			}
			SectionLabel("Shift")
			Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
				for ((label, edge, delta) in listOf(Triple("Start −15", "start", -15), Triple("Start +15", "start", 15), Triple("End −15", "end", -15), Triple("End +15", "end", 15)))
					Chip(label) { link.run("tracking", "shift", json("project" to entry["project"].string, "description" to entry["description"].string, "edge" to edge, "minutes" to delta)) }
			}
			Label(listOf(entry["range"].string, entry["duration"].string).filter { it.isNotEmpty() }.joinToString(" · "), style = Theme.Type.small, color = Theme.colors.textMuted)
			ListRow(if (entry["ticket"].string.isEmpty()) "Pick a Teamwork ticket" else entry["ticket"].string, icon = "ticket_outline", subtitle = if (entry["ticket"].string.isEmpty()) "Needed before it can be sent" else "Tap to change", onClick = { picking = entry })
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				SoftButton("Delete", Modifier.weight(1f).padding(vertical = 4.dp), icon = "delete_outline", tint = Theme.colors.danger) { close(); removing = entry }
				PrimaryButton("Save", Modifier.weight(1f), enabled = text.isNotBlank()) {
					if (text.trim() != entry["description"].string) link.run("tracking", "describe", json("project" to entry["project"].string, "description" to entry["description"].string, "text" to text.trim()))
					close()
				}
			}
		}
	}
	picking?.let { entry ->
		var search by remember { mutableStateOf("") }
		Sheet({ picking = null }, "Teamwork ticket") { close ->
			Field(search, placeholder = "Search tickets", icon = "magnify") { search = it }
			val tickets = tracking["tickets"].list.filter { search.isBlank() || "${it["name"].string} ${it["project"].string}".contains(search, ignoreCase = true) }.take(10)
			if (tickets.isEmpty()) {
				Label("No tickets. They load on the PC.", color = Theme.colors.textMuted)
				SoftButton("Load again", icon = "refresh") { link.run("tracking", "tickets") }
			}
			for (ticket in tickets) ListRow(ticket["name"].string, icon = "ticket_outline", subtitle = ticket["project"].string, onClick = {
				link.run("tracking", "assign", json("project" to entry["project"].string, "description" to entry["description"].string, "id" to ticket["id"].string))
				close()
				editing = null
			})
		}
	}
	removing?.let { entry ->
		Confirm("Delete this entry?", "${entry["description"].string} (${entry["duration"].string}) is removed from the day.", confirm = "Delete", danger = true, onDismiss = { removing = null }) {
			link.run("tracking", "remove", json("project" to entry["project"].string, "description" to entry["description"].string))
			removing = null
		}
	}
	if (days) Sheet({ days = false }, "Days") { close ->
		for (entry in tracking["days"].list.take(45)) {
			val current = entry["day"].string == day
			ListRow(daySaid(entry["day"].string, today), icon = if (current) "check" else "calendar_blank_outline", subtitle = "${entry["tasks"].int} entries · ${entry["sent"].int} sent" + if (entry["unsent"].int > 0) " · ${entry["unsent"].int} open" else "", iconBackground = if (current) Theme.colors.primary else Theme.colors.layer3, iconTint = if (current) Theme.colors.onPrimary else Theme.colors.text, onClick = {
				link.run("tracking", "show", json("day" to entry["day"].string))
				close()
			}) {
				Label(minutesSaid(entry["minutes"].int), style = Theme.Type.label.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
			}
		}
	}
}

/** One entry: the check that queues it, what was done, how long; sent ones are marked. */
@Composable
private fun EntryRow(entry: JsonElement, onEdit: () -> Unit) {
	val link = link
	val checked = entry["checked"].bool
	val synced = entry["synced"].bool
	Row(
		Modifier.fillMaxWidth().pressable(shape = RoundedCornerShape(Theme.Radius.huge), pressedScale = 0.985f, onClick = onEdit).padding(horizontal = 8.dp, vertical = 8.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Box(
			Modifier.size(36.dp).clip(CircleShape).background(if (synced) Theme.colors.success else if (checked) Theme.colors.primary else Theme.colors.layer3)
				.pressable(enabled = !synced, shape = CircleShape, pressedScale = 0.9f, haptic = true) { link.run("tracking", "toggle", json("project" to entry["project"].string, "description" to entry["description"].string)) },
			contentAlignment = Alignment.Center,
		) {
			if (synced || checked) Glyph(if (synced) "check_all" else "check", size = 18.dp, color = Theme.colors.onPrimary)
		}
		Spacer(Modifier.width(12.dp))
		Column(Modifier.weight(1f)) {
			Label(entry["description"].string.ifEmpty { "(no description)" }, style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold), maxLines = 2)
			Label(listOf(entry["range"].string, entry["ticket"].string.ifEmpty { if (!synced) "no ticket" else "" }, if (!entry["billable"].bool) "not billable" else "").filter { it.isNotEmpty() }.joinToString(" · "), style = Theme.Type.small, color = if (entry["ticket"].string.isEmpty() && !synced) Theme.colors.warning else Theme.colors.textMuted)
		}
		Spacer(Modifier.width(8.dp))
		Label(entry["duration"].string.ifEmpty { minutesSaid(entry["minutes"].int) }, style = Theme.Type.label.copy(fontFeatureSettings = "tnum", letterSpacing = 0.sp), color = if (entry["pending"].bool) Theme.colors.primary else Theme.colors.textMuted)
	}
}

