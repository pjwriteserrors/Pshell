package dev.pshell.app.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ContinueOnPcTest {
	@Test fun takesTheSubjectAsTitle() {
		val page = ContinueOnPc.page("https://example.org/a?b=1", "Example page")
		assertEquals(ContinueOnPc.Page("https://example.org/a?b=1", "Example page"), page)
	}

	@Test fun takesTheTextAroundTheLinkWithoutASubject() {
		val page = ContinueOnPc.page("Kino heute – https://kino.example/film/42.", null)
		assertEquals("https://kino.example/film/42", page?.url)
		assertEquals("Kino heute", page?.title)
	}

	@Test fun aTextWithoutALinkIsNoPage() {
		assertNull(ContinueOnPc.page("nothing to open here", "Subject"))
	}

	@Test fun anEmptySubjectFallsBackToNothing() {
		assertEquals("", ContinueOnPc.page("https://example.org", "  ")?.title)
	}
}
