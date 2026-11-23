package dev.pshell.app.calendar

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import dev.pshell.app.features.Feature
import dev.pshell.app.features.Group
import dev.pshell.app.nas.Nas
import dev.pshell.app.ui.LocalNav
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Confirm
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Gap
import dev.pshell.app.ui.widgets.Glyph
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
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle as DateText
import java.util.Locale
import kotlinx.coroutines.launch

/** Baikal on the phone: the month, the day, a line of text as an event, the editor; the calendars and who has them on a page. */
val BaikalFeature = Feature(
	id = "baikal",
	group = Group.Work,
	keywords = listOf("kalender", "termine", "events", "baikal", "appointment", "teilen", "share"),
	title = "Calendar",
	icon = "calendar_month",
	plugins = listOf("nas"),
	screen = { CalendarScreen() },
	page = { arg -> if (arg == "calendars") CalendarsPage() else if (arg.startsWith("new")) CalendarScreen(newOn = arg.removePrefix("new").removePrefix(":")) else CalendarScreen() },
)

private val PALETTE = listOf("#e0457b", "#f07c3c", "#e3b341", "#3fa66b", "#2fa3a3", "#4f8ef7", "#7b6cf6", "#b462d6", "#8d8d8d")

fun colorOf(hex: String, fallback: Color): Color = runCatching {
	if (hex.length < 7) fallback else Color(android.graphics.Color.parseColor(hex.take(7)))
}.getOrDefault(fallback)

private val DAY = DateTimeFormatter.ofPattern("EEEE, d. MMMM")
private val SHORT = DateTimeFormatter.ofPattern("EEE d. MMM")
private val TIME = DateTimeFormatter.ofPattern("HH:mm")

fun span(event: Event): String {
	if (event.allDay) {
		val last = event.end.minusDays(1)
		return if (!last.toLocalDate().isAfter(event.start.toLocalDate())) "All day" else "${event.start.format(SHORT)} – ${last.format(SHORT)}"
	}
	return if (event.start.toLocalDate() == event.end.toLocalDate()) "${event.start.format(TIME)} – ${event.end.format(TIME)}" else "${event.start.format(SHORT)} ${event.start.format(TIME)} – ${event.end.format(SHORT)} ${event.end.format(TIME)}"
}

private fun dayTitle(day: LocalDate): String = when (day) {
	LocalDate.now() -> "Today"
	LocalDate.now().plusDays(1) -> "Tomorrow"
	LocalDate.now().minusDays(1) -> "Yesterday"
	else -> day.format(DAY)
}

/** what the editor has open: a new event, or the series of one */
private data class Draft(val calendar: String, val href: String?, val fields: Ics.Fields, val overrides: Int = 0)

