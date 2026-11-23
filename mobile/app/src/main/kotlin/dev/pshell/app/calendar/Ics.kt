package dev.pshell.app.calendar

import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID

/**
 * iCalendar as the shell's scripts/nas/baikal.py writes it, for the phone: events
 * of a REPORT read, a new event built, an event that exists edited in place (only
 * the fields of the editor replaced, alarms, attendees and what DAVx5 wrote stay).
 * Times are wall clock in the phone's zone; whole days have an exclusive end.
 */
object Ics {
	const val PRODID = "-//pshell//Baikal calendar (phone)//EN"
	val REPEATS = mapOf("daily" to "DAILY", "weekly" to "WEEKLY", "monthly" to "MONTHLY", "yearly" to "YEARLY")

	/** the editor's fields; [repeat] null or "custom" and [reminder] null keep what is there */
	data class Fields(
		val title: String,
		val allDay: Boolean,
		val start: LocalDateTime,
		val end: LocalDateTime,
		val location: String = "",
		val notes: String = "",
		val repeat: String? = "",
		val reminder: Int? = -1,
	)

	/** one line split: name, parameters, value */
	data class Prop(val name: String, val params: Map<String, String>, val value: String)

	fun unfold(text: String): List<String> = text.replace(Regex("\r?\n[ \t]"), "").replace("\r\n", "\n").split("\n")

	fun fold(line: String): String {
		if (line.toByteArray().size <= 75) return line
		val out = StringBuilder()
		var part = 0
		var limit = 75
		for (ch in line) {
			val size = ch.toString().toByteArray().size
			if (part + size > limit) {
				out.append("\r\n ")
				part = 0
				limit = 74
			}
			out.append(ch)
			part += size
		}
		return out.toString()
	}

	fun escape(value: String) = value.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\r\n", "\n").replace("\n", "\\n")

	fun unescape(value: String) = Regex("""\\([\\;,nN])""").replace(value) { if (it.groupValues[1] in listOf("n", "N")) "\n" else it.groupValues[1] }

	fun split(line: String): Prop {
		var quoted = false
		var at = -1
		for ((i, ch) in line.withIndex()) {
			if (ch == '"') quoted = !quoted
			else if (ch == ':' && !quoted) {
				at = i
				break
			}
		}
		if (at < 0) return Prop(line.uppercase(), emptyMap(), "")
		val head = line.substring(0, at).split(";")
		val params = head.drop(1).associate { p -> p.substringBefore("=").uppercase() to p.substringAfter("=", "").trim('"') }
		return Prop(head[0].uppercase(), params, line.substring(at + 1))
	}

