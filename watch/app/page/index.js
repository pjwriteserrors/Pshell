// Home: the PC at a glance, in cards like the shell's panels – agents, what
// plays, the system, the printer, downloads, weather, screen time, the small
// things. Above them the two things the watch does: mouse and media.
//
// The cards are laid out again only when their shape changes (an agent more,
// a print starts); otherwise their texts and bars are updated in place.

import { localStorage } from '@zos/storage'
import { push } from '@zos/router'
import { writeJson } from '../lib/store.js'
import { summary } from '../lib/summary.js'
import { VERSION } from '../lib/version.js'
import * as U from '../lib/ui.js'

const { T, F, M, W, GAP } = U
const X = M
const CW = W - 2 * M
const TOPICS = ['agents', 'media', 'system', 'printer', 'downloads', 'weather', 'screentime', 'updates', 'messages', 'quick', 'plugins', 'session', 'sound', 'connections', 'pcs', 'machines', 'recording']

let s = null
let made = null
let head = null
let shape = ''
let painters = []
let ticker = null
const st = {}

const DAYS = { Mon: 'Mo', Tue: 'Di', Wed: 'Mi', Thu: 'Do', Fri: 'Fr', Sat: 'Sa', Sun: 'So' }
const WEEKDAYS = ['Sonntag', 'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag']

function plugin(name) {
  const p = st.plugins
  return !p || p[name] !== false
}

