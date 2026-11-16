package dev.pshell.app.nas

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.LinkProperties
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import coil3.ImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import dev.pshell.app.App
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/** What the NAS answered instead of what was asked: its `{error, code}` and the status. */
class NasError(val status: Int, val code: String, message: String) : IOException(message.ifEmpty { code.ifEmpty { "HTTP $status" } })

/**
 * pshell-nas from the phone (docs/nas.md, "Phone"). The token comes from the
 * PC through the phone daemon (`nas.token`, scripts/phone/pshell_phone/features/nas.py)
 * and is kept here, so the phone talks to the NAS on its own afterwards, with
 * or without a PC.
 *
 * Every request goes to http://nas.pshell/…; the client puts the address that
 * answers in its place and the token in front. That address is the home one
 * while a network of the phone has its default gateway in the home net and the
 * server there is the paired one (`/api/hello` server_id; another Fritzbox has
 * the same addresses), else the VPN's. It is looked for again whenever the
 * networks change, and when a connection to it fails.
 */
object Nas {
	const val HOST = "nas.pshell"
	private const val CHUNK = 4 * 1024 * 1024

	data class Account(val serverId: String, val home: String, val vpn: String, val device: String, val token: String, val name: String)

	private lateinit var context: Context
	private lateinit var store: SharedPreferences
	val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

	val account = MutableStateFlow<Account?>(null)
	/** the address that answers now; null while unknown or unreachable */
	val base = MutableStateFlow<String?>(null)
	/** "home", "vpn" or "" */
	val via = MutableStateFlow("")
	/** why the NAS cannot be reached, for the screen */
	val problem = MutableStateFlow("")
	/** raised by anything that changes files, so open lists read again */
	val changed = MutableStateFlow(0)

	private val resolving = Mutex()
	private var lastFresh = 0L
	private var recheck: Job? = null

	fun install(app: App) {
		context = app
		store = app.getSharedPreferences("nas", Context.MODE_PRIVATE)
		account.value = load()
		Pins.load(app)
		app.getSystemService(android.app.NotificationManager::class.java).createNotificationChannel(
			android.app.NotificationChannel(PhotoUpload.CHANNEL, "NAS", android.app.NotificationManager.IMPORTANCE_LOW).apply { description = "Photos going to the NAS" },
		)
		// the PC hands the token over when the phone connects (and when asked)
		scope.launch {
			app.link.events.collect { event ->
				if (event.topic == "nas" && event.name == "token") take(event.data)
			}
		}
		scope.launch {
			app.link.connects.collect { id ->
				if (account.value == null) ask(id, fresh = false)
			}
		}
		val connectivity = app.getSystemService(ConnectivityManager::class.java)
		connectivity.registerNetworkCallback(
			android.net.NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(),
			object : ConnectivityManager.NetworkCallback() {
				override fun onAvailable(network: Network) = networksChanged()
				override fun onLost(network: Network) = networksChanged()
				override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = networksChanged()
			},
		)
		PhotoUpload.schedule(app)
	}

	// ── the token ──────────────────────────────────────────────────────────
	private fun load(): Account? {
		val token = store.getString("token", "").orEmpty()
		if (token.isEmpty()) return null
		return Account(
			store.getString("server_id", "").orEmpty(), store.getString("home", "").orEmpty(), store.getString("vpn", "").orEmpty(),
			store.getString("device", "").orEmpty(), token, store.getString("name", "").orEmpty(),
		)
	}

	private fun take(data: JsonElement?) {
		val token = data["token"].string
		if (token.isEmpty()) return
		val next = Account(
			data["server_id"].string, data["addresses"]["home"].string.trimEnd('/'), data["addresses"]["vpn"].string.trimEnd('/'),
			data["device"].string, token, data["name"].string,
		)
		if (next == account.value) return
		store.edit().putString("token", next.token).putString("server_id", next.serverId).putString("home", next.home)
			.putString("vpn", next.vpn).putString("device", next.device).putString("name", next.name).apply()
		val sameServer = account.value?.serverId == next.serverId
		account.value = next
		if (!sameServer) base.value = null
		changed.value += 1
	}

