package dev.pshell.app.reminders

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import dev.pshell.app.features.Feature
import dev.pshell.app.features.Group
import dev.pshell.app.nas.Nas
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Confirm
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Gap
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Toggle
import dev.pshell.app.ui.widgets.pressable
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Reminders of pshell-core: own ones with Done and Snooze, a line of text as a new one, the editor; what core knows besides, read only. */
val RemindersFeature = Feature(
	id = "reminders",
	group = Group.Work,
	keywords = listOf("erinnerung", "erinnern", "wecker", "alarm", "remind", "reminder", "snooze"),
	title = "Reminders",
	icon = "bell_outline",
	plugins = listOf("nas"),
	summary = { Reminders.showing.collectAsState().value.values.count { it.level != "quiet" }.let { if (it > 0) "$it now" else "" } },
	screen = { RemindersScreen() },
)

private val TIME = DateTimeFormatter.ofPattern("HH:mm")
private val SHORT = DateTimeFormatter.ofPattern("EEE d. MMM")

private fun local(epoch: Long): LocalDateTime = Instant.ofEpochSecond(epoch).atZone(Reminders.zone).toLocalDateTime()
private fun epoch(time: LocalDateTime): Long = time.atZone(Reminders.zone).toEpochSecond()

fun whenText(epoch: Long, allDay: Boolean = false): String {
	val time = local(epoch)
	val today = LocalDate.now(Reminders.zone)
	val day = when (time.toLocalDate()) {
		today -> "Today"
		today.plusDays(1) -> "Tomorrow"
		today.minusDays(1) -> "Yesterday"
		else -> time.format(SHORT)
	}
	return if (allDay) day else "$day ${time.format(TIME)}"
}

private fun weekday(day: Int) = DayOfWeek.of(day).getDisplayName(TextStyle.SHORT, Locale.getDefault()).take(2)

fun repeatText(repeat: Repeat): String {
	val unit = mapOf("day" to "day", "week" to "week", "month" to "month", "year" to "year")[repeat.every] ?: repeat.every
	val base = if (repeat.n > 1) "Every ${repeat.n} ${unit}s" else "Every $unit"
	return if (repeat.every == "week" && repeat.days.isNotEmpty()) "$base · ${repeat.days.joinToString(" ") { weekday(it) }}" else base
}

val TRIGGER_LABELS = mapOf(
	"time" to "Time", "unlock" to "At PC", "arrive_home" to "Arrive home", "leave_home" to "Leave home",
	"washer_done" to "Washer done", "qtrack_stop" to "Timer stops", "game_end" to "Game ends",
)
private val LEVEL_LABELS = listOf("quiet" to "Quiet", "normal" to "Normal", "important" to "Important", "fullscreen" to "Alarm")
private fun levelIcon(level: String) = when (level) {
	"quiet" -> "bell_off_outline"
	"important" -> "bell_ring_outline"
	"fullscreen" -> "alarm"
	else -> "bell_outline"
}

/** What the list says below a reminder's title. */
fun describe(reminder: Reminder, now: Long = Reminders.now()): String {
	val parts = mutableListOf<String>()
	val snoozed = reminder.snoozedUntil?.takeIf { it > now }
	when {
		snoozed != null -> parts += "Snoozed · ${whenText(snoozed)}"
		reminder.trigger != "time" -> parts += TRIGGER_LABELS[reminder.trigger] ?: reminder.trigger
		else -> (reminder.next ?: Schedule.occurrences(reminder, now, Reminders.zone).firstOrNull() ?: reminder.at)?.let { parts += whenText(it, reminder.allDay) }
	}
	reminder.repeat?.let { parts += repeatText(it) }
	if (reminder.note.isNotEmpty()) parts += reminder.note
	return parts.joinToString(" · ")
}

