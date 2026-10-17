// Files in the app's /data, for the face to read (watch/face reads pc.json
// with the app's id: a watch face cannot reach the PC on its own).

import { writeFileSync } from '@zos/fs'

export function writeJson(path, data) {
  try {
    writeFileSync({ path, data: JSON.stringify(data), options: { encoding: 'utf8' } })
  } catch (e) {}
}
