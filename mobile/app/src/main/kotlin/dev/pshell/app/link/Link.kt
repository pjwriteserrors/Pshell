package dev.pshell.app.link

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

class LinkError(val code: String, message: String) : Exception(message.ifEmpty { code })

sealed interface LinkState {
	/** no PC was paired yet */
	data object Unpaired : LinkState

	/** paired, and none of its addresses answers */
	data object Searching : LinkState

	data class Connected(val pc: Pc, val address: String) : LinkState
}

/** Something a PC told the phone once; [pc] is the id of the one that did. */
data class Event(val topic: String, val name: String, val data: JsonElement?, val pc: String = "")

/**
 * The phone's side of the protocol (docs/mobile.md). Every paired PC has a
 * connection of its own ([PcLink]), all at once. What the app shows and
 * steers is the PC in front: the preferred one while it is connected,
 * otherwise whichever is. Topics are state a PC publishes while somebody
 * holds them ([acquire]); calls ask it to do something; the phone's own
 * topics are [publish]ed to every PC and answered by [handle].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class Link(private val context: Context) {
	val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
	val pcs = Pcs(context)
	internal val discovery = Discovery(context)

	private val links = ConcurrentHashMap<String, PcLink>()
	private val connections = MutableStateFlow<Map<String, LinkState.Connected>>(emptyMap())
	private val searching = ConcurrentHashMap.newKeySet<String>()

	/** the PC the app shows: preferred while connected, else any connected, else the preferred one */
	val active: StateFlow<PcLink?> = combine(pcs.list, connections, pcs.preferredFlow) { list, connected, preferred ->
		val id = when {
			preferred in connected -> preferred
			connected.isNotEmpty() -> list.firstOrNull { it.id in connected }?.id
			else -> list.firstOrNull { it.id == preferred }?.id ?: list.firstOrNull()?.id
		}
		id?.let { link(it) }
	}.stateIn(scope, SharingStarted.Eagerly, null)

	val state: StateFlow<LinkState> = combine(pcs.list, active, connections) { list, front, connected ->
		when {
			list.isEmpty() -> LinkState.Unpaired
			front != null && front.id in connected -> connected.getValue(front.id)
			else -> LinkState.Searching
		}
	}.stateIn(scope, SharingStarted.Eagerly, if (pcs.list.value.isEmpty()) LinkState.Unpaired else LinkState.Searching)

	/** every connection that just came up, by the PC's id */
	private val mutableConnects = MutableSharedFlow<String>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
	val connects: SharedFlow<String> = mutableConnects

	private val references = HashMap<String, Int>()
	internal val own = ConcurrentHashMap<String, JsonElement>()
	internal val handlers = ConcurrentHashMap<String, suspend (JsonElement?) -> JsonElement?>()
	private val fronts = ConcurrentHashMap<String, StateFlow<JsonElement?>>()

	private val mutableEvents = MutableSharedFlow<Event>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
	val events: SharedFlow<Event> = mutableEvents

	/** what went wrong with something the user asked for, to be shown once */
	private val mutableErrors = MutableSharedFlow<String>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
	val errors: SharedFlow<String> = mutableErrors

	/** whether the app is on screen; set by the activity */
	@Volatile var foreground = false
		set(value) {
			field = value
			if (value) retryNow()
		}

	/** Shows a short message at the bottom of the app. */
	fun toast(text: String) {
		mutableErrors.tryEmit(text)
	}

	/** round trip of the last ping to the PC in front, -1 while unknown */
	val latency: StateFlow<Long> = active.flatMapLatest { it?.latency ?: flowOf(-1L) }.stateIn(scope, SharingStarted.Eagerly, -1L)

	val clockOffset: Long get() = active.value?.clockOffset ?: 0L

	/** now, on the clock of the PC in front */
	fun pcNow() = System.currentTimeMillis() + clockOffset

	// ── the PCs ────────────────────────────────────────────────────────────
	private fun link(id: String): PcLink = links.getOrPut(id) { PcLink(this, id) }

	/** The connection to one PC, or to the one in front. */
	fun of(id: String?): PcLink? = when {
		id.isNullOrEmpty() -> active.value
		pcs.list.value.any { it.id == id } -> link(id)
		else -> active.value
	}

	internal fun connectionChanged(link: PcLink) {
		val now = link.connection.value
		connections.value = if (now == null) connections.value - link.id else connections.value + (link.id to now)
		if (now != null) mutableConnects.tryEmit(link.id)
	}

	/** mDNS runs only while some PC is being looked for */
	internal fun searching(link: PcLink, on: Boolean) {
		if (on) searching.add(link.id) else searching.remove(link.id)
		if (searching.isEmpty()) discovery.stop() else discovery.start()
	}

	internal fun received(event: Event) {
		mutableEvents.tryEmit(event)
	}

	// ── topics ─────────────────────────────────────────────────────────────
	/** A topic of the PC in front; it follows when another PC comes to the front. */
	fun topic(name: String): StateFlow<JsonElement?> = fronts.getOrPut(name) {
		active.flatMapLatest { it?.topic(name) ?: flowOf(null) }.stateIn(scope, SharingStarted.Eagerly, active.value?.topic(name)?.value)
	}

	internal fun subscriptions(): List<String> = synchronized(references) { references.keys.toList() }

	/** Subscribes while held, on every PC; [release] gives it back. */
	fun acquire(name: String) {
		val first = synchronized(references) {
			val count = (references[name] ?: 0) + 1
			references[name] = count
			count == 1
		}
		if (first) links.values.forEach { it.send(json("type" to "sub", "topics" to listOf(name))) }
	}

	fun release(name: String) {
		scope.launch {
			// a screen that comes right back keeps its topic
			delay(2500)
			val last = synchronized(references) {
				val count = (references[name] ?: 1) - 1
				if (count <= 0) references.remove(name) else references[name] = count
				count <= 0
			}
			if (last) links.values.forEach { it.send(json("type" to "unsub", "topics" to listOf(name))) }
		}
	}

	// ── calls ──────────────────────────────────────────────────────────────
	suspend fun call(topic: String, action: String, args: JsonObject = NoArgs, timeoutSeconds: Int = 15): JsonElement? =
		(active.value ?: throw LinkError("offline", "Not connected")).call(topic, action, args, timeoutSeconds)

	/** A call whose answer nobody waits for; a failure is reported through [errors]. */
	fun run(topic: String, action: String, args: JsonObject = NoArgs) {
		scope.launch {
			try {
				call(topic, action, args)
			} catch (error: LinkError) {
				mutableErrors.tryEmit(describe(error))
			}
		}
	}

	fun describe(error: LinkError): String = when (error.code) {
		"offline", "unreachable" -> "Not connected"
		"plugin-off" -> "Switched off on the PC"
		"timeout" -> "The PC did not answer"
		else -> error.message ?: error.code
	}

	// ── the phone's own topics ─────────────────────────────────────────────
	fun publish(topic: String, data: JsonElement) {
		if (own.put(topic, data) != data) links.values.forEach { it.send(json("type" to "state", "topic" to topic, "data" to data)) }
	}

	/** To every connected PC: the phone's notifications and calls are for all of them. */
	fun emit(topic: String, name: String, data: JsonObject = NoArgs) {
		links.values.forEach { it.send(json("type" to "event", "topic" to topic, "name" to name, "data" to data)) }
	}

	/** Answers a PC's calls to "<topic>.<action>". */
	fun handle(topic: String, action: String, handler: suspend (JsonElement?) -> JsonElement?) {
		handlers["$topic.$action"] = handler
	}

	fun sendBytes(bytes: ByteString): Boolean = active.value?.sendBytes(bytes) ?: false

	// ── blobs ──────────────────────────────────────────────────────────────
	/**
	 * Requests to https://pc.pshell/… go to the PC in front, wherever it is;
	 * https://<id>.pc.pshell/… to the PC of that id.
	 */
	val http: OkHttpClient = OkHttpClient.Builder().addInterceptor(Interceptor { chain -> proxy(chain) }).build()

	private fun proxy(chain: Interceptor.Chain): Response {
		val host = chain.request().url.host
		// anything else (a cover on the web) is fetched as it is
		if (host != "pc.pshell" && !host.endsWith(".pc.pshell")) return chain.proceed(chain.request())
		val target = (if (host == "pc.pshell") active.value else links.values.firstOrNull { it.id.startsWith(host.removeSuffix(".pc.pshell")) })
		val state = target?.connection?.value ?: throw IOException("Not connected")
		val base = target.base(state.address, state.pc.port)
		val url = chain.request().url.newBuilder().host(base.host).port(base.port).build()
		return target.client().newCall(chain.request().newBuilder().url(url).build()).execute()
	}

	/** A WebSocket of its own to the PC in front (a stream), next to the link. */
	fun socket(path: String, listener: WebSocketListener): WebSocket? = active.value?.socket(path, listener)

	fun blob(path: String?): String? = when {
		path.isNullOrEmpty() -> null
		path.startsWith("/") -> "https://pc.pshell$path"
		else -> path
	}

	// ── pairing ────────────────────────────────────────────────────────────
	/** Trades the secret of a pairing code (pshell://pair?…) for trust. */
	suspend fun pair(code: String): Pc = withContext(Dispatchers.IO) {
		val uri = Uri.parse(code.trim())
		val fingerprint = uri.getQueryParameter("f")?.lowercase().orEmpty()
		val secret = uri.getQueryParameter("s").orEmpty()
		val port = uri.getQueryParameter("p")?.toIntOrNull() ?: 0
		val addresses = uri.getQueryParameter("a").orEmpty().split(',').filter { it.isNotBlank() }
		if (uri.scheme != "pshell" || fingerprint.length != 64 || secret.isEmpty() || port == 0 || addresses.isEmpty())
			throw LinkError("bad-code", "This is not a pairing code")

		val pin = Identity.Pin(fingerprint)
		val client = OkHttpClient.Builder()
			.sslSocketFactory(Identity.context(pin, authenticated = false).socketFactory, pin)
			.hostnameVerifier { _, _ -> true }
			.connectTimeout(3, TimeUnit.SECONDS)
			.build()
		val body = json("secret" to secret, "name" to deviceName(), "model" to Build.MODEL, "cert" to Identity.pem).toString()
		var reached = false
		for (address in addresses) {
			val request = Request.Builder().url(link(fingerprint).base(address, port).newBuilder().addPathSegment("pair").build())
				.post(body.toRequestBody("application/json".toMediaType())).build()
			val response = try {
				client.newCall(request).execute()
			} catch (error: IOException) {
				continue
			}
			reached = true
			response.use {
				if (it.code == 403) throw LinkError("refused", "The code has expired. Show a new one on the PC.")
				if (!it.isSuccessful) throw LinkError("refused", "The PC refused (${it.code})")
				val answer = Json.parseToJsonElement(it.body.string())
				val pc = Pc(
					id = fingerprint,
					name = answer["name"].string.ifEmpty { uri.getQueryParameter("n") ?: "PC" },
					port = port,
					addresses = addresses,
					last = address,
				)
				pcs.put(pc)
				pcs.preferred = pc.id
				link(pc.id).apply {
					start()
					retryNow()
				}
				return@withContext pc
			}
		}
		if (pcs.list.value.none { it.id == fingerprint }) links.remove(fingerprint)
		throw LinkError("unreachable", if (reached) "Pairing failed" else "The PC is not reachable. Is the phone in the same network?")
	}

	fun unpair(id: String) {
		pcs.remove(id)
		links.remove(id)?.stop()
		searching.remove(id)
	}

	/**
	 * Wake on LAN: the "magic packet" (six 0xff, then the card's address
	 * sixteen times) to the broadcast address of the network the PC was in.
	 */
	suspend fun wake(pc: Pc): Boolean = withContext(Dispatchers.IO) {
		if (pc.mac.isEmpty()) return@withContext false
		val subnet = Regex("^(\\d+\\.\\d+\\.\\d+)\\.\\d+")
		val targets = (listOf("255.255.255.255") + (listOf(pc.last) + pc.addresses).mapNotNull { address ->
			subnet.find(address)?.groupValues?.get(1)?.let { "$it.255" }
		}).distinct()
		runCatching {
			java.net.DatagramSocket().use { socket ->
				socket.broadcast = true
				for (mac in pc.mac) {
					val bytes = mac.split(':', '-').map { it.toInt(16).toByte() }
					if (bytes.size != 6) continue
					val packet = ByteArray(6) { 0xff.toByte() } + ByteArray(16 * 6) { bytes[it % 6] }
					for (target in targets) for (port in listOf(9, 7)) {
						runCatching { socket.send(java.net.DatagramPacket(packet, packet.size, java.net.InetAddress.getByName(target), port)) }
					}
				}
			}
		}.isSuccess
	}

	fun deviceName(): String =
		Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } ?: Build.MODEL

	// ── connection ─────────────────────────────────────────────────────────
	private var started = false

	fun start() {
		if (started) return
		started = true
		acquire("plugins")
		acquire("theme")
		acquire("link")
		val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
		runCatching {
			connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
				override fun onAvailable(network: Network) = retryNow()
				override fun onLost(network: Network) = links.values.forEach { it.drop() }
			})
		}
		discovery.onFound = ::retryNow
		for (pc in pcs.list.value) link(pc.id).start()
	}

	/** Something changed that may make a PC reachable: try at once. */
	fun retryNow() {
		links.values.forEach { it.retryNow() }
	}
}
