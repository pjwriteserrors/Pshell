// What the watch knows about its wearer, for the PC (scripts/phone/
// pshell_phone/health.py keeps the history, the shell's >watch shows it).
// Read straight from the watch's sensors: last night's sleep with its stages
// and naps, the heart through the day, stress, blood oxygen, skin
// temperature, and the day's activity. Minutes are counted from 0:00 of the
// watch's day, as the sensors give them; the PC places them in time with
// `at` and `minute` (now, in the same count). Series are thinned out so the
// whole fits a few dozen BLE frames. A sensor this watch lacks is left out.

import { Sleep, HeartRate, Stress, BloodOxygen, Step, Calorie, Distance, Stand, FatBurning, Pai, Battery, BodyTemperature } from '@zos/sensor'

function safe(fn) {
  try {
    return fn()
  } catch (e) {
    return undefined
  }
}

// a day of values, one per `every` of them, as their mean; empty slots (no
// measurement: 0, or below `floor`) stay 0
function thin(values, every, floor) {
  const out = []
  if (!values || !values.length) return out
  for (let at = 0; at < values.length; at += every) {
    let sum = 0
    let n = 0
    for (let i = at; i < Math.min(at + every, values.length); i++) {
      const v = values[i]
      if (typeof v === 'number' && v > floor) {
        sum += v
        n++
      }
    }
    out.push(n ? Math.round((sum / n) * 10) / 10 : 0)
  }
  return out
}

function sleep() {
  const s = new Sleep()
  safe(() => s.updateInfo())
  const info = s.getInfo() || {}
  const c = safe(() => s.getStageConstantObj()) || {}
  const names = {}
  names[c.WAKE_STAGE] = 'wake'
  names[c.REM_STAGE] = 'rem'
  names[c.LIGHT_STAGE] = 'light'
  names[c.DEEP_STAGE] = 'deep'
  const stages = (safe(() => s.getStage()) || []).map((x) => [names[x.model] || 'light', x.start, x.stop])
  const naps = (safe(() => s.getNap()) || []).map((x) => [x.start, x.stop])
  return {
    score: info.score || 0,
    deep: info.deepTime || 0,
    start: info.startTime || 0,
    end: info.endTime || 0,
    total: info.totalTime || 0,
    stages,
    naps,
    sleeping: safe(() => s.getSleepingStatus()) || 0,
  }
}

function heart() {
  const h = new HeartRate()
  const summary = safe(() => h.getDailySummary()) || {}
  const max = summary.maximum || {}
  return {
    // one value per 10 minutes since midnight
    day: thin(safe(() => h.getToday()), 10, 0),
    last: safe(() => h.getLast()) || 0,
    resting: safe(() => h.getResting()) || 0,
    max: max.hr_value || 0,
    maxAt: max.time || 0,
  }
}

function stress() {
  const s = new Stress()
  const now = safe(() => s.getCurrent()) || {}
  return { now: now.value || 0, hours: safe(() => s.getTodayByHour()) || [], week: safe(() => s.getLastWeek()) || [] }
}

function oxygen() {
  const o = new BloodOxygen()
  const now = safe(() => o.getCurrent()) || {}
  return { now: now.value || 0, hours: safe(() => o.getLastDay()) || [] }
}

function goal(Sensor) {
  const s = new Sensor()
  return { now: safe(() => s.getCurrent()) || 0, goal: safe(() => s.getTarget()) || 0 }
}

export function collect() {
  const now = new Date()
  const out = { at: Date.now(), minute: now.getHours() * 60 + now.getMinutes() }
  const parts = {
    sleep,
    heart,
    stress,
    oxygen,
    steps: () => goal(Step),
    calories: () => goal(Calorie),
    stand: () => goal(Stand),
    fat: () => goal(FatBurning),
    distance: () => new Distance().getCurrent(),
    pai: () => {
      const p = new Pai()
      return { total: safe(() => p.getTotal()) || 0, today: safe(() => p.getToday()) || 0, week: safe(() => p.getLastWeek()) || [] }
    },
    // every 5 minutes, -1000 where nothing was measured: per half hour
    temperature: () => thin(new BodyTemperature().getToday(), 6, -100),
    battery: () => new Battery().getCurrent(),
  }
  Object.keys(parts).forEach((key) => {
    const value = safe(parts[key])
    if (value !== undefined) out[key] = value
  })
  return out
}

// what changes when a night ends: a new one is worth sending at once
export function nightKey() {
  return (
    safe(() => {
      const info = new Sleep().getInfo() || {}
      return `${info.startTime}-${info.endTime}-${info.totalTime}`
    }) || ''
  )
}

// last night as the face shows it: minutes asleep, the score, the stages
export function lastNight() {
  return safe(sleep) || null
}
