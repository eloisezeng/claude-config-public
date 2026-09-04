---
name: grep-the-ledger-for-the-artifact-not-your-lane
description: Your own closed lane is not clearance to act on a shared artifact — grep the OPEN ledger for the ARTIFACT, because a sibling's audit of it may be minutes old
metadata:
  type: feedback
  scope: global
---

Before an irreversible outward-facing act on a shared artifact (a publish, a push to a
public remote, a deploy, a destructive migration), grep the open lane ledger for **the
artifact**, not for your own lane.

I pushed the public mirror on the strength of a lane **I** had opened, measured and
closed, whose own "Next" line said to push once a named suite went green. It did, and I
pushed. Twenty-three minutes later a sibling seat was dispatched to fix four measured
publishing defects in that same mirror, on a handoff whose second heading is **"Do NOT
push to the public remote"** — because two content decisions were open and belonged to
The user. Its audit found 8 files at public HEAD leaking real person names, a real product
name, schema identifiers and a vendor name.

The push turned out harmless, and only measurement says so: over its 721 added lines,
0 hits for any audited term, and all 8 leaking files were pre-existing by eight days.
But that is the outcome, not the reasoning. The reasoning was "my lane says go", and my
lane could not know about an audit written after it closed.

The asymmetry is the whole point. A lane you wrote records what **you** measured; the
ledger records what **anyone** measured. On a shared artifact those diverge constantly,
and they diverge fastest right after you finish work on it, because finishing is exactly
when a sibling is most likely to be auditing the thing you just changed.

So:

- Grep `~/.claude/ops/lanes/` and `~/.claude/ops/handoffs/` for the artifact's **name**
  (repo, remote, host, table) at act time — not for your lane's slug. Re-grep after any
  gap, since the window that matters is minutes wide.
- A closed lane is evidence about the past. Clearance is a property of the ledger **now**.
- When you discover afterwards that you acted inside someone's hold, measure the blast
  radius before saying anything about it, correct any overstatement in your own record in
  place, and hand the other party the fact they most need — for me that was the base sha
  their handoff had wrong, which my push had moved.

Related: [[ops-lane-ledger]], [[act-on-fresh-state-anchor-by-identity]],
[[shared-runbooks-reclaim-ownership-at-fire-time]],
[[a-token-sanitizer-cannot-see-a-topic-leak]].
