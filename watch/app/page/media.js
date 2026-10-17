// The media player: what plays on the PC, where it is, play/pause and skip,
// and the volume – the one thing besides the mouse the watch does.

import * as U from '../lib/ui.js'

const { T, F, M, W } = U
const CW = W - 2 * M

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
  const has = d && d.has
  U.set(ui.title, has ? d.title || '–' : 'Nichts spielt')
  U.set(ui.artist, has ? d.artist || '' : '')
  ui.head.setLine(has ? d.player : '')
  U.setIcon(ui.play.glyph, has && d.playing ? 'pause' : 'play')
  U.color(ui.prev.glyph, has && d.prev ? T.fg : T.faint)
  U.color(ui.next.glyph, has && d.next ? T.fg : T.faint)
  tick()
}

// the position runs on between snapshots: from where it was, when, at what rate
function tick() {
  const d = media
  if (!d || !d.has) {
    ui.progress.set(0)
    U.set(ui.at, '')
    U.set(ui.length, '')
    return
  }
  let position = d.pos
  if (d.playing && d.at) position += ((Date.now() - d.at) / 1000) * (d.rate || 1)
  if (d.len) position = Math.min(position, d.len)
  ui.progress.set(d.len ? position / d.len : 0)
  U.set(ui.at, U.clock(position))
  U.set(ui.length, d.len ? U.clock(d.len) : '')
}

function paintSound(d) {
  if (!d) return
  U.set(ui.volume, d.muted ? 'stumm' : `${d.volume} %`)
  ui.level.set(d.volume / 100)
  ui.level.color(d.muted ? T.faint : T.primary)
  U.setIcon(ui.mute, d.muted ? 'volume_off' : d.volume > 60 ? 'volume_high' : d.volume > 25 ? 'volume_medium' : 'volume_low')
  U.color(ui.mute, d.muted ? T.danger : T.primary)
}

Page({
  build() {
    U.themed()
    s = U.scope()
    ui.head = U.header('Medien', '')
    s.keep(ui.head.off)

    ui.title = U.text(M + 6, 88, CW - 12, 64, '', { font: F.bold, size: 25, wrap: true, top: true })
    ui.artist = U.text(M + 6, 154, CW - 12, 24, '', { size: 18, color: T.muted })
    ui.progress = U.bar(M + 6, 194, CW - 12, 6)
    ui.at = U.text(M + 6, 206, 120, 22, '', { size: 15, color: T.muted })
    ui.length = U.text(W - M - 126, 206, 120, 22, '', { size: 15, color: T.muted, right: true })

    const big = 92
    const small = 68
    const mid = W / 2
    ui.prev = U.iconButton(mid - big / 2 - 22 - small, 244 + (big - small) / 2, small, 'skip_previous', () => call('previous'))
    ui.play = U.iconButton(mid - big / 2, 244, big, 'play', () => call('playPause'), { fill: T.primary, press: T.primaryContainer, color: T.onPrimary })
    ui.next = U.iconButton(mid + big / 2 + 22, 244 + (big - small) / 2, small, 'skip_next', () => call('next'))

    U.card(M, 356, CW, 76)
    ui.mute = U.icon(M + 16, 370, 30, 'volume_high', T.primary)
    U.tappable([ui.mute], () => sound('mute'))
    ui.volume = U.text(M + 52, 366, 90, 36, '', { font: F.bold, size: 20 })
    ui.level = U.bar(M + 18, 412, CW - 36 - 124, 6)
    U.iconButton(W - M - 124, 364, 56, 'volume_minus', () => sound('adjust', { delta: -0.05 }))
    U.iconButton(W - M - 64, 364, 56, 'volume_plus', () => sound('adjust', { delta: 0.05 }))
    U.rect(0, 470, W, 1, T.bg)

    s.sub('media', paintMedia)
    s.sub('sound', paintSound)
    paintMedia(U.link().state('media'))
    ticker = setInterval(tick, 1000)
  },
  onDestroy() {
    clearInterval(ticker)
    s.end()
  },
})
