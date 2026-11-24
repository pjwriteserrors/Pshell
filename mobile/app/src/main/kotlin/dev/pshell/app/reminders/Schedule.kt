package dev.pshell.app.reminders

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.time.temporal.TemporalAdjusters

/**
 * When a reminder is due, without the server: the phone schedules its own
 * alarms from the synced list so a reminder fires offline too. Pure, so the
 * unit tests cover it (RemindersTest).
 */
object Schedule {
	/** An alarm to set: [occurrence] is the reminder's scheduled time (its id on the server), [at] when the phone fires. */
	data class Due(val id: String, val occurrence: Long, val at: Long)

	const val ALL_DAY_HOUR = 9

	private fun epoch(time: LocalDateTime, zone: ZoneId) = time.atZone(zone).toEpochSecond()

	/** The next [limit] occurrences strictly after [after] (epoch s), by `at` and `repeat` in [zone]. */
	fun occurrences(reminder: Reminder, after: Long, zone: ZoneId, limit: Int = 1): List<Long> {
		val at = reminder.at ?: return emptyList()
		val given = Instant.ofEpochSecond(at).atZone(zone).toLocalDateTime()
		// as core: an all-day one rings at 9
		val base = if (reminder.allDay) given.toLocalDate().atTime(ALL_DAY_HOUR, 0) else given
		val repeat = reminder.repeat ?: return epoch(base, zone).let { if (it > after) listOf(it) else emptyList() }
		val until = repeat.until ?: Long.MAX_VALUE
		val n = repeat.n.coerceAtLeast(1).toLong()
		val out = ArrayList<Long>()
		val from = Instant.ofEpochSecond(maxOf(after, at)).atZone(zone).toLocalDateTime()
		// where to start counting, a step before the first that can be after [after]
		val unit = when (repeat.every) { "day" -> ChronoUnit.DAYS; "week" -> ChronoUnit.WEEKS; "month" -> ChronoUnit.MONTHS; else -> ChronoUnit.YEARS }
		val start = maxOf(0L, unit.between(base, from) / n - 1)
		var guard = 0
		if (repeat.every == "week" && repeat.days.isNotEmpty()) {
			val monday = base.toLocalDate().with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
			var week = start
			while (out.size < limit && guard++ < 2000) {
				for (day in repeat.days.sorted()) {
					val date = monday.plusWeeks(week * n).plusDays((day - 1).toLong())
					if (date.isBefore(base.toLocalDate())) continue
					val time = epoch(date.atTime(base.toLocalTime()), zone)
					if (time > until) return out
					if (time > after && out.size < limit) out += time
				}
				week++
			}
			return out
		}
		var k = start
		while (out.size < limit && guard++ < 5000) {
			val step = k * n
			val time = epoch(when (repeat.every) {
				"day" -> base.plusDays(step)
				"week" -> base.plusWeeks(step)
				"month" -> base.plusMonths(step)
				else -> base.plusYears(step)
			}, zone)
			if (time > until) break
			if (time > after) out += time
			k++
		}
		return out
	}

	/**
	 * The alarm a reminder needs now: its snooze, or the first occurrence after
	 * [now] the phone has not shown or seen acknowledged ([seen]). Server's
	 * `next` first when it is still ahead, then the phone's own count.
	 */
	fun next(reminder: Reminder, now: Long, zone: ZoneId, seen: (String, Long) -> Boolean): Due? {
		if (!reminder.open) return null
		reminder.snoozedUntil?.let { until ->
			if (until > now) return Due(reminder.id, reminder.pending.maxOrNull() ?: until, until)
		}
		if (reminder.trigger != "time") return null
		val candidates = (listOfNotNull(reminder.next) + occurrences(reminder, now, zone, 4)).filter { it > now }.distinct().sorted()
		val first = candidates.firstOrNull { !seen(reminder.id, it) } ?: return null
		return Due(reminder.id, first, first)
	}

	/** Every alarm of the list. */
	fun plan(list: List<Reminder>, now: Long, zone: ZoneId, seen: (String, Long) -> Boolean): List<Due> =
		list.mapNotNull { next(it, now, zone, seen) }.sortedBy { it.at }

	/** Alarms planned earlier whose time passed while the phone could not fire them (off, killed): shown now, up to [window] s late. */
	fun missed(planned: Collection<Due>, now: Long, window: Long, seen: (String, Long) -> Boolean): List<Due> =
		planned.filter { it.at <= now && now - it.at <= window && !seen(it.id, it.occurrence) }
}

/**
 * One notification per reminder; this decides what a fire (the phone's own
 * alarm, core's event, `/active` after being offline) does to it, so the same
 * occurrence never rings twice.
 */
object Dedupe {
	/** What the phone shows for a reminder now. */
	data class Shown(val id: String, val occurrence: Long, val level: String, val escalated: Boolean, val at: Long)

	enum class Action { Ignore, Show, Escalate, Adopt }

	/** Within this many seconds two fires of one reminder with different occurrences are one (a snooze, a trigger seen by phone and core). */
	const val SAME = 300L

	fun decide(shown: Shown?, acked: Boolean, occurrence: Long, escalated: Boolean, now: Long): Action {
		if (acked) return Action.Ignore
		if (shown == null) return Action.Show
		if (shown.occurrence == occurrence) return if (escalated && !shown.escalated) Action.Escalate else Action.Ignore
		if (kotlin.math.abs(now - shown.at) <= SAME) return if (escalated && !shown.escalated) Action.Escalate else Action.Adopt
		// an older occurrence is still showing; a new one replaces it
		return if (occurrence > shown.occurrence) Action.Show else Action.Ignore
	}

	/** The level a fire is shown at: escalated is fullscreen. */
	fun level(level: String, escalated: Boolean) = if (escalated && level == "important") "fullscreen" else level

	/** When an important one, shown at [shownAt], is escalated by the phone itself; null for never. */
	fun escalateAt(level: String, escalateMin: Int, occurrence: Long, shownAt: Long): Long? =
		if (level != "important" || escalateMin <= 0) null else maxOf(occurrence, shownAt) + escalateMin * 60L

	/** A showing one that `/active` no longer lists was acknowledged elsewhere; one just shown may not have reached core yet. */
	fun goneElsewhere(shown: Shown, active: Set<Pair<String, Long>>, activeIds: Set<String>, now: Long): Boolean {
		if (now - shown.at < 120) return false
		return (shown.id to shown.occurrence) !in active && shown.id !in activeIds
	}
}
