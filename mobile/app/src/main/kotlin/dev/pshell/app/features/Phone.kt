package dev.pshell.app.features

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.service.ClipboardSync
import dev.pshell.app.service.Handoff
import dev.pshell.app.service.PhoneNotificationListener
import dev.pshell.app.service.Transfers
import dev.pshell.app.ui.LocalApp
import dev.pshell.app.ui.Switch
import dev.pshell.app.ui.link
import dev.pshell.app.ui.pluginOn
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Meter
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Tile
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement

/** Re-read on every return to the screen: the user may have granted something in the system settings. */
@Composable
private fun <T> onResume(read: () -> T): T {
	var tick by remember { mutableIntStateOf(0) }
	LifecycleResumeEffect(Unit) {
		tick += 1
		onPauseOrDispose {}
	}
	return remember(tick) { read() }
}

/** A row that says whether Android lets the app do something, and leads to where it is granted. */
@Composable
private fun Access(title: String, granted: Boolean, explanation: String, icon: String, grant: () -> Unit) {
	Panel(color = if (granted) Theme.colors.layer1 else Theme.colors.primaryContainer, padding = PaddingValues(6.dp)) {
		ListRow(
			title, icon = if (granted) "check" else icon, subtitle = if (granted) "Allowed" else explanation,
			iconBackground = if (granted) Theme.colors.success else Theme.colors.primary,
			iconTint = if (granted) Theme.colors.bg else Theme.colors.onPrimary,
			onClick = if (granted) null else grant,
		) {
			if (!granted) Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
		}
	}
}

// ── notifications ──────────────────────────────────────────────────────────
val NotificationsFeature = Feature(
	id = "notifications",
	group = Group.Link,
	keywords = listOf("benachrichtigungen", "mirror", "alerts"),
	title = "Notifications",
	icon = "bell_outline",
	plugins = listOf("notifications"),
	screen = { NotificationsScreen() },
)

@Composable
private fun NotificationsScreen() {
	val context = LocalContext.current
	val link = link
	val scope = rememberCoroutineScope()
	Screen("Notifications") {
		if (pluginOn("phone-notifications")) {
			SectionLabel("Phone → PC")
			val listening = onResume { PhoneNotificationListener.enabled(context) }
			Access("Read this phone's notifications", listening, "Needed to show them on the PC, with their buttons and replies", "bell_outline") {
				context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
			}
		}
		if (pluginOn("phone-mirror")) {
			val state = topic("notifications")
			SectionLabel("PC → phone")
			Segmented(listOf("away" to "When away", "always" to "Always", "off" to "Never"), state["mode"].string.ifEmpty { "away" }, Modifier.fillMaxWidth()) {
				link.run("notifications", "mode", json("mode" to it))
			}
			Label(
				when (state["mode"].string) {
					"always" -> "Everything that pops up on the PC also shows here."
					"off" -> "Notifications of the PC stay on the PC."
					else -> "What pops up on the PC shows here while it is locked or nobody touched it for a minute." + if (state["away"].bool) " Right now: away." else ""
				},
				style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 4,
			)
			var answer by remember { mutableStateOf("") }
			SoftButton("Ask the PC something", icon = "message_question_outline") {
				scope.launch {
					answer = try {
						val result = link.call("notifications", "ask", json("title" to "Question from the phone", "body" to "Does a question reach the PC?", "choices" to listOf("Yes", "No"), "text" to true), timeoutSeconds = 120)
						"The PC answered: " + (result["choice"].string.ifEmpty { result["text"].string })
					} catch (error: LinkError) {
						link.describe(error)
					}
				}
			}
			if (answer.isNotEmpty()) Label(answer, color = Theme.colors.textMuted, maxLines = 3)
		}
	}
}

// ── clipboard ──────────────────────────────────────────────────────────────
val ClipboardFeature = Feature(
	id = "clipboard",
	group = Group.Link,
	keywords = listOf("zwischenablage", "copy", "paste", "kopieren"),
	title = "Clipboard",
	icon = "content_paste",
	plugins = listOf("phone-clipboard"),
	screen = { ClipboardScreen() },
)

