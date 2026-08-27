// Claude Fleet — a status-bar button that splits the live background-Claude
// sessions into the terminal panel you are already looking at.
//
// Design note, learned the hard way: the VS Code EXTENSION HOST is a
// GUI-launched process. Its PATH is launchd's bare four directories, so
// `node`, `claude` and `fleet` are all invisible to it. Every binary here is
// resolved by ABSOLUTE PATH, and nothing fails silently — a button that does
// nothing when clicked is the exact bug this replaces.

const vscode = require('vscode')
const cp = require('child_process')
const execFile = require('util').promisify(cp.execFile)
const fs = require('fs')
const os = require('os')
const path = require('path')

const CANDIDATES = [
  path.join(os.homedir(), '.local/bin/fleet'),
  '/opt/homebrew/bin/fleet',
  '/usr/local/bin/fleet',
]

/** @type {vscode.Terminal[]} */
let created = []
// Bumped by every replacement, Close and deactivate. An async `doSplit` that
// started before the bump must not create panes afterwards -- otherwise clicking
// Close while a split is still reading the roster leaves panes open behind it.
let generation = 0
/** @type {vscode.StatusBarItem} */
let status
let timer

function fleetPath() {
  const configured = vscode.workspace.getConfiguration('claudeFleet').get('fleetPath')
  if (configured) {
    if (!isExec(configured)) throw new Err(`claudeFleet.fleetPath is set to ${configured}, which is not an executable file.`)
    return configured
  }
  for (const c of CANDIDATES) if (isExec(c)) return c
  throw new Err(
    'The `fleet` script was not found.',
    `Looked in: ${CANDIDATES.join(', ')}. ` +
    'The extension host runs with no shell, so it cannot use your PATH — ' +
    'set `claudeFleet.fleetPath` to the absolute path instead.'
  )
}

function isExec(p) {
  try { fs.accessSync(p, fs.constants.X_OK); return fs.statSync(p).isFile() } catch { return false }
}

class Err extends Error {
  constructor(message, detail) { super(message); this.detail = detail || '' }
}

/**
 * The ONE roster read. `fleet ids` is the single enumeration every surface
 * shares, so a session can never be live for the button and invisible to
 * `fleet who` (or the reverse).
 * ASYNC on purpose: this polls every 20s, and a synchronous exec would block
 * the extension-host thread (50ms today at 103 job dirs, more as that grows).
 * Never block the host on a timer.
 * @returns {Promise<{short:string,state:string,ok:boolean,mins:number,cwd:string,name:string}[]>}
 */
async function roster({ reachableOnly = true, maxAge = 60 } = {}) {
  const bin = fleetPath()
  // DECISION: there is no `max` here. `fleet ids --max` exists and the script is
  // tested for it, but truncating at the SOURCE is what cost the pane labels their
  // short id in round 3 -- a roster cut to three rows cannot see that one of them
  // shares a name with a fourth. Every caller reads the WHOLE roster and slices for
  // DISPLAY. Do not add the option back; add the slice at the call site instead.
  const args = ['ids', '--max-age', String(maxAge)]
  if (reachableOnly) args.push('--reachable')
  let out
  try {
    ;({ stdout: out } = await execFile(bin, args, { encoding: 'utf8', timeout: 15000 }))
  } catch (e) {
    throw new Err('`fleet ids` failed.', (e.stderr || e.message || '').toString().trim())
  }
  return out.split('\n').filter(Boolean).map((line) => {
    const [short, state, ok, mins, cwd, ...rest] = line.split('\t')
    // A tab label is a UI surface: never show a raw session id if anything
    // human-readable exists. `state.json` can carry no name at all (seen live:
    // job faed3ee8), so fall back to the worktree it is running in.
    const raw = rest.join('\t').trim()
    const name = raw && raw !== '?' ? raw : (path.basename(cwd || '') || short)
    return { short, state, ok: ok === '1', mins: Number(mins), cwd, name }
  })
}

function closeCreated() {
  generation++
  for (const t of created) { try { t.dispose() } catch { /* already gone */ } }
  created = []
}

