package dev.pshell.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import dev.pshell.app.link.LinkState
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.service.LinkService
import dev.pshell.app.ui.Nav
import dev.pshell.app.ui.Root

class MainActivity : ComponentActivity() {
	private val nav = Nav()
	/** a pairing code that arrived as a link, until the pairing screen took it */
	val pendingCode = mutableStateOf<String?>(null)
	/** a text marked in another app and handed over through "Ask AI" */
	val markedText = mutableStateOf<String?>(null)
	/** raised by a volume key, so the app can show the PC's volume */
	val volumeShown = mutableStateOf(0L)

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		enableEdgeToEdge(SystemBarStyle.dark(0), SystemBarStyle.dark(0))
		handle(intent)
		hideNavigation()
		val app = application as App
		setContent { Root(app, nav, this) }
		LinkService.start(this)
		if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
			requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		handle(intent)
	}

	/** Android lets only the app in front read the clipboard: this is the moment. */
	override fun onWindowFocusChanged(hasFocus: Boolean) {
		super.onWindowFocusChanged(hasFocus)
		if (!hasFocus) return
		hideNavigation()
		dev.pshell.app.service.ClipboardSync.send(this)
	}

	/** The system's navigation buttons stay away, as in a game; a swipe up from the edge shows them for a moment. */
	private fun hideNavigation() {
		window.insetsController?.apply {
			hide(android.view.WindowInsets.Type.navigationBars())
			systemBarsBehavior = android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
		}
	}

	override fun onStart() {
		super.onStart()
		(application as App).link.foreground = true
	}

	override fun onStop() {
		super.onStop()
		(application as App).link.foreground = false
	}

	private fun handle(intent: Intent?) {
		val data = intent?.data
		if (data?.scheme == "pshell" && data.host == "pair") pendingCode.value = data.toString()
		intent?.getStringExtra("route")?.let { nav.open(it) }
		if (intent?.action == Intent.ACTION_PROCESS_TEXT) {
			val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.trim().orEmpty()
			if (text.isNotEmpty()) {
				if (intent.component?.className.orEmpty().endsWith("ProcessTranslate")) {
					dev.pshell.app.features.Chat.ask(dev.pshell.app.features.TextAction.Translate, text)
					nav.open("feature/chat")
				} else markedText.value = text
			}
		}
	}

	/** While the app is open, the volume keys are the PC's. */
	override fun dispatchKeyEvent(event: KeyEvent): Boolean {
		val app = application as App
		val direction = when (event.keyCode) {
			KeyEvent.KEYCODE_VOLUME_UP -> 1
			KeyEvent.KEYCODE_VOLUME_DOWN -> -1
			else -> 0
		}
		if (direction == 0 || !app.prefs.volumeKeys.value || app.link.state.value !is LinkState.Connected || !app.on("sound") || !app.on("phone"))
			return super.dispatchKeyEvent(event)
		if (event.action == KeyEvent.ACTION_DOWN) {
			app.link.acquire("sound")
			val current = app.link.topic("sound").value["volume"].float
			val next = (current + direction * app.prefs.volumeStep.value / 100f).coerceIn(0f, 1f)
			app.link.run("sound", "set", json("volume" to next))
			volumeShown.value = System.currentTimeMillis()
			app.link.release("sound")
		}
		return true
	}
}
