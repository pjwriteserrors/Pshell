package dev.pshell.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import dev.pshell.app.R

/** The app's notification channels, and the ids its own notifications use. */
object Channels {
	const val PC = "pc"
	const val ASK = "ask"
	const val FILES = "files"
	const val LINKS = "links"
	const val FIND = "find"

	const val ID_FIND = 10
	const val ID_TRANSFER = 11

	fun create(context: Context) {
		val manager = context.getSystemService(NotificationManager::class.java)
		fun channel(id: String, name: String, importance: Int, description: String) =
			manager.createNotificationChannel(NotificationChannel(id, name, importance).apply { this.description = description })
		channel(PC, "Notifications of the PC", NotificationManager.IMPORTANCE_HIGH, "What pops up on the PC while you are away from it")
		channel(ASK, "Questions of the PC", NotificationManager.IMPORTANCE_HIGH, "Scripts and agents on the PC that need an answer")
		channel(FILES, "Files", NotificationManager.IMPORTANCE_LOW, "Files sent between the phone and the PC")
		channel(LINKS, "Links and text of the PC", NotificationManager.IMPORTANCE_HIGH, "Things the PC sends to open here")
		channel(FIND, "Find my phone", NotificationManager.IMPORTANCE_HIGH, "Rings when the PC looks for the phone")
	}

	fun builder(context: Context, channel: String): Notification.Builder =
		Notification.Builder(context, channel).setSmallIcon(R.drawable.ic_stat).setShowWhen(true)

	/** A broadcast to [Actions], carrying what was pressed. */
	fun action(context: Context, name: String, code: Int, fill: Intent.() -> Unit = {}): PendingIntent =
		PendingIntent.getBroadcast(
			context, code,
			Intent(context, Actions::class.java).setAction(name).apply(fill),
			// a reply field writes its text into the intent, so it must stay mutable
			PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
		)
}