/**
 * Split `rows` into the CURRENT terminal panel, in groups of `perGroup`.
 *
 * Two VS Code mechanics do the work, and they are the reason this is tested
 * against a stub rather than eyeballed:
 *   - a terminal created with NO `location` becomes its own TAB (an entry in
 *     the list down the right-hand side of the panel);
 *   - a terminal created with `location: { parentTerminal }` becomes a SPLIT
 *     PANE beside that parent.
 * So one group = one tab holding `perGroup` side-by-side panes, and eight live
 * sessions at perGroup=3 give three tabs: 3 + 3 + 2.
 *
 * @param {'open'|'read'} mode  'open' = writable (the picker, narrowed to that
 *   session; enter opens it and you type straight into it). 'read' = the
 *   read-only tail, which is a cheap node process rather than a whole Claude.
 */
function splitInto(rows, mode, perGroup, authorisedAt, allRows, cutoff) {
  if (authorisedAt !== undefined && authorisedAt !== generation) return   // superseded mid-flight
  closeCreated()
  const bin = fleetPath()
  // The cutoff is the one the ROSTER was filtered with, handed in by the caller --
  // never re-read here. Every caller awaits at least one roster read and usually a
  // picker or a modal before reaching this point, and a setting changed during that
  // wait would put a row in the panes under one cutoff and into `fleet open` under
  // another, which is exactly the disagreement the shared resolver exists to prevent.
  const cut = String(cutoff)
  const per = perGroup
  let firstLeader = null
  // The pane LABEL is the only identifier that survives: `claude agents` takes the
  // whole screen 0.19s after launch (measured) and wipes the header that said which
  // row to pick. So where two of the panes being opened carry the same name -- two
  // sessions in one worktree, or the `basename(cwd) (unnamed)` fallback -- the label
  // carries the short id too. Only the ambiguous ones: adding it everywhere would
  // spend tab width on a distinction that is not being made.
  // Counted over the WHOLE roster, not the rows being opened. "Just the freshest 3"
  // and the multi-select picker both hand this function a SLICE, and a slice that
  // happens to contain one of two same-name sessions used to lose the short id --
  // the pane went back to reading "\u25cb same name" with no way to tell which of the
  // two it was, which is the one thing the label exists to say.
  const seen = new Map()
  for (const r of (allRows || rows)) seen.set(r.name, (seen.get(r.name) || 0) + 1)
  const labelFor = (r) =>
    `${r.state === 'blocked' ? '●' : '○'} ${r.name}${seen.get(r.name) > 1 ? ` · ${r.short}` : ''}`
  for (let i = 0; i < rows.length; i += per) {
    let parent = null
    for (const r of rows.slice(i, i + per)) {
      const opts = {
        name: labelFor(r),
        shellPath: bin,
        shellArgs: mode === 'read' ? [r.short, '--back', '14'] : ['open', r.short, '--max-age', String(cut)],
        cwd: fs.existsSync(r.cwd) ? r.cwd : os.homedir(),
        iconPath: new vscode.ThemeIcon(r.state === 'blocked' ? 'bell-dot' : 'pulse'),
        isTransient: true,
      }
      if (parent) opts.location = { parentTerminal: parent }
      const t = vscode.window.createTerminal(opts)
      created.push(t)
      if (!parent) { parent = t; t.show(false); if (!firstLeader) firstLeader = t }
    }
  }
  if (firstLeader) firstLeader.show(false)   // land back on the first group
}

async function withErrors(fn) {
  try { await fn() } catch (e) {
    if (e instanceof Err) {
      const detail = e.detail ? `  ${e.detail}` : ''
      vscode.window.showErrorMessage(`Claude Fleet: ${e.message}${detail}`)
    } else {
      vscode.window.showErrorMessage(`Claude Fleet: ${e && e.message ? e.message : String(e)}`)
    }
  }
}

function cfg(key) { return vscode.workspace.getConfiguration('claudeFleet').get(key) }

/**
 * The age cutoff, resolved ONCE and handed to both sides.
 *
 * `fleet ids` decides which sessions exist; `fleet open <short>` re-reads the same
 * roster to resolve the id it was given. When those two used different cutoffs the
 * extension could open a pane for a row `fleet open` then refused outright -- the
 * setting has no upper bound, `fleet open` hardcoded 1440, and a maxAgeMinutes of
 * 4320 produced a pane whose only output was "no live session <short>". They cannot
 * disagree now: this value goes into the roster args AND into the pane's argv.
 *
 * And it is a WHOLE number of minutes, bounded like `panes`. `fleet open` accepts
 * only digits for --max-age, while the manifest used to say `number` -- so a
 * schema-valid 1.5 listed every row and then made every pane die on
 * "needs a whole number of minutes". A value past MAX_AGE would likewise reach the
 * script as `1e+21`. The manifest now says `integer` with this same maximum; the
 * floor and clamp here cover a settings.json written before it did.
 */
