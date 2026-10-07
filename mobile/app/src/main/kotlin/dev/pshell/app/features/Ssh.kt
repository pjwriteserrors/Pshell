package dev.pshell.app.features

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.service.Transfers
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement

// ── ssh: saved logins; a session on the PC, or the host's folders ─────────
val SshFeature = Feature(
	id = "ssh",
	title = "SSH",
	icon = "console_network_outline",
	group = Group.Pc,
	plugins = listOf("ssh"),
	keywords = listOf("server", "login", "remote", "files", "dateien", "scp", "upload", "hosts"),
	screen = { SshScreen() },
	page = { id -> SshFilesPage(id) },
)

@Composable
private fun SshScreen() {
	val entries = topic("ssh")["entries"].list
	val link = link
	val nav = dev.pshell.app.ui.LocalNav.current
	var chosen by remember { mutableStateOf<JsonElement?>(null) }
	Screen("SSH", subtitle = "Saved logins of the PC; passwords and keys stay there") {
		if (entries.isEmpty()) EmptyState("console_network_outline", "No saved logins", text = "Add them on the PC, in the SSH panel.")
		else Panel(padding = PaddingValues(6.dp)) {
			for (entry in entries) {
				ListRow(entry["name"].string, icon = "server", subtitle = listOf(entry["user"].string, entry["host"].string).filter { it.isNotEmpty() }.joinToString("@"), onClick = { chosen = entry }) {
					Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
				}
			}
		}
	}
	chosen?.let { entry ->
		Sheet({ chosen = null }, entry["name"].string) { close ->
			Label(listOf(entry["user"].string, entry["host"].string).filter { it.isNotEmpty() }.joinToString("@"), color = Theme.colors.textMuted)
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				SoftButton("Files", Modifier.weight(1f).padding(vertical = 4.dp), icon = "folder_outline") {
					close()
					nav.open("feature/ssh/${Uri.encode(entry["id"].string)}")
				}
				PrimaryButton("Open on the PC", Modifier.weight(1f), icon = "console") {
					link.run("ssh", "connect", json("id" to entry["id"].string))
					close()
				}
			}
		}
	}
}

/**
 * The folders of a host, listed by the PC over SSH. Files of the phone go
 * there in two hops: up to the PC, then over with scp.
 */
@Composable
private fun SshFilesPage(id: String) {
	val link = link
	val scope = rememberCoroutineScope()
	val entry = topic("ssh")["entries"].list.firstOrNull { it["id"].string == id }
	var path by rememberSaveable { mutableStateOf("") }
	var listing by remember { mutableStateOf<JsonElement?>(null) }
	var error by remember { mutableStateOf("") }
	var loading by remember { mutableStateOf(false) }
	var sending by remember { mutableStateOf("") }
	var hidden by rememberSaveable { mutableStateOf(false) }
	var version by remember { mutableStateOf(0) }
	LaunchedEffect(path, version) {
		loading = true
		error = ""
		try {
			listing = link.call("ssh", "browse", json("id" to id, "path" to path), timeoutSeconds = 40)
		} catch (failure: LinkError) {
			error = link.describe(failure)
		}
		loading = false
	}
	val shownPath = listing["path"].string.ifEmpty { path.ifEmpty { "~" } }
	val parent = shownPath.trimEnd('/').substringBeforeLast('/', "")
	BackHandler(enabled = path.isNotEmpty() && shownPath != "/" && !shownPath.endsWith("~")) { path = parent.ifEmpty { "/" } }
	val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
		if (uris.isEmpty()) return@rememberLauncherForActivityResult
		sending = if (uris.size == 1) "Sending 1 file…" else "Sending ${uris.size} files…"
		val paths = ArrayList<String>()
		var left = uris.size
		Transfers.upload(uris) { _, uploaded ->
			synchronized(paths) {
				if (uploaded.isNotEmpty()) paths.add(uploaded)
				left -= 1
				if (left > 0) return@upload
			}
			scope.launch {
				try {
					val answer = link.call("ssh", "send", json("id" to id, "dest" to shownPath, "paths" to paths), timeoutSeconds = 120)
					link.toast(answer["message"].string.ifEmpty { "Copied to ${entry["name"].string}" })
					version += 1
				} catch (failure: LinkError) {
					link.toast(link.describe(failure))
				}
				sending = ""
			}
		}
	}
	Screen(entry["name"].string.ifEmpty { "Files" }, subtitle = shownPath, actions = {
		IconButton(if (hidden) "eye_off_outline" else "eye_outline", color = Theme.colors.layer2) { hidden = !hidden }
		Spacer(Modifier.width(6.dp))
		IconButton("upload", color = Theme.colors.primary, tint = Theme.colors.onPrimary, enabled = sending.isEmpty()) { picker.launch(arrayOf("*/*")) }
	}) {
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
			Chip("Home", icon = "home_outline", active = path.isEmpty()) { path = "" }
			Chip("/", active = shownPath == "/") { path = "/" }
			if (parent.isNotEmpty() && shownPath != "/") Chip("Up", icon = "arrow_up") { path = parent.ifEmpty { "/" } }
		}
		if (sending.isNotEmpty()) Label(sending, Modifier.padding(start = 6.dp), style = Theme.Type.small, color = Theme.colors.primary)
		when {
			error.isNotEmpty() -> EmptyState("alert_circle_outline", "Could not list the folder", text = error, action = { SoftButton("Try again", icon = "refresh") { version += 1 } })
			listing == null -> EmptyState("folder_outline", if (loading) "Asking the host…" else "Nothing here")
			else -> {
				val entries = listing["entries"].list.filter { hidden || !it["name"].string.startsWith(".") }
				val folders = entries.filter { it["dir"].bool }
				val files = entries.filter { !it["dir"].bool }
				if (entries.isEmpty()) EmptyState("folder_open_outline", "Empty folder")
				if (folders.isNotEmpty()) {
					SectionLabel("Folders")
					Panel(padding = PaddingValues(6.dp)) {
						for (folder in folders) ListRow(folder["name"].string, icon = "folder", onClick = { path = "${shownPath.trimEnd('/')}/${folder["name"].string}" }) {
							Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
						}
					}
				}
				if (files.isNotEmpty()) {
					SectionLabel("Files")
					Panel(padding = PaddingValues(6.dp)) {
						for (file in files) ListRow(file["name"].string, icon = "file_outline", subtitle = if (file["size"].long > 0) bytesSaid(file["size"].long) else "")
					}
				}
			}
		}
	}
}