// ── the cards: each knows when it shows, its height, and how to draw ──────
const CARDS = [
  {
    id: 'agents',
    shows: () => plugin('agents') && st.agents && st.agents.agents && st.agents.agents.length,
    key: () => st.agents.agents.length,
    height: () => 76 + st.agents.agents.length * 84,
    build(y, add) {
      const agents = st.agents.agents
      const h = add(U.head(X + 16, y + 16, CW - 32, 'robot', 'Agenten', '', ''))
      const rows = agents.map((a, i) => {
        const top = y + 76 + i * 84
        const dot = add(U.circle(X + 26, top + 14, 6, T.warning))
        const topic = add(U.text(X + 42, top, CW - 58, 50, '', { size: 19, wrap: true, top: true, lineSpace: 2 }))
        const meta = add(U.text(X + 42, top + 52, CW - 58, 22, '', { size: 16, color: T.muted }))
        return { dot, topic, meta }
      })
      return () => {
        const list = st.agents.agents
        const busy = list.filter((a) => a.state === 'busy').length
        const waiting = list.length - busy
        U.set(h.line, [busy ? `${busy} arbeite${busy > 1 ? 'n' : 't'}` : '', waiting ? `${waiting} warte${waiting > 1 ? 'n' : 't'}` : ''].filter(Boolean).join(' · '))
        U.set(h.value, list.length)
        list.forEach((a, i) => {
          const r = rows[i]
          if (!r) return
          U.color(r.dot, a.state === 'busy' ? T.warning : T.success)
          U.set(r.topic, a.topic || a.agent)
          U.set(r.meta, `${a.agent} · ${a.state === 'busy' ? 'arbeitet' : 'wartet'}${a.since ? ' · seit ' + U.span((Date.now() - a.since) / 1000) : ''}`)
        })
      }
    },
  },
  {
    id: 'media',
    shows: () => plugin('media') && st.media && st.media.has,
    key: () => 1,
    height: () => 132,
    tap: () => U.go('media'),
    build(y, add) {
      const c = add(U.chip(X + 16, y + 16, 44, 'music'))
      const title = add(U.text(X + 72, y + 14, CW - 88, 26, '', { font: F.bold, size: 21 }))
      const artist = add(U.text(X + 72, y + 40, CW - 88, 22, '', { size: 16, color: T.muted }))
      const progress = add(U.bar(X + 16, y + 84, CW - 32, 6))
      const time = add(U.text(X + 16, y + 96, CW - 32, 22, '', { size: 16, color: T.muted }))
      const state = add(U.text(X + 16, y + 96, CW - 32, 22, '', { size: 16, color: T.muted, right: true }))
      return () => {
        const d = st.media
        U.setIcon(c.glyph, d.playing ? 'play' : 'pause')
        U.set(title, d.title || '–')
        U.set(artist, [d.artist, d.player].filter(Boolean).join(' · '))
        let position = d.pos
        if (d.playing && d.at) position += ((Date.now() - d.at) / 1000) * (d.rate || 1)
        if (d.len) position = Math.min(position, d.len)
        progress.set(d.len ? position / d.len : 0)
        U.set(time, d.len ? `${U.clock(position)} / ${U.clock(d.len)}` : U.clock(position))
        U.set(state, d.playing ? 'läuft' : 'pausiert')
      }
    },
  },
  {
    id: 'pc',
    shows: () => st.session || st.quick || st.sound,
    key: () => (st.recording && st.recording.active ? 'r' : ''),
    height: () => 76 + 2 * 52 + (st.recording && st.recording.active ? 52 : 0) + 8,
    build(y, add) {
      const h = add(U.head(X + 16, y + 16, CW - 32, 'monitor_dashboard', 'Zustand', '', ''))
      const half = (CW - 32 - GAP) / 2
      const pill = (x, top, name) => {
        add(U.rect(x, top, half, 44, T.layer2, 22))
        const glyph = add(U.icon(x + 12, top + 10, 24, name, T.primary))
        const words = add(U.text(x + 42, top, half - 50, 44, '', { size: 17, font: F.medium }))
        return { glyph, words }
      }
      const dnd = pill(X + 16, y + 76, 'bell')
      const awake = pill(X + 16 + half + GAP, y + 76, 'coffee')
      const volume = pill(X + 16, y + 128, 'volume_high')
      const net = pill(X + 16 + half + GAP, y + 128, 'ethernet')
      const rec = st.recording && st.recording.active ? pill(X + 16, y + 180, 'record_rec') : null
      return () => {
        const session = st.session || {}
        const quick = st.quick || {}
        const sound = st.sound || {}
        const network = quick.network || {}
        U.set(h.line, [session.locked ? 'gesperrt' : 'entsperrt', network.online === false ? 'offline' : network.ip].filter(Boolean).join(' · '))
        U.setIcon(dnd.glyph, quick.dnd ? 'bell_off' : 'bell')
        U.color(dnd.glyph, quick.dnd ? T.warning : T.muted)
        U.set(dnd.words, quick.dnd ? 'Nicht stören' : 'Mitteilungen')
        U.color(awake.glyph, quick.keepAwake ? T.primary : T.muted)
        U.set(awake.words, quick.keepAwake ? 'Bleibt wach' : 'Schläft ein')
        U.setIcon(volume.glyph, sound.muted ? 'volume_off' : 'volume_high')
        U.set(volume.words, sound.muted ? 'stumm' : `${sound.volume || 0} % · ${sound.sink || ''}`)
        U.setIcon(net.glyph, network.signal >= 0 ? 'wifi' : 'ethernet')
        U.color(net.glyph, network.online === false ? T.danger : T.primary)
        U.set(net.words, network.label || '–')
        if (rec) U.set(rec.words, `Aufnahme · ${U.span((Date.now() - st.recording.startedAt) / 1000)}`)
        if (rec) U.color(rec.glyph, T.danger)
      }
    },
  },
  {
    id: 'system',
    tap: () => detail('system'),
    shows: () => plugin('system-monitor') && st.system,
    key: () => (st.system.disks || []).length,
    height: () => 150 + (st.system.disks || []).length * 40,
    build(y, add) {
      const cpu = add(U.ring(X + 70, y + 72, 48, 12))
      const cpuText = add(U.text(X + 22, y + 52, 96, 32, '', { font: F.bold, size: 26, center: true }))
      add(U.text(X + 22, y + 82, 96, 20, 'CPU', { size: 15, color: T.muted, center: true }))
      const memLabel = add(U.text(X + 140, y + 26, CW - 156, 24, '', { font: F.medium, size: 18 }))
      const mem = add(U.bar(X + 140, y + 56, CW - 156, 8, T.secondary))
      const extra = add(U.text(X + 140, y + 74, CW - 156, 48, '', { size: 16, color: T.muted, wrap: true, top: true }))
      const disks = (st.system.disks || []).map((k, i) => {
        const top = y + 140 + i * 40
        const label = add(U.text(X + 16, top, CW - 32, 20, '', { size: 16, color: T.muted }))
        const b = add(U.bar(X + 16, top + 24, CW - 32, 6, T.tertiary))
        return { label, b }
      })
      return () => {
        const d = st.system
        cpu.set(d.cpu / 100)
        U.set(cpuText, `${d.cpu}%`)
        U.set(memLabel, `RAM ${d.memory} %`)
        mem.set(d.memory / 100)
        U.set(extra, [d.battery ? `Akku ${d.battery}` : '', d.mouse ? `Maus ${d.mouse}` : ''].filter(Boolean).join('\n'))
        ;(d.disks || []).forEach((k, i) => {
          if (!disks[i]) return
          U.set(disks[i].label, `${k.name} · ${k.free} frei`)
          disks[i].b.set(k.usage / 100)
        })
      }
    },
  },
  {
    id: 'printer',
    shows: () => plugin('printer') && st.printer && st.printer.configured,
    key: () => (st.printer.printing || st.printer.paused ? 'p' : 'i'),
    height: () => (st.printer.printing || st.printer.paused ? 150 : 96),
    build(y, add) {
      const printing = st.printer.printing || st.printer.paused
      const h = add(U.head(X + 16, y + 16, CW - 32, 'printer_3d', st.printer.name || 'Drucker', '', ''))
      const heat = add(U.text(X + 16, y + 66, CW - 32, 22, '', { size: 16, color: T.muted }))
      const progress = printing ? add(U.bar(X + 16, y + 100, CW - 32, 8)) : null
      const left = printing ? add(U.text(X + 16, y + 114, CW - 32, 22, '', { size: 16, color: T.muted })) : null
      return () => {
        const d = st.printer
        U.set(h.line, !d.online ? 'nicht erreichbar' : d.error || (d.printing || d.paused ? d.title || d.status : d.status))
        U.color(h.line, d.error ? T.danger : T.muted)
        U.set(h.value, d.printing || d.paused ? `${Math.round(d.progress)} %` : '')
        const temp = (now, target) => (now === null || now === undefined ? '–' : `${Math.round(now)}°${target ? ' → ' + Math.round(target) + '°' : ''}`)
        U.set(heat, `Düse ${temp(d.nozzle, d.nozzleTarget)} · Bett ${temp(d.bed, d.bedTarget)}`)
        if (progress) progress.set(d.progress / 100)
        if (left) U.set(left, d.paused ? 'pausiert' : `noch ${U.span(d.left)} · Schicht ${d.layer} / ${d.layers}`)
      }
    },
  },
  {
    id: 'downloads',
    shows: () => plugin('downloads') && st.downloads && active().length,
    key: () => active().length,
    height: () => 76 + active().length * 58,
    build(y, add) {
      const h = add(U.head(X + 16, y + 16, CW - 32, 'download', 'Downloads', '', ''))
      const rows = active().map((item, i) => {
        const top = y + 76 + i * 58
        return { name: add(U.text(X + 16, top, CW - 32, 22, '', { size: 17 })), b: add(U.bar(X + 16, top + 28, CW - 32, 6)) }
      })
      return () => {
        const items = active()
        U.set(h.line, st.downloads.speed ? `${size(st.downloads.speed)}/s` : 'pausiert')
        U.set(h.value, items.length)
        items.forEach((item, i) => {
          if (!rows[i]) return
          U.set(rows[i].name, item.name)
          rows[i].b.set(item.total ? item.received / item.total : 0)
          rows[i].b.color(item.state === 'paused' ? T.faint : T.primary)
        })
      }
    },
  },
  {
    id: 'connections',
    shows: () => plugin('connections') && st.connections && st.connections.apps && st.connections.apps.length,
    key: () => Math.min(4, st.connections.apps.length),
    height: () => 76 + Math.min(4, st.connections.apps.length) * 40 + 8,
    tap: () => detail('connections'),
    build(y, add) {
      const h = add(U.head(X + 16, y + 16, CW - 32, 'lan', 'Verbindungen', '', ''))
      const rows = st.connections.apps.slice(0, 4).map((app, i) => {
        const top = y + 76 + i * 40
        return {
          label: add(U.text(X + 16, top, CW - 120, 32, '', { size: 18 })),
          value: add(U.text(X + CW - 116, top, 100, 32, '', { size: 18, font: F.bold, right: true })),
        }
      })
      return () => {
        const apps = st.connections.apps
        const total = apps.reduce((n, a) => n + a.conns, 0)
        const places = st.connections.places || []
        U.set(h.value, total)
        U.set(h.line, places.length ? `nach ${places.slice(0, 2).map((p) => p.city).join(', ')}${places.length > 2 ? ' …' : ''}` : 'offen')
        apps.slice(0, 4).forEach((app, i) => {
          U.set(rows[i].label, app.title)
          U.set(rows[i].value, app.conns)
        })
      }
    },
  },
  {
    id: 'weather',
    tap: () => detail('weather'),
    shows: () => plugin('weather') && st.weather && st.weather.available,
    key: () => (st.weather.hourly || []).length,
    height: () => 186,
    build(y, add) {
      const glyph = add(U.icon(X + 16, y + 16, 52, 'weather_cloudy', T.primary))
      const temp = add(U.text(X + 80, y + 12, 120, 44, '', { font: F.bold, size: 38 }))
      const desc = add(U.text(X + 80, y + 54, CW - 96, 22, '', { size: 16, color: T.muted }))
      const sun = add(U.text(X + CW - 140, y + 16, 124, 22, '', { size: 16, color: T.muted, right: true }))
      const cols = (st.weather.hourly || []).map((hour, i) => {
        const w = (CW - 32) / 6
        const left = X + 16 + i * w
        return {
          label: add(U.text(left, y + 96, w, 20, '', { size: 15, color: i ? T.muted : T.primary, center: true, font: i ? F.sans : F.bold })),
          icon: add(U.icon(left + w / 2 - 14, y + 120, 28, 'weather_cloudy', T.fg)),
          temp: add(U.text(left, y + 152, w, 22, '', { size: 17, center: true, font: F.medium })),
        }
      })
      return () => {
        const d = st.weather
        U.setIcon(glyph, weatherIcon(d.icon))
        U.set(temp, `${d.temperature}°`)
        U.set(desc, `${d.description} · ${d.city}`)
        U.set(sun, d.sunrise ? `${d.sunrise} · ${d.sunset}` : '')
        ;(d.hourly || []).forEach((hour, i) => {
          if (!cols[i]) return
          U.set(cols[i].label, i ? hour.label : 'Jetzt')
          U.setIcon(cols[i].icon, weatherIcon(hour.icon))
          U.set(cols[i].temp, `${hour.temp}°`)
        })
      }
    },
  },
  {
    id: 'screentime',
    tap: () => detail('screentime'),
    shows: () => plugin('screentime') && st.screentime,
    key: () => (st.screentime.week || []).length,
    height: () => 210,
    build(y, add) {
      const h = add(U.head(X + 16, y + 16, CW - 32, 'monitor', 'Bildschirmzeit', '', ''))
      const week = st.screentime.week || []
      const bw = 26
      const step = (CW - 32 - bw) / Math.max(1, week.length - 1)
      const bars = week.map((day, i) => {
        const left = X + 16 + i * step
        return {
          track: add(U.rect(left, y + 80, bw, 80, T.layer2, 8)),
          fill: add(U.rect(left, y + 150, bw, 10, T.subtle, 8)),
          label: add(U.text(left - 8, y + 166, bw + 16, 20, '', { size: 14, color: T.muted, center: true })),
          left,
        }
      })
      return () => {
        const d = st.screentime
        U.set(h.value, U.span(d.total))
        const versus = d.versus
        U.set(h.line, versus === null || versus === undefined ? 'heute' : `${versus >= 0 ? '+' : '−'}${U.span(Math.abs(versus))} zu gestern`)
        const most = Math.max(1, ...(d.week || []).map((w) => w.total))
        ;(d.week || []).forEach((day, i) => {
          const b = bars[i]
          if (!b) return
          const height = day.total ? Math.max(10, Math.round((80 * day.total) / most)) : 0
          b.fill.setProperty(U.prop.MORE, { x: b.left, y: y + 160 - height, w: bw, h: Math.max(height, 1) })
          U.show(b.fill, height > 0)
          U.color(b.fill, day.today ? T.primary : T.subtle)
          U.set(b.label, DAYS[day.label] || day.label)
          U.color(b.label, day.today ? T.primary : T.muted)
        })
      }
    },
  },
  {
    id: 'small',
    tap: () => st.updates && st.updates.count && detail('updates'),
    shows: () => smallRows().length,
    key: () => smallRows().map((r) => r.id).join(','),
    height: () => 24 + smallRows().length * 52,
    build(y, add) {
      const rows = smallRows().map((r, i) => {
        const top = y + 14 + i * 52
        add(U.chip(X + 16, top + 4, 36, r.icon, 'plain'))
        return { id: r.id, label: add(U.text(X + 64, top + 6, CW - 160, 32, '', { size: 18 })), value: add(U.text(X + CW - 116, top + 6, 100, 32, '', { size: 18, font: F.bold, right: true })) }
      })
      return () => {
        const now = smallRows()
        rows.forEach((row) => {
          const r = now.find((x) => x.id === row.id)
          if (!r) return
          U.set(row.label, r.label)
          U.set(row.value, r.value)
        })
      }
    },
  },
]

