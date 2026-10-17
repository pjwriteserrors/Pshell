// The face: the shell's look on the wrist, in its wallust colours. The time
// large in Adwaita Sans like the bar's clock, the day and the battery above,
// steps and pulse as the bar's pills beside a mouse pill that opens the app,
// and last night's sleep as a card: how long, the score, from when to when,
// and its stages drawn as the hypnogram the shell's >watch shows large.
//
// Now and then, when it comes on, the face connects to the PC once (with
// the app's secret and the PC's address from the app's link.json): it hands
// over what the watch measured (lib/health.js) and takes the shell's colours
// back, then lets go. At most every EVERY, and at once when a night ended.
//
// When the screen comes on the face plays a short intro, like a shell panel
// opening: the time settles into place, the pills and the card rise one
// after another, the stages grow across the card and the score counts up.
// About half a second, then nothing moves (a still face costs no battery).

import { createWidget, deleteWidget, widget, prop, align, text_style, event } from '@zos/ui'
import { Time, Battery, Step, HeartRate, Screen } from '@zos/sensor'
import { localStorage } from '@zos/storage'
import { launchApp } from '@zos/router'
import { I } from '../lib/icons.js'
import { collect, nightKey, lastNight } from '../lib/health.js'
import { createLink } from '../../app/lib/link.js'
import { readJson, writeJson, APP } from '../../app/lib/store.js'
import { VERSION } from '../../app/lib/version.js'

