#!/usr/bin/env node
// fleet-tail.mjs — live, read-only view of one background Claude session.
//
// Streams the session transcript (never buffers the whole file) and renders it
// compactly. Read-only by construction: it opens no session and spends no tokens,
// so a pane costs ~30 MB instead of the ~1 GB a second live session would.
//
//   fleet-tail.mjs <short-session-id> [--back N]

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { parseFlags } from './fleet-flags.mjs'

const JOBS = path.join(os.homedir(), '.claude', 'jobs')

// One reader for all three of `fleet`'s argv surfaces -- see fleet-flags.mjs. The old
// two lines here were `argv.find((a) => !a.startsWith('-'))` plus
// `Number(argv[argv.indexOf('--back') + 1]) || 12`, which read the SESSION ID as the
// back-count whenever --back was absent (indexOf -> -1 -> argv[0]) and silently turned
// an explicit `--back 0` into 12.
const { values, positionals } = parseFlags(process.argv.slice(2), {
  name: 'fleet-tail',
  usage: '  usage: fleet-tail.mjs <short-session-id> [--back <n>]',
  numeric: { '--back': 12 },
  positionals: { name: 'a short session id', min: 1, max: 1 },
})
const short = positionals[0]
const back = values['--back']

const C = {
  dim: '\x1b[2m', reset: '\x1b[0m', bold: '\x1b[1m',
  cyan: '\x1b[36m', green: '\x1b[32m', yellow: '\x1b[33m',
  red: '\x1b[31m', mag: '\x1b[35m', blue: '\x1b[34m',
}
const width = () => Math.max(40, process.stdout.columns || 100)

const statePath = path.join(JOBS, short, 'state.json')

function readState() {
  try { return JSON.parse(fs.readFileSync(statePath, 'utf8')) } catch { return null }
}

const st0 = readState()
if (!st0) {
  console.error(`fleet-tail: no job state at ${statePath}`)
  process.exit(1)
}
const transcript = st0.linkScanPath
if (!transcript || !fs.existsSync(transcript)) {
  console.error(`fleet-tail: transcript missing for ${short}: ${transcript}`)
  process.exit(1)
}

const stateColor = (s) =>
  s === 'working' ? C.green : s === 'done' ? C.blue :
  s === 'failed' ? C.red : s === 'blocked' ? C.yellow : C.dim

function header(st) {
  const w = width()
  const name = (st.name || short).slice(0, w - 2)
  const cwd = (st.cwd || '').replace(os.homedir(), '~')
  console.log(`${C.bold}${'─'.repeat(w)}${C.reset}`)
  console.log(`${C.bold}${name}${C.reset}  ${C.dim}${short}${C.reset}`)
  console.log(`${C.dim}${cwd}${C.reset}`)
  console.log(`${C.bold}${'─'.repeat(w)}${C.reset}`)
}

// ONE guarded read of a byte range. Every fs call on the transcript lives here because
// the transcript belongs to another process: 3 of this machine's 51 working/blocked job
// rows already point at a linkScanPath that is GONE (measured 2026-08-21), and every
// openSync in this file used to sit outside any try -- inside a setInterval callback,
// where an uncaught ENOENT does not skip a session, it terminates the viewer.
//
// It is also the memory bound. `Buffer.alloc(size - offset)` let one appended tool_result
// decide the process footprint, which is the opposite of what the header advertises; this
// reads in fixed CHUNKS and stops at the caller's boundary.
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
    return null                       // gone, or unreadable: the caller decides what that means
  } finally {
    if (fd !== null) { try { fs.closeSync(fd) } catch {} }
  }
}

const clip = (s, n) => {
  s = String(s ?? '').replace(/\s+/g, ' ').trim()
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}

function wrap(text, indent) {
  const w = width() - indent.length
  const out = []
  for (const para of String(text).split('\n')) {
    if (!para.trim()) { out.push(''); continue }
    let line = ''
    for (const word of para.split(/\s+/)) {
      if (line && (line + ' ' + word).length > w) { out.push(line); line = word }
      else line = line ? line + ' ' + word : word
    }
    if (line) out.push(line)
  }
  return out.map((l) => indent + l).join('\n')
}

// One-line summary of a tool call — the argument that identifies WHAT it did.
function toolSummary(name, input) {
  const i = input || {}
  const pick =
    i.command ?? i.file_path ?? i.path ?? i.pattern ?? i.url ??
    i.prompt ?? i.query ?? i.description ?? i.message ?? i.skill
  if (pick != null) return clip(pick, Math.max(20, width() - name.length - 12))
  const keys = Object.keys(i)
  return keys.length ? clip(keys.join(','), 40) : ''
}

const hhmm = (ts) => {
  try { return new Date(ts).toISOString().slice(11, 19) } catch { return '--:--:--' }
}