function detail(kind) {
  push({ url: 'page/detail', params: kind })
}

function active() {
  return ((st.downloads && st.downloads.items) || []).filter((i) => i.state === 'running' || i.state === 'paused' || i.state === 'in_progress')
}

function smallRows() {
  const out = []
  if (st.updates && st.updates.count && plugin('updates')) out.push({ id: 'updates', icon: 'update', label: 'Updates', value: st.updates.count })
  if (st.messages && st.messages.running && plugin('messages')) out.push({ id: 'mail', icon: 'email_outline', label: 'Ungelesen', value: st.messages.unread })
  ;((st.quick && st.quick.devices) || []).filter((b) => b.connected).forEach((b) => {
    out.push({ id: 'bt' + b.address, icon: 'headphones', label: b.name, value: b.battery || 'verbunden' })
  })
  ;((st.machines && st.machines.vms) || []).forEach((v, i) => {
    out.push({ id: 'vm' + i, icon: 'server', label: v.name, value: v.running ? 'läuft' : 'aus' })
  })
  ;((st.pcs && st.pcs.devices) || []).forEach((pc, i) => {
    out.push({ id: 'pc' + i, icon: 'laptop', label: pc.name, value: pc.connected ? 'verbunden' : 'getrennt' })
  })
  return out
}

