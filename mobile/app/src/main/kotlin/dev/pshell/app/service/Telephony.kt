package dev.pshell.app.service

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.provider.ContactsContract
import android.telephony.TelephonyManager
import dev.pshell.app.App
import dev.pshell.app.link.json

/**
 * Calls: the PC hears when the phone rings, is in a call, or hung up, and
 * pauses what it plays for that time. Declared in the manifest, so it works
 * while the app is not open.
 */
class Telephony : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent) {
		if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
		val app = context.applicationContext as App
		if (!app.on("phone-telephony")) return
		val state = when (intent.getStringExtra(TelephonyManager.EXTRA_STATE)) {
			TelephonyManager.EXTRA_STATE_RINGING -> "ringing"
			TelephonyManager.EXTRA_STATE_OFFHOOK -> "offhook"
			else -> "idle"
		}
		// with the call log permission the broadcast comes twice: once without, once with the number
		@Suppress("DEPRECATION")
		val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER).orEmpty()
		if (state == "ringing" && number.isEmpty() && context.checkSelfPermission(Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED) return
		if (state == "idle") unsilence(context)
		app.link.emit("phone.telephony", "call", json("state" to state, "number" to number, "name" to name(context, number)))
	}

	private fun name(context: Context, number: String): String {
		if (number.isEmpty() || context.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) return ""
		return runCatching {
			val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
			context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else "" }
		}.getOrNull().orEmpty()
	}

	companion object {
		private var silenced = false

		fun install(app: App) {
			app.link.handle("phone.telephony", "silence") {
				silenced = runCatching { app.getSystemService(AudioManager::class.java).adjustStreamVolume(AudioManager.STREAM_RING, AudioManager.ADJUST_MUTE, 0) }.isSuccess
				json("silenced" to silenced)
			}
		}

		private fun unsilence(context: Context) {
			if (!silenced) return
			silenced = false
			runCatching { context.getSystemService(AudioManager::class.java).adjustStreamVolume(AudioManager.STREAM_RING, AudioManager.ADJUST_UNMUTE, 0) }
		}
	}
}
