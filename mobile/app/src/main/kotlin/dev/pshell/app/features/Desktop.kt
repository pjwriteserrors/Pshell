package dev.pshell.app.features

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.zIndex
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.present
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Icons
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PillSlider
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.Tile
import kotlinx.serialization.json.JsonElement

/** A program's icon as the PC has it, or a glyph where it has none the phone can fetch. */
@Composable
fun AppIcon(path: String, size: Dp = 40.dp, fallback: String = "application_outline") {
	val url = link.blob(path)
	Box(Modifier.size(size).clip(RoundedCornerShape(size / 3.4f)).background(Theme.colors.layer3), contentAlignment = Alignment.Center) {
		if (url == null) Glyph(fallback, size = size * 0.5f, color = Theme.colors.textMuted)
		else AsyncImage(model = url, contentDescription = null, modifier = Modifier.size(size * 0.78f))
	}
}

// ── windows ────────────────────────────────────────────────────────────────
val WindowsFeature = Feature(
	id = "windows",
	group = Group.Remote,
	keywords = listOf("fenster", "workspaces", "overview", "focus"),
	title = "Windows",
	icon = "dock_window",
	plugins = listOf("overview"),
	screen = { WindowsScreen() },
)

/** A rectangle of the map, in pixels of its canvas. */
private class Spot(val x: Float, val y: Float, val w: Float, val h: Float) {
	fun contains(point: Offset) = point.x >= x && point.x <= x + w && point.y >= y && point.y <= y + h
}

/**
 * The desktop as a map, like the shell's overview: the monitors where they
 * stand, below each its workspaces, in each the windows where they sit in
 * the strip. A tap picks a window, a tap on a workspace goes there; a long
 * press lifts a window, to drop it on any workspace of any monitor.
 */