function size(bytes) {
  if (bytes >= 1e9) return (bytes / 1e9).toFixed(1) + ' GB'
  if (bytes >= 1e6) return (bytes / 1e6).toFixed(1) + ' MB'
  return Math.round(bytes / 1e3) + ' kB'
}

function weatherIcon(name) {
  return U.I[name] ? name : String(name || '').indexOf('night') >= 0 ? 'weather_night' : 'weather_cloudy'
}

// ── layout ────────────────────────────────────────────────────────────────
function actions(add) {
  const half = (CW - GAP) / 2
  const tile = (x, name, label, page) => {
    const back = add(U.rect(x, 90, half, 64, T.layer2, U.RADIUS))
    const glyph = add(U.icon(x + 18, 108, 28, name, T.primary))
    const words = add(U.text(x + 56, 90, half - 64, 64, label, { font: F.medium, size: 21 }))
    U.tappable([back, glyph, words], () => U.go(page))
  }
  tile(X, 'mouse', 'Maus', 'mouse')
  tile(X + half + GAP, 'music', 'Medien', 'media')
}

function layout() {
  const paired = U.link().paired()
  const shown = paired ? CARDS.filter((c) => c.shows()) : []
  const next = (paired ? 'p' : 'u') + shown.map((c) => c.id + ':' + c.key()).join('|')
  if (next === shape) {
    painters.forEach((p) => p())
    return
  }
  shape = next
  made.clear()
  painters = []
  const add = (w) => made.add(w)
  if (!paired) {
    add(U.text(X, 100, CW, 80, 'Die Uhr kennt den PC noch nicht.', { size: 20, color: T.muted, wrap: true, center: true }))
    add(U.button(X + 30, 190, CW - 60, 72, 'Mit dem PC koppeln', () => U.go('pair'), { fill: T.primary, color: T.onPrimary, font: F.bold }))
    return
  }
  actions(add)
  let y = 166
  shown.forEach((c) => {
    const h = c.height()
    const back = add(U.card(X, y, CW, h))
    const parts = []
    const collect = (w) => {
      parts.push(...(w && w.parts ? w.parts : [w]))
      return made.add(w)
    }
    painters.push(c.build(y, collect))
    if (c.tap) U.tappable([back].concat(parts), c.tap)
    y += h + GAP
  })
  // room to scroll the last card clear of the bottom corners
  add(U.rect(0, y + 40, W, 1, T.bg))
  painters.forEach((p) => p())
}

