package dev.pshell.app.features

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import dev.pshell.app.ui.LocalApp
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Toggle
import dev.pshell.app.zepp.Alarm
import dev.pshell.app.zepp.Catalog
import dev.pshell.app.zepp.Entry
import dev.pshell.app.zepp.WatchLink

// ── the Amazfit watch, straight from the phone ───────────────────────────────
// Zepp OS settings, alarms, faces and find without a PC (the PC's page,
// core/views/settings/AmazfitPage.qml, has the rest). Needs no PC plugin.
val WatchFeature = Feature(
	id = "watch-zepp",
	title = "Watch",
	icon = "watch",
	group = Group.Link,
	keywords = listOf("amazfit", "zepp", "uhr", "smartwatch", "active", "wecker", "alarm", "einstellungen"),
	screen = { WatchScreen() },
	page = { WatchHiddenPage() },
)

/** The names given to hidden settings, "gg/cc" → name. */
@Composable
private fun watchNames(): Map<String, String> {
	val raw by LocalApp.current.prefs.watchNames.flow.collectAsState()
	return remember(raw) { runCatching { org.json.JSONObject(raw).let { o -> o.keys().asSequence().associateWith { o.getString(it) } } }.getOrDefault(emptyMap()) }
}

private fun settingId(catalog: Catalog, group: String, code: Int) = "%02x/%02x".format(catalog.groups[group]?.first ?: 0, code)

private fun isHidden(catalog: Catalog, group: String, code: Int) = catalog.arg(group, code)?.let { it.guess } ?: true

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WatchScreen() {
	val context = LocalContext.current
	val app = LocalApp.current
	val state by WatchLink.flow.collectAsState()
	var allowed by remember { mutableStateOf(context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) }
	val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed = it }
	val address by app.prefs.watchAddress.flow.collectAsState()
	val savedKey by app.prefs.watchKey.flow.collectAsState()
	var key by remember { mutableStateOf(savedKey) }
	val open = state.link !in listOf("idle", "gone", "failed", "wrongkey")
	val nav = dev.pshell.app.ui.LocalNav.current
	val names = watchNames()
	DisposableEffect(Unit) {
		WatchLink.hold()
		onDispose { WatchLink.release() }
	}

	Screen("Watch", subtitle = if (state.name.isNotEmpty()) state.name else "Zepp OS, without the PC") {
		if (!allowed) {
			EmptyState("bluetooth", "Bluetooth is not allowed", text = "The app needs to connect to the watch the phone is paired with.") {
				PrimaryButton("Allow", icon = "bluetooth") { ask.launch(Manifest.permission.BLUETOOTH_CONNECT) }
			}
			return@Screen
		}
		val watches = remember(allowed) { WatchLink.bonded(context) }
		Panel {
			if (watches.isEmpty()) Label("No Amazfit watch is paired with this phone.", color = Theme.colors.textMuted)
			FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
				for (w in watches) Chip(w.name ?: w.address, icon = "watch", active = w.address == address) { app.prefs.watchAddress.value = w.address }
			}
			Spacer(Modifier.height(12.dp))
			Field(key, placeholder = "Auth key (32 hex digits)", icon = "key", onSubmit = { app.prefs.watchKey.value = key.trim() }) { key = it }
			Spacer(Modifier.height(8.dp))
			Label(
				"The key the watch was paired with (Gadgetbridge shows it). Gadgetbridge on this phone shares the watch's connection: while this screen is open its session is replaced, and it authenticates again when it reconnects.",
				style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 6,
			)
			Spacer(Modifier.height(12.dp))
			Row(verticalAlignment = Alignment.CenterVertically) {
				PrimaryButton(if (open) "Disconnect" else "Connect", icon = if (open) "bluetooth_off" else "bluetooth_connect", enabled = address.isNotEmpty()) {
					if (open) WatchLink.close()
					else {
						app.prefs.watchKey.value = key.trim()
						val hex = key.trim().removePrefix("0x")
						val bytes = if (hex.length == 32) runCatching { hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray() }.getOrNull() else null
						WatchLink.open(context, address, bytes)
					}
				}
				Spacer(Modifier.width(12.dp))
				Label(linkText(state.link, state.detail), color = if (state.link == "ready") Theme.colors.primary else Theme.colors.textMuted)
			}
		}
		if (state.link != "ready") return@Screen
		val zepp = WatchLink.zepp ?: return@Screen
		val catalog = WatchLink.catalog(context)

		Panel {
			ListRow(
				"${state.battery ?: "–"} %" + if (state.charging) " · charging" else "",
				icon = "battery",
				subtitle = listOfNotNull(state.info["firmware"]?.let { "Firmware $it" }, state.info["serial"]).joinToString(" · "),
			) {
				IconButton(if (state.finding) "close" else "watch_vibrate") { zepp.find(!state.finding) }
			}
		}

		val hiddenCount = state.config.values.sumOf { g -> g.entries.values.count { isHidden(catalog, g.name, it.code) } }
		Panel {
			ListRow("Hidden settings", icon = "eye_off_outline", subtitle = "$hiddenCount the watch has that nobody named · tell them apart", onClick = { nav.open("feature/watch-zepp/hidden") }) {
				dev.pshell.app.ui.widgets.Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
			}
		}

		SectionLabel("Instead of Gadgetbridge")
		Panel {
			StandIn(app)
		}

		SectionLabel("Alarms")
		Panel {
			for (a in state.alarms) AlarmRow(a, onChange = zepp::setAlarm, onDelete = { zepp.deleteAlarm(a.position) })
			if (state.alarms.size < 10) SoftButton("Add an alarm at 7:00", icon = "plus") {
				val pos = (0..9).first { p -> state.alarms.none { it.position == p } }
				zepp.setAlarm(Alarm(pos, true, false, 7, 0, 0x1f))
			}
		}

		if (state.faces.isNotEmpty()) {
			SectionLabel("Watch faces")
			Panel {
				FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
					for (f in state.faces) Chip(catalog.faces[f] ?: f, icon = if (f == state.face) "check" else "watch", active = f == state.face) { zepp.setFace(f) }
				}
			}
		}

		for (group in state.config.values.sortedBy { it.id }) {
			SectionLabel(catalog.groupLabels[group.name] ?: "Group ${group.name}")
			Panel {
				for (e in group.entries.values.sortedWith(compareBy({ catalog.arg(group.name, it.code) == null }, { it.code }))) {
					SettingLine(catalog, group.name, e, names) { value -> zepp.setSetting(group.name, e.code, value) }
				}
			}
		}
	}
}

