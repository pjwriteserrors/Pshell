// What every page is built from, in the shell's look (style/theme): its
// colour roles (worked out on the PC from the wal palette and kept here),
// Adwaita Sans and the shell's Material icons (watch/tools/fonts.py), filled
// cards without outlines, a bold title over a muted line, round icon chips,
// bars and rings in the primary colour. The screen is 390×450, square with
// rounded corners; coordinates are real pixels.

import { createWidget, deleteWidget, widget, prop, align, text_style, event } from '@zos/ui'
import { push } from '@zos/router'
import { localStorage } from '@zos/storage'
import { I } from './icons.js'
import { VERSION } from './version.js'
import { readJson, FACE } from './store.js'


export const W = 390
export const H = 450
export const M = 20 // the margin, clear of the rounded corners
export const GAP = 12
export const RADIUS = 22 // Theme.radius.huge: the shell's cards

export const F = { sans: 'fonts/sans.ttf', medium: 'fonts/medium.ttf', bold: 'fonts/bold.ttf', icons: 'fonts/icons.ttf' }

// the palette the shell has now, until the PC sends its own
const FALLBACK = {
  dark: true, bg: '#030305', fg: '#f4c84c', primary: '#19cef4', secondary: '#a679aa', tertiary: '#206196', onPrimary: '#030305',
  danger: '#cd5861', warning: '#dfa939', success: '#42ab68', layer1: '#0e0c08', layer2: '#17140b', layer3: '#221d0e',
  primaryContainer: '#072c35', dangerContainer: '#2b1417', muted: '#a18434', subtle: '#6f5b25', faint: '#453918', outline: '#201b0e',
}

export const T = {}

function adopt(roles) {
  Object.keys(FALLBACK).forEach((key) => {
    const value = roles && roles[key] !== undefined ? roles[key] : FALLBACK[key]
    T[key] = typeof value === 'string' ? parseInt(value.slice(1), 16) : value
  })
}

try {
  adopt(JSON.parse(localStorage.getItem('theme') || 'null'))
} catch (e) {
  adopt(null)
}

export function link() {
  return getApp()._options.globalData.link
}

// the shell's colours: as the face last had them from the PC (theme.json)
export function themed() {
  const roles = readJson('theme.json', FACE)
  if (roles && roles.bg) {
    adopt(roles)
    try {
      localStorage.setItem('theme', JSON.stringify(roles))
    } catch (e) {}
  }
  return T
}

export function text(x, y, w, h, value, o) {
  o = o || {}
  return createWidget(widget.TEXT, {
    x,
    y,
    w,
    h,
    color: o.color !== undefined ? o.color : T.fg,
    text_size: o.size || 22,
    font: o.font || F.sans,
    align_h: o.center ? align.CENTER_H : o.right ? align.RIGHT : align.LEFT,
    align_v: o.top ? align.TOP : o.bottom ? align.BOTTOM : align.CENTER_V,
    text_style: o.wrap ? text_style.WRAP : text_style.ELLIPSIS,
    line_space: o.lineSpace || 0,
    text: value === undefined || value === null ? '' : String(value),
  })
}

export function icon(x, y, size, name, color) {
  return createWidget(widget.TEXT, {
    x,
    y,
    w: size,
    h: size,
    color: color !== undefined ? color : T.fg,
    text_size: Math.round(size * 0.86),
    font: F.icons,
    align_h: align.CENTER_H,
    align_v: align.CENTER_V,
    text: I[name] || '',
  })
}

export function set(widgetRef, value) {
  if (widgetRef) widgetRef.setProperty(prop.TEXT, value === undefined || value === null ? '' : String(value))
}

export function setIcon(widgetRef, name) {
  if (widgetRef) widgetRef.setProperty(prop.TEXT, I[name] || '')
}

export function color(widgetRef, value) {
  if (widgetRef) widgetRef.setProperty(prop.COLOR, value)
}

export function show(widgetRef, visible) {
  if (widgetRef) widgetRef.setProperty(prop.VISIBLE, !!visible)
}

export function rect(x, y, w, h, fill, radius) {
  return createWidget(widget.FILL_RECT, { x, y, w, h, radius: radius || 0, color: fill })
}

export function circle(cx, cy, r, fill) {
  return createWidget(widget.CIRCLE, { center_x: cx, center_y: cy, radius: r, color: fill })
}

// a filled card without an outline, like every tile of the shell
export function card(x, y, w, h, fill) {
  return rect(x, y, w, h, fill !== undefined ? fill : T.layer1, RADIUS)
}

// an icon in a round chip of the primary's container colour
export function chip(x, y, size, name, tone) {
  const fill = tone === 'danger' ? T.dangerContainer : tone === 'plain' ? T.layer2 : T.primaryContainer
  const fg = tone === 'danger' ? T.danger : tone === 'plain' ? T.muted : T.primary
  const back = circle(x + size / 2, y + size / 2, size / 2, fill)
  const glyph = icon(x + size * 0.2, y + size * 0.2, size * 0.6, name, fg)
  return { back, glyph, parts: [back, glyph] }
}

