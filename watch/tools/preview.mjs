// Runs a page (or the face) with a fake link and prints the widgets it made.
//   node preview.mjs <file.js> <fixture.json> [face-file.json]
import { register } from 'node:module'
import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

register('./zos-loader.mjs', import.meta.url)
const { widgets } = await import('./zos-stub.mjs')

const [file, fixturePath, facePath] = process.argv.slice(2)
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'))
if (facePath) globalThis.__faceFile = new TextEncoder().encode(readFileSync(facePath, 'utf8'))
const state = fixture.state || {}
const link = {
  name: fixture.name || 'iseeu',
  rtt: 48,
  code: fixture.code || '',
  mouse: { pad() {}, wheel() {}, click() {}, button() {}, air() {}, gyro() {} },
  status: () => ({ status: fixture.status || 'ready', detail: fixture.detail || '' }),
  paired: () => fixture.paired !== false,
  onStatus: () => () => {},
  subscribe(topic, fn) {
    if (topic in state) fn(state[topic])
    return () => {}
  },
  state: (topic) => state[topic],
  call() {},
  pair() {},
  cancelPairing() {},
}
let options = null
globalThis.getApp = () => ({ _options: { globalData: { link } } })
globalThis.Page = (o) => (options = o)
globalThis.WatchFace = (o) => (options = o)
globalThis.App = (o) => (options = o)
const realSetInterval = setInterval
globalThis.setInterval = () => 0
globalThis.setTimeout = () => 0
await import(pathToFileURL(file).href)
if (options.onInit) options.onInit(process.env.PARAM)
options.build()
const plain = (v) => (typeof v === 'function' ? undefined : v)
process.stdout.write(JSON.stringify(widgets.filter((w) => w.visible).map((w) => ({ type: w.type, props: Object.fromEntries(Object.entries(w.props).map(([k, v]) => [k, plain(v)])) }))))
realSetInterval(() => process.exit(0), 10)
