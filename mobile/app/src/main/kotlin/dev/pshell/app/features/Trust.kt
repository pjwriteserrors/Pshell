package dev.pshell.app.features

import android.content.Context
import android.hardware.biometrics.BiometricPrompt
import android.net.Uri
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.Link
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
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Tile
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import kotlin.coroutines.resume
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.JsonElement

// ── the PC's files ─────────────────────────────────────────────────────────
val PcFilesFeature = Feature(
	id = "pcfiles",
	title = "PC files",
	icon = "folder_network_outline",
	plugins = listOf("phone-fs"),
	screen = { PcFilesScreen() },
)

private fun size(bytes: Long): String = when {
	bytes < 1024 -> "$bytes B"
	bytes < 1024 * 1024 -> "%.0f KB".format(bytes / 1024.0)
	bytes < 1024L * 1024 * 1024 -> "%.1f MB".format(bytes / 1024.0 / 1024.0)
	else -> "%.2f GB".format(bytes / 1024.0 / 1024.0 / 1024.0)
}

private fun fileIcon(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
	"png", "jpg", "jpeg", "webp", "gif", "svg" -> "file_image_outline"
	"mp4", "mkv", "webm", "mov" -> "file_video_outline"
	"mp3", "flac", "ogg", "wav", "m4a" -> "file_music_outline"
	"pdf" -> "file_pdf_box"
	"zip", "tar", "gz", "xz", "7z", "zst" -> "folder_zip_outline"
	"md", "txt", "log" -> "file_document_outline"
	else -> "file_outline"
}

@Composable
private fun PcFilesScreen() {
	val link = link
	val scope = rememberCoroutineScope()
	var path by remember { mutableStateOf("") }
	var listing by remember { mutableStateOf<JsonElement?>(null) }
	var error by remember { mutableStateOf("") }
	var reload by remember { mutableIntStateOf(0) }
	var naming by remember { mutableStateOf(false) }
	val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
		if (uris.isNotEmpty()) Transfers.upload(uris, endpoint = "upload", query = "?dir=${Uri.encode(path)}")
	}
	LaunchedEffect(path, reload) {
		try {
			listing = link.call("fs", "list", json("path" to path))
			error = ""
		} catch (failure: LinkError) {
			error = link.describe(failure)
		}
	}
	val entries = listing["entries"].list
	Screen(path.substringAfterLast('/').ifEmpty { listing["root"].string.ifEmpty { "PC files" } }, subtitle = path, scroll = false, actions = {
		IconButton("folder_plus_outline", color = Theme.colors.layer2) { naming = true }
		Spacer(Modifier.height(0.dp))
		IconButton("upload", color = Theme.colors.layer2) { picker.launch(arrayOf("*/*")) }
	}) {
		if (error.isNotEmpty()) Label(error, color = Theme.colors.danger, maxLines = 3)
		if (path.isNotEmpty()) Chip("Up", icon = "arrow_up") { path = path.substringBeforeLast('/', "") }
		if (entries.isEmpty() && listing != null && error.isEmpty()) EmptyState("folder_open_outline", "Empty")
		LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = BottomSpace)) {
			items(entries, key = { it["name"].string }) { entry ->
				val name = entry["name"].string
				val full = if (path.isEmpty()) name else "$path/$name"
				ListRow(
					name,
					icon = if (entry["dir"].bool) "folder" else fileIcon(name),
					subtitle = if (entry["dir"].bool) "" else size(entry["size"].long),
					iconBackground = if (entry["dir"].bool) Theme.colors.primaryContainer else Theme.colors.layer2,
					iconTint = if (entry["dir"].bool) Theme.colors.primary else Theme.colors.text,
					onClick = {
						if (entry["dir"].bool) path = full
						else scope.launch {
							runCatching { link.call("fs", "get", json("path" to full)) }.onSuccess { Transfers.fetch(it["name"].string, it["url"].string, it["size"].long) }
							link.toast("$name is being fetched into Downloads")
						}
					},
				)
			}
		}
	}
	if (naming) {
		var name by remember { mutableStateOf("") }
		Sheet({ naming = false }, "New folder") { close ->
			Field(name, placeholder = "Name") { name = it }
			PrimaryButton("Create", Modifier.fillMaxWidth(), enabled = name.isNotBlank()) {
				scope.launch {
					runCatching { link.call("fs", "mkdir", json("path" to path, "name" to name.trim())) }
					reload += 1
				}
				close()
			}
		}
	}
}

// ── unlock ─────────────────────────────────────────────────────────────────

/**
 * The key that unlocks the PC: made in the phone's secure hardware, and it
 * signs only right after a fingerprint (or face) was recognised. The PC
 * holds its public half.
 */
object UnlockKey {
	private const val ALIAS = "pshell-unlock"
	private val store: KeyStore get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

	val exists: Boolean get() = store.containsAlias(ALIAS)

	/** Makes the key and returns its public half, as the PC wants it. */
	fun create(): String {
		val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
			.setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
			.setDigests(KeyProperties.DIGEST_SHA256)
			.setUserAuthenticationRequired(true)
			.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
			.setInvalidatedByBiometricEnrollment(true)
			.build()
		val pair = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
		return Base64.encodeToString(pair.public.encoded, Base64.NO_WRAP)
	}

