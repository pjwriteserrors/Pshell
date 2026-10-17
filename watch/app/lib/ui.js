// What every page is built from: the screen (390×450, square with rounded
// corners), colours that follow the shell's theme, and a few widgets.

import { createWidget, deleteWidget, widget, prop, align, text_style, event } from '@zos/ui'
import { push } from '@zos/router'

export const W = 390
export const H = 450
export const M = 18 // the margin, clear of the rounded corners

export const C = {
  bg: 0x000000,
  card: 0x16191e,
  cardPress: 0x262b33,
  line: 0x2a3038,
  text: 0xf2f4f7,
  dim: 0x8b95a1,
  faint: 0x4c5560,
  accent: 0x7aa2f7,
  good: 0x7bd88f,
  warn: 0xf2c46d,
  bad: 0xf27b7b,
}

export function link() {
  return getApp()._options.globalData.link
}

// the accent of the shell's theme, once the PC sent it
export function themed() {
  const theme = link().state('theme')
  const hex = theme && theme.accent
  if (hex && /^#[0-9a-fA-F]{6}$/.test(hex)) C.accent = parseInt(hex.slice(1), 16)
  return C.accent
}

export function text(x, y, w, h, value, options) {
  const o = options || {}
  return createWidget(widget.TEXT, {
    x,
    y,
    w,
    h,
    color: o.color !== undefined ? o.color : C.text,
    text_size: o.size || 24,
    align_h: o.center ? align.CENTER_H : o.right ? align.RIGHT : align.LEFT,
    align_v: o.top ? align.TOP : align.CENTER_V,
    text_style: o.wrap ? text_style.WRAP : text_style.ELLIPSIS,
    text: value || '',
  })
}

export function set(widgetRef, value) {
  if (widgetRef) widgetRef.setProperty(prop.TEXT, value === undefined || value === null ? '' : String(value))
}

export function color(widgetRef, value) {
  if (widgetRef) widgetRef.setProperty(prop.COLOR, value)
}

export function rect(x, y, w, h, fill, radius) {
  return createWidget(widget.FILL_RECT, { x, y, w, h, radius: radius || 0, color: fill })
}

export function button(x, y, w, h, label, click, options) {
  const o = options || {}
  return createWidget(widget.BUTTON, {
    x,
    y,
    w,
    h,
    radius: o.radius !== undefined ? o.radius : Math.min(h / 2, 24),
    normal_color: o.fill !== undefined ? o.fill : C.card,
    press_color: o.press !== undefined ? o.press : C.cardPress,
    color: o.color !== undefined ? o.color : C.text,
    text: label,
    text_size: o.size || 24,
    click_func: () => click(),
  })
}

export function setLabel(buttonRef, label) {
  if (buttonRef) buttonRef.setProperty(prop.TEXT, label)
}

// a page's title and the state of the link, at the top
export function header(title) {
  const l = link()
  const t = text(M, 14, W - 2 * M - 30, 44, title, { size: 30, color: C.text })
  const dot = createWidget(widget.CIRCLE, { center_x: W - M - 10, center_y: 36, radius: 7, color: C.faint })
  const paint = (s) => dot.setProperty(prop.COLOR, s === 'ready' ? C.good : s === 'unpaired' || s === 'refused' ? C.bad : C.warn)
  paint(l.status().status)
  const off = l.onStatus(paint)
  return { title: t, off }
}

// a line under the header that says what is wrong with the link, if anything
export function linkLine(y) {
  const l = link()
  const line = text(M, y, W - 2 * M, 30, '', { size: 18, color: C.dim })
  const words = { searching: 'Suche den PC …', connecting: 'Verbinde …', handshake: 'Melde an …', unpaired: 'Nicht gekoppelt', pairing: 'Koppeln …', refused: 'Abgelehnt', off: 'Bluetooth aus' }
  const paint = (s, detail) => set(line, s === 'ready' ? '' : detail || words[s] || s)
  const now = l.status()
  paint(now.status, now.detail)
  const off = l.onStatus(paint)
  return { line, off }
}

// a card that reacts to a tap anywhere on it, its texts included (a text
// over a button would take the touch from it)
export function card(x, y, w, h, tap) {
  const parts = []
  let from = null
  const add = (widgetRef) => {
    widgetRef.addEventListener(event.CLICK_DOWN, (info) => (from = info))
    // a finger that scrolled the page did not mean to tap
    widgetRef.addEventListener(event.CLICK_UP, (info) => {
      if (from && Math.abs(info.x - from.x) + Math.abs(info.y - from.y) < 12) tap()
      from = null
    })
    parts.push(widgetRef)
    return widgetRef
  }
  add(rect(x, y, w, h, C.card, 24))
  return { add, parts }
}

// a bar of 0…1
export function bar(x, y, w, h, fill) {
  const back = rect(x, y, w, h, C.line, h / 2)
  const front = rect(x, y, Math.max(h, 1), h, fill || C.accent, h / 2)
  return {
    parts: [back, front],
    set(value) {
      const v = Math.max(0, Math.min(1, Number(value) || 0))
      front.setProperty(prop.MORE, { x, y, w: Math.max(h, Math.round(w * v)), h })
    },
    color(value) {
      front.setProperty(prop.COLOR, value)
    },
  }
}

// widgets made for a list, deleted together when the list is drawn again
export function group() {
  let made = []
  return {
    add(w) {
      made.push(w)
      return w
    },
    clear() {
      made.forEach((w) => deleteWidget(w))
      made = []
    },
  }
}

export function go(page) {
  push({ url: 'page/' + page })
}

// what to do with every subscription a page takes: undo them all on leaving
export function scope() {
  const offs = []
  return {
    sub(topic, fn) {
      offs.push(link().subscribe(topic, fn))
    },
    keep(off) {
      offs.push(off)
    },
    end() {
      offs.forEach((off) => off())
      offs.length = 0
    },
  }
}

export function clock(seconds) {
  seconds = Math.max(0, Math.floor(seconds))
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = seconds % 60
  const two = (n) => (n < 10 ? '0' : '') + n
  return h ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`
}

export { event, prop }
