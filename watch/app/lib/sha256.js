// SHA-256 and HMAC-SHA-256 over byte arrays, small enough for the watch.
// An HMAC key is absorbed once (hmacKey) and its two states reused for every
// frame of a session, so a frame costs two or three compressions.

const K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]
const INIT = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
const W = new Array(64)

function compress(h, block, at) {
  for (let i = 0; i < 16; i++) {
    const j = at + i * 4
    W[i] = ((block[j] << 24) | (block[j + 1] << 16) | (block[j + 2] << 8) | block[j + 3]) | 0
  }
  for (let i = 16; i < 64; i++) {
    const a = W[i - 15]
    const b = W[i - 2]
    const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3)
    const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10)
    W[i] = (W[i - 16] + s0 + W[i - 7] + s1) | 0
  }
  let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7]
  for (let i = 0; i < 64; i++) {
    const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))
    const t1 = (k + S1 + ((e & f) ^ (~e & g)) + K[i] + W[i]) | 0
    const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))
    const t2 = (S0 + ((a & b) ^ (a & c) ^ (b & c))) | 0
    k = g
    g = f
    f = e
    e = (d + t1) | 0
    d = c
    c = b
    b = a
    a = (t1 + t2) | 0
  }
  h[0] = (h[0] + a) | 0
  h[1] = (h[1] + b) | 0
  h[2] = (h[2] + c) | 0
  h[3] = (h[3] + d) | 0
  h[4] = (h[4] + e) | 0
  h[5] = (h[5] + f) | 0
  h[6] = (h[6] + g) | 0
  h[7] = (h[7] + k) | 0
}

// a running hash: { h, length } after whole blocks only
function start() {
  return { h: INIT.slice(), length: 0 }
}

function clone(state) {
  return { h: state.h.slice(), length: state.length }
}

// feeds whole 64-byte blocks; used for the HMAC pads
function absorb(state, block) {
  compress(state.h, block, 0)
  state.length += 64
}

function finish(state, data) {
  const total = state.length + data.length
  const padded = new Array(((data.length + 9 + 63) >> 6) << 6).fill(0)
  for (let i = 0; i < data.length; i++) padded[i] = data[i]
  padded[data.length] = 0x80
  const bits = total * 8
  const end = padded.length
  padded[end - 5] = (bits / 0x100000000) & 0xff
  padded[end - 4] = (bits >>> 24) & 0xff
  padded[end - 3] = (bits >>> 16) & 0xff
  padded[end - 2] = (bits >>> 8) & 0xff
  padded[end - 1] = bits & 0xff
  const h = state.h.slice()
  for (let at = 0; at < padded.length; at += 64) compress(h, padded, at)
  const out = new Array(32)
  for (let i = 0; i < 8; i++) {
    out[i * 4] = (h[i] >>> 24) & 0xff
    out[i * 4 + 1] = (h[i] >>> 16) & 0xff
    out[i * 4 + 2] = (h[i] >>> 8) & 0xff
    out[i * 4 + 3] = h[i] & 0xff
  }
  return out
}

export function sha256(data) {
  const state = start()
  let at = 0
  for (; at + 64 <= data.length; at += 64) {
    compress(state.h, data, at)
    state.length += 64
  }
  return finish(state, Array.prototype.slice.call(data, at))
}

// the two absorbed pads of a key, for hmac()
export function hmacKey(key) {
  let k = Array.prototype.slice.call(key)
  if (k.length > 64) k = sha256(k)
  const inner = new Array(64)
  const outer = new Array(64)
  for (let i = 0; i < 64; i++) {
    const byte = k[i] || 0
    inner[i] = byte ^ 0x36
    outer[i] = byte ^ 0x5c
  }
  const i = start()
  absorb(i, inner)
  const o = start()
  absorb(o, outer)
  return { inner: i, outer: o }
}

export function hmac(prepared, data) {
  const inner = clone(prepared.inner)
  let at = 0
  for (; at + 64 <= data.length; at += 64) {
    compress(inner.h, data, at)
    inner.length += 64
  }
  const digest = finish(inner, Array.prototype.slice.call(data, at))
  return finish(clone(prepared.outer), digest)
}