@Composable
fun CalendarScreen(newOn: String = "") {
	val nav = LocalNav.current
	val scope = rememberCoroutineScope()
	val nasAccount by Nas.account.collectAsState()
	val needPassword by Calendars.needPassword.collectAsState()
	val problem by Calendars.problem.collectAsState()
	val loading by Calendars.loading.collectAsState()
	val byDay by Calendars.byDay.collectAsState()
	val calendars by Calendars.calendars.collectAsState()
	var month by remember { mutableStateOf(LocalDate.now().withDayOfMonth(1)) }
	var selected by remember { mutableStateOf(LocalDate.now()) }
	var open by remember { mutableStateOf<Event?>(null) }
	var draft by remember { mutableStateOf<Draft?>(null) }
	var quick by remember { mutableStateOf("") }

	LaunchedEffect(month, nasAccount) { if (nasAccount != null) Calendars.ensure(month) }
	LaunchedEffect(newOn, calendars) {
		if (newOn == "" || draft != null || calendars.isEmpty()) return@LaunchedEffect
		draft = newDraft(runCatching { LocalDate.parse(newOn) }.getOrDefault(LocalDate.now()))
	}

	Screen("Calendar", subtitle = if (loading) "Loading…" else Calendars.account.collectAsState().value?.user.orEmpty(), actions = {
		IconButton("calendar_month", color = Theme.colors.layer2) { nav.open("feature/baikal/calendars") }
		IconButton("refresh", color = Theme.colors.layer2) { scope.launch { Calendars.refresh() } }
	}) {
		if (nasAccount == null) {
			EmptyState("calendar_month", "Not connected yet", text = "The calendar comes with the NAS token, which the PC hands over.")
			return@Screen
		}
		if (needPassword.isNotEmpty()) PasswordPanel(needPassword)
		if (problem.isNotEmpty()) Label(problem, color = Theme.colors.danger, maxLines = 3)

		// a line of text as an event
		val found = remember(quick) { if (quick.isBlank()) null else When.parse(quick) }
		Field(quick, placeholder = "morgen 15 Uhr Zahnarzt @Praxis", icon = "calendar_plus", onSubmit = {
			val f = found ?: return@Field
			if (f.title.isEmpty()) return@Field
			scope.launch {
				if (Calendars.save(Calendars.defaultCalendar(), null, Ics.Fields(f.title, f.allDay, f.start, f.end, f.location, "", f.repeat, if (f.allDay) -1 else 10))) quick = ""
			}
		}) { quick = it }
		if (found != null) {
			Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
				Column(Modifier.weight(1f)) {
					Label(found.title.ifEmpty { "Title?" }, style = Theme.Type.label, color = if (found.title.isEmpty()) Theme.colors.textSubtle else Theme.colors.text)
					Label(
						(if (found.allDay) found.start.format(SHORT) else "${found.start.format(SHORT)} · ${found.start.format(TIME)} – ${found.end.format(TIME)}") +
							(if (found.repeat.isNotEmpty()) " · ${found.repeat}" else "") + (if (found.location.isNotEmpty()) " · ${found.location}" else ""),
						style = Theme.Type.small, color = if (found.known) Theme.colors.textMuted else Theme.colors.warning,
					)
				}
				IconButton("pencil", size = 38.dp, iconSize = 18.dp) {
					draft = Draft(Calendars.defaultCalendar(), null, Ics.Fields(found.title, found.allDay, found.start, if (found.allDay) found.end.minusDays(1) else found.end, found.location, "", found.repeat, -1))
				}
			}
		}
		Gap(6)
		MonthGrid(month, selected, byDay, onMonth = { month = it }, onDay = { selected = it; if (it.month != month.month) month = it.withDayOfMonth(1) })
		Gap(6)
		Row(verticalAlignment = Alignment.CenterVertically) {
			SectionLabel(dayTitle(selected), Modifier.weight(1f))
			IconButton("plus", size = 38.dp, iconSize = 20.dp, color = Theme.colors.primaryContainer, enabled = Calendars.writable.isNotEmpty()) { draft = newDraft(selected) }
		}
		val events = byDay[selected].orEmpty()
		if (events.isEmpty()) Label("No events", color = Theme.colors.textSubtle, style = Theme.Type.small)
		else Panel(padding = androidx.compose.foundation.layout.PaddingValues(6.dp)) {
			for (event in events) EventRow(event) { open = event }
		}
	}

	open?.let { event ->
		EventSheet(event, onDismiss = { open = null }, onEdit = {
			open = null
			scope.launch {
				val (fields, overrides) = Calendars.series(event) ?: return@launch
				val shown = if (fields.allDay) fields.copy(end = fields.end.minusDays(1)) else fields
				draft = Draft(event.calendar.href, event.href, shown, overrides)
			}
		}, onDelete = {
			open = null
			scope.launch { Calendars.delete(event) }
		})
	}
	draft?.let { current ->
		Editor(current, onDismiss = { draft = null }) { calendar, fields ->
			scope.launch {
				val saved = if (fields.allDay) fields.copy(end = fields.end.plusDays(1)) else fields
				if (Calendars.save(calendar, current.href, saved)) draft = null
			}
		}
	}
}

private fun newDraft(day: LocalDate): Draft {
	val now = LocalDateTime.now()
	val start = if (day == now.toLocalDate()) now.toLocalDate().atTime((now.hour + 1).coerceAtMost(23), 0) else day.atTime(9, 0)
	return Draft(Calendars.defaultCalendar(), null, Ics.Fields("", false, start, start.plusHours(1)))
}

