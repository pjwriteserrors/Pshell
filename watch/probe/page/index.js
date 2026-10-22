// The probe: can the watch reach the PC on its own, and is it good enough as a
// mouse? It scans for the PC (scripts/watch/probe.py advertises as "pshell"),
// connects as BLE central, pings, and streams the gyroscope or a trackpad.
//
// Writes that follow each other closely get lost, and many writes a second
// without waiting for an answer reboot the watch (probe 3: 30/s did it within
// seconds). So everything waiting goes out as one frame at a rate picked on
// screen, as a write with response (the next one waits for it) or without:
// messages back to back, each [len, type, …].
// Watch → PC (write on 7A51):
//   0x01 text…                         hello, the last error
//   0x02 seq:u16                       ping, answered by 0x82 seq on 7A52
//   0x03 dx:i16 dy:i16                 trackpad motion in screen pixels
//   0x04 button:u8 down:u8             0 left, 1 right
//   0x05 n:u8 x:i16 y:i16 z:i16        gyro totals since air mode came on, wrapping: samples,
//                                      centidegrees (totals, so a lost frame loses no motion)
//   0x06 hz:u16 rtt:u16 lost:u16       sensor rate, mean ping time, pings never answered
//   0x07 dy:i16                        scroll, in screen pixels dragged along the right edge
// PC → watch (notify on 7A52):
//   0x81 text…                         shown on the status line
//   0x82 seq:u16                       pong

import { BLEMaster } from '@silver-zepp/easy-ble'
import { createWidget, widget, prop, align, text_style, event } from '@zos/ui'
import { Gyroscope, FREQ_MODE_HIGH } from '@zos/sensor'
import { setPageBrightTime, pauseDropWristScreenOff } from '@zos/display'
import { localStorage } from '@zos/storage'
import { setScrollLock } from '@zos/page'
import {
  onGesture,
  offGesture,
  onKey,
  offKey,
  GESTURE_RIGHT,
  KEY_BACK,
  KEY_HOME,
  KEY_SELECT,
  KEY_UP,
  KEY_DOWN,
  KEY_SHORTCUT,
  KEY_EVENT_CLICK,
  KEY_EVENT_PRESS,
  KEY_EVENT_RELEASE,
  KEY_EVENT_LONG_PRESS,
  KEY_EVENT_DOUBLE_CLICK,
} from '@zos/interaction'

const NAME = 'pshell'
const SERVICE = '7A50'
const RX = '7A51'
const TX = '7A52'
// frames stay within the default ATT payload until it is known what is safe
const FRAME = 20
const RATES = [5, 10, 20, 33]

const ble = new BLEMaster()
const gyro = new Gyroscope()

const state = {
  mac: '',
  connected: false,
  ready: false,
  closing: false,
  scanning: false,
  seq: 0,
  pings: {},
  rtt: [],
  lost: 0,
  frames: 0,
  received: 0,
  air: false,
  total: [0, 0, 0],
  samples: 0,
  airDirty: false,
  hzCount: 0,
  hz: 0,
  lastSample: 0,
  last: { x: 0, y: 0, z: 0 },
  touch: null,
  pad: [0, 0],
  wheel: 0,
  keyLong: false,
  greeted: false,
  queue: [],
  timers: [],
  maxFrame: 0,
  rate: 3,
  reliable: false,
  inflight: 0,
  flushTimer: null,
  started: Date.now(),
}

let ui = {}
const lines = []

// an exception inside a callback ends the app without a word; keep it for the PC
function guard(name, fn) {
  return (...args) => {
    try {
      return fn(...args)
    } catch (e) {
      const text = name + ': ' + (e && e.message ? e.message : String(e))
      try {
        localStorage.setItem('lastError', text)
      } catch (_) {}
      log('! ' + text)
    }
  }
}

function log(line) {
  console.log('[probe] ' + line)
  lines.unshift(line)
  lines.length = Math.min(lines.length, 5)
  if (ui.log) ui.log.setProperty(prop.TEXT, lines.join('\n'))
}

function status(text) {
  if (ui.status) ui.status.setProperty(prop.TEXT, text)
}

function mode() {
  return RATES[state.rate] + 'Hz ' + (state.reliable ? 'R' : 'U')
}

function setRate() {
  if (state.flushTimer) clearInterval(state.flushTimer)
  state.flushTimer = setInterval(guard('flush', flush), Math.round(1000 / RATES[state.rate]))
  if (ui.rate) ui.rate.setProperty(prop.TEXT, RATES[state.rate] + ' Hz')
  if (ui.reliable) ui.reliable.setProperty(prop.TEXT, state.reliable ? 'mit Antwort' : 'ohne Antwort')
  stats()
}