// The daemon writes a plain user turn as `message.content: "<the prompt>"`, NOT as an
// array of blocks. Requiring an array therefore dropped EVERY such turn: 555 of them
// across 163 of this machine's 170 readable transcripts, 100% of them `type: 'user'`,
// and they are the dispatch prompts -- "Read the handoff file at ..." . So the read-only
// panes showed Claude's answers with the instruction that produced them missing, which
// is not a gap in a log, it is a misleading account of what a session was told to do.
// Normalise here, at the ONE place both the initial paint and the follow loop go through.
const blocks = (d) => {
  const c = d.message?.content
  if (typeof c === 'string') return c.trim() ? [{ type: 'text', text: c }] : []
  return Array.isArray(c) ? c : null
}
const renderable = (d) =>
  (d.type === 'assistant' || d.type === 'user') && blocks(d) !== null

function render(line) {
  let d
  try { d = JSON.parse(line) } catch { return }
  if (!renderable(d)) return
  const content = blocks(d)
  const stamp = `${C.dim}${hhmm(d.timestamp)}${C.reset} `

  for (const b of content) {
    if (!b || typeof b !== 'object') continue
    if (b.type === 'text' && b.text?.trim()) {
      console.log(stamp + `${C.bold}●${C.reset}`)
      console.log(wrap(b.text.trim(), '  '))
      console.log('')
    } else if (b.type === 'thinking' && b.thinking?.trim()) {
      const first = b.thinking.trim().split('\n')[0]
      console.log(stamp + `${C.dim}✻ ${clip(first, width() - 14)}${C.reset}`)
    } else if (b.type === 'tool_use') {
      const s = toolSummary(b.name, b.input)
      console.log(stamp + `${C.cyan}⚙ ${b.name}${C.reset}${s ? ' ' + C.dim + s + C.reset : ''}`)
    } else if (b.type === 'tool_result') {
      let text = ''
      if (typeof b.content === 'string') text = b.content
      else if (Array.isArray(b.content)) text = b.content.map((x) => x?.text ?? '').join(' ')
      const bytes = Buffer.byteLength(text || '')
      const first = clip(text.split('\n').find((l) => l.trim()) || '', width() - 26)
      const mark = b.is_error ? `${C.red}✗${C.reset}` : `${C.dim}↳${C.reset}`
      console.log(`         ${mark} ${C.dim}${first}${bytes > 200 ? ` (${(bytes / 1024).toFixed(1)}kB)` : ''}${C.reset}`)
    }
  }
}

// ── initial paint: last `back` renderable entries, read from the tail only ──
// The boundary is read ONCE and reused as the follow offset. Two stats used to bracket
// this block, so a turn appended between them was painted by neither: the initial paint
// had already stopped, and `offset` started past it. That turn was lost for good.
header(st0)
let offset = 0
{
  const size = (() => { try { return fs.statSync(transcript).size } catch { return 0 } })()
  const span = Math.min(size, 512 * 1024)
  const got = readRange(transcript, size - span, size)
  offset = got ? got.end : size            // paint through here, follow from here
  const lines = (got ? got.text : '').split('\n')
  if (size > span) lines.shift() // partial first line
  const paint = lines.filter((l) => {
    if (!l.trim()) return false
    try { return renderable(JSON.parse(l)) } catch { return false }
  })
  for (const l of paint.slice(-back)) render(l)
}

// ── follow ──
let carry = ''
let lastState = st0.state
let lastTokens = st0.tokens

function pump() {
  let size
  try { size = fs.statSync(transcript).size } catch { return }
  if (size < offset) { offset = 0; carry = '' }   // truncated/rotated
  if (size === offset) return
  const got = readRange(transcript, offset, size)
  if (!got) return                                // deleted under us: try again next tick
  offset = got.end
  const lines = (carry + got.text).split('\n')
  carry = lines.pop() ?? ''
  for (const l of lines) if (l.trim()) render(l)
}

function statusPoll() {
  const st = readState()
  if (!st) return
  if (st.state !== lastState) {
    const c = stateColor(st.state)
    console.log(`${C.dim}${hhmm(new Date().toISOString())}${C.reset} ${c}${C.bold}▲ ${lastState} → ${st.state}${C.reset} ${C.dim}${st.detail ? clip(st.detail, width() - 30) : ''}${C.reset}`)
    lastState = st.state
  }
  if (typeof st.tokens === 'number' && st.tokens !== lastTokens) {
    lastTokens = st.tokens
    const title = `${short} ${st.state} ${(st.tokens / 1000).toFixed(0)}k`
    process.stdout.write(`\x1b]0;${title}\x07`)  // terminal tab title
  }
}

setInterval(pump, 1000).unref?.()
setInterval(statusPoll, 4000).unref?.()
setInterval(() => {}, 1 << 30)  // keep alive
process.on('SIGINT', () => { console.log(`\n${C.dim}fleet-tail: detached (session keeps running)${C.reset}`); process.exit(0) })
