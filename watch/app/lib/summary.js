// What the face shows of the PC, cut from the snapshots: the app writes it to
// pc.json while home is open, the face fetches it itself when it comes on.

export const TOPICS = ['link', 'theme', 'agents', 'system', 'media', 'weather', 'screentime', 'printer']

export function summary(state, name) {
  const st = (topic) => state(topic)
  const a = ((st('agents') || {}).agents || [])
  const system = st('system')
  const media = st('media')
  const printer = st('printer')
  const weather = st('weather')
  return {
    at: Date.now(),
    name: ((st('link') || {}).name) || name || '',
    theme: st('theme') || null,
    cpu: system ? system.cpu : null,
    memory: system ? system.memory : null,
    busy: a.filter((x) => x.state === 'busy').length,
    waiting: a.filter((x) => x.state !== 'busy').length,
    agent: a.length ? a[0].topic : '',
    media: media && media.has ? { title: media.title, artist: media.artist, playing: media.playing } : null,
    printer: printer && (printer.printing || printer.paused) ? { progress: printer.progress, left: printer.left } : null,
    weather: weather && weather.available ? { temperature: weather.temperature, icon: weather.icon } : null,
    screentime: st('screentime') ? st('screentime').total : null,
  }
}
