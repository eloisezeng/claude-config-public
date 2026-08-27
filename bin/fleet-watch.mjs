#!/usr/bin/env node
// fleet-watch.mjs — the whole background-Claude fleet in ONE terminal.
//
// Discovers live sessions on a timer (so successors appear by themselves when a
// session hands off), tails each transcript from its own offset, and interleaves
// everything into one colour-coded stream. One process, read-only, ~35 MB total —
// versus ~1 GB per extra live session if you attached to each one for real.
//
//   fleet-watch.mjs [--max-age MIN] [--back N] [--only a,b,c] [--quiet]
//
//   --quiet   drop thinking + tool_result lines (headlines only)

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { parseFlags } from './fleet-flags.mjs'

const HOME = os.homedir()
const JOBS = path.join(HOME, '.claude', 'jobs')

// One reader for all three of `fleet`'s argv surfaces -- see fleet-flags.mjs. The old
// `flag()` returned argv[i + 1] unchecked, so a missing or non-numeric operand became
// NaN, and NaN is not a small number here, it is NO LIMIT: `now - mtime > NaN` is false
// for every row, so `fleet --max-age nope` admitted 48 sessions where the default window
// admits 22, and `--back` with no operand reached `slice(-NaN)` === `slice(0)` -- the
// whole byte window, for every session at once.
const { values } = parseFlags(process.argv.slice(2), {
  name: 'fleet-watch',
  usage: '  usage: fleet [--max-age <minutes>] [--back <n>] [--only a,b,c] [--quiet]',
  numeric: { '--max-age': 60, '--back': 4 },
  string: { '--only': '' },
  boolean: ['--quiet'],
  positionals: { min: 0, max: 0 },
})
const MAXAGE = values['--max-age'] * 60_000
const BACK = values['--back']
const ONLY = values['--only'].split(',').filter(Boolean)
const QUIET = values['--quiet']

const R = '\x1b[0m', DIM = '\x1b[2m', B = '\x1b[1m'
const PALETTE = [36, 32, 33, 35, 34, 91, 92, 93, 95, 96, 94, 31].map((n) => `\x1b[${n}m`)
const width = () => Math.max(60, process.stdout.columns || 110)

// ONE guarded read of a byte range, for the same two reasons as in fleet-tail.mjs.
// (1) The transcript belongs to another process. 3 of this machine's 51 working/blocked
// rows already point at a linkScanPath that is GONE, and every openSync here used to sit
// outside any try, inside a setInterval callback -- so ONE deleted transcript did not drop
// ONE session from the view, it terminated the whole fleet-wide viewer. (2) It bounds
// memory: `Buffer.alloc(size - offset)` let a single appended tool_result decide the
// footprint of the process whose whole pitch is 35 MB instead of a gigabyte.
const CHUNK = 64 * 1024
function readRange(file, from, to) {
  if (to <= from) return { text: '', end: from }
  let fd = null
  try {
    fd = fs.openSync(file, 'r')
    const buf = Buffer.alloc(Math.min(CHUNK, to - from))
    const parts = []
    let at = from
    while (at < to) {
      const want = Math.min(buf.length, to - at)
      const got = fs.readSync(fd, buf, 0, want, at)
      if (got <= 0) break
      parts.push(Buffer.from(buf.subarray(0, got)))
      at += got
    }
    return { text: Buffer.concat(parts).toString('utf8'), end: at }
  } catch {
    return null
  } finally {
    if (fd !== null) { try { fs.closeSync(fd) } catch {} }
  }
}

const clip = (s, n) => {
  s = String(s ?? '').replace(/\s+/g, ' ').trim()
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}
const hhmm = (ts) => { try { return new Date(ts).toISOString().slice(11, 19) } catch { return '--:--:--' } }

/** @type {Map<string,{color:string,offset:number,carry:string,state:string,tokens:number,name:string,cwd:string,transcript:string}>} */
const tracked = new Map()
let colorCursor = 0

