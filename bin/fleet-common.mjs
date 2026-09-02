// Shared by the two fleet viewers (fleet-tail.mjs, one session; fleet-watch.mjs, the whole
// fleet). Both were copy-paste forks of the same reader, and the copies had already drifted
// in their COMMENTS while the code stayed identical -- which is the state just before they
// drift in behaviour too, and a `blocks()` that disagreed between the two panes would show
// one pane a turn the other silently dropped. One definition, both importers.
//
// Nothing here touches process state, terminal width or colour: those differ between the two
// viewers by design and stay in their own files.
import fs from 'node:fs'

// Read [from, to) out of a file that may vanish mid-read.
//
// Two things this exists for, both learned the hard way:
//
// (1) The transcript belongs to ANOTHER process. 3 of this machine's 51 working/blocked job
//     rows already pointed at a linkScanPath that was gone (measured 2026-08-21), and every
//     openSync used to sit outside any try -- inside a setInterval callback, where an
//     uncaught ENOENT does not skip one session, it terminates the whole viewer.
// (2) It is the MEMORY BOUND. `Buffer.alloc(size - offset)` let one appended tool_result
//     decide the footprint of a process whose whole pitch is 35 MB instead of a gigabyte.
//     This reads in fixed CHUNKS and stops at the caller's boundary.
//
// Returns null (never throws) when the file is gone or unreadable; the caller decides what
// that means for its own view.
export const CHUNK = 64 * 1024

export function readRange(file, from, to) {
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

// Collapse whitespace and cut to n columns, ellipsis included in the budget.
export const clip = (s, n) => {
  s = String(s ?? '').replace(/\s+/g, ' ').trim()
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}

export const hhmm = (ts) => {
  try { return new Date(ts).toISOString().slice(11, 19) } catch { return '--:--:--' }
}

// The daemon writes a plain user turn as `message.content: "<the prompt>"`, NOT as an array
// of blocks. Requiring an array therefore dropped EVERY such turn: 555 of them across 163 of
// this machine's 170 readable transcripts, 100% of them `type: 'user'`, and they are the
// DISPATCH PROMPTS -- "Read the handoff file at ...". So the read-only panes showed Claude's
// answers with the instruction that produced them missing, which is not a gap in a log, it is
// a misleading account of what a session was told to do. Normalise here, at the ONE place
// both the initial paint and the follow loop go through.
//
// The three cases are distinct and all load-bearing: a string becomes a one-element text
// block (empty string -> [], a turn with nothing to show), an array passes through, and
// anything else returns null, which is what `renderable` reads as "not a turn".
export const blocks = (d) => {
  const c = d.message?.content
  if (typeof c === 'string') return c.trim() ? [{ type: 'text', text: c }] : []
  return Array.isArray(c) ? c : null
}

export const renderable = (d) =>
  (d.type === 'assistant' || d.type === 'user') && blocks(d) !== null
