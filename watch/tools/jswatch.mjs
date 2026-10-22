// The watch app's protocol code (watch/app/lib/protocol.js) in node, driven
// line by line by scripts/phone/test_watch.py: it gets {"op": …} and frames
// from the PC, and prints the frames the watch would write.
//
//   {"op":"pair"}                       → PAIR with a new secret, prints {"code"}
//   {"op":"hello"}                      → HELLO
//   {"recv":"<hex>"}                    → handles a frame from the PC
//   {"op":"json","data":{…}}            → a JSON message, in parts
//   {"op":"raw","messages":["<hex>"]}   → session messages as they are

import { createInterface } from 'node:readline'
import { randomBytes } from 'node:crypto'
import * as P from '../app/lib/protocol.js'

let secret = null
let nonce = null
let expected = null
let session = null
let messageId = 0
const parts = P.assembler()

function say(object) {
  process.stdout.write(JSON.stringify(object) + '\n')
}

function send(bytes) {
  say({ send: P.hex(bytes) })
}

function handle(frame) {
  const kind = frame[0]
  if (kind === P.CHALLENGE) {
    const answer = P.prove(secret, frame.slice(1, 9), nonce)
    expected = answer
    send(answer.proof)
  } else if (kind === P.WELCOME) {
    if (!P.checkWelcome(expected.welcome, frame)) return say({ error: 'bad welcome' })
    session = P.session(expected.session)
    say({ session: true })
  } else if (kind === P.PAIRED) say({ paired: true })
  else if (kind === P.REFUSED) say({ refused: P.REASONS[frame[1]] })
  else if (kind === P.SESSION) {
    const messages = P.open(session, frame)
    if (!messages) return say({ error: 'not genuine' })
    for (const m of messages) {
      if (m[0] === 0x10) {
        const done = parts.feed(m)
        if (done === 'lost') say({ error: 'lost' })
        else if (done) say({ json: done })
      } else say({ message: P.hex(m) })
    }
  }
}

createInterface({ input: process.stdin }).on('line', (line) => {
  const order = JSON.parse(line)
  if (order.recv) return handle(P.fromHex(order.recv))
  if (order.op === 'pair') {
    secret = Array.from(randomBytes(16))
    say({ code: P.pairingCode(secret), secret: P.hex(secret) })
    send(P.pair(secret))
  } else if (order.op === 'hello') {
    nonce = Array.from(randomBytes(8))
    send(P.hello(secret, nonce))
  } else if (order.op === 'json') {
    messageId = (messageId + 1) & 0xff
    send(P.seal(session, P.jsonParts(messageId, order.data, 40)))
  } else if (order.op === 'raw') {
    send(P.seal(session, order.messages.map(P.fromHex)))
  }
})
