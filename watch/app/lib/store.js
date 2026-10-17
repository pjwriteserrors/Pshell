// Files in the app's /data: for the face to read (watch/face reads pc.json
// and link.json with the app's id), and the snapshots kept for the next start.

import { writeFileSync, readFileSync } from '@zos/fs'

export function writeJson(path, data) {
  try {
    writeFileSync({ path, data: JSON.stringify(data), options: { encoding: 'utf8' } })
  } catch (e) {}
}

export function readJson(path) {
  try {
    const text = readFileSync({ path, options: { encoding: 'utf8' } })
    return text ? JSON.parse(text) : null
  } catch (e) {
    return null
  }
}
