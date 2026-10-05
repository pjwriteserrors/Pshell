package dev.pshell.app

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** What the user set on this phone. Each setting is a flow, so the UI follows. */
class Prefs(context: Context) {
	private val prefs: SharedPreferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

	inner class Setting<T>(private val key: String, private val default: T) {
		private val state = MutableStateFlow(read())
		val flow: StateFlow<T> = state
		var value: T
			get() = state.value
			set(next) {
				state.value = next
				prefs.edit().apply {
					when (next) {
						is Boolean -> putBoolean(key, next)
						is Int -> putInt(key, next)
						is Float -> putFloat(key, next)
						else -> putString(key, next.toString())
					}
				}.apply()
			}

		@Suppress("UNCHECKED_CAST")
		private fun read(): T = when (default) {
			is Boolean -> prefs.getBoolean(key, default)
			is Int -> prefs.getInt(key, default)
			is Float -> prefs.getFloat(key, default)
			else -> prefs.getString(key, default.toString())
		} as T
	}

	/** "wallust": the PC's wallpaper colours; "default": the app's own */
	val theme = Setting("theme", "wallust")
	/** the wallpaper behind the home screen's header */
	val wallpaper = Setting("wallpaper", true)
	/** the PC's player in the phone's media controls */
	val mediaControls = Setting("mediaControls", true)
	/** volume keys set the PC's volume */
	val volumeKeys = Setting("volumeKeys", true)
	/** percent per key press */
	val volumeStep = Setting("volumeStep", 5)
	/** the app YouTube links open in; empty asks Android */
	val youtubeApp = Setting("youtubeApp", "")

	/** what is copied on the PC lands in the phone's clipboard */
	val clipboardToPhone = Setting("clipboardToPhone", true)
	/** the phone's clipboard is sent when the app comes to the front */
	val clipboardToPc = Setting("clipboardToPc", true)
	/** links of the PC open without asking (needs "display over other apps") */
	val openLinks = Setting("openLinks", true)

	/** packages whose notifications stay on the phone, one per line */
	val mutedApps = Setting("mutedApps", "")

	// the last the PC said, so the app looks and offers the same while offline
	val lastTheme = Setting("lastTheme", "")
	val lastPlugins = Setting("lastPlugins", "")
	val lastCommands = Setting("lastCommands", "")
	/** the model the chat used last */
	val chatModel = Setting("chatModel", "")
}
