// What plays on the PC: title, where it is, play/pause, skip; the volume below.

import * as U from '../lib/ui.js'

const { C, M, W } = U

let s = null
let ui = {}
let media = null
let ticker = null

function call(action, args) {
  U.link().call('media', action, args)
}

function sound(action, args) {
  U.link().call('sound', action, args)
}

function paintMedia(d) {
  media = d
  if (!d || !d.has) {
    U.set(ui.title, 'Nichts spielt')
    U.set(ui.artist, '')
    U.set(ui.time, '')
    ui.progress.set(0)
    U.setLabel(ui.play, 'Abspielen')
    return
  }
  U.set(ui.title, d.title || '–')
  U.set(ui.artist, [d.artist, d.player].filter(Boolean).join(' · '))
  U.setLabel(ui.play, d.playing ? 'Pause' : 'Abspielen')
  ui.prev.setProperty(U.prop.VISIBLE, !!d.prev)
  ui.next.setProperty(U.prop.VISIBLE, !!d.next)
  tick()
}

// the position goes on between snapshots: from where it was, when, and the rate
function tick() {
  const d = media
  if (!d || !d.has) return
  let position = d.pos
  if (d.playing && d.at) position += ((Date.now() - d.at) / 1000) * (d.rate || 1)
  position = Math.min(position, d.len || position)
  U.set(ui.time, d.len ? `${U.clock(position)} / ${U.clock(d.len)}` : U.clock(position))
  ui.progress.set(d.len ? position / d.len : 0)
}

function paintSound(d) {
  if (!d) return
  U.set(ui.volume, d.muted ? 'Stumm' : `${d.volume} %`)
  ui.level.set(d.volume / 100)
  ui.level.color(d.muted ? C.faint : C.accent)
  U.set(ui.sink, d.sink || '')
}

Page({
  build() {
    U.themed()
    s = U.scope()
    const head = U.header('Medien')
    s.keep(head.off)
    ui.title = U.text(M, 66, W - 2 * M, 64, '', { size: 26, wrap: true })
    ui.artist = U.text(M, 132, W - 2 * M, 28, '', { size: 18, color: C.dim })
    ui.progress = U.bar(M, 172, W - 2 * M, 8)
    ui.time = U.text(M, 184, W - 2 * M, 26, '', { size: 18, color: C.dim, right: true })

    const third = (W - 2 * M - 16) / 3
    ui.prev = U.button(M, 220, third, 76, 'Zurück', () => call('previous'), { size: 22 })
    ui.play = U.button(M + third + 8, 220, third, 76, 'Pause', () => call('playPause'), { fill: U.C.accent, color: 0x000000, size: 22 })
    ui.next = U.button(M + 2 * (third + 8), 220, third, 76, 'Weiter', () => call('next'), { size: 22 })

    ui.volume = U.text(M, 310, 150, 30, '', { size: 22 })
    ui.sink = U.text(M + 150, 310, W - 2 * M - 150, 30, '', { size: 18, color: C.dim, right: true })
    ui.level = U.bar(M, 346, W - 2 * M, 10)
    U.button(M, 370, third, 64, '-', () => sound('adjust', { delta: -0.05 }), { size: 34 })
    U.button(M + third + 8, 370, third, 64, 'Stumm', () => sound('mute'), { size: 20 })
    U.button(M + 2 * (third + 8), 370, third, 64, '+', () => sound('adjust', { delta: 0.05 }), { size: 34 })
    U.rect(0, 470, W, 2, C.bg)

    s.sub('media', paintMedia)
    s.sub('sound', paintSound)
    ticker = setInterval(tick, 1000)
  },
  onDestroy() {
    clearInterval(ticker)
    s.end()
  },
})
