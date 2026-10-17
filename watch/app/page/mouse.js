// The mouse: a trackpad with a scroll strip on its right, and the air mouse
// (the gyroscope) switched by a short press of a side key. Drag moves, a tap
// clicks, a finger held still for LONG ms right-clicks. Above and below the
// two surfaces the page scrolls as usual.

import { createWidget, widget, event } from '@zos/ui'
import { Gyroscope, FREQ_MODE_HIGH } from '@zos/sensor'
import { setPageBrightTime, pauseDropWristScreenOff } from '@zos/display'
import { setScrollLock } from '@zos/page'
import { onGesture, offGesture, onKey, offKey, GESTURE_RIGHT, KEY_BACK, KEY_HOME, KEY_EVENT_CLICK, KEY_EVENT_PRESS, KEY_EVENT_RELEASE, KEY_EVENT_LONG_PRESS } from '@zos/interaction'
import * as U from '../lib/ui.js'

const { C, M, W } = U
const LONG = 500
const PAD = { x: 12, y: 70, w: 290, h: 320 }
const STRIP = { x: 314, y: 70, w: 64, h: 320 }

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
  U.set(ui.air, on ? 'Air-Maus an' : 'Seitentaste: Air-Maus')
  U.color(ui.air, on ? C.accent : C.faint)
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
  const w = createWidget(widget.FILL_RECT, { ...box, radius: 24, color: fill })
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

    const line = U.linkLine(20)
    s.keep(line.off)
    surface(PAD, C.card, false)
    surface(STRIP, 0x0f1216, true)
    // nothing over the surfaces: a widget on top would take the touch
    ui.air = U.text(M, PAD.y + PAD.h + 6, W - 2 * M, 30, '', { size: 20, center: true })
    setAir(false)

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
