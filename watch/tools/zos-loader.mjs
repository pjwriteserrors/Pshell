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
    export class Screen extends Sensor { getStatus() { return 1 } }
    export class Battery extends Sensor { getCurrent() { return 78 } }
    export class Step extends Sensor { getCurrent() { return 6412 } getTarget() { return 8000 } }
    export class HeartRate extends Sensor { getCurrent() { return 72 } getLast() { return 72 } getResting() { return 54 } getDailySummary() { return { maximum: { hr_value: 141, time: 1792200000 } } } getToday() { return Array.from({ length: 900 }, (_, i) => (i % 7 ? 60 + (i % 40) : 0)) } }
    // last night: 23:40 to 07:05, its stages; the minutes count from 0:00
    export class Sleep { updateInfo() {} getInfo() { return { score: 82, deepTime: 94, startTime: 1420, endTime: 425, totalTime: 431 } } getStageConstantObj() { return { WAKE_STAGE: 7, REM_STAGE: 8, LIGHT_STAGE: 4, DEEP_STAGE: 5 } } getStage() { return [[4, 1420, 1470], [5, 1470, 40], [4, 40, 120], [8, 120, 150], [7, 150, 158], [5, 158, 210], [4, 210, 300], [8, 300, 340], [4, 340, 400], [8, 400, 425]].map(([model, start, stop]) => ({ model, start, stop })) } getNap() { return [] } getSleepingStatus() { return 0 } }
    export class Stress { getCurrent() { return { value: 31, time: 0 } } getTodayByHour() { return Array.from({ length: 24 }, (_, i) => (i < 15 ? 20 + i * 2 : 0)) } getLastWeek() { return [30, 42, 28, 35, 51, 33, 31] } }
    export class BloodOxygen { getCurrent() { return { value: 97, time: 0, retCode: 2 } } getLastDay() { return Array.from({ length: 24 }, () => 96) } }
    export class Calorie extends Sensor { getCurrent() { return 412 } getTarget() { return 600 } }
    export class Distance extends Sensor { getCurrent() { return 4800 } }
    export class Stand extends Sensor { getCurrent() { return 7 } getTarget() { return 12 } }
    export class FatBurning extends Sensor { getCurrent() { return 18 } getTarget() { return 30 } }
    export class Pai { getTotal() { return 74 } getToday() { return 6 } getLastWeek() { return [8, 12, 0, 9, 14, 25, 6] } }
    export class BodyTemperature { getToday() { return Array.from({ length: 288 }, (_, i) => (i < 90 ? 33.4 + (i % 10) / 20 : -1000)) } }
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
  // linktest.mjs puts its own in globalThis.__BLEMaster
  '@silver-zepp/easy-ble': `export class BLEMaster { constructor() { if (globalThis.__BLEMaster) return new globalThis.__BLEMaster(); this.write = { characteristic() {}, enableCharaNotifications() {} }; this.on = { charaNotification() {}, charaWriteComplete() {} } } startScan() { return true } stopScan() {} connect() {} disconnect() {} quit() {} generateProfileObject() { return {} } startListener() {} }`,
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