function paintHeader() {
  const now = new Date()
  const two = (n) => (n < 10 ? '0' : '') + n
  if (!head) return
  U.set(head.title, U.link().name || 'PShell')
  head.setLine(`${WEEKDAYS[now.getDay()]} · ${two(now.getHours())}:${two(now.getMinutes())} · v${VERSION}`)
}

// what the face shows of the PC: the latest numbers, written for it to read
let lastSave = 0
function save() {
  if (Date.now() - lastSave < 20000) return
  lastSave = Date.now()
  writeJson('pc.json', summary((topic) => U.link().state(topic), U.link().name))
  U.link().keepCache(TOPICS)
}

Page({
  build() {
    U.themed()
    s = U.scope()
    made = U.group()
    head = U.header(U.link().name || 'PShell', '', true)
    s.keep(head.off)
    paintHeader()
    TOPICS.forEach((topic) =>
      s.sub(topic, (d) => {
        st[topic] = d
        layout()
        save()
      }),
    )
    s.sub('theme', () => U.themed())
    s.sub('link', paintHeader)
    s.keep(
      U.link().onStatus(() => {
        paintHeader()
        layout()
      }),
    )
    layout()
    // the clock in the header, a playing title's time, agents' "since"
    ticker = setInterval(() => {
      paintHeader()
      painters.forEach((p) => p())
    }, 1000)
    try {
      localStorage.setItem('opened', String(Date.now()))
    } catch (e) {}
  },
  onDestroy() {
    clearInterval(ticker)
    s.end()
  },
})