/** What the editor has open. */
private data class Draft(
	val id: String?, val title: String, val note: String, val trigger: String, val start: LocalDateTime, val allDay: Boolean,
	val repeat: Repeat?, val level: String, val escalateMin: Int,
) {
	fun body(): JsonObject = JsonObject(mapOf(
		"title" to JsonPrimitive(title.trim()), "note" to JsonPrimitive(note.trim()), "trigger" to JsonPrimitive(trigger),
		"at" to if (trigger == "time") JsonPrimitive(epoch(if (allDay) start.toLocalDate().atStartOfDay() else start)) else JsonNull,
		"all_day" to JsonPrimitive(trigger == "time" && allDay),
		"repeat" to if (trigger == "time" && repeat != null) repeat.toJson() else JsonNull,
		"level" to JsonPrimitive(level), "escalate_min" to JsonPrimitive(escalateMin),
	))

	companion object {
		fun fresh(): Draft {
			val now = LocalDateTime.now(Reminders.zone)
			val own = Reminders.snapshot.value.levels["own"]?.takeIf { it in LEVELS } ?: "normal"
			return Draft(null, "", "", "time", now.toLocalDate().atTime(now.hour, 0).plusHours(1), false, null, own, 10)
		}

		fun of(reminder: Reminder) = Draft(
			reminder.id, reminder.title, reminder.note, reminder.trigger,
			reminder.at?.let { local(it) } ?: fresh().start, reminder.allDay, reminder.repeat, reminder.level, reminder.escalateMin,
		)

		fun of(parsed: Parsed) = fresh().let {
			it.copy(title = parsed.title, trigger = parsed.trigger, start = parsed.at?.let(::local) ?: it.start, allDay = parsed.allDay, repeat = parsed.repeat, level = parsed.level ?: it.level)
		}
	}
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun RemindersScreen() {
	val context = LocalContext.current
	val scope = rememberCoroutineScope()
	val nasAccount by Nas.account.collectAsState()
	val snapshot by Reminders.snapshot.collectAsState()
	val showing by Reminders.showing.collectAsState()
	val problem by Reminders.problem.collectAsState()
	val loading by Reminders.loading.collectAsState()
	val queued by Reminders.queued.collectAsState()
	var quick by remember { mutableStateOf("") }
	var parsed by remember { mutableStateOf<Parsed?>(null) }
	var open by remember { mutableStateOf<Reminder?>(null) }
	var draft by remember { mutableStateOf<Draft?>(null) }
	var permissions by remember { mutableIntStateOf(0) }

	LaunchedEffect(nasAccount) { if (nasAccount != null) Reminders.sync() }
	LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { permissions++ }
	LaunchedEffect(quick) {
		if (quick.isBlank()) return@LaunchedEffect run { parsed = null }
		delay(250)
		parsed = Reminders.parse(quick)
	}

	Screen("Reminders", subtitle = if (loading) "Loading…" else if (queued > 0) "$queued waiting" else "", actions = {
		IconButton("refresh", color = Theme.colors.layer2) { scope.launch { Reminders.sync() } }
	}) {
		if (nasAccount == null) {
			EmptyState("bell_outline", "Not connected yet")
			return@Screen
		}
		if (problem.isNotEmpty()) Label(problem, color = Theme.colors.danger, maxLines = 3)

		// what the phone may not do yet
		val missing = remember(permissions) {
			buildList {
				if (!Alerts.notificationsAllowed(context)) add(Triple("Notifications", "bell_off_outline", Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)))
				if (!Alerts.exactAllowed(context) && Build.VERSION.SDK_INT >= 31) add(Triple("Exact alarms", "alarm_off", Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${context.packageName}"))))
				if (!Alerts.fullScreenAllowed(context) && Build.VERSION.SDK_INT >= 34) add(Triple("Full screen", "fullscreen", Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${context.packageName}"))))
			}
		}
		if (missing.isNotEmpty()) FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
			for ((label, icon, intent) in missing) Chip(label, icon = icon, tint = Theme.colors.warning) { runCatching { context.startActivity(intent) } }
		}

		// a line of text as a reminder
		Field(quick, placeholder = "morgen 9 Arzt", icon = "bell_plus_outline", onSubmit = {
			val found = parsed ?: return@Field
			if (found.title.isBlank()) return@Field
			scope.launch { if (Reminders.create(found.body())) quick = "" }
		}) { quick = it }
		parsed?.let { found ->
			Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
				Column(Modifier.weight(1f)) {
					Label(found.title.ifEmpty { "Title?" }, style = Theme.Type.label, color = if (found.title.isEmpty()) Theme.colors.textSubtle else Theme.colors.text)
					Label(
						listOfNotNull(
							if (found.trigger != "time") TRIGGER_LABELS[found.trigger] ?: found.trigger else found.at?.let { whenText(it, found.allDay) },
							found.repeat?.let(::repeatText),
							found.level?.let { level -> LEVEL_LABELS.first { it.first == level }.second },
						).joinToString(" · "),
						style = Theme.Type.small, color = Theme.colors.textMuted,
					)
				}
				IconButton("pencil", size = 38.dp, iconSize = 18.dp) { draft = Draft.of(found) }
			}
		}

		val now = Reminders.now()
		val mine = snapshot.reminders
		val active = mine.filter { it.open && (showing.containsKey(it.id) || it.pending.isNotEmpty()) }
		val upcoming = (mine.filter { it.open } - active.toSet()).sortedWith(compareBy<Reminder> { it.trigger != "time" }.thenBy { it.snoozedUntil?.takeIf { s -> s > now } ?: it.next ?: Schedule.occurrences(it, now, Reminders.zone).firstOrNull() ?: Long.MAX_VALUE })
		val done = mine.filter { !it.open }.sortedByDescending { it.updated }.take(10)

		if (mine.isEmpty() && snapshot.sources.isEmpty() && !loading) EmptyState("bell_outline", "No reminders")

		if (active.isNotEmpty()) {
			SectionLabel("Now")
			for (reminder in active) ActivePanel(reminder, showing[reminder.id]?.occurrence ?: reminder.pending.maxOrNull()) { open = reminder }
		}
		if (upcoming.isNotEmpty()) {
			SectionLabel("Upcoming")
			Panel(padding = PaddingValues(6.dp)) {
				for (reminder in upcoming) ListRow(reminder.title, icon = levelIcon(reminder.level), subtitle = describe(reminder, now), onClick = { open = reminder })
			}
		}
		if (snapshot.sources.isNotEmpty()) {
			SectionLabel("Calendar & more")
			Panel(padding = PaddingValues(6.dp)) {
				for (item in snapshot.sources.sortedBy { it.at }) ListRow(
					item.title, icon = if (item.source == "expenses") "cash" else "calendar_month",
					subtitle = whenText(item.at),
					iconTint = Theme.colors.textMuted,
					onClick = if (item.url.isNotEmpty()) ({ runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(item.url))) } }) else null,
				)
			}
		}
		if (done.isNotEmpty()) {
			SectionLabel("Done")
			Panel(padding = PaddingValues(6.dp)) {
				for (reminder in done) ListRow(reminder.title, icon = "check", subtitle = reminder.at?.let { whenText(it, reminder.allDay) }.orEmpty(), iconTint = Theme.colors.textSubtle, onClick = { open = reminder })
			}
		}
		SoftButton("New", Modifier.fillMaxWidth(), icon = "plus") { draft = Draft.fresh() }
	}

	open?.let { reminder ->
		ReminderSheet(reminder, showing[reminder.id]?.occurrence ?: reminder.pending.maxOrNull(), onDismiss = { open = null }, onEdit = {
			open = null
			draft = Draft.of(reminder)
		})
	}
	draft?.let { current ->
		Editor(current, onDismiss = { draft = null }) { body ->
			scope.launch {
				val ok = if (current.id == null) Reminders.create(body) else Reminders.update(current.id, body)
				if (ok) {
					draft = null
					if (current.id == null) quick = ""
				}
			}
		}
	}
}