function meanRtt() {
  return state.rtt.length ? Math.round(state.rtt.reduce((a, b) => a + b, 0) / state.rtt.length) : 0
}

function stats() {
  if (!ui.stats) return
  const rtt = state.rtt.length ? meanRtt() + ' ms' : '–'
  ui.stats.setProperty(
    prop.TEXT,
    `RTT ${rtt}   lost ${state.lost}   frames ${state.frames}\nGyro ${state.hz} Hz   ${mode()}${state.air ? '   AIR' : ''}`,
  )
  const g = state.last
  if (ui.gyro) ui.gyro.setProperty(prop.TEXT, `x ${g.x.toFixed(1)}  y ${g.y.toFixed(1)}  z ${g.z.toFixed(1)}`)
}

// ---- outgoing ----

function u16(v) {
  return [v & 0xff, (v >> 8) & 0xff]
}

function i16(v) {
  v = Math.max(-32768, Math.min(32767, Math.round(v)))
  return [v & 0xff, (v >> 8) & 0xff]
}

function wrap16(v) {
  v = Math.round(v) & 0xffff
  return [v & 0xff, v >> 8]
}

function post(bytes) {
  if (state.ready) state.queue.push(bytes)
}

function text(type, s) {
  const out = [type]
  for (let i = 0; i < s.length && out.length < 19; i++) out.push(s.charCodeAt(i) & 0x7f)
  return out
}

function flush() {
  if (!state.ready) return
  // with response: one write at a time; an answer that never comes frees it after a second
  if (state.reliable && state.inflight && Date.now() - state.inflight < 1000) return
  if (state.air && state.airDirty) {
    const [x, y, z] = state.total
    state.queue.push([0x05, state.samples & 0xff, ...wrap16(x), ...wrap16(y), ...wrap16(z)])
    state.airDirty = false
  }
  if (state.wheel) {
    state.queue.unshift([0x07, ...i16(state.wheel)])
    state.wheel = 0
  }
  if (state.pad[0] || state.pad[1]) {
    state.queue.unshift([0x03, ...i16(state.pad[0]), ...i16(state.pad[1])])
    state.pad = [0, 0]
  }
  if (!state.queue.length) return
  const frame = []
  while (state.queue.length && frame.length + state.queue[0].length + 1 <= FRAME) {
    const message = state.queue.shift()
    frame.push(message.length, ...message)
  }
  if (!frame.length) {
    state.queue.shift()
    return
  }
  ble.write.characteristic(RX, new Uint8Array(frame).buffer, !state.reliable)
  if (state.reliable) state.inflight = Date.now()
  state.frames++
  state.maxFrame = Math.max(state.maxFrame, frame.length)
}

// ---- BLE ----

function scan() {
  if (state.connected || state.scanning || state.closing) return
  state.scanning = true
  status('Suche "' + NAME + '" …')
  let seen = 0
  const ok = ble.startScan(
    guard('scan', (result) => {
      seen++
      if (result.dev_name !== NAME) return
      ble.stopScan()
      state.scanning = false
      state.mac = result.dev_addr
      log('PC ' + result.dev_addr + ' rssi ' + result.rssi)
      connect()
    }),
    {
      duration: 15000,
      allow_duplicates: false,
      on_duration: guard('scan end', () => {
        state.scanning = false
        if (!state.connected) status('Nicht gefunden (' + seen + ' Geräte gesehen)')
      }),
    },
  )
  if (!ok) {
    state.scanning = false
    status('Scan geht nicht – BLE central gesperrt?')
  }
}

