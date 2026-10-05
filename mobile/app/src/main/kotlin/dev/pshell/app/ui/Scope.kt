package dev.pshell.app.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.staticCompositionLocalOf
import dev.pshell.app.App
import dev.pshell.app.link.Link
import dev.pshell.app.link.LinkState
import kotlinx.serialization.json.JsonElement

val LocalApp = staticCompositionLocalOf<App> { error("no app") }
val LocalNav = staticCompositionLocalOf<Nav> { error("no nav") }

val link: Link
	@Composable get() = LocalApp.current.link

/** A topic of the PC, subscribed for as long as the caller is on screen. */
@Composable
fun topic(name: String): JsonElement? {
	val link = link
	DisposableEffect(name) {
		link.acquire(name)
		onDispose { link.release(name) }
	}
	val value by link.topic(name).collectAsState()
	return value
}

@Composable
fun linkState(): LinkState {
	val state by link.state.collectAsState()
	return state
}

@Composable
fun connected(): Boolean = linkState() is LinkState.Connected

@Composable
fun pluginOn(vararg plugins: String): Boolean {
	val state by LocalApp.current.plugins.collectAsState()
	return state["phone"] == true && plugins.all { state[it] == true }
}

/** The floating tab bar's manners: gone while the content scrolls down, a mere handle where every pixel counts. */
object Chrome {
	var hidden by androidx.compose.runtime.mutableStateOf(false)
	/** routes on which the bar is only a handle until it is tapped */
	val compactRoutes = setOf("feature/touchpad", "feature/terminal")
	var expanded by androidx.compose.runtime.mutableStateOf(false)
}

/** Where the user is: a stack of routes ("home", "feature/media", "settings", …). */
class Nav {
	val stack = mutableStateListOf("home")
	val current: String get() = stack.last()

	fun open(route: String) {
		if (stack.last() != route) stack.add(route)
	}

	fun back(): Boolean {
		if (stack.size <= 1) return false
		stack.removeAt(stack.lastIndex)
		return true
	}

	/** tabs replace everything above the root */
	fun switchTo(route: String) {
		stack.clear()
		stack.add(route)
	}
}
