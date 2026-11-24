package dev.pshell.app.reminders

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import dev.pshell.app.App
import dev.pshell.app.calendar.Dav
import dev.pshell.app.calendar.DavError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.present
import dev.pshell.app.link.string
import dev.pshell.app.nas.Nas
import java.io.IOException
import java.time.ZoneId
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/**
 * Reminders of pshell-core on the phone (docs/mobile.md "Reminders"): the
 * list, kept for offline; local exact alarms for what comes next; one
 * notification per reminder at its level; Done and Snooze go to core, queued
 * while it cannot be reached; core's events (`/api/events`) while the link
 * service runs, `/active` otherwise, take away what was acknowledged elsewhere.
 */
object Reminders {
	val zone: ZoneId get() = ZoneId.systemDefault()

	private lateinit var app: App
	private lateinit var store: SharedPreferences
	val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
	private val lock = Any()
	private val syncing = Mutex()
	private val flushing = Mutex()

	val snapshot = MutableStateFlow(Snapshot())
	/** what the phone shows now, by reminder id */
	val showing = MutableStateFlow<Map<String, Dedupe.Shown>>(emptyMap())
	val problem = MutableStateFlow("")
	val loading = MutableStateFlow(false)
	/** Done, Snooze, triggers that wait for core */
	val queued = MutableStateFlow(0)
	/** core's events are coming in */
	val live = MutableStateFlow(false)

	/** "id:occurrence" → when it was acknowledged here (ms), so a stale list does not bring it back */
	private val acked = HashMap<String, Long>()
	/** id → until (epoch s): snoozed here, not shown again before */
	private val snoozes = HashMap<String, Long>()
	/** the alarms set, by id */
	private val planned = HashMap<String, Schedule.Due>()

	fun now() = System.currentTimeMillis() / 1000
	private fun key(id: String, occurrence: Long) = "$id:$occurrence"

	fun install(app: App) {
		this.app = app
		store = app.getSharedPreferences("reminders", Context.MODE_PRIVATE)
		load()
		Alerts.channels(app)
		val work = PeriodicWorkRequestBuilder<SyncWork>(15, TimeUnit.MINUTES)
			.setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build()
		WorkManager.getInstance(app).enqueueUniquePeriodicWork("reminders", ExistingPeriodicWorkPolicy.KEEP, work)
		reschedule()
		watchHome()
		scope.launch {
			// the token may come only now from the PC
			Nas.account.collect { if (it != null) sync() }
		}
	}

	// ── what is kept ───────────────────────────────────────────────────────
	private fun load() = synchronized(lock) {
		snapshot.value = runCatching { Snapshot.of(Json.parseToJsonElement(store.getString("snapshot", "{}") ?: "{}")) }.getOrDefault(Snapshot())
		showing.value = runCatching {
			Json.parseToJsonElement(store.getString("shown", "[]") ?: "[]").list.associate {
				it["id"].string to Dedupe.Shown(it["id"].string, it["o"].long, it["l"].string, it["e"].bool, it["a"].long)
			}
		}.getOrDefault(emptyMap())
		runCatching { Json.parseToJsonElement(store.getString("acked", "{}") ?: "{}") }.getOrNull()?.let { data ->
			(data as? JsonObject)?.forEach { (k, v) -> acked[k] = v.long }
		}
		runCatching { Json.parseToJsonElement(store.getString("snoozes", "{}") ?: "{}") }.getOrNull()?.let { data ->
			(data as? JsonObject)?.forEach { (k, v) -> snoozes[k] = v.long }
		}
		runCatching { Json.parseToJsonElement(store.getString("planned", "[]") ?: "[]").list }.getOrDefault(emptyList()).forEach {
			planned[it["id"].string] = Schedule.Due(it["id"].string, it["o"].long, it["a"].long)
		}
		queued.value = outbox().size
	}

