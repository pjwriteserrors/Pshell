// Node module hooks for the previews: @zos/* and easy-ble come from zos-stub.mjs.
const STUB = new URL('./zos-stub.mjs', import.meta.url).href

const MODULES = {
  '@zos/ui': `import { ui } from '${STUB}'; export const { createWidget, deleteWidget, widget, prop, align, text_style, event } = ui; export default ui`,
  '@zos/router': `export const push = () => {}, back = () => {}, replace = () => {}, exit = () => {}, launchApp = () => {}`,
  '@zos/interaction': `export const showToast = () => {}, createModal = () => ({ show() {} }), onGesture = () => {}, offGesture = () => {}, onKey = () => {}, offKey = () => {}, onDigitalCrown = () => {}, offDigitalCrown = () => {}
    export const KEY_BACK = 8, KEY_SELECT = 13, KEY_HOME = 36, KEY_UP = 1, KEY_DOWN = 2, KEY_SHORTCUT = 3, KEY_EVENT_CLICK = 1, KEY_EVENT_LONG_PRESS = 2, KEY_EVENT_DOUBLE_CLICK = 4, KEY_EVENT_RELEASE = 8, KEY_EVENT_PRESS = 16, GESTURE_UP = 1, GESTURE_DOWN = 2, GESTURE_LEFT = 3, GESTURE_RIGHT = 4, MODAL_CONFIRM = 1, MODAL_CANCEL = 0`,
  '@zos/sensor': `import { timeNow } from '${STUB}'
    class Sensor { start() {} stop() {} onChange() {} offChange() {} setFreqMode() {} getCurrent() { return 0 } getTarget() { return 10000 } }
    export class Gyroscope extends Sensor { getCurrent() { return { x: 0, y: 0, z: 0 } } }
    export class Accelerometer extends Sensor { getCurrent() { return { x: 0.1, y: 0.2, z: 9.8 } } }
    export class Battery extends Sensor { getCurrent() { return 78 } }
    export class Step extends Sensor { getCurrent() { return 6412 } getTarget() { return 8000 } }
    export class HeartRate extends Sensor { getCurrent() { return 72 } getLast() { return 72 } }
    export class Time { onPerMinute() {} onPerDay() {} getHours() { return timeNow.value.getHours() } getMinutes() { return timeNow.value.getMinutes() } getDate() { return timeNow.value.getDate() } getMonth() { return timeNow.value.getMonth() + 1 } getFullYear() { return timeNow.value.getFullYear() } getDay() { return timeNow.value.getDay() || 7 } getTime() { return timeNow.value.getTime() } }
    export const FREQ_MODE_HIGH = 2, FREQ_MODE_NORMAL = 1, FREQ_MODE_LOW = 0`,
  '@zos/display': `export const setPageBrightTime = () => 0, resetPageBrightTime = () => 0, pauseDropWristScreenOff = () => 0, resetDropWristScreenOff = () => 0`,
  '@zos/page': `export const setScrollLock = () => {}, scrollTo = () => {}, getScrollTop = () => 0`,
  '@zos/storage': `const data = {}; export const localStorage = { getItem: (k) => data[k], setItem: (k, v) => (data[k] = v), removeItem: (k) => delete data[k], clear() {} }`,
  '@zos/fs': `
    const files = {}
    export const O_RDONLY = 0, O_WRONLY = 1, O_RDWR = 2, O_CREAT = 64, O_TRUNC = 512
    export function openSync({ path }) { files.last = path; return 3 }
    export function statSync({ path }) { return globalThis.__faceFile ? { size: globalThis.__faceFile.length } : undefined }
    export function readSync({ fd, buffer }) { const src = globalThis.__faceFile || new Uint8Array(); new Uint8Array(buffer).set(src.slice(0, buffer.byteLength)); return Math.min(src.length, buffer.byteLength) }
    export function writeSync() { return 0 }
    export function writeFileSync() {}
    export function readFileSync() { return undefined }
    export function closeSync() { return 0 }
    export function rmSync() { return 0 }
    export function renameSync() { return 0 }`,
  '@zos/utils': `export const px = (v) => v`,
  '@zos/device': `export const getDeviceInfo = () => ({ width: 390, height: 450 })`,
  '@silver-zepp/easy-ble': `export class BLEMaster { constructor() { this.write = { characteristic() {}, enableCharaNotifications() {} }; this.on = { charaNotification() {}, charaWriteComplete() {} } } startScan() { return true } stopScan() {} connect() {} disconnect() {} quit() {} generateProfileObject() { return {} } startListener() {} }`,
}

export async function resolve(specifier, context, next) {
  if (specifier in MODULES) return { url: 'zos:' + specifier, shortCircuit: true }
  return next(specifier, context)
}

export async function load(url, context, next) {
  if (url.startsWith('zos:')) return { format: 'module', source: MODULES[url.slice(4)], shortCircuit: true }
  // the app's files are modules whatever node thinks of .js
  if (url.includes('/watch/') && url.endsWith('.js')) {
    const result = await next(url, { ...context, format: 'module' })
    return { ...result, format: 'module' }
  }
  return next(url, context)
}