@Composable
private fun ClipboardScreen() {
	val app = LocalApp.current
	val context = LocalContext.current
	val link = link
	val scope = rememberCoroutineScope()
	val clip = topic("clipboard")
	var history by remember { mutableStateOf<List<JsonElement>>(emptyList()) }
	val historyOn = pluginOn("clipboard")
	LaunchedEffect(clip, historyOn) {
		if (historyOn) history = runCatching { link.call("clipboard", "history", json("limit" to 60))["entries"].list }.getOrDefault(emptyList())
	}
	fun copyHere(text: String) = context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("PC", text))

	Screen("Clipboard") {
		PrimaryButton("Send this phone's clipboard", Modifier.fillMaxWidth(), icon = "send") { ClipboardSync.send(context, force = true) }
		Panel(padding = PaddingValues(6.dp)) {
			Switch(app.prefs.clipboardToPhone, "PC → phone", "What is copied on the PC can be pasted here at once", "monitor")
			Switch(app.prefs.clipboardToPc, "Phone → PC", "Sent whenever this app comes to the front; Android lets no app read the clipboard in the background", "cellphone")
		}
		if (clip["text"].string.isNotEmpty()) {
			SectionLabel("On the PC now")
			Panel(onClick = { copyHere(clip["text"].string) }) {
				Label(clip["text"].string, maxLines = 6)
			}
		}
		if (history.isNotEmpty()) {
			SectionLabel("History of the PC")
			Panel(padding = PaddingValues(6.dp)) {
				for (entry in history) {
					val binary = entry["binary"].bool
					ListRow(
						entry["preview"].string.trim().take(120),
						icon = if (binary) "image_outline" else "text",
						subtitle = if (binary) "Tap to make it the PC's clipboard" else "",
						onClick = {
							scope.launch {
								runCatching { link.call("clipboard", "entry", json("id" to entry["id"].string, "restore" to true))["text"].string }
									.onSuccess { if (it.isNotEmpty()) copyHere(it) }
							}
						},
					)
				}
			}
		}
	}
}

// ── files ──────────────────────────────────────────────────────────────────
val FilesFeature = Feature(
	id = "files",
	group = Group.Link,
	keywords = listOf("dateien", "send", "senden", "share", "teilen", "transfer"),
	title = "Files",
	icon = "file_send_outline",
	plugins = listOf("phone-files"),
	screen = { FilesScreen() },
)

private fun bytes(value: Long): String = when {
	value < 0 -> ""
	value < 1024 -> "$value B"
	value < 1024 * 1024 -> "%.0f KB".format(value / 1024.0)
	value < 1024L * 1024 * 1024 -> "%.1f MB".format(value / 1024.0 / 1024.0)
	else -> "%.2f GB".format(value / 1024.0 / 1024.0 / 1024.0)
}

@Composable
private fun FilesScreen() {
	val context = LocalContext.current
	val transfers by Transfers.list.collectAsState()
	val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> if (uris.isNotEmpty()) Transfers.upload(uris) }
	Screen("Files") {
		PrimaryButton("Send files to the PC", Modifier.fillMaxWidth(), icon = "file_send_outline") { picker.launch(arrayOf("*/*")) }
		Label("They land in the PC's downloads folder. From any other app: Share → Send to PC. The PC sends files with >phone in the launcher, or by dropping them on the phone page.", style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 5)
		if (transfers.isEmpty()) EmptyState("swap_vertical", "Nothing sent yet")
		else {
			SectionLabel("Transfers")
			Panel(padding = PaddingValues(6.dp)) {
				for (transfer in transfers) {
					Column {
						ListRow(
							transfer.name,
							icon = if (transfer.toPc) "arrow_up" else "arrow_down",
							subtitle = when (transfer.state) {
								"done" -> listOf(if (transfer.toPc) "Sent" else "Received", bytes(transfer.size)).filter { it.isNotEmpty() }.joinToString(" · ")
								"failed" -> "Failed: ${transfer.error}"
								else -> "${bytes(transfer.done)} of ${bytes(transfer.size)}"
							},
							iconBackground = when (transfer.state) {
								"done" -> Theme.colors.success
								"failed" -> Theme.colors.danger
								else -> Theme.colors.layer3
							},
							iconTint = if (transfer.state == "running") Theme.colors.text else Theme.colors.bg,
							onClick = transfer.uri?.let { uri -> { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)) } } },
						)
						if (transfer.state == "running" && transfer.size > 0) Meter(transfer.done.toFloat() / transfer.size, Modifier.fillMaxWidth())
					}
				}
			}
		}
	}
}

// ── links and hand-off ─────────────────────────────────────────────────────
val HandoffFeature = Feature(
	id = "handoff",
	group = Group.Media,
	keywords = listOf("continue", "weiter", "youtube", "headphones", "kopfhörer", "links"),
	title = "Continue",
	icon = "cellphone_link",
	plugins = listOf("phone-handoff"),
	screen = { HandoffScreen() },
)