function discover() {
  let dirs = []
  try { dirs = fs.readdirSync(JOBS) } catch { return }
  const now = Date.now()
  const live = new Set()

  for (const short of dirs) {
    if (ONLY.length && !ONLY.includes(short)) continue
    const sp = path.join(JOBS, short, 'state.json')
    let st, mtime
    try { mtime = fs.statSync(sp).mtimeMs; st = JSON.parse(fs.readFileSync(sp, 'utf8')) } catch { continue }
    if (st.state !== 'working' && st.state !== 'blocked') continue
    if (now - mtime > MAXAGE) continue
    if (!st.linkScanPath || !fs.existsSync(st.linkScanPath)) continue
    live.add(short)

    let t = tracked.get(short)
    if (!t) {
      t = {
        color: PALETTE[colorCursor++ % PALETTE.length],
        offset: 0,
        carry: '', state: st.state, tokens: st.tokens || 0,
        name: st.name || short, cwd: st.cwd || '', transcript: st.linkScanPath,
      }
      tracked.set(short, t)
      banner(short, t, 'joined')
      // paintTail OWNS the boundary. `offset` used to be stat'd here and paintTail stat'd
      // again a moment later, so a turn appended in between was painted as history AND
      // then read again by pump -- the same turn printed twice, which reads as the session
      // repeating itself. One snapshot, one boundary, consumed once.
      t.offset = paintTail(short, t, BACK)
    } else {
      if (st.state !== t.state) {
        emit(short, t, `${B}▲ ${t.state} → ${st.state}${R} ${DIM}${clip(st.detail || '', 50)}${R}`)
        t.state = st.state
      }
      t.tokens = st.tokens || t.tokens
      t.name = st.name || t.name
    }
  }

  for (const [short, t] of tracked) {
    if (!live.has(short)) { banner(short, t, 'left'); tracked.delete(short) }
  }
}

function banner(short, t, why) {
  const w = width()
  const tag = why === 'joined' ? '┌─ joined' : '└─ left  '
  const line = `${t.color}${B}${tag} ${short}${R}  ${t.name}  ${DIM}${(t.cwd || '').replace(HOME, '~')}${R}`
  console.log(`${t.color}${'─'.repeat(Math.min(w, 100))}${R}`)
  console.log(clip(line, w + 40))
}

function emit(short, t, body) {
  const stamp = `${DIM}${hhmm(Date.now())}${R}`
  console.log(`${stamp} ${t.color}${B}${short}${R} ${body}`)
}

function wrapUnder(text, pad) {
  const w = width() - pad
  const out = []
  for (const para of String(text).split('\n')) {
    if (!para.trim()) continue
    let line = ''
    for (const word of para.split(/\s+/)) {
      if (line && (line + ' ' + word).length > w) { out.push(line); line = word } else line = line ? line + ' ' + word : word
    }
    if (line) out.push(line)
  }
  return out
}

function toolSummary(name, input) {
  const i = input || {}
  const pick = i.command ?? i.file_path ?? i.path ?? i.pattern ?? i.url ?? i.prompt ?? i.query ?? i.description ?? i.message ?? i.skill
  if (pick != null) return clip(pick, Math.max(20, width() - name.length - 26))
  const k = Object.keys(i)
  return k.length ? clip(k.join(','), 36) : ''
}

// The daemon writes a plain user turn as `message.content: "<the prompt>"`, not as an
// array of blocks, so requiring an array dropped every one: 555 across 163 of this
// machine's 170 readable transcripts, all of them `type: 'user'`, and they are the
// dispatch prompts. A fleet view that shows the answers and never the instructions is
// worse than incomplete -- it invites the wrong conclusion about what a session is doing.
const blocks = (d) => {
  const c = d.message?.content
  if (typeof c === 'string') return c.trim() ? [{ type: 'text', text: c }] : []
  return Array.isArray(c) ? c : null
}
const renderable = (d) =>
  (d.type === 'assistant' || d.type === 'user') && blocks(d) !== null

