package dev.pshell.app.zepp

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Calendar
import java.util.TimeZone
import java.util.zip.CRC32

/**
 * What the watch measured, over Zepp OS (endpoint 0x004B controls, characteristic
 * 0x0005 carries the data) – the same as scripts/amazfit/zepp/fetch.py. The data
 * is acked with 0x09: it stays on the watch, so the PC gets it as well.
 */
class Fetcher(private val send: (ByteArray) -> Unit, private val done: (String, List<JSONObject>) -> Unit, private val finished: () -> Unit) {
	companion object {
		const val DATA = "00000005-0000-3512-2118-0009af100700"
		const val ENDPOINT = 0x004B
		val TYPES = linkedMapOf(
			"activity" to 0x01, "heart_manual" to 0x02, "pai" to 0x0D, "stress" to 0x13, "spo2" to 0x25,
			"temperature" to 0x2E, "breathing" to 0x38, "resting" to 0x3A, "heart_max" to 0x3D, "sleep" to 0x48, "hrv" to 0x49,
		)

		fun timeBytes(epoch: Long): ByteArray {
			val c = Calendar.getInstance().apply { timeInMillis = epoch * 1000 }
			val b = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
			b.putShort(c.get(Calendar.YEAR).toShort()).put((c.get(Calendar.MONTH) + 1).toByte()).put(c.get(Calendar.DAY_OF_MONTH).toByte())
				.put(c.get(Calendar.HOUR_OF_DAY).toByte()).put(c.get(Calendar.MINUTE).toByte()).put(0)
				.put((c.timeZone.getOffset(c.timeInMillis) / 900000).toByte())
			return b.array()
		}

		fun parseTime(p: ByteArray, at: Int): Long {
			val b = ByteBuffer.wrap(p, at, 8).order(ByteOrder.LITTLE_ENDIAN)
			val c = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
			c.clear()
			c.set(b.short.toInt(), b.get() - 1, b.get().toInt(), b.get().toInt(), b.get().toInt(), b.get().toInt())
			return c.timeInMillis / 1000 - b.get() * 900L
		}

		private fun o(vararg pairs: Pair<String, Any>) = JSONObject().apply { pairs.forEach { put(it.first, it.second) } }

		fun parse(kind: String, start: Long, d: ByteArray): List<JSONObject> {
			val b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN)
			val u = { i: Int -> d[i].toInt() and 0xFF }
			val out = ArrayList<JSONObject>()
			when (kind) {
				"activity" -> for (i in 0 until d.size - 7 step 8) out.add(o("t" to start + i / 8 * 60, "k" to u(i), "i" to u(i + 1), "s" to u(i + 2), "h" to u(i + 3), "sl" to u(i + 5), "d" to u(i + 6), "r" to u(i + 7)))
				"stress" -> for (i in d.indices) if (u(i) != 0xFF) out.add(o("t" to start + i * 60L, "v" to u(i)))
				"temperature" -> for (i in 0 until d.size - 7 step 8) {
					val v = b.getShort(i + 2).toInt()
					if (v in -999..5999 && v != 0) out.add(o("t" to start + i / 8 * 60, "v" to v / 100.0))
				}
				"spo2" -> if (d.isNotEmpty() && d[0].toInt() == 2) for (i in 1 until d.size - 64 step 65) {
					val raw = d[i + 4].toInt()
					out.add(o("t" to (b.getInt(i).toLong() and 0xFFFFFFFFL), "v" to if (raw < 0) raw + 128 else raw))
				}
				"resting", "heart_manual", "heart_max", "hrv" -> for (i in 0 until d.size - 5 step 6) out.add(o("t" to (b.getInt(i).toLong() and 0xFFFFFFFFL), "v" to u(i + 5)))
				"breathing" -> for (i in 0 until d.size - 7 step 8) out.add(o("t" to (b.getInt(i).toLong() and 0xFFFFFFFFL), "v" to u(i + 5)))
				"pai" -> for (i in 0 until d.size - 101 step 102) {
					if (u(i) != 5) continue
					out.add(o("t" to (b.getInt(i + 1).toLong() and 0xFFFFFFFFL), "low" to b.getFloat(i + 37), "mod" to b.getFloat(i + 41), "high" to b.getFloat(i + 45),
						"minLow" to b.getShort(i + 49).toInt(), "minMod" to b.getShort(i + 51).toInt(), "minHigh" to b.getShort(i + 53).toInt(),
						"today" to b.getFloat(i + 55), "total" to b.getFloat(i + 59)))
				}
				"sleep" -> for (i in 0 until d.size - 593 step 594) out.add(sleepSession(d.copyOfRange(i, i + 594)))
			}
			return out
		}

