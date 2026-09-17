#!/usr/bin/env node
/**
 * Two facts a session cannot see for itself, surfaced at SessionStart.
 *
 * WHY THIS EXISTS. On 2026-09-14 the full-suite backstop of `your-org/your-other-project` went red
 * on `main` and stayed red for 44 hours. Nothing reached anybody. Three independent gaps had to
 * line up, and they did:
 *
 *   1. No instruction anywhere — project CLAUDE.md, global CLAUDE.md, any skill — tells a session
 *      to read the status of a run it did not itself launch. The nightly was outside every
 *      checklist.
 *   2. `~/.claude/bin/ci-green.sh`, the one tool that could have seen it, is commit-scoped and
 *      `ci-derive.py` deliberately drops schedule-triggered workflows from the expected set. It
 *      answers GREEN for a sha whose nightly is red.
 *   3. The nightly's only alarm is GitHub's email to whoever last touched its `schedule:` block.
 *      No agent can read that, and 44 hours of evidence says nobody else did either.
 *
 * The pull request that eventually fixed it recorded in its own message that "nothing caught it
 * for 44 hours". The nightly had caught it twice. That sentence is what a session looks like when
 * it cannot see the signal.
 *
 * A fourth thing made it worse rather than causing it: the shared checkout was 753 commits behind
 * `origin/main`, so a session running the suite locally would have seen green about a tree from
 * three weeks earlier.
 *
 * WHY A LANE AND NOT A SOUND. `stop-event.sh` rings a bell on this Mac at the end of a turn. A
 * scheduled run finishes when no session is open, so the bell has nobody to ring to, and push
 * notifications are off in settings.json. The ops-lane ledger is read into EVERY session by
 * `inject-ops-lanes.sh` and keeps restating an item until somebody closes it. That persistence is
 * the property the bell lacks, and it is the same channel `sync.sh` already uses for a broken
 * backup.
 *
 * DESIGN CONSTRAINTS, all deliberate:
 *   - FAIL OPEN, ALWAYS. This runs before every session in every repo. Any error prints nothing
 *     and exits 0. A session must never be blocked or delayed by a health probe.
 *   - NO FETCH. The behind-count is read from remote refs that are ALREADY local. A hook that
 *     fetched would put a network write-ish operation on every session start in every repo, and
 *     the freshness of that local state is reported instead of silently assumed.
 *   - CACHED. The GitHub query runs at most once per TTL per repository, so the cost is a few
 *     calls a day rather than one per session.
 *   - RING ONCE PER RED RUN, not once per session. The lane is the persistent signal; the bell is
 *     a one-shot courtesy keyed on the run id, so a long-lived red does not become noise that
 *     trains her to ignore it.
 *   - GENERIC. Nothing here names your-other-project. Any repo with a `schedule:` workflow is
 *     covered the day it gains one.
 */
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = homedir()
const STATE_DIR = join(HOME, '.claude', 'session-state')
const LANE_DIR = join(HOME, '.claude', 'ops', 'lanes')
/** How long a scheduled-run verdict is reused before asking GitHub again. */
const CACHE_TTL_MS = 6 * 60 * 60 * 1000
/** Hard ceiling on any child process. BSD userland has no `timeout(1)`, so it is set here. */
const CHILD_TIMEOUT_MS = 8000
/** Behind-count at which the checkout is called out rather than merely noted. */
const BEHIND_LOUD = 25

function git(args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', timeout: CHILD_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'ignore'] }).trim()
}

function quietly(fn, fallback = null) {
  try { return fn() } catch { return fallback }
}

/**
 * How far this checkout is behind its remote, WITHOUT fetching, plus how old that remote state is.
 * Returning the staleness of the answer alongside the answer is the point: "0 behind" read off a
 * three-week-old fetch is not the same claim as "0 behind" read off one from a minute ago.
 */
