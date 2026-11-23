package dev.pshell.app.calendar

import dev.pshell.app.nas.Nas
import java.io.IOException
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.Authenticator
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.Route
import dev.pshell.app.link.get
import dev.pshell.app.link.list
import dev.pshell.app.link.string

class DavError(val status: Int, message: String) : IOException(message)

/** The Baikal account of this phone's member: from pshell-core, with the NAS token. */
data class Account(val url: String, val user: String, val password: String)

/**
 * pshell-core (docs/core.md "Calendar") and Baikal's CalDAV for the phone. Core
 * is on the NAS's host, port 8097, and knows this phone by its NAS token; it
 * hands out the member's Baikal account. Baikal wants Digest.
 */
object Dav {
	private val random = SecureRandom()

	private fun md5(text: String): String = MessageDigest.getInstance("MD5").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

	/** Digest (RFC 7616, MD5, qop=auth) on the 401 */
	private class Digest(private val user: String, private val password: String) : Authenticator {
		private val count = AtomicInteger(0)
		override fun authenticate(route: Route?, response: Response): Request? {
			if (response.request.header("Authorization") != null) return null
			val challenge = response.headers("WWW-Authenticate").firstOrNull { it.startsWith("Digest", ignoreCase = true) } ?: return null
			val parts = Regex("""(\w+)=(?:"([^"]*)"|([^,\s]*))""").findAll(challenge).associate { it.groupValues[1].lowercase() to it.groupValues[2].ifEmpty { it.groupValues[3] } }
			val realm = parts["realm"].orEmpty()
			val nonce = parts["nonce"].orEmpty()
			val url = response.request.url
			val uri = url.encodedPath + (url.encodedQuery?.let { "?$it" } ?: "")
			val nc = "%08x".format(count.incrementAndGet())
			val cnonce = ByteArray(8).also(random::nextBytes).joinToString("") { "%02x".format(it) }
			val ha1 = md5("$user:$realm:$password")
			val ha2 = md5("${response.request.method}:$uri")
			val qop = parts["qop"]
			val answer = if (qop != null) md5("$ha1:$nonce:$nc:$cnonce:auth:$ha2") else md5("$ha1:$nonce:$ha2")
			val header = buildString {
				append("Digest username=\"$user\", realm=\"$realm\", nonce=\"$nonce\", uri=\"$uri\", response=\"$answer\"")
				if (qop != null) append(", qop=auth, nc=$nc, cnonce=\"$cnonce\"")
				parts["opaque"]?.let { append(", opaque=\"$it\"") }
				append(", algorithm=MD5")
			}
			return response.request.newBuilder().header("Authorization", header).build()
		}
	}

	private val plain = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(25, TimeUnit.SECONDS).build()
	private var client: OkHttpClient? = null
	private var clientFor: Account? = null

	private fun clientOf(account: Account): OkHttpClient {
		if (clientFor != account) {
			client = plain.newBuilder().authenticator(Digest(account.user, account.password)).build()
			clientFor = account
		}
		return client!!
	}

	// ── core ───────────────────────────────────────────────────────────────
	private suspend fun coreBase(): String {
		val nas = Nas.resolve() ?: throw IOException(Nas.problem.value.ifEmpty { "The server is not reachable" })
		val url = nas.toHttpUrl()
		return "${url.scheme}://${url.host}:8097"
	}

	suspend fun core(method: String, path: String, body: JsonObject? = null): JsonElement? {
		val token = Nas.account.value?.token ?: throw IOException("No token yet: it comes from the PC")
		val base = coreBase()
		return runInterruptible(Dispatchers.IO) {
			val request = Request.Builder().url(base + path).header("Authorization", "Bearer $token").header("X-Pshell", "1")
				.method(method, body?.toString()?.toRequestBody("application/json".toMediaType())).build()
			plain.newCall(request).execute().use { response ->
				val text = response.body.string()
				val parsed = runCatching { if (text.isBlank()) null else Json.parseToJsonElement(text) }.getOrNull()
				if (!response.isSuccessful) throw DavError(response.code, parsed["error"].string.ifEmpty { "Core: HTTP ${response.code}" })
				parsed
			}
		}
	}

	// ── CalDAV ─────────────────────────────────────────────────────────────
	fun absolute(account: Account, href: String): String {
		if (href.startsWith("http")) return href
		val url = account.url.toHttpUrl()
		return "${url.scheme}://${url.host}:${url.port}$href"
	}