@Composable
private fun SnoozeRow(id: String) {
	Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
		for (snooze in Reminders.Snooze.entries) Chip(snooze.label, Modifier.weight(1f)) { Reminders.snooze(id, snooze) }
	}
}

@Composable
private fun ActivePanel(reminder: Reminder, occurrence: Long?, onOpen: () -> Unit) {
	Panel(color = if (reminder.level == "fullscreen" || reminder.level == "important") Theme.colors.primaryContainer else Theme.colors.layer1) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Column(Modifier.weight(1f).pressable(onClick = onOpen).padding(vertical = 4.dp)) {
				Label(reminder.title, style = Theme.Type.title, maxLines = 2)
				occurrence?.let { Label(whenText(it), style = Theme.Type.small, color = Theme.colors.textMuted) }
			}
			PrimaryButton("Done", icon = "check") { Reminders.ack(reminder.id, occurrence) }
		}
		Gap(10)
		SnoozeRow(reminder.id)
	}
}

@Composable
private fun ReminderSheet(reminder: Reminder, occurrence: Long?, onDismiss: () -> Unit, onEdit: () -> Unit) {
	val scope = rememberCoroutineScope()
	var asking by remember { mutableStateOf(false) }
	Sheet(onDismiss, reminder.title) { close ->
		ListRow(describe(reminder).ifEmpty { "–" }, icon = if (reminder.trigger == "time") "clock_outline" else "flash_outline")
		ListRow(LEVEL_LABELS.first { it.first == reminder.level }.second, icon = levelIcon(reminder.level),
			subtitle = if (reminder.level == "important" && reminder.escalateMin > 0) "Alarm after ${reminder.escalateMin} min" else "")
		if (reminder.open && occurrence != null) {
			PrimaryButton("Done", Modifier.fillMaxWidth(), icon = "check") {
				Reminders.ack(reminder.id, occurrence)
				close()
			}
			Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
				for (snooze in Reminders.Snooze.entries) Chip(snooze.label, Modifier.weight(1f)) {
					Reminders.snooze(reminder.id, snooze)
					close()
				}
			}
		}
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
			SoftButton("Edit", Modifier.weight(1f), icon = "pencil") { onEdit() }
			SoftButton("Delete", Modifier.weight(1f), icon = "delete_outline", tint = Theme.colors.danger) { asking = true }
		}
	}
	if (asking) Confirm(reminder.title, describe(reminder), "Delete", danger = true, onDismiss = { asking = false }) {
		onDismiss()
		scope.launch { Reminders.delete(reminder.id) }
	}
}

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun Editor(draft: Draft, onDismiss: () -> Unit, onSave: (JsonObject) -> Unit) {
	var title by remember { mutableStateOf(draft.title) }
	var note by remember { mutableStateOf(draft.note) }
	var trigger by remember { mutableStateOf(draft.trigger) }
	var start by remember { mutableStateOf(draft.start) }
	var allDay by remember { mutableStateOf(draft.allDay) }
	var every by remember { mutableStateOf(draft.repeat?.every ?: "") }
	var n by remember { mutableIntStateOf(draft.repeat?.n ?: 1) }
	var days by remember { mutableStateOf(draft.repeat?.days ?: emptyList()) }
	var level by remember { mutableStateOf(draft.level) }
	var escalate by remember { mutableIntStateOf(draft.escalateMin) }
	var picking by remember { mutableStateOf("") }

	Sheet(onDismiss, if (draft.id == null) "New reminder" else "Edit") { _ ->
		Field(title, placeholder = "Title") { title = it }
		Field(note, placeholder = "Note", icon = "text_box_outline", singleLine = false) { note = it }
		FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
			for ((value, label) in TRIGGER_LABELS) Chip(label, active = trigger == value) { trigger = value }
		}
		if (trigger == "time") {
			Row(verticalAlignment = Alignment.CenterVertically) {
				Label("All day", Modifier.weight(1f), color = Theme.colors.textMuted)
				Toggle(allDay) { allDay = it }
			}
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
				SoftButton(start.format(SHORT), Modifier.weight(1f), icon = "calendar_month") { picking = "date" }
				if (!allDay) SoftButton(start.format(TIME), icon = "clock_outline") { picking = "time" }
			}
			Segmented(listOf("" to "Once", "day" to "Day", "week" to "Week", "month" to "Month", "year" to "Year"), every, Modifier.fillMaxWidth()) { every = it }
			if (every.isNotEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
				Label("Every", Modifier.weight(1f), color = Theme.colors.textMuted)
				IconButton("minus", size = 38.dp, iconSize = 18.dp, enabled = n > 1) { n = (n - 1).coerceAtLeast(1) }
				Label("$n", Modifier.width(32.dp), style = Theme.Type.title, align = androidx.compose.ui.text.style.TextAlign.Center)
				IconButton("plus", size = 38.dp, iconSize = 18.dp) { n += 1 }
			}
			if (every == "week") Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
				for (day in 1..7) Chip(weekday(day), Modifier.weight(1f), active = day in days) { days = if (day in days) days - day else (days + day).sorted() }
			}
		}
		Segmented(LEVEL_LABELS, level, Modifier.fillMaxWidth()) { level = it }
		if (level == "important") Row(verticalAlignment = Alignment.CenterVertically) {
			androidx.compose.foundation.layout.Box(Modifier.padding(end = 8.dp)) { dev.pshell.app.ui.widgets.Glyph("alarm", size = 18.dp, color = Theme.colors.textMuted) }
			Segmented(listOf(0 to "Never", 5 to "5m", 10 to "10m", 30 to "30m", 60 to "1h") + (if (escalate !in listOf(0, 5, 10, 30, 60)) listOf(escalate to "${escalate}m") else emptyList()), escalate, Modifier.fillMaxWidth()) { escalate = it }
		}
		PrimaryButton("Save", Modifier.fillMaxWidth(), icon = "check", enabled = title.isNotBlank()) {
			val repeat = if (every.isEmpty()) null else Repeat(every, n, if (every == "week") days else emptyList(), draft.repeat?.until)
			onSave(draft.copy(title = title, note = note, trigger = trigger, start = start, allDay = allDay, repeat = repeat, level = level, escalateMin = escalate).body())
		}
	}

	when (picking) {
		"date" -> {
			val state = rememberDatePickerState(initialSelectedDateMillis = start.toLocalDate().atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli())
			DatePickerDialog(onDismissRequest = { picking = "" }, confirmButton = {
				TextButton({
					state.selectedDateMillis?.let { millis -> start = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate().atTime(start.toLocalTime()) }
					picking = ""
				}) { Label("OK", color = Theme.colors.primary) }
			}) { DatePicker(state) }
		}
		"time" -> {
			val state = rememberTimePickerState(start.hour, start.minute, true)
			Dialog(onDismissRequest = { picking = "" }) {
				Column(Modifier.clip(RoundedCornerShape(28.dp)).background(Theme.colors.layer1).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
					TimePicker(state)
					Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
						TextButton({ picking = "" }) { Label("Cancel", color = Theme.colors.textMuted) }
						TextButton({
							start = start.toLocalDate().atTime(LocalTime.of(state.hour, state.minute))
							picking = ""
						}) { Label("OK", color = Theme.colors.primary) }
					}
				}
			}
		}
	}
}
