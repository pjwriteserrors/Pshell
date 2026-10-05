package dev.pshell.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import dev.pshell.app.link.LinkState
import dev.pshell.app.link.json
import dev.pshell.app.service.ClipboardSync
import dev.pshell.app.service.Transfers

/**
 * "Share → pshell" from any app: a link opens on the PC, a text lands in
 * its clipboard, files go to its downloads folder. Also the target of the
 * "Send clipboard" tile, since only an activity in front may read the
 * clipboard. It has no window of its own and closes at once.
 */
class ShareActivity : Activity() {
	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		val app = application as App
		if (intent.action == ACTION_CLIPBOARD) return  // read in onWindowFocusChanged
		if (app.link.state.value !is LinkState.Connected) {
			toast("The PC is not connected")
			return finish()
		}
		// shared text, or a text marked somewhere and sent through "Send to PC"
		val text = (intent.getStringExtra(Intent.EXTRA_TEXT) ?: intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString())?.trim().orEmpty()
		@Suppress("DEPRECATION")
		val files = when (intent.action) {
			Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
			Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
			else -> emptyList()
		}
		when {
			files.isNotEmpty() -> {
				Transfers.upload(files)
				toast(if (files.size == 1) "Sending to the PC" else "Sending ${files.size} files to the PC")
			}
			Regex("""https?://\S+""").find(text) != null -> {
				app.link.run("handoff", "open", json("url" to Regex("""https?://\S+""").find(text)!!.value))
				toast("Opening on the PC")
			}
			text.isNotEmpty() -> {
				app.link.run("clipboard", "set", json("text" to text))
				toast("Copied on the PC")
			}
		}
		finish()
	}

	override fun onWindowFocusChanged(hasFocus: Boolean) {
		super.onWindowFocusChanged(hasFocus)
		if (!hasFocus || intent.action != ACTION_CLIPBOARD) return
		toast(if (ClipboardSync.send(this, force = true)) "Clipboard sent to the PC" else "Nothing to send")
		finish()
	}

	private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_SHORT).show()

	companion object {
		const val ACTION_CLIPBOARD = "dev.pshell.app.SEND_CLIPBOARD"
	}
}
