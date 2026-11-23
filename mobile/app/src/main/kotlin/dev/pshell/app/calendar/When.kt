package dev.pshell.app.calendar

import java.time.LocalDate
import java.time.LocalDateTime

/**
 * A line of text as an event, the rules of the shell's NasCalendar.parseText:
 * "morgen 15 Uhr Zahnarzt @Praxis", "Fr 18:30-20 Kino", "24.12. ganztägig
 * Weihnachten", "jeden Montag 9 Standup 15min", "in 2 Stunden Pizza",
 * "tomorrow 3pm dentist".
 */
object When {
	data class Found(
		val title: String,
		val start: LocalDateTime,
		val end: LocalDateTime,
		val allDay: Boolean,
		val location: String,
		val repeat: String,
		/** a day or a time was found */
		val known: Boolean,
	)

	private val days = listOf("so|sonntag|sun|sunday", "mo|montag|mon|monday", "di|dienstag|tue|tuesday", "mi|mittwoch|wed|wednesday", "do|donnerstag|thu|thursday", "fr|freitag|fri|friday", "sa|samstag|sat|saturday")

	private fun weekday(word: String): Int = days.indexOfFirst { word.lowercase().trimEnd('.') in it.split("|") }

	fun parse(input: String, now: LocalDateTime = LocalDateTime.now()): Found {
		var t = " ${input.replace(Regex("\\s+"), " ").trim()} "
		val today = now.toLocalDate()
		var day: LocalDate? = null
		var hour = -1
		var minute = 0
		var endHour = -1
		var endMinute = 0
		var length = 60.0
		var allDay = false
		var location = ""
		var repeat = ""
		var exact: LocalDateTime? = null

		// a match is cut out of the text; fn returning false puts it back
		fun take(pattern: String, fn: (MatchResult) -> Boolean = { true }): Boolean {
			val m = Regex(pattern, RegexOption.IGNORE_CASE).find(t) ?: return false
			val before = t
			t = t.substring(0, m.range.first) + " " + t.substring(m.range.last + 1)
			if (!fn(m)) {
				t = before
				return false
			}
			return true
		}

		fun nextDay(wd: Int, strict: Boolean): LocalDate {
			val now = today.dayOfWeek.value % 7
			val add = (wd - now + 7) % 7
			return today.plusDays(if (add == 0 && strict) 7L else add.toLong())
		}

		fun clock(h: String, m: String?, half: String?): Pair<Int, Int> {
			var hh = h.toInt()
			val mm = m?.takeIf { it.isNotEmpty() }?.toInt() ?: 0
			if (half != null && half.lowercase() == "pm" && hh < 12) hh += 12
			if (half != null && half.lowercase() == "am" && hh == 12) hh = 0
			return hh to mm
		}

		take("""\s@\s*(.+?)\s*$""") { location = it.groupValues[1]; true }
		take("""\s(ganzt(?:ä|ae)gig|ganztags|all[- ]day)(?=\s)""") { allDay = true; true }
		take("""\s(?:jede[nrs]?|every)\s+(?:tag|day)(?=\s)""") { repeat = "daily"; true }
		take("""\s(t(?:ä|ae)glich|daily)(?=\s)""") { repeat = "daily"; true }
		take("""\s(w(?:ö|oe)chentlich|weekly)(?=\s)""") { repeat = "weekly"; true }
		take("""\s(?:jede[nrs]?|every)\s+(?:monat|month)(?=\s)|\s(monatlich|monthly)(?=\s)""") { repeat = "monthly"; true }
		take("""\s(?:jede[nrs]?|every)\s+(?:jahr|year)(?=\s)|\s(j(?:ä|ae)hrlich|yearly)(?=\s)""") { repeat = "yearly"; true }
		take("""\s(?:jede[nrs]?|every)\s+([a-zä]+)(?=\s)""") {
			val wd = weekday(it.groupValues[1])
			if (wd < 0) false else { repeat = "weekly"; day = nextDay(wd, false); true }
		}
		take("""\sin\s+(\d+)\s*(min(?:uten)?|minutes?|std\.?|stunden?|h|hours?)(?=\s)""") {
			val n = it.groupValues[1].toLong()
			exact = if (it.groupValues[2].lowercase().startsWith("m")) now.plusMinutes(n) else now.plusHours(n)
			true
		}
		take("""\sin\s+(\d+)\s*(tag(?:en)?|days?|wochen?|weeks?)(?=\s)""") {
			val n = it.groupValues[1].toLong()
			day = if (it.groupValues[2].lowercase().startsWith("w")) today.plusWeeks(n) else today.plusDays(n)
			true
		}
		take("""\s(?:am\s+|on\s+)?(\d{4})-(\d{2})-(\d{2})(?=\s)""") {
			runCatching { LocalDate.of(it.groupValues[1].toInt(), it.groupValues[2].toInt(), it.groupValues[3].toInt()) }.getOrNull()?.let { d -> day = d; true } ?: false
		}
		take("""\s(?:am\s+|on\s+)?(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4})?)?(?=\s)""") {
			val d = it.groupValues[1].toInt()
			val mo = it.groupValues[2].toInt()
			if (mo !in 1..12 || d !in 1..31) return@take false
			val y = it.groupValues[3]
			val year = if (y.isEmpty()) today.year else if (y.length == 2) 2000 + y.toInt() else y.toInt()
			var date = runCatching { LocalDate.of(year, mo, d) }.getOrNull() ?: return@take false
			if (y.isEmpty() && date.isBefore(today)) date = date.plusYears(1)
			day = date
			true
		}
		take("""\s((?:ü|ue)bermorgen|day after tomorrow)(?=\s)""") { day = today.plusDays(2); true }
		take("""\s(morgen|tomorrow)(?=\s)""") { day = today.plusDays(1); true }
		take("""\s(heute|today|tonight)(?=\s)""") { day = today; true }
		if (day == null) take("""\s(?:(n(?:ä|ae)chste[nrs]?|next)\s+|am\s+|on\s+)?(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)\.?(?=\s)""") {
			day = nextDay(weekday(it.groupValues[2]), it.groupValues[1].isNotEmpty())
			true
		}
		if (day == null) take("""^\s(?:am\s+)?(mo|di|mi|do|fr|sa|so)\.?(?=\s)""") { day = nextDay(weekday(it.groupValues[1]), false); true }
		take("""\s(?:um\s+|at\s+|von\s+|from\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(uhr|h|am|pm)?\s*(?:-|–|bis|to|until)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(uhr|h|am|pm)?(?=\s)""") {
			val g = it.groupValues
			if (g[1].toInt() > 23 || g[4].toInt() > 24) return@take false
			val from = clock(g[1], g[2], g[3].ifEmpty { g[6] }.ifEmpty { null })
			val to = clock(g[4], g[5], g[6].ifEmpty { null })
			hour = from.first
			minute = from.second
			endHour = to.first
			endMinute = to.second
			true
		}
		if (hour < 0) take("""\s(?:um\s+|at\s+|ab\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(uhr|h|am|pm)(?=\s)|\s(?:um\s+|at\s+|ab\s+)?(\d{1,2}):(\d{2})(?=\s)|\s(?:um|at|ab)\s+(\d{1,2})(?=\s)""") {
			val g = it.groupValues
			val at = when {
				g[1].isNotEmpty() -> clock(g[1], g[2], g[3])
				g[4].isNotEmpty() -> clock(g[4], g[5], null)
				else -> clock(g[6], null, null)
			}
			hour = at.first
			minute = at.second
			true
		}
		if (hour < 0 && day != null) take("""\s(?:um\s+|at\s+|ab\s+)?(\d{1,2})\.(\d{2})(?=\s)""") {
			if (it.groupValues[1].toInt() > 23 || it.groupValues[2].toInt() > 59) return@take false
			hour = it.groupValues[1].toInt()
			minute = it.groupValues[2].toInt()
			true
		}
		take("""\s(?:f(?:ü|ue)r\s+|for\s+)?(\d+(?:[.,]\d+)?)\s*(min(?:uten)?\.?|minutes?|std\.?|stunden?|h|hours?)(?=\s)""") {
			val n = it.groupValues[1].replace(",", ".").toDouble()
			length = if (it.groupValues[2].lowercase().startsWith("m")) n else n * 60
			true
		}
		if (hour < 0 && day != null) take("""^\s+(\d{1,2})(?=\s)""") {
			if (it.groupValues[1].toInt() > 23) false else { hour = it.groupValues[1].toInt(); true }
		}
		val title = t.replace(Regex("""\s(am|um|at|on|von|from|ab|bis)(?=\s)""", RegexOption.IGNORE_CASE), " ").replace(Regex("\\s+"), " ").trim().trimStart('-', '–', ':', ',', ' ')
		val known = day != null || exact != null || hour >= 0
		val minutes = length.toLong()
		exact?.let { return Found(title, it, it.plusMinutes(minutes), false, location, repeat, true) }
		if (hour in 0..23 && !allDay) {
			val base = day ?: today
			var start = base.atTime(hour, minute.coerceAtMost(59))
			if (day == null && start.isBefore(now)) start = start.plusDays(1)
			var end = if (endHour >= 0) start.toLocalDate().atStartOfDay().plusHours(endHour.toLong()).plusMinutes(endMinute.toLong()) else start.plusMinutes(minutes)
			if (!end.isAfter(start)) end = end.plusDays(1)
			return Found(title, start, end, false, location, repeat, known)
		}
		val start = (day ?: today).atStartOfDay()
		return Found(title, start, start.plusDays(1), true, location, repeat, known)
	}
}