@Composable
private fun PasswordPanel(user: String) {
	val scope = rememberCoroutineScope()
	var password by remember { mutableStateOf("") }
	Panel(color = Theme.colors.primaryContainer) {
		Label("Baikal password of $user", style = Theme.Type.title)
		Gap(8)
		Field(password, placeholder = "Password", icon = "lock_outline", keyboard = KeyboardType.Password, onSubmit = {
			val given = password
			password = ""
			scope.launch { runCatching { Calendars.givePassword(given) }.onFailure { Calendars.problem.value = it.message.orEmpty() } }
		}) { password = it }
	}
}

@Composable
private fun EventRow(event: Event, onClick: () -> Unit) {
	Row(
		Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.Radius.large)).pressable(onClick = onClick).padding(horizontal = 10.dp, vertical = 10.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Box(Modifier.width(4.dp).height(34.dp).clip(CircleShape).background(colorOf(event.calendar.color, Theme.colors.secondary)))
		Column(Modifier.weight(1f).padding(start = 12.dp)) {
			Label(event.title, style = Theme.Type.body, color = if (event.cancelled) Theme.colors.textSubtle else Theme.colors.text)
			Label(listOf(span(event), event.location).filter { it.isNotEmpty() }.joinToString(" · "), style = Theme.Type.small, color = Theme.colors.textMuted)
		}
		if (event.recurring) Glyph("repeat", size = 16.dp, color = Theme.colors.textSubtle)
	}
}

