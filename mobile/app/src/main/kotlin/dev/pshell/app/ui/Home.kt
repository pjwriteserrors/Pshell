package dev.pshell.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import dev.pshell.app.link.bool
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.widgets.PillSlider
import dev.pshell.app.ui.widgets.pressable
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import dev.pshell.app.features.Feature
import dev.pshell.app.features.Features
import dev.pshell.app.link.LinkState
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Tile
import kotlinx.coroutines.launch

/** The features this PC has switched on. */
@Composable
fun enabledFeatures(): List<Feature> {
	val plugins by LocalApp.current.plugins.collectAsState()
	// before the first connection nothing is known: offer what needs no plugin
	return Features.filter { feature -> feature.plugins.all { plugins[it] == true } }
}

@Composable
fun Home() {
	val app = LocalApp.current
	val nav = LocalNav.current
	val state = linkState()
	val pcs by app.link.pcs.list.collectAsState()
	val latency by app.link.latency.collectAsState()
	val wallpaper by app.wallpaper.collectAsState()
	val showWallpaper by app.prefs.wallpaper.flow.collectAsState()
	val themeMode by app.prefs.theme.flow.collectAsState()
	val scroll = rememberScrollState()
	val connected = state as? LinkState.Connected
	val name = connected?.pc?.name ?: pcs.firstOrNull { it.id == app.link.pcs.preferred }?.name ?: pcs.firstOrNull()?.name ?: "pshell"
	val bg = Theme.colors.bg

	Box(Modifier.fillMaxSize()) {
		// the PC's wallpaper behind the header, fading into the background
		if (wallpaper != null && showWallpaper && themeMode == "wallust") {
			Box(Modifier.fillMaxWidth().height(300.dp).graphicsLayer { translationY = -scroll.value * 0.5f; alpha = (1f - scroll.value / 600f).coerceIn(0f, 1f) }) {
				AsyncImage(model = wallpaper, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
				Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to bg.copy(alpha = 0.35f), 0.55f to bg.copy(alpha = 0.7f), 1f to bg)))
			}
		}
		Column(
			Modifier
				.fillMaxSize()
				.padding(WindowInsets.statusBars.asPaddingValues())
				.verticalScroll(scroll)
				.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = BottomSpace),
			verticalArrangement = Arrangement.spacedBy(Theme.Gap.md),
		) {
			Row(Modifier.padding(start = 4.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
				Column(Modifier.weight(1f)) {
					Row(verticalAlignment = Alignment.CenterVertically) {
						Box(Modifier.size(8.dp).clip(CircleShape).background(if (connected != null) Theme.colors.success else Theme.colors.textSubtle))
						Spacer(Modifier.width(8.dp))
						Label(
							when {
								connected == null -> "LOOKING FOR THE PC"
								latency >= 0 -> "CONNECTED · $latency MS"
								else -> "CONNECTED"
							},
							style = Theme.Type.tiny.copy(letterSpacing = 1.2.sp),
							color = Theme.colors.textMuted,
						)
					}
					// with several PCs the name is a switch
					var choosing by remember { mutableStateOf(false) }
					Label(name, Modifier.then(if (pcs.size > 1) Modifier.pressable(shape = RoundedCornerShape(16.dp), pressedScale = 0.97f) { choosing = true } else Modifier), style = Theme.Type.hero.copy(fontSize = 44.sp))
					if (choosing) dev.pshell.app.ui.widgets.Sheet({ choosing = false }, "Which PC?") { close ->
						for (pc in pcs) {
							val up = app.link.of(pc.id)?.connected == true
							dev.pshell.app.ui.widgets.ListRow(pc.name, icon = "monitor", subtitle = if (up) "Connected" else "Not reachable", iconBackground = if (up) Theme.colors.primary else Theme.colors.layer3, iconTint = if (up) Theme.colors.onPrimary else Theme.colors.text, onClick = {
								app.link.pcs.preferred = pc.id
								close()
							}) {
								if (pc.id == app.link.pcs.preferred) Glyph("check", size = 20.dp, color = Theme.colors.primary)
							}
						}
					}
				}
				IconButton("cog", color = Theme.colors.layer2.copy(alpha = 0.8f), onClick = { nav.open("settings") })
			}

			if (connected == null) {
				Panel {
					Row(verticalAlignment = Alignment.CenterVertically) {
						Glyph("lan_disconnect", size = 24.dp, color = Theme.colors.textMuted)
						Spacer(Modifier.width(14.dp))
						Column(Modifier.weight(1f)) {
							Label("Not reachable", style = Theme.Type.title)
							Label("The app keeps looking and connects by itself. What is shown below is from the last time.", style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 3)
						}
					}
					Spacer(Modifier.height(12.dp))
					Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
						SoftButton("Try now", icon = "refresh") { app.link.retryNow() }
						val sleeping = pcs.firstOrNull { it.id == app.link.pcs.preferred } ?: pcs.firstOrNull()
						if (sleeping != null && sleeping.mac.isNotEmpty()) SoftButton("Wake it", icon = "power") {
							app.link.scope.launch {
								app.link.toast(if (app.link.wake(sleeping)) "Wake-up sent to ${sleeping.name}" else "Could not send the wake-up")
								app.link.retryNow()
							}
						}
					}
				}
			}

			val features = enabledFeatures()
			val ids = features.map { it.id }.toSet()
			fun open(id: String) = nav.open("feature/$id")

			// ── the control centre: what is going on, and what is changed most ──
			for (id in listOf("unlock", "media")) features.firstOrNull { it.id == id }?.card?.invoke { open(id) }
			if ("sound" in ids) dev.pshell.app.features.VolumeSlider()
			for (id in listOf("timer", "agents")) features.firstOrNull { it.id == id }?.card?.invoke { open(id) }
			if ("quick" in ids || "session" in ids) Toggles(showQuick = "quick" in ids)
			if ("commands" in ids) Shortcuts { open("commands") }
			for (id in listOf("system", "breaks")) features.firstOrNull { it.id == id }?.card?.invoke { open(id) }

			// ── everything else: tools one goes to, rather than glances at ──
			if (features.isNotEmpty()) {
				SectionLabel("Everything")
				for (row in features.chunked(4)) {
					Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
						for (feature in row) {
							Column(
								Modifier.weight(1f).pressable(shape = RoundedCornerShape(22.dp), pressedScale = 0.92f, haptic = true) { open(feature.id) }.padding(vertical = 8.dp),
								horizontalAlignment = Alignment.CenterHorizontally,
							) {
								Box(Modifier.size(56.dp).clip(RoundedCornerShape(20.dp)).background(Theme.colors.layer1), contentAlignment = Alignment.Center) {
									Glyph(feature.icon, size = 26.dp)
								}
								Spacer(Modifier.height(6.dp))
								Label(feature.title, style = Theme.Type.tiny.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Medium), color = Theme.colors.textMuted, align = androidx.compose.ui.text.style.TextAlign.Center)
								val summary = feature.summary()
								if (summary.isNotEmpty()) Label(summary, style = Theme.Type.tiny, color = Theme.colors.primary, align = androidx.compose.ui.text.style.TextAlign.Center)
							}
						}
						repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
					}
				}
			}
		}
	}
}

