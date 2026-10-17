// The face: the shell's look on the wrist. The time large in Adwaita Sans
// like the bar's clock, the day, the watch's own numbers as chips, and below
// a card with the PC. When the face comes on it connects to the PC once
// (with the app's secret, from the app's link.json), takes the snapshots it
// shows and lets go; between those, and when that fails, it shows what it or
// the app (pc.json) saw last. A tap on the card opens the app.

import { createWidget, deleteWidget, widget, prop, align, text_style, event } from '@zos/ui'
import { Time, Battery, Step, HeartRate, Screen } from '@zos/sensor'
import { localStorage } from '@zos/storage'
import { openSync, readSync, closeSync, O_RDONLY } from '@zos/fs'
import { launchApp } from '@zos/router'
import { I } from '../lib/icons.js'
import { createLink } from '../../app/lib/link.js'
import { summary, TOPICS } from '../../app/lib/summary.js'

const APP = 1073744
// at most one fetch a minute, however often the wrist is turned
const EVERY = 60 * 1000
// how long the PC may take to send its snapshots once signed in
const GATHER = 3500
const W = 390
const M = 20
const CW = W - 2 * M
const F = { sans: 'fonts/sans.ttf', medium: 'fonts/medium.ttf', bold: 'fonts/bold.ttf', icons: 'fonts/icons.ttf' }
const DAYS = ['So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa']
const MONTHS = ['Jan', 'Feb', 'März', 'Apr', 'Mai', 'Juni', 'Juli', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez']
// the shell's palette as it was when this was built, until the app saved one
const FALLBACK = {
  bg: '#030305', fg: '#f4c84c', primary: '#19cef4', secondary: '#a679aa', success: '#42ab68', warning: '#dfa939',
  layer1: '#0e0c08', layer2: '#17140b', layer3: '#221d0e', primaryContainer: '#072c35', muted: '#a18434', faint: '#453918',
}
// older than this, the card says when it was true
const STALE = 15 * 60 * 1000

const time = new Time()
const battery = new Battery()
const step = new Step()
const heart = new HeartRate()
let made = []
let ui = {}
let T = {}
let themeKey = ''

function colors(roles) {
  const out = {}
  Object.keys(FALLBACK).forEach((k) => (out[k] = parseInt(String((roles && roles[k]) || FALLBACK[k]).slice(1), 16)))
  return out
}

function add(w) {
  made.push(w)
  return w
}

function text(x, y, w, h, value, o) {
  o = o || {}
  return add(
    createWidget(widget.TEXT, {
      x, y, w, h,
      color: o.color !== undefined ? o.color : T.fg,
      text_size: o.size || 20,
      font: o.font || F.sans,
      align_h: o.center ? align.CENTER_H : o.right ? align.RIGHT : align.LEFT,
      align_v: align.CENTER_V,
      text_style: text_style.ELLIPSIS,
      text: value || '',
    }),
  )
}

function icon(x, y, size, name, color) {
  return text(x, y, size, size, I[name] || '', { font: F.icons, size: Math.round(size * 0.86), center: true, color })
}

function rect(x, y, w, h, color, radius) {
  return add(createWidget(widget.FILL_RECT, { x, y, w, h, color, radius: radius || 0 }))
}

// a pill like the bar's groups: an icon and a value
function pill(x, y, w, name, tone) {
  const back = rect(x, y, w, 44, T.layer1, 22)
  const glyph = icon(x + 12, y + 10, 24, name, tone)
  const value = text(x + 40, y, w - 48, 44, '', { font: F.medium, size: 19 })
  return { back, glyph, value }
}

function bar(x, y, w, h, color) {
  const back = rect(x, y, w, h, T.layer3, h / 2)
  const front = rect(x, y, h, h, color, h / 2)
  const set = (v) => front.setProperty(prop.MORE, { x, y, h, w: Math.max(h, Math.round(w * Math.max(0, Math.min(1, v || 0)))) })
  set.parts = [back, front]
  return set
}

function utf8(bytes) {
  let out = ''
  for (let i = 0; i < bytes.length; ) {
    const b = bytes[i++]
    let c = b
    if (b >= 0xf0) c = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)
    else if (b >= 0xe0) c = ((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)
    else if (b >= 0xc0) c = ((b & 31) << 6) | (bytes[i++] & 63)
    if (c >= 0x10000) {
      c -= 0x10000
      out += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023))
    } else out += String.fromCharCode(c)
  }
  return out
}

