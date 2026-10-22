// Pairing: the watch makes a secret and shows its four-digit code; the PC
// shows the same code in a notification and asks whether to pair.

import { back } from '@zos/router'
import * as U from '../lib/ui.js'

const { T, F, M, W } = U
const CW = W - 2 * M

let s = null
let ui = {}
let leaving = false

function paint(status, detail) {
  const l = U.link()
  if (status === 'pairing') {
    U.set(ui.code, l.code)
    U.set(ui.hint, 'Am PC erscheint eine Frage mit demselben Code. Dort auf „Koppeln“ klicken.')
    U.setLabel(ui.go, 'Abbrechen')
  } else if (l.paired()) {
    U.set(ui.code, '')
    U.set(ui.hint, 'Gekoppelt.')
    if (!leaving) {
      leaving = true
      setTimeout(() => back(), 1200)
    }
  } else {
    U.set(ui.code, '')
    U.set(ui.hint, detail || 'Der PC muss in der Nähe sein und das Plugin „Watch“ an.')
    U.setLabel(ui.go, 'Koppeln')
  }
}

Page({
  build() {
    U.themed()
    s = U.scope()
    leaving = false
    const head = U.header('Koppeln', 'mit dem PC')
    s.keep(head.off)
    U.card(M, 92, CW, 236)
    U.chip(W / 2 - 26, 108, 52, 'link_variant')
    ui.code = U.text(M, 164, CW, 80, '', { font: F.bold, size: 64, center: true, color: T.primary })
    ui.hint = U.text(M + 20, 240, CW - 40, 80, '', { size: 17, center: true, wrap: true, color: T.muted })
    ui.go = U.button(M + 40, 344, CW - 80, 68, 'Koppeln', () => {
      const l = U.link()
      if (l.status().status === 'pairing') l.cancelPairing()
      else l.pair()
    }, { fill: T.primary, press: T.primaryContainer, color: T.onPrimary, font: F.bold, size: 22 })
    s.keep(U.link().onStatus(paint))
    const now = U.link().status()
    paint(now.status, now.detail)
  },
  onDestroy() {
    s.end()
  },
})
