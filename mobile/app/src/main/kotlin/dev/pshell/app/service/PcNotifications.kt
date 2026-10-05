package dev.pshell.app.service

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import dev.pshell.app.App
import dev.pshell.app.MainActivity
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import okhttp3.Request

/**
 * Notifications of the PC, shown here with their buttons and their reply
 * field; what is pressed or typed goes back and acts on the PC's notification.
 */
object PcNotifications {
	const val TAG = "pc"

	fun install(app: App) {
		val manager = app.getSystemService(NotificationManager::class.java)
		app.link.scope.launch {
			app.link.events.collect { event ->
				if (event.topic != "notifications") return@collect
				when (event.name) {
					"posted" -> launch { post(app, manager, event.data) }
					"closed" -> places.remove(event.data["id"].int)?.let { manager.cancel(TAG, it) }
				}
			}
		}
	}

	suspend fun image(app: App, path: String): Bitmap? {
		val url = app.link.blob(path) ?: return null
		return withContext(Dispatchers.IO) {
			runCatching { app.link.http.newCall(Request.Builder().url(url).build()).execute().use { BitmapFactory.decodeStream(it.body.byteStream()) } }.getOrNull()
		}
	}

	/** PC id → the place it took on the phone, to take it away when the PC closes it */
	private val places = java.util.concurrent.ConcurrentHashMap<Int, Int>()

	private suspend fun post(app: App, manager: NotificationManager, data: JsonElement?) {
		val id = data["id"].int
		// One place per program and title: a notification that is updated, or
		// sent again, replaces its predecessor instead of piling up below it.
		val place = "${data["app"].string}|${data["title"].string}".hashCode()
		places[id] = place
		val picture = image(app, data["image"].string)
		val builder = Channels.builder(app, Channels.PC)
			.setContentTitle(data["title"].string)
			.setContentText(data["body"].string)
			.setSubText(data["app"].string)
			.setStyle(Notification.BigTextStyle().bigText(data["body"].string))
			.setLargeIcon(picture)
			.setAutoCancel(true)
			.setGroup("pc")
			.setContentIntent(PendingIntent.getActivity(app, 0, Intent(app, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
			.setDeleteIntent(Channels.action(app, Actions.PC_DISMISS, place * 16) {
				putExtra("id", id)
				putExtra("place", place)
			})
		if (data["critical"].bool) builder.setCategory(Notification.CATEGORY_ALARM)
		data["actions"].list.take(3).forEachIndexed { index, action ->
			builder.addAction(Notification.Action.Builder(null, action["label"].string, Channels.action(app, Actions.PC_ACT, place * 16 + 1 + index) {
				putExtra("id", id)
				putExtra("place", place)
				putExtra("action", action["id"].string)
			}).build())
		}
		if (data["reply"].bool) {
			builder.addAction(
				Notification.Action.Builder(null, data["placeholder"].string.ifEmpty { "Reply" }, Channels.action(app, Actions.PC_REPLY, place * 16 + 8) {
					putExtra("id", id)
					putExtra("place", place)
				})
					.addRemoteInput(RemoteInput.Builder("text").setLabel(data["placeholder"].string.ifEmpty { "Reply" }).build())
					.build(),
			)
		}
		manager.notify(TAG, place, builder.build())
		// several of them fold into one line in the shade
		manager.notify(TAG, 0, Channels.builder(app, Channels.PC).setContentTitle("PC").setGroup("pc").setGroupSummary(true).setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN).setAutoCancel(true).build())
	}
}
