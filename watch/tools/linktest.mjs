// lib/link.js coming up, against a scripted BLEMaster: straight to the
// remembered address, a scan when that fails, the first write once the
// notifications are on, and no connection ever left open behind it.
//
//   node watch/tools/linktest.mjs

import assert from 'node:assert/strict'
import { register } from 'node:module'

process.removeAllListeners('warning')
register('./zos-loader.mjs', import.meta.url)
const P = await import('../app/lib/protocol.js')
const { localStorage } = await import('@zos/storage')

const log = []
let script = {}
let made = 0

globalThis.__BLEMaster = class {
  constructor() {
    this.id = made++
    this.seen = new Set()
    log.push(['new', this.id])
    const me = this
    this.write = {
      characteristic(uuid, data) {
        log.push(['write', me.id, Array.from(new Uint8Array(data))[0], Date.now()])
      },
      enableCharaNotifications() {
        log.push(['cccd', me.id, Date.now()])
        if (script.cccd !== undefined) setTimeout(() => me.descDone && me.descDone(), script.cccd)
      },
    }
    this.on = {
      charaNotification() {},
      descWriteComplete(fn) {
        me.descDone = fn
      },
    }
  }
  // like easy-ble: a device once per instance
  startScan(cb) {
    log.push(['scan', this.id])
    const mac = script.found || 'aa:bb:cc:dd:ee:ff'
    setTimeout(() => {
      if (this.seen.has(mac)) return
      this.seen.add(mac)
      cb({ dev_name: 'pshell', dev_addr: mac })
    }, 20)
    return true
  }
  stopScan() {}
  connect(mac, cb) {
    const n = log.filter((e) => e[0] === 'connect').length
    log.push(['connect', this.id, mac])
    // by the how-manieth connect this is
    const [ok, after] = script.connect ? script.connect(mac, n) : [true, 30]
    if (after !== null) setTimeout(() => cb({ connected: ok, status: ok ? 'connected' : 'failed' }), after)
    // like easy-ble: the same callback hears when the link goes
    if (ok) globalThis.__drop = () => cb({ connected: false, status: 'disconnected' })
  }
  disconnect() {
    log.push(['disconnect', this.id])
  }
  quit() {}
  generateProfileObject() {
    return {}
  }
  startListener(profile, cb) {
    setTimeout(() => cb({ success: true }), 10)
  }
}

const { createLink } = await import('../app/lib/link.js')
const wait = (ms) => new Promise((r) => setTimeout(r, ms))

async function run(name, options, setup, check) {
  log.length = 0
  made = 0
  script = setup
  localStorage.removeItem('pcMac')
  const link = createLink({ once: !setup.app, secret: '00112233445566778899aabbccddeeff', connectAtMost: 300, ...options })
  if (setup.unpaired) localStorage.removeItem('secret')
  link.start()
  if (setup.then) await setup.then(link)
  await wait(setup.wait)
  link.stop()
  await wait(setup.after || 0)
  check(log, link)
  console.log('ok', name)
}

const kinds = (log, only) => log.map((e) => e[0]).filter((k) => !only || only.includes(k))
const hellos = (log) => log.filter((e) => e[0] === 'write' && e[2] === P.HELLO)
const KNOWN = '11:22:33:44:55:66'

await run('a known PC is reached without a scan, hello right after the CCCD', { mac: KNOWN }, { cccd: 40, wait: 700 }, (log) => {
  assert.ok(!kinds(log).includes('scan'))
  assert.equal(log.find((e) => e[0] === 'connect')[2], KNOWN)
  const h = hellos(log)[0]
  assert.ok(h, 'no hello')
  const cccd = log.find((e) => e[0] === 'cccd')[2]
  assert.ok(h[3] - cccd >= 300 && h[3] - cccd < 500, `hello ${h[3] - cccd} ms after the CCCD`)
})

await run('no word on the CCCD: hello after 1.5 s all the same', { mac: KNOWN }, { wait: 1800 }, (log) => {
  assert.ok(hellos(log)[0][3] - log.find((e) => e[0] === 'cccd')[2] >= 1500)
  assert.equal(hellos(log).length, 1)
})

await run('a remembered address that fails: a fresh BLEMaster scans', { mac: KNOWN }, { connect: (mac) => [mac !== KNOWN, 30], cccd: 10, wait: 600 }, (log) => {
  assert.deepEqual(kinds(log, ['connect', 'scan']), ['connect', 'scan', 'connect'])
  const scan = log.find((e) => e[0] === 'scan')
  assert.notEqual(scan[1], log.find((e) => e[0] === 'connect')[1])
  assert.equal(log.filter((e) => e[0] === 'connect')[1][2], 'aa:bb:cc:dd:ee:ff')
  assert.equal(hellos(log).length, 1)
})

await run('a connect that answers late, after another made it: closed', { mac: KNOWN }, { connect: (mac, id) => [true, id === 0 ? 700 : 30], cccd: 10, wait: 1000 }, (log) => {
  const first = log.find((e) => e[0] === 'connect')[1]
  assert.equal(hellos(log).length, 1)
  assert.notEqual(hellos(log)[0][1], first)
  assert.equal(log.find((e) => e[0] === 'disconnect')[1], first)
})

await run('a connect that answers late with nothing else under way: used', { mac: KNOWN }, { app: true, connect: (mac, id) => (id === 0 ? [true, 500] : [false, 30]), cccd: 10, wait: 1100 }, (log) => {
  const first = log.find((e) => e[0] === 'connect')[1]
  assert.equal(hellos(log).length, 1)
  assert.equal(hellos(log)[0][1], first)
  assert.ok(!log.some((e) => e[0] === 'disconnect' && log.indexOf(e) < log.indexOf(hellos(log)[0])))
})

await run('stopped while connecting: the connection that comes is closed', { mac: KNOWN }, { connect: () => [true, 200], wait: 50, after: 300 }, (log) => {
  assert.deepEqual(kinds(log, ['connect', 'disconnect']), ['connect', 'disconnect'])
})

await run('a scan after a lost connect sees the PC again', {}, { app: true, connect: (mac, id) => [id > 1, 30], cccd: 10, wait: 3200 }, (log) => {
  assert.ok(kinds(log, ['scan']).length >= 2)
  assert.ok(kinds(log, ['connect']).length >= 2)
  assert.equal(hellos(log).length, 1)
})

await run('a link the PC drops is noticed and made again', { mac: KNOWN }, {
  app: true,
  cccd: 10,
  wait: 1500,
  then: async () => {
    await wait(500)
    globalThis.__drop()
  },
}, (log) => {
  assert.equal(kinds(log, ['connect']).length, 2)
  assert.equal(hellos(log).length, 2)
})

await run('unpaired: lets go of the link, and comes back for pair()', { mac: KNOWN, secret: null }, {
  app: true,
  unpaired: true,
  cccd: 10,
  wait: 800,
  then: async (link) => {
    await wait(1200)
    assert.equal(link.status().status, 'unpaired')
    assert.deepEqual(kinds(log, ['connect', 'disconnect']), ['connect', 'disconnect'])
    link.pair()
  },
}, (log) => {
  assert.deepEqual(kinds(log, ['connect', 'disconnect']).slice(0, 3), ['connect', 'disconnect', 'connect'])
  assert.ok(log.some((e) => e[0] === 'write' && e[2] === P.PAIR))
})

await run('nothing remembered: scan first', {}, { cccd: 10, wait: 600 }, (log) => {
  assert.deepEqual(kinds(log, ['connect', 'scan']), ['scan', 'connect'])
  assert.ok(hellos(log).length)
})
process.exit(0)
