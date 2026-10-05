package dev.pshell.app.features

import android.annotation.SuppressLint
import android.graphics.Color as AndroidColor
import android.util.Base64
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.pshell.app.link.Link
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.Chrome
import dev.pshell.app.ui.LocalNav
import dev.pshell.app.ui.connected
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Palette
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString

val TerminalFeature = Feature(
	id = "terminal",
	title = "Terminal",
	icon = "console_line",
	plugins = listOf("phone-terminal"),
	screen = { TerminalScreen(null, null) },
)

private fun hex(color: androidx.compose.ui.graphics.Color) = "#%06X".format(color.toArgb() and 0xFFFFFF)

/**
 * xterm.js's colours as kitty has them on the PC (~/.cache/wal/colors-kitty.conf,
 * which wallust writes from the same palette): the sixteen colours, the
 * background, the foreground, and the foreground as the cursor.
 */
private fun themeJson(palette: Palette, colors: List<androidx.compose.ui.graphics.Color>): String {
	val names = listOf("black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite")
	val ansi = names.mapIndexed { index, name -> "\"$name\": \"${hex(colors.getOrElse(index) { palette.fg })}\"" }
	return """{"background": "${hex(palette.bg)}", "foreground": "${hex(palette.fg)}", "cursor": "${hex(palette.fg)}", "cursorAccent": "${hex(palette.bg)}", "selectionBackground": "${hex(palette.fg)}", "selectionForeground": "${hex(palette.bg)}", ${ansi.joinToString(", ")}}"""
}

/**
 * Your shell on the PC, with everything it loads. The page is xterm.js; the
 * connection is the app's, over the link's pinned TLS. [run] types a command
 * of the grid first, [command] one as it is.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun TerminalScreen(run: String?, command: String?) {
	val link = link
	val nav = LocalNav.current
	val view = LocalView.current
	val connected = connected()
	val palette = Theme.colors
	val theme = dev.pshell.app.ui.topic("theme")
	var web by remember { mutableStateOf<WebView?>(null) }
	var socket by remember { mutableStateOf<WebSocket?>(null) }
	var status by remember { mutableStateOf("Connecting…") }
	var ctrl by remember { mutableStateOf(false) }
	var alt by remember { mutableStateOf(false) }

	fun js(code: String) {
		web?.post { web?.evaluateJavascript(code, null) }
	}

	val bridge = remember {
		object {
			/** what was typed, base64 of its UTF-8 */
			@JavascriptInterface
			fun input(data: String) {
				var bytes = Base64.decode(data, Base64.DEFAULT)
				if (ctrl && bytes.size == 1) {
					bytes = byteArrayOf((bytes[0].toInt() and 0x1f).toByte())
					ctrl = false
				}
				if (alt) {
					bytes = byteArrayOf(0x1b) + bytes
					alt = false
				}
				socket?.send(bytes.toByteString())
			}

			@JavascriptInterface
			fun resize(columns: Int, rows: Int) {
				socket?.send(json("resize" to listOf(columns, rows)).toString())
			}
		}
	}

	fun open() {
		socket?.cancel()
		val query = buildString {
			append("stream/terminal?cols=80&rows=24")
			if (!run.isNullOrEmpty()) append("&run=").append(android.net.Uri.encode(run))
			if (!command.isNullOrEmpty()) append("&cmd=").append(android.net.Uri.encode(command))
		}
		status = "Connecting…"
		socket = link.socket(query, object : WebSocketListener() {
			override fun onOpen(webSocket: WebSocket, response: Response) {
				status = ""
				js("refit(); focus();")
			}

			override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
				js("write('${bytes.base64()}')")
			}

			override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
				status = "The shell ended"
			}

			override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
				status = if (response?.code == 403) "The terminal is switched off on the PC" else "No connection"
			}
		})
		if (socket == null) status = "Not connected"
	}

	LaunchedEffect(theme, palette) {
		js("setTheme('${themeJson(palette, theme["colors"].list.map { Palette.parse(it.string) ?: palette.fg })}')")
	}
	DisposableEffect(Unit) {
		view.keepScreenOn = true
		onDispose {
			view.keepScreenOn = false
			socket?.cancel()
		}
	}
	LaunchedEffect(web, connected) {
		if (web != null && connected && socket == null) open()
	}

	Column(Modifier.fillMaxSize().background(palette.bg).padding(WindowInsets.statusBars.asPaddingValues()).imePadding()) {
		Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 8.dp, top = 6.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
			IconButton("arrow_left", size = 38.dp, iconSize = 20.dp, color = palette.layer2) { nav.back() }
			Spacer(Modifier.width(10.dp))
			Column(Modifier.weight(1f)) {
				Label(run?.let { "Command" } ?: "Terminal", style = Theme.Type.title)
				Label(status.ifEmpty { (link.state.value as? dev.pshell.app.link.LinkState.Connected)?.pc?.name ?: "" }, style = Theme.Type.small, color = palette.textMuted)
			}
			if (status.isNotEmpty() && status != "Connecting…") IconButton("refresh", size = 38.dp, iconSize = 20.dp, color = palette.layer2) {
				js("term.reset()")
				open()
			}
		}
		AndroidView(
			factory = { context ->
				WebView(context).apply {
					layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
					setBackgroundColor(AndroidColor.TRANSPARENT)
					settings.javaScriptEnabled = true
					settings.allowFileAccess = true
					settings.domStorageEnabled = true
					addJavascriptInterface(bridge, "Bridge")
					webViewClient = object : WebViewClient() {
						override fun onPageFinished(view: WebView, url: String) {
							web = view
						}
					}
					loadUrl("file:///android_asset/term/index.html")
				}
			},
			modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 8.dp).clip(RoundedCornerShape(18.dp)),
		)
		// a line typed here goes as one piece: surer than typing into the page, and right for a password
		var line by remember { mutableStateOf("") }
		dev.pshell.app.ui.widgets.Field(line, Modifier.padding(horizontal = 8.dp), placeholder = "Type a line and send it", icon = "keyboard_return", onSubmit = {
			socket?.send((line + "\n").toByteArray().toByteString())
			line = ""
		}, trailing = {
			IconButton("send", size = 36.dp, iconSize = 18.dp, color = palette.primary, tint = palette.onPrimary) {
				socket?.send((line + "\n").toByteArray().toByteString())
				line = ""
			}
		}) { line = it }
		// the keys a phone's keyboard lacks
		Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
			Chip("Esc") { js("send('\\u001b')") }
			Chip("Tab") { js("send('\\t')") }
			Chip("Ctrl", active = ctrl) { ctrl = !ctrl }
			Chip("Alt", active = alt) { alt = !alt }
			Chip("↑") { js("send('\\u001b[A')") }
			Chip("↓") { js("send('\\u001b[B')") }
			Chip("←") { js("send('\\u001b[D')") }
			Chip("→") { js("send('\\u001b[C')") }
			Chip("Home") { js("send('\\u001b[H')") }
			Chip("End") { js("send('\\u001b[F')") }
			Chip("^C") { socket?.send(byteArrayOf(3).toByteString()) }
			Chip("^D") { socket?.send(byteArrayOf(4).toByteString()) }
			Chip("^Z") { socket?.send(byteArrayOf(26).toByteString()) }
			Chip("|") { js("send('|')") }
			Chip("~") { js("send('~')") }
			Chip("⌨") { js("focus()") }
		}
		Spacer(Modifier.height(if (Chrome.expanded) 96.dp else 26.dp))
	}
}
