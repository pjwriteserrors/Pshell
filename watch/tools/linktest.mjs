// lib/link.js coming up, against a scripted BLEMaster: straight to the
// remembered address, a scan when that does not answer, the first write once
// the notifications are on.
//
//   node watch/tools/linktest.mjs

import assert from 'node:assert/strict'
import { register } from 'node:module'

process.removeAllListeners('warning')
register('./zos-loader.mjs', import.meta.url)
const P = await import('../app/lib/protocol.js')

const log = []
let script = {}

globalThis.__BLEMaster = class {
  constructor() {
    this.id = log.filter((e) => e[0] === 'new').length
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
  startScan(cb) {
    log.push(['scan', this.id])
    setTimeout(() => cb({ dev_name: 'pshell', dev_addr: script.found || 'aa:bb:cc:dd:ee:ff' }), 20)
    return true
  }
  stopScan() {}
  connect(mac, cb) {
    log.push(['connect', this.id, mac])
    const answer = script.connect ? script.connect(mac) : true
    if (answer !== null) setTimeout(() => cb({ connected: answer, status: answer ? 'connected' : 'failed' }), 30)
  }
  disconnect() {}
  quit() {
    log.push(['quit', this.id])
  }
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
  script = setup
  const link = createLink({ once: true, secret: '00112233445566778899aabbccddeeff', ...options })
  const t0 = Date.now()
  link.start()
  await wait(setup.wait)
  link.stop()
  check(log, t0)
  console.log('ok', name)
}

const kinds = (log) => log.map((e) => e[0])
const hello = (log) => log.find((e) => e[0] === 'write' && e[2] === P.HELLO)

await run('a known PC is reached without a scan, hello right after the CCCD', { mac: '11:22:33:44:55:66' }, { cccd: 40, wait: 700 }, (log, t0) => {
  assert.ok(!kinds(log).includes('scan'))
  assert.deepEqual(log.find((e) => e[0] === 'connect').slice(2), ['11:22:33:44:55:66'])
  const h = hello(log)
  assert.ok(h, 'no hello')
  const cccd = log.find((e) => e[0] === 'cccd')[2]
  assert.ok(h[3] - cccd >= 300 && h[3] - cccd < 500, `hello ${h[3] - cccd} ms after the CCCD`)
})

await run('no word on the CCCD: hello after 1.5 s all the same', { mac: '11:22:33:44:55:66' }, { wait: 1800 }, (log) => {
  const h = hello(log)
  assert.ok(h)
  assert.ok(h[3] - log.find((e) => e[0] === 'cccd')[2] >= 1500)
  assert.equal(log.filter((e) => e[0] === 'write').length, 1)
})

await run('a remembered address that refuses: scan', { mac: '11:22:33:44:55:66' }, { connect: (mac) => mac !== '11:22:33:44:55:66', found: 'aa:bb:cc:dd:ee:ff', cccd: 10, wait: 600 }, (log) => {
  assert.deepEqual(kinds(log).filter((k) => k === 'connect' || k === 'scan'), ['connect', 'scan', 'connect'])
  assert.equal(log.filter((e) => e[0] === 'connect')[1][2], 'aa:bb:cc:dd:ee:ff')
  assert.ok(hello(log))
})

await run('a remembered address that never answers: a fresh BLEMaster scans after 4 s', { mac: '11:22:33:44:55:66' }, { connect: (mac) => (mac === '11:22:33:44:55:66' ? null : true), cccd: 10, wait: 4600 }, (log) => {
  assert.deepEqual(kinds(log).filter((k) => ['new', 'connect', 'quit', 'scan'].includes(k)).slice(0, 6), ['new', 'connect', 'quit', 'new', 'scan', 'connect'])
  assert.equal(hello(log)[1], 1)
})

const { localStorage } = await import('@zos/storage')
localStorage.removeItem('pcMac')
await run('nothing remembered: scan first', {}, { cccd: 10, wait: 600 }, (log) => {
  assert.deepEqual(kinds(log).filter((k) => k === 'connect' || k === 'scan'), ['scan', 'connect'])
  assert.ok(hello(log))
})
process.exit(0)