private fun linkText(link: String, detail: String) = when (link) {
	"connecting" -> "Connecting …"
	"gatt", "handshake" -> "Authenticating …"
	"ready" -> "Zepp OS link up"
	"nokey" -> "Connected, but no key"
	"wrongkey" -> "The watch refused the key"
	"failed" -> "Failed: $detail"
	"gone" -> "The watch went away"
	else -> ""
}

@Composable
private fun AlarmRow(a: Alarm, onChange: (Alarm) -> Unit, onDelete: () -> Unit) {
	val days = listOf("Mo", "Tu", "We", "Th", "Fr", "Sa", "Su")
	ListRow(
		"%02d:%02d".format(a.hour, a.minute),
		icon = "alarm",
		subtitle = days.filterIndexed { i, _ -> a.repeat and (1 shl i) != 0 }.joinToString(" ").ifEmpty { "Once" } + if (a.smart) " · smart, up to ${a.window} min early" else "",
	) {
		// smart wake: in light sleep up to 10–50 min early; a tap goes on to the next window
		IconButton(if (a.smart) "sleep" else "sleep_off") {
			val windows = listOf(0, 10, 20, 30, 40, 50)
			val next = windows[(windows.indexOf(if (a.smart) a.window else 0) + 1) % windows.size]
			onChange(a.copy(smart = next > 0, window = next))
		}
		IconButton("minus") { onChange(a.copy(minute = (a.minute + 55) % 60, hour = if (a.minute < 5) (a.hour + 23) % 24 else a.hour)) }
		IconButton("plus") { onChange(a.copy(minute = (a.minute + 5) % 60, hour = if (a.minute >= 55) (a.hour + 1) % 24 else a.hour)) }
		Toggle(a.enabled) { onChange(a.copy(enabled = it)) }
		IconButton("delete_outline") { onDelete() }
	}
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SettingLine(catalog: Catalog, group: String, e: Entry, names: Map<String, String>, set: (Any) -> Unit) {
	val arg = catalog.arg(group, e.code)
	val label = names[settingId(catalog, group, e.code)] ?: arg?.let { it.label + if (it.guess) " (likely)" else "" } ?: "Setting 0x%02x (hidden)".format(e.code)
	val range = listOfNotNull(
		if (e.min != null && e.max != null) "${e.min}–${e.max}${arg?.unit?.let { " $it" } ?: ""}" else null,
		arg?.note,
	).joinToString(" · ")
	when (e.type) {
		"bool" -> ListRow(label, subtitle = range.ifEmpty { if (arg == null) "nobody has named it yet" else "" }) { Toggle(e.value == true) { set(it) } }
		"byte" -> {
			val named = arg?.options ?: emptyMap()
			val values = (e.allowed?.map { (it as Number).toInt() }?.takeIf { it.isNotEmpty() } ?: named.keys.toList())
			if (arg?.choices == "languages") {
				ListRow(label, subtitle = catalog.languages.entries.firstOrNull { it.value == e.value }?.key ?: "${e.value}")
				FlowRow(Modifier.padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
					for ((code, id) in catalog.languages) if (e.allowed == null || id in e.allowed) Chip(code.replace('_', '-'), active = id == e.value) { set(id) }
				}
			} else if (values.isNotEmpty()) {
				Label(label, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
				if (values.size <= 4) Segmented(values.map { it to (named[it] ?: "$it") }, selected = (e.value as Number).toInt(), modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp)) { set(it) }
				else FlowRow(Modifier.padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
					for (v in values) Chip(named[v] ?: "$v", active = v == e.value) { set(v) }
				}
			} else NumberLine(label, range, (e.value as Number).toInt(), 0, 255, set)
		}
		"short", "int" -> NumberLine(label, range, (e.value as Number).toInt(), e.min?.toInt() ?: 0, e.max?.toInt() ?: Int.MAX_VALUE, set)
		"hhmm", "string" -> TextLine(label, e.value.toString(), set)
		"strings" -> {
			val allowed = e.allowed?.map { it.toString() } ?: emptyList()
			if (allowed.isEmpty()) TextLine(label, e.value.toString(), set)
			else {
				Label(label, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
				FlowRow(Modifier.padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
					for (v in allowed) Chip(catalog.menu[v]?.replace('_', ' ') ?: v, active = v == e.value) { set(v) }
				}
			}
		}
		"bytes" -> {
			val named = arg?.options ?: emptyMap()
			val now = (e.value as List<*>).map { (it as Number).toInt() }
			Label(label, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
			FlowRow(Modifier.padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
				for (v in e.allowed?.map { (it as Number).toInt() } ?: named.keys.toList()) Chip(named[v] ?: "$v", active = v in now) { set(if (v in now) now - v else now + v) }
			}
		}
		else -> ListRow(label, subtitle = "${e.value}")
	}
}

@Composable
private fun NumberLine(label: String, range: String, value: Int, min: Int, max: Int, set: (Any) -> Unit) {
	val step = if (max - min > 2000) 100 else if (max - min > 200) 10 else 1
	ListRow(label, subtitle = range) {
		IconButton("minus") { set(maxOf(min, value - step)) }
		Label("$value", modifier = Modifier.padding(horizontal = 6.dp))
		IconButton("plus") { set(minOf(max, value + step)) }
	}
}

@Composable
private fun TextLine(label: String, value: String, set: (Any) -> Unit) {
	var text by remember(value) { mutableStateOf(value) }
	Label(label, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
	Field(text, modifier = Modifier.padding(horizontal = 10.dp), onSubmit = { set(text.trim()) }) { text = it }
	Spacer(Modifier.height(6.dp))
}

// ── the hidden settings, and telling them apart ───────────────────────────────
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WatchHiddenPage() {
	val context = LocalContext.current
	val app = LocalApp.current
	val state by WatchLink.flow.collectAsState()
	val names = watchNames()
	DisposableEffect(Unit) {
		WatchLink.hold()
		onDispose { WatchLink.release() }
	}
	val scope = androidx.compose.runtime.rememberCoroutineScope()
	var snapshot by remember { mutableStateOf<Map<String, Any?>?>(null) }
	var changes by remember { mutableStateOf<List<Triple<String, Any?, Any?>>?>(null) }
	var busy by remember { mutableStateOf(false) }

	Screen("Hidden settings", subtitle = "What the watch has that nobody named") {
		val zepp = WatchLink.zepp
		if (state.link != "ready" || zepp == null) {
			EmptyState("watch", "Not connected", text = "Connect on the Watch screen first.")
			return@Screen
		}
		val catalog = WatchLink.catalog(context)
		fun rename(id: String, text: String) {
			val o = org.json.JSONObject(app.prefs.watchNames.value)
			if (text.isBlank()) o.remove(id) else o.put(id, text.trim())
			app.prefs.watchNames.value = o.toString()
		}

		Panel {
			Label("Remember the watch's settings, change one thing in the watch's own menu, then ask what changed: the code that moved is that setting – name it.", style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 6)
			Spacer(Modifier.height(12.dp))
			Row(verticalAlignment = Alignment.CenterVertically) {
				PrimaryButton(if (busy) "Reading …" else "Remember now", icon = "camera_outline", enabled = !busy) {
					busy = true
					changes = null
					zepp.reread()
					scope.launch {
						kotlinx.coroutines.delay(3000)
						snapshot = zepp.values()
						busy = false
					}
				}
				Spacer(Modifier.width(8.dp))
				SoftButton("What changed?", icon = "compare_horizontal") {
					val before = snapshot ?: return@SoftButton
					busy = true
					zepp.reread()
					scope.launch {
						kotlinx.coroutines.delay(3000)
						val now = zepp.values()
						changes = now.filter { before[it.key] != it.value }.map { Triple(it.key, before[it.key], it.value) }
						busy = false
					}
				}
			}
			if (snapshot != null && changes == null && !busy) Label("Now change one setting on the watch …", modifier = Modifier.padding(top = 8.dp), color = Theme.colors.primary)
			val found = changes
			if (found != null) {
				Spacer(Modifier.height(8.dp))
				if (found.isEmpty()) Label("Nothing changed (yet).", color = Theme.colors.textMuted)
				for ((id, old, new) in found) {
					val (g, c) = id.split("/").map { it.toInt(16) }
					val group = catalog.groupName(g)
					val arg = catalog.arg(group, c)
					var text by remember(id) { mutableStateOf(names[id] ?: "") }
					ListRow("${catalog.groupLabels[group] ?: group} · 0x%02x".format(c), icon = "swap_horizontal", subtitle = "$old → $new" + (arg?.let { " · ${it.label}" } ?: ""))
					if (arg == null || arg.guess) Field(text, placeholder = "What is it on the watch?", icon = "pencil", onSubmit = { rename(id, text) }) { text = it }
				}
			}
		}

		for (group in state.config.values.sortedBy { it.id }) {
			val hidden = group.entries.values.filter { isHidden(catalog, group.name, it.code) }.sortedBy { it.code }
			if (hidden.isEmpty()) continue
			SectionLabel(catalog.groupLabels[group.name] ?: "Group ${group.name}")
			Panel {
				for (e in hidden) {
					val id = settingId(catalog, group.name, e.code)
					var text by remember(id) { mutableStateOf(names[id] ?: "") }
					SettingLine(catalog, group.name, e, names) { value -> zepp.setSetting(group.name, e.code, value) }
					Field(text, modifier = Modifier.padding(horizontal = 10.dp), placeholder = "Name 0x%02x".format(e.code), icon = "pencil", onSubmit = { rename(id, text) }) { text = it }
					Spacer(Modifier.height(10.dp))
				}
			}
		}
	}
}

// ── the phone in Gadgetbridge's place ─────────────────────────────────────────
@Composable
private fun StandIn(app: dev.pshell.app.App) {
	val context = LocalContext.current
	val keep by app.prefs.watchKeep.flow.collectAsState()
	val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }
	ListRow("Keep the watch connected", icon = "link_variant", subtitle = "In the background, back by itself when it is near – switch Gadgetbridge off for it") {
		Toggle(keep) { on ->
			app.prefs.watchKeep.value = on
			if (on) {
				ask.launch(arrayOf(Manifest.permission.ANSWER_PHONE_CALLS, Manifest.permission.ACCESS_COARSE_LOCATION))
				dev.pshell.app.service.LinkService.start(context)
			}
		}
	}
	for ((setting, title, sub) in listOf(
		Triple(app.prefs.watchHealth, "Health data", "Fetched every 30 min, kept on the watch, on to the PC"),
		Triple(app.prefs.watchNotify, "Phone notifications on the watch", "Replies and dismissals come back"),
		Triple(app.prefs.watchCalls, "Calls on the watch", "Reject or mute from the wrist"),
		Triple(app.prefs.watchMusic, "Music remote", "The watch's music app steers what plays on the phone"),
		Triple(app.prefs.watchWeather, "Weather", "For the phone's place (open-meteo)"),
		Triple(app.prefs.watchFind, "Find the phone", "The watch can make the phone ring"),
	)) {
		val on by setting.flow.collectAsState()
		ListRow(title, subtitle = sub) { Toggle(on) { setting.value = it } }
	}
	if (!dev.pshell.app.service.PhoneNotificationListener.enabled(context))
		SoftButton("Allow reading notifications (for notifications and music)", icon = "bell_outline") {
			context.startActivity(android.content.Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
		}
}
