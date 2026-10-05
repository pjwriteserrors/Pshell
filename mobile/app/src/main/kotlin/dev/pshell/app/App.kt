package dev.pshell.app

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import dev.pshell.app.link.Link
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.list
import dev.pshell.app.link.map
import dev.pshell.app.link.string
import dev.pshell.app.service.Asks
import dev.pshell.app.service.Channels
import dev.pshell.app.service.ClipboardSync
import dev.pshell.app.service.Finder
import dev.pshell.app.service.Handoff
import dev.pshell.app.service.PcNotifications
import dev.pshell.app.service.PhoneNotificationListener
import dev.pshell.app.service.Telephony
import dev.pshell.app.service.Transfers
import dev.pshell.app.ui.theme.Icons
import dev.pshell.app.ui.theme.Palette
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

class App : Application(), SingletonImageLoader.Factory {
	lateinit var link: Link
		private set
	lateinit var prefs: Prefs
		private set

	/** the switches of core/plugins.json as the PC resolved them */
	lateinit var plugins: StateFlow<Map<String, Boolean>>
		private set

	/** the PC's wallpaper colours, or the app's own */
	lateinit var palette: StateFlow<Palette>
		private set

	/** the PC's wallpaper, as a URL of the link */
	val wallpaper = MutableStateFlow<String?>(null)

	override fun onCreate() {
		super.onCreate()
		instance = this
		// a crash is written down and handed to the PC at the next connection
		val crashFile = java.io.File(filesDir, "crash.txt")
		val previous = Thread.getDefaultUncaughtExceptionHandler()
		Thread.setDefaultUncaughtExceptionHandler { thread, error ->
			runCatching { crashFile.writeText(android.util.Log.getStackTraceString(error)) }
			previous?.uncaughtException(thread, error)
		}
		Icons.load(this)
		prefs = Prefs(this)
		link = Link(this)

		val themeTopic = link.topic("theme")
		val pluginTopic = link.topic("plugins")
		link.scope.launch {
			themeTopic.collect { if (it != null) prefs.lastTheme.value = it.toString() }
		}
		link.scope.launch {
			pluginTopic.collect { if (it != null) prefs.lastPlugins.value = it.toString() }
		}
		link.scope.launch {
			themeTopic.collect { wallpaper.value = link.blob(it["wallpaper"].string) }
		}

		plugins = combine(pluginTopic, prefs.lastPlugins.flow) { live, saved -> (live ?: parse(saved)).map.mapValues { it.value.bool } }
			.stateIn(link.scope, SharingStarted.Eagerly, parse(prefs.lastPlugins.value).map.mapValues { it.value.bool })
		palette = combine(themeTopic, prefs.lastTheme.flow, prefs.theme.flow) { live, saved, mode -> if (mode == "wallust") derive(live ?: parse(saved)) else Palette.Default }
			.stateIn(link.scope, SharingStarted.Eagerly, if (prefs.theme.value == "wallust") derive(parse(prefs.lastTheme.value)) else Palette.Default)

		// what a phone needs to wake this PC later is remembered while it is reachable
		link.scope.launch {
			link.topic("link").collect { info ->
				val state = link.state.value as? dev.pshell.app.link.LinkState.Connected ?: return@collect
				val mac = info["mac"].list.map { it.string }
				if (mac.isNotEmpty() && mac != state.pc.mac) link.pcs.update(state.pc.id) { it.copy(mac = mac) }
			}
		}
		link.scope.launch {
			link.state.collect { state ->
				if (state is dev.pshell.app.link.LinkState.Connected && crashFile.exists()) {
					val trace = runCatching { crashFile.readText() }.getOrDefault("")
					runCatching { link.call("link", "crash", dev.pshell.app.link.json("trace" to trace, "version" to BuildConfig.VERSION_NAME)) }.onSuccess { crashFile.delete() }
				}
			}
		}
		Channels.create(this)
		PcNotifications.install(this)
		Asks.install(this)
		Finder.install(this)
		ClipboardSync.install(this)
		Transfers.install(this)
		Handoff.install(this)
		Telephony.install(this)
		PhoneNotificationListener.install(this)
		dev.pshell.app.service.Unlocks.install(this)
		dev.pshell.app.widget.Widgets.install(this)
		dev.pshell.app.features.Chat.install(this)
		link.start()
	}

	private fun parse(text: String): JsonElement? = if (text.isEmpty()) null else runCatching { Json.parseToJsonElement(text) }.getOrNull()

	private fun derive(theme: JsonElement?): Palette {
		val bg = Palette.parse(theme["background"].string) ?: return Palette.Default
		val fg = Palette.parse(theme["foreground"].string) ?: return Palette.Default
		return Palette.derive(bg, fg, theme["colors"].list.map { Palette.parse(it.string) ?: fg })
	}

	fun on(plugin: String) = plugins.value[plugin] == true

	override fun newImageLoader(context: PlatformContext): ImageLoader =
		ImageLoader.Builder(context).components {
			add(OkHttpNetworkFetcherFactory(callFactory = { link.http }))
			// the PC's program icons are mostly SVG (Papirus)
			add(coil3.svg.SvgDecoder.Factory())
		}.crossfade(true).build()

	companion object {
		lateinit var instance: App
			private set
	}
}