const MAX_AGE = 525600   // a year of minutes, and the manifest's `maximum`
function ageCutoff() {
  const n = Math.floor(Number(cfg('maxAgeMinutes')))
  return Number.isFinite(n) && n >= 1 ? Math.min(n, MAX_AGE) : 60
}

/**
 * The group size, normalised ONCE. A fractional `panes` (3.5) walked non-integer
 * slice bounds and produced groups BIGGER than the setting asked for, so this is
 * floored and bounded rather than merely defaulted. Bounded above because every
 * writable pane is a whole Claude process.
 */
function groupSize() {
  const n = Math.floor(Number(cfg('panes')))
  return Number.isFinite(n) ? Math.min(Math.max(n, 1), 12) : 3
}

/**
 * How many WRITABLE panes may be opened, asking first past `confirmAbove`.
 *
 * A writable pane is a whole `claude` process, not a log tail, and this machine has
 * already lost VS Code and seven background sessions to memory pressure once. The
 * gate therefore guards the COUNT, wherever the count comes from -- the one-click
 * button and the multi-select picker alike. The picker matters especially: it opens
 * with every row pre-ticked, so a single Enter there is exactly as expensive as the
 * button and must not slip past.
 *
 * Read-only tails are cheap and are never gated.
 * @returns {Promise<number>} how many rows to open; 0 means the user declined.
 */
async function confirmWritable(mode, count, per) {
  const limit = Number(cfg('confirmAbove')) || 0
  if (mode !== 'open' || limit <= 0 || count <= limit) return count
  const groups = Math.ceil(count / per)
  // The limiting button must open strictly FEWER than "all", or it lies. With
  // panes=12 and an 8-row roster it used to read "Just the freshest 12" and open
  // every one of the eight -- the reassuring button doing the expensive thing.
  const safe = Math.min(per, count - 1)
  const all = `Open all ${count}`
  const just = safe >= 1 ? `Just the freshest ${safe}` : null
  const go = await vscode.window.showWarningMessage(
    `Open all ${count} live sessions? That is ${groups} tab${groups === 1 ? '' : 's'} of ` +
    `up to ${per} panes, and each writable pane runs its own Claude process.`,
    { modal: true },
    ...(just ? [all, just] : [all])
  )
  if (!go) return 0
  // Compared against the exact string that was offered, never a prefix: a reworded
  // button used to fall through to `count` and open everything.
  return go === just ? safe : count
}

async function doSplit(mode, onlyFirstGroup) {
  const per = groupSize()
  // RESERVE the token, do not merely read it. Two clicks that both read the same
  // value would let whichever roster read returned FIRST win -- so a later, cheaper
  // splitFreshest could lose to the full split it was meant to replace.
  const at = ++generation
  // Read the WHOLE roster even for splitFreshest, which used to ask `fleet ids`
  // for three rows and nothing else. A roster truncated at the source cannot see
  // that the session it is about to open shares a name with a fourth one, so the
  // pane label lost its short id exactly when there was another session to confuse
  // it with. Truncation is a display decision and belongs here; the read costs 60ms
  // over 103 job dirs either way.
  const cut = ageCutoff()
  const all = await roster({ reachableOnly: cfg('reachableOnly'), maxAge: cut })
  const rows = onlyFirstGroup ? all.slice(0, per) : all
  if (!rows.length) {
    // The fleet has drained. Panes from a previous click are pointing at sessions
    // that no longer exist, so clear them -- otherwise the warning contradicts the
    // panes still on screen.
    if (at === generation) closeCreated()
    vscode.window.showWarningMessage(
      'Claude Fleet: no live background sessions right now. ' +
      '(Run `fleet who` in a terminal to see what the daemon thinks is running.)'
    )
    return
  }
  const keep = await confirmWritable(mode, rows.length, per)
  if (!keep) return
  splitInto(rows.slice(0, keep), mode, per, at, all, cut)
}

