package dev.pshell.app

import android.app.Activity
import android.os.Bundle
import android.util.Base64
import android.widget.Toast
import dev.pshell.app.features.UnlockKey
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.string
import dev.pshell.app.service.Unlocks
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Nothing but the fingerprint prompt: opened by a tap on the "PC is locked"
 * notification, on a sudo request of the PC, or on the quick settings tile.
 * It unlocks the PC, or signs the request, and is gone again.
 */
class UnlockActivity : Activity() {
	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		setShowWhenLocked(true)
		setTurnScreenOn(true)
		val app = application as App
		val link = app.link.of(intent.getStringExtra("pc"))
		if (link == null || !UnlockKey.exists) {
			Toast.makeText(this, "Set up unlocking in the app first", Toast.LENGTH_SHORT).show()
			return finish()
		}
		val proof = intent.getStringExtra("proof")
		app.link.scope.launch(Dispatchers.Main) {
			val message = try {
				if (proof != null) {
					val nonce = Base64.decode(intent.getStringExtra("nonce"), Base64.DEFAULT)
					val signature = UnlockKey.sign(this@UnlockActivity, nonce, intent.getStringExtra("title") ?: "Allow on the PC?")
					if (signature == null) "Not allowed" else {
						link.call("unlock", "prove", json("id" to proof, "signature" to Base64.encodeToString(signature, Base64.NO_WRAP)))
						Unlocks.settled(app, proof)
						"Allowed"
					}
				} else {
					val nonce = Base64.decode(link.call("unlock", "challenge")["nonce"].string, Base64.DEFAULT)
					val signature = UnlockKey.sign(this@UnlockActivity, nonce, "Unlock ${link.pc?.name ?: "the PC"}")
					if (signature == null) "Not unlocked" else {
						link.call("unlock", "answer", json("signature" to Base64.encodeToString(signature, Base64.NO_WRAP)))
						"Unlocked"
					}
				}
			} catch (error: LinkError) {
				app.link.describe(error)
			}
			withContext(Dispatchers.Main) { Toast.makeText(this@UnlockActivity, message, Toast.LENGTH_SHORT).show() }
			finish()
		}
	}
}