	private fun save() = synchronized(lock) {
		val cutoff = System.currentTimeMillis() - 3 * 86_400_000L
		acked.entries.removeAll { it.value < cutoff }
		snoozes.entries.removeAll { it.value < now() - 86_400 }
		store.edit()
			.putString("snapshot", snapshot.value.toJson().toString())
			.putString("shown", JsonArray(showing.value.values.map {
				JsonObject(mapOf("id" to JsonPrimitive(it.id), "o" to JsonPrimitive(it.occurrence), "l" to JsonPrimitive(it.level), "e" to JsonPrimitive(it.escalated), "a" to JsonPrimitive(it.at)))
			}).toString())
			.putString("acked", JsonObject(acked.mapValues { JsonPrimitive(it.value) }).toString())
			.putString("snoozes", JsonObject(snoozes.mapValues { JsonPrimitive(it.value) }).toString())
			.putString("planned", JsonArray(planned.values.map {
				JsonObject(mapOf("id" to JsonPrimitive(it.id), "o" to JsonPrimitive(it.occurrence), "a" to JsonPrimitive(it.at)))
			}).toString())
			.apply()
	}

	fun reminder(id: String) = snapshot.value.reminders.firstOrNull { it.id == id }

	private fun upsert(reminder: Reminder) = synchronized(lock) {
		val list = snapshot.value.reminders
		snapshot.value = snapshot.value.copy(reminders = if (list.any { it.id == reminder.id }) list.map { if (it.id == reminder.id) reminder else it } else list + reminder)
	}

	private fun seen(id: String, occurrence: Long) = key(id, occurrence) in acked || showing.value[id]?.occurrence == occurrence

	// ── alarms ─────────────────────────────────────────────────────────────
	/** Sets the alarms for what comes next, shows what was missed. After every change, on boot, on a new time zone. */
	fun reschedule() {
		val now = now()
		val missed = synchronized(lock) { Schedule.missed(planned.values.toList(), now, 6 * 3600, ::seen) }
		for (due in missed) reminder(due.id)?.let { if (it.open) present(it, due.occurrence, escalated = false, fromServer = false) }
		synchronized(lock) {
			val plan = Schedule.plan(snapshot.value.reminders.filter { it.level != "quiet" }, now, zone, ::seen)
			val ids = plan.map { it.id }.toSet()
			for (gone in planned.keys - ids) Alerts.unsetAlarm(app, gone)
			planned.clear()
			for (due in plan) {
				planned[due.id] = due
				Alerts.setAlarm(app, due, reminder(due.id)?.level ?: "normal")
			}
		}
		save()
	}

	/** The phone's own alarm went off. */
	fun alarm(id: String, occurrence: Long) {
		val reminder = reminder(id)
		synchronized(lock) { planned.remove(id) }
		if (reminder != null && reminder.open && (reminder.snoozedUntil ?: 0) <= now() + 5) present(reminder, occurrence, escalated = false, fromServer = false)
		reschedule()
		scope.launch { sync() }
	}

	/** The phone's escalation of an important one went off. */
	fun escalate(id: String, occurrence: Long) {
		val shown = showing.value[id] ?: return
		if (shown.occurrence != occurrence || shown.escalated) return
		reminder(id)?.let { present(it, occurrence, escalated = true, fromServer = false) }
	}

	// ── showing ────────────────────────────────────────────────────────────
	/** A fire of [reminder] (the phone's alarm, a core event, `/active`): shown once per occurrence, at its level. */
	fun present(reminder: Reminder, occurrence: Long, escalated: Boolean, fromServer: Boolean) {
		val now = now()
		val shownNow: Dedupe.Shown
		val alert: Boolean
		synchronized(lock) {
			snoozes[reminder.id]?.let { until -> if (now < until - 5) return else snoozes.remove(reminder.id) }
			val current = showing.value[reminder.id]
			val wasAcked = key(reminder.id, occurrence) in acked
			when (Dedupe.decide(current, wasAcked, occurrence, escalated, now)) {
				Dedupe.Action.Ignore -> {
					// acknowledged here before core had fired it: once more, now that it has
					if (wasAcked && fromServer) reack(reminder.id, occurrence)
					return
				}
				Dedupe.Action.Adopt -> {
					// the same fire seen twice: core's occurrence is the one to acknowledge
					if (!fromServer || current!!.occurrence == occurrence) return
					shownNow = current.copy(occurrence = occurrence)
					alert = false
				}
				Dedupe.Action.Escalate -> {
					shownNow = Dedupe.Shown(reminder.id, occurrence, "fullscreen", true, current?.at ?: now)
					alert = true
				}
				Dedupe.Action.Show -> {
					shownNow = Dedupe.Shown(reminder.id, occurrence, Dedupe.level(reminder.level, escalated), escalated, now)
					alert = true
				}
			}
			showing.value = showing.value + (reminder.id to shownNow)
		}
		Alerts.show(app, reminder, shownNow, alert)
		if (alert && !shownNow.escalated) Dedupe.escalateAt(reminder.level, reminder.escalateMin, occurrence, now)?.let { Alerts.setEscalation(app, reminder.id, occurrence, it) }
		save()
		poll()
	}

