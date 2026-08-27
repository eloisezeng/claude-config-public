---
name: enumerate-recurring-defect-classes
description: When a defect class recurs across review rounds, stop hunting instances and demand an enumeration with a denominator
metadata:
  type: feedback
scope: global
---

When the same defect class surfaces in three consecutive review rounds, each time at a *different*
site, the reviews are not converging on it — they are sampling it. Stop asking "is this correct?"
and start asking for a census: **enumerate every site of the pattern, classify each one, and report
the counts.**

Measured on the 2026-08-10 AI-budget branch. An effective-vs-stored cap distinction leaked one
surface per round for three rounds (Agents headline → inbox headroom + credits note → chat
preflight + chat money summary + health warning). Each round fixed the instance it found and
declared the class closed. Round 4's lens was instead told: *find every read site, classify each as
correctly-A, correctly-B, or wrong, and report the count.* It returned **34 sites: 18 correctly
stored, 13 correctly effective, 3 wrong** — and named the three. The class closed in one pass.

**Why:** The denominator is what makes the sweep checkable. "I looked and found three" is
indistinguishable from "I found the three that were easy to see"; "34 sites, here is how they
split" can be audited, and a later reader can re-run the census and compare. It also converts a
judgment task into a mechanical one, which is where reviewers are reliable.

**How to apply**
- Trigger on the SECOND repeat, not the fifth. Two rounds finding the same class at different sites
  is the signal.
- Put the enumeration in the prompt as the round's primary deliverable, and require the count in the
  summary — not just the findings list.
- Demand the full three-way classification. "Correct for reason X" is as informative as "wrong":
  it proves the site was examined rather than skipped, and the correctly-A bucket is where a future
  refactor will break things.
- The same move works for any family with enumerable membership — every caller of a gate, every
  writer of a payload, every path that rebuilds a table.
- Run the enumeration at INTRODUCTION time, not just at recurrence: a new error type, enum value,
  or semantic distinction has a consumer set the moment it exists (catch sites, outcome labels,
  slot/satisfaction queries, event consumption), and enumerating it then closes in one pass the
  class that review rounds would otherwise surface one consumer at a time (2026-08-10: four of one
  round's findings were a single new error type reaching four unenumerated consumers; the #253
  stored-vs-enforced cap was the same shape).

- **Never ASSERT a class from samples — the census is what earns the claim, and it often disproves
  it.** Same discipline, opposite direction: from two partly-guarded-looking timer bodies I told the
  operator "any uncaught throw in a worker timer restarts the machine, and nobody has enumerated the
  rest." The census took four greps: 9 hits → **4 real call sites, 4/4 covered** (2 explicitly
  try/caught, 2 structurally safe because an `async function` cannot throw synchronously, so its
  `.catch` takes every throw). The hazard was real as a vector with zero unguarded sites — so the
  count REMOVED a work item instead of adding one, and a peer who had amplified my claim re-ran the
  census rather than forwarding my retraction. Counting is cheap; speculation is what reaches the
  operator and has to be walked back (2026-08-11).

- **An enumeration is valid only at the head it was run against, and the pass that ANSWERS it
  invalidates its own count.** The fix pass edits the enumerated document, so it adds sites to the very
  class it is closing. Re-run the search as the last step of the fix, not the first (2026-08-20, GTM
  spec: a count of 11 was published, three matching lines were added by the same pass, the reviewer
  re-ran the documented search and got 14, and the fix for *that* took it to 16).
- **Count with the method the claim uses.** `grep -c` counts matching LINES; a claim of "N hits" means
  matches, which is `grep -o | wc -l`. The two agree often enough to hide the error and then silently
  disagree — same document, same round: 10 lines but 11 matches across 10 distinct sites, against a
  published 10/9. Write the search string beside its count, and say which of the two the number is.
- **For a value with closed structure, enumerate the STRUCTURE, not the vocabulary.** A vocabulary grep
  finds only rules that use the vocabulary, and the rules that matter most are often phrased in the
  domain's own words. An enum's transitions, a state machine's edges, a matrix's cells are computable
  from the type: three owners give nine ordered pairs, each of which must have a named writer or an
  explicit refusal. Two vocabulary enumerations and five review rounds missed a state with no outbound
  edge at all; the transition enumeration found it in one pass (2026-08-20).
- **Assert the WRITER, not just the permission.** A transition table checked only for "is this allowed"
  passes with every writer label wrong, and with `from`/`to` swapped. The label is the part that decays.

Related: `[[verify-claims-against-artifacts]]`, `[[codex-parallel-lenses-beat-serial-rounds]]`,
`[[mirror-a-gate-at-its-exact-scope]]`.