// a card's head: chip, bold title, muted line under it, a value at the right
export function head(x, y, w, name, title, line, value) {
  const c = chip(x, y, 44, name)
  const t = text(x + 56, y - 1, w - 56 - 92, 26, title, { font: F.bold, size: 21 })
  const l = text(x + 56, y + 24, w - 56, 22, line, { color: T.muted, size: 16 })
  const v = text(x + w - 92, y - 1, 92, 26, value, { font: F.bold, size: 21, right: true })
  return { chip: c, title: t, line: l, value: v, parts: c.parts.concat([t, l, v]) }
}

export function button(x, y, w, h, label, click, o) {
  o = o || {}
  return createWidget(widget.BUTTON, {
    x,
    y,
    w,
    h,
    radius: o.radius !== undefined ? o.radius : Math.min(h / 2, RADIUS),
    normal_color: o.fill !== undefined ? o.fill : T.layer2,
    press_color: o.press !== undefined ? o.press : T.layer3,
    color: o.color !== undefined ? o.color : T.fg,
    text: label,
    text_size: o.size || 22,
    font: o.font || F.medium,
    click_func: () => click(),
  })
}

// a round button with an icon (the media player's)
export function iconButton(x, y, size, name, click, o) {
  o = o || {}
  const b = button(x, y, size, size, '', click, { radius: size / 2, fill: o.fill, press: o.press })
  const g = icon(x + size * 0.25, y + size * 0.25, size * 0.5, name, o.color !== undefined ? o.color : T.fg)
  return { button: b, glyph: g, parts: [b, g] }
}

export function setLabel(buttonRef, label) {
  if (buttonRef) buttonRef.setProperty(prop.TEXT, label)
}

// a bar of 0…1: a layer3 track, the value in a colour
export function bar(x, y, w, h, fill) {
  const back = rect(x, y, w, h, T.layer3, h / 2)
  const front = rect(x, y, Math.max(h, 1), h, fill !== undefined ? fill : T.primary, h / 2)
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

// a ring of 0…1 starting at twelve o'clock, like the shell's donuts
export function ring(cx, cy, r, width, fill) {
  const box = { x: cx - r, y: cy - r, w: 2 * r, h: 2 * r, line_width: width }
  const back = createWidget(widget.ARC, { ...box, radius: r, start_angle: -90, end_angle: 270, color: T.layer3 })
  const front = createWidget(widget.ARC, { ...box, radius: r, start_angle: -90, end_angle: -88, color: fill !== undefined ? fill : T.primary })
  return {
    parts: [back, front],
    set(value) {
      const v = Math.max(0.006, Math.min(1, Number(value) || 0))
      front.setProperty(prop.MORE, { ...box, radius: r, start_angle: -90, end_angle: -90 + 360 * v })
    },
  }
}

// the page's title, its line, and a dot for the link to the PC
// version: the build is named while there is no line of the page's own
export function header(title, line, version) {
  const l = link()
  const t = text(M + 6, 18, W - 2 * M - 40, 38, title, { font: F.bold, size: 30 })
  const sub = text(M + 6, 54, W - 2 * M - 12, 24, line || '', { color: T.muted, size: 17 })
  const dot = circle(W - M - 16, 38, 6, T.faint)
  const words = { searching: 'Suche den PC …', connecting: 'Verbinde …', handshake: 'Melde an …', unpaired: 'Nicht gekoppelt', pairing: 'Koppeln …', refused: 'Abgelehnt', off: 'Bluetooth aus' }
  let own = line || ''
  const paint = (s, detail) => {
    dot.setProperty(prop.COLOR, s === 'ready' ? T.success : s === 'unpaired' || s === 'refused' ? T.danger : T.warning)
    const said = detail || words[s] || s
    sub.setProperty(prop.TEXT, s === 'ready' ? own : version ? `${said} · v${VERSION}` : said)
  }
  const now = l.status()
  paint(now.status, now.detail)
  const off = l.onStatus(paint)
  return {
    title: t,
    line: sub,
    off,
    setLine(value) {
      own = value || ''
      if (l.status().status === 'ready') sub.setProperty(prop.TEXT, own)
    },
  }
}

// widgets made for a list, deleted together when it is drawn again
export function group() {
  let made = []
  return {
    add(w) {
      if (w && w.parts) w.parts.forEach((p) => made.push(p))
      else if (w) made.push(w)
      return w
    },
    clear() {
      made.forEach((w) => deleteWidget(w))
      made = []
    },
  }
}

// widgets that react to a tap anywhere on them (a text over a button would
// take the touch from it); a finger that scrolled the page did not mean it
export function tappable(widgets, tap) {
  let from = null
  widgets.forEach((w) => {
    w.addEventListener(event.CLICK_DOWN, (info) => (from = info))
    w.addEventListener(event.CLICK_UP, (info) => {
      if (from && Math.abs(info.x - from.x) + Math.abs(info.y - from.y) < 12) tap()
      from = null
    })
  })
}

export function go(page) {
  push({ url: 'page/' + page })
}

// the subscriptions a page takes, undone together when it goes
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

// "5 h 42", "16 min": how the shell writes a span
export function span(seconds) {
  const minutes = Math.round((seconds || 0) / 60)
  if (minutes < 60) return `${minutes} min`
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return m ? `${h} h ${m < 10 ? '0' : ''}${m}` : `${h} h`
}

export { event, prop, I }
