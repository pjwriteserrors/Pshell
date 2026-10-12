package dev.pshell.app.service

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Base64
import android.util.Size
import dev.pshell.app.App
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/**
 * The phone's pictures, videos, downloads and WhatsApp media for the PC's
 * file manager: lists of what is there (newest first), small pictures of
 * them, and the files themselves sent up to a folder the PC chose (it hands
 * a ticket for it; the phone never picks a place on the PC).
 */
object PhoneMedia {
	private lateinit var app: App

	/** what the PC may look into, each a question to MediaStore */
	private data class Collection(val uri: Uri, val where: String?, val args: Array<String>?)

	private fun collection(name: String): Collection {
		val files = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
		val path = MediaStore.MediaColumns.RELATIVE_PATH
		return when (name) {
			"photos" -> Collection(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "$path LIKE ? AND $path NOT LIKE ?", arrayOf("DCIM/%", "%Screenshots%"))
			"camera" -> Collection(files, "$path LIKE ? AND (${MediaStore.Files.FileColumns.MEDIA_TYPE} = ${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE} OR ${MediaStore.Files.FileColumns.MEDIA_TYPE} = ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})", arrayOf("DCIM/Camera%"))
			"pictures" -> Collection(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, null, null)
			"videos" -> Collection(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, null, null)
			"screenshots" -> Collection(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "$path LIKE ?", arrayOf("%Screenshots%"))
			"downloads" -> Collection(MediaStore.Downloads.EXTERNAL_CONTENT_URI, null, null)
			"whatsapp" -> Collection(files, "$path LIKE ? AND ${MediaStore.Files.FileColumns.MEDIA_TYPE} != ${MediaStore.Files.FileColumns.MEDIA_TYPE_NONE}", arrayOf("%WhatsApp/Media/%"))
			"music" -> Collection(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, null, null)
			"documents" -> Collection(files, "${MediaStore.Files.FileColumns.MIME_TYPE} IN (?, ?, ?, ?, ?, ?)", arrayOf("application/pdf", "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.oasis.opendocument.text", "text/plain", "application/epub+zip"))
			else -> throw LinkError("no-collection", "Nothing called $name on the phone")
		}
	}

	fun allowed(context: Context): Boolean {
		fun has(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
		return if (Build.VERSION.SDK_INT >= 33) has(Manifest.permission.READ_MEDIA_IMAGES) && has(Manifest.permission.READ_MEDIA_VIDEO)
		else has(Manifest.permission.READ_EXTERNAL_STORAGE)
	}

	val permissions: Array<String>
		get() = if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_AUDIO)
		else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)

	private fun check() {
		if (!allowed(app)) throw LinkError("permission", "Allow the Pshell app to see photos and videos (on the phone: Files → Let the PC see your photos)")
	}

	fun install(app: App) {
		this.app = app

		// { collection, since (seconds), offset, limit } → { items: [{ id, name, size, modified, mime, folder, width, height }], total }
		app.link.handle("phone.files", "browse") { args ->
			check()
			withContext(Dispatchers.IO) {
				val wanted = collection(args["collection"].string)
				val since = args["since"].long
				val limit = args["limit"].long.takeIf { it > 0 }?.coerceAtMost(2000) ?: 300
				val offset = args["offset"].long.coerceAtLeast(0)
				val columns = arrayOf(
					MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE,
					MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.RELATIVE_PATH,
					MediaStore.MediaColumns.WIDTH, MediaStore.MediaColumns.HEIGHT, MediaStore.MediaColumns.DATE_TAKEN,
				)
				var where = wanted.where
				var whereArgs = wanted.args ?: emptyArray()
				if (since > 0) {
					where = listOfNotNull(where, "${MediaStore.MediaColumns.DATE_ADDED} > ?").joinToString(" AND ")
					whereArgs = whereArgs + since.toString()
				}
				val items = mutableListOf<Map<String, Any?>>()
				var total = 0
				app.contentResolver.query(wanted.uri, columns, where, whereArgs.takeIf { it.isNotEmpty() }, "${MediaStore.MediaColumns.DATE_MODIFIED} DESC")?.use { cursor ->
					total = cursor.count
					if (cursor.moveToPosition(offset.toInt())) {
						do {
							val id = cursor.getLong(0)
							val taken = if (cursor.isNull(8)) 0L else cursor.getLong(8) / 1000
							items += mapOf(
								"id" to "${args["collection"].string}:$id",
								"name" to (cursor.getString(1) ?: "file"),
								"size" to cursor.getLong(2),
								"modified" to (taken.takeIf { it > 0 } ?: cursor.getLong(3)),
								"mime" to (cursor.getString(4) ?: ""),
								"folder" to (cursor.getString(5) ?: "").trimEnd('/'),
								"width" to cursor.getInt(6),
								"height" to cursor.getInt(7),
							)
						} while (items.size < limit && cursor.moveToNext())
					}
				}
				json("items" to items, "total" to total)
			}
		}

		// { ids } → { thumbs: { id: base64 JPEG } }, small pictures of the files (about 256 px)
		app.link.handle("phone.files", "thumbs") { args ->
			check()
			withContext(Dispatchers.IO) {
				val out = mutableMapOf<String, String>()
				for (raw in args["ids"].list.take(60)) {
					val id = raw.string
					val uri = uriOf(id) ?: continue
					runCatching {
						val bitmap = app.contentResolver.loadThumbnail(uri, Size(256, 256), null)
						val bytes = ByteArrayOutputStream()
						bitmap.compress(Bitmap.CompressFormat.JPEG, 78, bytes)
						bitmap.recycle()
						out[id] = Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP)
					}
				}
				json("thumbs" to out)
			}
		}

		// { ids, ticket } → the files go up to the folder the PC's ticket stands for
		app.link.handle("phone.files", "upload") { args ->
			check()
			val ticket = args["ticket"].string
			if (ticket.isEmpty()) throw LinkError("no-ticket", "The PC gave no folder")
			val uris = args["ids"].list.mapNotNull { uriOf(it.string) }
			if (uris.isEmpty()) throw LinkError("no-file", "Those files are gone")
			Transfers.upload(uris, query = "?ticket=${Uri.encode(ticket)}")
			json("accepted" to uris.size)
		}
	}

	private fun uriOf(id: String): Uri? {
		val kind = id.substringBefore(':')
		val number = id.substringAfter(':').toLongOrNull() ?: return null
		val base = when (kind) {
			"photos", "pictures", "screenshots" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
			"videos" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
			"music" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
			"downloads" -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
			else -> MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
		}
		return ContentUris.withAppendedId(base, number)
	}
}
