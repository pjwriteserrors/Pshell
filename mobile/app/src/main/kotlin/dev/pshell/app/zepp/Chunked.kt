package dev.pshell.app.zepp

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

/** Zepp OS's chunked transport over 0x0016 (to the watch) and 0x0017 (from it); see scripts/amazfit/zepp/chunked.py. */
object Chunked {
	const val WRITE = "00000016-0000-3512-2118-0009af100700"
	const val READ = "00000017-0000-3512-2118-0009af100700"

	fun aes(key: ByteArray, data: ByteArray, decrypt: Boolean = false): ByteArray {
		val c = Cipher.getInstance("AES/ECB/NoPadding")
		c.init(if (decrypt) Cipher.DECRYPT_MODE else Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
		return c.doFinal(data)
	}

	fun padded(n: Int): Int {
		val m = n + 8
		return m + ((16 - m % 16) % 16)
	}

	fun keyFor(session: ByteArray, handle: Int) = ByteArray(16) { (session[it].toInt() xor handle).toByte() }
}

class Encoder(var mtu: Int = 23) {
	private var handle = 0
	var sequence = 0
	var session: ByteArray? = null

	fun reset() {
		handle = 0; sequence = 0; session = null
	}

	fun chunks(endpoint: Int, data: ByteArray, encrypt: Boolean): List<ByteArray> {
		val key = session
		require(!encrypt || key != null) { "no session key yet" }
		handle = (handle + 1) and 0xFF
		val body: ByteArray = if (encrypt) {
			val buf = ByteBuffer.allocate(Chunked.padded(data.size)).order(ByteOrder.LITTLE_ENDIAN)
			buf.put(data); buf.putInt(sequence++)
			val crc = CRC32().apply { update(buf.array(), 0, data.size + 4) }
			buf.putInt(crc.value.toInt())
			Chunked.aes(Chunked.keyFor(key!!, handle), buf.array())
		} else data
		val room = minOf(512, maxOf(23, mtu) - 3)
		val out = ArrayList<ByteArray>()
		var pos = 0
		var count = 0
		var header = 11
		while (true) {
			val take = minOf(body.size - pos, room - header)
			var flags = if (encrypt) 0x08 else 0
			if (count == 0) flags = flags or 0x01
			val last = pos + take >= body.size
			if (last) flags = flags or 0x06
			val buf = ByteBuffer.allocate(header + take).order(ByteOrder.LITTLE_ENDIAN)
			buf.put(0x03).put(flags.toByte()).put(0).put(handle.toByte()).put(count.toByte())
			if (count == 0) buf.putInt(data.size).putShort(endpoint.toShort())
			buf.put(body, pos, take)
			out.add(buf.array())
			pos += take; count++; header = 5
			if (last) break
		}
		return out
	}
}

class Decoder {
	var session: ByteArray? = null
	private var handle = -1
	private var endpoint = 0
	private var length = 0
	private var buffer = java.io.ByteArrayOutputStream()

	fun reset() {
		handle = -1; endpoint = 0; length = 0; buffer = java.io.ByteArrayOutputStream()
	}

	/** (ack or null, (endpoint, payload) or null) */
	fun feed(data: ByteArray): Pair<ByteArray?, Pair<Int, ByteArray>?> {
		if (data.size < 5 || data[0].toInt() != 0x03) return null to null
		val flags = data[1].toInt()
		val encrypted = flags and 0x08 != 0
		val h = data[3].toInt() and 0xFF
		val count = data[4]
		var i = 5
		if (handle >= 0 && h != handle && flags and 0x01 == 0) return null to null
		if (flags and 0x01 != 0) {
			val b = ByteBuffer.wrap(data, 5, 6).order(ByteOrder.LITTLE_ENDIAN)
			length = b.int; endpoint = b.short.toInt() and 0xFFFF
			i = 11; handle = h; buffer = java.io.ByteArrayOutputStream()
		}
		buffer.write(data, i, data.size - i)
		val ack = if (flags and 0x04 != 0) byteArrayOf(0x04, 0x00, h.toByte(), 0x01, count) else null
		if (flags and 0x02 == 0) return ack to null
		var payload = buffer.toByteArray()
		val ep = endpoint
		val len = length
		reset()
		if (encrypted) {
			val key = session ?: return ack to null
			if (payload.size % 16 != 0) return ack to null
			payload = Chunked.aes(Chunked.keyFor(key, h), payload, decrypt = true).copyOf(len)
		}
		return ack to (ep to payload)
	}
}