function connect() {
  status('Verbinde …')
  ble.connect(
    state.mac,
    guard('connect', (result) => {
      if (!result.connected) {
        state.connected = state.ready = false
        state.queue = []
        status('Getrennt: ' + result.status)
        log('connect: ' + result.status)
        // come back on our own: the PC may have restarted, or the radio dropped out
        if (!state.closing) setTimeout(guard('reconnect', () => scan()), 2000)
        return
      }
      state.connected = true
      status('Verbunden, baue Profil …')
      const profile = ble.generateProfileObject({ [SERVICE]: { [RX]: [], [TX]: ['2902'] } })
      profile.pair = false
      ble.startListener(
        profile,
        guard('profile', (response) => {
          if (!response.success) {
            status('Profil: ' + response.message)
            log('profile ' + response.code + ' ' + response.message)
            return
          }
          ble.on.charaNotification(guard('notify', onNotify))
          ble.on.charaWriteComplete(
            guard('written', () => {
              state.inflight = 0
            }),
          )
          state.inflight = 0
          ble.write.enableCharaNotifications(TX, true)
          // writes sent while the connection is still being set up hung the
          // watch or slowed it to a crawl (probes 6, 7): give it time first
          status('Verbunden …')
          setTimeout(
            guard('settle', () => {
              if (!state.connected || state.closing) return
              state.ready = true
              state.pings = {}
              status('Bereit')
              state.greeted = false
              hello()
              post(text(0x01, `B${KEY_BACK} H${KEY_HOME} S${KEY_SELECT}`))
              post(text(0x01, `U${KEY_UP} D${KEY_DOWN} X${KEY_SHORTCUT}`))
              post(text(0x01, `c${KEY_EVENT_CLICK} p${KEY_EVENT_PRESS} r${KEY_EVENT_RELEASE}`))
              post(text(0x01, `l${KEY_EVENT_LONG_PRESS} d${KEY_EVENT_DOUBLE_CLICK}`))
              let last = ''
              let crumb = ''
              try {
                last = localStorage.getItem('lastError') || ''
                localStorage.removeItem('lastError')
                crumb = localStorage.getItem('crumb') || ''
              } catch (_) {}
              // one message per 18 characters: a frame holds no more
              if (last) for (let i = 0; i < last.length; i += 17) post(text(0x01, 'E' + last.slice(i, i + 17)))
              if (crumb) post(text(0x01, 'C' + crumb))
            }),
            1500,
          )
        }),
      )
    }),
  )
}

function onNotify(uuid, data) {
  state.received++
  const bytes = new Uint8Array(data)
  if (bytes[0] === 0x82) {
    const seq = bytes[1] | (bytes[2] << 8)
    const sent = state.pings[seq]
    if (sent) {
      state.rtt.push(Date.now() - sent)
      if (state.rtt.length > 10) state.rtt.shift()
      delete state.pings[seq]
    }
  } else if (bytes[0] === 0x81) {
    state.greeted = true
    let s = ''
    for (let i = 1; i < bytes.length; i++) s += String.fromCharCode(bytes[i])
    status(s)
  }
}

// the PC answers a hello with 0x81; until then it is said again, a first frame gets lost at times
function hello() {
  if (state.ready && !state.greeted) post(text(0x01, 'hello probe 7'))
}

function everySecond() {
  hello()
  state.hz = state.hzCount
  state.hzCount = 0
  // what the app was doing, for the next start to tell if this one dies
  try {
    localStorage.setItem('crumb', `${Math.round((Date.now() - state.started) / 1000)}s f${state.frames} q${state.queue.length} ${mode()}${state.air ? ' A' : ''}`)
  } catch (_) {}
  if (state.ready) {
    const now = Date.now()
    Object.keys(state.pings).forEach((seq) => {
      if (now - state.pings[seq] > 3000) {
        state.lost++
        delete state.pings[seq]
      }
    })
    const seq = state.seq++ & 0xffff
    state.pings[seq] = now
    post([0x02, ...u16(seq)])
    post([0x06, ...u16(state.hz), ...u16(meanRtt()), ...u16(state.lost)])
  }
  stats()
}

// ---- gyroscope ----

function onGyro() {
  const now = Date.now()
  const g = gyro.getCurrent()
  state.hzCount++
  state.last = g
  if (state.lastSample && state.air) {
    const dt = Math.min(now - state.lastSample, 100) / 1000
    state.total[0] += g.x * dt * 100
    state.total[1] += g.y * dt * 100
    state.total[2] += g.z * dt * 100
    state.samples++
    state.airDirty = true
  }
  state.lastSample = now
}

function toggleAir() {
  state.air = !state.air
  state.total = [0, 0, 0]
  state.samples = 0
  state.airDirty = state.air
  if (ui.air) ui.air.setProperty(prop.TEXT, state.air ? 'AIR an' : '')
  stats()
}

function click(index) {
  post([0x04, index, 1])
  post([0x04, index, 0])
}

// ---- page ----
// The whole screen is the trackpad: drag moves, a tap clicks, holding still
// for LONG ms right-clicks, a drag along the right edge (EDGE wide) scrolls.
// A side key (not back/home) switches the air mouse; a long press keeps its
// usual meaning so the app can always be left. Every key the watch reports
// goes to the PC as K<key>:<event>, the key constants at hello, to learn which
// code each of the two keys sends.

