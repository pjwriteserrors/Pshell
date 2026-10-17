// The 3D printer: what it prints, how far, how long still, its heat; pause,
// go on, the light.

import { showToast } from '@zos/interaction'
import * as U from '../lib/ui.js'

const { C, M, W } = U

let s = null
let ui = {}
let printer = null

function call(action, args) {
  U.link().call('printer', action, args || {}, (ok, e) => !ok && showToast({ content: String(e) }))
}

function paint(d) {
  printer = d
  if (!d || !d.configured) {
    U.set(ui.status, d ? 'Kein Drucker eingerichtet' : '')
    return
  }
  U.set(ui.name, d.name)
  U.set(ui.status, !d.online ? 'Nicht erreichbar' : d.error || d.status)
  U.color(ui.status, d.error ? C.bad : d.printing ? C.accent : C.dim)
  const printing = d.printing || d.paused
  U.set(ui.title, printing ? d.title : '')
  ui.progress.set(printing ? d.progress / 100 : 0)
  U.set(ui.percent, printing ? `${Math.round(d.progress)} %` : '')
  U.set(ui.left, printing ? `noch ${U.clock(d.left)} · Schicht ${d.layer}/${d.layers}` : '')
  const heat = (now, target) => (now === null || now === undefined ? '–' : `${Math.round(now)}°${target ? ' / ' + Math.round(target) + '°' : ''}`)
  U.set(ui.heat, `Düse ${heat(d.nozzle, d.nozzleTarget)}   Bett ${heat(d.bed, d.bedTarget)}`)
  U.setLabel(ui.pause, d.paused ? 'Weiter' : 'Pause')
  ui.pause.setProperty(U.prop.VISIBLE, !!printing)
  U.setLabel(ui.light, d.light ? 'Licht aus' : 'Licht an')
}

Page({
  build() {
    U.themed()
    s = U.scope()
    const head = U.header('Drucker')
    s.keep(head.off)
    ui.name = U.text(M, 62, W - 2 * M, 28, '', { size: 18, color: C.dim })
    ui.status = U.text(M, 90, W - 2 * M, 34, '', { size: 24 })
    ui.title = U.text(M, 128, W - 2 * M, 30, '', { size: 20 })
    ui.progress = U.bar(M, 166, W - 2 * M, 12)
    ui.percent = U.text(M, 184, 120, 32, '', { size: 26 })
    ui.left = U.text(M + 110, 184, W - 2 * M - 110, 32, '', { size: 18, color: C.dim, right: true })
    ui.heat = U.text(M, 226, W - 2 * M, 30, '', { size: 20 })
    const half = (W - 2 * M - 10) / 2
    ui.pause = U.button(M, 272, half, 72, 'Pause', () => call(printer && printer.paused ? 'resume' : 'pause'), { size: 24 })
    ui.light = U.button(M + half + 10, 272, half, 72, 'Licht', () => call('light', { on: !(printer && printer.light) }), { size: 24 })
    s.sub('printer', paint)
  },
  onDestroy() {
    s.end()
  },
})
