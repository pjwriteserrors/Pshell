package dev.pshell.app.service

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import dev.pshell.app.App
import dev.pshell.app.UnlockActivity
import dev.pshell.app.features.UnlockKey
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.string
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement

/**
 * The fingerprint, within reach: a notification while a PC is locked (tap,
 * finger, unlocked), and one for every request of the PC (sudo) that opens
 * the prompt right away.
 */
object Unlocks {
	private const val LOCKED = 30

	fun intent(context: Context, pc: String, proof: JsonElement? = null): Intent =
		Intent(context, UnlockActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION).putExtra("pc", pc).apply {
			if (proof != null) {
				putExtra("proof", proof["id"].string)
				putExtra("nonce", proof["nonce"].string)
				putExtra("title", proof["title"].string)
			}
		}

	fun install(app: App) {
		val manager = app.getSystemService(NotificationManager::class.java)
		app.link.acquire("session")
		// "PC locked": as long as it is, for the PC in front
		app.link.scope.launch {
			app.link.active.collectLatest { one ->
				if (one == null) return@collectLatest
				one.topic("session").collect { session ->
					val locked = session["locked"].bool && UnlockKey.exists && app.on("phone-unlock") && one.connected
					if (!locked) return@collect manager.cancel("unlock", LOCKED)
					val tap = PendingIntent.getActivity(app, LOCKED, intent(app, one.id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
					manager.notify("unlock", LOCKED, Channels.builder(app, Channels.ASK)
						.setContentTitle("${one.pc?.name ?: "The PC"} is locked")
						.setContentText("Tap and put your finger on the sensor to unlock it")
						.setContentIntent(tap)
						.setOngoing(true)
						.setOnlyAlertOnce(true)
						.setCategory(Notification.CATEGORY_STATUS)
						.build())
				}
			}
		}
		// a request of the PC: sudo, or whatever asked through the PAM helper
		app.link.handle("phone.unlock", "prove") { request ->
			val pc = app.link.active.value?.id.orEmpty()
			val front = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
			val tap = intent(app, pc, request)
			val opened = front && runCatching { app.startActivity(tap) }.isSuccess
			if (!opened) {
				val pending = PendingIntent.getActivity(app, request["id"].string.hashCode(), tap, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
				manager.notify("prove", request["id"].string.hashCode(), Channels.builder(app, Channels.ASK)
					.setContentTitle(request["title"].string.ifEmpty { "Allow on the PC?" })
					.setContentText(request["body"].string.ifEmpty { "Tap and put your finger on the sensor." })
					.setContentIntent(pending)
					// the request is urgent: it shows over whatever is on the screen
					.setFullScreenIntent(pending, true)
					.setCategory(Notification.CATEGORY_ALARM)
					.setAutoCancel(true)
					.setTimeoutAfter(request["timeout"].int.takeIf { it > 0 }?.times(1000L) ?: 60_000L)
					.build())
			}
			json("shown" to true, "opened" to opened)
		}
		app.link.handle("phone.unlock", "settle") { request ->
			settled(app, request["id"].string)
			json()
		}
	}

	fun settled(app: App, id: String) {
		app.getSystemService(NotificationManager::class.java).cancel("prove", id.hashCode())
	}
}
