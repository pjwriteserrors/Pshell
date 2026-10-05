package dev.pshell.app.features

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import dev.pshell.app.link.Link
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.pluginOn
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PillSlider
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonElement

val MediaFeature = Feature(
	id = "media",
	title = "Media",
	icon = "music",
	plugins = listOf("media"),
	tab = 1,
	card = { open -> MediaCard(open) },
	screen = { MediaScreen() },
)

/** Where the track is now: the PC sends a position at a time, the phone counts on. */
fun mediaPosition(media: JsonElement?, link: Link): Double {
	val length = media["length"].double
	val base = media["position"].double
	if (!media["playing"].bool) return base.coerceIn(0.0, length.coerceAtLeast(base))
	val elapsed = (link.pcNow() - media["positionAt"].long) / 1000.0 * media["rate"].double.takeIf { it > 0 }.let { it ?: 1.0 }
	return (base + elapsed).coerceIn(0.0, if (length > 0) length else Double.MAX_VALUE)
}

@Composable
private fun livePosition(media: JsonElement?): Double {
	val link = link
	var position by remember { mutableStateOf(mediaPosition(media, link)) }
	LaunchedEffect(media) {
		while (true) {
			position = mediaPosition(media, link)
			delay(250)
		}
	}
	return position
}

fun clock(seconds: Double): String {
	val total = seconds.toLong().coerceAtLeast(0)
	return if (total >= 3600) "%d:%02d:%02d".format(total / 3600, total % 3600 / 60, total % 60) else "%d:%02d".format(total / 60, total % 60)
}

@Composable
fun Cover(media: JsonElement?, size: Dp?, radius: Dp, modifier: Modifier = Modifier) {
	val art = link.blob(media["art"].string)
	Box(
		modifier
			.then(if (size != null) Modifier.size(size) else Modifier.fillMaxWidth().aspectRatio(1f))
			.clip(RoundedCornerShape(radius))
			.background(Theme.colors.layer2),
		contentAlignment = Alignment.Center,
	) {
		Glyph("music", size = (size ?: 160.dp) * 0.4f, color = Theme.colors.textFaint)
		if (art != null) AsyncImage(model = art, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
	}
}

@Composable
private fun MediaCard(open: () -> Unit) {
	val media = topic("media")
	val link = link
	if (!media["has"].bool) return
	Panel(onClick = open, padding = androidx.compose.foundation.layout.PaddingValues(12.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Cover(media, 64.dp, 18.dp)
			Spacer(Modifier.width(14.dp))
			Column(Modifier.weight(1f)) {
				Label(media["player"].string.uppercase(), style = Theme.Type.tiny.copy(letterSpacing = 1.sp), color = Theme.colors.textSubtle)
				Label(media["title"].string, style = Theme.Type.title)
				if (media["artist"].string.isNotEmpty()) Label(media["artist"].string, style = Theme.Type.small, color = Theme.colors.textMuted)
			}
			IconButton(if (media["playing"].bool) "pause" else "play", size = 52.dp, iconSize = 26.dp, color = Theme.colors.primary, tint = Theme.colors.onPrimary) {
				link.run("media", "playPause")
			}
			Spacer(Modifier.width(4.dp))
			IconButton("skip_next", enabled = media["canNext"].bool) { link.run("media", "next") }
		}
		if (media["length"].double > 0) {
			Spacer(Modifier.height(12.dp))
			val position = livePosition(media)
			Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Theme.colors.layer3)) {
				Box(Modifier.fillMaxWidth((position / media["length"].double).toFloat().coerceIn(0f, 1f)).height(4.dp).clip(CircleShape).background(Theme.colors.primary))
			}
		}
	}
}

