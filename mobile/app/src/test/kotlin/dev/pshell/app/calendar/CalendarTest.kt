package dev.pshell.app.calendar

import java.time.LocalDateTime
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarTest {
	private val berlin = ZoneId.of("Europe/Berlin")
	private val now = LocalDateTime.of(2026, 11, 17, 16, 30)

	private val phone = listOf(
		"BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:DAVx5",
		"BEGIN:VEVENT", "DTSTAMP:20260101T000000Z", "UID:abc-1", "SUMMARY:Sport\\, mit Anna", "DTSTART;TZID=Europe/Berlin:20261118T180000",
		"DTEND;TZID=Europe/Berlin:20261118T193000", "RRULE:FREQ=WEEKLY;BYDAY=WE", "ATTENDEE;CN=Anna:mailto:anna@example.org", "SEQUENCE:2",
		"BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "DESCRIPTION:x", "END:VALARM", "END:VEVENT",
		"BEGIN:VEVENT", "DTSTAMP:20260101T000000Z", "UID:abc-1", "RECURRENCE-ID;TZID=Europe/Berlin:20261125T180000", "SUMMARY:Sport (später)",
		"DTSTART;TZID=Europe/Berlin:20261125T190000", "DTEND;TZID=Europe/Berlin:20261125T203000", "END:VEVENT",
		"END:VCALENDAR", "").joinToString("\r\n")

	@Test fun describesTheSeriesOfThePhone() {
		val (fields, overrides) = Ics.describe(phone, berlin)
		assertEquals("Sport, mit Anna", fields.title)
		assertEquals(LocalDateTime.of(2026, 11, 18, 18, 0), fields.start)
		assertEquals("custom", fields.repeat)
		assertEquals(15, fields.reminder)
		assertEquals(1, overrides)
	}

	@Test fun editKeepsWhatTheEditorDoesNotKnow() {
		val text = Ics.edit(phone, Ics.Fields("Sport", false, LocalDateTime.of(2026, 11, 18, 18, 30), LocalDateTime.of(2026, 11, 18, 20, 0), "Halle; 2", "a\nb", null, null), berlin)
		val lines = Ics.unfold(text)
		assertTrue("ATTENDEE;CN=Anna:mailto:anna@example.org" in lines)
		assertTrue("RRULE:FREQ=WEEKLY;BYDAY=WE" in lines)
		assertTrue("TRIGGER:-PT15M" in lines)
		assertTrue("SEQUENCE:3" in lines)
		assertTrue("LOCATION:Halle\\; 2" in lines)
		assertTrue("DESCRIPTION:a\\nb" in lines)
		assertTrue("DTSTART;TZID=Europe/Berlin:20261118T183000" in lines)
		assertTrue("SUMMARY:Sport (später)" in lines)
		assertEquals(1, lines.count { it == "BEGIN:VTIMEZONE" })
		assertEquals("Halle; 2", Ics.describe(text, berlin).first.location)
	}

	@Test fun buildsNewAndReadsItBack() {
		val (_, text) = Ics.build(Ics.Fields("x".repeat(200), false, LocalDateTime.of(2026, 12, 22, 9, 0), LocalDateTime.of(2026, 12, 22, 10, 0), repeat = "yearly", reminder = 0), berlin)
		assertTrue(text.split("\r\n").all { it.toByteArray().size <= 75 })
		val (fields, _) = Ics.describe(text, berlin)
		assertEquals("x".repeat(200), fields.title)
		assertEquals("yearly", fields.repeat)
		assertEquals(0, fields.reminder)
		val events = Ics.events(text, "/a.ics", "\"e\"", DavCalendar("/c/", "C", "#ff0000"), berlin)
		assertEquals(1, events.size)
		assertEquals(0, events[0].reminder)
		val (_, day) = Ics.build(Ics.Fields("Urlaub", true, LocalDateTime.of(2026, 12, 22, 0, 0), LocalDateTime.of(2026, 12, 22, 0, 0)), berlin)
		assertTrue("DTEND;VALUE=DATE:20261223" in Ics.unfold(day))
	}

	@Test fun parsesLines() {
		fun p(text: String) = When.parse(text, now)
		p("morgen 15 Uhr Zahnarzt @Praxis Dr. Berg").let {
			assertEquals("Zahnarzt", it.title); assertEquals(LocalDateTime.of(2026, 11, 18, 15, 0), it.start); assertEquals("Praxis Dr. Berg", it.location)
		}
		p("Fr 18:30-20 Kino").let { assertEquals(LocalDateTime.of(2026, 11, 20, 18, 30), it.start); assertEquals(LocalDateTime.of(2026, 11, 20, 20, 0), it.end) }
		p("jeden Montag 9 Standup 15min").let { assertEquals("Standup", it.title); assertEquals("weekly", it.repeat); assertEquals(LocalDateTime.of(2026, 11, 23, 9, 15), it.end) }
		p("24.12 Feier").let { assertTrue(it.allDay); assertEquals(LocalDateTime.of(2026, 12, 24, 0, 0), it.start) }
		p("Sa 10.30 Markt").let { assertEquals("Markt", it.title); assertEquals(LocalDateTime.of(2026, 11, 21, 10, 30), it.start) }
		p("tomorrow 3pm-4:30pm dentist").let { assertEquals(LocalDateTime.of(2026, 11, 18, 16, 30), it.end) }
		p("in 2 Stunden Pizza").let { assertEquals(LocalDateTime.of(2026, 11, 17, 18, 30), it.start) }
		p("Zahnarzt").let { assertFalse(it.known); assertTrue(it.allDay) }
		p("am 3.1. um 10 Termin Amt").let { assertEquals("Termin Amt", it.title); assertEquals(LocalDateTime.of(2027, 1, 3, 10, 0), it.start) }
	}
}
