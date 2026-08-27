// fleet-flags.mjs — ONE argv reader for the two read-only viewers.
//
// `fleet` has THREE argv surfaces: `fleet ids` (inside bin/fleet), fleet-watch.mjs and
// fleet-tail.mjs. Round 6 hardened the first one and left a comment saying exactly why:
//
//     And Number("abc") is NaN, which no row is older than,
//     so a typo used to admit EVERY session instead of failing.
//
// Both viewers still had the loose form when they finally entered review in round 7, and
// all four of the predicted symptoms were live on this machine:
//
//   * `fleet <id>` read the SESSION ID as the back-count, because
//     `argv[argv.indexOf('--back') + 1]` is `argv[0]` when the flag is absent. Short ids
//     are [0-9a-f]{8}, so an all-digit id is a number: 39879268 and 57217260 both exist
//     here, and `fleet 39879268` asked for 39,879,268 entries.
//   * `fleet --max-age nope` turned the cutoff into NaN, and no row is older than NaN, so
//     it admitted 48 sessions where the default window admits 22 (measured 2026-08-21).
//   * `fleet --back` with no operand gave NaN, which `if (n <= 0) return` does not catch
//     and `slice(-NaN)` treats as `slice(0)` — the whole byte window, for every session.
//   * `--back 0` was silently overridden by `|| 12`.
//
// A flag whose value one surface accepts and another refuses is the same defect as a flag
// nobody validates, so the rule here is deliberately IDENTICAL to `fleet ids`: digits only,
// operand required, unknown argument refused, and an explicit 0 honoured.

/** Digits only — the same predicate `fleet ids` enforces. Rejects "", "-5", "1.5", "abc", "1e3". */
export const isWholeNumber = (v) => typeof v === 'string' && /^[0-9]+$/.test(v)

/**
 * Read argv against a spec, or exit 2 with usage.
 *
 * spec = { usage, numeric: {'--back': 12}, string: {'--only': ''}, boolean: ['--quiet'],
 *          positionals: {name: 'short-session-id', min: 0, max: 0} }
 *
 * Returns { values, positionals }. `die` is injectable so this is testable without a process.
 */
export function parseFlags(argv, spec, die = defaultDie(spec)) {
  const numeric = spec.numeric || {}
  const string = spec.string || {}
  const boolean = spec.boolean || []
  const pos = spec.positionals || { min: 0, max: 0 }

  const values = { ...numeric, ...string }
  for (const b of boolean) values[b] = false
  const positionals = []

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (boolean.includes(a)) { values[a] = true; continue }
    if (a in numeric || a in string) {
      const v = argv[i + 1]
      // An operand that is missing, or that is itself a flag, is a typo — not a value.
      // `fleet --back --quiet` used to mean "back = NaN" and painted everything.
      if (v === undefined) die(`${a} needs a value and nothing followed it`)
      if (a in numeric) {
        if (!isWholeNumber(v)) die(`${a} needs a whole number\n  Got: ${JSON.stringify(v)}`)
        values[a] = Number(v)          // an explicit 0 survives: no `||` anywhere here
      } else {
        values[a] = v
      }
      i++
      continue
    }
    // Silently ignoring an unknown argument is how `--reachble` became decoration; and a
    // POSITIONAL that looks like a flag is the same mistake from the other end.
    if (a.startsWith('-')) die(`unknown argument ${JSON.stringify(a)}`)
    positionals.push(a)
  }

  if (positionals.length < (pos.min ?? 0)) die(`missing ${pos.name || 'argument'}`)
  if (positionals.length > (pos.max ?? 0)) {
    die(`takes ${pos.max ?? 0} argument${(pos.max ?? 0) === 1 ? '' : 's'}\n  Got: ${JSON.stringify(positionals)}`)
  }
  return { values, positionals }
}

function defaultDie(spec) {
  return (msg) => {
    process.stderr.write(`${spec.name || 'fleet'}: ${msg}\n${spec.usage || ''}\n`)
    process.exit(2)
  }
}
