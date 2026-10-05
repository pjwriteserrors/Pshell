package dev.pshell.app.link

import android.os.Build
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/**
 * The connection to one paired PC: finds it, keeps the WebSocket open, holds
 * what that PC published. Every paired PC has one, all at the same time;
 * [Link] is what the app talks to and picks the one in front.
 */
class PcLink(private val link: Link, val id: String) {
	val pc: Pc? get() = link.pcs.list.value.firstOrNull { it.id == id }

	/** where it is connected, or null */
	private val mutableConnection = MutableStateFlow<LinkState.Connected?>(null)
	val connection: StateFlow<LinkState.Connected?> = mutableConnection
	val connected: Boolean get() = mutableConnection.value != null

	private val topics = ConcurrentHashMap<String, MutableStateFlow<JsonElement?>>()
	private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonElement?>>()
	private val answering = ConcurrentHashMap<String, Job>()
	private val ids = AtomicInteger()

	/** round trip of the last ping in ms, -1 while unknown */
	val latency = MutableStateFlow(-1L)

	/** PC clock minus phone clock in ms, so positions anchored on the PC's clock can be continued here */
	@Volatile var clockOffset = 0L
		private set

	fun pcNow() = System.currentTimeMillis() + clockOffset

	private val kick = Channel<Unit>(Channel.CONFLATED)
	private var loop: Job? = null
	@Volatile private var session: Session? = null
	private var client: OkHttpClient? = null

	fun topic(name: String): StateFlow<JsonElement?> = flow(name)

	private fun flow(name: String) = topics.getOrPut(name) { MutableStateFlow(null) }

	fun send(message: JsonObject) {
		session?.send(message)
	}

	fun sendBytes(bytes: ByteString): Boolean = session?.socket?.send(bytes) ?: false

	suspend fun call(topic: String, action: String, args: JsonObject = NoArgs, timeoutSeconds: Int = 15): JsonElement? {
		val current = session ?: throw LinkError("offline", "Not connected")
		val callId = "p${ids.incrementAndGet()}"
		val answer = CompletableDeferred<JsonElement?>()
		pending[callId] = answer
		try {
			current.send(json("type" to "call", "id" to callId, "topic" to topic, "action" to action, "args" to args, "timeout" to timeoutSeconds))
			return withTimeoutOrNull(timeoutSeconds * 1000L + 2000L) { answer.await() } ?: throw LinkError("timeout", "The PC did not answer")
		} finally {
			pending.remove(callId)
		}
	}

	/** A call whose answer nobody waits for; a failure is shown once. */
	fun run(topic: String, action: String, args: JsonObject = NoArgs) {
		link.scope.launch {
			try {
				call(topic, action, args)
			} catch (error: LinkError) {
				link.toast(link.describe(error))
			}
		}
	}

	/** Something this PC offers under a path, as a URL the app's HTTP client can fetch. */
	fun blob(path: String?): String? = when {
		path.isNullOrEmpty() -> null
		path.startsWith("/") -> "https://${id.take(16)}.pc.pshell$path"
		else -> path
	}

	fun base(address: String, port: Int): HttpUrl = when {
		// an address found by mDNS or entered with its own port
		address.count { it == ':' } == 1 -> "https://$address/".toHttpUrl()
		address.contains(':') -> "https://[$address]:$port/".toHttpUrl()
		else -> "https://$address:$port/".toHttpUrl()
	}

	fun client(): OkHttpClient = client ?: run {
		val pin = Identity.Pin(id)
		OkHttpClient.Builder()
			.sslSocketFactory(Identity.context(pin, authenticated = true).socketFactory, pin)
			.hostnameVerifier { _, _ -> true }
			.connectTimeout(4, TimeUnit.SECONDS)
			.readTimeout(0, TimeUnit.SECONDS)
			// the keepalive that notices a dead link; the PC pings every 45 s as well
			.pingInterval(50, TimeUnit.SECONDS)
			.build()
			.also { client = it }
	}

	/** A WebSocket of its own to this PC (a stream), next to the link. */
	fun socket(path: String, listener: WebSocketListener): WebSocket? {
		val state = mutableConnection.value ?: return null
		val url = base(state.address, state.pc.port).resolve(path) ?: return null
		return client().newBuilder().pingInterval(0, TimeUnit.SECONDS).build().newWebSocket(Request.Builder().url(url).build(), listener)
	}

	fun start() {
		if (loop?.isActive == true) return
		loop = link.scope.launch { run() }
	}

	fun stop() {
		loop?.cancel()
		session?.socket?.close(1000, null)
		session = null
		mutableConnection.value = null
		link.connectionChanged(this)
	}

	/** Something changed that may make the PC reachable: try at once. */
	fun retryNow() {
		kick.trySend(Unit)
	}

	/** The network went away: the socket would only notice at its next ping. */
	fun drop() {
		session?.socket?.cancel()
	}

