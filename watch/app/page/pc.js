// The PC itself: lock it, the quick switches (do not disturb, stay awake,
// Bluetooth and its devices), and how busy it is.

import { showToast } from '@zos/interaction'
import * as U from '../lib/ui.js'

const { C, M, W } = U

let s = null
let ui = {}
let devices = null

function quick(action, args) {
  U.link().call('quick', action, args || {}, (ok, e) => !ok && showToast({ content: String(e) }))
}

function toggle(buttonRef, label, on) {
  U.setLabel(buttonRef, `${label}: ${on === null || on === undefined ? '–' : on ? 'an' : 'aus'}`)
  buttonRef.setProperty(U.prop.MORE, { normal_color: on ? 0x1d2f45 : C.card })
}

function paintSession(d) {
  if (!d) return
  U.setLabel(ui.lock, d.locked ? 'Gesperrt' : 'Sperren')
}

function paintQuick(d) {
  if (!d) return
  toggle(ui.dnd, 'Nicht stören', d.dnd)
  toggle(ui.awake, 'Wach bleiben', d.keepAwake)
  toggle(ui.bluetooth, 'Bluetooth', d.bluetooth)
  devices.clear()
  const list = (d.devices || []).filter((b) => b.name)
  list.forEach((b, i) => {
    const y = 500 + i * 70
    const label = `${b.name}${b.battery ? ' · ' + b.battery : ''}`
    devices.add(U.button(M, y, W - 2 * M, 62, label, () => quick('bluetooth', { address: b.address }), { fill: b.connected ? 0x1d2f45 : C.card, size: 20, radius: 20 }))
  })
  devices.add(U.rect(0, 500 + list.length * 70 + 30, W, 2, C.bg))
}

function paintSystem(d) {
  if (!d) return
  U.set(ui.cpu, `CPU ${d.cpu} %`)
  ui.cpuBar.set(d.cpu / 100)
  U.set(ui.memory, `RAM ${d.memory} %`)
  ui.memoryBar.set(d.memory / 100)
  const extra = []
  if (d.battery) extra.push(`Akku ${d.battery}`)
  if (d.mouse) extra.push(`Maus ${d.mouse}`)
  ;(d.disks || []).forEach((k) => extra.push(`${k.name} ${k.free} frei`))
  U.set(ui.extra, extra.join(' · '))
}

Page({
  build() {
    U.themed()
    s = U.scope()
    devices = U.group()
    const head = U.header('PC')
    s.keep(head.off)
    ui.lock = U.button(M, 66, W - 2 * M, 72, 'Sperren', () => U.link().call('session', 'lock', {}), { fill: C.accent, color: 0x000000, size: 26 })

    ui.cpu = U.text(M, 152, 170, 28, '', { size: 20 })
    ui.cpuBar = U.bar(M, 182, W - 2 * M, 8)
    ui.memory = U.text(M, 196, 170, 28, '', { size: 20 })
    ui.memoryBar = U.bar(M, 226, W - 2 * M, 8, C.good)
    ui.extra = U.text(M, 240, W - 2 * M, 50, '', { size: 18, color: C.dim, wrap: true })

    ui.dnd = U.button(M, 300, W - 2 * M, 60, 'Nicht stören', () => quick('dnd'), { size: 22, radius: 20 })
    ui.awake = U.button(M, 368, W - 2 * M, 60, 'Wach bleiben', () => quick('keepAwake'), { size: 22, radius: 20 })
    ui.bluetooth = U.button(M, 436, W - 2 * M, 60, 'Bluetooth', () => quick('bluetooth'), { size: 22, radius: 20 })

    s.sub('session', paintSession)
    s.sub('quick', paintQuick)
    s.sub('system', paintSystem)
  },
  onDestroy() {
    s.end()
  },
})
