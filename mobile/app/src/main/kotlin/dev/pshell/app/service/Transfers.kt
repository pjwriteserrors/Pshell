package dev.pshell.app.service

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import dev.pshell.app.App
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Request
import okhttp3.RequestBody
import okio.BufferedSink
import okio.source

/** Files between the phone and the PC, with what happened to each. */
object Transfers {
	data class Transfer(val name: String, val toPc: Boolean, val size: Long, val done: Long = 0, val state: String = "running", val uri: Uri? = null, val error: String = "")

	val list = MutableStateFlow<List<Transfer>>(emptyList())
	private lateinit var app: App

	fun install(app: App) {
		this.app = app
		app.link.handle("phone.files", "receive") { args ->
			val name = args["name"].string.ifEmpty { "file" }
			val url = app.link.blob(args["url"].string) ?: throw LinkError("bad-url", "Nothing to fetch")
			// answered at once; the download goes on
			app.link.scope.launch { download(name, url, args["size"].long) }
			json("accepted" to true)
		}
	}

	private fun update(name: String, toPc: Boolean, change: (Transfer) -> Transfer) {
		list.value = list.value.map { if (it.name == name && it.toPc == toPc && it.state == "running") change(it) else it }
	}

	private fun mime(name: String) = MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"

	/** Fetches something the PC offers (a screenshot, say) into Downloads. */
	fun fetch(name: String, path: String, size: Long) {
		val url = app.link.blob(path) ?: return
		app.link.scope.launch { download(name, url, size) }
	}

	private suspend fun download(name: String, url: String, size: Long) = withContext(Dispatchers.IO) {
		list.value = listOf(Transfer(name, false, size)) + list.value.take(30)
		val resolver = app.contentResolver
		val target = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
			put(MediaStore.Downloads.DISPLAY_NAME, name)
			put(MediaStore.Downloads.MIME_TYPE, mime(name))
			put(MediaStore.Downloads.IS_PENDING, 1)
		})
		try {
			if (target == null) throw java.io.IOException("No place to save to")
			app.link.http.newCall(Request.Builder().url(url).build()).execute().use { response ->
				if (!response.isSuccessful) throw java.io.IOException("The PC answered ${response.code}")
				resolver.openOutputStream(target)!!.use { out ->
					val input = response.body.byteStream()
					val buffer = ByteArray(128 * 1024)
					var total = 0L
					var last = 0L
					while (true) {
						val read = input.read(buffer)
						if (read < 0) break
						out.write(buffer, 0, read)
						total += read
						if (total - last > 512 * 1024) {
							last = total
							update(name, false) { it.copy(done = total) }
						}
					}
				}
			}
			resolver.update(target, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
			update(name, false) { it.copy(state = "done", done = size, uri = target) }
			val open = PendingIntent.getActivity(app, name.hashCode(), Intent(Intent.ACTION_VIEW).setDataAndType(target, mime(name)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), PendingIntent.FLAG_IMMUTABLE)
			app.getSystemService(NotificationManager::class.java).notify("file", name.hashCode(), Channels.builder(app, Channels.FILES).setContentTitle(name).setContentText("Received from the PC · in Downloads").setContentIntent(open).setAutoCancel(true).build())
		} catch (error: Exception) {
			target?.let { resolver.delete(it, null, null) }
			update(name, false) { it.copy(state = "failed", error = error.message.orEmpty()) }
		}
	}

	fun nameOf(context: Context, uri: Uri): Pair<String, Long> {
		context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
			if (it.moveToFirst()) return (it.getString(0) ?: "file") to (if (it.isNull(1)) -1L else it.getLong(1))
		}
		return (uri.lastPathSegment ?: "file") to -1L
	}

	/**
	 * Sends files of the phone to the PC's downloads folder. Each file is
	 * opened right here: what another app shared may only be read while the
	 * activity that received it lives, and that one closes at once.
	 */
	fun upload(uris: List<Uri>, endpoint: String = "upload", query: String = "") {
		for (uri in uris) {
			val (name, size) = runCatching { nameOf(app, uri) }.getOrDefault((uri.lastPathSegment ?: "file") to -1L)
			val type = runCatching { app.contentResolver.getType(uri) }.getOrNull() ?: mime(name)
			val opened = try {
				app.contentResolver.openFileDescriptor(uri, "r") ?: throw java.io.IOException("Could not be opened")
			} catch (error: Exception) {
				list.value = listOf(Transfer(name, true, size, state = "failed", error = error.message ?: "No access to the file")) + list.value.take(30)
				continue
			}
			send(name, size, type, opened, endpoint, query)
		}
	}

	private fun send(name: String, size: Long, type: String, opened: android.os.ParcelFileDescriptor, endpoint: String, query: String) {
		app.link.scope.launch(Dispatchers.IO) {
			list.value = listOf(Transfer(name, true, size)) + list.value.take(30)
			val body = object : RequestBody() {
				override fun contentType() = type.toMediaTypeOrNull()
				override fun contentLength() = size
				override fun isOneShot() = true
				override fun writeTo(sink: BufferedSink) {
					android.os.ParcelFileDescriptor.AutoCloseInputStream(opened).source().use { source ->
						var total = 0L
						var last = 0L
						while (true) {
							val read = source.read(sink.buffer, 128 * 1024)
							if (read < 0) break
							sink.emitCompleteSegments()
							total += read
							if (total - last > 512 * 1024) {
								last = total
								update(name, true) { it.copy(done = total) }
							}
						}
					}
				}
			}
			try {
				val url = "https://pc.pshell/$endpoint/${Uri.encode(name)}$query"
				app.link.http.newCall(Request.Builder().url(url).put(body).build()).execute().use { response ->
					if (!response.isSuccessful) throw java.io.IOException(if (response.code == 403) "Files are switched off on the PC" else "The PC answered ${response.code}")
				}
				update(name, true) { it.copy(state = "done", done = size) }
			} catch (error: Exception) {
				runCatching { opened.close() }
				update(name, true) { it.copy(state = "failed", error = error.message.orEmpty()) }
			}
		}
	}
}
