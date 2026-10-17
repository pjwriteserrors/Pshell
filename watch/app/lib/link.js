// The connection to the PC, for every page: app.js makes one and keeps it in
// globalData. It finds the PC over BLE, signs in with the secret from pairing,
// and then carries subscriptions, calls and the mouse (lib/protocol.js has the
// frames, scripts/phone/pshell_phone/watch.py the other end).
//
// The face makes one too, with `once`: it connects when the face comes on,
// takes the snapshots it wants and lets go (createLink({ once, secret })).
//
// Quick to come up: the PC's address is kept from the last time, so the link
// connects straight away and only scans when that fails; the snapshots it
// had are kept too (cache.json), so a page shows them before the PC answers.

import { BLEMaster } from '@silver-zepp/easy-ble'
import { localStorage } from '@zos/storage'
import { Accelerometer } from '@zos/sensor'
import * as P from './protocol.js'
import { sha256 } from './sha256.js'
import { writeJson, readJson } from './store.js'
import { VERSION } from './version.js'

const NAME = 'pshell'
const SERVICE = '7A50'
const RX = '7A51'
const TX = '7A52'
// one write to the PC: kept small, writes are what the watch is touchy about
const FRAME = 60
const ROOM = FRAME - 14
const TICK = 30
// writes while the connection is being set up hung the watch (watch/probe):
// a moment after the notifications are on, or this long when no word comes
const SETTLE = 300
const SETTLE_AT_MOST = 1500
// a connect the watch never answers (it normally gives up by itself)
const CONNECT_AT_MOST = 15000

