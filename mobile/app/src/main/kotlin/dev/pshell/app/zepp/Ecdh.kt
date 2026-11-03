package dev.pshell.app.zepp

import java.math.BigInteger

/**
 * ECDH on NIST B-163 (sect163r2), as Zepp OS authenticates (scripts/amazfit/zepp/ecdh.py
 * is the same on the PC). Keys are laid out as tiny-ECDH does: 24 bytes private,
 * 48 public (x then y), little endian.
 */
object Ecdh {
	private const val DEGREE = 163
	private val POLY = BigInteger.ONE.shiftLeft(163).or(BigInteger.ONE.shiftLeft(7)).or(BigInteger.ONE.shiftLeft(6)).or(BigInteger.ONE.shiftLeft(3)).or(BigInteger.ONE)
	private val B = BigInteger("20A601907B8C953CA1481EB10512F78744A3205FD", 16)
	private val GX = BigInteger("3F0EBA16286A2D57EA0991168D4994637E8343E36", 16)
	private val GY = BigInteger("0D51FBC6C71A0094FA2CDD545B11C5C0C797324F1", 16)
	private val ORDER = BigInteger("40000000000000000000292FE77E70C12A4234C33", 16)
	const val KEY_BYTES = 24

	private fun mul(a0: BigInteger, b0: BigInteger): BigInteger {
		var a = a0
		var b = b0
		var r = BigInteger.ZERO
		while (b.signum() != 0) {
			if (b.testBit(0)) r = r.xor(a)
			b = b.shiftRight(1)
			a = a.shiftLeft(1)
			if (a.testBit(DEGREE)) a = a.xor(POLY)
		}
		return r
	}

	private fun inv(a: BigInteger): BigInteger {
		var u = a
		var v = POLY
		var g1 = BigInteger.ONE
		var g2 = BigInteger.ZERO
		while (u != BigInteger.ONE) {
			var j = u.bitLength() - v.bitLength()
			if (j < 0) {
				val t = u; u = v; v = t
				val s = g1; g1 = g2; g2 = s
				j = -j
			}
			u = u.xor(v.shiftLeft(j))
			g1 = g1.xor(g2.shiftLeft(j))
		}
		return g1
	}

	private class P(val x: BigInteger, val y: BigInteger)

	private fun double(p: P?): P? {
		if (p == null || p.x.signum() == 0) return null
		val lam = p.x.xor(mul(p.y, inv(p.x)))
		val x3 = mul(lam, lam).xor(lam).xor(BigInteger.ONE)
		return P(x3, mul(p.x, p.x).xor(mul(lam, x3)).xor(x3))
	}

	private fun add(p: P?, q: P?): P? {
		if (p == null) return q
		if (q == null) return p
		if (p.x == q.x) return if (p.y == q.y) double(p) else null
		val lam = mul(p.y.xor(q.y), inv(p.x.xor(q.x)))
		val x3 = mul(lam, lam).xor(lam).xor(p.x).xor(q.x).xor(BigInteger.ONE)
		return P(x3, mul(lam, p.x.xor(x3)).xor(x3).xor(p.y))
	}

	private fun scalar(k: BigInteger, p: P): P? {
		var r: P? = null
		for (i in k.bitLength() - 1 downTo 0) {
			r = double(r)
			if (k.testBit(i)) r = add(r, p)
		}
		return r
	}

	private fun le(bytes: ByteArray, from: Int, len: Int): BigInteger {
		val be = ByteArray(len + 1)
		for (i in 0 until len) be[len - i] = bytes[from + i]
		return BigInteger(be)
	}

	private fun toLe(v: BigInteger): ByteArray {
		val out = ByteArray(KEY_BYTES)
		val be = v.toByteArray()
		for (i in be.indices) {
			val at = be.size - 1 - i
			if (i < KEY_BYTES) out[i] = be[at]
		}
		return out
	}

	private fun scalarOf(private: ByteArray): BigInteger = le(private, 0, KEY_BYTES).and(BigInteger.ONE.shiftLeft(ORDER.bitLength() - 1).subtract(BigInteger.ONE))

	private fun bytes(p: P): ByteArray = toLe(p.x) + toLe(p.y)

	fun publicKey(private: ByteArray): ByteArray? {
		if (le(private, 0, KEY_BYTES).bitLength() < DEGREE / 2) return null
		return scalar(scalarOf(private), P(GX, GY))?.let(::bytes)
	}

	fun sharedSecret(private: ByteArray, remote: ByteArray): ByteArray? {
		val x = le(remote, 0, KEY_BYTES)
		val y = le(remote, KEY_BYTES, KEY_BYTES)
		if (x.signum() == 0 && y.signum() == 0) return null
		if (mul(y, y).xor(mul(x, y)) != mul(mul(x, x), x).xor(mul(x, x)).xor(B)) return null
		return scalar(scalarOf(private), P(x, y))?.let(::bytes)
	}
}