	/** Asks a PC (the one in front without an id) for the token; fresh: the NAS refused the one kept. */
	suspend fun ask(pcId: String? = null, fresh: Boolean = false): Boolean {
		val app = App.instance
		return try {
			val link = app.link.of(pcId) ?: return false
			take(link.call("nas", "token", json("fresh" to fresh), timeoutSeconds = 40))
			true
		} catch (error: LinkError) {
			if (fresh || account.value == null) problem.value = "No token from the PC: ${app.link.describe(error)}"
			false
		}
	}

	/** The NAS said 401: one fresh token per ten minutes at most. */
	private fun refused() {
		val now = System.currentTimeMillis()
		if (now - lastFresh < 10 * 60_000) return
		lastFresh = now
		scope.launch { ask(fresh = true) }
	}

	fun forget() {
		store.edit().clear().apply()
		account.value = null
		base.value = null
	}

	// ── where it is ────────────────────────────────────────────────────────
	private fun networksChanged() {
		recheck?.cancel()
		recheck = scope.launch {
			delay(1200) // a switch between networks comes as several callbacks
			base.value = null
			if (account.value != null) resolve()
		}
	}

	/** Whether a network of the phone (not a VPN) has its default gateway in the home net. */
	fun atHome(): Boolean {
		val home = account.value?.home ?: return false
		val net = runCatching { home.toHttpUrl().host }.getOrNull()?.substringBeforeLast('.')?.plus('.') ?: return false
		val connectivity = context.getSystemService(ConnectivityManager::class.java)
		@Suppress("DEPRECATION")
		return connectivity.allNetworks.any { network ->
			val capabilities = connectivity.getNetworkCapabilities(network) ?: return@any false
			if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@any false
			val properties = connectivity.getLinkProperties(network) ?: return@any false
			properties.routes.any { it.isDefaultRoute && it.gateway?.hostAddress?.startsWith(net) == true }
		}
	}

	private val probe = OkHttpClient.Builder().connectTimeout(2500, TimeUnit.MILLISECONDS).readTimeout(3, TimeUnit.SECONDS).callTimeout(4, TimeUnit.SECONDS).build()

	/** The address that answers as the paired server, tried in the order the network suggests. */
	suspend fun resolve(): String? = resolving.withLock {
		base.value?.let { return@withLock it }
		val account = account.value ?: run { problem.value = "No token yet: it comes from the PC"; return@withLock null }
		val home = atHome()
		val order = (if (home) listOf("home" to account.home, "vpn" to account.vpn) else listOf("vpn" to account.vpn, "home" to account.home)).filter { it.second.isNotEmpty() }
		val reasons = mutableListOf<String>()
		for ((name, address) in order) {
			val hello = try {
				runInterruptible(Dispatchers.IO) {
					probe.newCall(Request.Builder().url("$address/api/hello").build()).execute().use { response ->
						if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
						Json.parseToJsonElement(response.body.string())
					}
				}
			} catch (error: Exception) {
				reasons += "$name: ${error.message ?: error.javaClass.simpleName}"
				continue
			}
			val id = hello["server_id"].string
			if (account.serverId.isNotEmpty() && id != account.serverId) {
				reasons += "$name: another server answers there"
				continue
			}
			base.value = address
			via.value = name
			problem.value = ""
			return@withLock address
		}
		via.value = ""
		problem.value = if (order.isEmpty()) "No address of the NAS known" else if (!home && account.vpn.isNotEmpty()) "Not reachable – away from home, is the VPN on? (${reasons.joinToString("; ")})" else "Not reachable (${reasons.joinToString("; ")})"
		null
	}

	// ── HTTP ───────────────────────────────────────────────────────────────
	private fun route(chain: Interceptor.Chain): Response {
		val request = chain.request()
		if (request.url.host != HOST) return chain.proceed(request)
		val account = account.value ?: throw IOException("No NAS token yet")
		val address = base.value ?: runBlocking { resolve() } ?: throw IOException(problem.value.ifEmpty { "The NAS is not reachable" })
		val target = address.toHttpUrl()
		val url = request.url.newBuilder().scheme(target.scheme).host(target.host).port(target.port).build()
		val response = try {
			chain.proceed(request.newBuilder().url(url).header("Authorization", "Bearer ${account.token}").build())
		} catch (error: IOException) {
			// the address went away (another network): looked for again next time
			if (error is ConnectException || error is NoRouteToHostException || error is UnknownHostException || error is java.net.SocketTimeoutException && error.message.orEmpty().contains("connect")) base.compareAndSet(address, null)
			throw error
		}
		if (response.code == 401) refused()
		return response
	}

