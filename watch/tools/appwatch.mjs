// The app's home page with the real link (lib/link.js) over a BLEMaster that
// speaks through stdio, for scripts/phone/test_watch.py to put the daemon on
// the other end: {"write":"<hex>"} out for every write, {"notify":"<hex>"} in
// for every notification; {"op":"pair"} taps "Koppeln", {"op":"texts"} prints
// what the screen shows, {"op":"call",...} runs link.call. Errors are printed
// as {"error"} instead of ending the run.
import { register } from 'node:module'
import { createInterface } from 'node:readline'

process.removeAllListeners('warning')
register('./zos-loader.mjs', import.meta.url)
const { widgets } = await import('./zos-stub.mjs')

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
  disconnect() {}
  quit() {}
  generateProfileObject() {
    return {}
  }
  startListener(profile, cb) {
    setTimeout(() => cb({ success: true }), 5)
  }
}

const { createLink } = await import('../app/lib/link.js')
const link = createLink()
let page = null
globalThis.getApp = () => ({ _options: { globalData: { link } } })
globalThis.Page = (o) => (page = o)
await import('../app/page/index.js')
link.start()
page.build()

createInterface({ input: process.stdin }).on('line', (line) => {
  const order = JSON.parse(line)
  try {
    if (order.notify) notify && notify('7A52', new Uint8Array(Buffer.from(order.notify, 'hex')).buffer)
    else if (order.op === 'pair') say({ code: link.pair() })
    else if (order.op === 'status') say({ status: link.status() })
    else if (order.op === 'texts') say({ texts: widgets.filter((w) => w.visible && w.props.text).map((w) => w.props.text) })
    else if (order.op === 'call') link.call(order.topic, order.action, order.args, (ok, data) => say({ result: { ok, data } }))
  } catch (e) {
    say({ error: String((e && e.stack) || e) })
  }
})