// a JSON file in the app's /data, or null
function appFile(path) {
  try {
    const fd = openSync({ path, flag: O_RDONLY, options: { appId: APP } })
    if (fd === undefined || fd < 0) return null
    const chunk = new ArrayBuffer(1024)
    let bytes = []
    for (let i = 0; i < 16; i++) {
      const n = readSync({ fd, buffer: chunk })
      if (!n || n <= 0) break
      bytes = bytes.concat(Array.from(new Uint8Array(chunk, 0, n)))
      if (n < chunk.byteLength) break
    }
    closeSync({ fd })
    return bytes.length ? JSON.parse(utf8(bytes)) : null
  } catch (e) {
    return null
  }
}

function own() {
  try {
    return JSON.parse(localStorage.getItem('pc') || 'null')
  } catch (e) {
    return null
  }
}

// the newer of what the face fetched and what the app wrote
function pc() {
  const a = own()
  const b = appFile('pc.json')
  if (!a) return b
  if (!b) return a
  return (a.at || 0) >= (b.at || 0) ? a : b
}

let lastTry = 0
let fetching = null

// connect, sign in, take the snapshots, let go
function fetch() {
  if (fetching || Date.now() - lastTry < EVERY) return
  const key = appFile('link.json')
  if (!key || !key.secret) return
  lastTry = Date.now()
  let link = null
  const finish = () => {
    if (!fetching) return
    fetching = null
    try {
      link.stop()
    } catch (e) {}
  }
  try {
    link = createLink({ once: true, secret: key.secret, name: key.name })
  } catch (e) {
    return
  }
  fetching = link
  TOPICS.forEach((topic) => link.subscribe(topic, () => {}))
  link.onStatus((status) => {
    if (status === 'ready') {
      setTimeout(() => {
        if (fetching !== link) return
        const data = summary((topic) => link.state(topic), key.name)
        try {
          localStorage.setItem('pc', JSON.stringify(data))
        } catch (e) {}
        finish()
        paint()
      }, GATHER)
    } else if (status === 'off' || status === 'unpaired' || status === 'refused') finish()
  })
  // never longer than this, whatever happens
  setTimeout(finish, 25000)
  link.start()
}

function two(n) {
  return (n < 10 ? '0' : '') + n
}

function span(seconds) {
  const minutes = Math.round((seconds || 0) / 60)
  if (minutes < 60) return `${minutes} min`
  return `${Math.floor(minutes / 60)} h ${two(minutes % 60)}`
}

function build(data) {
  made.forEach((w) => deleteWidget(w))
  made = []
  ui = {}
  T = colors(data && data.theme)
  themeKey = JSON.stringify((data && data.theme) || null)
  rect(0, 0, W, 450, T.bg)

  ui.date = text(M + 8, 18, 220, 30, '', { font: F.medium, size: 20, color: T.muted })
  icon(W - M - 96, 21, 24, 'battery', T.muted)
  ui.battery = text(W - M - 70, 18, 62, 30, '', { font: F.medium, size: 20, color: T.muted, right: true })
  ui.time = text(0, 46, W, 132, '', { font: F.bold, size: 124, center: true })

  const third = (CW - 16) / 3
  ui.steps = pill(M, 186, third + 14, 'walk', T.primary)
  ui.heart = pill(M + third + 22, 186, third - 14, 'heart_pulse', T.secondary)
  ui.weather = pill(M + 2 * third + 16, 186, third, 'weather_cloudy', T.primary)

  // the PC
  const y = 246
  const first = made.length
  const card = rect(M, y, CW, 172, T.layer1, 22)
  const chipBack = add(createWidget(widget.CIRCLE, { center_x: M + 38, center_y: y + 38, radius: 22, color: T.primaryContainer }))
  icon(M + 25, y + 25, 26, 'monitor', T.primary)
  ui.name = text(M + 72, y + 14, CW - 180, 28, '', { font: F.bold, size: 21 })
  ui.age = text(W - M - 116, y + 14, 100, 28, '', { size: 16, color: T.muted, right: true })
  ui.load = text(M + 72, y + 40, CW - 88, 22, '', { size: 16, color: T.muted })
  ui.cpu = bar(M + 72, y + 68, (CW - 104) / 2, 6, T.primary)
  ui.mem = bar(M + 88 + (CW - 104) / 2, y + 68, (CW - 104) / 2, 6, T.secondary)
  ui.agentDot = add(createWidget(widget.CIRCLE, { center_x: M + 26, center_y: y + 108, radius: 6, color: T.warning }))
  ui.agent = text(M + 42, y + 92, CW - 58, 32, '', { size: 18 })
  ui.note = icon(M + 14, y + 132, 24, 'music', T.primary)
  ui.media = text(M + 42, y + 128, CW - 58, 32, '', { size: 18 })
  const open = () => launchApp({ appId: APP, url: 'page/index' })
  // everything on the card opens the app: a text over it would take the tap
  made.slice(first).forEach((w) => w.addEventListener(event.CLICK_UP, open))
}

