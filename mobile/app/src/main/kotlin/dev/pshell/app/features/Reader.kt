package dev.pshell.app.features

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.LocalApp
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Meter
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.SoftButton
import kotlinx.coroutines.delay

// ── fast reader: a text one word at a time ─────────────────────────────────
val ReaderFeature = Feature(
	id = "reader",
	title = "Reader",
	icon = "eye_outline",
	group = Group.Work,
	plugins = listOf("fast-reader"),
	keywords = listOf("fast", "schnell", "lesen", "read", "rsvp", "speed", "wpm", "words", "artikel", "article"),
	screen = { ReaderScreen() },
)

/** The text that is to be read: pasted here, or marked in another app and sent through "Read fast". */
object Reader {
	var text by mutableStateOf("")
	/** opens the screen on the words at once */
	var start by mutableStateOf(false)

	fun words(text: String): List<String> {
		val words = ArrayList<String>()
		for (token in text.replace("­", "").split(Regex("\\s+"))) {
			if (token.isEmpty()) continue
			// a dash on its own stays with the word before it
			if (words.isNotEmpty() && token.none { it.isLetterOrDigit() }) words[words.lastIndex] += " $token"
			else words.add(token)
		}
		return words
	}

	/** the letter the eye rests on, a little left of the middle, as the PC marks it */
	fun pivot(word: String): Int {
		val letters = word.count { it.isLetterOrDigit() }
		val wanted = when {
			letters <= 1 -> 0
			letters <= 5 -> 1
			letters <= 9 -> 2
			letters <= 13 -> 3
			else -> 4
		}
		var seen = 0
		for ((index, character) in word.withIndex()) {
			if (!character.isLetterOrDigit()) continue
			if (seen == wanted) return index
			seen += 1
		}
		return 0
	}

	/** how long a word stays: longer words and the ones that end a sentence a little longer */
	fun duration(word: String, wpm: Int, punctuation: Boolean): Long {
		val base = 60_000.0 / wpm.coerceAtLeast(60)
		var factor = 1.0 + ((word.length - 6).coerceAtLeast(0) * 0.04)
		if (punctuation) {
			val last = word.trimEnd('"', '\'', ')', ']', '»', '“', '”').lastOrNull()
			if (last != null && last in ".!?…") factor += 1.2
			else if (last != null && last in ",;:–—") factor += 0.5
		}
		return (base * factor).toLong()
	}

	fun endsSentence(word: String): Boolean {
		val last = word.trimEnd('"', '\'', ')', ']', '»', '“', '”').lastOrNull() ?: return false
		return last in ".!?…"
	}
}

@Composable
private fun ReaderScreen() {
	val app = LocalApp.current
	val link = link
	val reader = topic("reader")
	val clipboard = LocalClipboardManager.current
	val view = LocalView.current
	var text by remember { mutableStateOf(Reader.text) }
	var reading by remember { mutableStateOf(Reader.start) }
	LaunchedEffect(Reader.text, Reader.start) {
		if (Reader.text.isNotEmpty()) text = Reader.text
		if (Reader.start) {
			reading = true
			Reader.start = false
		}
	}
	val wpm by app.prefs.readerWpm.flow.collectAsState()
	Screen("Reader", subtitle = "A text one word at a time, here or on the PC") {
		if (reading && text.isNotBlank()) {
			Rsvp(text, wpm, onDone = { reading = false }, onWpm = { app.prefs.readerWpm.value = it })
			return@Screen
		}
		Field(text, placeholder = "Paste a text, or mark one in another app and choose \"Read fast\"", singleLine = false, trailing = {
			if (text.isEmpty()) IconButton("content_paste", size = 36.dp, color = Theme.colors.layer2) { text = clipboard.getText()?.text.orEmpty() }
			else IconButton("close", size = 36.dp, color = Theme.colors.layer2) { text = ""; Reader.text = "" }
		}) { text = it }
		val count = Reader.words(text).size
		if (count > 0) Label("$count words · about ${((count * 60.0 / wpm) / 60).toInt().coerceAtLeast(1)} min at $wpm wpm", Modifier.padding(start = 6.dp), style = Theme.Type.small, color = Theme.colors.textMuted)
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			PrimaryButton("Read here", Modifier.weight(1f), icon = "eye_outline", enabled = count > 0) {
				view.keepScreenOn = true
				reading = true
			}
			SoftButton("On the PC", Modifier.weight(1f).padding(vertical = 4.dp), icon = "monitor", onClick = { if (count > 0) link.run("reader", "read", json("text" to text)) })
		}
		// the reader on the PC, while it is up
		if (reader["shown"].bool) {
			SectionLabel("On the PC")
			Panel {
				Row(verticalAlignment = Alignment.CenterVertically) {
					Column(Modifier.weight(1f)) {
						Label(reader["word"].string.ifEmpty { "…" }, style = Theme.Type.heading)
						Label("${reader["index"].int + 1} of ${reader["count"].int} · ${reader["wpm"].int} wpm", style = Theme.Type.small, color = Theme.colors.textMuted)
					}
					IconButton("skip_previous", color = Theme.colors.layer2) { link.run("reader", "back") }
					IconButton(if (reader["playing"].bool) "pause" else "play", color = Theme.colors.primary, tint = Theme.colors.onPrimary) { link.run("reader", if (reader["playing"].bool) "pause" else "play") }
					IconButton("skip_next", color = Theme.colors.layer2) { link.run("reader", "forward") }
					IconButton("close", color = Theme.colors.layer2) { link.run("reader", "close") }
				}
				Spacer(Modifier.height(10.dp))
				Meter(reader["progress"].string.toFloatOrNull() ?: 0f)
				Spacer(Modifier.height(10.dp))
				Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
					for (speed in reader["speeds"].list) Chip(speed["label"].string, active = speed["wpm"].int == reader["wpm"].int) { link.run("reader", "speed", json("wpm" to speed["wpm"].int)) }
				}
			}
		}
	}
}