		fun sleepSession(s: ByteArray): JSONObject {
			val b = ByteBuffer.wrap(s).order(ByteOrder.LITTLE_ENDIAN)
			val base = (b.getInt(4).toLong() and 0xFFFFFFFFL) - 86400
			val stages = org.json.JSONArray()
			for (n in 0 until (s[0x54].toInt() and 0xFF)) {
				val a = b.getShort(0x56 + 5 * n).toInt() and 0xFFFF
				val e = b.getShort(0x58 + 5 * n).toInt() and 0xFFFF
				val kind = when (s[0x5A + 5 * n].toInt()) { 5 -> "deep"; 8 -> "rem"; 7 -> "wake"; else -> "light" }
				stages.put(org.json.JSONArray().put(kind).put(base + a * 60).put(base + (e + 1) * 60))
			}
			return o("t" to (b.getInt(0).toLong() and 0xFFFFFFFFL), "bed" to base + (b.getShort(0x0A).toInt() and 0xFFFF) * 60,
				"wake" to base + ((b.getShort(0x0C).toInt() and 0xFFFF) + 1) * 60, "avgHr" to (s[0x15].toInt() and 0xFF), "score" to (s[0x16].toInt() and 0xFF),
				"stages" to stages, "rem" to (b.getShort(0x24A).toInt() and 0xFFFF), "light" to (b.getShort(0x24C).toInt() and 0xFFFF),
				"deep" to (b.getShort(0x24E).toInt() and 0xFFFF), "awake" to (b.getShort(0x250).toInt() and 0xFFFF))
		}
	}

	private class Current(val kind: String, val since: Long) {
		val buf = java.io.ByteArrayOutputStream()
		var counter = -1
		var ok = true
		var start = 0L
	}

	private val queue = ArrayDeque<Pair<String, Long>>()
	private val rounds = HashMap<String, Int>()
	private var current: Current? = null
	val busy get() = current != null

	fun start(since: Map<String, Long>) {
		queue.clear(); rounds.clear()
		val now = System.currentTimeMillis() / 1000
		for (k in TYPES.keys) queue.add(k to (since[k] ?: (now - 30 * 86400)))
		next()
	}

	private fun next() {
		val (kind, since) = queue.removeFirstOrNull() ?: run { current = null; finished(); return }
		current = Current(kind, since)
		send(byteArrayOf(0x01, TYPES[kind]!!.toByte()) + timeBytes(since))
	}

	fun onData(v: ByteArray) {
		val c = current ?: return
		if (v.isEmpty()) return
		if ((c.counter + 1) and 0xFF == (v[0].toInt() and 0xFF)) {
			c.counter = v[0].toInt() and 0xFF
			c.buf.write(v, 1, v.size - 1)
		} else c.ok = false
	}

	fun onControl(p: ByteArray) {
		val c = current ?: return
		if (p.size < 3 || p[0].toInt() != 0x10) return
		when (p[1].toInt()) {
			0x01 -> {
				if (p[2].toInt() != 1) return next()
				val length = ByteBuffer.wrap(p, 3, 4).order(ByteOrder.LITTLE_ENDIAN).int
				c.start = parseTime(p, 7)
				send(if (length == 0) byteArrayOf(0x03, 0x09) else byteArrayOf(0x02))
			}
			0x02 -> {
				val data = c.buf.toByteArray()
				val crcOk = p.size < 7 || ByteBuffer.wrap(p, 3, 4).order(ByteOrder.LITTLE_ENDIAN).int == CRC32().apply { update(data) }.value.toInt()
				val samples = if (c.ok && crcOk) parse(c.kind, c.start, data) else emptyList()
				send(byteArrayOf(0x03, 0x09))
				if (samples.isNotEmpty()) done(c.kind, samples)
				val until = samples.maxOfOrNull { it.getLong("t") } ?: 0
				val n = (rounds[c.kind] ?: 0) + 1
				rounds[c.kind] = n
				if (samples.isNotEmpty() && until + 60 < System.currentTimeMillis() / 1000 - 120 && n < 10 && until > c.since) queue.addFirst(c.kind to until + 60)
			}
			0x03 -> next()
		}
	}
}