	private fun reack(id: String, occurrence: Long) {
		val path = "/api/reminders/$id/ack"
		val waiting = synchronized(lock) { outbox().any { it["p"].string == path && it["b"]["occurrence"].long == occurrence } }
		if (!waiting) scope.launch { queue("POST", path, JsonObject(mapOf("occurrence" to JsonPrimitive(occurrence)))) }
	}

	private fun hide(id: String) {
		synchronized(lock) { showing.value = showing.value - id }
		Alerts.cancel(app, id)
		Alerts.unsetEscalation(app, id)
	}

	/** Another one that wants the whole screen, after one was closed there. */
	fun nextFullscreen(): Dedupe.Shown? = showing.value.values.filter { it.level == "fullscreen" }.minByOrNull { it.at }

	// ── Done, Snooze ───────────────────────────────────────────────────────
	fun ack(id: String, occurrence: Long?) {
		val shown = showing.value[id]
		val occ = occurrence ?: shown?.occurrence
		val reminder = reminder(id)
		synchronized(lock) {
			if (occ != null) acked[key(id, occ)] = System.currentTimeMillis()
			else reminder?.pending?.forEach { acked[key(id, it)] = System.currentTimeMillis() }
		}
		hide(id)
		if (reminder != null) {
			val left = if (occ == null) emptyList() else reminder.pending - occ
			val oneOff = reminder.repeat == null && reminder.trigger == "time"
			upsert(reminder.copy(pending = left, snoozedUntil = null, state = if (oneOff && left.isEmpty()) "done" else reminder.state))
		}
		// an occurrence core does not know (a trigger the phone saw while offline) acknowledges all that is pending
		val known = occ != null && (reminder == null || reminder.trigger == "time" || occ in reminder.pending)
		queue("POST", "/api/reminders/$id/ack", if (known) JsonObject(mapOf("occurrence" to JsonPrimitive(occ))) else JsonObject(emptyMap()))
		reschedule()
	}

	enum class Snooze(val label: String) { Minutes5("5 min"), Hour("1 h"), Tomorrow("Tomorrow"), Pc("At PC") }

	/** Tomorrow at the same time of day. */
	fun until(snooze: Snooze, now: Long = now()): Long? = when (snooze) {
		Snooze.Minutes5 -> now + 300
		Snooze.Hour -> now + 3600
		Snooze.Tomorrow -> java.time.Instant.ofEpochSecond(now).atZone(zone).plusDays(1).toEpochSecond()
		Snooze.Pc -> null
	}

	fun snooze(id: String, snooze: Snooze) {
		val until = until(snooze)
		synchronized(lock) { snoozes[id] = until ?: (now() + 120) }
		hide(id)
		reminder(id)?.let { upsert(if (until != null) it.copy(snoozedUntil = until) else it.copy(snoozedUntil = null, trigger = "unlock")) }
		queue("POST", "/api/reminders/$id/snooze", if (until != null) JsonObject(mapOf("until" to JsonPrimitive(until))) else JsonObject(mapOf("pc" to JsonPrimitive(true))))
		reschedule()
	}

	// ── what waits for core ────────────────────────────────────────────────
	private fun outbox(): List<JsonElement> = runCatching { Json.parseToJsonElement(store.getString("outbox", "[]") ?: "[]").list }.getOrDefault(emptyList())

	private fun queue(method: String, path: String, body: JsonObject) {
		synchronized(lock) {
			val list = outbox() + JsonObject(mapOf("m" to JsonPrimitive(method), "p" to JsonPrimitive(path), "b" to body))
			store.edit().putString("outbox", JsonArray(list).toString()).apply()
			queued.value = list.size
		}
		scope.launch { flush() }
	}

