// The commands of the phone's grid (commands.json on the PC), as a list of
// buttons. A command that asks first asks here too; one with a form or a
// terminal cannot run from the watch and is left out.

import { createModal, showToast, MODAL_CONFIRM } from '@zos/interaction'
import * as U from '../lib/ui.js'

const { C, M, W } = U

let s = null
let list = null
let ui = {}

function run(tile) {
  U.link().call('commands', 'run', { id: tile.id }, (ok, data) => {
    if (!ok) showToast({ content: String(data || 'Fehlgeschlagen') })
    else if (data && data.output) showToast({ content: String(data.output).trim().split('\n').pop().slice(0, 80) || 'Fertig' })
    else showToast({ content: `${tile.label}: gestartet` })
  })
}

function ask(tile) {
  const dialog = createModal({
    content: `${tile.label}?`,
    autoHide: true,
    onClick: (key) => {
      if (key.type === MODAL_CONFIRM) run(tile)
    },
  })
  dialog.show(true)
}

function paint(d) {
  list.clear()
  const tiles = ((d && d.tiles) || []).filter((t) => t.plain)
  U.set(ui.empty, tiles.length ? '' : d ? 'Keine Befehle' : '')
  tiles.forEach((tile, i) => {
    const y = 70 + i * 86
    const fill = tile.color === 'danger' ? 0x3a1818 : tile.on ? 0x1d2f45 : C.card
    const label = tile.text ? `${tile.label} · ${tile.text}` : tile.label
    list.add(U.button(M, y, W - 2 * M, 76, label, () => (tile.confirm ? ask(tile) : run(tile)), { fill, size: 24, radius: 22 }))
  })
  list.add(U.rect(0, 70 + tiles.length * 86 + 30, W, 2, C.bg))
}

Page({
  build() {
    U.themed()
    s = U.scope()
    list = U.group()
    const head = U.header('Befehle')
    s.keep(head.off)
    ui.empty = U.text(M, 120, W - 2 * M, 40, '', { size: 22, color: C.dim, center: true })
    s.sub('commands', paint)
  },
  onDestroy() {
    s.end()
  },
})