@Composable
private fun WindowsScreen() {
	val state = topic("windows")
	val link = link
	val density = LocalDensity.current
	val outputs = state["outputs"].list
	val workspaces = state["workspaces"].list
	val windows = state["windows"].list
	var selected by remember { mutableStateOf(0L) }
	var dragging by remember { mutableStateOf(0L) }
	var finger by remember { mutableStateOf(Offset.Zero) }
	var available by remember { mutableStateOf(0) }

	Screen("Windows", subtitle = "${windows.size} open · hold a window to move it", actions = {
		IconButton("view_grid_outline", color = Theme.colors.layer2) { link.run("windows", "overview") }
	}) {
		if (outputs.isEmpty()) {
			EmptyState("dock_window", if (state == null) "Waiting for the PC" else "No monitors")
			return@Screen
		}
		Box(Modifier.fillMaxWidth().onSizeChanged { available = it.width })
		if (available == 0) return@Screen

		// monitors side by side as they stand, all of them in view
		val minX = outputs.minOf { it["x"].float }
		val minY = outputs.minOf { it["y"].float }
		val span = outputs.maxOf { it["x"].float + it["width"].float } - minX
		val gap = with(density) { 8.dp.toPx() }
		val label = with(density) { 22.dp.toPx() }
		val scale = (available - gap * (outputs.size - 1)) / span
		val ordered = outputs.sortedBy { it["x"].float }

		val workspaceSpots = HashMap<Long, Spot>()
		val windowSpots = HashMap<Long, Spot>()
		val outputSpots = ArrayList<Pair<String, Spot>>()
		var height = 0f
		ordered.forEachIndexed { index, output ->
			val x = (output["x"].float - minX) * scale + gap * index
			val w = output["width"].float * scale
			val h = output["height"].float * scale
			var y = (output["y"].float - minY) * scale
			outputSpots.add(output["name"].string to Spot(x, y, w, label))
			y += label
			for (workspace in workspaces.filter { it["output"].string == output["name"].string }.sortedBy { it["idx"].int }) {
				workspaceSpots[workspace["id"].long] = Spot(x, y, w, h)
				// the strip: columns left to right, rows top to bottom, shrunk to fit if it is wider than the monitor
				val here = windows.filter { it["workspace"].long == workspace["id"].long }
				val columns = here.filter { !it["floating"].bool }.groupBy { it["column"].int }.toSortedMap()
				val widths = columns.mapValues { column -> column.value.maxOf { it["width"].float }.coerceAtLeast(200f) }
				val total = widths.values.sum().coerceAtLeast(1f)
				val inner = minOf(scale, (w - 2 * gap) / total)
				var cx = x + gap + ((w - 2 * gap) - total * inner) / 2
				for ((number, tiles) in columns) {
					val stack = tiles.sortedBy { it["row"].int }
					val tall = stack.sumOf { it["height"].double.coerceAtLeast(120.0) }.toFloat()
					val vertical = minOf(inner, (h - 2 * gap) / tall)
					var cy = y + gap + ((h - 2 * gap) - tall * vertical) / 2
					for (tile in stack) {
						val th = tile["height"].float.coerceAtLeast(120f) * vertical
						windowSpots[tile["id"].long] = Spot(cx + 2f, cy + 2f, widths[number]!! * inner - 4f, th - 4f)
						cy += th
					}
					cx += widths[number]!! * inner
				}
				here.filter { it["floating"].bool }.forEachIndexed { floatIndex, tile ->
					windowSpots[tile["id"].long] = Spot(x + w * 0.3f + floatIndex * gap, y + h * 0.25f + floatIndex * gap, w * 0.4f, h * 0.5f)
				}
				y += h + gap
			}
			height = maxOf(height, y)
		}
		val width = outputSpots.maxOf { it.second.x + it.second.w }
		fun Float.dp() = with(density) { this@dp.toDp() }

		Box {
			Box(
				Modifier
					.size(width.dp(), height.dp())
					.pointerInput(windowSpots.keys, workspaceSpots.keys) {
						detectTapGestures { point ->
							val window = windowSpots.entries.firstOrNull { it.value.contains(point) }?.key
							val workspace = workspaceSpots.entries.firstOrNull { it.value.contains(point) }?.key
							when {
								window != null && window == selected -> link.run("windows", "focus", json("id" to window))
								window != null -> selected = window
								workspace != null -> {
									selected = 0
									link.run("windows", "workspace", json("workspace" to workspace))
								}
							}
						}
					}
					.pointerInput(windowSpots.keys, workspaceSpots.keys) {
						detectDragGesturesAfterLongPress(
							onDragStart = { point ->
								dragging = windowSpots.entries.firstOrNull { it.value.contains(point) }?.key ?: 0
								finger = point
								if (dragging != 0L) selected = dragging
							},
							onDrag = { change, amount ->
								change.consume()
								finger += amount
							},
							onDragEnd = {
								val target = workspaceSpots.entries.firstOrNull { it.value.contains(finger) }?.key
								val from = windows.firstOrNull { it["id"].long == dragging }?.get("workspace").long
								if (dragging != 0L && target != null && target != from) link.run("windows", "move", json("id" to dragging, "workspace" to target))
								dragging = 0
							},
							onDragCancel = { dragging = 0 },
						)
					},
			) {
				for ((name, spot) in outputSpots) {
					Label(name, Modifier.offset(spot.x.dp(), spot.y.dp()).width(spot.w.dp()).padding(start = 6.dp), style = Theme.Type.tiny, color = Theme.colors.textSubtle)
				}
				for (workspace in workspaces) {
					val spot = workspaceSpots[workspace["id"].long] ?: continue
					val target = dragging != 0L && spot.contains(finger)
					Box(
						Modifier
							.offset(spot.x.dp(), spot.y.dp())
							.size(spot.w.dp(), spot.h.dp())
							.clip(RoundedCornerShape(12.dp))
							.background(if (target) Theme.colors.primarySoft.compositeOver(Theme.colors.layer2) else if (workspace["focused"].bool) Theme.colors.primaryContainer else if (workspace["active"].bool) Theme.colors.layer2 else Theme.colors.layer1)
							.then(if (target) Modifier.border(2.dp, Theme.colors.primary, RoundedCornerShape(12.dp)) else Modifier),
					)
				}
				for (window in windows) {
					val id = window["id"].long
					val spot = windowSpots[id] ?: continue
					val lifted = id == dragging
					val offset = if (lifted) Offset(finger.x - spot.w / 2, finger.y - spot.h / 2) else Offset(spot.x, spot.y)
					Box(
						Modifier
							.offset(offset.x.dp(), offset.y.dp())
							.size(spot.w.dp(), spot.h.dp())
							.zIndex(if (lifted) 2f else 1f)
							.graphicsLayer {
								scaleX = if (lifted) 1.12f else 1f
								scaleY = scaleX
								alpha = if (lifted) 0.92f else 1f
							}
							.clip(RoundedCornerShape(8.dp))
							.background(if (id == selected) Theme.colors.primary.copy(alpha = 0.35f).compositeOver(Theme.colors.layer3) else Theme.colors.layer3)
							.then(if (window["focused"].bool || id == selected) Modifier.border(1.5.dp, Theme.colors.primary, RoundedCornerShape(8.dp)) else Modifier),
						contentAlignment = Alignment.Center,
					) {
						val icon = link.blob(window["icon"].string)
						val side = minOf(spot.w, spot.h).dp() * 0.62f
						if (icon != null) AsyncImage(model = icon, contentDescription = null, modifier = Modifier.size(side.coerceAtMost(40.dp)))
						else Glyph("application_outline", size = side.coerceAtMost(28.dp), color = Theme.colors.textMuted)
					}
				}
			}
		}

		val chosen = windows.firstOrNull { it["id"].long == selected }
		if (chosen != null) {
			Panel(padding = PaddingValues(start = 6.dp, end = 10.dp, top = 6.dp, bottom = 6.dp)) {
				Row(verticalAlignment = Alignment.CenterVertically) {
					Box(Modifier.weight(1f)) {
						ListRow(chosen["title"].string.ifEmpty { chosen["app"].string }, subtitle = chosen["app"].string, onClick = { link.run("windows", "focus", json("id" to selected)) })
					}
					IconButton("target", color = Theme.colors.primary, tint = Theme.colors.onPrimary) { link.run("windows", "focus", json("id" to selected)) }
					Spacer(Modifier.width(8.dp))
					IconButton("close", color = Theme.colors.layer3) {
						link.run("windows", "close", json("id" to selected))
						selected = 0
					}
				}
			}
		} else {
			Label("Tap a window to pick it, tap it again to bring it to the front. Tap a workspace to go there.", style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 3)
		}
	}
}

