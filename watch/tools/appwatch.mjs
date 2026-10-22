// The watch's two programs with the real link (lib/link.js) over a BLEMaster
// that speaks through stdio, for scripts/phone/test_watch.py to put the
// daemon on the other end: {"write":"<hex>"} out for every write,
// {"notify":"<hex>"} in for every notification. Errors are printed as
// {"error"} instead of ending the run.
//
//   node appwatch.mjs app    the mouse app: {"op":"pair"}, {"op":"status"},
//                            {"op":"pad","dx":…,"dy":…}
//   node appwatch.mjs face   the face, signing in with LINK_JSON (the app's
//                            link.json): it syncs as soon as it is built
import { register } from 'node:module'
import { createInterface } from 'node:readline'

process.removeAllListeners('warning')
register('./zos-loader.mjs', import.meta.url)
const mode = process.argv[2] || 'app'
if (process.env.LINK_JSON) globalThis.__faceFile = new TextEncoder().encode(process.env.LINK_JSON)

const say = (o) => process.stdout.write(JSON.stringify(o) + '\n')
process.on('uncaughtException', (e) => say({ error: String((e && e.stack) || e) }))
let notify = null
let descDone = null

globalThis.__BLEMaster = class {
  constructor() {
    this.write = {
      characteristic(uuid, data) {
        say({ write: Buffer.from(new Uint8Array(data)).toString('hex') })
      },
      enableCharaNotifications() {
        setTimeout(() => descDone && descDone(), 5)
      },
    }
    this.on = {
      charaNotification(fn) {
        notify = fn
      },
      descWriteComplete(fn) {
        descDone = fn
      },
    }
  }
  startScan(cb) {
    setTimeout(() => cb({ dev_name: 'pshell', dev_addr: 'a8:6e:84:87:57:e9' }), 5)
    return true
  }
  stopScan() {}
  connect(mac, cb) {
    setTimeout(() => cb({ connected: true, status: 'connected' }), 5)
  }
  disconnect() {
    say({ disconnected: true })
  }
  quit() {}
  generateProfileObject() {
    return {}
  }
  startListener(profile, cb) {
    setTimeout(() => cb({ success: true }), 5)
  }
}

const { createLink } = await import('../app/lib/link.js')
let link = null
let page = null
if (mode === 'face') {
  globalThis.WatchFace = (o) => (page = o)
  await import('../face/watchface/index.js')
  page.build()
} else {
  link = createLink()
  globalThis.getApp = () => ({ _options: { globalData: { link } } })
  globalThis.Page = (o) => (page = o)
  await import('../app/page/mouse.js')
  link.start()
  page.build()
}

createInterface({ input: process.stdin }).on('line', (line) => {
  const order = JSON.parse(line)
  try {
    if (order.notify) notify && notify('7A52', new Uint8Array(Buffer.from(order.notify, 'hex')).buffer)
    else if (order.op === 'pair') say({ code: link.pair() })
    else if (order.op === 'status') say({ status: link.status() })
    else if (order.op === 'pad') link.mouse.pad(order.dx, order.dy)
  } catch (e) {
    say({ error: String((e && e.stack) || e) })
  }
})