/** The track's progress: a line to drag, with the times below. */
@Composable
private fun SeekBar(media: JsonElement?) {
	val link = link
	val length = media["length"].double
	val position = livePosition(media)
	var width by remember { mutableFloatStateOf(1f) }
	var dragging by remember { mutableStateOf(false) }
	var local by remember { mutableFloatStateOf(0f) }
	val live = if (length > 0) (position / length).toFloat() else 0f
	val shown by animateFloatAsState(if (dragging) local else live, if (dragging) spring(stiffness = 10000f) else spring(stiffness = 200f), label = "seek")
	val thickness by animateFloatAsState(if (dragging) 10f else 6f, label = "seekThickness")
	val canSeek = media["canSeek"].bool
	val liveNow by rememberUpdatedState(live)
	val primary = Theme.colors.primary
	val track = Theme.colors.layer3
	Column {
		Canvas(
			Modifier
				.fillMaxWidth()
				.height(28.dp)
				.onSizeChanged { width = it.width.toFloat().coerceAtLeast(1f) }
				.pointerInput(canSeek) {
					if (!canSeek) return@pointerInput
					detectTapGestures { link.run("media", "seek", json("ratio" to (it.x / width).coerceIn(0f, 1f))) }
				}
				.pointerInput(canSeek) {
					if (!canSeek) return@pointerInput
					detectHorizontalDragGestures(
						onDragStart = {
							local = liveNow
							dragging = true
						},
						onDragEnd = {
							link.run("media", "seek", json("ratio" to local))
							dragging = false
						},
						onDragCancel = { dragging = false },
					) { input, amount ->
						input.consume()
						local = (local + amount / width).coerceIn(0f, 1f)
					}
				},
		) {
			val y = size.height / 2
			val stroke = thickness.dp.toPx()
			drawLine(track, Offset(stroke / 2, y), Offset(size.width - stroke / 2, y), stroke, StrokeCap.Round)
			val end = (size.width - stroke) * shown.coerceIn(0f, 1f) + stroke / 2
			drawLine(primary, Offset(stroke / 2, y), Offset(end, y), stroke, StrokeCap.Round)
			drawCircle(primary, (stroke * 0.9f).coerceAtLeast(7.dp.toPx()), Offset(end, y))
		}
		Row(Modifier.fillMaxWidth()) {
			Label(clock(if (dragging) local * length else position), style = Theme.Type.small.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
			Spacer(Modifier.weight(1f))
			Label(clock(length), style = Theme.Type.small.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
		}
	}
}

@Composable
fun VolumeSlider(modifier: Modifier = Modifier) {
	val sound = topic("sound")
	val link = link
	val muted = sound["muted"].bool
	val volume = if (muted) 0f else sound["volume"].float
	val icon = when {
		muted || volume <= 0.001f -> "volume_off"
		volume < 0.34f -> "volume_low"
		volume < 0.67f -> "volume_medium"
		else -> "volume_high"
	}
	PillSlider(volume, modifier, icon = icon, label = "${Math.round(volume * 100)}%") { link.run("sound", "set", json("volume" to it)) }
}

@Composable
private fun MediaScreen() {
	val media = topic("media")
	val link = link
	Screen("Media", subtitle = media["player"].string) {
		if (!media["has"].bool) {
			EmptyState("music", "Nothing playing", text = "A player that runs on the PC shows up here.")
			if (pluginOn("sound")) VolumeSlider()
			return@Screen
		}
		Cover(media, null, 32.dp, Modifier.padding(horizontal = 20.dp, vertical = 4.dp))
		Column(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
			AnimatedContent(media["title"].string, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "title") { title ->
				Label(title, Modifier.fillMaxWidth(), style = Theme.Type.heading, maxLines = 2, align = TextAlign.Center)
			}
			val by = listOf(media["artist"].string, media["album"].string).filter { it.isNotEmpty() }.joinToString(" · ")
			if (by.isNotEmpty()) Label(by, Modifier.fillMaxWidth().padding(top = 2.dp), color = Theme.colors.textMuted, align = TextAlign.Center)
		}
		if (media["length"].double > 0) SeekBar(media)
		Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
			IconButton("skip_previous", size = 60.dp, iconSize = 30.dp, enabled = media["canPrevious"].bool) { link.run("media", "previous") }
			Spacer(Modifier.width(18.dp))
			val playing = media["playing"].bool
			val radius by animateFloatAsState(if (playing) 26f else 42f, spring(dampingRatio = 0.55f, stiffness = 300f), label = "play")
			Box(
				Modifier
					.size(84.dp)
					.pressable(shape = RoundedCornerShape(radius.dp), pressedScale = 0.9f, haptic = true) { link.run("media", "playPause") }
					.background(Theme.colors.primary),
				contentAlignment = Alignment.Center,
			) {
				Glyph(if (playing) "pause" else "play", size = 38.dp, color = Theme.colors.onPrimary)
			}
			Spacer(Modifier.width(18.dp))
			IconButton("skip_next", size = 60.dp, iconSize = 30.dp, enabled = media["canNext"].bool) { link.run("media", "next") }
		}
		if (pluginOn("sound")) VolumeSlider()
		val players = media["players"].list
		if (players.size > 1) {
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (player in players) {
					Chip(player["name"].string, icon = if (player["playing"].bool) "play" else null, active = player["current"].bool) {
						link.run("media", "select", json("player" to player["name"].string))
					}
				}
			}
		}
	}
}

