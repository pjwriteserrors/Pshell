package dev.pshell.app.zepp

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom

/** A setting as the watch reported it (see parse_config in scripts/amazfit/zepp/protocol.py). */
data class Entry(
	val code: Int,
	val type: String,
	val value: Any?,
	val min: Long? = null,
	val max: Long? = null,
	val allowed: List<Any>? = null,
	val maxLength: Int? = null,
)

data class Group(val name: String, val id: Int, val version: Int, val entries: Map<Int, Entry>)

/** [window]: smart wake – in light sleep up to this many minutes early (10–50), 0 = at the time. */
data class Alarm(val position: Int, val enabled: Boolean, val smart: Boolean, val hour: Int, val minute: Int, val repeat: Int, val window: Int = 0)

data class WatchState(
	val link: String = "idle",            // idle, connecting, gatt, handshake, ready, nokey, wrongkey, failed, gone
	val detail: String = "",
	val name: String = "",
	val battery: Int? = null,
	val charging: Boolean = false,
	val info: Map<String, String> = emptyMap(),
	val config: Map<String, Group> = emptyMap(),
	val alarms: List<Alarm> = emptyList(),
	val faces: List<String> = emptyList(),
	val face: String? = null,
	val services: Map<Int, Boolean> = emptyMap(),
	val finding: Boolean = false,
	val musicOpen: Boolean = false,
	val fetching: Boolean = false,
	val fetchedAt: Long = 0,
)

/** What the watch starts; set by WatchLink. */
class ZeppEvents {
	var findPhone: (Boolean) -> Unit = {}
	var button: (String) -> Unit = {}
	var musicOpen: (Boolean) -> Unit = {}
	var reply: (Int, String) -> Unit = { _, _ -> }
	var dismiss: (Int) -> Unit = {}
	var callAction: (String) -> Unit = {}
	var http: (Int, String) -> Unit = { _, _ -> }
	var fetchControl: (ByteArray) -> Unit = {}
	var ready: () -> Unit = {}
}

/** What the catalogue (scripts/amazfit/zepp/catalog.json, copied in as assets/zepp.json) says. */
class Catalog(json: JSONObject) {
	class Arg(val group: String, val code: Int, val type: String, val key: String, val label: String, val options: Map<Int, String>, val choices: String?, val unit: String?, val note: String?, val guess: Boolean)

	val groups: Map<String, Pair<Int, Int>> = json.getJSONObject("groups").let { g ->
		g.keys().asSequence().associateWith { k -> g.getJSONObject(k).let { it.getInt("id") to it.getInt("version") } }
	}
	val groupLabels: Map<String, String> = json.getJSONObject("groups").let { g -> g.keys().asSequence().associateWith { g.getJSONObject(it).getString("label") } }
	val types: Map<String, Int> = json.getJSONObject("types").let { t -> t.keys().asSequence().associateWith { t.getInt(it) } }
	val args: List<Arg> = json.getJSONArray("args").let { a ->
		(0 until a.length()).map { i ->
			val o = a.getJSONObject(i)
			val opts = o.optJSONObject("options")
			Arg(o.getString("group"), o.getInt("code"), o.getString("type"), o.getString("key"), o.getString("label"),
				opts?.keys()?.asSequence()?.associate { it.toInt() to opts.getString(it) } ?: emptyMap(), o.optString("choices").ifEmpty { null }, o.optString("unit").ifEmpty { null },
				o.optString("note").ifEmpty { null }, o.optBoolean("guess", false))
		}
	}
	val languages: Map<String, Int> = json.getJSONObject("languages").let { l -> l.keys().asSequence().associateWith { l.getInt(it) } }
	val faces: Map<String, String> = json.getJSONObject("faces").let { f -> f.keys().asSequence().associateWith { f.getString(it) } }
	val menu: Map<String, String> = json.getJSONObject("menu").let { f -> f.keys().asSequence().associateWith { f.getString(it) } }

	fun arg(group: String, code: Int) = args.firstOrNull { it.group == group && it.code == code }
	fun groupName(id: Int) = groups.entries.firstOrNull { it.value.first == id }?.key ?: "%02x".format(id)
	fun typeName(byte: Int) = types.entries.firstOrNull { it.value == byte }?.key
}

