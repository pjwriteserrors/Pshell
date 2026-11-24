package dev.pshell.app.reminders

import java.time.LocalDateTime
import java.time.ZoneId
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemindersTest {
	private val berlin = ZoneId.of("Europe/Berlin")
	private fun at(y: Int, m: Int, d: Int, h: Int, min: Int = 0) = LocalDateTime.of(y, m, d, h, min).atZone(berlin).toEpochSecond()
	private val never: (String, Long) -> Boolean = { _, _ -> false }

	@Test fun readsWhatCoreSends() {
		val data = Json.parseToJsonElement("""{"reminders": [{"id": "rm_abcdefghij", "owner": "lu", "title": "Wäsche", "note": "", "at": 1795000000,
			"all_day": false, "repeat": {"every": "week", "n": 2, "days": [5, 1, 9]}, "level": "important", "escalate_min": 0, "trigger": "time",
			"state": "open", "snoozed_until": null, "next": 1795000000, "pending": [1794000000], "created": 1, "updated": 2},
			{"title": "no id"}], "levels": {"calendar": "quiet"}, "sources": [{"source": "calendar", "key": "k", "title": "Zahnarzt", "at": 1795003600, "level": "normal"}]}""")
		val snapshot = Snapshot.of(data)
		assertEquals(1, snapshot.reminders.size)
		val r = snapshot.reminders[0]
		assertEquals(Repeat("week", 2, listOf(1, 5)), r.repeat)
		assertEquals(0, r.escalateMin)
		assertEquals(listOf(1794000000L), r.pending)
		assertEquals("quiet", snapshot.levels["calendar"])
		assertEquals("Zahnarzt", snapshot.sources[0].title)
		// and back, for the cache
		assertEquals(snapshot, Snapshot.of(Json.parseToJsonElement(snapshot.toJson().toString())))
	}

	@Test fun oneOffOnlyAhead() {
		val r = Reminder("a", "x", at = at(2026, 11, 24, 9))
		assertEquals(listOf(r.at), Schedule.occurrences(r, at(2026, 11, 24, 8), berlin))
		assertTrue(Schedule.occurrences(r, at(2026, 11, 24, 9), berlin).isEmpty())
	}

	@Test fun allDayRingsAtNineLikeCore() {
		val r = Reminder("a", "x", at = at(2026, 12, 24, 0), allDay = true)
		assertEquals(listOf(at(2026, 12, 24, 9)), Schedule.occurrences(r, at(2026, 12, 24, 8), berlin))
		val yearly = r.copy(repeat = Repeat("year"))
		assertEquals(listOf(at(2027, 12, 24, 9)), Schedule.occurrences(yearly, at(2026, 12, 24, 10), berlin))
	}

	@Test fun dailyKeepsTheWallClockOverDst() {
		val r = Reminder("a", "x", at = at(2026, 10, 20, 7, 30), repeat = Repeat("day"))
		val next = Schedule.occurrences(r, at(2026, 10, 24, 12), berlin, 3)
		// 25 October 2026 the clocks go back; 7:30 stays 7:30
		assertEquals(listOf(at(2026, 10, 25, 7, 30), at(2026, 10, 26, 7, 30), at(2026, 10, 27, 7, 30)), next)
		assertEquals(25 * 3600L, next[0] - at(2026, 10, 24, 7, 30))
	}

	@Test fun everyOtherWeekOnDays() {
		// Monday 2 November 2026, 8:00; every 2 weeks on Monday and Friday
		val r = Reminder("a", "x", at = at(2026, 11, 2, 8), repeat = Repeat("week", 2, listOf(1, 5)))
		val next = Schedule.occurrences(r, at(2026, 11, 3, 0), berlin, 4)
		assertEquals(listOf(at(2026, 11, 6, 8), at(2026, 11, 16, 8), at(2026, 11, 20, 8), at(2026, 11, 30, 8)), next)
	}

	@Test fun weekDaysBeforeTheStartDoNotCount() {
		// starts on a Wednesday; Monday of that week is before it
		val r = Reminder("a", "x", at = at(2026, 11, 18, 18), repeat = Repeat("week", 1, listOf(1, 3)))
		assertEquals(listOf(at(2026, 11, 18, 18), at(2026, 11, 23, 18)), Schedule.occurrences(r, at(2026, 11, 1, 0), berlin, 2))
	}

	@Test fun monthlyClampsAndUntilEnds() {
		val r = Reminder("a", "x", at = at(2026, 1, 31, 10), repeat = Repeat("month", 1, until = at(2026, 4, 30, 10)))
		assertEquals(listOf(at(2026, 2, 28, 10), at(2026, 3, 31, 10), at(2026, 4, 30, 10)), Schedule.occurrences(r, at(2026, 2, 1, 0), berlin, 5))
	}

	@Test fun farAheadIsQuick() {
		val r = Reminder("a", "x", at = at(2000, 1, 1, 6), repeat = Repeat("day"))
		assertEquals(listOf(at(2026, 11, 25, 6)), Schedule.occurrences(r, at(2026, 11, 24, 12), berlin))
		val y = Reminder("b", "x", at = at(1990, 12, 24, 18), repeat = Repeat("year"))
		assertEquals(listOf(at(2026, 12, 24, 18)), Schedule.occurrences(y, at(2026, 11, 24, 12), berlin))
	}

	@Test fun nextSkipsWhatWasShownAndPrefersTheSnooze() {
		val now = at(2026, 11, 24, 12)
		val r = Reminder("a", "x", at = at(2026, 11, 20, 13), repeat = Repeat("day"), next = at(2026, 11, 24, 13))
		assertEquals(Schedule.Due("a", at(2026, 11, 24, 13), at(2026, 11, 24, 13)), Schedule.next(r, now, berlin, never))
		val seen: (String, Long) -> Boolean = { _, o -> o == at(2026, 11, 24, 13) }
		assertEquals(at(2026, 11, 25, 13), Schedule.next(r, now, berlin, seen)!!.occurrence)
		val snoozed = r.copy(snoozedUntil = now + 300, pending = listOf(at(2026, 11, 24, 11)))
		assertEquals(Schedule.Due("a", at(2026, 11, 24, 11), now + 300), Schedule.next(snoozed, now, berlin, never))
		assertNull(Schedule.next(r.copy(state = "done"), now, berlin, never))
		assertNull(Schedule.next(r.copy(trigger = "arrive_home", at = null, repeat = null, next = null), now, berlin, never))
	}

	@Test fun missedOnesComeOnceWithinTheWindow() {
		val now = at(2026, 11, 24, 12)
		val planned = listOf(Schedule.Due("a", now - 600, now - 600), Schedule.Due("b", now - 8 * 3600, now - 8 * 3600), Schedule.Due("c", now + 60, now + 60))
		assertEquals(listOf("a"), Schedule.missed(planned, now, 6 * 3600, never).map { it.id })
		assertTrue(Schedule.missed(planned, now, 6 * 3600) { id, _ -> id == "a" }.isEmpty())
	}

	@Test fun dedupe() {
		val now = 1_000_000L
		val shown = Dedupe.Shown("a", 500, "important", false, now - 10)
		assertEquals(Dedupe.Action.Show, Dedupe.decide(null, false, 500, false, now))
		assertEquals(Dedupe.Action.Ignore, Dedupe.decide(null, true, 500, false, now))
		// phone alarm and core event of the same occurrence
		assertEquals(Dedupe.Action.Ignore, Dedupe.decide(shown, false, 500, false, now))
		assertEquals(Dedupe.Action.Escalate, Dedupe.decide(shown, false, 500, true, now))
		assertEquals(Dedupe.Action.Ignore, Dedupe.decide(shown.copy(escalated = true), false, 500, true, now))
		// a trigger the phone saw and core fired a moment later
		assertEquals(Dedupe.Action.Adopt, Dedupe.decide(shown, false, 520, false, now))
		// tomorrow's occurrence while yesterday's still shows
		val old = shown.copy(at = now - 86_400)
		assertEquals(Dedupe.Action.Show, Dedupe.decide(old, false, 86_900, false, now))
		assertEquals(Dedupe.Action.Ignore, Dedupe.decide(old, false, 100, false, now))
	}

	@Test fun escalation() {
		assertEquals("fullscreen", Dedupe.level("important", true))
		assertEquals("normal", Dedupe.level("normal", true))
		assertEquals(1600L, Dedupe.escalateAt("important", 10, 1000, 900))
		assertEquals(2200L, Dedupe.escalateAt("important", 10, 1000, 1600))
		assertNull(Dedupe.escalateAt("important", 0, 1000, 1000))
		assertNull(Dedupe.escalateAt("normal", 10, 1000, 1000))
	}

	@Test fun ackedElsewhere() {
		val now = 10_000L
		val shown = Dedupe.Shown("a", 500, "normal", false, now - 600)
		assertTrue(Dedupe.goneElsewhere(shown, emptySet(), emptySet(), now))
		assertTrue(!Dedupe.goneElsewhere(shown, setOf("a" to 500L), setOf("a"), now))
		assertTrue(!Dedupe.goneElsewhere(shown.copy(at = now - 30), emptySet(), emptySet(), now))
	}
}
