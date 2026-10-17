// One card of home in full, opened by a tap on it: the system, the weather,
// screen time, updates, connections. Which one comes as the page's parameter.

import * as U from '../lib/ui.js'

const { T, F, M, W, GAP } = U
const X = M
const CW = W - 2 * M
const DAYS = { Mon: 'Mo', Tue: 'Di', Wed: 'Mi', Thu: 'Do', Fri: 'Fr', Sat: 'Sa', Sun: 'So', Today: 'Heute' }

let s = null
let made = null
let kind = 'system'
let shape = ''

const KINDS = {
  system: {
    title: 'System',
    topic: 'system',
    key: (d) => `${(d.cpuHistory || []).length}|${(d.disks || []).length}`,
    build(d, add) {
      const head = header(add, 'Prozessor', `${d.cores} Kerne`)
      let y = 88
      add(U.card(X, y, CW, 168))
      const now = add(U.text(X + 16, y + 12, 160, 40, '', { font: F.bold, size: 34 }))
      add(U.text(X + 16, y + 50, 200, 22, 'die letzten Minuten', { size: 15, color: T.muted }))
      const history = d.cpuHistory || []
      const bw = (CW - 32) / Math.max(1, history.length)
      const bars = history.map((v, i) => add(U.rect(X + 16 + i * bw, y + 150, Math.max(2, bw - 3), 2, T.primary, 2)))
      y += 168 + GAP
      add(U.card(X, y, CW, 96))
      add(U.text(X + 16, y + 12, 190, 26, 'Arbeitsspeicher', { font: F.bold, size: 19 }))
      const memory = add(U.text(X + CW - 156, y + 12, 140, 26, '', { size: 17, color: T.muted, right: true }))
      const memoryBar = add(U.bar(X + 16, y + 56, CW - 32, 10, T.secondary))
      y += 96 + GAP
      const disks = (d.disks || []).map(() => {
        add(U.card(X, y, CW, 86))
        const name = add(U.text(X + 16, y + 10, 120, 26, '', { font: F.bold, size: 19 }))
        const text = add(U.text(X + 120, y + 10, CW - 136, 26, '', { size: 16, color: T.muted, right: true }))
        const b = add(U.bar(X + 16, y + 52, CW - 32, 10, T.tertiary))
        y += 86 + GAP
        return { name, text, b }
      })
      const extra = add(U.text(X + 6, y, CW - 12, 50, '', { size: 17, color: T.muted, wrap: true, top: true }))
      add(U.rect(0, y + 90, W, 1, T.bg))
      return (d) => {
        head.setLine(`${d.cores} Kerne · ${d.cpu} % jetzt`)
        U.set(now, `${d.cpu} %`)
        ;(d.cpuHistory || []).forEach((v, i) => {
          if (!bars[i]) return
          const h = Math.max(3, Math.round(v * 0.9))
          bars[i].setProperty(U.prop.MORE, { x: X + 16 + i * bw, y: 88 + 156 - h, w: Math.max(2, bw - 3), h })
        })
        U.set(memory, `${d.memoryUsed} / ${d.memoryTotal} GB`)
        memoryBar.set(d.memory / 100)
        ;(d.disks || []).forEach((k, i) => {
          if (!disks[i]) return
          U.set(disks[i].name, k.name)
          U.set(disks[i].text, `${k.free} frei von ${k.total}`)
          disks[i].b.set(k.usage / 100)
        })
        U.set(extra, [d.battery ? `Akku ${d.battery}` : '', d.mouse ? `Maus ${d.mouse}` : ''].filter(Boolean).join(' · '))
      }
    },
  },
  weather: {
    title: 'Wetter',
    topic: 'weather',
    key: (d) => `${(d.hourly || []).length}|${(d.daily || []).length}`,
    build(d, add) {
      const head = header(add, 'Wetter', d.city)
      let y = 88
      add(U.card(X, y, CW, 196))
      const glyph = add(U.icon(X + 16, y + 16, 64, 'weather_cloudy', T.primary))
      const temp = add(U.text(X + 92, y + 12, 140, 56, '', { font: F.bold, size: 48 }))
      const desc = add(U.text(X + 92, y + 66, CW - 108, 22, '', { size: 17, color: T.muted }))
      const facts = [
        ['thermometer', 'gefühlt'],
        ['water_percent', 'Feuchte'],
        ['weather_windy', 'Wind'],
        ['weather_sunset_up', 'Sonne'],
      ].map(([name, label], i) => {
        const left = X + 16 + (i % 2) * ((CW - 32) / 2)
        const top = y + 106 + Math.floor(i / 2) * 42
        add(U.icon(left, top + 4, 26, name, T.muted))
        return add(U.text(left + 32, top, (CW - 32) / 2 - 36, 34, '', { size: 17 }))
      })
      y += 196 + GAP
      const days = (d.daily || []).map((day, i) => {
        const top = y + i * 54
        add(U.card(X, top, CW, 46, i % 2 ? T.bg : T.layer1))
        return {
          label: add(U.text(X + 14, top, 72, 46, '', { size: 17, font: F.medium })),
          icon: add(U.icon(X + 84, top + 10, 26, 'weather_cloudy', T.fg)),
          min: add(U.text(X + 116, top, 50, 46, '', { size: 17, color: T.muted, right: true })),
          range: add(U.rect(X + 176, top + 20, 10, 6, T.primary, 3)),
          max: add(U.text(X + CW - 64, top, 50, 46, '', { size: 17, font: F.bold, right: true })),
        }
      })
      add(U.rect(0, y + days.length * 54 + 40, W, 1, T.bg))
      return (d) => {
        head.setLine(d.city)
        U.setIcon(glyph, U.I[d.icon] ? d.icon : 'weather_cloudy')
        U.set(temp, `${d.temperature}°`)
        U.set(desc, d.description)
        U.set(facts[0], d.feelsLike)
        U.set(facts[1], d.humidity)
        U.set(facts[2], d.wind)
        U.set(facts[3], d.sunrise ? `${d.sunrise} – ${d.sunset}` : '–')
        const all = d.daily || []
        const low = Math.min(...all.map((x) => x.min))
        const high = Math.max(...all.map((x) => x.max))
        const span = Math.max(1, high - low)
        const width = CW - 176 - 72
        all.forEach((day, i) => {
          const r = days[i]
          if (!r) return
          U.set(r.label, DAYS[day.label] || day.label)
          U.setIcon(r.icon, U.I[day.icon] ? day.icon : 'weather_cloudy')
          U.set(r.min, `${day.min}°`)
          U.set(r.max, `${day.max}°`)
          const left = X + 176 + Math.round((width * (day.min - low)) / span)
          const w = Math.max(10, Math.round((width * (day.max - day.min)) / span))
          r.range.setProperty(U.prop.MORE, { x: left, y: y + i * 54 + 20, w, h: 6 })
        })
      }
    },
  },
  screentime: {
    title: 'Bildschirmzeit',
    topic: 'screentime',
    key: (d) => `${(d.apps || []).length}`,
    build(d, add) {
      const head = header(add, 'Bildschirmzeit', '')
      let y = 88
      add(U.card(X, y, CW, 104))
      const total = add(U.text(X + 16, y + 10, CW - 32, 46, '', { font: F.bold, size: 38 }))
      const line = add(U.text(X + 16, y + 58, CW - 32, 22, '', { size: 16, color: T.muted }))
      const longest = add(U.text(X + 16, y + 78, CW - 32, 22, '', { size: 16, color: T.muted }))
      y += 104 + GAP
      const apps = (d.apps || []).map((app, i) => {
        const top = y + i * 58
        add(U.card(X, top, CW, 50))
        return {
          label: add(U.text(X + 16, top + 4, CW - 140, 26, '', { size: 18, font: F.medium })),
          value: add(U.text(X + CW - 116, top + 4, 100, 26, '', { size: 17, right: true })),
          b: add(U.bar(X + 16, top + 34, CW - 32, 5)),
        }
      })
      add(U.rect(0, y + apps.length * 58 + 40, W, 1, T.bg))
      return (d) => {
        head.setLine('heute')
        U.set(total, U.span(d.total))
        const v = d.versus
        U.set(line, v === null || v === undefined ? '' : `${v >= 0 ? '+' : '−'}${U.span(Math.abs(v))} gegenüber gestern`)
        U.set(longest, d.longest ? `am längsten am Stück ${U.span(d.longest)}${d.longestEnd ? ' bis ' + d.longestEnd : ''}` : '')
        const most = Math.max(1, ...(d.apps || []).map((a) => a.seconds))
        ;(d.apps || []).forEach((app, i) => {
          if (!apps[i]) return
          U.set(apps[i].label, app.label)
          U.set(apps[i].value, U.span(app.seconds))
          apps[i].b.set(app.seconds / most)
        })
      }
    },
  },
  updates: {
    title: 'Updates',
    topic: 'updates',
    key: (d) => `${(d.packages || []).length}`,
    build(d, add) {
      const head = header(add, 'Updates', '')
      const rows = (d.packages || []).map((name, i) => {
        const top = 88 + i * 52
        add(U.card(X, top, CW, 44, i % 2 ? T.bg : T.layer1))
        return add(U.text(X + 16, top, CW - 32, 44, '', { size: 18 }))
      })
      add(U.rect(0, 88 + rows.length * 52 + 40, W, 1, T.bg))
      return (d) => {
        head.setLine(`${d.count} bereit${d.count > (d.packages || []).length ? ', die ersten ' + (d.packages || []).length : ''}`)
        ;(d.packages || []).forEach((name, i) => rows[i] && U.set(rows[i], name))
      }
    },
  },
  connections: {
    title: 'Verbindungen',
    topic: 'connections',
    key: (d) => `${(d.apps || []).length}|${(d.places || []).length}`,
    build(d, add) {
      const head = header(add, 'Verbindungen', '')
      let y = 88
      const row = (top) => ({
        label: add(U.text(X + 16, top, CW - 120, 40, '', { size: 18 })),
        value: add(U.text(X + CW - 116, top, 100, 40, '', { size: 18, font: F.bold, right: true })),
      })
      add(U.text(X + 6, y, CW, 28, 'Programme', { size: 16, color: T.muted }))
      y += 32
      add(U.card(X, y, CW, (d.apps || []).length * 44 + 8))
      const apps = (d.apps || []).map((a, i) => row(y + 4 + i * 44))
      y += (d.apps || []).length * 44 + 8 + GAP
      add(U.text(X + 6, y, CW, 28, 'Orte', { size: 16, color: T.muted }))
      y += 32
      add(U.card(X, y, CW, (d.places || []).length * 44 + 8))
      const places = (d.places || []).map((p, i) => row(y + 4 + i * 44))
      add(U.rect(0, y + (d.places || []).length * 44 + 60, W, 1, T.bg))
      return (d) => {
        head.setLine(`${(d.apps || []).reduce((n, a) => n + a.conns, 0)} offen`)
        ;(d.apps || []).forEach((a, i) => {
          if (!apps[i]) return
          U.set(apps[i].label, a.title)
          U.set(apps[i].value, a.conns)
        })
        ;(d.places || []).forEach((p, i) => {
          if (!places[i]) return
          U.set(places[i].label, `${p.city}${p.cc ? ' · ' + p.cc : ''}`)
          U.set(places[i].value, p.conns)
        })
      }
    },
  },
}

let head = null
function header(add, title, line) {
  if (!head) {
    head = U.header(title, line)
    s.keep(head.off)
  }
  return head
}

let paint = null

function draw(d) {
  const spec = KINDS[kind]
  if (!d) return
  const next = spec.key(d)
  if (next !== shape || !paint) {
    shape = next
    made.clear()
    paint = spec.build(d, (w) => made.add(w))
  }
  paint(d)
}

Page({
  onInit(params) {
    kind = KINDS[params] ? params : 'system'
  },
  build() {
    U.themed()
    s = U.scope()
    made = U.group()
    head = null
    shape = ''
    paint = null
    header(null, KINDS[kind].title, '')
    s.sub(KINDS[kind].topic, draw)
  },
  onDestroy() {
    s.end()
  },
})
