// Files in /data, shared between the app and the face: each reads the
// other's with its appId. The app writes link.json (the secret and the PC's
// address, so the face can sign in), the face writes theme.json (the
// shell's colours as the PC last sent them).

import { writeFileSync, openSync, readSync, closeSync, O_RDONLY } from '@zos/fs'

export const APP = 1073744
export const FACE = 1073745

export function writeJson(path, data) {
  try {
    writeFileSync({ path, data: JSON.stringify(data), options: { encoding: 'utf8' } })
  } catch (e) {}
}

function utf8(bytes) {
  let out = ''
  for (let i = 0; i < bytes.length; ) {
    const b = bytes[i++]
    let c = b
    if (b >= 0xf0) c = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)
    else if (b >= 0xe0) c = ((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)
    else if (b >= 0xc0) c = ((b & 31) << 6) | (bytes[i++] & 63)
    if (c >= 0x10000) {
      c -= 0x10000
      out += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023))
    } else out += String.fromCharCode(c)
  }
  return out
}

// a JSON file of this app (appId left out) or of the other one, or null
export function readJson(path, appId) {
  try {
    const fd = openSync({ path, flag: O_RDONLY, options: appId ? { appId } : undefined })
    if (fd === undefined || fd < 0) return null
    const chunk = new ArrayBuffer(1024)
    let bytes = []
    for (let i = 0; i < 32; i++) {
      const n = readSync({ fd, buffer: chunk })
      if (!n || n <= 0) break
      bytes = bytes.concat(Array.from(new Uint8Array(chunk, 0, n)))
      if (n < chunk.byteLength) break
    }
    closeSync({ fd })
    return bytes.length ? JSON.parse(utf8(bytes)) : null
  } catch (e) {
    return null
  }
}
