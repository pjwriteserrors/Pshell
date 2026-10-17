// The browser's downloads on the PC: what is running and how far; a tap
// pauses or goes on.

import { showToast } from '@zos/interaction'
import * as U from '../lib/ui.js'

const { C, M, W } = U

let s = null
let list = null
let ui = {}

function size(bytes) {
  if (bytes >= 1e9) return (bytes / 1e9).toFixed(1) + ' GB'
  if (bytes >= 1e6) return (bytes / 1e6).toFixed(1) + ' MB'
  return Math.round(bytes / 1e3) + ' kB'
}

function call(action, key) {
  U.link().call('downloads', action, { key }, (ok, e) => !ok && showToast({ content: String(e) }))
}

function paint(d) {
  list.clear()
  const items = (d && d.items) || []
  U.set(ui.speed, d && d.speed ? `${size(d.speed)}/s` : '')
  U.set(ui.empty, items.length ? '' : d ? 'Keine Downloads' : '')
  items.forEach((item, i) => {
    const y = 70 + i * 104
    const running = item.state === 'running' || item.state === 'in_progress'
    const paused = item.state === 'paused'
    const tap = () => {
      if (running) call('pause', item.key)
      else if (paused && item.canResume) call('resume', item.key)
    }
    const row = U.card(M, y, W - 2 * M, 94, tap)
    row.add(U.text(M + 16, y + 8, W - 2 * M - 32, 30, item.name, { size: 20 }))
    const done = item.state === 'done'
    const status = done
      ? `fertig · ${size(item.total)}`
      : item.state === 'failed'
        ? 'fehlgeschlagen'
        : `${size(item.received)}${item.total ? ' / ' + size(item.total) : ''}${paused ? ' · pausiert' : ''}`
    row.add(U.text(M + 16, y + 38, W - 2 * M - 32, 26, status, { size: 18, color: done ? C.faint : C.dim }))
    row.parts.forEach((w) => list.add(w))
    if (!done) {
      const progress = U.bar(M + 16, y + 72, W - 2 * M - 32, 8, paused ? C.faint : C.accent)
      progress.set(item.total ? item.received / item.total : 0)
      progress.parts.forEach((w) => list.add(w))
    }
  })
  list.add(U.rect(0, 70 + items.length * 104 + 30, W, 2, C.bg))
}

Page({
  build() {
    U.themed()
    s = U.scope()
    list = U.group()
    const head = U.header('Downloads')
    s.keep(head.off)
    ui.speed = U.text(M + 180, 22, W - 2 * M - 220, 30, '', { size: 18, color: C.dim, right: true })
    ui.empty = U.text(M, 120, W - 2 * M, 40, '', { size: 22, color: C.dim, center: true })
    s.sub('downloads', paint)
  },
  onDestroy() {
    s.end()
  },
})
