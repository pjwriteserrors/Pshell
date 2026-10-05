package dev.pshell.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.BuildConfig
import dev.pshell.app.Prefs
import dev.pshell.app.link.Identity
import dev.pshell.app.link.LinkState
import dev.pshell.app.link.Pc
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Confirm
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Toggle

@Composable
fun Switch(setting: Prefs.Setting<Boolean>, title: String, subtitle: String, icon: String) {
	val value by setting.flow.collectAsState()
	ListRow(title, icon = icon, subtitle = subtitle, onClick = { setting.value = !value }) {
		Toggle(value) { setting.value = it }
	}
}

@Composable
fun Settings() {
	val app = LocalApp.current
	val nav = LocalNav.current
	val prefs = app.prefs
	val pcs by app.link.pcs.list.collectAsState()
	val state = linkState()
	val theme by prefs.theme.flow.collectAsState()
	var editing by remember { mutableStateOf<Pc?>(null) }

	Screen("Settings") {
		SectionLabel("Look")
		Segmented(listOf("wallust" to "Wallpaper colours", "default" to "Default"), theme, Modifier.fillMaxWidth()) { prefs.theme.value = it }
		Panel(padding = PaddingValues(6.dp)) {
			Switch(prefs.wallpaper, "Wallpaper on the home screen", "The PC's wallpaper behind the header", "wallpaper")
		}

		SectionLabel("Media")
		Panel(padding = PaddingValues(6.dp)) {
			Switch(prefs.mediaControls, "Player in the notification shade", "Pause and skip what plays on the PC without opening the app", "music")
			Switch(prefs.volumeKeys, "Volume keys set the PC's volume", "While the app is open, and while the PC plays", "volume_high")
		}

		SectionLabel("Connection")
		val context = androidx.compose.ui.platform.LocalContext.current
		var resumed by remember { mutableStateOf(0) }
		androidx.lifecycle.compose.LifecycleResumeEffect(Unit) {
			resumed += 1
			onPauseOrDispose {}
		}
		val unrestricted = remember(resumed) { context.getSystemService(android.os.PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName) }
		val notifying = remember(resumed) { context.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled() }
		Panel(padding = PaddingValues(6.dp)) {
			ListRow(
				"Stay connected in the background",
				icon = if (unrestricted) "check" else "battery_alert",
				subtitle = if (unrestricted) "Android does not put the app to sleep" else "Android may cut the connection to save battery. Tap to allow it to run.",
				iconBackground = if (unrestricted) Theme.colors.success else Theme.colors.warning,
				iconTint = Theme.colors.bg,
				onClick = if (unrestricted) null else ({
					@android.annotation.SuppressLint("BatteryLife")
					val intent = android.content.Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, android.net.Uri.parse("package:${context.packageName}"))
					runCatching { context.startActivity(intent) }
					Unit
				}),
			)
			if (!notifying) ListRow(
				"Notifications are off",
				icon = "bell_off_outline",
				subtitle = "Without them there are no media controls, no questions and no notifications of the PC. Tap to switch them on.",
				iconBackground = Theme.colors.warning,
				iconTint = Theme.colors.bg,
				onClick = {
					runCatching { context.startActivity(android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)) }
				},
			)
		}

		SectionLabel("PCs")
		Panel(padding = PaddingValues(6.dp)) {
			for (pc in pcs) {
				val connected = (state as? LinkState.Connected)?.pc?.id == pc.id
				ListRow(
					pc.name,
					icon = "monitor",
					subtitle = if (connected) "Connected · ${(state as LinkState.Connected).address}" else "Not connected",
					iconBackground = if (connected) Theme.colors.primary else Theme.colors.layer3,
					iconTint = if (connected) Theme.colors.onPrimary else Theme.colors.text,
					onClick = { editing = pc },
				) {
					Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
				}
			}
			ListRow("Pair another PC", icon = "plus", onClick = { nav.open("pairing") })
		}

		SectionLabel("About")
		Panel {
			Label("pshell ${BuildConfig.VERSION_NAME}", style = Theme.Type.title)
			Label("This phone's certificate", style = Theme.Type.small, color = Theme.colors.textMuted)
			Label(Identity.fingerprint(Identity.certificate).chunked(4).take(8).joinToString(" "), style = Theme.Type.small.copy(fontFamily = Theme.mono), color = Theme.colors.textMuted)
		}
	}

	editing?.let { pc -> PcSheet(pc) { editing = null } }
}

/** One paired PC: its addresses, an address of your own (a VPN name), un-pairing. */
@Composable
private fun PcSheet(pc: Pc, onDismiss: () -> Unit) {
	val app = LocalApp.current
	val pcs by app.link.pcs.list.collectAsState()
	val current = pcs.firstOrNull { it.id == pc.id } ?: pc
	var address by remember { mutableStateOf("") }
	var removing by remember { mutableStateOf(false) }
	Sheet(onDismiss, current.name) { close ->
		Label("Certificate ${current.id.chunked(4).take(6).joinToString(" ")}…", style = Theme.Type.small.copy(fontFamily = Theme.mono), color = Theme.colors.textMuted)
		SectionLabel("Addresses")
		Label((listOf(current.last) + current.addresses).filter { it.isNotEmpty() }.distinct().joinToString("  ·  "), style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 4)
		for (manual in current.manual) {
			ListRow(manual, icon = "lan_connect") {
				IconButton("close", size = 36.dp) { app.link.pcs.update(current.id) { it.copy(manual = it.manual - manual) } }
			}
		}
		Field(address, placeholder = "Another address (VPN name, IP)", icon = "plus", onSubmit = {
			if (address.isNotBlank()) {
				app.link.pcs.update(current.id) { it.copy(manual = (it.manual + address.trim()).distinct()) }
				address = ""
				app.link.retryNow()
			}
		}) { address = it }
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
			SoftButton("Prefer this PC", Modifier.weight(1f)) {
				app.link.pcs.preferred = current.id
				app.link.retryNow()
				close()
			}
			PrimaryButton("Un-pair", Modifier.weight(1f), danger = true) { removing = true }
		}
	}
	if (removing) {
		Confirm("Un-pair ${current.name}", "The phone forgets this PC. To connect again, pair again. Remove the phone on the PC as well.", "Un-pair", danger = true, onDismiss = { removing = false }) {
			app.link.unpair(current.id)
			onDismiss()
		}
	}
}