	fun delete() = runCatching { store.deleteEntry(ALIAS) }

	/** Asks for the fingerprint and signs [nonce]; null if the user gave up. */
	suspend fun sign(context: Context, nonce: ByteArray, title: String): ByteArray? = suspendCancellableCoroutine { continuation ->
		val signature = try {
			Signature.getInstance("SHA256withECDSA").apply { initSign(store.getKey(ALIAS, null) as PrivateKey) }
		} catch (error: Exception) {
			// a new fingerprint was enrolled: the key is gone for good, on purpose
			continuation.resume(null)
			return@suspendCancellableCoroutine
		}
		val cancel = CancellationSignal()
		continuation.invokeOnCancellation { cancel.cancel() }
		val prompt = BiometricPrompt.Builder(context)
			.setTitle(title)
			.setNegativeButton("Cancel", context.mainExecutor) { _, _ -> if (continuation.isActive) continuation.resume(null) }
			.build()
		prompt.authenticate(BiometricPrompt.CryptoObject(signature), cancel, context.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
			override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
				val signed = runCatching {
					result.cryptoObject.signature!!.run {
						update(nonce)
						sign()
					}
				}.getOrNull()
				if (continuation.isActive) continuation.resume(signed)
			}

			override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
				if (continuation.isActive) continuation.resume(null)
			}
		})
	}
}

/** Challenge, fingerprint, signature: lifts the PC's lock screen. Returns what to tell the user. */
suspend fun unlockPc(context: Context, link: Link): String = try {
	val nonce = Base64.decode(link.call("unlock", "challenge")["nonce"].string, Base64.DEFAULT)
	val signature = UnlockKey.sign(context, nonce, "Unlock the PC")
	if (signature == null) "Not unlocked"
	else {
		link.call("unlock", "answer", json("signature" to Base64.encodeToString(signature, Base64.NO_WRAP)))
		"Unlocked"
	}
} catch (failure: LinkError) {
	link.describe(failure)
}

val UnlockFeature = Feature(
	id = "unlock",
	title = "Unlock",
	icon = "fingerprint",
	plugins = listOf("phone-unlock", "lock-screen"),
	card = { _ -> UnlockCard() },
	screen = { UnlockScreen() },
)

/** On the home screen while the PC is locked: one tap and a fingerprint. */
@Composable
private fun UnlockCard() {
	val session = topic("session")
	val context = LocalContext.current
	val link = link
	val scope = rememberCoroutineScope()
	if (!session["locked"].bool || !UnlockKey.exists) return
	Panel(color = Theme.colors.primaryContainer, padding = PaddingValues(6.dp)) {
		ListRow("The PC is locked", icon = "fingerprint", subtitle = "Tap to unlock it with your fingerprint", iconBackground = Theme.colors.primary, iconTint = Theme.colors.onPrimary, onClick = {
			scope.launch { link.toast(unlockPc(context, link)) }
		})
	}
}

@Composable
private fun UnlockScreen() {
	val context = LocalContext.current
	val link = link
	val scope = rememberCoroutineScope()
	val session = topic("session")
	var enrolled by remember { mutableStateOf(false) }
	var local by remember { mutableStateOf(true) }
	var message by remember { mutableStateOf("") }
	var tick by remember { mutableIntStateOf(0) }
	LaunchedEffect(tick) {
		runCatching { link.call("unlock", "status") }.onSuccess {
			enrolled = it["enrolled"].bool && UnlockKey.exists
			local = it["local"].bool
		}
	}
	Screen("Unlock", subtitle = "A fingerprint here lifts the PC's lock screen") {
		if (enrolled) {
			Tile("fingerprint", if (session["locked"].bool) "Unlock the PC" else "The PC is not locked", Modifier.fillMaxWidth(), subtitle = if (local) "Asks for your fingerprint" else "Only in the PC's own network", active = session["locked"].bool, enabled = local) {
				scope.launch { message = unlockPc(context, link) }
			}
			SoftButton("Stop unlocking with this phone", icon = "close") {
				scope.launch {
					runCatching { link.call("unlock", "forget") }
					UnlockKey.delete()
					tick += 1
				}
			}
		} else {
			Label("Setting it up makes a key in this phone's secure hardware that works only right after a fingerprint. The PC then asks, on its own screen, whether this phone may unlock it.", color = Theme.colors.textMuted, maxLines = 8)
			PrimaryButton("Set up", Modifier.fillMaxWidth(), icon = "fingerprint") {
				scope.launch {
					message = try {
						UnlockKey.delete()
						val key = UnlockKey.create()
						message = "Confirm it on the PC…"
						link.call("unlock", "enroll", json("key" to key), timeoutSeconds = 95)
						tick += 1
						"Done. Lock the PC to try it."
					} catch (failure: LinkError) {
						UnlockKey.delete()
						link.describe(failure)
					} catch (failure: Exception) {
						"This phone has no fingerprint set up (${failure.message})"
					}
				}
			}
		}
		if (message.isNotEmpty()) Label(message, color = Theme.colors.textMuted, maxLines = 4)
		Label("It unlocks the screen, not the keyring: programs that need your password still ask. It works only in the PC's own network, and a newly added fingerprint on the phone invalidates the key.", style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 6)
	}
}