// how often the face may sync, however often the wrist is turned
const EVERY = 30 * 60 * 1000
// longest a sync may hold the link
const HOLD = 20000
const W = 390
const M = 20
const CW = W - 2 * M
const F = { sans: 'fonts/sans.ttf', medium: 'fonts/medium.ttf', bold: 'fonts/bold.ttf', icons: 'fonts/icons.ttf' }
const DAYS = ['So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa']
const MONTHS = ['Jan', 'Feb', 'März', 'Apr', 'Mai', 'Juni', 'Juli', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez']
// the shell's palette as it was when this was built, until the PC sent one
const FALLBACK = {
  bg: '#030305', fg: '#f4c84c', primary: '#19cef4', secondary: '#a679aa', tertiary: '#206196', success: '#42ab68', warning: '#dfa939',
  layer1: '#0e0c08', layer2: '#17140b', layer3: '#221d0e', primaryContainer: '#072c35', muted: '#a18434', faint: '#453918',
}
// the intro: frames this far apart, this long in all
const FRAME = 33
const INTRO = 520
// the hypnogram's rows, top to bottom, as the shell draws them
const ROWS = { wake: 0, rem: 1, light: 2, deep: 3 }

const time = new Time()
const battery = new Battery()
const step = new Step()
const heart = new HeartRate()
let made = []
let ui = {}
let T = {}
let themeKey = ''
let night = null
let nightRead = 0
// widgets that move in the intro: [widget, x, y, w, h, order]
let moving = []
let intro = null

function colors(roles) {
  const out = {}
  Object.keys(FALLBACK).forEach((k) => (out[k] = parseInt(String((roles && roles[k]) || FALLBACK[k]).slice(1), 16)))
  return out
}

function theme() {
  try {
    return JSON.parse(localStorage.getItem('theme') || 'null')
  } catch (e) {
    return null
  }
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

// a widget that rises into place in the intro, after `order` others
function rises(w, x, y, wide, high, order) {
  moving.push([w, x, y, wide, high, order])
  return w
}

// a pill like the bar's groups: an icon and a value
function pill(x, y, w, name, tone, order) {
  const back = rises(rect(x, y, w, 44, T.layer1, 22), x, y, w, 44, order)
  const glyph = rises(icon(x + 12, y + 10, 24, name, tone), x + 12, y + 10, 24, 24, order)
  const value = rises(text(x + 40, y, w - 48, 44, '', { font: F.medium, size: 19 }), x + 40, y, w - 48, 44, order)
  return { back, glyph, value }
}

function two(n) {
  return (n < 10 ? '0' : '') + n
}

function clock(minutes) {
  const m = ((Math.round(minutes) % 1440) + 1440) % 1440
  return `${two(Math.floor(m / 60))}:${two(m % 60)}`
}

function span(minutes) {
  const m = Math.round(minutes || 0)
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${two(m % 60)}`
}

// last night, read from the sensor at most every few minutes
function sleep() {
  if (!night || Date.now() - nightRead > 5 * 60 * 1000) {
    night = lastNight()
    nightRead = Date.now()
  }
  return night
}

function build() {
  made.forEach((w) => deleteWidget(w))
  made = []
  moving = []
  ui = {}
  const roles = theme()
  T = colors(roles)
  themeKey = JSON.stringify(roles || null)
  rect(0, 0, W, 450, T.bg)

  ui.date = text(M + 8, 18, 220, 30, '', { font: F.medium, size: 20, color: T.muted })
  icon(W - M - 96, 21, 24, 'battery', T.muted)
  ui.battery = text(W - M - 70, 18, 62, 30, '', { font: F.medium, size: 20, color: T.muted, right: true })
  ui.time = rises(text(0, 46, W, 132, '', { font: F.bold, size: 124, center: true }), 0, 46, W, 132, -1)

  const third = (CW - 16) / 3
  ui.steps = pill(M, 186, third + 14, 'walk', T.primary, 0)
  ui.heart = pill(M + third + 22, 186, third - 14, 'heart_pulse', T.secondary, 1)
  // the app: the PC's mouse
  const mouse = pill(M + 2 * third + 16, 186, third, 'mouse', T.primary, 2)
  mouse.value.setProperty(prop.TEXT, 'Maus')
  const open = () => {
    letGo()
    launchApp({ appId: APP, url: 'page/mouse' })
  }
  ;[mouse.back, mouse.glyph, mouse.value].forEach((w) => w.addEventListener(event.CLICK_UP, open))

  // last night
  const y = 246
  rises(rect(M, y, CW, 172, T.layer1, 22), M, y, CW, 172, 3)
  rises(rect(M + 16, y + 16, 44, 44, T.primaryContainer, 22), M + 16, y + 16, 44, 44, 3)
  rises(icon(M + 25, y + 25, 26, 'sleep', T.primary), M + 25, y + 25, 26, 26, 3)
  ui.slept = rises(text(M + 72, y + 12, CW - 160, 32, '', { font: F.bold, size: 26 }), M + 72, y + 12, CW - 160, 32, 3)
  ui.score = rises(text(W - M - 110, y + 14, 94, 28, '', { font: F.medium, size: 18, color: T.primary, right: true }), W - M - 110, y + 14, 94, 28, 3)
  ui.span = rises(text(M + 72, y + 42, CW - 88, 22, '', { size: 16, color: T.muted }), M + 72, y + 42, CW - 88, 22, 3)
  ui.graph = { x: M + 16, y: y + 80, w: CW - 32, h: 52, parts: [], boxes: [] }
  ui.stages = rises(text(M + 16, y + 138, CW - 32, 24, '', { size: 15, color: T.muted }), M + 16, y + 138, CW - 32, 24, 4)
  text(0, 422, W, 22, `v${VERSION}`, { size: 14, color: T.faint, center: true })
}

// the stages as rows: awake on top, deep at the bottom, each in its colour
function hypnogram(n) {
  const g = ui.graph
  g.parts.forEach((w) => {
    deleteWidget(w)
    made = made.filter((m) => m !== w)
  })
  g.parts = []
  g.boxes = []
  const tone = { wake: T.warning, rem: T.tertiary, light: T.secondary, deep: T.primary }
  const stages = (n && n.stages) || []
  if (!stages.length) return
  // minutes run on past midnight: an end before its start is the next day
  const at = (m, ref) => (m < ref - 720 ? m + 1440 : m)
  const first = stages[0][1]
  const last = stages.reduce((end, s) => Math.max(end, at(s[2], first)), first + 1)
  const scale = g.w / Math.max(1, last - first)
  const row = g.h / 4
  stages.forEach((s) => {
    const x = g.x + (at(s[1], first) - first) * scale
    const w = Math.max(2, (at(s[2], first) - at(s[1], first)) * scale)
    const r = ROWS[s[0]] !== undefined ? ROWS[s[0]] : 2
    const box = [Math.round(x), Math.round(g.y + r * row + 1), Math.round(w), Math.round(row - 2)]
    g.parts.push(rect(box[0], box[1], box[2], box[3], tone[s[0]] || T.secondary, 3))
    g.boxes.push(box)
  })
}

function paint() {
  if (JSON.stringify(theme() || null) !== themeKey || !ui.time) build()
  const now = new Date()
  U(ui.time, `${two(time.getHours())}:${two(time.getMinutes())}`)
  U(ui.date, `${DAYS[now.getDay()]} ${time.getDate()}. ${MONTHS[time.getMonth() - 1]}`)
  U(ui.battery, `${battery.getCurrent()} %`)
  U(ui.steps.value, String(step.getCurrent()).replace(/\B(?=(\d{3})+(?!\d))/g, '.'))
  const beat = heart.getLast ? heart.getLast() : heart.getCurrent()
  U(ui.heart.value, beat ? String(beat) : '–')

  const n = sleep()
  if (!n || !n.total) {
    U(ui.slept, 'Kein Schlaf')
    U(ui.score, '')
    U(ui.span, 'Die Uhr hat heute Nacht nichts gemessen')
    U(ui.stages, '')
    hypnogram(null)
    return
  }
  U(ui.slept, span(n.total))
  ui.scoreValue = n.score || 0
  U(ui.score, n.score ? `Score ${n.score}` : '')
  U(ui.span, `${clock(n.start)} – ${clock(n.end)}`)
  const sum = {}
  ;(n.stages || []).forEach((s) => {
    const len = (((s[2] - s[1]) % 1440) + 1440) % 1440
    sum[s[0]] = (sum[s[0]] || 0) + len
  })
  U(ui.stages, `Tief ${span(sum.deep || n.deep)} · REM ${span(sum.rem || 0)} · Wach ${span(sum.wake || 0)}`)
  hypnogram(n)
}

function U(w, value) {
  if (w) w.setProperty(prop.TEXT, value === undefined || value === null ? '' : String(value))
}

// ── the intro ───────────────────────────────────────────────────────────────
// the shell's spatial curve, roughly: quick, a touch past the end, settled
function spatial(t) {
  const u = t - 1
  return 1 + 2.2 * u * u * u + 1.2 * u * u
}

function place(w, x, y, wide, high) {
  w.setProperty(prop.MORE, { x: Math.round(x), y: Math.round(y), w: Math.round(wide), h: Math.round(high) })
}

function play() {
  if (intro) clearTimeout(intro)
  const start = Date.now()
  const g = ui.graph
  const frame = () => {
    intro = null
    const t = Date.now() - start
    moving.forEach(([w, x, y, wide, high, order]) => {
      // the time drops in from above, the rest rises, each a little later
      const k = spatial(Math.max(0, Math.min(1, (t - 40 * (order + 1)) / 340)))
      const lift = order < 0 ? -14 : 18
      place(w, x, y + lift * (1 - k), wide, high)
    })
    // the stages grow across, left to right
    const sweep = Math.max(0, Math.min(1, (t - 220) / 300))
    const edge = g.x + g.w * sweep
    g.parts.forEach((w, i) => {
      const b = g.boxes[i]
      const wide = Math.max(0, Math.min(b[2], edge - b[0]))
      w.setProperty(prop.VISIBLE, wide > 0)
      if (wide > 0) place(w, b[0], b[1], wide, b[3])
    })
    if (ui.scoreValue) U(ui.score, `Score ${Math.round(ui.scoreValue * Math.min(1, t / INTRO))}`)
    if (t < INTRO + 200) intro = setTimeout(frame, FRAME)
  }
  frame()
}

// ── syncing with the PC ─────────────────────────────────────────────────────
let syncing = null

function due() {
  const last = Number(localStorage.getItem('synced') || 0)
  if (Date.now() - last > EVERY) return true
  // a night that ended since: the PC should have it now
  return nightKey() !== (localStorage.getItem('night') || '')
}

// stop a sync under way, connection and all
function letGo() {
  const link = syncing
  syncing = null
  if (link) {
    try {
      link.stop()
    } catch (e) {}
  }
}

function sync() {
  if (syncing || !due()) return
  const key = readJson('link.json', APP)
  if (!key || !key.secret) return
  let link = null
  try {
    link = createLink({ once: true, secret: key.secret, name: key.name, mac: key.mac })
  } catch (e) {
    return
  }
  syncing = link
  const night = nightKey()
  let delivered = false
  let colours = false
  const done = () => {
    if (syncing !== link) return
    if (delivered) {
      localStorage.setItem('synced', String(Date.now()))
      localStorage.setItem('night', night)
    }
    letGo()
    paint()
  }
  link.subscribe('theme', (roles) => {
    if (!roles || !roles.bg) return
    colours = true
    localStorage.setItem('theme', JSON.stringify(roles))
    // for the app, which reads it with this face's id
    writeJson('theme.json', roles)
    if (delivered) done()
  })
  link.onMessage((message) => {
    if (message.t !== 'got') return
    delivered = true
    if (colours) done()
  })
  link.onStatus((status) => {
    if (status === 'ready') link.send({ t: 'health', d: collect() })
    else if (status === 'off' || status === 'unpaired' || status === 'refused') letGo()
  })
  // never longer than this, whatever happens
  setTimeout(done, HOLD)
  link.start()
}

// the face comes on: show what is known, play the intro, sync when it is time
function wake() {
  paint()
  play()
  sync()
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
  onPause() {
    letGo()
    if (intro) clearTimeout(intro)
    intro = null
  },
  onDestroy() {
    letGo()
    made = []
  },
})
