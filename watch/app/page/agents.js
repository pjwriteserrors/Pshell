// The coding agents in the PC's terminals: who works, who waits for an
// answer. A tap brings the agent's window to the front on the PC.

import { showToast } from '@zos/interaction'
import * as U from '../lib/ui.js'

const { C, M, W } = U

let s = null
let list = null
let ui = {}
let ticker = null
let last = null

function since(ms) {
  const minutes = Math.floor((Date.now() - ms) / 60000)
  if (minutes < 1) return 'gerade'
  if (minutes < 60) return `${minutes} min`
  return `${Math.floor(minutes / 60)} h ${minutes % 60} min`
}

function paint(d) {
  last = d
  list.clear()
  const agents = (d && d.agents) || []
  U.set(ui.empty, agents.length ? '' : d ? 'Kein Agent läuft' : '')
  agents.forEach((a, i) => {
    const y = 70 + i * 112
    const busy = a.state === 'busy'
    const focus = () => U.link().call('agents', 'focus', { window: a.window }, (ok, e) => showToast({ content: ok ? 'Fenster vorne' : String(e) }))
    const row = U.card(M, y, W - 2 * M, 100, focus)
    row.add(U.rect(M + 16, y + 20, 10, 10, busy ? C.warn : C.good, 5))
    row.add(U.text(M + 36, y + 10, W - 2 * M - 52, 30, `${a.agent} · ${busy ? 'arbeitet' : 'wartet'} · ${a.since ? since(a.since) : ''}`, { size: 18, color: C.dim }))
    row.add(U.text(M + 16, y + 40, W - 2 * M - 32, 54, a.topic || '', { size: 22, wrap: true }))
    row.parts.forEach((w) => list.add(w))
  })
  list.add(U.rect(0, 70 + agents.length * 112 + 30, W, 2, C.bg))
}

Page({
  build() {
    U.themed()
    s = U.scope()
    list = U.group()
    const head = U.header('Agenten')
    s.keep(head.off)
    ui.empty = U.text(M, 120, W - 2 * M, 40, '', { size: 22, color: C.dim, center: true })
    s.sub('agents', paint)
    // "since" moves on
    ticker = setInterval(() => last && paint(last), 60000)
  },
  onDestroy() {
    clearInterval(ticker)
    s.end()
  },
})
