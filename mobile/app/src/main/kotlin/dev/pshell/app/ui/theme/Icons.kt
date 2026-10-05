package dev.pshell.app.ui.theme

import android.content.Context
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The shell's icons: Material Design glyphs of "Symbols Nerd Font", by the
 * names of style/theme/Icons.qml. The map is generated from that file at
 * build time, so an icon the PC names is one the phone can draw.
 */
object Icons {
	private var glyphs: Map<String, String> = emptyMap()

	fun load(context: Context) {
		if (glyphs.isNotEmpty()) return
		glyphs = runCatching {
			context.assets.open("icons.json").bufferedReader().use { Json.parseToJsonElement(it.readText()) }
				.jsonObject.mapValues { it.value.jsonPrimitive.content }
		}.getOrDefault(emptyMap())
	}

	fun has(name: String) = glyphs.containsKey(name)

	operator fun get(name: String): String = glyphs[name] ?: glyphs["help_circle_outline"] ?: "?"

	val names: List<String> get() = glyphs.keys.sorted()
}
