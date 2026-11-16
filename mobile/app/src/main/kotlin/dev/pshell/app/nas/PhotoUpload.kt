package dev.pshell.app.nas

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import dev.pshell.app.App
import dev.pshell.app.MainActivity
import dev.pshell.app.link.get
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.service.Channels
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Photo auto upload: the phone's pictures and videos go to
 * `/Phone photos/<yyyy>/<mm>/` on the NAS, straight, without the PC.
 *
 * WorkManager runs it: every hour, and whenever MediaStore's pictures or
 * videos change (a content URI trigger, re-armed after each run), within the
 * constraints of the settings (Wi-Fi only on by default, while charging only
 * off). An upload is resumable (the NAS keeps a started one by path and size),
 * so a run that is stopped goes on where it was next time. What is done is
 * kept by MediaStore id with the size the NAS confirmed; only those may be
 * offered for deletion from the phone (off by default, and Android asks).
 */
object PhotoUpload {
	private const val PERIODIC = "nas-photos"
	private const val TRIGGER = "nas-photos-trigger"
	private const val NOW = "nas-photos-now"
	const val ID_PROGRESS = 40
	const val ID_FREE = 41
	const val CHANNEL = "nas"
	const val TAG_TRIGGER = "nas-trigger"
	const val TAG_NOW = "nas-now"

	data class Status(val running: Boolean = false, val done: Int = 0, val total: Int = 0, val current: String = "", val last: Long = 0, val uploaded: Int = 0, val error: String = "", val waiting: Int = 0)

	val status = MutableStateFlow(Status())

	fun state(context: Context): SharedPreferences = context.getSharedPreferences("nas-photos", Context.MODE_PRIVATE)

	private fun constraints(app: App, trigger: Boolean): Constraints = Constraints.Builder()
		.setRequiredNetworkType(if (app.prefs.nasWifiOnly.value) NetworkType.UNMETERED else NetworkType.CONNECTED)
		.setRequiresCharging(app.prefs.nasChargingOnly.value)
		.apply {
			if (trigger) {
				addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
				addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
				setTriggerContentUpdateDelay(20, TimeUnit.SECONDS)
				setTriggerContentMaxDelay(2, TimeUnit.MINUTES)
			}
		}
		.build()

