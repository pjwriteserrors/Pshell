// Home: what the PC is up to at a glance, and a tile for each page. Tiles of
// a plugin that is off on the PC are left out.

import * as U from '../lib/ui.js'

const { C, M, W } = U

const PAGES = [
  { page: 'mouse', label: 'Maus', plugin: 'phone-touchpad' },
  { page: 'media', label: 'Medien', plugin: 'media' },
  { page: 'commands', label: 'Befehle', plugin: 'phone-commands' },
  { page: 'agents', label: 'Agenten', plugin: 'agents' },
  { page: 'pc', label: 'PC', plugin: null },
  { page: 'printer', label: 'Drucker', plugin: 'printer' },
  { page: 'downloads', label: 'Downloads', plugin: 'downloads' },
]

let s = null
let tiles = null
let ui = {}

let drawnPaired = null

function drawTiles(plugins) {
  tiles.clear()
  drawnPaired = U.link().paired()
  // before pairing there is only the pairing button
  if (!drawnPaired) return
  const shown = PAGES.filter((p) => !p.plugin || !plugins || plugins[p.plugin])
  const w = (W - 2 * M - 12) / 2
  shown.forEach((p, i) => {
    const x = M + (i % 2) * (w + 12)
    const y = 150 + Math.floor(i / 2) * 104
    tiles.add(U.button(x, y, w, 92, p.label, () => U.go(p.page), { radius: 26, size: 26 }))
  })
  // room to scroll past the last row
  tiles.add(U.rect(0, 150 + Math.ceil(shown.length / 2) * 104 + 20, W, 2, C.bg))
}

function paintStatus() {
  const l = U.link()
  U.set(ui.title, l.name || 'PShell')
  ui.pair.setProperty(U.prop.VISIBLE, !l.paired())
  if (drawnPaired !== l.paired()) drawTiles(l.state('plugins'))
}

function paintGlance() {
  const l = U.link()
  const media = l.state('media')
  const agents = l.state('agents')
  const parts = []
  if (media && media.has && media.playing) parts.push(media.title)
  if (agents && agents.agents) {
    const waiting = agents.agents.filter((a) => a.state !== 'busy').length
    const busy = agents.agents.length - waiting
    if (busy) parts.push(`${busy} Agent${busy > 1 ? 'en' : ''} arbeite${busy > 1 ? 'n' : 't'}`)
    if (waiting) parts.push(`${waiting} warte${waiting > 1 ? 'n' : 't'}`)
  }
  U.set(ui.glance, parts.join(' · '))
}

Page({
  build() {
    U.themed()
    s = U.scope()
    tiles = U.group()
    const head = U.header('PShell')
    ui.title = head.title
    s.keep(head.off)
    const line = U.linkLine(56)
    s.keep(line.off)
    ui.glance = U.text(M, 84, W - 2 * M, 52, '', { size: 20, color: C.dim, wrap: true })
    ui.pair = U.button(M, 150, W - 2 * M, 92, 'Mit dem PC koppeln', () => U.go('pair'), { fill: C.accent, color: 0x000000, size: 26, radius: 26 })

    drawTiles(U.link().state('plugins'))
    s.sub('plugins', (p) => drawTiles(p))
    s.sub('theme', () => U.themed())
    s.sub('link', paintStatus)
    s.sub('media', paintGlance)
    s.sub('agents', paintGlance)
    s.keep(U.link().onStatus(paintStatus))
    paintStatus()
  },
  onDestroy() {
    s.end()
  },
})
