const assert = require('assert')
const path = require('path')
const fs = require('fs')
const vscode = require('vscode')
const S = vscode.__state
const ext = require(process.env.EXT + '/extension.js')

const REAL = path.join(require('os').homedir(), '.local/bin/fleet')
const FAKE = path.join(__dirname, 'fake-fleet')

let pass = 0, fail = 0
const t = (name, fn) => { try { fn(); pass++; console.log('  ok   ' + name) } catch (e) { fail++; console.log('  FAIL ' + name + '\n       ' + String(e.message).split('\n')[0]) } }
const reset = () => { S.terminals.length = 0; S.disposed.length = 0; S.errors.length = 0; S.warnings.length = 0; S.modals.length = 0; S.answer = undefined; S.quickPick = null; S.quickPickCalls.length = 0; S.shown.length = 0
  delete process.env.FAKE_FLEET_MODE; delete process.env.FAKE_FLEET_ROWS; delete process.env.FAKE_FLEET_DUPS
  delete process.env.FAKE_FLEET_ARGV; delete process.env.FAKE_FLEET_SLEEP
  delete process.env.FAKE_FLEET_UNREACH }

/** Wait until `fn()` is true, so a test can act on a command that is mid-await. */
const until = async (fn, what) => {
  for (let i = 0; i < 400; i++) { if (fn()) return; await new Promise((r) => setTimeout(r, 5)) }
  throw new Error('timed out waiting for ' + what)
}
/** The short ids behind the terminals, in the order they were opened. */
const openedShorts = () => S.terminals.map((x) => x.opts.shellArgs[x.opts.shellArgs[0] === 'open' ? 1 : 0])
/** Group sizes, derived from where the tabs (no `location`) fall. */
const groupSizes = () => {
  const tabs = leaders()
  return tabs.map((at, k) => (k + 1 < tabs.length ? tabs[k + 1] : S.terminals.length) - at)
}

/** Indices of terminals that opened as their own TAB (no parentTerminal). */
const leaders = () => S.terminals.map((x, i) => (x.opts.location ? -1 : i)).filter((i) => i >= 0)

