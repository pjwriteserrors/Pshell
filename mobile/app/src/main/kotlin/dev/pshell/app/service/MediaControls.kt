package dev.pshell.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.SystemClock
import dev.pshell.app.App
import dev.pshell.app.MainActivity
import dev.pshell.app.R
import dev.pshell.app.features.mediaPosition
import dev.pshell.app.link.LinkState
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.string
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import okhttp3.Request

/**
 * The PC's player as a media session of the phone: it shows up in the
 * notification shade's media controls and on the lock screen, and because
 * its volume is "remote", the volume keys set the PC's volume while it plays.
 */
class MediaControls(private val service: Service, private val app: App, private val scope: CoroutineScope) {
	private val link = app.link
	private val manager = service.getSystemService(NotificationManager::class.java)
	private var session: MediaSession? = null
	private var job: Job? = null
	private var artUrl: String? = null
	private var art: Bitmap? = null
	private var shown = false

	private val volume = object : VolumeProvider(VOLUME_CONTROL_ABSOLUTE, 100, 0) {
		override fun onSetVolumeTo(volume: Int) = set(volume)

		override fun onAdjustVolume(direction: Int) {
			if (direction != 0) set(currentVolume + direction * app.prefs.volumeStep.value)
		}

		fun set(next: Int) {
			val clamped = next.coerceIn(0, 100)
			currentVolume = clamped
			link.run("sound", "set", json("volume" to clamped / 100.0))
		}
	}

	fun start() {
		manager.createNotificationChannel(NotificationChannel(CHANNEL, "Media on the PC", NotificationManager.IMPORTANCE_LOW).apply {
			description = "Controls for what plays on the PC"
			setShowBadge(false)
		})
		link.acquire("media")
		link.acquire("sound")
		job = scope.launch {
			combine(link.topic("media"), link.topic("sound"), link.state, app.prefs.mediaControls.flow, app.prefs.volumeKeys.flow) { media, sound, state, enabled, keys ->
				Snapshot(media, sound, state is LinkState.Connected && enabled && app.on("media") && media["has"].bool, keys && app.on("sound"))
			}.collect(::update)
		}
	}

	fun stop() {
		job?.cancel()
		link.release("media")
		link.release("sound")
		hide()
	}

	fun onAction(action: String) {
		when (action) {
			ACTION_TOGGLE -> link.run("media", "playPause")
			ACTION_NEXT -> link.run("media", "next")
			ACTION_PREVIOUS -> link.run("media", "previous")
		}
	}

	private class Snapshot(val media: JsonElement?, val sound: JsonElement?, val show: Boolean, val remoteVolume: Boolean)

	private fun ensureSession(): MediaSession = session ?: MediaSession(service, "pshell").apply {
		setCallback(object : MediaSession.Callback() {
			override fun onPlay() = link.run("media", "play")
			override fun onPause() = link.run("media", "pause")
			override fun onStop() = link.run("media", "pause")
			override fun onSkipToNext() = link.run("media", "next")
			override fun onSkipToPrevious() = link.run("media", "previous")
			override fun onSeekTo(pos: Long) = link.run("media", "seek", json("position" to pos / 1000.0))
		})
		setSessionActivity(PendingIntent.getActivity(service, 1, Intent(service, MainActivity::class.java).putExtra("route", "feature/media"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
		session = this
	}

	private fun hide() {
		if (!shown) return
		shown = false
		session?.isActive = false
		session?.release()
		session = null
		manager.cancel(ID)
	}

	private fun update(snapshot: Snapshot) {
		if (!snapshot.show) return hide()
		val media = snapshot.media
		val current = ensureSession()

		val url = link.blob(media["art"].string)
		if (url != artUrl) {
			artUrl = url
			art = null
			if (url != null) scope.launch {
				val loaded = withContext(Dispatchers.IO) {
					runCatching { link.http.newCall(Request.Builder().url(url).build()).execute().use { BitmapFactory.decodeStream(it.body.byteStream()) } }.getOrNull()
				}
				if (artUrl == url && loaded != null) {
					art = loaded
					update(snapshot)
				}
			}
		}

		val playing = media["playing"].bool
		var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE
		if (media["canNext"].bool) actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
		if (media["canPrevious"].bool) actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
		if (media["canSeek"].bool) actions = actions or PlaybackState.ACTION_SEEK_TO
		current.setMetadata(MediaMetadata.Builder()
			.putString(MediaMetadata.METADATA_KEY_TITLE, media["title"].string)
			.putString(MediaMetadata.METADATA_KEY_ARTIST, media["artist"].string)
			.putString(MediaMetadata.METADATA_KEY_ALBUM, media["album"].string)
			.putLong(MediaMetadata.METADATA_KEY_DURATION, if (media["length"].double > 0) (media["length"].double * 1000).toLong() else -1L)
			.apply { art?.let { putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) } }
			.build())
		current.setPlaybackState(PlaybackState.Builder()
			.setActions(actions)
			.setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, (mediaPosition(media, link) * 1000).toLong(), if (playing) media["rate"].double.toFloat().takeIf { it > 0f } ?: 1f else 0f, SystemClock.elapsedRealtime())
			.build())

		if (snapshot.remoteVolume) {
			val level = if (snapshot.sound["muted"].bool) 0 else Math.round(snapshot.sound["volume"].double * 100).toInt()
			if (volume.currentVolume != level) volume.currentVolume = level
			current.setPlaybackToRemote(volume)
		} else {
			current.setPlaybackToLocal(AudioAttributes.Builder().setLegacyStreamType(android.media.AudioManager.STREAM_MUSIC).build())
		}
		current.isActive = true

		fun action(icon: Int, title: String, name: String) = Notification.Action.Builder(
			Icon.createWithResource(service, icon), title,
			PendingIntent.getService(service, name.hashCode(), Intent(service, LinkService::class.java).setAction(name), PendingIntent.FLAG_IMMUTABLE),
		).build()

		val notification = Notification.Builder(service, CHANNEL)
			.setSmallIcon(R.drawable.ic_stat)
			.setContentTitle(media["title"].string)
			.setContentText(media["artist"].string)
			.setSubText(media["player"].string)
			.setLargeIcon(art)
			.setContentIntent(current.controller.sessionActivity)
			.setVisibility(Notification.VISIBILITY_PUBLIC)
			.setOngoing(playing)
			.setShowWhen(false)
			.addAction(action(android.R.drawable.ic_media_previous, "Previous", ACTION_PREVIOUS))
			.addAction(action(if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play, if (playing) "Pause" else "Play", ACTION_TOGGLE))
			.addAction(action(android.R.drawable.ic_media_next, "Next", ACTION_NEXT))
			.setStyle(Notification.MediaStyle().setMediaSession(current.sessionToken).setShowActionsInCompactView(0, 1, 2))
			.build()
		manager.notify(ID, notification)
		shown = true
	}

	companion object {
		private const val CHANNEL = "media"
		private const val ID = 2
		const val ACTION_TOGGLE = "dev.pshell.app.media.TOGGLE"
		const val ACTION_NEXT = "dev.pshell.app.media.NEXT"
		const val ACTION_PREVIOUS = "dev.pshell.app.media.PREVIOUS"
	}
}
