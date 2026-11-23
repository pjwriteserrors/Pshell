package dev.pshell.app.calendar

import android.content.Context
import android.content.SharedPreferences
import androidx.glance.appwidget.updateAll
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import dev.pshell.app.App
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.widget.CalendarWidget
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The Baikal calendar on the phone (docs/mobile.md "Calendar"): the account
 * from pshell-core, the member's calendars, the events of the month looked at,
 * and the next two weeks kept for the widget and for when the server is not
 * reachable. Every change goes straight to Baikal; DAVx5 brings it to the
 * phone's own calendar app as before.
 */
object Calendars {
	val zone: ZoneId get() = ZoneId.systemDefault()

	private lateinit var app: App
	private lateinit var store: SharedPreferences
	val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
	private val lock = Mutex()

	val account = MutableStateFlow<Account?>(null)
	/** core has an account for the member it has no password for: the user's name, asked for once */
	val needPassword = MutableStateFlow("")
	val problem = MutableStateFlow("")
	val loading = MutableStateFlow(false)
	val calendars = MutableStateFlow<List<DavCalendar>>(emptyList())
	/** the events by day of the months loaded */
	val byDay = MutableStateFlow<Map<LocalDate, List<Event>>>(emptyMap())
	/** the next 14 days, also from the cache: for the widget */
	val upcoming = MutableStateFlow<List<Upcoming>>(emptyList())
	val members = MutableStateFlow<List<Dav.Member>>(emptyList())
	val sharees = MutableStateFlow<Map<String, List<Dav.Sharee>>>(emptyMap())
	private val loaded = HashSet<LocalDate>()

	/** an event as the widget keeps it */
	data class Upcoming(val title: String, val start: LocalDateTime, val end: LocalDateTime, val allDay: Boolean, val color: String, val location: String)

	fun install(app: App) {
		this.app = app
		store = app.getSharedPreferences("calendar", Context.MODE_PRIVATE)
		account.value = store.getString("account", null)?.let { text ->
			runCatching { Json.parseToJsonElement(text) }.getOrNull()?.let { Account(it["url"].string, it["user"].string, it["password"].string) }
		}
		upcoming.value = readUpcoming()
		val work = PeriodicWorkRequestBuilder<Refresh>(30, TimeUnit.MINUTES)
			.setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build()
		WorkManager.getInstance(app).enqueueUniquePeriodicWork("calendar", ExistingPeriodicWorkPolicy.KEEP, work)
	}

	class Refresh(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
		override suspend fun doWork(): Result {
			runCatching { refreshUpcoming() }
			return Result.success()
		}
	}

	// ── the account ────────────────────────────────────────────────────────
	private suspend fun ensureAccount(fresh: Boolean = false): Account? {
		if (!fresh) account.value?.let { return it }
		val (found, user) = Dav.accountFromCore()
		if (found == null) {
			needPassword.value = user.ifEmpty { "?" }
			return null
		}
		needPassword.value = ""
		account.value = found
		store.edit().putString("account", JsonObject(mapOf("url" to JsonPrimitive(found.url), "user" to JsonPrimitive(found.user), "password" to JsonPrimitive(found.password))).toString()).apply()
		return found
	}

	/** with the account; once more with a fresh one from core when Baikal refuses the kept one */
	private suspend fun <T> withAccount(block: suspend (Account) -> T): T? {
		val first = ensureAccount() ?: return null
		return try {
			block(first)
		} catch (error: DavError) {
			if (error.status != 401) throw error
			val again = ensureAccount(fresh = true) ?: return null
			block(again)
		}
	}

	suspend fun givePassword(password: String) {
		Dav.givePassword(password)
		ensureAccount(fresh = true)
		refresh()
	}

	/** runs [block], what goes wrong as [problem] */
	private suspend fun guarded(block: suspend () -> Unit): Boolean = try {
		block()
		problem.value = ""
		true
	} catch (error: Exception) {
		problem.value = error.message ?: error.javaClass.simpleName
		false
	}

	// ── reading ────────────────────────────────────────────────────────────
	fun gridStart(month: LocalDate): LocalDate {
		val first = month.withDayOfMonth(1)
		return first.minusDays((first.dayOfWeek.value - 1).toLong())
	}

	suspend fun ensure(month: LocalDate) {
		val start = gridStart(month)
		if (start in loaded) return
		load(start)
	}