	/** Sends what waits, in order; stops at the first that cannot get through and lets WorkManager try again. */
	suspend fun flush(): Boolean = flushing.withLock {
		while (true) {
			val first = synchronized(lock) { outbox().firstOrNull() } ?: break
			val drop = try {
				Dav.core(first["m"].string, first["p"].string, first["b"] as? JsonObject)
				true
			} catch (error: DavError) {
				// refused for good (gone, invalid) or worth another try
				error.status in 400..499 && error.status !in listOf(401, 408, 429)
			} catch (error: Exception) {
				false
			}
			if (!drop) {
				retryLater()
				return@withLock false
			}
			synchronized(lock) {
				val rest = outbox().drop(1)
				store.edit().putString("outbox", JsonArray(rest).toString()).apply()
				queued.value = rest.size
			}
		}
		true
	}

	private fun retryLater() {
		val work = OneTimeWorkRequestBuilder<FlushWork>()
			.setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
			.setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
		WorkManager.getInstance(app).enqueueUniqueWork("reminders-outbox", ExistingWorkPolicy.KEEP, work)
	}

	class FlushWork(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
		override suspend fun doWork(): Result = if (flush()) Result.success().also { sync() } else Result.retry()
	}

	class SyncWork(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
		override suspend fun doWork(): Result {
			sync()
			return Result.success()
		}
	}

	// ── sync ───────────────────────────────────────────────────────────────
	private suspend fun guarded(block: suspend () -> Unit): Boolean = try {
		block()
		problem.value = ""
		true
	} catch (error: Exception) {
		android.util.Log.w("Reminders", "failed", error)
		problem.value = error.message ?: error.javaClass.simpleName
		false
	}

	/** The list and what is active, from core; then the alarms. */
	suspend fun sync(): Boolean = syncing.withLock {
		if (Nas.account.value == null) return@withLock false
		loading.value = true
		kotlinx.coroutines.withTimeoutOrNull(90_000) { flush() }
		// never holds the lock for good, whatever hangs
		val ok = kotlinx.coroutines.withTimeoutOrNull(90_000) {
			guarded {
				val list = Snapshot.of(Dav.core("GET", "/api/reminders"))
				synchronized(lock) { snapshot.value = list }
				active(Dav.core("GET", "/api/reminders/active"))
			}
		} ?: false
		loading.value = false
		reschedule()
		ok
	}

	/** `/active`: what was missed is shown, what is no longer there goes. */
	private fun active(data: JsonElement?) {
		val entries = data["active"].list.mapNotNull { entry -> Reminder.of(entry["reminder"])?.let { Triple(it, entry["occurrence"].long, entry["escalated"].bool) } }
		for ((reminder, occurrence, escalated) in entries) present(reminder, occurrence, escalated, fromServer = true)
		val pairs = entries.map { it.first.id to it.second }.toSet()
		val ids = entries.map { it.first.id }.toSet()
		val now = now()
		for (shown in showing.value.values) if (Dedupe.goneElsewhere(shown, pairs, ids, now)) {
			synchronized(lock) { acked[key(shown.id, shown.occurrence)] = System.currentTimeMillis() }
			hide(shown.id)
		}
		save()
	}

	/** Polls `/active` every few minutes while something is shown and core's events do not come in. */
	private var polling: Job? = null

	private fun poll() {
		if (polling?.isActive == true) return
		polling = scope.launch {
			while (isActive && showing.value.values.any { it.level != "quiet" }) {
				delay(3 * 60_000L)
				if (!live.value) runCatching { active(Dav.core("GET", "/api/reminders/active")) }
			}
		}
	}

	// ── changes ────────────────────────────────────────────────────────────
	suspend fun parse(text: String): Parsed? = try {
		Parsed.of(Dav.core("POST", "/api/reminders/parse", JsonObject(mapOf("text" to JsonPrimitive(text)))))
	} catch (error: DavError) {
		null
	} catch (error: IOException) {
		null
	}

	suspend fun create(body: JsonObject): Boolean = change { Reminder.of(Dav.core("POST", "/api/reminders", body))?.let(::upsert) }

	suspend fun update(id: String, body: JsonObject): Boolean = change { Reminder.of(Dav.core("PATCH", "/api/reminders/$id", body))?.let(::upsert) }

	suspend fun delete(id: String): Boolean = change {
		Dav.core("DELETE", "/api/reminders/$id")
		synchronized(lock) { snapshot.value = snapshot.value.copy(reminders = snapshot.value.reminders.filter { it.id != id }) }
		hide(id)
	}

	private suspend fun change(block: suspend () -> Unit): Boolean {
		val ok = guarded(block)
		if (ok) {
			reschedule()
			scope.launch { sync() }
		}
		return ok
	}

