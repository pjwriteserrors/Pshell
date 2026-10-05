package dev.pshell.app.service

import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import dev.pshell.app.App
import dev.pshell.app.link.json

/** "Where is my phone": rings as loud as it can until somebody finds it. */
object Finder {
	private var player: MediaPlayer? = null
	private var previousVolume = -1
	private val handler = Handler(Looper.getMainLooper())

	fun install(app: App) {
		app.link.handle("phone.find", "ring") {
			handler.post { ring(app) }
			json("ringing" to true)
		}
		app.link.handle("phone.find", "stop") {
			handler.post { stop(app) }
			json()
		}
	}

	private fun ring(context: Context) {
		if (player != null) return
		val audio = context.getSystemService(AudioManager::class.java)
		previousVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
		runCatching { audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0) }
		val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
		player = runCatching {
			MediaPlayer().apply {
				setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
				setDataSource(context, sound)
				isLooping = true
				prepare()
				start()
			}
		}.getOrNull()
		val notification = Channels.builder(context, Channels.FIND)
			.setContentTitle("Here I am")
			.setContentText("The PC is looking for this phone")
			.setOngoing(true)
			.setContentIntent(Channels.action(context, Actions.FIND_STOP, 1))
			.addAction(android.app.Notification.Action.Builder(null, "Found it", Channels.action(context, Actions.FIND_STOP, 1)).build())
			.build()
		context.getSystemService(NotificationManager::class.java).notify(Channels.ID_FIND, notification)
		handler.postDelayed({ stop(context) }, 90_000)
	}

	fun stop(context: Context) {
		handler.removeCallbacksAndMessages(null)
		player?.runCatching {
			stop()
			release()
		}
		player = null
		if (previousVolume >= 0) runCatching { context.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, previousVolume, 0) }
		previousVolume = -1
		context.getSystemService(NotificationManager::class.java).cancel(Channels.ID_FIND)
	}
}
