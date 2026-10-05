package dev.pshell.app.service

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import dev.pshell.app.App
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * What the PC sends to continue here: a link opens in its app, a video at
 * the second it was at on the PC, a text lands in the clipboard. Android
 * lets an app in the background open something only if it may "display over
 * other apps"; without that, the link waits in a notification.
 */
object Handoff {
	private val youtube = Regex("""(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|live/)|youtu\.be/)([\w-]{6,})""")

	fun install(app: App) {
		app.link.handle("phone.handoff", "open") { args ->
			val text = args["text"].string
			val url = args["url"].string
			if (url.isEmpty() && text.isNotEmpty()) {
				withContext(Dispatchers.Main) { app.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("PC", text)) }
				notify(app, "Text from the PC", text, null)
				return@handle json("copied" to true)
			}
			val intent = intent(app, url, args["position"].long) ?: throw LinkError("bad-url", "Not a link")
			// the PC let its headphones go: they come along
			args["headset"]["address"].string.takeIf { it.isNotEmpty() }?.let { Headset.connect(app, it) }
			val front = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
			val opened = app.prefs.openLinks.value && (front || Settings.canDrawOverlays(app)) && runCatching { app.startActivity(intent) }.isSuccess
			if (!opened) notify(app, args["title"].string.ifEmpty { "Link from the PC" }, if (Settings.canDrawOverlays(app)) url else "Tap to open. To open by itself: allow it under Continue in the app.", intent)
			json("opened" to opened)
		}
	}

	/** A YouTube link becomes one with the position, for the app the user chose. */
	fun intent(app: App, url: String, position: Long): Intent? {
		if (!url.startsWith("http://") && !url.startsWith("https://")) return null
		val video = youtube.find(url)?.groupValues?.get(1)
		val target = if (video != null) "https://youtu.be/$video" + (if (position > 0) "?t=$position" else "") else url
		return Intent(Intent.ACTION_VIEW, Uri.parse(target)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).apply {
			val chosen = app.prefs.youtubeApp.value
			if (video != null && chosen.isNotEmpty() && app.packageManager.getLaunchIntentForPackage(chosen) != null) setPackage(chosen)
		}
	}

	private fun notify(app: App, title: String, text: String, intent: Intent?) {
		val builder = Channels.builder(app, Channels.LINKS).setContentTitle(title).setContentText(text).setAutoCancel(true)
		if (intent != null) builder.setContentIntent(PendingIntent.getActivity(app, text.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
		app.getSystemService(NotificationManager::class.java).notify("link", text.hashCode(), builder.build())
	}
}