/** The words, each on the same spot with the letter the eye rests on marked. */
@Composable
private fun Rsvp(text: String, wpm: Int, onDone: () -> Unit, onWpm: (Int) -> Unit) {
	val words = remember(text) { Reader.words(text) }
	val view = LocalView.current
	var index by remember { mutableIntStateOf(0) }
	var playing by remember { mutableStateOf(true) }
	var counting by remember { mutableIntStateOf(3) }
	var finished by remember { mutableStateOf(false) }
	LaunchedEffect(playing, wpm, index, counting) {
		if (!playing || finished) return@LaunchedEffect
		if (counting > 0) {
			delay(700)
			counting -= 1
			return@LaunchedEffect
		}
		delay(Reader.duration(words[index], wpm, true))
		if (index < words.lastIndex) index += 1
		else {
			finished = true
			playing = false
			view.keepScreenOn = false
		}
	}
	val word = words.getOrNull(index) ?: ""
	val pivot = Reader.pivot(word)
	Panel(padding = PaddingValues(vertical = 36.dp, horizontal = 16.dp)) {
		Box(Modifier.fillMaxWidth().height(80.dp), contentAlignment = Alignment.Center) {
			when {
				counting > 0 -> Label("$counting", style = Theme.Type.hero, color = Theme.colors.textMuted)
				finished -> Label("Done", style = Theme.Type.heading, color = Theme.colors.textMuted)
				else -> Row(verticalAlignment = Alignment.CenterVertically) {
					// the pivot letter sits on the centre: the part before it is right-aligned, the rest left
					Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) { Label(word.substring(0, pivot), style = Theme.Type.hero.copy(fontSize = 40.sp, fontWeight = FontWeight.Medium), maxLines = 1) }
					Label(word.substring(pivot, pivot + 1), style = Theme.Type.hero.copy(fontSize = 40.sp, fontWeight = FontWeight.Bold), color = Theme.colors.primary, maxLines = 1)
					Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) { Label(word.substring(pivot + 1), style = Theme.Type.hero.copy(fontSize = 40.sp, fontWeight = FontWeight.Medium), maxLines = 1) }
				}
			}
		}
		Spacer(Modifier.height(20.dp))
		Meter(if (words.size > 1) index.toFloat() / words.lastIndex else 1f)
		Spacer(Modifier.height(4.dp))
		Label("${index + 1} of ${words.size} · $wpm wpm", style = Theme.Type.tiny, color = Theme.colors.textSubtle, align = TextAlign.Center, modifier = Modifier.fillMaxWidth())
	}
	Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
		IconButton("skip_previous", color = Theme.colors.layer2) {
			var at = (index - 1).coerceAtLeast(0)
			while (at > 0 && !Reader.endsSentence(words[at - 1])) at -= 1
			index = at
			finished = false
		}
		IconButton("restart", color = Theme.colors.layer2) { index = 0; finished = false; counting = 3; playing = true }
		Spacer(Modifier.weight(1f))
		IconButton(if (playing && !finished) "pause" else "play", size = 64.dp, iconSize = 30.dp, color = Theme.colors.primary, tint = Theme.colors.onPrimary) {
			if (finished) { index = 0; finished = false; counting = 3 }
			playing = !playing || finished
			view.keepScreenOn = playing
		}
		Spacer(Modifier.weight(1f))
		IconButton("skip_next", color = Theme.colors.layer2) {
			var at = index + 1
			while (at < words.size && !Reader.endsSentence(words[at - 1])) at += 1
			index = at.coerceAtMost(words.lastIndex)
		}
		IconButton("close", color = Theme.colors.layer2) { view.keepScreenOn = false; onDone() }
	}
	Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
		Chip("−25") { onWpm((wpm - 25).coerceAtLeast(100)) }
		for (speed in listOf(250, 300, 400, 500)) Chip("$speed", active = wpm == speed) { onWpm(speed) }
		Chip("+25") { onWpm((wpm + 25).coerceAtMost(1000)) }
	}
	// the words around the one shown, for a look back
	Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Theme.colors.layer1).padding(12.dp)) {
		Label(words.subList((index - 8).coerceAtLeast(0), (index + 12).coerceAtMost(words.size)).joinToString(" "), style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 3)
	}
}