@Composable
private fun MonthGrid(month: LocalDate, selected: LocalDate, byDay: Map<LocalDate, List<Event>>, onMonth: (LocalDate) -> Unit, onDay: (LocalDate) -> Unit) {
	val start = Calendars.gridStart(month)
	val today = LocalDate.now()
	Panel(padding = androidx.compose.foundation.layout.PaddingValues(10.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Label("${month.month.getDisplayName(DateText.FULL, Locale.getDefault())} ${month.year}", Modifier.weight(1f).padding(start = 6.dp).pressable { onMonth(today.withDayOfMonth(1)); onDay(today) }, style = Theme.Type.title)
			IconButton("chevron_left", size = 38.dp) { onMonth(month.minusMonths(1)) }
			IconButton("chevron_right", size = 38.dp) { onMonth(month.plusMonths(1)) }
		}
		Row(Modifier.fillMaxWidth()) {
			for (i in 0 until 7) Label(start.plusDays(i.toLong()).dayOfWeek.getDisplayName(DateText.SHORT, Locale.getDefault()).take(2), Modifier.weight(1f), style = Theme.Type.tiny, color = if (i >= 5) Theme.colors.secondary else Theme.colors.textSubtle, align = TextAlign.Center)
		}
		for (week in 0 until 6) {
			Row(Modifier.fillMaxWidth()) {
				for (i in 0 until 7) {
					val day = start.plusDays((week * 7 + i).toLong())
					val inMonth = day.month == month.month
					val events = byDay[day].orEmpty()
					Box(Modifier.weight(1f).aspectRatio(1.1f).padding(2.dp).clip(RoundedCornerShape(12.dp))
						.background(when {
							day == today -> Theme.colors.primary
							day == selected -> Theme.colors.primarySoft
							else -> Color.Transparent
						})
						.pressable(shape = RoundedCornerShape(12.dp)) { onDay(day) }, contentAlignment = Alignment.Center) {
						Label("${day.dayOfMonth}", style = Theme.Type.label, color = when {
							day == today -> Theme.colors.onPrimary
							!inMonth -> Theme.colors.textFaint
							else -> Theme.colors.text
						}, align = TextAlign.Center)
						if (events.isNotEmpty()) Row(Modifier.align(Alignment.BottomCenter).padding(bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
							for (event in events.take(3)) Box(Modifier.size(4.dp).clip(CircleShape).background(if (day == today) Theme.colors.onPrimary else colorOf(event.calendar.color, Theme.colors.primary)))
						}
					}
				}
			}
		}
	}
}

@Composable
private fun EventSheet(event: Event, onDismiss: () -> Unit, onEdit: () -> Unit, onDelete: () -> Unit) {
	val context = androidx.compose.ui.platform.LocalContext.current
	var asking by remember { mutableStateOf(false) }
	Sheet(onDismiss, event.title) { close ->
		ListRow(event.start.format(DAY), icon = "clock_outline", subtitle = span(event))
		if (event.location.isNotEmpty()) ListRow(event.location, icon = "map_marker_outline")
		ListRow(event.calendar.name, icon = "calendar_month", iconTint = colorOf(event.calendar.color, Theme.colors.text), subtitle = when (event.calendar.access) {
			"read" -> "Shared with you · read"
			"write" -> "Shared with you"
			else -> ""
		})
		if (event.reminder >= 0) ListRow(if (event.reminder == 0) "At the start" else "${event.reminder} min before", icon = "bell_outline")
		if (event.notes.isNotEmpty()) Label(event.notes, color = Theme.colors.textMuted, maxLines = 12)
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
			if (event.join.isNotEmpty()) PrimaryButton("Join", icon = "video") { runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(event.join))) } }
			if (!event.calendar.readOnly) {
				SoftButton(if (event.recurring) "Edit series" else "Edit", icon = "pencil") { onEdit() }
				SoftButton(if (event.recurring) "Delete series" else "Delete", icon = "delete_outline", tint = Theme.colors.danger) { asking = true }
			}
		}
	}
	if (asking) Confirm(event.title, if (event.recurring) "Every date of the series goes." else span(event), "Delete", danger = true, onDismiss = { asking = false }) { onDelete() }
}

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun Editor(draft: Draft, onDismiss: () -> Unit, onSave: (String, Ics.Fields) -> Unit) {
	var title by remember { mutableStateOf(draft.fields.title) }
	var calendar by remember { mutableStateOf(draft.calendar) }
	var allDay by remember { mutableStateOf(draft.fields.allDay) }
	var start by remember { mutableStateOf(draft.fields.start) }
	var end by remember { mutableStateOf(draft.fields.end) }
	var location by remember { mutableStateOf(draft.fields.location) }
	var notes by remember { mutableStateOf(draft.fields.notes) }
	var repeat by remember { mutableStateOf(draft.fields.repeat ?: "custom") }
	var reminder by remember { mutableStateOf(draft.fields.reminder?.toString() ?: "keep") }
	var picking by remember { mutableStateOf("") }
	val calendars by Calendars.calendars.collectAsState()

	Sheet(onDismiss, if (draft.href == null) "New event" else "Edit") { _ ->
		Field(title, placeholder = "Title") { title = it }
		if (draft.href == null && Calendars.writable.size > 1) FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
			for (c in calendars.filter { !it.readOnly }) Chip(c.name, icon = "circle", active = calendar == c.href, tint = colorOf(c.color, Theme.colors.primary)) { calendar = c.href }
		}
		Row(verticalAlignment = Alignment.CenterVertically) {
			Label("All day", Modifier.weight(1f), color = Theme.colors.textMuted)
			Toggle(allDay) { allDay = it }
		}
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
			Label("From", Modifier.width(44.dp), color = Theme.colors.textMuted, style = Theme.Type.small)
			SoftButton(start.format(SHORT), Modifier.weight(1f)) { picking = "startDate" }
			if (!allDay) SoftButton(start.format(TIME)) { picking = "startTime" }
		}
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
			Label("To", Modifier.width(44.dp), color = Theme.colors.textMuted, style = Theme.Type.small)
			SoftButton(end.format(SHORT), Modifier.weight(1f)) { picking = "endDate" }
			if (!allDay) SoftButton(end.format(TIME)) { picking = "endTime" }
		}
		val repeats = listOf("" to "Once", "daily" to "Daily", "weekly" to "Weekly", "monthly" to "Monthly", "yearly" to "Yearly") + (if (draft.fields.repeat == "custom" || draft.fields.repeat == null) listOf("custom" to "As set") else emptyList())
		Segmented(repeats, repeat) { repeat = it }
		val reminders = listOf("-1" to "None", "0" to "Start", "10" to "10m", "60" to "1h", "1440" to "1d") +
			(draft.fields.reminder?.takeIf { it >= 0 && it.toString() !in listOf("0", "10", "60", "1440") }?.let { listOf(it.toString() to "${it}m") } ?: emptyList()) +
			(if (draft.fields.reminder == null) listOf("keep" to "As set") else emptyList())
		Row(verticalAlignment = Alignment.CenterVertically) {
			Glyph("bell_outline", size = 18.dp, color = Theme.colors.textMuted)
			Box(Modifier.padding(start = 8.dp)) { Segmented(reminders, reminder) { reminder = it } }
		}
		Field(location, placeholder = "Place", icon = "map_marker_outline") { location = it }
		Field(notes, placeholder = "Notes", icon = "text_box_outline", singleLine = false) { notes = it }
		if (draft.overrides > 0) Label("${draft.overrides} moved ${if (draft.overrides == 1) "date stays" else "dates stay"}", style = Theme.Type.small, color = Theme.colors.textSubtle)
		PrimaryButton("Save", Modifier.fillMaxWidth(), icon = "check", enabled = title.isNotBlank() && calendar.isNotEmpty() && !end.isBefore(start)) {
			onSave(calendar, Ics.Fields(title.trim(), allDay, start, end, location.trim(), notes, if (repeat == "custom") null else repeat, if (reminder == "keep") null else reminder.toInt()))
		}
	}

	when (picking) {
		"startDate", "endDate" -> {
			val current = if (picking == "startDate") start else end
			val state = rememberDatePickerState(initialSelectedDateMillis = current.toLocalDate().atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli())
			DatePickerDialog(onDismissRequest = { picking = "" }, confirmButton = {
				TextButton({
					state.selectedDateMillis?.let { millis ->
						val day = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()
						if (picking == "startDate") {
							val length = java.time.Duration.between(start, end)
							start = day.atTime(start.toLocalTime())
							end = start.plus(length)
						} else end = day.atTime(end.toLocalTime())
					}
					picking = ""
				}) { Label("OK", color = Theme.colors.primary) }
			}) { DatePicker(state) }
		}
		"startTime", "endTime" -> {
			val current = if (picking == "startTime") start else end
			val state = rememberTimePickerState(current.hour, current.minute, true)
			Dialog(onDismissRequest = { picking = "" }) {
				Column(Modifier.clip(RoundedCornerShape(28.dp)).background(Theme.colors.layer1).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
					TimePicker(state)
					Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
						TextButton({ picking = "" }) { Label("Cancel", color = Theme.colors.textMuted) }
						TextButton({
							val time = LocalTime.of(state.hour, state.minute)
							if (picking == "startTime") {
								val length = java.time.Duration.between(start, end)
								start = start.toLocalDate().atTime(time)
								end = start.plus(length)
							} else end = end.toLocalDate().atTime(time)
							picking = ""
						}) { Label("OK", color = Theme.colors.primary) }
					}
				}
			}
		}
	}
}

