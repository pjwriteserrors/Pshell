package dev.pshell.app.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import dev.pshell.app.App
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.string
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The shared clipboard. What is copied on the PC is put into the phone's
 * clipboard at once. The other way Android only lets the app in front read
 * the clipboard, so the phone's is sent whenever the app comes to the front
 * (and by the "Send clipboard" tile).
 */
object ClipboardSync {
	private var lastFromPc = ""
	private var lastSent = ""

	fun install(app: App) {
		app.link.acquire("clipboard")
		app.link.scope.launch {
			combine(app.link.topic("clipboard"), app.prefs.clipboardToPhone.flow) { clip, enabled -> if (enabled) clip else null }.collect { clip ->
				val text = clip["text"].string
				if (text.isEmpty() || clip["from"].string != "pc" || text == lastFromPc) return@collect
				lastFromPc = text
				withContext(Dispatchers.Main) {
					runCatching { app.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("PC", text)) }
				}
			}
		}
	}

	/** Called while the app has the focus: only then may it read the clipboard. */
	fun send(context: Context, force: Boolean = false): Boolean {
		val app = context.applicationContext as App
		if (!app.on("phone-clipboard") || (!force && !app.prefs.clipboardToPc.value)) return false
		val text = runCatching { context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.coerceToText(context)?.toString() }.getOrNull().orEmpty()
		if (text.isEmpty() || (!force && (text == lastSent || text == lastFromPc))) return false
		lastSent = text
		app.link.run("clipboard", "set", json("text" to text))
		return true
	}
}
