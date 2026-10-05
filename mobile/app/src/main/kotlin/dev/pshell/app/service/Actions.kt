package dev.pshell.app.service

import android.app.NotificationManager
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.pshell.app.App
import dev.pshell.app.link.json

/** Buttons and reply fields of the app's own notifications end up here. */
class Actions : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent) {
		val app = context.applicationContext as App
		val manager = context.getSystemService(NotificationManager::class.java)
		val id = intent.getIntExtra("id", 0)
		val typed = RemoteInput.getResultsFromIntent(intent)?.getCharSequence("text")?.toString()
		when (intent.action) {
			PC_ACT -> {
				app.link.run("notifications", "act", json("id" to id, "action" to intent.getStringExtra("action")))
				manager.cancel(PcNotifications.TAG, intent.getIntExtra("place", id))
			}
			PC_REPLY -> {
				if (!typed.isNullOrBlank()) app.link.run("notifications", "reply", json("id" to id, "text" to typed))
				manager.cancel(PcNotifications.TAG, intent.getIntExtra("place", id))
			}
			PC_DISMISS -> app.link.run("notifications", "dismiss", json("id" to id))
			ASK_ANSWER -> Asks.answer(intent.getStringExtra("ask").orEmpty(), action = intent.getStringExtra("action"), text = typed)
			ASK_DISMISS -> Asks.dismiss(intent.getStringExtra("ask").orEmpty())
			FIND_STOP -> Finder.stop(context)
		}
	}

	companion object {
		const val PC_ACT = "dev.pshell.app.PC_ACT"
		const val PC_REPLY = "dev.pshell.app.PC_REPLY"
		const val PC_DISMISS = "dev.pshell.app.PC_DISMISS"
		const val ASK_ANSWER = "dev.pshell.app.ASK_ANSWER"
		const val ASK_DISMISS = "dev.pshell.app.ASK_DISMISS"
		const val FIND_STOP = "dev.pshell.app.FIND_STOP"
	}
}