	/** Requests to http://nas.pshell/… reach the NAS wherever it is, with the token. */
	val client: OkHttpClient by lazy {
		OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).addInterceptor(Interceptor { route(it) }).build()
	}

	/** Thumbnails and pictures of the NAS, through [client]. */
	val images: ImageLoader by lazy {
		ImageLoader.Builder(context).components { add(OkHttpNetworkFetcherFactory(callFactory = { client })) }.crossfade(true).build()
	}

	fun url(path: String, vararg query: Pair<String, Any?>): String {
		val builder = "http://$HOST$path".toHttpUrl().newBuilder()
		for ((key, value) in query) if (value != null) builder.addQueryParameter(key, value.toString())
		return builder.build().toString()
	}

	fun fileUrl(path: String) = url("/api/file", "path" to path)
	fun thumbUrl(path: String, size: Int = 256) = url("/api/thumb", "path" to path, "size" to size)

	private fun answer(response: Response): JsonElement? {
		val text = response.body.string()
		val parsed = runCatching { if (text.isBlank()) null else Json.parseToJsonElement(text) }.getOrNull()
		if (!response.isSuccessful) throw NasError(response.code, parsed["code"].string, parsed["error"].string.ifEmpty { if (response.code == 401) "The NAS does not know this phone's token" else "HTTP ${response.code}" })
		return parsed
	}

	suspend fun get(path: String, vararg query: Pair<String, Any?>): JsonElement? = runInterruptible(Dispatchers.IO) {
		client.newCall(Request.Builder().url(url(path, *query)).build()).execute().use { answer(it) }
	}

	suspend fun send(method: String, path: String, body: JsonObject = JsonObject(emptyMap())): JsonElement? = runInterruptible(Dispatchers.IO) {
		val request = Request.Builder().url(url(path)).method(method, body.toString().toRequestBody("application/json".toMediaType())).build()
		client.newCall(request).execute().use { answer(it) }
	}

	// the calls of docs/nas.md the app uses
	suspend fun list(path: String) = get("/api/ls", "path" to path)["entries"].list
	suspend fun stat(path: String): JsonElement? = try {
		get("/api/stat", "path" to path)
	} catch (error: NasError) {
		if (error.status == 404) null else throw error
	}

	suspend fun search(query: String, kind: String = "", path: String = "", limit: Int = 200): List<JsonElement> =
		get("/api/search", "q" to query, "kind" to kind.ifEmpty { null }, "path" to path.ifEmpty { null }, "limit" to limit)["entries"].list

	suspend fun mkdir(path: String) = send("POST", "/api/mkdir", json("path" to path))

	suspend fun delete(paths: List<String>) = send("POST", "/api/delete", json("paths" to paths)).also { changed.value += 1 }

	suspend fun trash(): List<JsonElement> = get("/api/trash").let { it["entries"].list.ifEmpty { it.list } }

	suspend fun restore(ids: List<String>) = send("POST", "/api/trash/restore", json("ids" to ids)).also { changed.value += 1 }

	/** The PCs and laptops the NAS can wake. */
	suspend fun wakeable(): List<JsonElement> = get("/api/devices").let { it["devices"].list.ifEmpty { it.list } }
		.filter { it["kind"].string == "pc" || it["kind"].string == "laptop" }

	suspend fun wake(device: String) = send("POST", "/api/wake", json("device" to device))

	// ── uploads (resumable: the NAS keeps a started one by path and size) ──
	/**
	 * Puts a file on the NAS: [open] gives its bytes from the start each time it
	 * is called (a 409 or a new attempt goes on where the NAS says).
	 * Answers the new Entry.
	 */
	suspend fun upload(open: () -> InputStream, size: Long, path: String, mtime: Long? = null, conflict: String = "rename", progress: (Long) -> Unit = {}): JsonElement? {
		val start = send("POST", "/api/upload", json("path" to path, "size" to size, "mtime" to mtime, "conflict" to conflict))
		val id = start["id"].string
		if (id.isEmpty()) throw IOException("The NAS started no upload")
		var offset = start["offset"].long
		progress(offset)
		val buffer = ByteArray(CHUNK)
		var input = withContext(Dispatchers.IO) { open().also { skip(it, offset) } }
		try {
			while (offset < size) {
				currentCoroutineContext().ensureActive()
				val read = withContext(Dispatchers.IO) { fill(input, buffer) }
				if (read <= 0) throw IOException("The file is shorter than it said")
				val request = Request.Builder().url(url("/api/upload/$id")).header("Upload-Offset", offset.toString())
					.put(buffer.toRequestBody("application/offset+octet-stream".toMediaType(), 0, read)).build()
				val next = runInterruptible(Dispatchers.IO) {
					client.newCall(request).execute().use { response ->
						val text = response.body.string()
						val parsed = runCatching { Json.parseToJsonElement(text) }.getOrNull()
						when {
							response.code == 409 -> -(parsed["offset"].long + 1) // where the NAS really is
							!response.isSuccessful -> throw NasError(response.code, parsed["code"].string, parsed["error"].string)
							else -> parsed["offset"].long.takeIf { it > 0 } ?: (offset + read)
						}
					}
				}
				if (next < 0) {
					offset = -next - 1
					input.close()
					input = withContext(Dispatchers.IO) { open().also { skip(it, offset) } }
				} else offset = next
				progress(offset)
			}
		} finally {
			withContext(Dispatchers.IO) { input.close() }
		}
		return send("POST", "/api/upload/$id/done").also { changed.value += 1 }
	}

	private fun skip(input: InputStream, count: Long) {
		var left = count
		while (left > 0) {
			val skipped = input.skip(left)
			if (skipped <= 0) {
				if (input.read() < 0) throw IOException("The file is shorter than the NAS has of it")
				left -= 1
			} else left -= skipped
		}
	}

	private fun fill(input: InputStream, buffer: ByteArray): Int {
		var total = 0
		while (total < buffer.size) {
			val read = input.read(buffer, total, buffer.size - total)
			if (read < 0) break
			total += read
		}
		return total
	}

	// ── downloads ──────────────────────────────────────────────────────────
	/** A NAS file to a local one, through a temporary file beside it. */
	suspend fun download(path: String, target: File, progress: (Long, Long) -> Unit = { _, _ -> }): File = runInterruptible(Dispatchers.IO) {
		target.parentFile?.mkdirs()
		val partial = File(target.parentFile, ".${target.name}.part")
		client.newCall(Request.Builder().url(fileUrl(path)).build()).execute().use { response ->
			if (!response.isSuccessful) answer(response)
			val total = response.body.contentLength()
			response.body.byteStream().use { input ->
				partial.outputStream().use { output ->
					val buffer = ByteArray(256 * 1024)
					var done = 0L
					while (true) {
						if (Thread.interrupted()) throw InterruptedException()
						val read = input.read(buffer)
						if (read < 0) break
						output.write(buffer, 0, read)
						done += read
						progress(done, total)
					}
				}
			}
		}
		if (!partial.renameTo(target)) throw IOException("Could not keep ${target.name}")
		target
	}

	/** Into the phone's Downloads/NAS, where the files app finds it. */
	suspend fun saveToDownloads(path: String): String = withContext(Dispatchers.IO) {
		val name = path.substringAfterLast('/')
		val values = ContentValues().apply {
			put(MediaStore.Downloads.DISPLAY_NAME, name)
			put(MediaStore.Downloads.MIME_TYPE, mimeOf(name))
			put(MediaStore.Downloads.RELATIVE_PATH, "Download/NAS")
			put(MediaStore.Downloads.IS_PENDING, 1)
		}
		val resolver = context.contentResolver
		val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw IOException("No room in Downloads")
		try {
			runInterruptible {
				client.newCall(Request.Builder().url(fileUrl(path)).build()).execute().use { response ->
					if (!response.isSuccessful) answer(response)
					resolver.openOutputStream(uri)!!.use { output -> response.body.byteStream().use { it.copyTo(output, 256 * 1024) } }
				}
			}
			resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
		} catch (error: Throwable) {
			resolver.delete(uri, null, null)
			throw error
		}
		"Download/NAS/$name"
	}

	/** A local copy to hand to another app: a pinned one, else one in the cache. */
	suspend fun local(path: String): File = Pins.fresh(path) ?: download(path, File(context.cacheDir, "nas/${hash(path)}/${path.substringAfterLast('/')}"))

	fun mimeOf(name: String): String =
		MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"

	fun contentUri(file: File) = FileProvider.getUriForFile(context, "${context.packageName}.nasfiles", file)

	fun share(file: File) {
		val send = Intent(Intent.ACTION_SEND).setType(mimeOf(file.name)).putExtra(Intent.EXTRA_STREAM, contentUri(file)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
		context.startActivity(Intent.createChooser(send, file.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
	}

	fun openWith(file: File) {
		val view = Intent(Intent.ACTION_VIEW).setDataAndType(contentUri(file), mimeOf(file.name)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
		context.startActivity(Intent.createChooser(view, file.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
	}

	fun hash(text: String): String = MessageDigest.getInstance("SHA-1").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }.take(16)
}

/**
 * Files kept on the phone (offline pins): a copy in the app's storage and
 * what the NAS said of it (size, mtime). Opening a pinned file checks the
 * NAS first and fetches it again when it changed there; offline the copy opens.
 */
object Pins {
	data class Pin(val path: String, val size: Long, val mtime: Long, val file: String)

	private lateinit var folder: File
	val pinned = MutableStateFlow<Map<String, Pin>>(emptyMap())
	/** paths being fetched right now */
	val busy = MutableStateFlow<Set<String>>(emptySet())

	fun load(context: Context) {
		folder = File(context.filesDir, "nas-pins")
		pinned.value = runCatching {
			Json.parseToJsonElement(File(folder, "pins.json").readText()).list.map { Pin(it["path"].string, it["size"].long, it["mtime"].long, it["file"].string) }
		}.getOrDefault(emptyList()).filter { File(it.file).exists() }.associateBy { it.path }
	}

	private fun save() {
		folder.mkdirs()
		val text = pinned.value.values.map { json("path" to it.path, "size" to it.size, "mtime" to it.mtime, "file" to it.file) }.let { kotlinx.serialization.json.JsonArray(it) }.toString()
		val temporary = File(folder, "pins.json.tmp")
		temporary.writeText(text)
		temporary.renameTo(File(folder, "pins.json"))
	}

	fun isPinned(path: String) = path in pinned.value

	suspend fun pin(entry: JsonElement) {
		val path = entry["path"].string
		busy.value += path
		try {
			val target = File(folder, "${Nas.hash(path)}/${path.substringAfterLast('/')}")
			Nas.download(path, target)
			pinned.value += path to Pin(path, entry["size"].long, entry["mtime"].long, target.path)
			save()
		} finally {
			busy.value -= path
		}
	}

	fun unpin(path: String) {
		val pin = pinned.value[path] ?: return
		File(pin.file).parentFile?.deleteRecursively()
		pinned.value -= path
		save()
	}

	/** The pinned copy, fetched again first when the NAS has another one; null when not pinned. */
	suspend fun fresh(path: String): File? {
		val pin = pinned.value[path] ?: return null
		val stat = try {
			Nas.stat(path)
		} catch (error: IOException) {
			return File(pin.file) // offline: what there is
		}
		if (stat == null) return File(pin.file) // gone on the NAS: the copy stays until unpinned
		if (stat["size"].long != pin.size || stat["mtime"].long != pin.mtime) {
			busy.value += path
			try {
				Nas.download(path, File(pin.file))
				pinned.value += path to pin.copy(size = stat["size"].long, mtime = stat["mtime"].long)
				save()
			} finally {
				busy.value -= path
			}
		}
		return File(pin.file)
	}

	/** Every pin checked against the NAS (when the pinned list is looked at). */
	suspend fun syncAll() {
		for (path in pinned.value.keys.toList()) runCatching { fresh(path) }
	}
}
