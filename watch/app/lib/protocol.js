// The watch's side of the link's frames (scripts/phone/pshell_phone/watch.py
// has the whole description). Plain functions over byte arrays: no Zepp OS
// here, so watch/tools/test-protocol.mjs runs it in node against the PC.

import { sha256, hmacKey, hmac } from './sha256.js'

export const VERSION = 1
export const HELLO = 0x20
export const CHALLENGE = 0x21
export const PROOF = 0x22
export const WELCOME = 0x23
export const PAIR = 0x24
export const PAIRED = 0x25
export const REFUSED = 0x26
export const SESSION = 0x30
export const REASONS = { 1: 'unknown', 2: 'refused', 3: 'busy', 4: 'timeout', 5: 'off' }

export function ascii(text) {
  const out = []
  for (let i = 0; i < text.length; i++) out.push(text.charCodeAt(i) & 0x7f)
  return out
}

export function utf8(text) {
  const out = []
  for (let i = 0; i < text.length; i++) {
    let c = text.charCodeAt(i)
    if (c >= 0xd800 && c < 0xdc00 && i + 1 < text.length) {
      const low = text.charCodeAt(i + 1)
      if (low >= 0xdc00 && low < 0xe000) {
        c = 0x10000 + ((c - 0xd800) << 10) + (low - 0xdc00)
        i++
      }
    }
    if (c < 0x80) out.push(c)
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63))
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
  }
  return out
}

export function fromUtf8(bytes) {
  let out = ''
  for (let i = 0; i < bytes.length; ) {
    const b = bytes[i++]
    let c
    if (b < 0x80) c = b
    else if (b < 0xe0) c = ((b & 31) << 6) | (bytes[i++] & 63)
    else if (b < 0xf0) c = ((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)
    else c = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)
    if (c >= 0x10000) {
      c -= 0x10000
      out += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023))
    } else out += String.fromCharCode(c)
  }
  return out
}

export function hex(bytes) {
  let out = ''
  for (let i = 0; i < bytes.length; i++) out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16)
  return out
}

export function fromHex(text) {
  const out = []
  for (let i = 0; i + 1 < text.length; i += 2) out.push(parseInt(text.slice(i, i + 2), 16))
  return out
}

function u32(v) {
  return [v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff]
}

function equal(a, b, n) {
  let diff = 0
  for (let i = 0; i < n; i++) diff |= (a[i] | 0) ^ (b[i] | 0)
  return diff === 0
}

export function watchId(secret) {
  return sha256(ascii('id').concat(secret)).slice(0, 8)
}

export function pairingCode(secret) {
  const d = sha256(ascii('code').concat(secret))
  const n = ((d[0] << 24) >>> 0) + (d[1] << 16) + (d[2] << 8) + d[3]
  return String(n % 10000).padStart(4, '0')
}

export function hello(secret, nonce) {
  return [HELLO, VERSION].concat(secret ? watchId(secret) : [0, 0, 0, 0, 0, 0, 0, 0], nonce)
}

export function pair(secret) {
  return [PAIR].concat(secret)
}

// the answer to a challenge; and what the PC must say back, and the session key
export function prove(secret, noncePc, nonceWatch) {
  const key = hmacKey(secret)
  return {
    proof: [PROOF].concat(hmac(key, ascii('proof').concat(noncePc, nonceWatch)).slice(0, 16)),
    welcome: hmac(key, ascii('welcome').concat(nonceWatch, noncePc)).slice(0, 16),
    session: hmac(key, ascii('session').concat(nonceWatch, noncePc)),
  }
}

export function checkWelcome(expected, frame) {
  return frame.length >= 17 && equal(expected, frame.slice(1, 17), 16)
}

// a session: counters both ways, the key absorbed once
export function session(key) {
  return { key: hmacKey(key), out: 0, in: 0 }
}

// messages: arrays of bytes, each [type, …]
export function seal(s, messages) {
  s.out++
  const counter = u32(s.out)
  let body = []
  for (const m of messages) body = body.concat([m.length], m)
  const t = hmac(s.key, [0x57].concat(counter, body)).slice(0, 4)
  return [SESSION].concat(counter, body, t)
}

// the messages of a frame from the PC, or null when it is not genuine
export function open(s, frame) {
  if (frame.length < 9 || frame[0] !== SESSION) return null
  const counter = (frame[1] | (frame[2] << 8) | (frame[3] << 16) | (frame[4] << 24)) >>> 0
  if (counter <= s.in) return null
  const body = frame.slice(5, frame.length - 4)
  const t = hmac(s.key, [0x50].concat(frame.slice(1, 5), body))
  if (!equal(t, frame.slice(frame.length - 4), 4)) return null
  s.in = counter
  const messages = []
  for (let at = 0; at < body.length; ) {
    const size = body[at]
    if (size) messages.push(body.slice(at + 1, at + 1 + size))
    at += 1 + size
  }
  return messages
}

// a JSON message cut into 0x10 messages of at most `room` bytes of text each
export function jsonParts(id, data, room) {
  const raw = utf8(JSON.stringify(data))
  const out = []
  for (let at = 0, index = 0; at < raw.length || index === 0; at += room, index++) {
    const part = raw.slice(at, at + room)
    out.push([0x10, id & 0xff, index & 0xff, at + room >= raw.length ? 1 : 0].concat(part))
  }
  return out
}

// puts parts back together: feed() returns the message when its last part came,
// 'lost' when a part went missing, null otherwise
export function assembler() {
  let id = -1
  let next = 0
  let bytes = []
  return {
    feed(m) {
      const [, message, index, last] = m
      if (index === 0) {
        id = message
        next = 0
        bytes = []
      }
      if (message !== id || index !== next) {
        id = -1
        return 'lost'
      }
      next++
      bytes = bytes.concat(m.slice(4))
      if (!last) return null
      id = -1
      try {
        return JSON.parse(fromUtf8(bytes))
      } catch (e) {
        return 'lost'
      }
    },
  }
}
