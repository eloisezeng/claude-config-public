---
name: a-rename-sweep-takes-its-census-from-the-guard
description: a typecheck is not the census for a vocabulary sweep — the project's own vocabulary guard is, and importing its exemption list as the sweep's rule is what keeps external contracts intact
metadata:
  type: feedback
  scope: global
---

For a rename or vocabulary sweep, the CENSUS is the project's own vocabulary guard, never the
typecheck, and the sweep's RULE is that guard's exported exemption list rather than a pattern of
your own.

**Why:** a typecheck sees only a broken MODULE REFERENCE. A legacy identifier used as a local
variable, a prop name, a mocked JSON field or a comment typechecks perfectly and still fails the
guard, which the gate runs (measured, finishing PR #42's merge onto #37 in a private frontend repo:
the typecheck named 21 files, `tests/idea-vocabulary.test.ts` reported **377 unapproved occurrences
across 43 files**). A hand-written sweep pattern is a second rule that will disagree with the guard
in both directions — too narrow and it misses files, too wide and it rewrites the SQL object names,
the MCP tool names, the telemetry and browser-storage keys, the compatibility redirects and the
ordinary English phrases the guard exempts as external contracts.

**How to apply:** import the guard's exported `ALLOWED` array, reproduce its per-occurrence
`location` string byte-for-byte (including any masking of the other occurrences on the same line),
and rewrite ONLY the occurrences it classifies as unapproved — occurrence by occurrence, because
one line can hold both an approved and an unapproved hit. Reuse the guard's own file-set derivation
and its exclusions, so a file it never reads is a file you never write. Dry-run first and require
your count to EQUAL the guard's; an equal count is the check that the two rules are one rule.

Then expect two further things, both findings rather than breakage:

- **A rename UNMASKS other guards.** A guard keyed on the retired vocabulary is blind to the same
  violation spelled the old way, so renaming makes it able to see a file for the first time
  (measured: a case-sensitive "this deleted write path must not return" guard had been blind to the
  incoming branch's file because that file spelled the forbidden procedure with the retired word).
  Read the new red as a discovery about the merged tree. Fix the code, never the guard — widening a
  guard to go green is the wrong direction, and a name a guard forbids can be named by ROLE in a
  comment instead.
- **Paying off a forward contract makes its exemption STALE.** A guard that asserts no exemption is
  unused will name the one you just retired; remove it, because an exemption nothing uses is a hole
  kept open. That second assertion is the reason to run the guard rather than only read the first.

Also sweep for the ARTICLES a word change breaks: "a venture" becomes "a idea".

Related: [[a-denylist-only-holds-what-someone-typed]] ·
[[replacing-a-list-with-a-glob-changes-the-set]] · [[a-mention-is-not-a-property]] ·
[[verify-claims-against-artifacts]]

**Where the guard is NEW, the equality check runs in BOTH directions.** The rule above assumes a
guard that predates the sweep. When you write the guard and the sweep together, the guard's census
is a GUESS at the rename's extent, and a census smaller than the sweep's rule is a fail-open: the
guard passes over every name nobody wrote down. Recover the true extent mechanically rather than by
reading the diff — tokenise both sides of the sweep's own commit and difference the token multisets,
which names exactly what moved that the census never mentioned (measured: a census of 21 exported
identifiers accounted for 29 of 50 changed files, and tokenising found **30 more compound
identifiers** the rename had legitimately moved, each one real).

Admit a recovered name to the census on one mechanical test — **zero surviving occurrences anywhere
in the corpus** — and never on inspection. A name that still occurs somewhere is being used in a
RETAINED meaning too, so pinning it reddens correct code and the documented repair for a guard like
that is to switch it off (measured: of 30 recovered names, 28 were admissible and 2 were not —
`byLane` survived in twelve files of a different meaning). Record the inadmissible ones in a named
constant with an assertion holding them OUT of the census, and state the bound that leaves open, so
a later reader cannot "complete the list" and reintroduce the hole. Re-derive the admission rule
inside the test against the live tree, or it decays into a comment.

**A sweep that failed on SCOPE is salvageable by two mechanical fences, and reading its hunks by
hand is the wrong repair.** Scope is exactly what a machine can check. Build a PATH fence from the
guard's own corpus derivation, and a CONTENT fence that strips the renamed word family from both
sides and demands byte equality, protecting any name the rename must NOT touch so a violation shows
up as residue rather than passing. What survives both fences needs no hand review; only the residue
does (measured: a quarantined `--write` run's 96-file commit split into 48 in-fence files, 46
discarded — memory-index ARCHIVES, past review verdicts, handoffs — and of the in-fence files 29
were provably confined to the word family, with the residue turning out to be the census gap above
rather than defect). Diff against the sweep's own START_SHA, not your current head, or the base
mismatch reads as the sweep having edited files it never touched.

**A guard that scans a corpus should make git find the candidates.** Reading every corpus file into
the test process is the whole cost and it grows with the census; asking `git grep -l -w` which files
can hold a hit does not (measured, 2,208 files / 38.7 MB: reading all of them 8.3 s, tokenising all
of them 0.64 s, a 49-name `includes` gate 0.83 s, one `git grep -l -w` **1.06 s** — and the slow
shape had already tripped vitest's 30 s per-test default at 35.6 s under parallel load). Make that
gate fail CLOSED, because `git grep` exits 1 for "no matches" and non-zero for a broken scan, and
reading an error as an empty result makes every assertion pass vacuously. Give it a positive control
in both directions, since a gate that decides which files are read at all is a fail-open surface.
And when you prove the guard arms with a mutant, read the LINE it reports: a comment stripper that
DELETES comments collapses the file and names the wrong line, so blank them instead.