function checkoutLag(root) {
  const remoteHead = quietly(() => git(['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'], root))
    ?? (quietly(() => git(['rev-parse', '--verify', '--quiet', 'origin/main'], root)) ? 'origin/main' : null)
  if (!remoteHead) return null
  const behind = Number(quietly(() => git(['rev-list', '--count', `HEAD..${remoteHead}`], root), '0'))
  if (!Number.isFinite(behind)) return null

  const commonDir = quietly(() => git(['rev-parse', '--path-format=absolute', '--git-common-dir'], root))
    ?? quietly(() => git(['rev-parse', '--git-common-dir'], root))
  let fetchedAgoH = null
  if (commonDir) {
    const st = quietly(() => statSync(join(commonDir, 'FETCH_HEAD')))
    if (st) fetchedAgoH = Math.round((Date.now() - st.mtimeMs) / 3_600_000)
  }
  return { remoteHead, behind, fetchedAgoH }
}

/** Workflow files declaring a `schedule:` trigger. Derived from the directory, never a list. */
function scheduledWorkflows(root) {
  const dir = join(root, '.github', 'workflows')
  if (!existsSync(dir)) return []
  return quietly(() => readdirSync(dir).filter((f) => /\.ya?ml$/.test(f)), [])
    .filter((f) => quietly(() => /^\s*schedule:/m.test(readFileSync(join(dir, f), 'utf8')), false))
}

function repoSlug(root) {
  const url = quietly(() => git(['remote', 'get-url', 'origin'], root))
  const m = url && /[:/]([^/:]+\/[^/]+?)(?:\.git)?$/.exec(url)
  return m ? m[1] : null
}

/**
 * Latest run of one workflow on the default branch. Uses `gh-axi` per the standing tool rule; its
 * `api` subcommand emits a YAML-ish block, so the fields are read by line rather than parsed as
 * JSON. Any shape it does not recognise yields null, which is treated as "unknown", never as
 * "green" — this probe may not fail open into a false reassurance, only into silence.
 */
function latestRun(slug, workflowFile, branch) {
  const out = quietly(() => execFileSync('gh-axi',
    ['api', `repos/${slug}/actions/workflows/${workflowFile}/runs?branch=${branch}&per_page=1`],
    { encoding: 'utf8', timeout: CHILD_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'ignore'] }))
  if (!out) return null
  const field = (name) => {
    const m = new RegExp(`^\\s*${name}:\\s*"?([^"\\n]+)"?\\s*$`, 'm').exec(out)
    return m ? m[1].trim() : null
  }
  const status = field('status')
  const conclusion = field('conclusion')
  if (!status) return null
  return { status, conclusion, createdAt: field('created_at'), id: field('id'), headSha: field('head_sha') }
}

function cacheFor(slug) {
  return join(STATE_DIR, `${slug.replace(/[^\w.-]/g, '_')}.schedruns.json`)
}

/** One-shot bell, keyed so a red that persists for days rings once rather than every session. */
function ringOnce(key, message) {
  const marker = join(STATE_DIR, `ring-${key.replace(/[^\w.-]/g, '_')}`)
  if (existsSync(marker)) return
  quietly(() => writeFileSync(marker, new Date().toISOString()))
  quietly(() => execFileSync('bash', ['-lc',
    `source "$HOME/dotfiles/claude/hooks/notif-ring.sh" 2>/dev/null && ring ${JSON.stringify(message)} "CI backstop" "Glass"`],
  { timeout: CHILD_TIMEOUT_MS, stdio: 'ignore' }))
}

/**
 * Write or refresh the lane. Rewriting an already-open lane in place is deliberate: the ledger
 * should carry ONE entry per broken backstop that stays current, not one per night it was broken.
 */
function writeLane(slug, workflowFile, run) {
  quietly(() => mkdirSync(LANE_DIR, { recursive: true }))
  const repo = slug.split('/')[1]
  const lane = `ci-backstop-red-${repo}-${workflowFile.replace(/\.ya?ml$/, '')}`
  const path = join(LANE_DIR, `${lane}.md`)
  const body = `---
lane: ${lane}
state: open
opened: ${new Date().toISOString().slice(0, 10)}
opened_by: repo-health-at-session-start.mjs (automatic)
pointer: https://github.com/${slug}/actions/workflows/${workflowFile}
---

# The full-suite backstop of ${slug} is RED on its default branch

Latest \`${workflowFile}\` run: **${run.conclusion ?? run.status}**, started ${run.createdAt ?? 'unknown'}, head \`${(run.headSha ?? '').slice(0, 8)}\`.

This workflow is the backstop behind the per-pull-request affected-test selection. A red here means
a failure that the selection let through is **already on the default branch**, and on a repository
that auto-deploys, already in production. Fix it forward the same day: a chronically red backstop
protects nothing, and the last one sat red for 44 hours while a merged pull request's own message
claimed nothing had caught it.

This lane was written automatically and is refreshed, not duplicated, on each session start while
the run remains red. It clears itself once the workflow's latest run on the default branch is
green. Do not close it by hand while it is still failing.
`
  quietly(() => writeFileSync(path, body))
  return path
}