	private suspend fun run() {
		var wait = 1000L
		while (true) {
			val target = pc ?: return
			link.searching(this, true)
			val opened = connect(target)
			if (opened == null) {
				withTimeoutOrNull(wait) { kick.receive() }
				// a PC that is off is asked less and less often; a network change asks at once
				wait = (wait * 2).coerceAtMost(if (link.foreground) 30_000L else 180_000L)
				continue
			}
			wait = 1000L
			link.searching(this, false)
			session = opened
			link.pcs.update(id) { it.copy(last = opened.address) }
			mutableConnection.value = LinkState.Connected(pc ?: target, opened.address)
			opened.greet()
			link.connectionChanged(this)
			val pinger = link.scope.launch { ping() }
			opened.closed.await()
			pinger.cancel()
			session = null
			latency.value = -1
			pending.values.forEach { it.completeExceptionally(LinkError("offline", "Connection lost")) }
			pending.clear()
			mutableConnection.value = null
			link.connectionChanged(this)
		}
	}

	/** Knocks on every address of the PC at once; the first that opens wins. */
	private suspend fun connect(pc: Pc): Session? {
		val found = link.discovery.found[pc.id.take(32)]
		val addresses = (listOfNotNull(pc.last.ifEmpty { null }, found) + pc.manual + pc.addresses).distinct()
		if (addresses.isEmpty()) return null
		val attempts = addresses.map { Session(pc, it).also(Session::open) }
		val winner = CompletableDeferred<Session?>()
		val left = AtomicInteger(attempts.size)
		for (attempt in attempts) {
			link.scope.launch {
				if (attempt.opened.await()) winner.complete(attempt)
				else if (left.decrementAndGet() == 0) winner.complete(null)
			}
		}
		val won = withTimeoutOrNull(6000) { winner.await() }
		attempts.filter { it !== won }.forEach { it.socket?.cancel() }
		return won
	}

	/** Measures the round trip, but only while somebody looks at the app: in the background the keepalives are enough. */
	private suspend fun ping() {
		while (true) {
			if (!link.foreground) {
				latency.value = -1
				delay(15_000)
				continue
			}
			val sent = System.nanoTime()
			val wall = System.currentTimeMillis()
			runCatching { call("link", "ping", timeoutSeconds = 8) }.onSuccess {
				val trip = (System.nanoTime() - sent) / 1_000_000
				latency.value = trip
				if (it["time"].long > 0) clockOffset = it["time"].long - (wall + trip / 2)
			}
			delay(15_000)
		}
	}

	private inner class Session(val pc: Pc, val address: String) : WebSocketListener() {
		val opened = CompletableDeferred<Boolean>()
		val closed = CompletableDeferred<Unit>()
		@Volatile var socket: WebSocket? = null

		fun open() {
			val url = base(address, pc.port).newBuilder().addPathSegment("link").build()
			socket = client().newWebSocket(Request.Builder().url(url).build(), this)
		}

		fun send(message: JsonObject) {
			socket?.send(message.toString())
		}

		/** After connecting: who we are, what we watch, what we publish. */
		fun greet() {
			send(json("type" to "hello", "version" to 1, "name" to link.deviceName(), "model" to Build.MODEL, "android" to Build.VERSION.SDK_INT))
			val wanted = link.subscriptions()
			if (wanted.isNotEmpty()) send(json("type" to "sub", "topics" to wanted))
			link.own.forEach { (topic, data) -> send(json("type" to "state", "topic" to topic, "data" to data)) }
		}

		override fun onOpen(webSocket: WebSocket, response: Response) {
			opened.complete(true)
		}

		override fun onMessage(webSocket: WebSocket, text: String) {
			if (session !== this) return
			val message = runCatching { Json.parseToJsonElement(text) }.getOrNull() ?: return
			when (message["type"].string) {
				"state" -> flow(message["topic"].string).value = message["data"]
				"result" -> pending.remove(message["id"].string)?.let { answer ->
					if (message["ok"].bool) answer.complete(message["data"])
					else answer.completeExceptionally(LinkError(message["error"]["code"].string, message["error"]["message"].string))
				}
				"event" -> link.received(Event(message["topic"].string, message["name"].string, message["data"], id))
				"call" -> {
					val callId = message["id"].string
					answering[callId] = link.scope.launch { answer(message) }.also { job -> job.invokeOnCompletion { answering.remove(callId) } }
				}
				// the PC no longer waits for the answer
				"cancel" -> answering.remove(message["id"].string)?.cancel()
			}
		}

		private suspend fun answer(message: JsonElement) {
			val callId = message["id"] ?: return
			val handler = link.handlers["${message["topic"].string}.${message["action"].string}"]
			val result = if (handler == null) {
				json("type" to "result", "id" to callId, "ok" to false, "error" to json("code" to "unknown-action", "message" to ""))
			} else try {
				json("type" to "result", "id" to callId, "ok" to true, "data" to handler(message["args"]))
			} catch (error: kotlinx.coroutines.CancellationException) {
				throw error
			} catch (error: Exception) {
				json("type" to "result", "id" to callId, "ok" to false, "error" to json("code" to ((error as? LinkError)?.code ?: "failed"), "message" to (error.message ?: "")))
			}
			send(result)
		}

		override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
			webSocket.close(1000, null)
		}

		override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = finish()

		override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = finish()

		private fun finish() {
			opened.complete(false)
			closed.complete(Unit)
		}
	}
}