export function createLink(options) {
  options = options || {}
  let ble = new BLEMaster()
  let parts = P.assembler()
  const listeners = { status: [], had: [] }
  const subscribers = {}
  const cache = {}
  const calls = {}
  let status = 'off'
  let detail = ''
  let secret = null
  let mac = ''
  let connected = false
  let session = null
  let nonce = null
  let answer = null
  let pairingSecret = null
  let queue = []
  let messageId = 0
  let callId = 0
  let timers = []
  let retry = null
  let handshake = null
  let unsubscribing = {}
  let pingSeq = 0
  let pings = {}
  let lastPong = 0
  let closing = false
  let flushTimer = null
  // what came from the PC, sent along with every ping for its log
  const heard = { frames: 0, refused: 0, longest: 0, lost: 0, again: 0 }
  let askedAgain = 0
  // the connect under way, if any
  let attempt = null
  let settled = null
  let begun = false
  // when each step was reached, sent to the PC's log once ready
  let times = {}
  const self = { rtt: 0, code: '', name: '' }

  try {
    const stored = options.secret || localStorage.getItem('secret')
    if (stored) secret = P.fromHex(stored)
    self.name = options.name || localStorage.getItem('pcName') || ''
    mac = options.mac || localStorage.getItem('pcMac') || ''
  } catch (e) {}
  // the face signs in with the app's secret: it reads this file with the app's id
  function keep() {
    if (secret && !options.once) writeJson('link.json', { secret: P.hex(secret), name: self.name, mac })
  }
  keep()
  if (!options.once) Object.assign(cache, readJson('cache.json') || {})

  function setStatus(next, text) {
    status = next
    detail = text || ''
    listeners.status.forEach((fn) => guarded('status ' + next, fn, status, detail))
  }

  // a page's mistake must not stop the link: caught, and told to the PC's log
  let errors = []
  function guarded(where, fn, ...args) {
    try {
      fn(...args)
    } catch (e) {
      const said = `${where}: ${(e && e.message) || e}`.slice(0, 160)
      if (session) json({ t: 'error', e: said })
      else if (errors.length < 5) errors.push(said)
    }
  }

  function later(fn, ms) {
    const t = setTimeout(() => {
      timers = timers.filter((x) => x !== t)
      fn()
    }, ms)
    timers.push(t)
    return t
  }

  function write(bytes) {
    if (!connected) return
    ble.write.characteristic(RX, new Uint8Array(bytes).buffer, true)
  }

  // ── finding and connecting ──────────────────────────────────────────────
  function mark(step) {
    if (!(step in times)) times[step] = Date.now() - times.start
  }

  // a BLEMaster per attempt: easy-ble reports a device only once per
  // instance, so a second scan on the same one never sees the PC again
  function fresh() {
    try {
      ble.stopScan()
    } catch (e) {}
    ble = new BLEMaster()
  }

  // the address from last time first, a scan when that fails
  function find() {
    if (closing || connected || attempt) return
    times = { start: Date.now() }
    fresh()
    if (!mac) return scan()
    connect(true)
  }

  function scan() {
    if (closing || connected || attempt) return
    setStatus('searching')
    mark('scan')
    const mine = ble
    const ok = mine.startScan(
      (result) => {
        if (result.dev_name !== NAME || mine !== ble || attempt || connected) return
        mine.stopScan()
        mark('found')
        if (result.dev_addr !== mac) {
          mac = result.dev_addr
          try {
            localStorage.setItem('pcMac', mac)
          } catch (e) {}
          keep()
        }
        connect(false)
      },
      {
        duration: options.once ? 8000 : 20000,
        on_duration: () => {
          if (mine !== ble || connected || closing || attempt) return
          if (options.once) return setStatus('off', 'PC nicht gefunden')
          setStatus('searching', 'PC nicht gefunden')
          retry = later(find, 1000)
        },
      },
    )
    if (!ok) setStatus('off', 'Bluetooth geht nicht')
  }

  // one connect at a time, and every one either used or closed: one left open
  // keeps the PC from advertising, and no scan finds it any more
  function connect(straight) {
    setStatus('connecting')
    const mine = ble
    const id = (attempt = {})
    // the watch gives up on its own; this is only for one that never answers
    const guard = later(() => {
      if (attempt !== id) return
      attempt = null
      times.direct = 'no answer'
      fresh()
      if (straight) scan()
      else lost()
    }, options.connectAtMost || CONNECT_AT_MOST)
    mine.connect(mac, (result) => {
      clearTimeout(guard)
      const ours = attempt === id
      if (ours) attempt = null
      if (!result.connected) {
        // easy-ble answers here again when the link goes later on
        if (!ours) {
          if (connected && mine === ble && !closing) lost()
          return
        }
        if (closing) return
        // the remembered address failed: look for the PC
        if (straight) {
          times.direct = result.status
          fresh()
          return scan()
        }
        lost()
        return
      }
      if (closing || connected || (!ours && mine !== ble && !adopt(mine))) {
        try {
          mine.disconnect()
        } catch (e) {}
        return
      }
      connected = true
      mark('connected')
      const profile = mine.generateProfileObject({ [SERVICE]: { [RX]: [], [TX]: ['2902'] } })
      profile.pair = false
      mine.startListener(profile, (response) => {
        if (mine !== ble || !connected) return
        if (!response.success) {
          setStatus('connecting', response.message)
          return
        }
        mark('profile')
        mine.on.charaNotification((uuid, data) => receive(Array.from(new Uint8Array(data))))
        // without this the library's queue waits 5 s for the CCCD write to
        // finish before it sends anything else; it also says when to begin
        mine.on.descWriteComplete(() => {
          mark('notifying')
          settle(SETTLE)
        })
        mine.write.enableCharaNotifications(TX, true)
        settle(SETTLE_AT_MOST)
      })
    })
  }

  // a connect given up on that made it after all, with nothing else under way: use it
  function adopt(late) {
    if (attempt) return false
    try {
      ble.stopScan()
    } catch (e) {}
    ble = late
    if (retry) clearTimeout(retry)
    return true
  }

  function settle(ms) {
    if (settled) clearTimeout(settled)
    settled = later(() => {
      settled = null
      begin()
    }, ms)
  }

  function lost() {
    const was = connected
    connected = false
    begun = false
    if (settled) clearTimeout(settled)
    settled = null
    session = null
    queue = []
    parts = P.assembler()
    Object.keys(calls).forEach((id) => {
      const call = calls[id]
      delete calls[id]
      call.done(false, 'Verbindung weg')
    })
    if (closing) return
    if (options.once) return setStatus('off', 'Verbindung weg')
    setStatus('searching', was ? 'Verbindung weg' : '')
    retry = later(find, was ? 500 : 2000)
  }

  // ── signing in ───────────────────────────────────────────────────────────
  function begin() {
    if (!connected || begun) return
    begun = true
    if (pairingSecret) {
      write(P.pair(pairingSecret))
      setStatus('pairing')
      return
    }
    if (!secret) {
      idle('unpaired')
      return
    }
    sayHello()
  }

  // nothing to say until someone taps: let go of the link (a silent one is
  // dropped by the PC after 20 s anyway) and wait for pair()
  function idle(next, text) {
    const gone = ble
    connected = false
    begun = false
    session = null
    if (settled) clearTimeout(settled)
    settled = null
    if (retry) clearTimeout(retry)
    try {
      gone.disconnect()
    } catch (e) {}
    setStatus(next, text)
  }

  function sayHello() {
    nonce = randomBytes(8)
    write(P.hello(secret, nonce))
    setStatus('handshake')
    // a write without response can get lost: say it again
    if (handshake) clearTimeout(handshake)
    handshake = later(() => {
      if (connected && !session && status === 'handshake') sayHello()
    }, 4000)
  }

  function receive(frame) {
    const kind = frame[0]
    heard.frames++
    heard.longest = Math.max(heard.longest, frame.length)
    if (kind === P.CHALLENGE && secret) {
      answer = P.prove(secret, frame.slice(1, 9), nonce)
      write(answer.proof)
    } else if (kind === P.WELCOME && answer) {
      if (!P.checkWelcome(answer.welcome, frame)) {
        setStatus('refused', 'Der PC ist nicht der gekoppelte')
        return
      }
      session = P.session(answer.session)
      answer = null
      lastPong = Date.now()
      mark('ready')
      // asked for before the pages hear of it: what they do cannot hold it up
      const topics = Object.keys(subscribers).filter((t) => subscribers[t].length)
      if (topics.length) json({ t: 'sub', k: topics })
      json({ t: 'times', v: VERSION, face: !!options.once, ms: times })
      errors.forEach((e) => json({ t: 'error', e }))
      errors = []
      setStatus('ready')
    } else if (kind === P.PAIRED && pairingSecret) {
      secret = pairingSecret
      pairingSecret = null
      self.code = ''
      try {
        localStorage.setItem('secret', P.hex(secret))
      } catch (e) {}
      keep()
      sayHello()
    } else if (kind === P.REFUSED) {
      const reason = P.REASONS[frame[1]] || 'refused'
      if (pairingSecret) {
        pairingSecret = null
        self.code = ''
        idle('unpaired', reason === 'timeout' ? 'Am PC nicht bestätigt' : reason === 'busy' ? 'Der PC fragt gerade schon' : 'Am PC abgelehnt')
      } else if (reason === 'unknown') {
        // the PC forgot this watch (removed there): pair anew
        secret = null
        try {
          localStorage.removeItem('secret')
        } catch (e) {}
        idle('unpaired', 'Der PC kennt die Uhr nicht mehr')
      } else idle('refused', 'Anmeldung abgelehnt')
    } else if (kind === P.SESSION && session) {
      const messages = P.open(session, frame)
      if (!messages) {
        heard.refused++
        return
      }
      messages.forEach(handle)
    }
  }

  function handle(m) {
    if (m[0] === 0x82) {
      const seq = m[1] | (m[2] << 8)
      if (pings[seq]) {
        self.rtt = Date.now() - pings[seq]
        delete pings[seq]
      }
      lastPong = Date.now()
    } else if (m[0] === 0x10) {
      const message = parts.feed(m)
      if (message === 'lost') {
        heard.lost++
        // once in a while: every snapshot again for each lost part floods the link
        if (Date.now() - askedAgain > 3000) {
          askedAgain = Date.now()
          heard.again++
          json({ t: 'again' })
        }
      }
      else if (message) onJson(message)
    }
  }

  function onJson(message) {
    lastPong = Date.now()
    if (message.t === 's') {
      cache[message.k] = message.d
      if (message.k === 'link' && message.d && message.d.name) {
        self.name = message.d.name
        try {
          localStorage.setItem('pcName', self.name)
        } catch (e) {}
      }
      ;(subscribers[message.k] || []).forEach((fn) => guarded(message.k, fn, message.d))
    } else if (message.t === 'had') {
      listeners.had.forEach((fn) => guarded('had', fn, message.k || []))
    } else if (message.t === 'r') {
      const call = calls[message.i]
      if (!call) return
      delete calls[message.i]
      guarded('call', call.done, message.ok, message.ok ? message.d : message.e)
    }
  }

  // ── sending in a session ────────────────────────────────────────────────
  function post(m) {
    if (session) queue.push(m)
  }

  function json(data) {
    if (!session) return
    messageId = (messageId + 1) & 0xff
    P.jsonParts(messageId, data, ROOM).forEach((m) => queue.push(m))
  }

  // the mouse's motion is summed up between frames, not queued
  const motion = { pad: [0, 0], wheel: 0, gyro: null }

  function flush() {
    if (!session || !connected) return
    const messages = []
    let size = 9
    const add = (m) => {
      messages.push(m)
      size += m.length + 1
    }
    if (motion.pad[0] || motion.pad[1]) {
      add([0x03].concat(i16(motion.pad[0]), i16(motion.pad[1])))
      motion.pad = [0, 0]
    }
    if (motion.wheel) {
      add([0x07].concat(i16(motion.wheel)))
      motion.wheel = 0
    }
    if (motion.gyro) {
      add(motion.gyro)
      motion.gyro = null
    }
    while (queue.length && size + queue[0].length + 1 <= FRAME) add(queue.shift())
    if (!messages.length) return
    write(P.seal(session, messages))
  }

  function everyTwoSeconds() {
    if (!session) return
    if (Date.now() - lastPong > 10000) {
      // nothing from the PC for a while: say what did come, then start over
      ping()
      flush()
      const gone = ble
      session = null
      later(() => {
        try {
          gone.disconnect()
        } catch (e) {}
        lost()
      }, 300)
      return
    }
    ping()
  }

  function ping() {
    const seq = pingSeq++ & 0xffff
    pings[seq] = Date.now()
    const u16 = (v) => [v & 0xff, (v >> 8) & 0xff]
    post([0x02, seq & 0xff, seq >> 8].concat(u16(Math.min(heard.frames, 0xffff)), u16(Math.min(heard.refused, 0xffff)), [Math.min(heard.longest, 255), Math.min(heard.lost, 255), Math.min(heard.again, 255)]))
  }

  function i16(v) {
    v = Math.max(-32768, Math.min(32767, Math.round(v)))
    return [v & 0xff, (v >> 8) & 0xff]
  }

  function randomBytes(n) {
    // no system source of randomness here: the clock, Math.random and the
    // accelerometer's noise, through SHA-256
    let seed = P.ascii(String(Date.now()) + String(Math.random()) + String(Math.random()))
    try {
      const a = new Accelerometer()
      const c = a.getCurrent()
      seed = seed.concat(P.ascii(`${c.x}${c.y}${c.z}`))
    } catch (e) {}
    const out = []
    let block = P.ascii('')
    while (out.length < n) {
      block = sha256(seed.concat(block))
      for (let i = 0; i < block.length && out.length < n; i++) out.push(block[i])
      seed = seed.concat(P.ascii(String(Math.random())))
    }
    return out
  }

  // ── for the pages ───────────────────────────────────────────────────────
  Object.assign(self, {
    start() {
      closing = false
      if (!flushTimer) {
        flushTimer = setInterval(flush, TICK)
        timers.push(setInterval(everyTwoSeconds, 2000))
      }
      find()
    },
    // what the pages saw, for the next start (written now and then by a page)
    keepCache(topics) {
      const out = {}
      topics.forEach((t) => {
        if (t in cache) out[t] = cache[t]
      })
      writeJson('cache.json', out)
    },
    stop() {
      closing = true
      if (flushTimer) clearInterval(flushTimer)
      flushTimer = null
      timers.forEach((t) => {
        clearTimeout(t)
        clearInterval(t)
      })
      timers = []
      try {
        ble.stopScan()
      } catch (e) {}
      try {
        if (connected) ble.disconnect()
      } catch (e) {}
      connected = false
      session = null
      ble.quit()
    },
    status() {
      return { status, detail }
    },
    paired() {
      return !!secret
    },
    onStatus(fn) {
      listeners.status.push(fn)
      return () => (listeners.status = listeners.status.filter((f) => f !== fn))
    },
    // fn(topics) when the PC has sent every snapshot a subscription asked for
    onHad(fn) {
      listeners.had.push(fn)
    },
    // fn(data) now with what is known, and with every new snapshot
    subscribe(topic, fn) {
      const list = (subscribers[topic] = subscribers[topic] || [])
      list.push(fn)
      if (unsubscribing[topic]) {
        clearTimeout(unsubscribing[topic])
        delete unsubscribing[topic]
      } else if (list.length === 1) json({ t: 'sub', k: [topic] })
      if (topic in cache) fn(cache[topic])
      return () => {
        subscribers[topic] = (subscribers[topic] || []).filter((f) => f !== fn)
        if (subscribers[topic].length) return
        // a page that comes back soon keeps the subscription
        unsubscribing[topic] = setTimeout(() => {
          delete unsubscribing[topic]
          if (!subscribers[topic].length) json({ t: 'unsub', k: [topic] })
        }, 5000)
      }
    },
    state(topic) {
      return cache[topic]
    },
    // done(ok, dataOrMessage)
    call(topic, action, args, done) {
      done = done || (() => {})
      if (!session) return done(false, 'Nicht verbunden')
      const id = ++callId
      calls[id] = { done }
      json({ t: 'call', i: id, k: topic, a: action, g: args || {} })
      setTimeout(() => {
        if (calls[id]) {
          delete calls[id]
          done(false, 'Keine Antwort')
        }
      }, 25000)
    },
    // pairing: a new secret, its code for the screen; the PC asks its user
    pair() {
      pairingSecret = randomBytes(16)
      self.code = P.pairingCode(pairingSecret)
      if (connected) {
        begun = false
        begin()
      } else find()
      setStatus('pairing')
      return self.code
    },
    cancelPairing() {
      pairingSecret = null
      self.code = ''
      if (!connected) return setStatus(secret ? 'searching' : 'unpaired')
      if (secret) {
        begun = false
        begin()
      } else idle('unpaired')
    },
    mouse: {
      pad(dx, dy) {
        motion.pad[0] += dx
        motion.pad[1] += dy
      },
      wheel(dy) {
        motion.wheel += dy
      },
      button(index, down) {
        post([0x04, index, down ? 1 : 0])
      },
      click(index) {
        post([0x04, index, 1])
        post([0x04, index, 0])
      },
      air(on) {
        post([0x08, on ? 1 : 0])
      },
      // totals since air mode came on: samples and centidegrees, wrapping
      gyro(n, x, y, z) {
        const w = (v) => {
          v = Math.round(v) & 0xffff
          return [v & 0xff, v >> 8]
        }
        motion.gyro = [0x05, n & 0xff].concat(w(x), w(y), w(z))
      },
    },
  })
  return self
}