	fun launch(block: suspend () -> Unit) = scope.launch { block() }

	// ── core's events ──────────────────────────────────────────────────────
	private val events = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(0, TimeUnit.SECONDS).pingInterval(30, TimeUnit.SECONDS).build()
	private var listener: Job? = null

	/** While the link service runs: core's WebSocket, so an ack elsewhere takes the notification away at once. */
	fun listen(on: Boolean) {
		listener?.cancel()
		listener = null
		live.value = false
		if (!on) return
		listener = scope.launch {
			var wait = 5_000L
			while (isActive) {
				val token = Nas.account.value?.token
				val base = if (token == null) null else runCatching { Nas.resolve() }.getOrNull()
				if (token != null && base != null) {
					val url = base.toHttpUrl()
					val closed = CompletableDeferred<Unit>()
					val socket = events.newWebSocket(
						Request.Builder().url("http://${url.host}:8097/api/events").header("Authorization", "Bearer $token").build(),
						object : WebSocketListener() {
							override fun onOpen(webSocket: WebSocket, response: Response) {
								live.value = true
								wait = 5_000L
								scope.launch { sync() }
							}
							override fun onMessage(webSocket: WebSocket, text: String) = event(text)
							override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { closed.complete(Unit) }
							override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { closed.complete(Unit) }
						},
					)
					try {
						closed.await()
					} finally {
						live.value = false
						socket.cancel()
					}
				}
				delay(wait)
				wait = (wait * 2).coerceAtMost(5 * 60_000L)
			}
		}
	}

	private var resync: Job? = null

	private fun event(text: String) {
		val data = runCatching { Json.parseToJsonElement(text) }.getOrNull() ?: return
		when (data["type"].string) {
			"reminder" -> Reminder.of(data["reminder"])?.let { reminder ->
				upsert(reminder)
				present(reminder, data["occurrence"].long, data["escalated"].bool, fromServer = true)
			}
			"reminder_ack" -> {
				val id = data["id"].string
				val occurrence = data["occurrence"].takeIf { it.present }?.long
				val shown = showing.value[id]
				if (shown != null && (occurrence == null || occurrence == shown.occurrence)) {
					synchronized(lock) { acked[key(id, shown.occurrence)] = System.currentTimeMillis() }
					hide(id)
					save()
				}
				refresh()
			}
			"reminder_snooze" -> {
				val id = data["id"].string
				val until = data["until"].takeIf { it.present }?.long
				synchronized(lock) { snoozes[id] = until ?: (now() + 120) }
				hide(id)
				save()
				refresh()
			}
			"reminders" -> refresh()
		}
	}

	/** A sync soon; several events in a row make one. */
	private fun refresh() {
		resync?.cancel()
		resync = scope.launch {
			delay(800)
			sync()
		}
	}

	// ── arriving home, leaving it ──────────────────────────────────────────
	private var homeCheck: Job? = null

	private fun watchHome() {
		val connectivity = app.getSystemService(ConnectivityManager::class.java)
		connectivity.registerNetworkCallback(
			NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(),
			object : ConnectivityManager.NetworkCallback() {
				override fun onAvailable(network: Network) = networks()
				override fun onLost(network: Network) = networks()
				override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = networks()
			},
		)
	}

	private fun networks() {
		homeCheck?.cancel()
		homeCheck = scope.launch {
			delay(8_000) // a switch comes as several callbacks, and Wi-Fi takes a moment
			if (Nas.account.value == null) return@launch
			val home = Nas.atHome()
			val before = if (store.contains("home")) store.getBoolean("home", false) else null
			store.edit().putBoolean("home", home).apply()
			if (before == null || before == home) {
				if (queued.value > 0) flush()
				return@launch
			}
			triggered(if (home) "arrive_home" else "leave_home")
		}
	}

	/** A trigger the phone saw: shown here at once (armed ones: `at` passed), and told to core, which fires it for every device. */
	fun triggered(trigger: String) {
		val now = now()
		for (reminder in snapshot.value.reminders) {
			if (!reminder.open || reminder.trigger != trigger) continue
			if ((reminder.snoozedUntil ?: 0) > now || (reminder.at ?: 0) > now) continue
			present(reminder, now, escalated = false, fromServer = false)
		}
		queue("POST", "/api/reminders/trigger", JsonObject(mapOf("trigger" to JsonPrimitive(trigger))))
	}
}
