package dev.pshell.app.zepp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/** The phone's Zepp OS code against what scripts/amazfit/zepp (Python) gives for the same input. */
class ZeppTest {
	private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
	private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

	@Test
	fun ecdhMatchesThePc() {
		val p1 = ByteArray(24) { (it + 1).toByte() }
		val p2 = ByteArray(24) { (it + 100).toByte() }
		assertEquals("a1e4ad02c2a44ea24152962c140ea063c69b2e5c07000000cd5073a06d67b78a3bc5f519ab85fb9cf5855dc801000000", Ecdh.publicKey(p1)!!.hex())
		val shared = Ecdh.sharedSecret(p1, Ecdh.publicKey(p2)!!)!!
		assertEquals("e560260ec1f65732411c74882df85c51c78d3a5101000000739578dab2848fe39d4d59472218c4bc43ad669e03000000", shared.hex())
		assertArrayEquals(shared, Ecdh.sharedSecret(p2, Ecdh.publicKey(p1)!!))
	}

	@Test
	fun chunksMatchThePc() {
		val e = Encoder(23).apply { session = ByteArray(16) { it.toByte() }; sequence = 0x11223344 }
		val chunks = e.chunks(0x0a, ByteArray(30) { it.toByte() }, true)
		assertEquals(
			"03090001001e0000000a0033c8a99ded06a1439b,03080001015f654efeae3307668c126f5b65b77d,03080001023e953fc3e0f22caa855db845db72af,030e000103781175381bbedb7c81",
			chunks.joinToString(",") { it.hex() },
		)
		val d = Decoder().apply { session = ByteArray(16) { it.toByte() } }
		var got: Pair<Int, ByteArray>? = null
		for (c in chunks) got = d.feed(c).second ?: got
		assertEquals(0x0a, got!!.first)
		assertArrayEquals(ByteArray(30) { it.toByte() }, got.second)
	}

	@Test
	fun plainRoundTrip() {
		val e = Encoder(247)
		val d = Decoder()
		val data = ByteArray(700) { (it * 7).toByte() }
		var got: Pair<Int, ByteArray>? = null
		for (c in e.chunks(0x1234, data, false)) got = d.feed(c).second ?: got
		assertEquals(0x1234, got!!.first)
		assertArrayEquals(data, got.second)
		assertArrayEquals(hex("030700010001000000000003"), Encoder(23).chunks(0, byteArrayOf(3), false)[0])
	}
}