const LONG = 500
const W = 390
// the trackpad and, right of it, the scroll strip; above and below them the
// page scrolls as usual
const PAD = { x: 12, y: 96, w: 290, h: 300 }
const STRIP = { x: 314, y: 96, w: 64, h: 300 }

function padDown(info, scroll) {
  state.touch = { x: info.x, y: info.y, at: Date.now(), moved: 0, long: false, scroll }
  // the page must not scroll under a finger that drives the pointer
  setScrollLock({ lock: true })
  const touch = state.touch
  if (scroll) return
  setTimeout(
    guard('long', () => {
      if (state.touch === touch && touch.moved < 8) {
        touch.long = true
        click(1)
      }
    }),
    LONG,
  )
}

function padMove(info) {
  const t = state.touch
  if (!t) return
  const dx = info.x - t.x
  const dy = info.y - t.y
  t.moved += Math.abs(dx) + Math.abs(dy)
  t.x = info.x
  t.y = info.y
  if (t.scroll) state.wheel += dy
  else {
    state.pad[0] += dx
    state.pad[1] += dy
  }
}

function padUp() {
  const t = state.touch
  state.touch = null
  setScrollLock({ lock: false })
  if (t && !t.long && !t.scroll && t.moved < 8 && Date.now() - t.at < 250) click(0)
}

function onKeyEvent(key, keyEvent) {
  post(text(0x01, 'K' + key + ':' + keyEvent))
  if (key === KEY_BACK || key === KEY_HOME) return false
  // a long press is left alone, so the app can always be left
  if (keyEvent === KEY_EVENT_LONG_PRESS) {
    state.keyLong = true
    return false
  }
  if (keyEvent === KEY_EVENT_PRESS) state.keyLong = false
  // release, not click: the watch reported press and release only (probe 6)
  if (keyEvent === KEY_EVENT_RELEASE && !state.keyLong) toggleAir()
  return true
}

Page({
  build() {
    setPageBrightTime({ brightTime: 600000 })
    pauseDropWristScreenOff({ duration: 600000 })

    const label = (y, h, size, color) =>
      createWidget(widget.TEXT, {
        x: 16,
        y,
        w: W - 32,
        h,
        color,
        text_size: size,
        align_h: align.CENTER_H,
        align_v: align.CENTER_V,
        text_style: text_style.WRAP,
        text: '',
      })
    ui.status = label(10, 36, 24, 0xc0ccd8)
    ui.stats = label(46, 46, 16, 0x5a6a7a)

    const surface = (box, color, scroll) => {
      const w = createWidget(widget.FILL_RECT, { ...box, radius: 22, color })
      w.addEventListener(event.CLICK_DOWN, guard('pad down', (info) => padDown(info, scroll)))
      w.addEventListener(event.MOVE, guard('pad move', padMove))
      w.addEventListener(event.CLICK_UP, guard('pad up', padUp))
      return w
    }
    surface(PAD, 0x16212b, false)
    surface(STRIP, 0x101820, true)
    // nothing drawn over the surfaces: a widget on top would take the touch
    ui.air = label(PAD.y + PAD.h + 2, 22, 18, 0x2f6fbf)

    // below the screen, reached by scrolling the page
    ui.gyro = label(424, 26, 16, 0x5a6a7a)
    ui.log = createWidget(widget.TEXT, {
      x: 16,
      y: 456,
      w: W - 32,
      h: 160,
      color: 0x5a6a7a,
      text_size: 16,
      text_style: text_style.WRAP,
      text: '',
    })

    setRate()
    stats()

    // a swipe to the right would close the app mid-drag; the back key still does
    onGesture({ callback: (gesture) => gesture === GESTURE_RIGHT })
    onKey({ callback: guard('key', onKeyEvent) })

    gyro.setFreqMode(FREQ_MODE_HIGH)
    gyro.onChange(guard('gyro', onGyro))
    gyro.start()

    state.timers.push(setInterval(guard('second', everySecond), 1000))
    scan()
  },

  onDestroy() {
    state.closing = true
    offGesture()
    offKey()
    try {
      localStorage.setItem('crumb', 'clean exit')
    } catch (_) {}
    state.timers.forEach((t) => clearInterval(t))
    if (state.flushTimer) clearInterval(state.flushTimer)
    gyro.offChange()
    gyro.stop()
    try {
      ble.stopScan()
    } catch (e) {}
    ble.quit()
  },
})