@Composable
private fun HandoffScreen() {
	val app = LocalApp.current
	val context = LocalContext.current
	val link = link
	val scope = rememberCoroutineScope()
	val media = if (pluginOn("media")) topic("media") else null
	val chosen by app.prefs.youtubeApp.flow.collectAsState()
	var error by remember { mutableStateOf("") }
	Screen("Continue", subtitle = "Links and videos between the PC and the phone") {
		if (media["canHandoff"].bool) {
			Panel(color = Theme.colors.primaryContainer) {
				Label("ON THE PC", style = Theme.Type.tiny, color = Theme.colors.primary)
				Label(media["title"].string, style = Theme.Type.title, maxLines = 2)
				Spacer(Modifier.height(12.dp))
				PrimaryButton("Continue here", Modifier.fillMaxWidth(), icon = "cellphone_play") {
					scope.launch {
						try {
							val answer = link.call("media", "handoff")
							answer["headset"]["address"].string.takeIf { it.isNotEmpty() }?.let { dev.pshell.app.service.Headset.connect(app, it) }
							Handoff.intent(app, answer["url"].string, answer["position"].long)?.let { context.startActivity(it) }
						} catch (failure: LinkError) {
							error = link.describe(failure)
						}
					}
				}
				if (error.isNotEmpty()) Label(error, color = Theme.colors.danger, maxLines = 2)
			}
		}
		SectionLabel("From the PC")
		val overlay = onResume { Settings.canDrawOverlays(context) }
		var askedBluetooth by remember { mutableIntStateOf(0) }
		val bluetooth = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { askedBluetooth += 1 }
		val headphones = remember(askedBluetooth) { dev.pshell.app.service.Headset.allowed(context) }
		Access("Headphones come along", headphones, "Bluetooth headphones on the PC switch to the phone when the music does", "headphones_bluetooth") {
			bluetooth.launch(Manifest.permission.BLUETOOTH_CONNECT)
		}
		Panel(padding = PaddingValues(6.dp)) {
			Switch(app.prefs.openLinks, "Open links at once", "Otherwise a link of the PC waits in a notification", "open_in_new")
		}
		Access("Open while the app is in the background", overlay, "Android wants \"display over other apps\" for that", "open_in_app") {
			context.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
		}

		SectionLabel("YouTube opens in")
		val players = remember {
			context.packageManager.queryIntentActivities(Intent(Intent.ACTION_VIEW, Uri.parse("https://youtu.be/dQw4w9WgXcQ")), PackageManager.MATCH_ALL)
				.map { it.activityInfo.packageName to it.loadLabel(context.packageManager).toString() }.distinctBy { it.first }
		}
		Panel(padding = PaddingValues(6.dp)) {
			ListRow("Whatever Android picks", icon = "android", onClick = { app.prefs.youtubeApp.value = "" }) {
				if (chosen.isEmpty()) Glyph("check", size = 20.dp, color = Theme.colors.primary)
			}
			for ((name, label) in players) {
				ListRow(label, icon = "youtube", subtitle = name, onClick = { app.prefs.youtubeApp.value = name }) {
					if (chosen == name) Glyph("check", size = 20.dp, color = Theme.colors.primary)
				}
			}
		}
		Label("A video sent from the PC opens there at the second it was at. To send one the other way, share it from the YouTube app to \"Send to PC\".", style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 4)
	}
}

// ── calls, and finding each other ──────────────────────────────────────────
val CallsFeature = Feature(
	id = "calls",
	group = Group.Link,
	keywords = listOf("anrufe", "phone", "telefon", "ring"),
	title = "Calls",
	icon = "phone_outline",
	plugins = listOf("phone-telephony"),
	screen = { CallsScreen() },
)

@Composable
private fun CallsScreen() {
	val context = LocalContext.current
	val wanted = arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS)
	var asked by remember { mutableIntStateOf(0) }
	val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { asked += 1 }
	fun has(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
	val state = remember(asked) { wanted.map(::has) }
	Screen("Calls") {
		Label("While the phone rings or is in a call, the PC pauses what it plays and starts it again afterwards. The PC shows who calls and can silence the ringing.", color = Theme.colors.textMuted, maxLines = 5)
		Access("Know when the phone rings", state[0], "Needed for everything here", "phone_outline") { launcher.launch(wanted) }
		Access("See the number", state[1], "Android keeps it behind the call log permission", "dialpad") { launcher.launch(wanted) }
		Access("Show the contact's name", state[2], "Otherwise the PC shows the number", "account_outline") { launcher.launch(wanted) }
		Label("Text messages come through Notifications: a message shows on the PC and can be answered there.", style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 3)
	}
}

val FindFeature = Feature(
	id = "find",
	group = Group.Link,
	keywords = listOf("finden", "ring", "klingeln", "locate"),
	title = "Find my PC",
	icon = "crosshairs_gps",
	plugins = listOf("phone-find"),
	screen = {
		val link = link
		Screen("Find", subtitle = "Each can make the other speak up") {
			Tile("monitor_shimmer", "Find my PC", Modifier.fillMaxWidth(), subtitle = "It plays a sound and says so on its screens") { link.run("session", "find") }
			Label("The other way: >phone in the PC's launcher, then Ring. The phone rings at full volume, even when silent.", style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 3)
		}
	},
)
