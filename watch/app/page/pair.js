// Pairing: the watch makes a secret and shows its four-digit code; the PC
// shows the same code in a notification and asks whether to pair.

import { back } from '@zos/router'
import * as U from '../lib/ui.js'

const { C, M, W } = U

let s = null
let ui = {}

function paint(status, detail) {
  const l = U.link()
  if (status === 'pairing') {
    U.set(ui.code, l.code)
    U.set(ui.hint, 'Am PC erscheint eine Frage mit demselben Code. Dort auf „Koppeln“ tippen.')
    U.setLabel(ui.go, 'Abbrechen')
  } else if (status === 'ready' || status === 'handshake') {
    U.set(ui.code, 'OK')
    U.set(ui.hint, 'Gekoppelt.')
    setTimeout(() => back(), 1200)
  } else {
    U.set(ui.code, '')
    U.set(ui.hint, detail || 'Der PC muss in der Nähe sein, mit eingeschaltetem Watch-Plugin.')
    U.setLabel(ui.go, 'Koppeln')
  }
}

Page({
  build() {
    s = U.scope()
    const head = U.header('Koppeln')
    s.keep(head.off)
    ui.code = U.text(M, 90, W - 2 * M, 110, '', { size: 84, center: true, color: C.accent })
    ui.hint = U.text(M, 205, W - 2 * M, 120, '', { size: 22, center: true, wrap: true, color: C.dim })
    ui.go = U.button(M + 40, 340, W - 2 * M - 80, 72, 'Koppeln', () => {
      const l = U.link()
      if (l.status().status === 'pairing') l.cancelPairing()
      else l.pair()
    }, { fill: C.accent, color: 0x000000, size: 26 })
    s.keep(U.link().onStatus(paint))
    const now = U.link().status()
    paint(now.status, now.detail)
  },
  onDestroy() {
    s.end()
  },
})
