#!/usr/bin/env node
/**
 * Keep a project's memory store on its default branch, at SessionStart.
 *
 * WHY THIS EXISTS. Claude Code reads a project's memory from
 * `<config-root>/projects/<project>/memory`. When that path is a symlink into a git checkout that
 * TRACKS the notes, two things must hold for the store to stay one store: a note merged to the
 * default branch must reach the checkout the link points at, and a note written through the link
 * must be visible as not-yet-merged. A shared working checkout satisfies neither — it sits on
 * whatever branch its last user left it on, often far behind — and one project's store diverged
 * from its default branch twice in one week that way.
 *
 * So a store is a DEDICATED clone on the default branch, marked with
 * `git config claude.memoryStore true`, and this hook moves it forward.
 *
 * WHAT IT DOES, per opted-in store (every other repository is ignored, so a shared checkout is
 * never pulled):
 *   1. At most once per THROTTLE_MS, and by one session at a time (a lock file in the git dir),
 *      fetch the upstream branch into its remote-tracking ref with an explicit refspec, so a
 *      deleted tracking ref is recreated instead of blocking every later run.
 *   2. Plan the fast-forward with `planRefresh`, a pure function of the incoming changes and the
 *      working-tree changes. A working file whose bytes already equal the incoming version is
 *      ADOPTED — staged as it is — so a note that was written here and then merged through a pull
 *      request does not block the pull. Staging never removes or rewrites a byte a concurrently
 *      running session might be writing, which deleting the "duplicate" would.
 *   3. Anything else that overlaps, an unmerged path, or a local commit REFUSES the fast-forward.
 *   4. Report, for the store that shares a remote with the session's own repository only: a
 *      refusal or a failed git step (kept and re-reported every session until the next attempt
 *      clears it) and, as information, the notes older than UNSYNCED_MIN_AGE_MS that are new,
 *      edited or deleted here relative to the upstream branch.
 *
 * DESIGN CONSTRAINTS, all deliberate:
 *   - FAIL OPEN. The hook always exits 0 and never blocks a session. A git failure inside a store
 *     (a held index.lock, an unreachable remote, a corrupt repository) is RECORDED and reported,
 *     because a store that silently stops moving is the defect this hook exists to prevent.
 *   - A store must be on a local branch whose upstream is the SAME branch name on a real remote;
 *     a detached HEAD, a branch with no upstream, or one following another branch is refused and
 *     reported with the command that repairs that case.
 *   - OPT-IN. Only a repository whose LOCAL config sets `claude.memoryStore` is touched.
 *   - GENERIC. Nothing here names a project.
 *
 * Test hooks (environment): MEMORY_STORE_CONFIG_ROOTS (colon-separated config roots, default every
 * `~/.claude*` directory), MEMORY_STORE_THROTTLE_MS (default 600000), MEMORY_STORE_UNSYNCED_AGE_MS
 * (default 3600000).
 */
import { execFileSync } from 'node:child_process'
import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const CHILD_TIMEOUT_MS = 8000
const THROTTLE_MS = Number(process.env.MEMORY_STORE_THROTTLE_MS ?? 10 * 60 * 1000)
// Longer than any run can take (a handful of git calls, each capped at CHILD_TIMEOUT_MS), so a
// lock this old was left by a killed run.
const LOCK_STALE_MS = 2 * 60 * 1000
const LIST_LIMIT = 8
// A note younger than this is probably still being written by a live session, so it is not listed.
const UNSYNCED_MIN_AGE_MS = Number(process.env.MEMORY_STORE_UNSYNCED_AGE_MS ?? 60 * 60 * 1000)
// Bumped whenever the report's shape changes, so a record written by an older hook is ignored.
const REPORT_VERSION = 2

/**
 * The pure decision.
 * @param {Map<string, {status: 'A'|'M'|'D', blob: string|null}>} incoming  upstream vs HEAD
 * @param {Array<{path: string, xy: string, blob: string|null}>} dirty  working-tree changes;
 *        `blob` is the working file's blob id, or null when the file is absent
 * @param {boolean} ancestor  whether HEAD is an ancestor of the upstream
 */