	private suspend fun load(start: LocalDate) = lock.withLock {
		loading.value = true
		guarded {
			withAccount { account ->
				val list = Dav.calendars(account)
				calendars.value = list
				val found = list.flatMap { Dav.events(account, it, start, 42, zone) }
				val days = byDay.value.toMutableMap()
				for (i in 0 until 42) days.remove(start.plusDays(i.toLong()))
				for (event in found) for (day in event.days()) if (!day.isBefore(start) && day.isBefore(start.plusDays(42))) days[day] = (days[day].orEmpty().filter { it.id != event.id } + event)
				byDay.value = days.mapValues { (_, list) -> list.sortedWith(compareByDescending<Event> { it.allDay }.thenBy { it.start }) }
				loaded += start
			}
		}
		loading.value = false
	}

	/** everything shown again, and the widget's two weeks */
	suspend fun refresh() {
		val months = loaded.toList()
		loaded.clear()
		for (start in months.ifEmpty { listOf(gridStart(LocalDate.now())) }) load(start)
		refreshUpcoming()
	}

	suspend fun refreshUpcoming() {
		guarded {
			withAccount { account ->
				val today = LocalDate.now()
				val list = Dav.calendars(account)
				calendars.value = list
				val now = LocalDateTime.now()
				val found = list.flatMap { Dav.events(account, it, today, 14, zone) }
					.filter { !it.cancelled && it.end.isAfter(now) }
					.distinctBy { it.id }
					.sortedWith(compareBy<Event> { it.start.toLocalDate() }.thenByDescending { it.allDay }.thenBy { it.start })
					.map { Upcoming(it.title, it.start, it.end, it.allDay, it.calendar.color, it.location) }
				upcoming.value = found
				writeUpcoming(found)
			}
		}
		runCatching { CalendarWidget().updateAll(app) }
	}

	private fun writeUpcoming(list: List<Upcoming>) {
		val array = JsonArray(list.map {
			JsonObject(mapOf("t" to JsonPrimitive(it.title), "s" to JsonPrimitive(it.start.toString()), "e" to JsonPrimitive(it.end.toString()),
				"a" to JsonPrimitive(it.allDay), "c" to JsonPrimitive(it.color), "l" to JsonPrimitive(it.location)))
		})
		store.edit().putString("upcoming", array.toString()).putLong("upcomingAt", System.currentTimeMillis()).apply()
	}

	private fun readUpcoming(): List<Upcoming> = runCatching {
		Json.parseToJsonElement(store.getString("upcoming", "[]") ?: "[]").list.map {
			Upcoming(it["t"].string, LocalDateTime.parse(it["s"].string), LocalDateTime.parse(it["e"].string), it["a"].bool, it["c"].string, it["l"].string)
		}
	}.getOrDefault(emptyList())

	fun eventsOn(day: LocalDate) = byDay.value[day].orEmpty()

	val writable get() = calendars.value.filter { !it.readOnly }

	fun defaultCalendar(): String {
		val last = store.getString("last", "")
		return (writable.firstOrNull { it.href == last } ?: writable.firstOrNull())?.href.orEmpty()
	}

	// ── writing ────────────────────────────────────────────────────────────
	/** the series of an event for the editor */
	suspend fun series(event: Event): Pair<Ics.Fields, Int>? {
		var out: Pair<Ics.Fields, Int>? = null
		guarded { withAccount { account -> out = Ics.describe(Dav.get(account, event.href).text, zone) } }
		return out
	}

	suspend fun save(calendar: String, href: String?, fields: Ics.Fields): Boolean {
		val ok = guarded {
			withAccount { account ->
				if (href == null) Dav.create(account, calendar, fields, zone) else Dav.update(account, href, fields, zone)
			}
		}
		if (ok && href == null) store.edit().putString("last", calendar).apply()
		if (ok) refresh()
		return ok
	}

	suspend fun delete(event: Event): Boolean {
		val ok = guarded { withAccount { Dav.delete(it, event.href, event.etag) } }
		if (ok) refresh()
		return ok
	}

	suspend fun makeCalendar(name: String, color: String) = guarded { withAccount { Dav.makeCalendar(it, name, color) } }.also { if (it) refresh() }

	suspend fun changeCalendar(href: String, name: String? = null, color: String? = null) = guarded { withAccount { Dav.changeCalendar(it, href, name, color) } }.also { if (it) refresh() }

	suspend fun deleteCalendar(href: String) = guarded { withAccount { Dav.deleteCalendar(it, href) } }.also { if (it) refresh() }

	suspend fun loadSharing(href: String) {
		guarded {
			members.value = Dav.members().filter { it.name != account.value?.user }
			withAccount { account -> sharees.value = sharees.value + (href to Dav.sharees(account, href)) }
		}
	}

	suspend fun share(href: String, member: Dav.Member, mode: String) {
		if (guarded { withAccount { Dav.share(it, href, member.email, member.display.ifEmpty { member.name }, mode) } }) loadSharing(href)
	}

	fun launch(block: suspend () -> Unit) = scope.launch { block() }
}