async function refreshStatus() {
  if (!status) return
  let rows
  try {
    rows = await roster({ reachableOnly: cfg('reachableOnly'), maxAge: ageCutoff() })
  } catch (e) {
    status.text = '$(warning) Fleet'
    status.tooltip = `Claude Fleet: ${e.message}\n${e.detail || ''}`.trim()
    status.show()
    return
  }
  const waiting = rows.filter((r) => r.state === 'blocked').length
  status.text = `$(layout-panel) Fleet ${rows.length}${waiting ? ` $(bell-dot) ${waiting}` : ''}`
  const per = groupSize()
  const groups = Math.ceil(rows.length / per)
  const md = new vscode.MarkdownString(
    `**Click** to open all ${rows.length} in this terminal panel — ` +
    `${groups} tab${groups === 1 ? '' : 's'} of up to ${per} panes you can type into.\n\n` +
    rows.map((r) => `${r.state === 'blocked' ? '●' : '○'} \`${r.short}\`  ${r.name} — ${r.mins}m`).join('\n\n') +
    `\n\n● waiting on you  ○ working\n\nIn a pane: **enter** opens that session so you can write to it, **space** replies without opening.`
  )
  md.supportThemeIcons = true
  status.tooltip = md
  status.show()
}

function activate(context) {
  status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100)
  status.command = 'claudeFleet.split'
  status.text = '$(layout-panel) Fleet'
  context.subscriptions.push(status)

  const reg = (id, fn) => context.subscriptions.push(vscode.commands.registerCommand(id, () => withErrors(fn)))

  reg('claudeFleet.split', async () => doSplit('open', false))
  reg('claudeFleet.splitFreshest', async () => doSplit('open', true))
  reg('claudeFleet.splitRead', async () => doSplit('read', false))
  reg('claudeFleet.close', async () => { closeCreated(); await refreshStatus() })

  reg('claudeFleet.pick', async () => {
    // The picker awaits TWO user interactions (the quick pick, then possibly the cost
    // modal), so it is the path most likely to still be pending when Close is clicked.
    // It reserves and carries a token exactly like doSplit.
    const at = ++generation
    const cut = ageCutoff()
    const rows = await roster({ reachableOnly: cfg('reachableOnly'), maxAge: cut })
    if (!rows.length) {
      if (at === generation) closeCreated()
      vscode.window.showWarningMessage('Claude Fleet: no live background sessions right now.')
      return
    }
    const picked = await vscode.window.showQuickPick(
      rows.map((r) => ({
        label: `${r.state === 'blocked' ? '$(bell-dot)' : '$(pulse)'} ${r.name}`,
        description: `${r.short}  ·  ${r.mins}m`,
        detail: r.cwd,
        row: r,
        picked: true,
      })),
      { canPickMany: true, title: 'Split which sessions into the terminal panel?' }
    )
    if (!picked || !picked.length) return
    const per = groupSize()
    const keep = await confirmWritable('open', picked.length, per)
    if (!keep) return
    splitInto(picked.slice(0, keep).map((p) => p.row), 'open', per, at, rows, cut)
  })

  reg('claudeFleet.watch', async () => {
    closeCreated()
    const t = vscode.window.createTerminal({
      name: 'Fleet — all sessions',
      shellPath: fleetPath(),
      iconPath: new vscode.ThemeIcon('list-tree'),
      isTransient: true,
    })
    created.push(t); t.show(false)
  })

  reg('claudeFleet.write', async () => {
    // DECISION: this terminal is deliberately NOT pushed to `created`. Every other
    // pane here belongs to the fleet view and Close reclaims it; this one belongs to
    // YOUR — it is the pane you are typing a reply into. A Close (or the next click of
    // the button, which replaces the round) must never take it out from under you.
    const t = vscode.window.createTerminal({
      name: 'Fleet — reply',
      shellPath: fleetPath(),
      shellArgs: ['write'],
      iconPath: new vscode.ThemeIcon('comment-discussion'),
    })
    t.show(true)
  })

  context.subscriptions.push(vscode.window.onDidCloseTerminal((t) => {
    created = created.filter((x) => x !== t)
  }))

  refreshStatus()
  timer = setInterval(() => { refreshStatus() }, 20000)
  context.subscriptions.push({ dispose: () => clearInterval(timer) })
}

function deactivate() { clearInterval(timer); closeCreated() }

module.exports = { activate, deactivate }