export function planRefresh(incoming, dirty, ancestor) {
  const entry = ({ path, xy }) => ({ path, xy })
  if (!ancestor) return { action: 'refuse', reason: 'local-commits', adopt: [], conflicts: [], unsynced: dirty.map(entry) }
  const adopt = []
  const conflicts = []
  const unsynced = []
  for (const d of dirty) {
    if (/U/.test(d.xy) || d.xy === 'AA' || d.xy === 'DD') { conflicts.push(d.path); continue }
    const inc = incoming.get(d.path)
    if (!inc) { unsynced.push(entry(d)); continue }
    const same = inc.status === 'D' ? d.blob === null : d.blob !== null && d.blob === inc.blob
    if (same) adopt.push(d.path)
    else conflicts.push(d.path)
  }
  if (conflicts.length > 0) return { action: 'refuse', reason: 'conflicts', adopt: [], conflicts, unsynced }
  return { action: incoming.size > 0 ? 'ff' : 'up-to-date', reason: null, adopt, conflicts, unsynced }
}

/**
 * The environment every git child gets. Repository-selecting variables are removed so `cwd` alone
 * decides the repository, and paths are literal so an adopted `n[1].md` cannot stage `n1.md`.
 */
export function childEnv(base = process.env) {
  const env = { ...base, GIT_TERMINAL_PROMPT: '0', GIT_LITERAL_PATHSPECS: '1' }
  for (const k of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_COMMON_DIR', 'GIT_NAMESPACE', 'GIT_CEILING_DIRECTORIES', 'GIT_CONFIG']) delete env[k]
  return env
}
const CHILD_ENV = childEnv()

/**
 * The environment for a fetch: ssh in batch mode, so an unknown host key or a passphrase fails
 * instead of prompting on the user's terminal (GIT_TERMINAL_PROMPT alone does not prevent that,
 * because ssh opens /dev/tty itself). GIT_SSH_COMMAND outranks the repository's core.sshCommand,
 * so the configured command is carried into it; a caller's own GIT_SSH or GIT_SSH_COMMAND is left
 * exactly as it is.
 */
export function sshEnv(env, configured) {
  if (env.GIT_SSH || env.GIT_SSH_COMMAND) return env
  return { ...env, GIT_SSH_COMMAND: `${configured || 'ssh'} -o BatchMode=yes -o ConnectTimeout=5` }
}

function git(args, cwd, env = CHILD_ENV) {
  return execFileSync('git', args, {
    cwd, encoding: 'utf8', timeout: CHILD_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'pipe'], env,
  })
}

function quietly(fn, fallback = null) {
  try { return fn() } catch { return fallback }
}

/** A path as one shell word. */
function sq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`
}

/**
 * A remote URL reduced to host and path, so the spellings git accepts for one repository compare
 * equal: `git@host:o/r.git`, `ssh://git@host:22/o/r`, `https://host/o/r/`, `/p/r.git`, `file:///p/r`.
 */