// ── launcher ───────────────────────────────────────────────────────────────
val AppsFeature = Feature(
	id = "apps",
	group = Group.Remote,
	keywords = listOf("launcher", "programs", "programme", "start", "search", "web"),
	title = "Launcher",
	icon = "apps",
	plugins = listOf("apps"),
	screen = { AppsScreen() },
)

@Composable
private fun AppsScreen() {
	val link = link
	var apps by remember { mutableStateOf<List<JsonElement>?>(null) }
	var search by remember { mutableStateOf("") }
	LaunchedEffect(Unit) { apps = runCatching { link.call("apps", "list")["apps"].list }.getOrDefault(emptyList()) }
	val words = search.trim().lowercase().split(' ').filter { it.isNotEmpty() }
	val matches = apps.orEmpty().filter { app -> words.all { "${app["name"].string} ${app["comment"].string}".lowercase().contains(it) } }
	val web = dev.pshell.app.ui.pluginOn("web-search")
	Screen("Launcher", subtitle = "Starts a program on the PC", scroll = false) {
		Field(search, placeholder = "Search ${apps?.size ?: ""} programs", icon = "magnify", onSubmit = { if (web && search.isNotBlank() && matches.isEmpty()) link.run("search", "search", json("query" to search)) }) { search = it }
		if (web && search.isNotBlank()) Chip("Search the web for “$search” on the PC", icon = "web") { link.run("search", "search", json("query" to search)) }
		LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = BottomSpace), verticalArrangement = Arrangement.spacedBy(2.dp)) {
			items(matches, key = { it["id"].string }) { app ->
				Row(verticalAlignment = Alignment.CenterVertically) {
					AppIcon(app["icon"].string)
					Box(Modifier.weight(1f)) {
						ListRow(app["name"].string, subtitle = app["comment"].string, onClick = { link.run("apps", "launch", json("id" to app["id"].string)) })
					}
				}
			}
		}
	}
}

// ── radial menu ────────────────────────────────────────────────────────────
val RadialFeature = Feature(
	id = "radial",
	group = Group.Remote,
	keywords = listOf("menu", "menü", "pie"),
	title = "Radial menu",
	icon = "chart_donut",
	plugins = listOf("radial-menu"),
	screen = { RadialScreen() },
)

@Composable
private fun RadialScreen() {
	val entries = topic("radial")["entries"].list
	val link = link
	var path by remember { mutableStateOf(listOf<String>()) }
	var level = entries
	val trail = ArrayList<JsonElement>()
	for (id in path) {
		val entry = level.firstOrNull { it["id"].string == id } ?: break
		trail.add(entry)
		level = entry["children"].list
	}
	Screen("Radial menu", subtitle = trail.joinToString(" › ") { it["label"].string }.ifEmpty { "What Mod+X offers on the PC" }) {
		if (trail.isNotEmpty()) Chip("Back", icon = "arrow_left") { path = path.dropLast(1) }
		for (pair in level.chunked(2)) {
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (entry in pair) {
					val group = entry["children"].present
					Tile(
						entry["icon"].string.takeIf { Icons.has(it) } ?: "circle_outline",
						entry["label"].string,
						Modifier.weight(1f),
						subtitle = if (group) "${entry["children"].list.size} more" else "",
						active = entry["active"].bool,
						enabled = entry["enabled"].bool,
					) {
						if (group) path = trail.map { it["id"].string } + entry["id"].string
						else link.run("radial", "run", json("path" to trail.map { it["id"].string } + entry["id"].string))
					}
				}
				if (pair.size == 1) Spacer(Modifier.weight(1f))
			}
		}
	}
}

