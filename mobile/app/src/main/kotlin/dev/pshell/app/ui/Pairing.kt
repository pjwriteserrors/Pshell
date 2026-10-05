package dev.pshell.app.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import dev.pshell.app.link.LinkError
import dev.pshell.app.service.LinkService
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import kotlinx.coroutines.launch

/** Holds the one pairing in flight, so a code from a link or the scanner lands in the same place. */
class PairingState {
	var busy by mutableStateOf(false)
	var error by mutableStateOf("")
}

/**
 * Pairing: the PC shows a code (QR), the phone scans it. The code names the
 * PC's certificate, so nothing else can answer for it, and carries a secret
 * that works once.
 */
@Composable
fun Pairing(first: Boolean) {
	val app = LocalApp.current
	val nav = LocalNav.current
	val scope = rememberCoroutineScope()
	val pairing = remember { PairingState() }
	var code by remember { mutableStateOf("") }

	fun pair(text: String) {
		if (pairing.busy || text.isBlank()) return
		pairing.busy = true
		pairing.error = ""
		scope.launch {
			try {
				app.link.pair(text)
				LinkService.start(app)
				if (!first) nav.back()
			} catch (error: LinkError) {
				pairing.error = error.message ?: "Pairing failed"
			} catch (error: Exception) {
				pairing.error = "Pairing failed: ${error.message}"
			} finally {
				pairing.busy = false
			}
		}
	}

	val scanner = rememberLauncherForActivityResult(ScanContract()) { result -> result.contents?.let(::pair) }

	Column(
		Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 16.dp),
		horizontalAlignment = Alignment.CenterHorizontally,
	) {
		if (!first) {
			Row(Modifier.fillMaxWidth()) { IconButton("arrow_left", color = Theme.colors.layer2, onClick = { nav.back() }) }
		}
		Spacer(Modifier.height(if (first) 56.dp else 16.dp))
		Box(Modifier.size(132.dp).clip(RoundedCornerShape(44.dp)).background(Theme.colors.primaryContainer), contentAlignment = Alignment.Center) {
			Box(Modifier.size(84.dp).clip(CircleShape).background(Theme.colors.primary), contentAlignment = Alignment.Center) {
				Glyph("cellphone_link", size = 42.dp, color = Theme.colors.onPrimary)
			}
		}
		Spacer(Modifier.height(28.dp))
		Label(if (first) "Pair with your PC" else "Pair another PC", style = Theme.Type.display, align = TextAlign.Center)
		Spacer(Modifier.height(8.dp))
		Label(
			"On the PC, open the launcher and type >phone, then choose Pair. Scan the code it shows.",
			style = Theme.Type.body, color = Theme.colors.textMuted, maxLines = 4, align = TextAlign.Center,
		)
		Spacer(Modifier.height(28.dp))
		PrimaryButton(if (pairing.busy) "Pairing…" else "Scan the code", Modifier.fillMaxWidth(), icon = "qrcode_scan", enabled = !pairing.busy) {
			scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setBeepEnabled(false).setOrientationLocked(false).setPrompt(""))
		}
		if (pairing.error.isNotEmpty()) {
			Spacer(Modifier.height(14.dp))
			Panel(color = Theme.colors.dangerContainer, radius = Theme.Radius.huge) {
				Row(verticalAlignment = Alignment.CenterVertically) {
					Glyph("alert_circle_outline", size = 20.dp, color = Theme.colors.danger)
					Spacer(Modifier.width(10.dp))
					Label(pairing.error, maxLines = 4)
				}
			}
		}
		Spacer(Modifier.height(28.dp))
		Label("OR PASTE THE CODE", style = Theme.Type.tiny, color = Theme.colors.textSubtle)
		Spacer(Modifier.height(10.dp))
		Field(code, placeholder = "pshell://pair?…", icon = "link_variant", onSubmit = { pair(code) }, trailing = {
			if (code.isNotBlank()) IconButton("arrow_right", size = 40.dp, color = Theme.colors.primary, tint = Theme.colors.onPrimary) { pair(code) }
		}) { code = it }
		Spacer(Modifier.height(24.dp))
		Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
			Glyph("shield_lock_outline", size = 20.dp, color = Theme.colors.textSubtle)
			Label(
				"Only this phone and that PC can talk afterwards: each keeps the other's certificate, and the phone's key never leaves its secure hardware.",
				Modifier.weight(1f), style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 5,
			)
		}
	}
}