export function normalizeRemote(url) {
  let u = String(url).trim().replace(/^[a-z][a-z0-9+.-]*:\/\//i, '')
  u = u.replace(/^[^@/]+@/, '')
  if (!u.startsWith('/')) u = u.replace(/^([^/:]+):\d+\//, '$1/').replace(/^([^/:]+):/, '$1/')
  u = u.replace(/\/+$/, '').replace(/\.git$/, '')
  const slash = u.indexOf('/')
  return slash > 0 ? u.slice(0, slash).toLowerCase() + u.slice(slash) : u
}

function remoteUrls(dir) {
  const out = quietly(() => git(['config', '--get-regexp', '^remote\\..*\\.url$'], dir), '')
  return out.split('\n').filter(Boolean).map((l) => normalizeRemote(l.slice(l.indexOf(' ') + 1)))
}

function configRoots() {
  if (process.env.MEMORY_STORE_CONFIG_ROOTS) return process.env.MEMORY_STORE_CONFIG_ROOTS.split(':').filter(Boolean)
  const home = homedir()
  return readdirSync(home).filter((n) => /^\.claude/.test(n)).map((n) => join(home, n))
}

/** Distinct opted-in store top-levels reachable through any project's memory link. */
export function discoverStores() {
  const stores = new Set()
  for (const root of configRoots()) {
    const projects = join(root, 'projects')
    for (const p of quietly(() => readdirSync(projects), [])) {
      const link = join(projects, p, 'memory')
      if (!quietly(() => lstatSync(link).isSymbolicLink(), false)) continue
      const target = quietly(() => realpathSync(link))
      if (!target) continue
      const top = quietly(() => git(['rev-parse', '--show-toplevel'], target).trim())
      if (!top) continue
      if (quietly(() => git(['config', '--local', '--bool', 'claude.memoryStore'], top).trim()) !== 'true') continue
      stores.add(top)
    }
  }
  return [...stores]
}

function parseIncoming(top, upstream) {
  const incoming = new Map()
  const out = git(['diff', '--no-renames', '--raw', '-z', '--no-abbrev', 'HEAD', upstream], top)
  const parts = out.split('\0')
  for (let i = 0; i + 1 < parts.length; i += 2) {
    const meta = parts[i].replace(/^:/, '').split(' ')
    const path = parts[i + 1]
    const status = meta[4][0]
    incoming.set(path, { status: status === 'D' ? 'D' : status === 'A' ? 'A' : 'M', blob: status === 'D' ? null : meta[3] })
  }
  return incoming
}

function parseDirty(top) {
  const out = git(['status', '--porcelain=v1', '-z', '--untracked-files=all', '--no-renames'], top)
  const dirty = []
  for (const rec of out.split('\0')) {
    if (rec.length < 4) continue
    const xy = rec.slice(0, 2)
    const path = rec.slice(3)
    const abs = join(top, path)
    const blob = existsSync(abs) ? git(['hash-object', '--', path], top).trim() : null
    dirty.push({ path, xy, blob })
  }
  return dirty
}

/** Where `git switch` should take a store: the remote's default branch when git recorded one. */
function defaultBranch(top) {
  const remote = quietly(() => git(['remote'], top).split('\n').filter(Boolean)[0])
  const head = remote && quietly(() => git(['symbolic-ref', '--quiet', `refs/remotes/${remote}/HEAD`], top).trim())
  const branch = head ? head.slice(`refs/remotes/${remote}/`.length) : null
  return { remote: remote ?? '<remote>', branch: branch ?? '<default-branch>' }
}

/**
 * The branch HEAD is on and the upstream it follows when that upstream is the same branch name on
 * a real remote; otherwise which of the three other cases applies.
 *
 * The branch's own config is read directly rather than through `%(upstream:remotename)`, which
 * resolves via the configured fetch refspec: a store whose refspec no longer covers its branch
 * reports no upstream at all, and the repair that reading suggests (setting an upstream that is
 * already set) does not fix it. With the refspec out of the question, the explicit refspec this
 * hook fetches with is what keeps such a store moving.
 */
function trackedUpstream(top) {
  const head = quietly(() => git(['symbolic-ref', '--quiet', 'HEAD'], top).trim())
  if (!head?.startsWith('refs/heads/')) return { ok: false, cause: 'detached', branch: null, follows: null }
  const branch = head.slice('refs/heads/'.length)
  const remote = quietly(() => git(['config', `branch.${branch}.remote`], top).trim())
  const merge = quietly(() => git(['config', `branch.${branch}.merge`], top).trim())
  if (!remote || remote === '.' || !merge) return { ok: false, cause: 'no-upstream', branch, follows: null }
  if (merge !== head) return { ok: false, cause: 'other-branch', branch, follows: `${remote}/${merge.replace(/^refs\/heads\//, '')}` }
  return { ok: true, remote, branch, ref: `refs/remotes/${remote}/${branch}`, name: `${remote}/${branch}` }
}

function isAncestor(top, ref) {
  try {
    git(['merge-base', '--is-ancestor', 'HEAD', ref], top)
    return true
  } catch (err) {
    if (err.status === 1) return false
    throw err
  }
}

/** The first line git wrote to stderr, else the error's own first line. */
function gitFailure(err) {
  const lines = `${err?.stderr ?? ''}`.split('\n').map((l) => l.trim()).filter(Boolean)
  return (lines[0] ?? `${err?.message ?? err}`.split('\n')[0]).slice(0, 200)
}

function decide(top, now) {
  const base = { v: REPORT_VERSION, at: now, adopt: [], conflicts: [], unsynced: [], committed: [] }
  const up = trackedUpstream(top)
  if (!up.ok) {
    return { ...base, upstream: null, head: git(['rev-parse', 'HEAD'], top).trim(), action: 'refuse', reason: 'not-on-tracking-branch',
      cause: up.cause, branch: up.branch, follows: up.follows, suggest: defaultBranch(top) }
  }
  const configured = quietly(() => git(['config', 'core.sshCommand'], top).trim())
  git(['fetch', '--quiet', '--no-tags', up.remote, `+refs/heads/${up.branch}:${up.ref}`], top, sshEnv(CHILD_ENV, configured))

  const ancestor = isAncestor(top, up.ref)
  const plan = planRefresh(ancestor ? parseIncoming(top, up.ref) : new Map(), parseDirty(top), ancestor)
  if (plan.action === 'ff') {
    if (plan.adopt.length > 0) git(['add', '-A', '--', ...plan.adopt], top)
    git(['merge', '--ff-only', '--quiet', up.ref], top)
  }
  // The notes a local commit would lose on a reset, so the report can name what to copy out first.
  const committed = ancestor ? [] : git(['log', '-z', '--format=', '--name-only', `${up.ref}..HEAD`], top)
    .split('\0').map((p) => p.replace(/^\n+/, '')).filter(Boolean)
  return { ...base, upstream: up.name, head: git(['rev-parse', 'HEAD'], top).trim(), ...plan, committed: [...new Set(committed)] }
}

/** Take the per-store lock; false when a live run holds it. A lock older than LOCK_STALE_MS is broken. */
function takeLock(lock, now) {
  const take = () => { writeFileSync(lock, String(process.pid), { flag: 'wx' }); return true }
  try {
    return take()
  } catch (err) {
    if (err.code !== 'EEXIST') throw err
  }
  if (quietly(() => now - statSync(lock).mtimeMs, 0) < LOCK_STALE_MS) return false
  rmSync(lock, { force: true })
  return quietly(take, false)
}

/** Refresh one store. Returns the report object, or the last recorded one when this session does not run. */
export function refreshStore(top, now = Date.now()) {
  const gitDir = git(['rev-parse', '--absolute-git-dir'], top).trim()
  const stamp = join(gitDir, 'claude-memory-refresh.stamp')
  const last = join(gitDir, 'claude-memory-refresh.last.json')
  const lock = join(gitDir, 'claude-memory-refresh.lock')
  const lastReport = () => quietly(() => {
    const r = JSON.parse(readFileSync(last, 'utf8'))
    return r.v === REPORT_VERSION ? r : null
  })
  const fresh = () => quietly(() => Date.now() - statSync(stamp).mtimeMs < THROTTLE_MS, false)
  if (fresh()) return lastReport()
  // Sessions start in bursts; without the lock each would fetch and merge at once, and the losers'
  // "cannot lock ref" would be reported as a failure of a store that in fact moved.
  if (!takeLock(lock, now)) return lastReport()
  try {
    if (fresh()) return lastReport()
    writeFileSync(stamp, String(now))
    let report
    try {
      report = decide(top, now)
    } catch (err) {
      report = { v: REPORT_VERSION, at: now, upstream: null, head: quietly(() => git(['rev-parse', 'HEAD'], top).trim()),
        action: 'error', reason: gitFailure(err), adopt: [], conflicts: [], unsynced: [], committed: [] }
    }
    // Kept whatever the outcome, so a throttled session re-reports a refusal, a failure and the
    // unsynced notes instead of going quiet until the next attempt.
    writeFileSync(last, JSON.stringify(report))
    return report
  } finally {
    rmSync(lock, { force: true })
  }
}

/**
 * Unsynced notes worth mentioning, grouped by what happened here: no backup files, and nothing a
 * live session may still be writing (a deleted note has no age and is always listed).
 */
export function groupUnsynced(top, entries, now = Date.now()) {
  const groups = { added: [], edited: [], deleted: [] }
  for (const { path, xy } of entries) {
    if (path.endsWith('.bak') || /\.bak-/.test(path)) continue
    const mtime = quietly(() => statSync(join(top, path)).mtimeMs)
    if (mtime !== null && now - mtime < UNSYNCED_MIN_AGE_MS) continue
    const kind = /[?A]/.test(xy) ? 'added' : xy.includes('D') ? 'deleted' : 'edited'
    groups[kind].push(path)
  }
  return groups
}

function list(paths) {
  const shown = paths.slice(0, LIST_LIMIT).map((p) => `\`${p}\``).join(', ')
  return paths.length > LIST_LIMIT ? `${shown} and ${paths.length - LIST_LIMIT} more` : shown
}

function refusalLine(top, report) {
  const store = `The memory store \`${top}\``
  if (report.reason === 'not-on-tracking-branch') {
    const { remote, branch } = report.suggest
    if (report.cause === 'detached') return `${store} has a detached HEAD, so it was NOT updated. Put it back on its branch with \`git -C ${sq(top)} switch ${branch}\`.`
    if (report.cause === 'no-upstream') return `${store} is on branch \`${report.branch}\`, which follows no upstream branch, so it was NOT updated. Set one with \`git -C ${sq(top)} branch --set-upstream-to=${remote}/${report.branch}\`.`
    return `${store} is on branch \`${report.branch}\`, which follows \`${report.follows}\` instead of a branch of the same name, so it was NOT updated. Switch it with \`git -C ${sq(top)} switch ${branch}\`.`
  }
  if (report.reason === 'local-commits') {
    const notes = report.committed.length > 0 ? ` Those commits touch ${list(report.committed)}.` : ''
    return `${store} has commits that are not on \`${report.upstream}\`, so it was NOT updated.${notes} Copy those notes out of the store first, then run \`git -C ${sq(top)} reset --keep ${report.upstream}\`; notes are landed by pull request from a worktree, never committed in the store.`
  }
  return `${store} was NOT updated: ${list(report.conflicts)} differ both locally and on \`${report.upstream}\`. Fold each by content, then re-run this hook.`
}

export function main(cwd = process.cwd()) {
  const mine = new Set(remoteUrls(cwd))
  const lines = []
  for (const top of discoverStores()) {
    const report = quietly(() => refreshStore(top))
    if (!report || !remoteUrls(top).some((u) => mine.has(u))) continue
    if (report.action === 'error') {
      lines.push(`⚠️  The memory store \`${top}\` could not be updated; git said: \`${report.reason}\`. The hook tries again after ${Math.round(THROTTLE_MS / 60000)} minutes.`)
    } else if (report.action === 'refuse') {
      lines.push(`⚠️  ${refusalLine(top, report)}`)
    }
    const g = groupUnsynced(top, report.unsynced)
    const n = g.added.length + g.edited.length + g.deleted.length
    if (n > 0) {
      const parts = [['new here', g.added], ['edited here', g.edited], ['deleted here', g.deleted]]
        .filter(([, ps]) => ps.length > 0).map(([label, ps]) => `${label}: ${list(ps)}`)
      lines.push(`For information: ${n} memory note(s) in \`${top}\` differ from \`${report.upstream}\` — ${parts.join('; ')}. They are kept as they are; a pull request is the way to share them.`)
    }
  }
  if (lines.length > 0) process.stdout.write(`# Memory store\n\n${lines.map((l) => `- ${l}`).join('\n')}\n`)
}

// Compared on REAL paths: Node resolves symlinks in import.meta.url but not in argv[1], so a hook
// registered through a linked path (or living under macOS's /var -> /private/var) would otherwise
// never run, silently.
if (process.argv[1] && quietly(() => realpathSync(process.argv[1])) === fileURLToPath(import.meta.url)) {
  try { main() } catch { /* fail open: a store refresh may never block a session */ }
}