val SoundFeature = Feature(
	id = "sound",
	title = "Sound",
	icon = "volume_high",
	plugins = listOf("sound"),
	screen = { SoundScreen() },
)

@Composable
private fun SoundScreen() {
	val sound = topic("sound")
	val link = link
	Screen("Sound", subtitle = sound["sink"].string) {
		VolumeSlider()
		val mic = if (sound["micMuted"].bool) 0f else sound["mic"].float
		PillSlider(mic, icon = if (sound["micMuted"].bool) "microphone_off" else "microphone", label = "${Math.round(mic * 100)}%") {
			link.run("sound", "setMic", json("volume" to it))
		}
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			Chip(if (sound["muted"].bool) "Muted" else "Mute", icon = "volume_off", active = sound["muted"].bool) { link.run("sound", "mute") }
			Chip(if (sound["micMuted"].bool) "Microphone off" else "Mute microphone", icon = "microphone_off", active = sound["micMuted"].bool) { link.run("sound", "muteMic") }
		}
		val sinks = sound["sinks"].list
		if (sinks.isNotEmpty()) {
			dev.pshell.app.ui.widgets.SectionLabel("Output")
			Panel(padding = androidx.compose.foundation.layout.PaddingValues(6.dp)) {
				for (sink in sinks) {
					dev.pshell.app.ui.widgets.ListRow(
						sink["title"].string,
						icon = if (sink["headphones"].bool) "headphones" else "speaker",
						iconBackground = if (sink["active"].bool) Theme.colors.primary else Theme.colors.layer3,
						iconTint = if (sink["active"].bool) Theme.colors.onPrimary else Theme.colors.text,
						onClick = { link.run("sound", "sink", json("name" to sink["name"].string)) },
					) {
						if (sink["active"].bool) Glyph("check", size = 20.dp, color = Theme.colors.primary)
					}
				}
			}
		}
		val streams = sound["streams"].list
		if (streams.isNotEmpty()) {
			dev.pshell.app.ui.widgets.SectionLabel("Apps")
			for (stream in streams) {
				Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
					Label(listOf(stream["name"].string, stream["title"].string).filter { it.isNotEmpty() }.joinToString(" · "), Modifier.padding(start = 6.dp), style = Theme.Type.small.copy(fontWeight = FontWeight.SemiBold), color = Theme.colors.textMuted)
					val level = if (stream["muted"].bool) 0f else stream["volume"].float
					PillSlider(level, height = 44.dp, icon = if (stream["muted"].bool) "volume_off" else "volume_medium", label = "${Math.round(level * 100)}%", color = Theme.colors.secondary) {
						link.run("sound", "stream", json("id" to stream["id"], "volume" to it, "muted" to false))
					}
				}
			}
		}
	}
}
