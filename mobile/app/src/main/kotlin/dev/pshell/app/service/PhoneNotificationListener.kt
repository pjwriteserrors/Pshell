package dev.pshell.app.service

import android.app.Notification
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import dev.pshell.app.App
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.LinkState
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.string
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/**
 * The phone's notifications for the PC: each one with its text, its app's
 * icon and its actions. A click, a reply or a dismissal on the PC comes back
 * here and is carried out on the real notification.
 */
class PhoneNotificationListener : NotificationListenerService() {
	private val app get() = application as App
	private val icons = HashMap<String, String>()
	// key → what was last sent for it, so that a re-post with the same text
	// counts as an update (no toast) and a new message in the same chat does not
	private val sent = HashMap<String, String>()
	private var watcher: Job? = null

	override fun onListenerConnected() {
		instance = this
		// after every (re)connection the PC learns what is there, quietly
		watcher = app.link.scope.launch {
			resend()
			app.link.connects.collect { resend() }
		}
	}

	override fun onListenerDisconnected() {
		watcher?.cancel()
		if (instance === this) instance = null
	}

	override fun onNotificationPosted(sbn: StatusBarNotification) = send(sbn, quiet = false)

	override fun onNotificationRemoved(sbn: StatusBarNotification) {
		if (sent.remove(sbn.key) != null) app.link.emit("phone.notifications", "removed", json("key" to sbn.key))
	}

	/** Everything that is there, quietly: for a PC that (re)connected or whose shell started again. */
	fun resend() {
		runCatching { activeNotifications }.getOrNull()?.forEach { send(it, quiet = true) }
	}

	private fun wanted(sbn: StatusBarNotification): Boolean {
		val notification = sbn.notification
		if (sbn.packageName == packageName) return false
		if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
		if (notification.flags and (Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE) != 0) return false
		if (notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) return false
		if (notification.category == Notification.CATEGORY_CALL) return false
		return sbn.packageName !in app.prefs.mutedApps.value.split('\n')
	}

	private fun send(sbn: StatusBarNotification, quiet: Boolean) {
		if (!app.on("phone-notifications") || app.link.state.value !is LinkState.Connected || !wanted(sbn)) return
		val extras = sbn.notification.extras
		val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
		val text = (messages(extras) ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
		if (title.isEmpty() && text.isEmpty()) return
		val ranking = Ranking().also { currentRanking.getRanking(sbn.key, it) }
		val signature = "$title\u0000$text"
		val update = quiet || sent[sbn.key] == signature
		sent[sbn.key] = signature
		val actions = sbn.notification.actions.orEmpty().mapIndexed { index, action ->
			json("id" to index.toString(), "label" to action.title?.toString().orEmpty(), "reply" to !action.remoteInputs.isNullOrEmpty())
		}
		app.link.emit("phone.notifications", "posted", json(
			"key" to sbn.key,
			"package" to sbn.packageName,
			"app" to label(sbn.packageName),
			"title" to title,
			"text" to text,
			"icon" to icon(sbn.packageName),
			"actions" to actions,
			"canOpen" to (sbn.notification.contentIntent != null),
			"silent" to (ranking.importance < android.app.NotificationManager.IMPORTANCE_DEFAULT),
			"update" to update,
			"time" to sbn.postTime,
		))
	}

	/** The newest line of a conversation, with who said it. */
	private fun messages(extras: Bundle): CharSequence? {
		val last = extras.getParcelableArray(Notification.EXTRA_MESSAGES)?.lastOrNull() as? Bundle ?: return null
		val text = last.getCharSequence("text") ?: return null
		val sender = last.getCharSequence("sender")
		return if (sender.isNullOrEmpty() || extras.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION).not()) text else "$sender: $text"
	}

	private fun label(name: String): String = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(name, 0)).toString() }.getOrDefault(name)

	/** The app's icon as a small PNG in a data: URL, which the shell's views can show as they are. */
	private fun icon(name: String): String = icons.getOrPut(name) {
		runCatching {
			val drawable = packageManager.getApplicationIcon(name)
			val bitmap = Bitmap.createBitmap(72, 72, Bitmap.Config.ARGB_8888)
			drawable.setBounds(0, 0, 72, 72)
			drawable.draw(Canvas(bitmap))
			val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
			"data:image/png;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
		}.getOrDefault("")
	}

	private fun find(key: String): StatusBarNotification = runCatching { activeNotifications }.getOrNull()?.firstOrNull { it.key == key } ?: throw LinkError("gone", "That notification is gone")

	fun act(key: String, index: Int, text: String?) {
		val action = find(key).notification.actions?.getOrNull(index) ?: throw LinkError("gone", "That action is gone")
		val inputs = action.remoteInputs
		if (text != null && !inputs.isNullOrEmpty()) {
			val intent = Intent()
			RemoteInput.addResultsToIntent(inputs, intent, Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, text) } })
			action.actionIntent.send(this, 0, intent)
		} else {
			action.actionIntent.send()
		}
	}

	companion object {
		@Volatile var instance: PhoneNotificationListener? = null

		fun enabled(context: Context): Boolean =
			Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners").orEmpty().contains(ComponentName(context, PhoneNotificationListener::class.java).flattenToString())

		fun install(app: App) {
			fun listener() = instance ?: throw LinkError("no-access", "The app may not read notifications")
			app.link.handle("phone.notifications", "act") { args ->
				listener().act(args["key"].string, args["action"].string.toIntOrNull() ?: -1, null)
				JsonObject(emptyMap())
			}
			app.link.handle("phone.notifications", "reply") { args ->
				listener().act(args["key"].string, args["action"].string.toIntOrNull() ?: -1, args["text"].string)
				JsonObject(emptyMap())
			}
			app.link.handle("phone.notifications", "dismiss") { args ->
				listener().cancelNotification(args["key"].string)
				JsonObject(emptyMap())
			}
			app.link.handle("phone.notifications", "sync") {
				listener().resend()
				JsonObject(emptyMap())
			}
		}
	}
}