	/** a time of the file in the phone's zone; whole days as their midnight, flagged */
	fun time(value: String, params: Map<String, String>, zone: ZoneId): Pair<LocalDateTime, Boolean>? {
		val digits = value.trim()
		if (params["VALUE"]?.uppercase() == "DATE" || Regex("""\d{8}""").matches(digits)) {
			val day = runCatching { LocalDate.parse(digits.take(8), DateTimeFormatter.BASIC_ISO_DATE) }.getOrNull() ?: return null
			return day.atStartOfDay() to true
		}
		val stamp = runCatching { LocalDateTime.parse(digits.take(15), DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss")) }.getOrNull() ?: return null
		if (digits.endsWith("Z")) return stamp.atZone(ZoneOffset.UTC).withZoneSameInstant(zone).toLocalDateTime() to false
		val source = params["TZID"]?.let { runCatching { ZoneId.of(it) }.getOrNull() } ?: zone
		return stamp.atZone(source).withZoneSameInstant(zone).toLocalDateTime() to false
	}

	fun duration(value: String): Duration {
		val m = Regex("""([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?""").matchEntire(value.trim()) ?: return Duration.ZERO
		val g = m.groupValues
		val seconds = ((g[2].toLongOrNull() ?: 0) * 7 + (g[3].toLongOrNull() ?: 0)) * 86400 + (g[4].toLongOrNull() ?: 0) * 3600 + (g[5].toLongOrNull() ?: 0) * 60 + (g[6].toLongOrNull() ?: 0)
		return Duration.ofSeconds(if (g[1] == "-") -seconds else seconds)
	}

	/** [begin, end] line indexes of the top-level components of a kind */
	fun components(lines: List<String>, kind: String): List<IntRange> {
		val out = mutableListOf<IntRange>()
		var depth = 0
		var begin = -1
		for ((i, line) in lines.withIndex()) {
			val upper = line.uppercase()
			if (upper.startsWith("BEGIN:")) {
				depth += 1
				if (upper == "BEGIN:$kind" && depth == 2) begin = i
			} else if (upper.startsWith("END:")) {
				if (upper == "END:$kind" && depth == 2 && begin >= 0) {
					out += begin..i
					begin = -1
				}
				depth -= 1
			}
		}
		return out
	}

	private fun own(lines: List<String>, range: IntRange): List<Int> {
		var depth = 0
		val out = mutableListOf<Int>()
		for (i in range.first + 1 until range.last) {
			val upper = lines[i].uppercase()
			if (upper.startsWith("BEGIN:")) depth += 1
			else if (upper.startsWith("END:")) depth -= 1
			else if (depth == 0) out += i
		}
		return out
	}

	private fun alarms(lines: List<String>, range: IntRange): List<IntRange> {
		val out = mutableListOf<IntRange>()
		var start = -1
		for (i in range.first + 1 until range.last) {
			val upper = lines[i].uppercase()
			if (upper == "BEGIN:VALARM") start = i
			else if (upper == "END:VALARM" && start >= 0) {
				out += start..i
				start = -1
			}
		}
		return out
	}

	private fun master(lines: List<String>): Pair<IntRange, Int> {
		val events = components(lines, "VEVENT")
		val found = events.firstOrNull { range -> own(lines, range).none { split(lines[it]).name == "RECURRENCE-ID" } }
			?: throw IllegalStateException("No series in this event")
		return found to events.size - 1
	}

	/** minutes before the start of the first alarm relative to the start, or -1 */
	fun alarmOf(lines: List<String>, range: IntRange): Int {
		for (alarm in alarms(lines, range)) {
			for (i in alarm) {
				val prop = split(lines[i])
				if (prop.name != "TRIGGER") continue
				if (prop.params["VALUE"]?.uppercase() == "DATE-TIME" || prop.params["RELATED"]?.uppercase() == "END") return -1
				val minutes = -duration(prop.value).toMinutes()
				return if (minutes >= 0) minutes.toInt() else -1
			}
		}
		return -1
	}

	/** the events of a REPORT's calendar-data (already expanded by the server) */
	fun events(text: String, href: String, etag: String, calendar: DavCalendar, zone: ZoneId): List<Event> {
		val lines = unfold(text)
		val out = mutableListOf<Event>()
		for (range in components(lines, "VEVENT")) {
			val fields = HashMap<String, Prop>()
			for (i in own(lines, range)) {
				val prop = split(lines[i])
				fields.putIfAbsent(prop.name, prop)
			}
			val (start, allDay) = fields["DTSTART"]?.let { time(it.value, it.params, zone) } ?: continue
			var end = fields["DTEND"]?.let { time(it.value, it.params, zone)?.first }
			if (end == null && fields["DURATION"] != null) end = start.plus(duration(fields["DURATION"]!!.value))
			if (end == null) end = if (allDay) start.plusDays(1) else start
			val location = fields["LOCATION"]?.let { unescape(it.value) }.orEmpty()
			val notes = fields["DESCRIPTION"]?.let { unescape(it.value) }.orEmpty()
			val join = Regex("""https://\S*(teams\.microsoft|zoom\.us|meet\.google|meet\.jit)\S*""").find("$location\n$notes")?.value.orEmpty()
			out += Event(
				id = "${fields["UID"]?.value.orEmpty()}:${fields["RECURRENCE-ID"]?.value ?: start}",
				href = href,
				etag = etag,
				calendar = calendar,
				title = fields["SUMMARY"]?.let { unescape(it.value) } ?: "(No title)",
				start = start,
				end = end,
				allDay = allDay,
				location = location,
				notes = notes,
				join = join,
				recurring = fields["RECURRENCE-ID"] != null || fields["RRULE"] != null,
				cancelled = fields["STATUS"]?.value?.uppercase() == "CANCELLED",
				reminder = alarmOf(lines, range),
			)
		}
		return out
	}

	/** the series of an event as the editor shows it: fields, and how many moved instances it has */
	fun describe(text: String, zone: ZoneId): Pair<Fields, Int> {
		val lines = unfold(text)
		val (range, overrides) = master(lines)
		val fields = HashMap<String, Prop>()
		for (i in own(lines, range)) split(lines[i]).let { fields.putIfAbsent(it.name, it) }
		val (start, allDay) = fields["DTSTART"]?.let { time(it.value, it.params, zone) } ?: throw IllegalStateException("The event has no start")
		val end = fields["DTEND"]?.let { time(it.value, it.params, zone)?.first }
			?: fields["DURATION"]?.let { start.plus(duration(it.value)) }
			?: if (allDay) start.plusDays(1) else start
		val rule = fields["RRULE"]?.value.orEmpty()
		val parts = rule.split(";").filter { it.isNotEmpty() }.associate { it.substringBefore("=") to it.substringAfter("=", "") }
		val repeat = when {
			rule.isEmpty() -> ""
			parts.keys.all { it in setOf("FREQ", "INTERVAL", "WKST") } && (parts["INTERVAL"] ?: "1") == "1" -> REPEATS.entries.firstOrNull { it.value == parts["FREQ"] }?.key ?: "custom"
			else -> "custom"
		}
		val count = alarms(lines, range).size
		return Fields(
			title = fields["SUMMARY"]?.let { unescape(it.value) }.orEmpty(),
			allDay = allDay,
			start = start,
			end = end,
			location = fields["LOCATION"]?.let { unescape(it.value) }.orEmpty(),
			notes = fields["DESCRIPTION"]?.let { unescape(it.value) }.orEmpty(),
			repeat = repeat,
			reminder = when (count) {
				0 -> -1
				1 -> alarmOf(lines, range)
				else -> null
			},
		) to overrides
	}

	private val STAMP = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC)
	private val LOCAL = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss")

	private fun timeLine(name: String, value: LocalDateTime, allDay: Boolean, zone: ZoneId): String =
		if (allDay) "$name;VALUE=DATE:${value.toLocalDate().format(DateTimeFormatter.BASIC_ISO_DATE)}"
		else if (zone.id == "UTC" || zone.id == "Z") "$name:${STAMP.format(value.atZone(zone).toInstant())}"
		else "$name;TZID=${zone.id}:${value.format(LOCAL)}"

	/** central Europe written out, for zones that keep its rules */
	fun vtimezone(zone: ZoneId): List<String> {
		val jan = ZonedDateTime.of(2026, 1, 15, 12, 0, 0, 0, zone).offset.totalSeconds
		val jul = ZonedDateTime.of(2026, 7, 15, 12, 0, 0, 0, zone).offset.totalSeconds
		if (jan != 3600 || jul != 7200 || !zone.id.startsWith("Europe/")) return emptyList()
		return listOf(
			"BEGIN:VTIMEZONE", "TZID:${zone.id}",
			"BEGIN:DAYLIGHT", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200", "TZNAME:CEST", "DTSTART:19700329T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU", "END:DAYLIGHT",
			"BEGIN:STANDARD", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "TZNAME:CET", "DTSTART:19701025T030000", "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU", "END:STANDARD",
			"END:VTIMEZONE",
		)
	}

	private fun checked(fields: Fields): Fields {
		require(fields.title.isNotBlank()) { "The event needs a title" }
		if (fields.allDay) {
			val start = fields.start.toLocalDate().atStartOfDay()
			var end = fields.end.toLocalDate().atStartOfDay()
			if (!end.isAfter(start)) end = start.plusDays(1)
			return fields.copy(title = fields.title.trim(), start = start, end = end)
		}
		require(!fields.end.isBefore(fields.start)) { "The end is before the start" }
		return fields.copy(title = fields.title.trim())
	}

	private fun alarm(minutes: Int): List<String> {
		val trigger = if (minutes == 0) "-PT0M" else if (minutes % 1440 == 0) "-P${minutes / 1440}D" else "-PT${minutes}M"
		return listOf("BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:$trigger", "END:VALARM")
	}

	/** a new event: its uid and text */
	fun build(raw: Fields, zone: ZoneId, now: Instant = Instant.now()): Pair<String, String> {
		val fields = checked(raw)
		val uid = "${UUID.randomUUID()}@pshell"
		val stamp = STAMP.format(now)
		val event = mutableListOf("BEGIN:VEVENT", "UID:$uid", "DTSTAMP:$stamp", "CREATED:$stamp", "LAST-MODIFIED:$stamp",
			"SUMMARY:${escape(fields.title)}", timeLine("DTSTART", fields.start, fields.allDay, zone), timeLine("DTEND", fields.end, fields.allDay, zone))
		if (fields.location.isNotEmpty()) event += "LOCATION:${escape(fields.location)}"
		if (fields.notes.isNotEmpty()) event += "DESCRIPTION:${escape(fields.notes)}"
		REPEATS[fields.repeat]?.let { event += "RRULE:FREQ=$it" }
		if ((fields.reminder ?: -1) >= 0) event += alarm(fields.reminder!!)
		event += "END:VEVENT"
		val lines = listOf("BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:$PRODID", "CALSCALE:GREGORIAN") +
			(if (fields.allDay) emptyList() else vtimezone(zone)) + event + "END:VCALENDAR"
		return uid to lines.joinToString("\r\n") { fold(it) } + "\r\n"
	}

	/** the text of an event that exists with the editor's fields put into its series */
	fun edit(text: String, raw: Fields, zone: ZoneId, now: Instant = Instant.now()): String {
		val fields = checked(raw)
		var lines = unfold(text.trimEnd('\r', '\n'))
		val (range, _) = master(lines)
		val keep = mutableListOf<String>()
		var sequence = 0
		for (i in own(lines, range)) {
			val prop = split(lines[i])
			when {
				prop.name == "SEQUENCE" -> sequence = (prop.value.trim().toIntOrNull() ?: 0) + 1
				prop.name in setOf("SUMMARY", "LOCATION", "DESCRIPTION", "DTSTART", "DTEND", "DURATION", "DTSTAMP", "LAST-MODIFIED") -> {}
				prop.name == "RRULE" && fields.repeat != null && fields.repeat != "custom" -> {}
				else -> keep += lines[i]
			}
		}
		val stamp = STAMP.format(now)
		val event = (listOf("BEGIN:VEVENT") + keep + listOf("DTSTAMP:$stamp", "LAST-MODIFIED:$stamp", "SEQUENCE:$sequence",
			"SUMMARY:${escape(fields.title)}", timeLine("DTSTART", fields.start, fields.allDay, zone), timeLine("DTEND", fields.end, fields.allDay, zone))).toMutableList()
		if (fields.location.isNotEmpty()) event += "LOCATION:${escape(fields.location)}"
		if (fields.notes.isNotEmpty()) event += "DESCRIPTION:${escape(fields.notes)}"
		REPEATS[fields.repeat]?.let { event += "RRULE:FREQ=$it" }
		when {
			fields.reminder == null -> for (alarm in alarms(lines, range)) event += lines.subList(alarm.first, alarm.last + 1)
			fields.reminder >= 0 -> event += alarm(fields.reminder)
		}
		event += "END:VEVENT"
		lines = lines.subList(0, range.first) + event + lines.subList(range.last + 1, lines.size)
		if (!fields.allDay && lines.none { it == "TZID:${zone.id}" }) {
			val timezone = vtimezone(zone)
			if (timezone.isNotEmpty()) {
				val at = lines.indexOfFirst { it.uppercase().startsWith("BEGIN:VEVENT") || it.uppercase().startsWith("BEGIN:VTODO") }
				lines = lines.subList(0, at) + timezone + lines.subList(at, lines.size)
			}
		}
		return lines.joinToString("\r\n") { fold(it) } + "\r\n"
	}
}

/** a calendar of the account: [access] "" not shared, owner (shared by me), read or write (shared with me) */
data class DavCalendar(val href: String, val name: String, val color: String, val access: String = "") {
	val readOnly get() = access == "read"
	val mine get() = access == "" || access == "owner"
}

data class Event(
	val id: String,
	val href: String,
	val etag: String,
	val calendar: DavCalendar,
	val title: String,
	val start: LocalDateTime,
	val end: LocalDateTime,
	val allDay: Boolean,
	val location: String,
	val notes: String,
	val join: String,
	val recurring: Boolean,
	val cancelled: Boolean,
	val reminder: Int,
) {
	/** the days it shows on */
	fun days(): List<LocalDate> {
		val last = if (end.isAfter(start)) end.minusNanos(1) else end
		val out = mutableListOf<LocalDate>()
		var day = start.toLocalDate()
		while (!day.isAfter(last.toLocalDate()) && out.size < 400) {
			out += day
			day = day.plusDays(1)
		}
		return out
	}
}
