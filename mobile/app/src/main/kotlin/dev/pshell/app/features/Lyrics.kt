package dev.pshell.app.features

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.delay

// ── lyrics: the words of what plays on the PC ──────────────────────────────
val LyricsFeature = Feature(
	id = "lyrics",
	title = "Lyrics",
	icon = "music_note",
	group = Group.Media,
	plugins = listOf("lyrics", "media"),
	keywords = listOf("songtext", "text", "words", "karaoke", "singen", "sing"),
	screen = { LyricsScreen() },
)

@Composable
private fun LyricsScreen() {
	val lyrics = topic("lyrics")
	val media = topic("media")
	val link = link
	val lines = lyrics["lines"].list
	val synced = lyrics["synced"].bool
	// which line is sung: the last one whose time has come, from the player's position
	var current by remember { mutableIntStateOf(-1) }
	LaunchedEffect(media, lines) {
		while (true) {
			if (synced && media["playing"].bool || synced && current < 0) {
				val at = mediaPosition(media, link) + 0.2
				var found = -1
				for ((index, line) in lines.withIndex()) if (line["t"].double <= at) found = index else break
				current = found
			}
			delay(250)
		}
	}
	val state = rememberLazyListState()
	LaunchedEffect(current) {
		if (current >= 0 && synced) state.animateScrollToItem((current - 3).coerceAtLeast(0))
	}
	Screen(lyrics["title"].string.ifEmpty { "Lyrics" }, subtitle = lyrics["artist"].string, scroll = false, actions = {
		val playing = media["playing"].bool
		if (media["has"].bool) IconButton(if (playing) "pause" else "play", color = Theme.colors.layer2) { link.run("media", "playPause") }
	}) {
		when {
			lyrics == null || !media["has"].bool -> EmptyState("music_note_off", "Nothing plays on the PC")
			lyrics["state"].string == "loading" || lyrics["state"].string == "" -> EmptyState("music_note", "Looking for the words…", text = lyrics["title"].string)
			lyrics["state"].string == "none" -> EmptyState("music_note_off", "No lyrics for this song", text = "LRCLIB knows none. Instrumental, maybe.")
			lyrics["state"].string == "error" -> EmptyState("alert_circle_outline", "Could not fetch the lyrics")
			lines.isEmpty() -> EmptyState("music_note", "No lines")
			else -> LazyColumn(Modifier.fillMaxSize(), state = state, contentPadding = PaddingValues(top = 8.dp, bottom = BottomSpace + 120.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
				itemsIndexed(lines) { index, line ->
					val text = line["text"].string
					val active = synced && index == current
					val past = synced && index < current
					val color by animateColorAsState(if (active) Theme.colors.text else if (past) Theme.colors.textSubtle else Theme.colors.textMuted, label = "line")
					Box(
						Modifier.fillMaxWidth()
							.then(if (synced && media["canSeek"].bool && line["t"].double >= 0) Modifier.pressable(shape = RoundedCornerShape(14.dp), pressedScale = 0.99f) { link.run("media", "seek", json("position" to line["t"].double)) } else Modifier)
							.padding(horizontal = 8.dp, vertical = if (active) 10.dp else 6.dp),
					) {
						if (text.isBlank()) Row(Modifier.height(if (active) 28.dp else 14.dp), verticalAlignment = Alignment.CenterVertically) { Label("· · ·", style = Theme.Type.small, color = color) }
						else Label(text, style = if (active) Theme.Type.heading.copy(fontWeight = FontWeight.SemiBold, lineHeight = 34.sp) else Theme.Type.title.copy(fontWeight = FontWeight.Normal), color = color, maxLines = 6)
					}
				}
				if (!synced) item {
					Spacer(Modifier.height(8.dp))
					Label("These lyrics carry no times, so they do not follow the song.", Modifier.padding(horizontal = 8.dp), style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 2)
				}
			}
		}
	}
}