function render(short, t, line) {
  let d
  try { d = JSON.parse(line) } catch { return }
  if (!renderable(d)) return
  const content = blocks(d)

  for (const b of content) {
    if (!b || typeof b !== 'object') continue
    if (b.type === 'text' && b.text?.trim()) {
      emit(short, t, `${B}●${R}`)
      for (const l of wrapUnder(b.text.trim(), 13)) console.log(`         ${t.color}│${R} ${l}`)
    } else if (b.type === 'thinking' && b.thinking?.trim() && !QUIET) {
      emit(short, t, `${DIM}✻ ${clip(b.thinking.trim().split('\n')[0], width() - 30)}${R}`)
    } else if (b.type === 'tool_use') {
      const s = toolSummary(b.name, b.input)
      emit(short, t, `\x1b[36m⚙ ${b.name}${R}${s ? ' ' + DIM + s + R : ''}`)
    } else if (b.type === 'tool_result' && !QUIET) {
      let text = typeof b.content === 'string' ? b.content
        : Array.isArray(b.content) ? b.content.map((x) => x?.text ?? '').join(' ') : ''
      const bytes = Buffer.byteLength(text || '')
      const first = clip((text.split('\n').find((l) => l.trim()) || ''), width() - 34)
      console.log(`         ${t.color}│${R} ${b.is_error ? '\x1b[31m✗' : DIM + '↳'} ${first}${bytes > 200 ? ` (${(bytes / 1024).toFixed(1)}kB)` : ''}${R}`)
    }
  }
}

// Returns the byte offset it painted THROUGH, which becomes the follow offset.
function paintTail(short, t, n) {
  let size
  try { size = fs.statSync(t.transcript).size } catch { return 0 }
  if (n <= 0) return size
  const span = Math.min(size, 256 * 1024)
  const got = readRange(t.transcript, size - span, size)
  if (!got) return size
  const lines = got.text.split('\n')
  if (size > span) lines.shift()
  const good = lines.filter((l) => {
    if (!l.trim()) return false
    try { return renderable(JSON.parse(l)) } catch { return false }
  })
  for (const l of good.slice(-n)) render(short, t, l)
  return got.end
}

function pump() {
  for (const [short, t] of tracked) {
    let size
    try { size = fs.statSync(t.transcript).size } catch { continue }
    if (size < t.offset) { t.offset = 0; t.carry = '' }
    if (size === t.offset) continue
    const got = readRange(t.transcript, t.offset, size)
    if (!got) continue                    // deleted under us: `discover` will retire it
    t.offset = got.end
    const lines = (t.carry + got.text).split('\n')
    t.carry = lines.pop() ?? ''
    for (const l of lines) if (l.trim()) render(short, t, l)
  }
}

function statusBar() {
  const rows = [...tracked.entries()].sort((a, b) => b[1].tokens - a[1].tokens)
  const w = width()
  console.log(`${DIM}${'═'.repeat(Math.min(w, 100))}${R}`)
  const cells = rows.map(([s, t]) => `${t.color}${s}${R} ${t.state === 'working' ? '\x1b[32m●' : '\x1b[33m◐'}${R}${DIM}${Math.round(t.tokens / 1000)}k${R}`)
  console.log(`${DIM}${hhmm(Date.now())} fleet ${rows.length}${R}  ${cells.join('  ')}`)
  console.log(`${DIM}${'═'.repeat(Math.min(w, 100))}${R}`)
  process.stdout.write(`\x1b]0;fleet ${rows.length} live\x07`)
}

console.log(`${B}Claude fleet — one terminal, every live session.${R}`)
console.log(`${DIM}read-only; Ctrl-C detaches and changes nothing. --quiet for headlines only.${R}`)
console.log(`${DIM}to WRITE to a session: run ${R}${B}fleet write${R}${DIM} in any terminal, then:${R}`)
console.log(`${DIM}   ↑/↓ pick a session · ${R}${B}space${R}${DIM} = reply to it · enter = open it · esc = quit${R}`)
discover()
statusBar()
setInterval(pump, 1000)
setInterval(discover, 5000)
setInterval(statusBar, 60000)
process.on('SIGINT', () => { console.log(`\n${DIM}fleet-watch: detached — every session keeps running.${R}`); process.exit(0) })