	fun home(account: Account) = "${account.url.trimEnd('/')}/calendars/${URLEncoder.encode(account.user, "UTF-8")}/"

	data class Reply(val status: Int, val text: String, val etag: String)

	suspend fun call(account: Account, method: String, url: String, body: String? = null, headers: Map<String, String> = emptyMap()): Reply =
		runInterruptible(Dispatchers.IO) {
			val type = headers["Content-Type"] ?: "application/xml; charset=utf-8"
			val builder = Request.Builder().url(url).method(method, body?.toRequestBody(type.toMediaType()))
			for ((key, value) in headers) if (key != "Content-Type") builder.header(key, value)
			clientOf(account).newCall(builder.build()).execute().use { response ->
				val text = response.body.string()
				if (!response.isSuccessful) {
					val message = Regex("<s:message>(.*?)</s:message>", RegexOption.DOT_MATCHES_ALL).find(text)?.groupValues?.get(1)?.trim()
					throw DavError(response.code, when (response.code) {
						401 -> "Baikal did not take the user or password"
						412 -> "Changed elsewhere in the meantime, load again"
						else -> "Baikal: ${response.code} ${message ?: response.message}"
					})
				}
				Reply(response.code, text, response.header("ETag").orEmpty())
			}
		}

	private val XML = Regex("&(lt|gt|quot|apos|amp|#13|#x[0-9a-fA-F]+|#\\d+);")

	fun decode(text: String): String = XML.replace(text) {
		when (val e = it.groupValues[1]) {
			"lt" -> "<"; "gt" -> ">"; "quot" -> "\""; "apos" -> "'"; "amp" -> "&"; "#13" -> "\r"
			else -> if (e.startsWith("#x")) e.drop(2).toInt(16).toChar().toString() else e.drop(1).toInt().toChar().toString()
		}
	}

	fun xml(text: String) = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

	fun elements(text: String, name: String): List<String> =
		Regex("<((?:[\\w-]+:)?$name)\\b[^>]*>(.*?)</\\1>", RegexOption.DOT_MATCHES_ALL).findAll(text).map { it.groupValues[2] }.toList()

	fun first(text: String, name: String) = elements(text, name).firstOrNull()?.trim().orEmpty()

