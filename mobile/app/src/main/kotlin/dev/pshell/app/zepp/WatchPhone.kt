package dev.pshell.app.zepp

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager
import dev.pshell.app.App
import dev.pshell.app.service.Finder
import dev.pshell.app.service.PhoneNotificationListener
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * What the phone does for the watch while it keeps it (what Gadgetbridge did):
 * its notifications on the watch (replies and dismissals back), calls (reject,
 * mute), what plays (the watch's music app steers it), weather, find, and the
 * health data on to the PC when one is connected.
 */
@SuppressLint("MissingPermission")
object WatchPhone {
	private val main = Handler(Looper.getMainLooper())
	private val io = Executors.newSingleThreadExecutor()
	private var context: Context? = null
	private val keys = HashMap<Int, String>()      // watch id → notification key
	private var media: MediaController? = null
	private val app get() = App.instance
	private val zepp get() = WatchLink.zepp?.takeIf { WatchLink.flow.value.link == "ready" }

	fun attach(c: Context) {
		context = c
		Finder.onStop = { zepp?.foundPhone() }
	}

	fun ready(c: Context, z: Zepp) {
		z.events.findPhone = { start -> main.post { if (start && app.prefs.watchFind.value) Finder.ringFor(c, "Your watch is looking for this phone") else if (!start) Finder.stop(c) } }
		z.events.reply = { id, text -> keys[id]?.let { key -> runCatching { PhoneNotificationListener.instance?.reply(key, text) } } }
		z.events.dismiss = { id -> keys.remove(id)?.let { key -> runCatching { PhoneNotificationListener.instance?.cancelNotification(key) } } }
		z.events.callAction = { what -> main.post { callAction(c, what) } }
		z.events.musicOpen = { open -> main.post { if (open) music() } }
		z.events.button = { name -> main.post { button(c, name) } }
		z.events.http = { id, url -> weather(c, id, url) }
		if (app.prefs.watchWeather.value) location(c)?.let { (lat, lon) -> z.weatherLocation(lat, lon, "Here") }
		// what is there already
		runCatching { PhoneNotificationListener.instance?.activeNotifications }.getOrNull()?.forEach { posted(it) }
	}

	// ── notifications ─────────────────────────────────────────────────────
	fun posted(sbn: StatusBarNotification) {
		val z = zepp ?: return
		if (!app.prefs.watchNotify.value || PhoneNotificationListener.instance?.wanted(sbn) != true) return
		val extras = sbn.notification.extras
		val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
		val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
		if (title.isEmpty() && text.isEmpty()) return
		val id = sbn.key.hashCode() and 0x7FFFFFFF
		if (keys[id] == sbn.key + "\u0000" + title + text) return
		keys[id] = sbn.key
		val label = runCatching { context!!.packageManager.getApplicationLabel(context!!.packageManager.getApplicationInfo(sbn.packageName, 0)).toString() }.getOrDefault(sbn.packageName)
		val reply = sbn.notification.actions.orEmpty().any { !it.remoteInputs.isNullOrEmpty() }
		z.notify(id, title.ifEmpty { label }, text, sbn.packageName, label, reply, sms = sbn.notification.category == Notification.CATEGORY_MESSAGE && sbn.packageName.contains("messag"))
	}

	fun removed(sbn: StatusBarNotification) {
		val id = sbn.key.hashCode() and 0x7FFFFFFF
		if (keys.remove(id) != null) zepp?.unnotify(id)
	}

	// ── calls ─────────────────────────────────────────────────────────────
	fun call(state: String, number: String, name: String) {
		val z = zepp ?: return
		if (!app.prefs.watchCalls.value) return
		z.call(name.ifEmpty { number }, number, state == "ringing")
	}

	private fun callAction(c: Context, what: String) {
		if (what == "reject" && c.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED)
			runCatching { @Suppress("DEPRECATION") c.getSystemService(TelecomManager::class.java).endCall() }
		else runCatching { c.getSystemService(AudioManager::class.java).adjustStreamVolume(AudioManager.STREAM_RING, AudioManager.ADJUST_MUTE, 0) }
	}

	// ── music ─────────────────────────────────────────────────────────────
	private val callback = object : MediaController.Callback() {
		override fun onMetadataChanged(metadata: MediaMetadata?) = music()
		override fun onPlaybackStateChanged(state: PlaybackState?) = music()
	}

	private fun controller(): MediaController? {
		val c = context ?: return null
		val sessions = runCatching { c.getSystemService(MediaSessionManager::class.java).getActiveSessions(ComponentName(c, PhoneNotificationListener::class.java)) }.getOrNull() ?: return null
		val best = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: sessions.firstOrNull()
		if (best?.sessionToken != media?.sessionToken) {
			media?.unregisterCallback(callback)
			media = best
			best?.registerCallback(callback, main)
		}
		return best
	}

	fun music() {
		val z = zepp ?: return
		if (!app.prefs.watchMusic.value || !WatchLink.flow.value.musicOpen) return
		val m = controller()
		val meta = m?.metadata
		val audio = context?.getSystemService(AudioManager::class.java)
		val volume = audio?.let { it.getStreamVolume(AudioManager.STREAM_MUSIC) * 100 / maxOf(1, it.getStreamMaxVolume(AudioManager.STREAM_MUSIC)) }
		if (m == null) return z.music(null, "", "", "", 0, 0, volume)
		z.music(m.playbackState?.state == PlaybackState.STATE_PLAYING,
			meta?.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty(), meta?.getString(MediaMetadata.METADATA_KEY_ALBUM).orEmpty(),
			meta?.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty(), ((m.playbackState?.position ?: 0) / 1000).toInt(),
			((meta?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0) / 1000).toInt(), volume)
	}

	private fun button(c: Context, name: String) {
		val t = controller()?.transportControls
		val audio = c.getSystemService(AudioManager::class.java)
		when (name) {
			"play" -> t?.play()
			"pause" -> t?.pause()
			"next" -> t?.skipToNext()
			"previous" -> t?.skipToPrevious()
			"volup" -> audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, 0)
			"voldown" -> audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, 0)
		}
		main.postDelayed({ music() }, 300)
	}

	// ── weather ───────────────────────────────────────────────────────────
	private fun location(c: Context): Pair<Double, Double>? {
		if (c.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) return null
		val lm = c.getSystemService(LocationManager::class.java)
		val l = lm.getProviders(true).mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }.maxByOrNull { it.time } ?: return null
		return l.latitude to l.longitude
	}

	private fun weather(c: Context, id: Int, url: String) {
		val z = zepp ?: return
		val place = if (app.prefs.watchWeather.value) location(c) else null
		// the watch asks Huami's server by its full address: https://api-mifit.huami.com/weather/…
		val path = url.substringAfter("://", url).let { if (url.contains("://")) "/" + it.substringAfter('/', "") else it }
		if (!path.startsWith("/weather/") || place == null) return z.httpReply(id, 0, null)
		io.execute {
			val (status, body) = runCatching { WeatherZepp.answer(path, place.first, place.second) }.getOrDefault(404 to "{}")
			main.post { zepp?.httpReply(id, status, body) }
		}
	}

	// ── health, on to the PC ──────────────────────────────────────────────
	fun health(c: Context, days: List<JSONObject>, nights: List<JSONObject>, battery: Int?) {
		if (days.isEmpty() && nights.isEmpty()) return
		val args = JSONObject().put("days", JSONArray(days)).put("nights", JSONArray(nights)).put("synced", System.currentTimeMillis() / 1000)
		battery?.let { args.put("battery", it) }
		runCatching { app.link.run("health", "add", Json.parseToJsonElement(args.toString()) as JsonObject) }
	}
}