// ── the calendars ──────────────────────────────────────────────────────────
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun CalendarsPage() {
	val scope = rememberCoroutineScope()
	val calendars by Calendars.calendars.collectAsState()
	val members by Calendars.members.collectAsState()
	val sharees by Calendars.sharees.collectAsState()
	val problem by Calendars.problem.collectAsState()
	var sharing by remember { mutableStateOf("") }
	var leaving by remember { mutableStateOf<DavCalendar?>(null) }
	var colouring by remember { mutableStateOf<DavCalendar?>(null) }
	var newName by remember { mutableStateOf("") }
	var newColor by remember { mutableStateOf(PALETTE[5]) }
	LaunchedEffect(Unit) { if (calendars.isEmpty()) Calendars.refresh() }

	Screen("Calendars") {
		if (problem.isNotEmpty()) Label(problem, color = Theme.colors.danger, maxLines = 3)
		for (calendar in calendars) {
			Panel(padding = androidx.compose.foundation.layout.PaddingValues(12.dp)) {
				Row(verticalAlignment = Alignment.CenterVertically) {
					Box(Modifier.size(26.dp).clip(CircleShape).background(colorOf(calendar.color, Theme.colors.secondary)).pressable(shape = CircleShape) { colouring = calendar })
					var name by remember(calendar.href, calendar.name) { mutableStateOf(calendar.name) }
					Box(Modifier.weight(1f).padding(horizontal = 10.dp)) {
						Field(name, onSubmit = { if (name.isNotBlank() && name != calendar.name) scope.launch { Calendars.changeCalendar(calendar.href, name = name.trim()) } }) { name = it }
					}
					if (calendar.mine) IconButton("account_multiple_plus", size = 40.dp, iconSize = 20.dp, color = if (sharing == calendar.href) Theme.colors.primaryContainer else Color.Transparent) {
						sharing = if (sharing == calendar.href) "" else calendar.href
						if (sharing.isNotEmpty()) scope.launch { Calendars.loadSharing(calendar.href) }
					}
					IconButton(if (calendar.mine) "delete_outline" else "logout", size = 40.dp, iconSize = 20.dp, tint = Theme.colors.danger) { leaving = calendar }
				}
				if (!calendar.mine) Label(if (calendar.readOnly) "Shared with you · read" else "Shared with you", Modifier.padding(start = 36.dp, top = 4.dp), style = Theme.Type.small, color = Theme.colors.textMuted)
				val shared = sharees[calendar.href].orEmpty()
				if (calendar.mine && shared.isNotEmpty() && sharing != calendar.href) Label("Shared · ${shared.size}", Modifier.padding(start = 36.dp, top = 4.dp), style = Theme.Type.small, color = Theme.colors.primary)
				if (sharing == calendar.href) {
					Gap(8)
					if (members.isEmpty()) Label("No other members in pshell-core", style = Theme.Type.small, color = Theme.colors.textSubtle)
					for (member in members) {
						val entry = shared.firstOrNull { it.email.equals(member.email, ignoreCase = true) }
						Column(Modifier.padding(vertical = 4.dp)) {
							Label(member.display.ifEmpty { member.name }, style = Theme.Type.label)
							Gap(4)
							Segmented(listOf("" to "No", "read" to "Read", "write" to "Read & write"), if (entry == null) "" else if (entry.write) "write" else "read") { mode ->
								scope.launch { Calendars.share(calendar.href, member, mode) }
							}
						}
					}
				}
			}
			Gap(8)
		}
		SectionLabel("New calendar")
		Panel(padding = androidx.compose.foundation.layout.PaddingValues(12.dp)) {
			Field(newName, placeholder = "Name", onSubmit = {
				if (newName.isNotBlank()) scope.launch { if (Calendars.makeCalendar(newName.trim(), newColor)) newName = "" }
			}) { newName = it }
			Gap(8)
			FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
				for (hex in PALETTE) Box(Modifier.size(30.dp).clip(CircleShape).background(colorOf(hex, Theme.colors.primary))
					.border(if (hex == newColor) 3.dp else 0.dp, Theme.colors.text, CircleShape).pressable(shape = CircleShape) { newColor = hex })
			}
			Gap(10)
			PrimaryButton("Add", Modifier.fillMaxWidth(), icon = "plus", enabled = newName.isNotBlank()) {
				scope.launch { if (Calendars.makeCalendar(newName.trim(), newColor)) newName = "" }
			}
		}
	}

	leaving?.let { calendar ->
		Confirm(calendar.name, if (calendar.mine) "The calendar and all its events go, for everyone it is shared with." else "It is no longer shared with you.", if (calendar.mine) "Delete" else "Leave", danger = true, onDismiss = { leaving = null }) {
			scope.launch { Calendars.deleteCalendar(calendar.href) }
		}
	}
	colouring?.let { calendar ->
		Sheet({ colouring = null }, calendar.name) { close ->
			FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
				for (hex in PALETTE) Box(Modifier.size(40.dp).clip(CircleShape).background(colorOf(hex, Theme.colors.primary)).pressable(shape = CircleShape) {
					scope.launch { Calendars.changeCalendar(calendar.href, color = hex) }
					close()
				})
			}
		}
	}
}