function clearLane(slug, workflowFile) {
  const repo = slug.split('/')[1]
  const path = join(LANE_DIR, `ci-backstop-red-${repo}-${workflowFile.replace(/\.ya?ml$/, '')}.md`)
  if (!existsSync(path)) return
  const current = quietly(() => readFileSync(path, 'utf8'), '')
  if (!current.includes('opened_by: repo-health-at-session-start.mjs')) return // never touch a human's lane
  quietly(() => writeFileSync(path, current.replace(/^state: open$/m, 'state: completed')))
}

function main() {
  const cwd = process.cwd()
  const root = quietly(() => git(['rev-parse', '--show-toplevel'], cwd))
  if (!root) return

  const lines = []

  const lag = checkoutLag(root)
  if (lag && lag.behind > 0) {
    const age = lag.fetchedAgoH === null ? 'unknown age' : `last fetched ~${lag.fetchedAgoH}h ago`
    const loud = lag.behind >= BEHIND_LOUD
    lines.push(
      `${loud ? '⚠️  STALE CHECKOUT' : 'Checkout lag'}: this working tree is **${lag.behind} commits behind ${lag.remoteHead}** (${age}).`
      + (loud
        ? ' A local test run here measures a tree that old, not the current one, and a green result says nothing about the default branch. Work from a fresh worktree, or read files with `git show '
          + lag.remoteHead + ':<path>` rather than from disk.'
        : ''),
    )
  }

  const slug = repoSlug(root)
  const workflows = slug ? scheduledWorkflows(root) : []
  if (slug && workflows.length > 0) {
    const cachePath = cacheFor(slug)
    const cached = quietly(() => JSON.parse(readFileSync(cachePath, 'utf8')), null)
    const fresh = cached && Date.now() - (cached.at ?? 0) < CACHE_TTL_MS
    let verdicts = fresh ? cached.verdicts : null

    if (!verdicts) {
      const branch = (lag?.remoteHead ?? 'origin/main').replace(/^origin\//, '')
      verdicts = {}
      for (const wf of workflows) {
        const run = latestRun(slug, wf, branch)
        if (run) verdicts[wf] = run
      }
      quietly(() => mkdirSync(STATE_DIR, { recursive: true }))
      quietly(() => writeFileSync(cachePath, JSON.stringify({ at: Date.now(), verdicts })))
    }

    for (const [wf, run] of Object.entries(verdicts ?? {})) {
      if (run.status !== 'completed') continue
      if (run.conclusion === 'success') { clearLane(slug, wf); continue }
      if (run.conclusion !== 'failure' && run.conclusion !== 'timed_out') continue
      const lanePath = writeLane(slug, wf, run)
      ringOnce(`${slug}-${wf}-${run.id ?? run.createdAt}`, `${wf} is red on ${slug}`)
      lines.push(
        `🔴 **The scheduled backstop \`${wf}\` is RED on the default branch of ${slug}** `
        + `(run started ${run.createdAt ?? 'unknown'}, head \`${(run.headSha ?? '').slice(0, 8)}\`). `
        + 'It is the only full-suite run anywhere, so a red means a selected-away failure is already merged — '
        + `and on an auto-deploying repo, already live. Lane: ${lanePath}`,
      )
    }
  }

  if (lines.length > 0) process.stdout.write(`# Repository health\n\n${lines.map((l) => `- ${l}`).join('\n')}\n`)
}

try { main() } catch { /* fail open: a health probe may never block a session */ }