async function main() {
// The fleet on THIS machine is whatever happens to be running, so the grouping
// tests drive a deterministic stand-in instead. It also exercises the
// configured-fleetPath branch for free.
S.config = { panes: 3, maxAgeMinutes: 60, reachableOnly: true, fleetPath: FAKE, confirmAbove: 0 }
ext.activate({ subscriptions: [] })

// ---- 1. GROUPS OF THREE: 8 sessions -> tabs of 3 + 3 + 2 -------------------
reset(); await S.commands['claudeFleet.split']()
t('every live session gets a pane (8 of them)', () => assert.strictEqual(S.terminals.length, 8))
t('8 sessions at panes=3 make exactly 3 TABS, opening at 0, 3, 6', () =>
  assert.deepStrictEqual(leaders(), [0, 3, 6]))
t('a pane is parented to ITS OWN group leader, not to the first tab', () => {
  for (let i = 0; i < S.terminals.length; i++) {
    const leader = S.terminals[Math.floor(i / 3) * 3]
    if (i % 3 === 0) { assert.strictEqual(S.terminals[i].opts.location, undefined, `terminal ${i} should open a new TAB`); continue }
    assert.ok(S.terminals[i].opts.location, `terminal ${i} has no location -> it would open as a TAB, not a split`)
    assert.strictEqual(S.terminals[i].opts.location.parentTerminal, leader,
      `terminal ${i} is split off the wrong tab (all-parented-to-[0] is the bug this catches)`)
  }
})
t('each pane is WRITABLE: `fleet open <short> --max-age <cut>` by absolute path', () => {
  assert.strictEqual(S.terminals.length, 8, 'nothing opened: the loop below would check nothing')
  for (const x of S.terminals) {
    assert.strictEqual(x.opts.shellPath, FAKE)
    assert.strictEqual(x.opts.shellArgs[0], 'open')
    assert.match(x.opts.shellArgs[1], /^[0-9a-z]{8}$/)
    // The cutoff travels WITH the id. `fleet open` re-reads the roster to resolve
    // the short it was handed, and it used to do that at a hardcoded 1440 minutes
    // while this setting had no upper bound -- so maxAgeMinutes: 4320 opened a pane
    // whose entire output was `no live session <short>`.
    assert.deepStrictEqual(x.opts.shellArgs.slice(2), ['--max-age', '60'])
    assert.strictEqual(x.opts.shellArgs.length, 4)
  }
})

t('panes are named after the session, never a bare id', () =>
  assert.ok(S.terminals.every((x) => /^[●○] \S/.test(x.opts.name) && !/^[●○] [0-9a-f]{8}$/.test(x.opts.name))))
t('the ● / ○ marker follows the session state', () => {
  assert.ok(S.terminals[0].opts.name.startsWith('●'), 'a blocked session should be marked ●')
  assert.ok(S.terminals[1].opts.name.startsWith('○'), 'a working session should be marked ○')
})
t('no error and no prompt on the happy path', () =>
  assert.deepStrictEqual([S.errors, S.warnings], [[], []]))

// ---- 2. the group size is the `panes` setting ------------------------------
reset(); S.config.panes = 4; await S.commands['claudeFleet.split']()
t('panes=4 makes 2 tabs, opening at 0 and 4', () => assert.deepStrictEqual(leaders(), [0, 4]))
reset(); S.config.panes = 1; await S.commands['claudeFleet.split']()
t('panes=1 degenerates to 8 separate tabs, never a crash', () =>
  assert.deepStrictEqual(leaders(), [0, 1, 2, 3, 4, 5, 6, 7]))
S.config.panes = 3

// ---- 3. just the freshest group -------------------------------------------
reset(); await S.commands['claudeFleet.splitFreshest']()
t('splitFreshest opens ONE tab of `panes`', () => {
  assert.strictEqual(S.terminals.length, 3)
  assert.deepStrictEqual(leaders(), [0])
})

// ---- 4. the read-only view still exists and is a DIFFERENT command ---------
reset(); await S.commands['claudeFleet.splitRead']()
t('splitRead runs the cheap tail, not a Claude process', () => {
  assert.deepStrictEqual(S.terminals[0].opts.shellArgs.slice(1), ['--back', '14'])
  assert.match(S.terminals[0].opts.shellArgs[0], /^[0-9a-z]{8}$/)
  assert.deepStrictEqual(leaders(), [0, 3, 6])
})
t('read-only panes never prompt about cost', () => assert.deepStrictEqual(S.modals, []))

// ---- 5. opening many WRITABLE panes asks first ------------------------------
S.config.confirmAbove = 6
reset(); S.answer = undefined; await S.commands['claudeFleet.split']()
t('dismissing the prompt opens NOTHING', () => {
  assert.strictEqual(S.modals.length, 1)
  assert.strictEqual(S.terminals.length, 0)
})
t('the prompt says how many tabs and why it costs', () => {
  assert.match(S.modals[0].message, /8 live sessions/)
  assert.match(S.modals[0].message, /3 tabs/)
  assert.match(S.modals[0].message, /own Claude process/)
})
reset(); S.answer = 'Just the freshest 3'; await S.commands['claudeFleet.split']()
t('"just the freshest" opens one tab of 3', () => {
  assert.strictEqual(S.terminals.length, 3)
  assert.deepStrictEqual(leaders(), [0])
})
reset(); S.answer = 'Open all 8'; await S.commands['claudeFleet.split']()
t('"open all" opens all 8 in 3 tabs', () => {
  assert.strictEqual(S.terminals.length, 8)
  assert.deepStrictEqual(leaders(), [0, 3, 6])
})
reset(); S.answer = undefined; await S.commands['claudeFleet.splitRead']()
t('the cost gate does NOT apply to read-only tails', () => {
  assert.deepStrictEqual(S.modals, [])
  assert.strictEqual(S.terminals.length, 8)
})
S.config.confirmAbove = 0

// ---- 6. clicking twice replaces, never piles up ----------------------------
reset(); await S.commands['claudeFleet.split']()
const firstRound = S.terminals.slice()
S.disposed.length = 0
await S.commands['claudeFleet.split']()
t('a second click disposes the first round', () => {
  assert.strictEqual(S.disposed.length, firstRound.length)
  assert.deepStrictEqual(S.disposed.map((x) => x.opts.shellArgs.join(' ')), firstRound.map((x) => x.opts.shellArgs.join(' ')))
})
reset(); await S.commands['claudeFleet.split']()
S.disposed.length = 0
await S.commands['claudeFleet.close']()
t('close disposes every pane it opened', () => assert.strictEqual(S.disposed.length, 8))

// ---- 7. it FAILS LOUDLY when fleet is missing (the whole point) ------------
reset(); S.config.fleetPath = '/nonexistent/fleet'; await S.commands['claudeFleet.split']()
t('a bad fleetPath surfaces an error and opens NO terminal', () => {
  assert.strictEqual(S.terminals.length, 0)
  assert.strictEqual(S.errors.length, 1)
  assert.match(S.errors[0], /not an executable file/)
})

// ---- 8. against the REAL fleet: the TSV contract still holds ---------------
// The fake above can drift from the script it stands in for, so drive the real
// one once. Zero live sessions is a legitimate outcome; a parse failure is not.
reset(); S.config.fleetPath = REAL; S.config.confirmAbove = 0
// Ask the real script the SAME question the extension is about to ask, before it
// does. Two reasons. (1) Vacuity: on an idle machine every assertion below runs
// zero times and the test prints green anyway -- so the row count goes in the
// test's NAME, where a silent 0 is legible instead of invisible. (2) A mutant that
// passes the wrong args (`--reachable` dropped, a renamed subcommand) yields a row
// count the extension cannot match; the equality is deliberately one-sided --
// `>0 probe implies >0 panes` -- because a session really can exit between the two
// calls, and a flaky test teaches people to ignore it.
const probe = require('child_process')
  .execFileSync(REAL, ['ids', '--max-age', '60', '--reachable'], { encoding: 'utf8' })
  .split('\n').filter(Boolean).length
await S.commands['claudeFleet.splitRead']()
t(`the real \`fleet ids\` still parses, with no raw id as a label (${probe} live rows)`, () => {
  assert.deepStrictEqual(S.errors, [])
  if (probe > 0) {
    assert.ok(S.terminals.length > 0,
      `fleet ids printed ${probe} rows but the extension opened no pane -- wrong args?`)
  }
  for (const x of S.terminals) {
    assert.match(x.opts.shellArgs[0], /^[0-9a-f]{8}$/, 'short id column moved')
    assert.ok(!/^[●○] [0-9a-f]{8}$/.test(x.opts.name), 'raw id leaked into a tab label: ' + x.opts.name)
    // `isAbsolute` is weaker than this test's own name: the fallback is os.homedir(),
    // which is absolute, so a moved cwd column would fall back and still pass. Measured
    // 2026-08-21: `cwd: os.homedir()` survived all 66 tests. Require a directory that
    // EXISTS and is not simply $HOME for every row (a session whose cwd is literally
    // $HOME is possible but none of yours is, and `fleet ids` would have to invent one).
    assert.ok(path.isAbsolute(x.opts.cwd), 'cwd column moved: ' + x.opts.cwd)
    assert.ok(fs.existsSync(x.opts.cwd), 'cwd column moved: ' + x.opts.cwd)
  }
})

// ---- 9. THE BUTTON ITSELF -------------------------------------------------
// A mutation that repoints the status bar at the read-only command silently undoes
// the whole feature. Measured 2026-08-21: it survived the entire suite.
reset(); S.config.fleetPath = FAKE
t('the status-bar button is wired to the WRITABLE command', () =>
  assert.strictEqual(S.status.command, 'claudeFleet.split'))
await S.commands[S.status.command]()
t('and invoking whatever the button points at opens writable panes', () => {
  assert.ok(S.terminals.length > 0)
  for (const x of S.terminals) assert.strictEqual(x.opts.shellArgs[0], 'open')
})

// ---- 10. an empty or broken roster ----------------------------------------
// Neither shape occurs on a machine that always has sessions running, so the fake
// supplies them. Without these, deleting the warning entirely was a silent no-op
// that the suite passed — also measured.
reset(); process.env.FAKE_FLEET_MODE = 'empty'; await S.commands['claudeFleet.split']()
t('an empty roster SAYS so and opens nothing', () => {
  assert.strictEqual(S.terminals.length, 0)
  assert.strictEqual(S.warnings.length, 1)
  assert.match(S.warnings[0], /no live background sessions/)
  assert.deepStrictEqual(S.errors, [])
})
reset(); await S.commands['claudeFleet.split']()          // a full fleet first...
const beforeDrain = S.terminals.length
S.disposed.length = 0
process.env.FAKE_FLEET_MODE = 'empty'
await S.commands['claudeFleet.split']()                    // ...then the fleet drains
t('a drained fleet CLEARS the panes it left behind', () => {
  assert.strictEqual(S.disposed.length, beforeDrain,
    'panes pointing at sessions that no longer exist were left on screen')
})
reset(); process.env.FAKE_FLEET_MODE = 'fail'; await S.commands['claudeFleet.split']()
t('a failing `fleet` reports the error and opens nothing', () => {
  assert.strictEqual(S.terminals.length, 0)
  assert.strictEqual(S.errors.length, 1)
  assert.match(S.errors[0], /fleet ids` failed/)
  assert.match(S.errors[0], /daemon socket is gone/, 'stderr from the tool must reach the user')
})

// ---- 11. the cost gate's boundary and the PICKER ---------------------------
reset(); S.config.confirmAbove = 8; await S.commands['claudeFleet.split']()
t('confirmAbove is a strict ceiling: exactly 8 of 8 does NOT prompt', () => {
  assert.deepStrictEqual(S.modals, [])
  assert.strictEqual(S.terminals.length, 8)
})
reset(); S.config.confirmAbove = 7; await S.commands['claudeFleet.split']()
t('...and 8 over a limit of 7 does', () => assert.strictEqual(S.modals.length, 1))
S.config.confirmAbove = 6

// The picker opens with every row pre-ticked, so one Enter is exactly as expensive
// as the button. It must meet the same gate.
reset(); S.quickPick = (items) => items; await S.commands['claudeFleet.pick']()
t('the picker offers every row pre-ticked', () => {
  assert.strictEqual(S.quickPickCalls.length, 1)
  assert.ok(S.quickPickCalls[0].items.every((i) => i.picked === true))
})
t('so selecting all 8 in the picker hits the SAME memory gate', () => {
  assert.strictEqual(S.modals.length, 1, 'the picker slipped past the writable-pane gate')
  assert.strictEqual(S.terminals.length, 0, 'dismissed, so nothing should open')
})
reset(); S.quickPick = (items) => items.slice(0, 2); await S.commands['claudeFleet.pick']()
t('a small hand-picked selection is never nagged', () => {
  assert.deepStrictEqual(S.modals, [])
  assert.strictEqual(S.terminals.length, 2)
})
S.config.confirmAbove = 0

// ---- 12. `panes` is normalised, not trusted --------------------------------
reset(); S.config.panes = 3.5; await S.commands['claudeFleet.split']()
t('a fractional `panes` never yields a group LARGER than it asked for', () => {
  const sizes = []
  for (const i of leaders()) sizes.push(S.terminals.filter((x, j) => j > i && x.opts.location).length)
  const tabs = leaders()
  for (let k = 0; k < tabs.length; k++) {
    const end = k + 1 < tabs.length ? tabs[k + 1] : S.terminals.length
    assert.ok(end - tabs[k] <= 3, `group ${k} holds ${end - tabs[k]} panes, > 3`)
  }
})
reset(); S.config.panes = 0; await S.commands['claudeFleet.split']()
t('`panes: 0` degrades to one pane per tab rather than an infinite loop', () =>
  assert.strictEqual(S.terminals.length, 8))
reset(); S.config.panes = -4; await S.commands['claudeFleet.split']()
t('a negative `panes` likewise cannot hang', () => assert.strictEqual(S.terminals.length, 8))
S.config.panes = 3

// ---- 13. the manifest agrees with the code --------------------------------
const manifest = require(process.env.EXT + '/package.json')
const props = manifest.contributes.configuration.properties
t('the manifest default group size is the three you asked for', () =>
  assert.strictEqual(props['claudeFleet.panes'].default, 3))
t('`panes` is declared an integer, so the fractional case cannot be entered', () =>
  assert.strictEqual(props['claudeFleet.panes'].type, 'integer'))
t('every command the extension registers is declared in the manifest', () => {
  const declared = new Set(manifest.contributes.commands.map((c) => c.command))
  for (const id of Object.keys(S.commands)) assert.ok(declared.has(id), `${id} is not in package.json`)
})

// ---- 14. Close beats a split that is still reading the roster --------------
reset()
const inFlight = S.commands['claudeFleet.split']()
await S.commands['claudeFleet.close']()
await inFlight
t('clicking Close while a split is in flight leaves NO panes open', () =>
  assert.strictEqual(S.terminals.length, 0,
    'a superseded split created its panes after Close had run'))

// ---- 15. the button must be VISIBLE, not merely wired ----------------------
// `show()`/`hide()` used to be indistinguishable no-ops in the stub, so a status item
// that was correctly wired and permanently invisible passed every test.
reset(); S.config.fleetPath = FAKE; await S.commands['claudeFleet.split']()
t('the status button is actually shown after a successful roster', () =>
  assert.strictEqual(S.status.visible, true))
// `close` awaits refreshStatus, which is the same path the 20s poll drives -- so this
// exercises the real catch branch rather than the command's own error handling.
reset(); process.env.FAKE_FLEET_MODE = 'fail'; S.status.visible = false
await S.commands['claudeFleet.close']()
t('...and still shown when the roster FAILS, so you can retry', () => {
  assert.strictEqual(S.status.visible, true, 'a failing fleet left you with no button')
  assert.match(String(S.status.tooltip), /daemon socket is gone/,
    'the button gives no clue why the fleet is unreadable')
})

// ---- 16. where you are left looking ----------------------------------------
reset(); await S.commands['claudeFleet.split']()
t('you land back on the FIRST group, not the last tab created', () =>
  assert.strictEqual(S.activeTerminal(), S.terminals[0]))

// ---- 17. the fixture must be bigger than any cap production might apply ----
// Every grouping assertion used exactly 8 rows, so capping the roster read at 8 was
// invisible -- on a machine that runs 11+ sessions, three would simply vanish.
reset(); process.env.FAKE_FLEET_ROWS = '13'; await S.commands['claudeFleet.split']()
t('all 13 of a 13-session fleet get a pane', () =>
  assert.strictEqual(S.terminals.length, 13))
t('...in five tabs of 3,3,3,3,1', () =>
  assert.deepStrictEqual(groupSizes(), [3, 3, 3, 3, 1]))
t('...with the tabs at 0,3,6,9,12', () =>
  assert.deepStrictEqual(leaders(), [0, 3, 6, 9, 12]))

// Roster sizes across every boundary. A loop that dropped the last row of a 1-row or
// a `panes`+1-row fleet passed the old suite outright.
for (const [n, want] of [[1, [1]], [2, [2]], [3, [3]], [4, [3, 1]], [8, [3, 3, 2]], [13, [3, 3, 3, 3, 1]]]) {
  reset(); process.env.FAKE_FLEET_ROWS = String(n)
  await S.commands['claudeFleet.split']()
  t(`a ${n}-row fleet opens ${n} panes in groups of ${want.join(',')}`, () => {
    assert.strictEqual(S.terminals.length, n, `${n} rows produced ${S.terminals.length} panes`)
    assert.deepStrictEqual(groupSizes(), want)
  })
}

reset(); S.config.panes = 12; process.env.FAKE_FLEET_ROWS = '12'
await S.commands['claudeFleet.split']()
t('the manifest maximum panes=12 is honoured exactly, not clamped below it', () => {
  assert.strictEqual(S.terminals.length, 12)
  assert.deepStrictEqual(leaders(), [0], 'a clamp to 11 would split this into two tabs')
})
S.config.panes = 3

// ---- 18. the cost modal's limiting button must actually limit ---------------
reset(); S.config.confirmAbove = 6; S.config.panes = 12
// Click whichever button is NOT "open all" -- deliberately chosen from the items the
// modal really offered, so a reworded button cannot silently mean "open everything".
S.answer = (items) => items[items.length - 1]
await S.commands['claudeFleet.split']()
t('with panes=12 over an 8-row fleet the limiting button opens FEWER than all 8', () => {
  assert.ok(S.terminals.length < 8,
    `the "just the freshest" button opened ${S.terminals.length} of 8`)
  assert.ok(S.terminals.length >= 1)
})
t('...and it never offers a number bigger than the fleet', () => {
  const just = S.modals[0].items.find((x) => /freshest/.test(x))
  assert.ok(just, 'no limiting button was offered')
  assert.strictEqual(Number(just.match(/\d+/)[0]), S.terminals.length,
    `the button said "${just}" and opened ${S.terminals.length}`)
})
S.config.panes = 3

reset(); S.answer = (items) => items.find((x) => /freshest/.test(x))
await S.commands['claudeFleet.split']()
t('the limiting button is matched by IDENTITY, so rewording it cannot open all 8', () =>
  assert.strictEqual(S.terminals.length, 3))
t('...and it opens the FRESHEST three, not the stalest', () =>
  assert.deepStrictEqual(openedShorts(), ['aaaaaaa1', 'aaaaaaa2', 'aaaaaaa3']))

reset(); S.quickPick = (items) => items; S.answer = (items) => items.find((x) => /freshest/.test(x))
await S.commands['claudeFleet.pick']()
t('the picker\'s limiting button also opens the freshest three', () =>
  assert.deepStrictEqual(openedShorts(), ['aaaaaaa1', 'aaaaaaa2', 'aaaaaaa3']))
S.config.confirmAbove = 0

// ---- 19. a stale picker must not resurrect 8 GB of panes -------------------
reset()
let releasePick
S.quickPick = (items) => new Promise((res) => { releasePick = () => res(items) })
S.answer = (items) => items[0]                       // "open all", if it ever got that far
const pickRun = S.commands['claudeFleet.pick']()
await until(() => S.quickPickCalls.length === 1, 'the quick pick to open')
await S.commands['claudeFleet.close']()              // you give up and close the view
releasePick()
await pickRun
t('a picker resolved AFTER Close opens nothing', () =>
  assert.strictEqual(S.terminals.length, 0,
    `a superseded picker opened ${S.terminals.length} writable panes after Close`))

reset(); S.quickPick = (items) => items; process.env.FAKE_FLEET_MODE = 'empty'
await S.commands['claudeFleet.split']()              // warns, opens nothing
delete process.env.FAKE_FLEET_MODE
await S.commands['claudeFleet.split']()              // a full fleet
S.disposed.length = 0
process.env.FAKE_FLEET_MODE = 'empty'
await S.commands['claudeFleet.pick']()               // the fleet drains, via the PICKER
t('a drained fleet clears the panes even when found through the picker', () =>
  assert.strictEqual(S.disposed.length, 8,
    'pick left 8 finished sessions holding ~1 GB each'))

// ---- 20. the LATEST click wins, not the fastest roster read ----------------
reset()
const slow = S.commands['claudeFleet.split']()         // 8 panes
const fast = S.commands['claudeFleet.splitFreshest']() // ...superseded by 3
await slow; await fast
t('a later splitFreshest beats an earlier full split regardless of completion order', () => {
  assert.strictEqual(S.terminals.length, 3,
    `ended with ${S.terminals.length} panes; the older, more expensive request won`)
  assert.deepStrictEqual(leaders(), [0])
})

// ---- 21. closing ONE pane must not forget the others -----------------------
reset(); await S.commands['claudeFleet.split']()
const victim = S.terminals[4]
S.closeTerminal(victim)                                // you close one pane by hand
S.disposed.length = 0
await S.commands['claudeFleet.close']()
t('closing one pane by hand leaves the other 7 still reclaimable', () => {
  assert.strictEqual(S.disposed.length, 7,
    `Close reclaimed ${S.disposed.length} of the 7 panes still open`)
  assert.ok(!S.disposed.includes(victim), 'the hand-closed pane was disposed twice')
})

reset(); await S.commands['claudeFleet.split']()
S.disposed.length = 0
ext.deactivate()
t('deactivate reclaims every pane, so a reload cannot strand 8 GB', () =>
  assert.strictEqual(S.disposed.length, 8))

// ---- 22. every command that claims to open sessions opens WRITABLE ones ----
reset(); await S.commands['claudeFleet.splitFreshest']()
t('splitFreshest opens panes you can TYPE into, not read-only tails', () => {
  assert.strictEqual(S.terminals.length, 3)
  for (const x of S.terminals) {
    assert.strictEqual(x.opts.shellPath, FAKE)
    assert.strictEqual(x.opts.shellArgs[0], 'open', 'regressed to a read-only tail')
    assert.deepStrictEqual(x.opts.shellArgs.slice(2), ['--max-age', '60'])
  }
})

// ---- 23. the pane label is the identifier that SURVIVES ---------------------
// `claude agents` takes the screen 0.19s after launch (measured) and wipes the header
// that says which row to pick. The label is what is left.
reset(); process.env.FAKE_FLEET_DUPS = '1'; await S.commands['claudeFleet.split']()
t('two panes sharing a name each carry their short id in the label', () => {
  const dup = S.terminals.filter((x) => x.opts.name.includes('same name'))
  assert.strictEqual(dup.length, 2)
  const names = dup.map((x) => x.opts.name)
  assert.notStrictEqual(names[0], names[1], 'both panes are labelled identically')
  assert.ok(names.some((n) => n.includes('aaaaaaa2')) && names.some((n) => n.includes('aaaaaaa3')))
})
t('...while the unambiguous panes stay clean', () => {
  const solo = S.terminals.find((x) => x.opts.name.includes('one blocked'))
  assert.ok(solo && !/aaaaaaa/.test(solo.opts.name), `label was "${solo && solo.opts.name}"`)
})

// ---- 24. the pane OPTIONS that only matter on the next reload ---------------
// Three mutations that survived all 66 tests when measured on 2026-08-21. None of
// them changes anything you can see on the day; each changes what happens next time.
reset(); S.config.fleetPath = FAKE; S.config.confirmAbove = 0
await S.commands['claudeFleet.split']()
t('every pane is TRANSIENT, so a window reload cannot restore 8 GB of claude', () => {
  assert.strictEqual(S.terminals.length, 8, 'nothing opened: the loop below would check nothing')
  // VS Code restores non-transient terminals on reload, relaunching each shellPath.
  // With 8 writable panes that is eight `claude` processes at startup -- the exact
  // way this machine lost VS Code and seven sessions on 2026-08-21.
  for (const x of S.terminals) assert.strictEqual(x.opts.isTransient, true, x.opts.name)
})
t('each pane starts in ITS OWN session directory, not a fallback', () => {
  const shorts = openedShorts()
  assert.strictEqual(shorts.length, 8)
  // The fake roster puts rows 1-2 in your_other_project and the rest in $HOME, so a
  // blanket `cwd: os.homedir()` (which survived the suite) differs on rows 1-2.
  assert.ok(S.terminals.slice(0, 2).every((x) => x.opts.cwd !== require('os').homedir()),
    'panes fell back to $HOME instead of the row cwd')
})
t('a blocked session is iconed differently from a working one', () => {
  // The icon is how you spot, at a glance down a tab strip, which pane wants a reply.
  const icons = S.terminals.map((x) => x.opts.iconPath && x.opts.iconPath.id)
  assert.ok(icons.every(Boolean), 'a pane has no icon at all: ' + JSON.stringify(icons))
  assert.strictEqual(new Set(icons).size, 2, 'blocked and working share an icon: ' + icons)
})

// ---- 25. watch / write ------------------------------------------------------
reset(); await S.commands['claudeFleet.watch']()
t('watch opens ONE terminal with no args', () => {
  assert.strictEqual(S.terminals.length, 1)
  assert.strictEqual(S.terminals[0].opts.shellArgs, undefined)
})
reset(); await S.commands['claudeFleet.write']()
t('write opens `fleet write` and is NOT transient', () => {
  assert.deepStrictEqual(S.terminals[0].opts.shellArgs, ['write'])
  // Falsy, not merely !== true: VS Code treats ANY truthy value as on.
  assert.ok(!S.terminals[0].opts.isTransient)
})


// ---- 26. round-3 lens findings ---------------------------------------------
// Everything here pins something that was TRUE of the code and INVISIBLE to the
// suite: three mutants (isTransient on watch, the label's ambiguity source, the
// open cutoff) survived all 69 tests when measured on 2026-08-21.

// (a) TRANSIENT is a property of every pane the extension opens, not just the
// button's. VS Code relaunches a non-transient terminal's shellPath on window
// reload; eight writable panes is eight `claude` processes at startup, which is
// how this machine lost VS Code and seven sessions once already. Group 24 asserted
// it for `split` alone, so `isTransient: false` on the WATCH terminal survived.
for (const cmd of ['split', 'splitFreshest', 'splitRead', 'watch']) {
  reset(); S.config.fleetPath = FAKE; S.config.confirmAbove = 0
  await S.commands['claudeFleet.' + cmd]()
  t(`${cmd}: every pane is TRANSIENT, so a reload cannot relaunch it`, () => {
    assert.ok(S.terminals.length > 0, cmd + ' opened nothing')
    for (const x of S.terminals) assert.strictEqual(x.opts.isTransient, true, x.opts.name)
  })
  t(`${cmd}: names its executable by absolute path, and inherits the environment`, () => {
    assert.ok(S.terminals.length > 0, cmd + ' opened nothing: the loop below would check nothing')
    for (const x of S.terminals) {
      assert.strictEqual(x.opts.shellPath, FAKE)
      assert.ok(path.isAbsolute(x.opts.shellPath), 'relative shellPath: ' + x.opts.shellPath)
      // VS Code's `strictEnv` hands the child an EMPTY environment. `fleet` resolves
      // $HOME to find the jobs directory and the daemon roster, so a pane opened with
      // strictEnv would paint an empty fleet and look like a dead daemon.
      assert.ok(!x.opts.strictEnv, 'strictEnv would empty $HOME (any truthy value turns it on)')
    }
  })
}
// `write` is the one deliberate exception to transience: it is YOUR pane, and a
// reload relaunching a picker you were typing into is a feature, not 1 GB of Claude.
reset(); await S.commands['claudeFleet.write']()
t('write is the ONE non-transient pane, and that is a decision, not an omission', () => {
  assert.strictEqual(S.terminals[0].opts.shellPath, FAKE)
  assert.ok(!S.terminals[0].opts.isTransient)
  assert.ok(!S.terminals[0].opts.strictEnv)
})

// (b) the open cutoff in the argv is YOUR setting, not a constant that happens to
// match the default. Both sides read one resolver, so they cannot drift.
reset(); S.config.maxAgeMinutes = 4320; S.config.confirmAbove = 0
await S.commands['claudeFleet.split']()
t('the --max-age in each pane argv follows maxAgeMinutes', () =>
  assert.deepStrictEqual(S.terminals[0].opts.shellArgs.slice(2), ['--max-age', '4320']))
reset(); S.config.maxAgeMinutes = 0        // nonsense value: fall back, never emit 0
await S.commands['claudeFleet.split']()
t('...and a nonsense cutoff falls back rather than emitting `--max-age 0`', () =>
  assert.deepStrictEqual(S.terminals[0].opts.shellArgs.slice(2), ['--max-age', '60']))
S.config.maxAgeMinutes = 60

// (c) the short id is added to a label because the SESSION is ambiguous, not
// because the opened SLICE is. splitFreshest opens rows 1-2 of eight; rows 2 and 3
// share a name, so row 2's pane must still say which one it is even though its
// twin is not on screen -- that is the whole point of a durable identifier.
reset(); S.config.panes = 2; process.env.FAKE_FLEET_DUPS = '1'
await S.commands['claudeFleet.splitFreshest']()
t('a name shared with a session OUTSIDE the opened slice still gets the short id', () => {
  assert.strictEqual(S.terminals.length, 2)
  const dup = S.terminals[1]
  assert.match(dup.opts.name, /same name · aaaaaaa2$/,
    'label computed over the slice, not the roster: ' + dup.opts.name)
})
S.config.panes = 3

// (d) the JOIN: the argv this extension emits is argv the REAL script accepts.
// The two halves were tested separately -- the stub records opts, the pty suite runs
// `fleet open` -- and nothing asserted they were the same shape, so a renamed
// subcommand would have passed both. Run it with pipes for stdio so the real
// script's own TTY guard stops it before it can exec `claude agents`: a test must
// never be one inherited terminal away from opening a real session.
reset(); S.config.fleetPath = FAKE; await S.commands['claudeFleet.split']()
const emitted = S.terminals[0].opts.shellArgs
t('the real `fleet` accepts the argv the extension emits', () => {
  let out = ''
  try {
    require('child_process').execFileSync(REAL, emitted,
      { stdio: ['pipe', 'pipe', 'pipe'], encoding: 'utf8' })
    assert.fail('fleet open ran to completion without a TTY -- the guard is gone')
  } catch (e) {
    out = String((e.stderr || '') + (e.stdout || ''))
  }
  assert.match(out, /needs a real terminal/, 'argv rejected before the TTY guard: ' + out)
  assert.doesNotMatch(out, /usage:|unknown argument/, 'the real script rejected this argv: ' + out)
})

// ---- 27. round-4 lens findings ---------------------------------------------
// Thirteen mutants survived the 82-test suite when measured on 2026-08-21 (the
// ledger is .review-rounds/2026-08-21-claude-fleet/ROUND-4-DISPOSITIONS.md in
// your_other_project). Each test here kills at least one of them; the fleet-side
// three live in fleet-open-pty.py.

// (a) the cutoff is normalised ONCE, and the SAME whole number reaches the
// roster read and every pane's argv. maxAgeMinutes is user-typed JSON: the
// manifest says integer, but settings.json enforces nothing, and a fractional
// or garbage value used to reach `fleet ids` verbatim -- which kills the roster
// (or, before the digit guard, admitted every row while every PANE then died).
const argvLog = path.join(require('os').tmpdir(), 'fleet-argv-' + process.pid)
let fracArgv = null
for (const [val, want] of [[1.5, '1'], [0.5, '60'], [4320.7, '4320'], [1e21, '525600'],
                           ['7', '7'], [NaN, '60'], [-3, '60'], ['abc', '60'],
                           [525600, '525600'], [525601, '525600']]) {
  reset(); S.config.fleetPath = FAKE; S.config.confirmAbove = 0; S.config.panes = 3
  S.config.maxAgeMinutes = val
  fs.writeFileSync(argvLog, '')
  process.env.FAKE_FLEET_ARGV = argvLog
  await S.commands['claudeFleet.split']()
  delete process.env.FAKE_FLEET_ARGV
  t(`maxAgeMinutes=${String(val)} reaches the roster AND the panes as --max-age ${want}`, () => {
    const calls = fs.readFileSync(argvLog, 'utf8').trim().split('\n')
    const idsArgv = calls[calls.length - 1].split(' ')
    const rosterCut = idsArgv[idsArgv.indexOf('--max-age') + 1]
    assert.strictEqual(rosterCut, want, `fleet ids was asked with --max-age ${rosterCut}`)
    assert.match(rosterCut, /^[1-9][0-9]*$/, 'a non-digit cutoff kills the roster read')
    assert.ok(S.terminals.length > 0, 'no pane opened, so the pane half proves nothing')
    for (const x of S.terminals)
      assert.deepStrictEqual(x.opts.shellArgs.slice(2), ['--max-age', want])
  })
  if (val === 1.5 && S.terminals[0]) fracArgv = S.terminals[0].opts.shellArgs
}
S.config.maxAgeMinutes = 60
t('the argv a FRACTIONAL setting produces is argv the REAL script accepts', () => {
  // Group 26(d) joins the two halves at the default; this joins them at the exact
  // value that used to fall through: 1.5 listed every row and killed every pane.
  assert.ok(fracArgv, 'the 1.5 case opened no pane')
  let out = ''
  try {
    require('child_process').execFileSync(REAL, fracArgv,
      { stdio: ['pipe', 'pipe', 'pipe'], encoding: 'utf8' })
    assert.fail('fleet open ran to completion without a TTY -- the guard is gone')
  } catch (e) { out = String((e.stderr || '') + (e.stdout || '')) }
  assert.match(out, /needs a real terminal/, 'rejected before the TTY guard: ' + out)
  assert.doesNotMatch(out, /whole number/, 'the emitted cutoff is still fractional: ' + out)
})
t('the manifest agrees with the code: integer, and maximum IS the clamp', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(process.env.EXT, 'package.json'), 'utf8'))
  const prop = manifest.contributes.configuration.properties['claudeFleet.maxAgeMinutes']
  assert.strictEqual(prop.type, 'integer')
  assert.strictEqual(prop.minimum, 1)
  // 525600 == MAX_AGE in extension.js; the 1e21 row above proves the code clamps
  // to this same number, so the two cannot drift without one side failing.
  assert.strictEqual(prop.maximum, 525600)
})

// (b) the cutoff is resolved ONCE PER COMMAND, not once per read. A setting
// changed while the picker sits open (settings.json is a text file; you edit it)
// must not split the roster's cutoff from the panes'.
reset(); S.config.maxAgeMinutes = 4320
fs.writeFileSync(argvLog, '')
process.env.FAKE_FLEET_ARGV = argvLog
S.quickPick = (items) => { S.config.maxAgeMinutes = 60; return items.slice(0, 2) }
await S.commands['claudeFleet.pick']()
delete process.env.FAKE_FLEET_ARGV
t('a setting changed while the picker is open cannot split roster from panes', () => {
  const calls = fs.readFileSync(argvLog, 'utf8').trim().split('\n')
  const idsArgv = calls[calls.length - 1].split(' ')
  assert.strictEqual(idsArgv[idsArgv.indexOf('--max-age') + 1], '4320')
  assert.strictEqual(S.terminals.length, 2)
  for (const x of S.terminals)
    assert.deepStrictEqual(x.opts.shellArgs.slice(2), ['--max-age', '4320'],
      'the pane re-read the setting the roster was NOT filtered with')
})
S.config.maxAgeMinutes = 60

// (c) an EMPTY fleetPath auto-detects the real script -- which is how YOUR
// settings run it. Group 7 covers a wrong path; nothing covered the default
// resolver, so a candidate walk returning the wrong binary survived.
reset(); S.config.fleetPath = ''
await S.commands['claudeFleet.splitRead']()
t('an empty fleetPath resolves to the real script, and the roster read works', () => {
  assert.deepStrictEqual(S.errors, [], 'the resolver picked something that is not fleet')
  // This one drives the LIVE roster, so on a machine with no background sessions
  // the loop below runs zero times -- which is how a resolver returning the wrong
  // binary survived. 28(d) pins the resolver deterministically; what this test can
  // still demand is a DEFINITE outcome, so a run that checked nothing FAILS.
  assert.ok(S.terminals.length > 0 || S.warnings.length > 0,
    'neither panes nor a drained-fleet warning: this test checked nothing')
  for (const x of S.terminals)
    assert.strictEqual(x.opts.shellPath, REAL, 'resolved to ' + x.opts.shellPath)
})
S.config.fleetPath = FAKE

// (d) every pane is wired to ITS OWN session: the full ordered roster->argv
// mapping, at both fixture sizes. Counting panes and spot-checking pane 0 let a
// mutant that routed panes 4..n to row 1's session keep all 82 tests green --
// eight tabs all replying to the same Claude.
for (const n of [8, 13]) {
  reset(); process.env.FAKE_FLEET_ROWS = String(n)
  await S.commands['claudeFleet.split']()
  t(`every one of ${n} panes runs ITS OWN session, in roster order`, () => {
    assert.deepStrictEqual(openedShorts(),
      Array.from({ length: n }, (_, k) => 'aaaaaaa' + (k + 1)))
    const words = 'one two three four five six seven eight nine ten eleven twelve thirteen'.split(' ')
    for (let k = 0; k < n; k++)
      assert.strictEqual(S.terminals[k].opts.name.split(' ')[1], words[k],
        `pane ${k} is labelled "${S.terminals[k].opts.name}" but runs ${S.terminals[k].opts.shellArgs[1]}`)
  })
}

// (e) parentage at panes values OTHER than 3. Group 1 pins it at the default,
// so `per === 3 ? parent : firstLeader` -- every later tab's panes splitting off
// tab 1 -- survived. The discriminating shape is a SECOND group with >= 2 panes.
for (const per of [2, 4]) {
  reset(); S.config.panes = per
  await S.commands['claudeFleet.split']()
  t(`panes=${per}: every pane is parented to ITS OWN group leader`, () => {
    assert.strictEqual(S.terminals.length, 8)
    for (let i = 0; i < S.terminals.length; i++) {
      if (i % per === 0) { assert.strictEqual(S.terminals[i].opts.location, undefined, `pane ${i} should lead a tab`); continue }
      assert.strictEqual(S.terminals[i].opts.location.parentTerminal, S.terminals[Math.floor(i / per) * per],
        `pane ${i} split off the wrong tab at panes=${per}`)
    }
  })
}
S.config.panes = 3

// (f) the duplicate-name count is taken over the WHOLE roster, including its
// last row. Group 26(c)'s twins sit mid-roster, so a count that dropped the
// tail (`.slice(0, -1)`) was invisible.
reset(); S.config.panes = 2; process.env.FAKE_FLEET_DUPS = 'edge'
await S.commands['claudeFleet.splitFreshest']()
t('a twin in the LAST roster row still forces the short id onto the pane label', () => {
  assert.strictEqual(S.terminals.length, 2)
  assert.match(S.terminals[0].opts.name, /same name · aaaaaaa1$/,
    'the duplicate count dropped the roster tail: ' + S.terminals[0].opts.name)
})
S.config.panes = 3

// (g) LIFE-01: panes opened via the PICKER are in the registry Close reclaims.
// A pick that created panes and then dropped the registry left them orphaned --
// Close and the next split would silently stop reaching them.
reset(); S.quickPick = (items) => items.slice(0, 3)
await S.commands['claudeFleet.pick']()
S.disposed.length = 0
await S.commands['claudeFleet.close']()
t('Close reclaims panes that came from the PICKER, not only the button\'s', () =>
  assert.strictEqual(S.disposed.length, 3, 'picker panes were left outside the registry'))

// (h) LIFE-02: deactivate does not just dispose -- it INVALIDATES. A picker you
// left open across a window reload resolves after deactivate ran; if deactivate
// swept the registry without bumping the generation, that resolution would
// create panes nothing tracks anymore.
reset()
let releaseLatePick
S.quickPick = (items) => new Promise((res) => { releaseLatePick = () => res(items) })
const pendingLatePick = S.commands['claudeFleet.pick']()
await until(() => S.quickPickCalls.length === 1, 'the quick pick to open')
ext.deactivate()               // the reload begins while your picker is still up
releaseLatePick()
await pendingLatePick
t('a picker resolved AFTER deactivate creates NOTHING', () =>
  assert.strictEqual(S.terminals.length, 0,
    `deactivate ran, then the picker still opened ${S.terminals.length} panes`))

// (i) LIFE-03: the LATER command wins regardless of which roster read finishes
// first, for command pairs beyond split-then-splitFreshest (the one group 20
// covers). FAKE_FLEET_SLEEP makes the earlier read finish FIRST deterministically.
reset()
const earlyFreshest = S.commands['claudeFleet.splitFreshest']()   // fast read, spawned now
process.env.FAKE_FLEET_SLEEP = '0.3'
const lateFull = S.commands['claudeFleet.split']()                // slow read, later click
delete process.env.FAKE_FLEET_SLEEP
await earlyFreshest; await lateFull
t('a later FULL split beats an earlier splitFreshest even when it finishes LAST', () => {
  assert.strictEqual(S.terminals.length, 8, `ended with ${S.terminals.length} panes`)
  assert.deepStrictEqual(leaders(), [0, 3, 6])
})
reset()
const earlyWrite = S.commands['claudeFleet.split']()
process.env.FAKE_FLEET_SLEEP = '0.3'
const lateRead = S.commands['claudeFleet.splitRead']()
delete process.env.FAKE_FLEET_SLEEP
await earlyWrite; await lateRead
t('a later READ-ONLY split beats an earlier writable one the same way', () => {
  assert.strictEqual(S.terminals.length, 8)
  for (const x of S.terminals)
    assert.notStrictEqual(x.opts.shellArgs[0], 'open', 'the older WRITABLE request won')
})

// (j) LIFE-04: your reply pane stays OUT of the managed registry for its whole
// life. Group 25 pins what write opens; nothing pinned that Close, a later
// replacement round and deactivate all leave it alone.
reset(); await S.commands['claudeFleet.write']()
const herPane = S.terminals[0]
S.disposed.length = 0
await S.commands['claudeFleet.close']()
await S.commands['claudeFleet.split']()
ext.deactivate()
t('Close, a replacement round and deactivate all leave YOUR reply pane alone', () =>
  assert.ok(!S.disposed.includes(herPane), 'the reply pane you were typing into was killed'))

// (k) LIFE-05: the watch terminal is IN the registry -- it runs a real `fleet`
// process, and one that neither a second watch nor Close reclaims is a leak
// that outlives the window.
reset(); await S.commands['claudeFleet.watch']()
const firstWatch = S.terminals[0]
await S.commands['claudeFleet.watch']()
t('a second watch REPLACES the first (its process is reclaimed)', () =>
  assert.ok(S.disposed.includes(firstWatch), 'the first watch terminal leaked'))
S.disposed.length = 0
await S.commands['claudeFleet.close']()
t('...and Close reclaims the watch terminal too', () =>
  assert.strictEqual(S.disposed.length, 1))

// ---- 28. round-5 lens findings ---------------------------------------------
// Every item here kills a mutation that survived all 108 tests when measured on
// 2026-08-21, and names the mutant it kills.

// (a) the PICKER RESERVES its generation token (`++generation`); it does not merely
// read it. A pick that only read the token left an EARLIER click's slow roster read
// still believing it was current: the eight-pane split you had replaced opened
// anyway, and was then closed under your by the two-pane pick that should have
// superseded it before it ever reached the screen.
// MUTANT: `const at = generation` in claudeFleet.pick.
reset()
// `reset()` clears the STUB; the extension's own pane registry survives it, so the
// next splitInto would dispose the previous test's panes and `S.disposed` would be
// non-empty before this test acted. Close first, then start counting.
await S.commands['claudeFleet.close']()
S.disposed.length = 0
process.env.FAKE_FLEET_SLEEP = '0.3'
const slowSplit = S.commands['claudeFleet.split']()          // clicked first, reads slowly
delete process.env.FAKE_FLEET_SLEEP
let releaseR5Pick
S.quickPick = (items) => new Promise((res) => { releaseR5Pick = () => res(items.slice(0, 2)) })
const laterPick = S.commands['claudeFleet.pick']()           // clicked second: it wins
await until(() => S.quickPickCalls.length === 1, 'the quick pick to open')
await slowSplit                                              // the superseded roster lands
releaseR5Pick()
await laterPick
t('a pick RESERVES its token, so an earlier slow split cannot still open', () => {
  assert.strictEqual(S.terminals.length, 2,
    `${S.terminals.length} panes: the superseded split opened too`)
  assert.deepStrictEqual(S.disposed, [], 'panes were opened and then closed under your')
  assert.deepStrictEqual(openedShorts(), ['aaaaaaa1', 'aaaaaaa2'])
})

// (b) a superseded split that comes back to an EMPTY fleet must not close the panes
// a LATER command has already opened. Unguarded, the drained-fleet warning takes
// live panes with it -- and `closeCreated()` bumps the generation, so a command
// that ended in a warning would go on to supersede the next click as well.
// MUTANT: unconditional `closeCreated()` in doSplit's empty-roster branch.
reset()
// `reset()` clears the STUB; the extension's own pane registry survives it, so the
// next splitInto would dispose the previous test's panes and `S.disposed` would be
// non-empty before this test acted. Close first, then start counting.
await S.commands['claudeFleet.close']()
S.disposed.length = 0
process.env.FAKE_FLEET_MODE = 'empty'; process.env.FAKE_FLEET_SLEEP = '0.3'
const drainedSplit = S.commands['claudeFleet.split']()       // slow, and finds nothing
delete process.env.FAKE_FLEET_MODE; delete process.env.FAKE_FLEET_SLEEP
await S.commands['claudeFleet.splitRead']()                  // later, and finds eight
await drainedSplit
t('a superseded EMPTY roster leaves the later command\'s panes alone', () => {
  assert.strictEqual(S.terminals.length, 8, 'the later split did not open')
  assert.deepStrictEqual(S.disposed, [], 'the drained-fleet warning closed live panes')
  assert.strictEqual(S.warnings.length, 1, 'the drained fleet must still be reported')
})

// (c) the same guard on the PICKER's empty-roster branch, which is a separate site.
// MUTANT: unconditional `closeCreated()` in claudeFleet.pick's empty branch.
reset()
// `reset()` clears the STUB; the extension's own pane registry survives it, so the
// next splitInto would dispose the previous test's panes and `S.disposed` would be
// non-empty before this test acted. Close first, then start counting.
await S.commands['claudeFleet.close']()
S.disposed.length = 0
process.env.FAKE_FLEET_MODE = 'empty'; process.env.FAKE_FLEET_SLEEP = '0.3'
const drainedPick = S.commands['claudeFleet.pick']()
delete process.env.FAKE_FLEET_MODE; delete process.env.FAKE_FLEET_SLEEP
await S.commands['claudeFleet.splitRead']()
await drainedPick
t('a superseded pick that finds an EMPTY fleet closes nothing either', () => {
  assert.strictEqual(S.terminals.length, 8)
  assert.deepStrictEqual(S.disposed, [], 'the empty-roster pick closed live panes')
  assert.strictEqual(S.quickPickCalls.length, 0, 'an empty roster must not open a picker')
})

// (d) the DEFAULT fleet path resolves to the real script. 27(c) drives the same
// resolver through splitRead, whose panes only exist if this machine happens to be
// running background sessions -- on a quiet box its loop runs zero times, which is
// how a candidate walk returning the wrong binary survived. `watch` and `write`
// create their terminal unconditionally and read no roster at all, so they see the
// resolver on every run, on any machine.
// MUTANT: the CANDIDATES walk returning anything other than the executable it found.
for (const cmd of ['watch', 'write']) {
  reset(); S.config.fleetPath = ''
  await S.commands['claudeFleet.' + cmd]()
  t(`${cmd} with no configured path resolves to the real fleet script`, () => {
    assert.strictEqual(S.terminals.length, 1, cmd + ' opened nothing to check')
    assert.strictEqual(S.terminals[0].opts.shellPath, REAL,
      'resolved to ' + S.terminals[0].opts.shellPath)
    assert.deepStrictEqual(S.errors, [])
  })
}
S.config.fleetPath = FAKE

// (e) panes opened from the PICKER are grouped by the `panes` SETTING, not by how
// many rows you ticked. Every earlier picker test ticks two rows, which is one tab
// either way, so handing the pick's own count in as the group size survived: eight
// ticks became a single tab of eight panes, each a hand's width wide.
// MUTANT: `splitInto(..., picked.length, ...)` instead of `per`.
reset(); S.quickPick = (items) => items
await S.commands['claudeFleet.pick']()
t('eight PICKED sessions are grouped by `panes`, not into one tab of eight', () => {
  assert.strictEqual(S.terminals.length, 8)
  assert.deepStrictEqual(leaders(), [0, 3, 6])
  assert.deepStrictEqual(groupSizes(), [3, 3, 2])
})
// Round 6: the same case at a size that is not 8. Every picker assertion in this file
// ran against the default eight-row fleet, and 8 is the number a plausible cap would
// be written at -- `picked.slice(0, 8)`, `Math.min(picked.length, 8)` -- so a cap that
// silently dropped your ticks was indistinguishable from no cap at all. It also gives
// the grouping a FOURTH tab and a remainder of 1 rather than 2: [3,3,3,3,1] and
// [3,3,2] disagree about the last group, so a `slice` off by one is visible here too.
// MUTANT: `picked.slice(0, 8)` before the split.
reset(); process.env.FAKE_FLEET_ROWS = '13'; S.quickPick = (items) => items
await S.commands['claudeFleet.pick']()
t('...and THIRTEEN picked sessions all open, none quietly dropped', () => {
  assert.strictEqual(S.terminals.length, 13)
  assert.deepStrictEqual(openedShorts(),
    Array.from({ length: 13 }, (_, k) => 'aaaaaaa' + (k + 1)))
  assert.deepStrictEqual(leaders(), [0, 3, 6, 9, 12])
  assert.deepStrictEqual(groupSizes(), [3, 3, 3, 3, 1])
})

// (f) the panes are the rows you TICKED, in the order the picker returned them --
// never the first N of the roster. Every earlier picker test picks a LEADING slice,
// which makes those two indistinguishable, so opening the roster prefix instead of
// the selection survived: untick the noisy sessions and they open regardless.
// MUTANT: `rows.slice(0, keep)` in place of the picked rows.
reset(); S.quickPick = (items) => [items[4], items[1]]
await S.commands['claudeFleet.pick']()
t('the panes are the sessions you TICKED, in your order, not the roster prefix', () => {
  assert.deepStrictEqual(openedShorts(), ['aaaaaaa5', 'aaaaaaa2'])
  assert.strictEqual(S.terminals[0].opts.name.split(' ')[1], 'five',
    'pane 0 is labelled ' + S.terminals[0].opts.name)
})

// (g) `--reachable` FILTERS the roster; it is not decoration. Every fixture row used
// to carry a live socket, so a roster asked WITH the flag and one asked without it
// returned the same eight rows -- the flag was pinned by its own argv and by nothing
// else. A pane on an unreachable session is a terminal opening onto a dead socket.
// MUTANT: `if (!reachableOnly) args.push('--reachable')`.
reset(); process.env.FAKE_FLEET_UNREACH = '2,5'
await S.commands['claudeFleet.split']()
t('reachableOnly=true keeps socketless sessions OUT of the panes', () => {
  assert.deepStrictEqual(openedShorts(),
    ['aaaaaaa1', 'aaaaaaa3', 'aaaaaaa4', 'aaaaaaa6', 'aaaaaaa7', 'aaaaaaa8'])
})
// Round 6: thirteen rows, four of them socketless, asserted as the COMPLETE ordered
// list. A count of 8 against an eight-row fleet is satisfied by any implementation
// that opens eight of something -- the roster prefix, a capped slice, the reachable
// six padded back out -- and `includes('aaaaaaa5')` only says one particular row
// survived. Naming every row in order says which sessions opened AND in what order,
// and 13 is past the size a cap would be written at.
// MUTANT: `rows.slice(0, 8)`, or dropping the unreachable rows anyway.
reset(); process.env.FAKE_FLEET_ROWS = '13'
process.env.FAKE_FLEET_UNREACH = '2,5,9,12'; S.config.reachableOnly = false
await S.commands['claudeFleet.split']()
t('...and reachableOnly=false opens every session, socket or not', () => {
  assert.deepStrictEqual(openedShorts(),
    Array.from({ length: 13 }, (_, k) => 'aaaaaaa' + (k + 1)))
})
S.config.reachableOnly = true

// (h) every READ pane tails ITS OWN session. 27(d) pins that mapping for the
// writable arm; the read arm builds a different argv and had only its first pane
// spot-checked, so routing every tail to row 1 survived -- eight tabs showing one
// session's log, which reads as "they are all doing the same thing".
// MUTANT: `mode === 'read' ? [rows[0].short, '--back', '14'] : ...`.
for (const n of [8, 13]) {
  reset(); process.env.FAKE_FLEET_ROWS = String(n)
  await S.commands['claudeFleet.splitRead']()
  t(`every one of ${n} READ panes tails its own session`, () => {
    assert.deepStrictEqual(openedShorts(),
      Array.from({ length: n }, (_, k) => 'aaaaaaa' + (k + 1)))
    for (const x of S.terminals)
      assert.deepStrictEqual(x.opts.shellArgs.slice(1), ['--back', '14'])
  })
}

console.log(`\n  ${pass} passed, ${fail} failed`)
ext.deactivate()
process.exit(fail ? 1 : 0)
}
main()