private class Reader(val b: ByteArray, var i: Int) {
	fun u8() = b[i++].toInt() and 0xFF
	fun s16(): Int = ByteBuffer.wrap(b, i, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt().also { i += 2 }
	fun s32(): Int = ByteBuffer.wrap(b, i, 4).order(ByteOrder.LITTLE_ENDIAN).int.also { i += 4 }
	fun s64(): Long = ByteBuffer.wrap(b, i, 8).order(ByteOrder.LITTLE_ENDIAN).long.also { i += 8 }
	fun cstr(): String {
		var end = i
		while (end < b.size && b[end].toInt() != 0) end++
		return String(b, i, end - i, Charsets.UTF_8).also { i = minOf(b.size, end + 1) }
	}
	fun left() = b.size - i
}

private fun le16(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte())
private fun le32(v: Int) = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array()
private fun z(s: String) = s.toByteArray(Charsets.UTF_8) + 0

/**
 * The Zepp OS session and the endpoints the phone app uses: settings (all of them,
 * the unnamed ones too), battery, device info, alarms, faces, find. The PC's daemon
 * (scripts/amazfit) has the rest. [write] sends a chunk to a characteristic.
 */
class Zepp(private val catalog: Catalog, private val write: (String, ByteArray) -> Unit, private val onState: (WatchState) -> Unit) {
	private val encoder = Encoder()
	private val decoder = Decoder()
	private var key: ByteArray? = null
	private var private = ByteArray(Ecdh.KEY_BYTES)
	var state = WatchState()
		private set
	val events = ZeppEvents()
	private var notifyCaps = 0
	private var notifyPictures = false
	private var notifyKey = false
	private var encrypted = setOf(0x000a, 0x000f, 0x0023)
	private var proved = false

	private fun set(next: WatchState) {
		state = next
		onState(next)
	}

	fun mtu(value: Int) {
		encoder.mtu = value
	}

	fun start(authKey: ByteArray?) {
		encoder.reset(); decoder.reset(); decoder.session = null
		key = authKey
		proved = false
		if (authKey == null) return set(state.copy(link = "nokey"))
		val random = SecureRandom()
		var pub: ByteArray?
		do {
			random.nextBytes(private)
			pub = Ecdh.publicKey(private)
		} while (pub == null)
		set(state.copy(link = "handshake"))
		raw(0x0082, byteArrayOf(0x04, 0x02, 0x00, 0x02) + pub, false)
	}

	private fun raw(endpoint: Int, payload: ByteArray, encrypt: Boolean) {
		for (c in encoder.chunks(endpoint, payload, encrypt)) write(Chunked.WRITE, c)
	}

	fun send(endpoint: Int, payload: ByteArray) {
		if (state.link == "ready") raw(endpoint, payload, endpoint in encrypted)
	}

	fun feed(uuid: String, data: ByteArray) {
		if (uuid != Chunked.READ) return
		val (ack, message) = decoder.feed(data)
		if (ack != null) write(Chunked.READ, ack)
		val (endpoint, p) = message ?: return
		if (endpoint == 0x0082) auth(p) else if (state.link == "ready") runCatching { handle(endpoint, p) }
	}