	suspend fun calendars(account: Account): List<DavCalendar> {
		val body = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:a="http://apple.com/ns/ical/"><d:prop><d:resourcetype/><d:displayname/><a:calendar-color/><d:share-access/></d:prop></d:propfind>"""
		val text = call(account, "PROPFIND", home(account), body, mapOf("Depth" to "1")).text
		return elements(text, "response").filter { Regex("<(?:[\\w-]+:)?calendar\\s*/>").containsMatchIn(it) }.mapNotNull { response ->
			val href = first(response, "href").ifEmpty { return@mapNotNull null }
			val access = first(response, "share-access")
			DavCalendar(
				href = href,
				name = decode(first(response, "displayname")).ifEmpty { java.net.URLDecoder.decode(href.trimEnd('/').substringAfterLast('/'), "UTF-8") },
				color = first(response, "calendar-color").take(7),
				access = when {
					"read-write" in access -> "write"
					Regex("<(?:[\\w-]+:)?read\\s*/>").containsMatchIn(access) -> "read"
					"shared-owner" in access -> "owner"
					else -> ""
				},
			)
		}.sortedBy { it.name.lowercase() }
	}

	private val UTC = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC)

	/** the events from [from] for [days] days, repeating ones unrolled by the server */
	suspend fun events(account: Account, calendar: DavCalendar, from: LocalDate, days: Long, zone: ZoneId): List<Event> {
		val start = UTC.format(from.atStartOfDay(zone).toInstant())
		val end = UTC.format(from.plusDays(days).atStartOfDay(zone).toInstant())
		val range = """start="$start" end="$end""""
		val body = """<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data><c:expand $range/></c:calendar-data></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:time-range $range/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"""
		val text = call(account, "REPORT", absolute(account, calendar.href), body, mapOf("Depth" to "1")).text
		return elements(text, "response").flatMap { response ->
			val data = first(response, "calendar-data")
			if (data.isEmpty()) emptyList() else Ics.events(decode(data), first(response, "href"), decode(first(response, "getetag")), calendar, zone)
		}
	}

	suspend fun get(account: Account, href: String): Reply = call(account, "GET", absolute(account, href))

	suspend fun create(account: Account, calendar: String, fields: Ics.Fields, zone: ZoneId): String {
		val (uid, text) = Ics.build(fields, zone)
		val href = calendar.trimEnd('/') + "/" + uid.substringBefore("@") + ".ics"
		call(account, "PUT", absolute(account, href), text, mapOf("Content-Type" to "text/calendar; charset=utf-8", "If-None-Match" to "*"))
		return href
	}

	suspend fun update(account: Account, href: String, fields: Ics.Fields, zone: ZoneId) {
		val current = get(account, href)
		val text = Ics.edit(current.text, fields, zone)
		call(account, "PUT", absolute(account, href), text, buildMap {
			put("Content-Type", "text/calendar; charset=utf-8")
			if (current.etag.isNotEmpty()) put("If-Match", current.etag)
		})
	}

	suspend fun delete(account: Account, href: String, etag: String = "") {
		call(account, "DELETE", absolute(account, href), headers = if (etag.isNotEmpty()) mapOf("If-Match" to etag) else emptyMap())
	}

	suspend fun makeCalendar(account: Account, name: String, color: String): String {
		val href = home(account) + java.util.UUID.randomUUID() + "/"
		val body = """<?xml version="1.0" encoding="utf-8"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop><d:displayname>${xml(name)}</d:displayname>""" +
			(if (color.isNotEmpty()) "<a:calendar-color>${xml(color)}</a:calendar-color>" else "") +
			"""<c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/></c:supported-calendar-component-set></d:prop></d:set></c:mkcalendar>"""
		call(account, "MKCALENDAR", href, body)
		return href.toHttpUrl().encodedPath
	}

	suspend fun changeCalendar(account: Account, href: String, name: String? = null, color: String? = null) {
		val props = (name?.let { "<d:displayname>${xml(it)}</d:displayname>" } ?: "") + (color?.let { "<a:calendar-color>${xml(it)}</a:calendar-color>" } ?: "")
		call(account, "PROPPATCH", absolute(account, href), """<?xml version="1.0" encoding="utf-8"?><d:propertyupdate xmlns:d="DAV:" xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop>$props</d:prop></d:set></d:propertyupdate>""")
	}

	suspend fun deleteCalendar(account: Account, href: String) {
		require(href.trimEnd('/') != home(account).toHttpUrl().encodedPath.trimEnd('/')) { "Not a calendar" }
		call(account, "DELETE", absolute(account, href))
	}

	data class Sharee(val email: String, val write: Boolean)

	suspend fun sharees(account: Account, href: String): List<Sharee> {
		val body = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:prop><cs:invite/></d:prop></d:propfind>"""
		val text = call(account, "PROPFIND", absolute(account, href), body, mapOf("Depth" to "0")).text
		return elements(text, "user").mapNotNull { user ->
			val target = first(user, "href")
			if (!target.lowercase().startsWith("mailto:")) null else Sharee(target.drop(7), Regex("<(?:\\w+:)?read-write\\s*/>").containsMatchIn(user))
		}
	}

	/** mode "" (not shared), read or write */
	suspend fun share(account: Account, href: String, email: String, name: String, mode: String) {
		val part = if (mode.isEmpty()) "<cs:remove><d:href>mailto:${xml(email)}</d:href></cs:remove>"
		else "<cs:set><d:href>mailto:${xml(email)}</d:href><cs:common-name>${xml(name)}</cs:common-name>${if (mode == "write") "<cs:read-write/>" else "<cs:read/>"}</cs:set>"
		call(account, "POST", absolute(account, href), """<?xml version="1.0" encoding="utf-8"?><cs:share xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">$part</cs:share>""")
	}

	// ── what core says ─────────────────────────────────────────────────────
	/** the account, or null with core's reason when it wants the Baikal password once */
	suspend fun accountFromCore(): Pair<Account?, String> {
		val data = core("GET", "/api/calendar/account")
		if (data["need"].string == "password") return null to data["user"].string
		return Account(data["url"].string, data["user"].string, data["password"].string) to ""
	}

	suspend fun givePassword(password: String) {
		core("POST", "/api/calendar/account", JsonObject(mapOf("password" to JsonPrimitive(password))))
	}

	data class Member(val name: String, val email: String, val display: String)

	suspend fun members(): List<Member> = core("GET", "/api/calendar/members")["members"].list.map { Member(it["name"].string, it["email"].string, it["display"].string) }
}
