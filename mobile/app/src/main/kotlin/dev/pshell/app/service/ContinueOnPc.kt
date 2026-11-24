package dev.pshell.app.service

import dev.pshell.app.App
import dev.pshell.app.link.json

/**
 * "Share → Continue on PC": the page does not open on the PC, it waits
 * there – on the browser's new tab page and first in the launcher's >tab –
 * as the page last open on the phone (topic phone.handoff, { page: { url,
 * title, at } }; docs/mobile.md). Kept while the app runs and sent to every
 * PC it connects to.
 */
object ContinueOnPc {
	data class Page(val url: String, val title: String)

	private val link = Regex("""https?://[^\s<>"]+""")
	private val edges = Regex("""^[\s\-–—:|.,]+|[\s\-–—:|.,]+$""")

	/** The link of a share and its title: the subject, else the text around the link. */
	fun page(text: String, subject: String?): Page? {
		val url = link.find(text)?.value?.trimEnd('.', ',', ';', '!', '?') ?: return null
		val rest = text.replace(url, " ").lineSequence().map { it.replace(edges, "") }.firstOrNull { it.isNotEmpty() }.orEmpty()
		val title = subject?.trim()?.takeIf { it.isNotEmpty() } ?: rest
		return Page(url, title.take(200))
	}

	fun park(app: App, page: Page, now: Long = System.currentTimeMillis()) {
		app.link.publish("phone.handoff", json("page" to json("url" to page.url, "title" to page.title, "at" to now)))
	}
}
