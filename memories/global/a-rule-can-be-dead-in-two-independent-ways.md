---
name: a-rule-can-be-dead-in-two-independent-ways
description: An entry in an ordered rule table can silently never fire for two INDEPENDENT reasons — an earlier broader rule consumes its stem, and its KIND refuses at the site — so fixing the ordering alone reads as a fix and changes nothing; prove a rule fires by running the transform on the real line.
metadata:
  type: feedback
  scope: global
---

In any ordered substitution table (sanitizers, redactors, routers, lint autofixers) a rule that looks present can be dead, and the two causes stack:

- **Shadowing.** A broader rule earlier in the list consumes the stem. A specific rule sitting *below* the generic one it refines never sees a match.
- **Kind refusal.** The rule's own matching mode declines at that site. A `word`-style rule that requires the match not be part of a longer identifier-shaped run refuses inside `Name/other-name`, reporting the site as *guarded* rather than applying.

Measured 2026-09-04: a specific org-name rule sat ~40 lines below the generic rule that consumed its stem, so the mirror published a stand-in that still carried the real name's suffix, in six already-published files. Moving it up — the obvious fix, and the one the table's own "most specific first" comment prescribes — changed the output not at all, because every occurrence was inside a path and the rule's kind refused there. It had to change kind as well. Two edits, one of which was invisible on its own.

**Why:** the fix for cause 1 is verifiable by *reading* (the line moved), which is exactly why it gets trusted. Cause 2 is only visible by running the thing. A half-fixed rule is worse than an absent one: it now looks handled in review.

**How to apply:**

- Prove a rule fires by **executing the transform on the real offending line** and diffing the output — never by reading the table. Import the module and call its transform in three lines; that is the whole cost.
- When a table reports **guarded / skipped / refused** sites, read that report. It is the kind-refusal signal, and it is usually printed right next to the success line that says everything passed.
- After fixing, re-run the pipeline and count the files that CHANGED. A shadow fix that corrects already-published output should move more files than the one you were looking at — six here, not one. A fix that moves exactly the file you tested has probably only moved that file.
- A verify pass over a hand-kept forbidden list cannot catch this: the output no longer contains the forbidden token, only a mangled stand-in built from it. Same class as [[a-denylist-only-holds-what-someone-typed]].

Related: [[verify-claims-against-artifacts]], [[a-mention-is-not-a-property]], [[absence-needs-a-probe-that-could-see-presence]].