	/** On or off, with the settings as they are now. */
	fun schedule(app: App) {
		val work = WorkManager.getInstance(app)
		val last = state(app)
		status.value = status.value.copy(last = last.getLong("last", 0), uploaded = last.getInt("uploaded", 0), error = last.getString("error", "").orEmpty())
		if (!app.prefs.nasAutoUpload.value) {
			work.cancelUniqueWork(PERIODIC)
			work.cancelUniqueWork(TRIGGER)
			return
		}
		work.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, PeriodicWorkRequestBuilder<PhotoWorker>(1, TimeUnit.HOURS).setConstraints(constraints(app, false)).build())
		arm(app)
	}

	/** The run that waits for a new picture. */
	fun arm(app: App, after: Boolean = false) {
		val request = OneTimeWorkRequestBuilder<PhotoWorker>().setConstraints(constraints(app, true)).addTag(TAG_TRIGGER).build()
		WorkManager.getInstance(app).enqueueUniqueWork(TRIGGER, if (after) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.REPLACE, request)
	}

	/** "Upload now" in the screen: the network still counts, charging not. */
	fun now(app: App) {
		val constraints = Constraints.Builder().setRequiredNetworkType(if (app.prefs.nasWifiOnly.value) NetworkType.UNMETERED else NetworkType.CONNECTED).build()
		WorkManager.getInstance(app).enqueueUniqueWork(NOW, ExistingWorkPolicy.KEEP, OneTimeWorkRequestBuilder<PhotoWorker>().setConstraints(constraints).addTag(TAG_NOW).build())
	}

	fun permissions(): Array<String> = if (Build.VERSION.SDK_INT >= 33)
		arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.ACCESS_MEDIA_LOCATION, Manifest.permission.POST_NOTIFICATIONS)
	else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.ACCESS_MEDIA_LOCATION)

	fun mayRead(context: Context): Boolean = if (Build.VERSION.SDK_INT >= 33)
		context.checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
	else context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

	/** One picture or video of the phone. */
	data class Item(val uri: Uri, val key: String, val name: String, val size: Long, val taken: Long, val modified: Long)

	fun items(context: Context, since: Long): List<Item> {
		val found = mutableListOf<Item>()
		for ((kind, collection) in listOf("i" to MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "v" to MediaStore.Video.Media.EXTERNAL_CONTENT_URI)) {
			val columns = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_TAKEN, MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.DATE_MODIFIED)
			context.contentResolver.query(collection, columns, "${MediaStore.MediaColumns.DATE_ADDED} >= ? AND ${MediaStore.MediaColumns.IS_PENDING} = 0", arrayOf(since.toString()), "${MediaStore.MediaColumns.DATE_ADDED} ASC")?.use { cursor ->
				while (cursor.moveToNext()) {
					val id = cursor.getLong(0)
					val size = cursor.getLong(2)
					if (size <= 0) continue
					val taken = cursor.getLong(3).takeIf { it > 0 } ?: (cursor.getLong(4) * 1000)
					found += Item(ContentUris.withAppendedId(collection, id), "$kind$id", cursor.getString(1) ?: "$kind$id", size, taken, cursor.getLong(5))
				}
			}
		}
		return found.sortedBy { it.taken }
	}

	fun target(item: Item): String {
		val date = Date(item.taken)
		val year = SimpleDateFormat("yyyy", Locale.ROOT).format(date)
		val month = SimpleDateFormat("MM", Locale.ROOT).format(date)
		return "/Phone photos/$year/$month/${item.name.replace('/', '_')}"
	}

	/** Uploaded ones the NAS confirmed with the same size, still on the phone: what may be freed. */
	fun freeable(context: Context): List<Item> {
		val done = state(context)
		return items(context, 0).filter { item -> done.getString(item.key, null)?.let { record -> record.substringBefore('|').toLongOrNull() == item.size } == true }
	}

	/** The delete request Android shows the user; afterwards the records go. */
	fun deleteRequest(context: Context, items: List<Item>): PendingIntent = MediaStore.createDeleteRequest(context.contentResolver, items.map { it.uri })

	fun forgetDeleted(context: Context, items: List<Item>) {
		val editor = state(context).edit()
		items.forEach { editor.remove(it.key) }
		editor.apply()
	}
}

class PhotoWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
	private val app = context.applicationContext as App

	override suspend fun doWork(): Result {
		if (!app.prefs.nasAutoUpload.value && PhotoUpload.TAG_NOW !in tags) return Result.success()
		try {
			return run()
		} finally {
			// a trigger is used up once it fired: the next picture needs a new one, after this run
			if (PhotoUpload.TAG_TRIGGER in tags && app.prefs.nasAutoUpload.value) PhotoUpload.arm(app, after = true)
		}
	}

	private suspend fun run(): Result {
		if (!PhotoUpload.mayRead(app)) return finish(0, "The app may not read the photos: allow it in the NAS screen")
		if (Nas.account.value == null) return finish(0, "No NAS token yet: connect to the PC once")
		if (Nas.resolve() == null) return finish(0, Nas.problem.value, retry = true)
		val done = PhotoUpload.state(app)
		val since = app.prefs.nasUploadSince.value.toLongOrNull() ?: 0
		val waiting = PhotoUpload.items(app, since).filter { done.getString(it.key, null) == null }
		if (waiting.isEmpty()) return finish(0, "")
		val folders = mutableSetOf<String>()
		var uploaded = 0
		val notifications = app.getSystemService(NotificationManager::class.java)
		for ((index, item) in waiting.withIndex()) {
			if (isStopped) break
			PhotoUpload.status.value = PhotoUpload.status.value.copy(running = true, done = index, total = waiting.size, current = item.name, waiting = waiting.size - index)
			runCatching { setForeground(foreground(index, waiting.size, item.name, 0f)) }
			val target = PhotoUpload.target(item)
			try {
				// already there with the same size (an earlier run, or the old filebrowser upload): nothing to send
				val there = Nas.stat(target)
				val entry = if (there != null && there["size"].long == item.size) there else {
					val folder = target.substringBeforeLast('/')
					if (folder !in folders) {
						ensureFolder(folder)
						folders += folder
					}
					val uri = if (app.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED) MediaStore.setRequireOriginal(item.uri) else item.uri
					var shown = 0L
					Nas.upload({ app.contentResolver.openInputStream(uri) ?: throw IOException("${item.name} is gone") }, item.size, target, item.modified.takeIf { it > 0 }, conflict = "rename") { offset ->
						val now = System.currentTimeMillis()
						if (now - shown > 700) {
							shown = now
							notifications.notify(PhotoUpload.ID_PROGRESS, notification(index, waiting.size, item.name, offset.toFloat() / item.size))
						}
					}
				}
				// done only when the NAS says it has every byte
				if (entry["size"].long == item.size) {
					done.edit().putString(item.key, "${item.size}|${entry["path"].string.ifEmpty { target }}").apply()
					uploaded += 1
				}
			} catch (error: java.io.FileNotFoundException) {
				done.edit().putString(item.key, "gone|").apply() // deleted meanwhile
			} catch (error: IOException) {
				notifications.cancel(PhotoUpload.ID_PROGRESS)
				return finish(uploaded, "${item.name}: ${error.message}", retry = true)
			}
		}
		notifications.cancel(PhotoUpload.ID_PROGRESS)
		if (uploaded > 0 && app.prefs.nasDeleteAfter.value) offerFreeing(uploaded)
		return finish(uploaded, "")
	}

	private suspend fun ensureFolder(folder: String) {
		var walked = ""
		for (part in folder.split('/').filter { it.isNotEmpty() }) {
			walked += "/$part"
			if (Nas.stat(walked) == null) runCatching { Nas.mkdir(walked) }
		}
	}

	private fun finish(uploaded: Int, error: String, retry: Boolean = false): Result {
		val now = System.currentTimeMillis()
		val total = PhotoUpload.state(app).getInt("uploaded", 0) + uploaded
		PhotoUpload.state(app).edit().putLong("last", now).putInt("uploaded", total).putString("error", error).apply()
		PhotoUpload.status.value = PhotoUpload.Status(running = false, last = now, uploaded = total, error = error)
		return if (retry) Result.retry() else Result.success()
	}

	private fun offerFreeing(count: Int) {
		val open = PendingIntent.getActivity(app, PhotoUpload.ID_FREE, Intent(app, MainActivity::class.java).putExtra("route", "feature/nas-photos").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
		val notification = Channels.builder(app, PhotoUpload.CHANNEL)
			.setContentTitle("$count on the NAS")
			.setContentText("They can be removed from the phone – tap to choose")
			.setContentIntent(open).setAutoCancel(true).build()
		app.getSystemService(NotificationManager::class.java).notify(PhotoUpload.ID_FREE, notification)
	}

	private fun notification(index: Int, total: Int, name: String, part: Float) = Channels.builder(app, PhotoUpload.CHANNEL)
		.setContentTitle("Photos to the NAS: ${index + 1} of $total")
		.setContentText(name)
		.setProgress(1000, ((index + part) / total * 1000).toInt(), false)
		.setOngoing(true).setOnlyAlertOnce(true)
		.setContentIntent(PendingIntent.getActivity(app, PhotoUpload.ID_PROGRESS, Intent(app, MainActivity::class.java).putExtra("route", "feature/nas-photos").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
		.build()

	private fun foreground(index: Int, total: Int, name: String, part: Float) =
		ForegroundInfo(PhotoUpload.ID_PROGRESS, notification(index, total, name, part), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)

	override suspend fun getForegroundInfo(): ForegroundInfo = foreground(0, 1, "", 0f)
}
