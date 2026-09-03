---
name: measure-what-reaches-context-not-disk
description: A truncating SessionStart injection silently drops most of the memory index; measure what reaches context, not what is on disk.
metadata:
  type: feedback
scope: global
---

Anything injected at SessionStart is capped, and a cap without a COUNT in its
notice loses data silently. `inject-global-memory.sh` truncated the global memory
index to 12,000 chars and said only "truncated": 69 of 123 memories (56%) reached
no session at all, for months. The memory system looked healthy from the file.

Three separate errors compounded, each invisible alone:

- **Billing the file, not the injection.** MEMORY.md is 8,479 tokens on disk but
  only ~2,900 were injected. A first pass at a budget tool measured the file and
  overstated session cost by 39%, while missing that the rest was being *lost*.
- **Byte/char mixing.** The hook tested `${#out}` (characters) but sliced with
  `head -c` (bytes). 3-byte em-dashes made it cut ~166 chars early — dropping an
  entry the cap allowed, and disagreeing with the Windows runtime, which sliced
  characters. The parity test pinned the budget NUMBER, so it saw nothing.
- **A predicate written against the old format.** After the index was compacted
  to `- slug`, a counter still matching `- [` reported 122 of 123 dropped.

**The fix is not a bigger cap — it is a cap that abbreviates instead of drops.**
Truncating an entry's prose is recoverable; dropping its NAME is not, because an
unlisted memory can never be unfolded and the mistake it exists to prevent just
gets made again. Binary-search the largest per-entry cap that fits and cut only
the entries above it: 125 of 125 memories now reach context at the same 12,000
chars, where 66 did before. Only then is raising the budget a real choice, and a
priced one — 20,000 chars buys 122-char hooks for about +1,800 tokens a session.

**A budget guard must not redden on honest growth.** Enforce PER-ENTRY size
(MAX only) plus the invariant `dropped == 0`; report every total AND every MEAN as
the bill without failing on them. A ratchet on totals fails the moment a genuine
new memory is written, and a guard that fails on correct behaviour gets switched off.

**A mean is a total wearing a per-entry label.** This rule previously said to
enforce "mean and max", the guard was built that way, and it cost a red tree:
measured 2026-09-02, an honest 646 B directive — well inside the 977 B per-entry
limit — pushed the mean 387 -> 389 B and failed `--check`, and holding that mean
would have required every future directive to come in under 372 B, below the
corpus average of 389. Divide by N and a metric stops being something a writer
controls: it moves when someone ELSE writes. Test the classification the same
way — compute what a single new honest entry of typical size does to the metric;
if it rises, the metric belongs in the bill, whatever it is named.

**Why:** a silent cap converts an accumulating index into an invisible one, and
every guard around it (parity test, sanitizer, suite) can be green throughout.

**How to apply:** measure the artifact that REACHES the consumer, by running the
producer and diffing — never by reimplementing its truncation arithmetic. Make
every cap name the count it discarded, so the loss is a defect report rather than
a formatting note. Assert runtime parity on OUTPUT, not on the shared constant.
Slice and measure in the SAME unit. And re-check any counting predicate after the
format it reads changes — see [[verify-claims-against-artifacts]],
[[a-control-must-match-the-probes-shape]], [[absence-needs-a-probe-that-could-see-presence]].
