// The app is the mouse: a trackpad with a scroll strip on its right, and the
// air mouse (the gyroscope) switched by a short press of a side key. Drag
// moves, a tap clicks, a finger held still for LONG ms right-clicks. Above
// and below the two surfaces the page scrolls as usual. Not paired yet, the
// line under the pad is the way to pairing.

import { createWidget, widget, event } from '@zos/ui'
import { Gyroscope, FREQ_MODE_HIGH } from '@zos/sensor'
import { setPageBrightTime, pauseDropWristScreenOff } from '@zos/display'
import { setScrollLock } from '@zos/page'
import { onGesture, offGesture, onKey, offKey, GESTURE_RIGHT, KEY_BACK, KEY_HOME, KEY_EVENT_CLICK, KEY_EVENT_PRESS, KEY_EVENT_RELEASE, KEY_EVENT_LONG_PRESS } from '@zos/interaction'
import * as U from '../lib/ui.js'

const { T, F, M, W } = U
const LONG = 500
const PAD = { x: M, y: 88, w: 282, h: 300 }
const STRIP = { x: M + 294, y: 88, w: W - 2 * M - 294, h: 300 }

const gyro = new Gyroscope()
let s = null
let ui = {}
let touch = null
let air = false
let keyLong = false
const total = { n: 0, x: 0, y: 0, z: 0, last: 0 }

function mouse() {
  return U.link().mouse
}

function down(info, scroll) {
  touch = { x: info.x, y: info.y, at: Date.now(), moved: 0, long: false, scroll }
  // the page must not scroll under a finger that drives the pointer
  setScrollLock({ lock: true })
  const mine = touch
  if (scroll) return
  setTimeout(() => {
    if (touch === mine && mine.moved < 8) {
      mine.long = true
      mouse().click(1)
    }
  }, LONG)
}

function move(info) {
  if (!touch) return
  const dx = info.x - touch.x
  const dy = info.y - touch.y
  touch.moved += Math.abs(dx) + Math.abs(dy)
  touch.x = info.x
  touch.y = info.y
  if (touch.scroll) mouse().wheel(dy)
  else mouse().pad(dx, dy)
}

function up() {
  const t = touch
  touch = null
  setScrollLock({ lock: false })
  if (t && !t.long && !t.scroll && t.moved < 8 && Date.now() - t.at < 250) mouse().click(0)
}

function onGyro() {
  if (!air) return
  const now = Date.now()
  const g = gyro.getCurrent()
  if (total.last) {
    const dt = Math.min(now - total.last, 100) / 1000
    total.x += g.x * dt * 100
    total.y += g.y * dt * 100
    total.z += g.z * dt * 100
    total.n++
    mouse().gyro(total.n, total.x, total.y, total.z)
  }
  total.last = now
}

function setAir(on) {
  air = on
  Object.assign(total, { n: 0, x: 0, y: 0, z: 0, last: 0 })
  mouse().air(on)
  U.set(ui.air, on ? 'Air-Maus an · Seitentaste aus' : 'Seitentaste: Air-Maus')
  U.color(ui.air, on ? T.primary : T.muted)
  U.color(ui.airDot, on ? T.primary : T.faint)
}

function onKeyEvent(key, keyEvent) {
  if (key === KEY_BACK || key === KEY_HOME) return false
  // a long press keeps its meaning, so the page can always be left
  if (keyEvent === KEY_EVENT_LONG_PRESS) {
    keyLong = true
    return false
  }
  if (keyEvent === KEY_EVENT_PRESS) keyLong = false
  // release, not click: the watch reports press and release (watch/probe)
  if (keyEvent === KEY_EVENT_RELEASE && !keyLong) setAir(!air)
  return keyEvent === KEY_EVENT_CLICK || keyEvent === KEY_EVENT_PRESS || keyEvent === KEY_EVENT_RELEASE
}

function surface(box, fill, scroll) {
  const w = createWidget(widget.FILL_RECT, { ...box, radius: U.RADIUS, color: fill })
  w.addEventListener(event.CLICK_DOWN, (info) => down(info, scroll))
  w.addEventListener(event.MOVE, move)
  w.addEventListener(event.CLICK_UP, up)
}

Page({
  build() {
    U.themed()
    s = U.scope()
    setPageBrightTime({ brightTime: 600000 })
    pauseDropWristScreenOff({ duration: 600000 })

    const head = U.header('Maus', 'Ziehen · Tippen · Halten für rechts')
    s.keep(head.off)
    surface(PAD, T.layer1, false)
    surface(STRIP, T.layer2, true)
    // nothing over the surfaces: a widget on top would take the touch
    ui.airDot = U.circle(M + 14, PAD.y + PAD.h + 25, 5, T.faint)
    ui.air = U.text(M + 28, PAD.y + PAD.h + 10, W - 2 * M - 28, 30, '', { size: 17 })
    ui.pair = U.button(M + 40, PAD.y + PAD.h + 4, W - 2 * M - 80, 44, 'Mit dem PC koppeln', () => U.go('pair'), { fill: T.primary, press: T.primaryContainer, color: T.onPrimary, font: F.bold, size: 19 })
    setAir(false)
    const paired = () => {
      const yes = U.link().paired()
      U.show(ui.pair, !yes)
      U.show(ui.air, yes)
      U.show(ui.airDot, yes)
    }
    paired()
    s.keep(U.link().onStatus(paired))

    // a swipe to the right would close the page mid-drag; the back key still does
    onGesture({ callback: (gesture) => gesture === GESTURE_RIGHT })
    onKey({ callback: onKeyEvent })

    gyro.setFreqMode(FREQ_MODE_HIGH)
    gyro.onChange(onGyro)
    gyro.start()
  },
  onDestroy() {
    if (air) mouse().air(false)
    offGesture()
    offKey()
    gyro.offChange()
    gyro.stop()
    setScrollLock({ lock: false })
    s.end()
  },
})