	private fun auth(p: ByteArray) {
		if (p.size < 3 || p[0].toInt() != 0x10) return
		when (p[1].toInt()) {
			0x04 -> {
				if (proved || state.link != "handshake") return  // the same answer again
				if (p[2].toInt() != 1 || p.size < 67) return set(state.copy(link = "failed", detail = "public key refused"))
				val k = key ?: return
				val shared = Ecdh.sharedSecret(private, p.copyOfRange(19, 67)) ?: return set(state.copy(link = "failed", detail = "the watch's key is not on B-163"))
				val session = ByteArray(16) { (shared[8 + it].toInt() xor k[it].toInt()).toByte() }
				encoder.session = session
				encoder.sequence = ByteBuffer.wrap(shared, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
				decoder.session = session
				val r = p.copyOfRange(3, 19)
				proved = true
				raw(0x0082, byteArrayOf(0x05) + Chunked.aes(k, r) + Chunked.aes(session, r), false)
			}
			0x05 -> if (state.link == "handshake") when (p[2].toInt() and 0xFF) {
				0x01 -> {
					set(state.copy(link = "ready", detail = ""))
					raw(0x0000, byteArrayOf(0x03), false)
				}
				0x25 -> set(state.copy(link = "wrongkey"))
				else -> set(state.copy(link = "failed", detail = "session refused"))
			}
		}
	}

	private fun handle(endpoint: Int, p: ByteArray) {
		when (endpoint) {
			0x0000 -> if (p[0].toInt() == 0x04) {
				val r = Reader(p, 1)
				val n = r.s16()
				val services = (0 until n).associate { r.s16() and 0xFFFF to (r.u8() == 1) }
				encrypted = services.filterValues { it }.keys
				set(state.copy(services = services))
				init()
			}
			0x000a -> config(p)
			0x0029 -> if (p[0].toInt() == 0x04 && p.size >= 21) set(state.copy(battery = p[2].toInt(), charging = p[3].toInt() == 1))
			0x0043 -> if (p[0].toInt() == 0x02 && p[1].toInt() == 1) {
				val r = Reader(p, 2)
				val flags = r.s64()
				val info = LinkedHashMap<String, String>()
				if (flags and 1L != 0L) { val skip = r.u8(); r.i += skip }
				if (flags and 2L != 0L) info["serial"] = r.cstr()
				if (flags and 4L != 0L) info["hardware"] = r.cstr()
				if (flags and 8L != 0L) info["firmware"] = r.cstr()
				set(state.copy(info = info))
			}
			0x000f -> when (p[0].toInt()) {
				0x0a -> {
					val n = p[1].toInt()
					val alarms = (0 until n).map { k ->
						val o = 2 + k * 10
						val f = p[o].toInt()
						// the watch marks a smart one with 0x02 and keeps the window in the entry's last byte
						val window = if (f and 0x02 != 0) p[o + 9].toInt() and 0xFF else 0
						Alarm(p[o + 1].toInt(), f and 0x04 != 0, window > 0, p[o + 2].toInt(), p[o + 3].toInt(), p[o + 4].toInt() and 0xFF, window)
					}.sortedBy { it.position }
					set(state.copy(alarms = alarms))
				}
				0x04, 0x06, 0x08, 0x0f -> send(0x000f, byteArrayOf(0x09))
			}
			0x0023 -> when (p[0].toInt() and 0xFF) {
				0x06 -> if (p[1].toInt() == 1) {
					val r = Reader(p, 3)
					set(state.copy(faces = (0 until (p[2].toInt() and 0xFF)).map { "%08X".format(r.s32()) }))
				}
				0x0a -> set(state.copy(face = "%08X".format(Reader(p, 1).s32())))
				0x08, 0xff -> send(0x0023, byteArrayOf(0x09))
			}
			0x001a -> when (p[0].toInt()) {
				0x11 -> { send(0x001a, byteArrayOf(0x12, 0x01)); events.findPhone(true) }
				0x13 -> events.findPhone(false)
				0x07 -> set(state.copy(finding = false))
			}
			0x004b -> events.fetchControl(p)
			0x001b -> when (p[0].toInt()) {
				0x04 -> { set(state.copy(musicOpen = p[1].toInt() == 1)); events.musicOpen(p[1].toInt() == 1) }
				0x05 -> events.button(when (p[1].toInt()) { 0 -> "play"; 1 -> "pause"; 3 -> "next"; 4 -> "previous"; 5 -> "volup"; 6 -> "voldown"; else -> "?" })
			}
			0x001e -> when (p[0].toInt()) {
				0x02 -> {
					notifyCaps = p[1].toInt()
					if (notifyCaps >= 5 && p.size >= 9) {
						val r = Reader(p, 2); r.s16(); r.u8()
						if (r.u8() != 0) r.i += r.s16()
						if (r.left() >= 2) { notifyPictures = r.u8() != 0; notifyKey = r.u8() != 0 }
					}
				}
				0x04 -> {
					val id = ByteBuffer.wrap(p, 1, 4).order(ByteOrder.LITTLE_ENDIAN).int
					events.reply(id, Reader(p, 5).cstr())
					send(0x001e, byteArrayOf(0x06) + le32(id) + ByteArray(4))
				}
				0x05 -> when (p[1].toInt()) {
					0x03 -> events.dismiss(ByteBuffer.wrap(p, 2, 4).order(ByteOrder.LITTLE_ENDIAN).int)
					0x02 -> events.callAction("mute")
					0x01 -> events.callAction("reject")
				}
				0x10 -> send(0x001e, byteArrayOf(0x11) + z(Reader(p, 1).cstr()) + 0)   // icons need file transfer: the watch shows its own
			}
			0x0001 -> if (p[0].toInt() == 0x01) {
				val r = Reader(p, 1)
				val id = r.u8(); r.cstr()
				events.http(id, r.cstr())
			}
			0x003b -> if (p[0].toInt() == 0x05) send(0x003b, byteArrayOf(0x03, 0x00))
		}
	}

	private fun init() {
		val s = state.services
		if (0x0047 in s) send(0x0047, byteArrayOf(0x05) + TimeBytes.now())
		if (0x0043 in s) send(0x0043, byteArrayOf(0x01))
		if (0x0029 in s) send(0x0029, byteArrayOf(0x03))
		if (0x000a in s) send(0x000a, byteArrayOf(0x01))
		if (0x000f in s) send(0x000f, byteArrayOf(0x09))
		if (0x0023 in s) { send(0x0023, byteArrayOf(0x05)); send(0x0023, byteArrayOf(0x09)) }
		if (0x001a in s) send(0x001a, byteArrayOf(0x01))
		if (0x001e in s) send(0x001e, byteArrayOf(0x01))
		events.ready()
	}

	private fun config(p: ByteArray) {
		when (p[0].toInt()) {
			0x02 -> for (i in 0 until (p[2].toInt() and 0xFF)) {
				val g = p[3 + i].toInt() and 0xFF
				val known = catalog.args.filter { catalog.groups[it.group]?.first == g }.map { it.code.toByte() }
				send(0x000a, byteArrayOf(0x03, 0x01, g.toByte(), known.size.toByte()) + known.toByteArray())
				send(0x000a, byteArrayOf(0x03, 0x01, g.toByte(), 0x00))
			}
			0x04 -> if (p.size > 5 && p[1].toInt() == 1) {
				val gid = p[2].toInt() and 0xFF
				val version = p[3].toInt()
				val constraints = p[4].toInt() == 1
				val count = p[5].toInt() and 0xFF
				val r = Reader(p, 6)
				val name = catalog.groupName(gid)
				val entries = LinkedHashMap(state.config[name]?.entries ?: emptyMap())
				var n = 0
				while (r.left() > 1 && n <= count) {
					val code = r.u8()
					val type = catalog.typeName(r.u8()) ?: break
					val e: Entry = when (type) {
						"bool" -> Entry(code, type, r.u8() == 1)
						"string" -> Entry(code, type, r.cstr(), maxLength = if (constraints) r.u8() else null)
						"strings" -> {
							val v = r.cstr()
							if (constraints) { val ml = r.u8(); Entry(code, type, v, maxLength = ml, allowed = (0 until r.u8()).map { r.cstr() }) } else Entry(code, type, v)
						}
						"short" -> { val v = r.s16(); if (constraints) Entry(code, type, v, r.s16().toLong(), r.s16().toLong()) else Entry(code, type, v) }
						"int" -> { val v = r.s32(); if (constraints) Entry(code, type, v, r.s32().toLong(), r.s32().toLong()) else Entry(code, type, v) }
						"byte" -> { val v = r.u8(); if (constraints) Entry(code, type, v, allowed = (0 until r.u8()).map { r.u8() }) else Entry(code, type, v) }
						"bytes" -> { val v = (0 until r.u8()).map { r.u8() }; if (constraints) Entry(code, type, v, allowed = (0 until r.u8()).map { r.u8() }) else Entry(code, type, v) }
						"shorts" -> {
							val v = (0 until r.u8()).map { r.s16() }
							if (constraints) { r.u8(); r.u8(); Entry(code, type, v, r.s16().toLong(), r.s16().toLong()) } else Entry(code, type, v)
						}
						"hhmm" -> Entry(code, type, "%02d:%02d".format(r.u8(), r.u8()))
						"millis" -> Entry(code, type, r.s64())
						"intu" -> Entry(code, type, r.s32().toLong() and 0xFFFFFFFFL)
						else -> break
					}
					entries[code] = e
					n++
				}
				val config = LinkedHashMap(state.config)
				config[name] = Group(name, gid, version, entries)
				set(state.copy(config = config))
			}
		}
	}

	/** Every setting's value now, by "gg/cc". */
	fun values(): Map<String, Any?> = state.config.values.flatMap { g -> g.entries.values.map { "%02x/%02x".format(g.id, it.code) to it.value } }.toMap()

	/** Asks every group again for all it has (the answers update [state]). */
	fun reread() {
		for (g in state.config.values) send(0x000a, byteArrayOf(0x03, 0x01, g.id.toByte(), 0x00))
	}

	// ── what the screen asks ──────────────────────────────────────────────
	fun setSetting(group: String, code: Int, value: Any) {
		val g = state.config[group] ?: return
		val e = g.entries[code] ?: return
		val t = catalog.types[e.type] ?: return
		val bytes: ByteArray = when (e.type) {
			"bool" -> byteArrayOf(if (value == true) 1 else 0)
			"string", "strings" -> z(value.toString())
			"short" -> le16((value as Number).toInt())
			"int" -> le32((value as Number).toInt())
			"byte" -> byteArrayOf((value as Number).toByte())
			"bytes" -> (value as List<*>).map { (it as Number).toByte() }.let { byteArrayOf(it.size.toByte()) + it.toByteArray() }
			"hhmm" -> value.toString().split(":").let { byteArrayOf(it[0].toInt().toByte(), it[1].toInt().toByte()) }
			else -> return
		}
		send(0x000a, byteArrayOf(0x05, g.id.toByte(), g.version.toByte(), 0x00, 0x01, code.toByte(), t.toByte()) + bytes)
		val entries = LinkedHashMap(g.entries)
		entries[code] = e.copy(value = value)
		val config = LinkedHashMap(state.config)
		config[group] = g.copy(entries = entries)
		set(state.copy(config = config))
	}

	fun setAlarm(a: Alarm) {
		// the watch takes windows of 10–50 minutes (anything else it keeps as 70) and marks them 0x02 itself
		val window = if (a.smart) listOf(10, 20, 30, 40, 50).minByOrNull { kotlin.math.abs(it - (if (a.window > 0) a.window else 30)) }!! else 0
		val flags = (if (a.enabled) 0x04 else 0) or (if (window > 0) 0x02 else 0)
		send(0x000f, byteArrayOf(0x03, 0x01, flags.toByte(), a.position.toByte(), a.hour.toByte(), a.minute.toByte(), a.repeat.toByte(), 0, 0, 0, 0, window.toByte()))
	}

	fun supports(endpoint: Int) = endpoint in state.services

	fun notify(id: Int, title: String, body: String, app: String, source: String, reply: Boolean, sms: Boolean = false) {
		var out = byteArrayOf(0x03) + le32(id) + byteArrayOf(if (sms) 0x05 else 0xFA.toByte(), 0x00) + z(app) + z(title) + z(body.take(512)) + z(source) + byteArrayOf(if (reply) 1 else 0)
		if (notifyCaps >= 5) out += 0
		if (notifyPictures) out += 0
		if (notifyKey) out += 0
		send(0x001e, out)
	}

	fun unnotify(id: Int) = send(0x001e, byteArrayOf(0x03) + le32(id) + byteArrayOf(0xFA.toByte(), 0x02, 0, 0, 0, 0, 0))

	fun call(name: String, number: String, ringing: Boolean) =
		send(0x001e, byteArrayOf(0x03) + le32(0) + byteArrayOf(0x03, if (ringing) 0x00 else 0x02, 0x00) + z(name) + byteArrayOf(0, 0) + z(number) + byteArrayOf(if (number.isNotEmpty()) 1 else 0))

	fun music(playing: Boolean?, artist: String, album: String, track: String, position: Int, duration: Int, volume: Int?) {
		var flags = 0
		var body = ByteArray(0)
		if (playing != null) { flags = flags or 0x01; body += byteArrayOf(if (playing) 1 else 0, 0) + le16(position) }
		for ((bit, text) in listOf(0x02 to artist, 0x04 to album, 0x08 to track)) if (text.isNotEmpty()) { flags = flags or bit; body += z(text.take(80)) }
		if (duration > 0) { flags = flags or 0x10; body += le16(duration) }
		if (volume != null) { flags = flags or 0x40; body += byteArrayOf(volume.coerceIn(0, 100).toByte()) }
		if (playing == null && artist.isEmpty() && track.isEmpty()) { flags = flags or 0x20; body += 1 }
		send(0x001b, byteArrayOf(0x03, flags.toByte()) + body)
	}

	fun foundPhone() = send(0x001a, byteArrayOf(0x14))

	fun httpReply(id: Int, status: Int, body: String?) {
		if (body == null) return send(0x0001, byteArrayOf(0x02, id.toByte(), 0x02, 0, 0, 0, 0))
		val data = body.toByteArray()
		send(0x0001, byteArrayOf(0x02, id.toByte(), 0x01, status.toByte()) + le32(data.size) + data)
	}

	fun weatherLocation(lat: Double, lon: Double, name: String) =
		send(0x000e, byteArrayOf(0x09, 0x02, 0, 0, 0) + z("%.4f,%.4f,xiaomi_accu:%d".format(java.util.Locale.ROOT, lat, lon, System.currentTimeMillis() / 1000 % 65536)) + z(name))

	fun fetching(on: Boolean) = set(state.copy(fetching = on, fetchedAt = if (on) state.fetchedAt else System.currentTimeMillis()))

	fun sendFetch(payload: ByteArray) = send(0x004b, payload)

	fun deleteAlarm(position: Int) = send(0x000f, byteArrayOf(0x05, 0x01, position.toByte()))

	fun setFace(id: String) = send(0x0023, byteArrayOf(0x07) + le32(id.toLong(16).toInt()))

	fun find(on: Boolean) {
		send(0x001a, byteArrayOf(if (on) 0x03 else 0x06))
		set(state.copy(finding = on))
	}

	fun gone(link: String = "gone") = set(state.copy(link = link))
	fun named(name: String) = set(state.copy(name = name))
	fun linkState(link: String, detail: String = "") = set(state.copy(link = link, detail = detail))
}

object TimeBytes {
	/** The current time as Zepp OS takes it: GATT Current Time plus DST flag and offset in quarter hours. */
	fun now(): ByteArray {
		val c = java.util.Calendar.getInstance()
		val tz = c.timeZone
		val buf = ByteBuffer.allocate(11).order(ByteOrder.LITTLE_ENDIAN)
		buf.putShort(c.get(java.util.Calendar.YEAR).toShort())
		buf.put((c.get(java.util.Calendar.MONTH) + 1).toByte())
		buf.put(c.get(java.util.Calendar.DAY_OF_MONTH).toByte())
		buf.put(c.get(java.util.Calendar.HOUR_OF_DAY).toByte())
		buf.put(c.get(java.util.Calendar.MINUTE).toByte())
		buf.put(c.get(java.util.Calendar.SECOND).toByte())
		buf.put((c.get(java.util.Calendar.DAY_OF_WEEK) - 1).toByte())
		buf.put((c.get(java.util.Calendar.MILLISECOND) * 256 / 1000).toByte())
		buf.put(if (tz.inDaylightTime(c.time)) 0x08 else 0x00)
		buf.put((tz.getOffset(c.timeInMillis) / 900000).toByte())
		return buf.array()
	}
}