/** The quick settings of the PC: lock, silence, keep awake, Bluetooth, and the monitors' brightness. */
@Composable
private fun Toggles(showQuick: Boolean) {
	val link = LocalApp.current.link
	val session = topic("session")
	val quick = if (showQuick) topic("quick") else null
	val tiles = ArrayList<@Composable (Modifier) -> Unit>()
	if (session["canLock"].bool) tiles.add { modifier ->
		Tile("lock", if (session["locked"].bool) "Locked" else "Lock", modifier, subtitle = session["host"].string, active = session["locked"].bool) { link.run("session", "lock") }
	}
	quick["dnd"]?.let { dnd ->
		tiles.add { modifier -> Tile(if (dnd["on"].bool) "bell_off_outline" else "bell_outline", "Silence", modifier, subtitle = if (dnd["on"].bool) dnd["reason"].string.ifEmpty { "On" } else "Off", active = dnd["on"].bool) { link.run("quick", "dnd") } }
	}
	quick["keepAwake"]?.let { awake ->
		tiles.add { modifier -> Tile("coffee_outline", "Keep awake", modifier, subtitle = if (awake["on"].bool) "On" else "Off", active = awake["on"].bool) { link.run("quick", "keepAwake") } }
	}
	quick["bluetooth"]?.let { bluetooth ->
		tiles.add { modifier -> Tile(if (bluetooth["powered"].bool) "bluetooth" else "bluetooth_off", "Bluetooth", modifier, subtitle = bluetooth["summary"].string, active = bluetooth["powered"].bool) { link.run("quick", "bluetooth") } }
	}
	quick["power"]?.let { power ->
		val profiles = power["profiles"].list
		val now = profiles.firstOrNull { it["id"].string == power["current"].string }
		tiles.add { modifier ->
			Tile("speedometer", "Power", modifier, subtitle = now["label"].string, active = power["current"].string == "performance") {
				val next = profiles[(profiles.indexOf(now) + 1).mod(profiles.size.coerceAtLeast(1))]
				link.run("quick", "power", json("profile" to next["id"].string))
			}
		}
	}
	for (pair in tiles.chunked(2)) {
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			for (tile in pair) tile(Modifier.weight(1f))
			if (pair.size == 1) Spacer(Modifier.weight(1f))
		}
	}
	quick["backlight"]?.let { backlight ->
		PillSlider(backlight["value"].float, icon = "brightness_6", label = "${Math.round(backlight["value"].float * 100)}%") { link.run("quick", "backlight", json("value" to it)) }
	}
	for (monitor in quick["monitors"].list) {
		// DDC is slow: the monitor gets the value when the finger lets go
		PillSlider(monitor["value"].float, height = 46.dp, icon = "brightness_6", label = monitor["label"].string, onChangeFinished = {
			link.run("quick", "monitor", json("bus" to monitor["bus"], "value" to it))
		}) {}
	}
}

/** The first commands as a row of buttons: one tap runs one; those that ask first open the grid. */
@Composable
private fun Shortcuts(openAll: () -> Unit) {
	val link = LocalApp.current.link
	val tiles = topic("commands")["tiles"].list
	if (tiles.isEmpty()) return
	Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
		for (tile in tiles.take(12)) {
			val direct = !tile["confirm"].bool && tile["fields"].list.isEmpty() && !tile["output"].bool && !tile["terminal"].bool
			val nav = LocalNav.current
			Row(
				Modifier.height(48.dp).pressable(shape = CircleShape, pressedScale = 0.93f, haptic = true) {
					if (tile["terminal"].bool) nav.open("terminal/run/${tile["id"].string}") else if (direct) link.run("commands", "run", json("id" to tile["id"].string)) else openAll()
				}.background(Theme.colors.layer1).padding(start = 14.dp, end = 18.dp),
				verticalAlignment = Alignment.CenterVertically,
			) {
				Glyph(tile["icon"].string.ifEmpty { "console" }, size = 20.dp, color = Theme.colors.primary)
				Spacer(Modifier.width(8.dp))
				Label(tile["label"].string, style = Theme.Type.label)
			}
		}
	}
}