// ── quick settings ─────────────────────────────────────────────────────────
val QuickFeature = Feature(
	id = "quick",
	group = Group.Pc,
	keywords = listOf("settings", "einstellungen", "dnd", "silence", "bluetooth", "brightness", "helligkeit", "power", "autocorrect"),
	title = "Quick settings",
	icon = "tune_variant",
	plugins = listOf("quick-settings"),
	screen = { QuickScreen() },
)

@Composable
private fun QuickScreen() {
	val quick = topic("quick")
	val link = link
	Screen("Quick settings") {
		val tiles = ArrayList<@Composable (Modifier) -> Unit>()
		quick["dnd"]?.let { dnd ->
			tiles.add { modifier -> Tile(if (dnd["on"].bool) "bell_off_outline" else "bell_outline", "Silence", modifier, subtitle = if (dnd["on"].bool) dnd["reason"].string.ifEmpty { "On" } else "Off", active = dnd["on"].bool) { link.run("quick", "dnd") } }
		}
		quick["keepAwake"]?.let { awake ->
			tiles.add { modifier -> Tile("coffee_outline", "Keep awake", modifier, subtitle = if (awake["on"].bool) "On" else "Off", active = awake["on"].bool) { link.run("quick", "keepAwake") } }
		}
		quick["bluetooth"]?.let { bluetooth ->
			tiles.add { modifier -> Tile(if (bluetooth["powered"].bool) "bluetooth" else "bluetooth_off", "Bluetooth", modifier, subtitle = bluetooth["summary"].string, active = bluetooth["powered"].bool) { link.run("quick", "bluetooth") } }
		}
		quick["network"]?.let { network ->
			tiles.add { modifier -> Tile(network["icon"].string.takeIf { Icons.has(it) } ?: "lan", network["label"].string, modifier, subtitle = network["ip"].string, active = network["online"].bool) {} }
		}
		quick["autocorrect"]?.let { auto ->
			tiles.add { modifier -> Tile("keyboard", "Autocorrect", modifier, subtitle = if (auto["failed"].bool) "Failed to start" else if (auto["on"].bool) (if (auto["active"].bool) "Correcting what is typed" else "On") else "Off", active = auto["on"].bool) { link.run("quick", "autocorrect") } }
		}
		for (pair in tiles.chunked(2)) {
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (tile in pair) tile(Modifier.weight(1f))
				if (pair.size == 1) Spacer(Modifier.weight(1f))
			}
		}

		quick["power"]?.let { power ->
			SectionLabel("Power profile")
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (profile in power["profiles"].list) {
					Chip(profile["label"].string, icon = profile["icon"].string.takeIf { Icons.has(it) }, active = profile["id"].string == power["current"].string) {
						link.run("quick", "power", json("profile" to profile["id"].string))
					}
				}
			}
		}

		if (quick["backlight"].present || quick["monitors"].list.isNotEmpty()) SectionLabel("Brightness")
		quick["backlight"]?.let { backlight ->
			PillSlider(backlight["value"].float, icon = "brightness_6", label = "${Math.round(backlight["value"].float * 100)}%") { link.run("quick", "backlight", json("value" to it)) }
		}
		for (monitor in quick["monitors"].list) {
			Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
				Label(monitor["label"].string, Modifier.padding(start = 6.dp), style = Theme.Type.small, color = Theme.colors.textMuted)
				// DDC is slow: the monitor gets the value when the finger lets go
				PillSlider(monitor["value"].float, icon = "monitor", label = if (monitor["known"].bool) "${Math.round(monitor["value"].float * 100)}%" else "?", onChangeFinished = {
					link.run("quick", "monitor", json("bus" to monitor["bus"], "value" to it))
				}) {}
				val inputs = monitor["inputs"].list
				if (inputs.size > 1) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					for (input in inputs) Chip(input["label"].string, icon = "video_input_hdmi", active = input["code"].string == monitor["input"].string) {
						link.run("quick", "monitor", json("bus" to monitor["bus"], "input" to input["code"].string))
					}
				}
			}
		}

		val devices = quick["bluetooth"]["devices"].list
		if (devices.isNotEmpty()) {
			SectionLabel("Bluetooth devices")
			Panel(padding = PaddingValues(6.dp)) {
				for (device in devices) {
					ListRow(
						device["name"].string,
						icon = device["icon"].string.takeIf { Icons.has(it) } ?: "bluetooth",
						subtitle = listOf(if (device["connected"].bool) "Connected" else "Not connected", device["battery"].string).filter { it.isNotEmpty() }.joinToString(" · "),
						iconBackground = if (device["connected"].bool) Theme.colors.primary else Theme.colors.layer3,
						iconTint = if (device["connected"].bool) Theme.colors.onPrimary else Theme.colors.text,
						onClick = { link.run("quick", "bluetooth", json("address" to device["address"].string)) },
					)
				}
			}
		}
	}
}