function paint() {
  const data = pc()
  if (JSON.stringify((data && data.theme) || null) !== themeKey || !ui.time) build(data)
  const now = new Date()
  U(ui.time, `${two(time.getHours())}:${two(time.getMinutes())}`)
  U(ui.date, `${DAYS[now.getDay()]} ${time.getDate()}. ${MONTHS[time.getMonth() - 1]}`)
  U(ui.battery, `${battery.getCurrent()} %`)
  U(ui.steps.value, String(step.getCurrent()).replace(/\B(?=(\d{3})+(?!\d))/g, '.'))
  const beat = heart.getLast ? heart.getLast() : heart.getCurrent()
  U(ui.heart.value, beat ? String(beat) : '–')

  const known = !!data
  ;[ui.agentDot, ui.note].concat(ui.cpu.parts, ui.mem.parts).forEach((w) => w.setProperty(prop.VISIBLE, known))
  if (!data) {
    U(ui.name, 'PC')
    U(ui.load, 'PShell öffnen, um ihn zu sehen')
    U(ui.age, '')
    U(ui.weather.value, '–')
    U(ui.agent, '')
    U(ui.media, '')
    return
  }
  const age = Date.now() - (data.at || 0)
  U(ui.name, data.name || 'PC')
  U(ui.age, age > STALE ? `${two(new Date(data.at).getHours())}:${two(new Date(data.at).getMinutes())}` : 'gerade')
  U(ui.load, data.cpu === null || data.cpu === undefined ? '' : `CPU ${data.cpu} % · RAM ${data.memory} %${data.screentime ? ' · ' + span(data.screentime) : ''}`)
  ui.cpu((data.cpu || 0) / 100)
  ui.mem((data.memory || 0) / 100)
  U(ui.weather.value, data.weather ? `${data.weather.temperature}°` : '–')
  if (data.weather && I[data.weather.icon]) U(ui.weather.glyph, I[data.weather.icon])
  const agents = data.busy + data.waiting
  ui.agentDot.setProperty(prop.COLOR, data.busy ? T.warning : agents ? T.success : T.faint)
  U(ui.agent, agents ? `${data.busy ? data.busy + ' arbeitet' : data.waiting + ' wartet'} · ${data.agent}` : data.printer ? `Druck ${Math.round(data.printer.progress)} % · noch ${span(data.printer.left)}` : 'Kein Agent läuft')
  U(ui.media, data.media ? `${data.media.title}${data.media.artist ? ' · ' + data.media.artist : ''}` : 'Nichts spielt')
}

function U(w, value) {
  if (w) w.setProperty(prop.TEXT, value === undefined || value === null ? '' : String(value))
}

// the face comes on: show what is known, then ask the PC
function wake() {
  paint()
  fetch()
}

let screen = null

WatchFace({
  build() {
    wake()
    time.onPerMinute(paint)
    battery.onChange(paint)
    try {
      screen = new Screen()
      screen.onChange((status) => status === 1 && wake())
    } catch (e) {
      screen = null
    }
  },
  onResume() {
    wake()
  },
  onDestroy() {
    if (fetching) {
      try {
        fetching.stop()
      } catch (e) {}
    }
    made = []
  },
})
