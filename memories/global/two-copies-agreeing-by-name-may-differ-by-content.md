---
name: two-copies-agreeing-by-name-may-differ-by-content
description: "Two copies of a store that agree by file NAME prove nothing about agreeing at all — hash every member, and on a shared multi-writer store order the versions by the version-control dates rather than by mtime"
metadata:
  node_type: memory
  type: feedback
  scope: global
  originSessionId: b32bfaea-8458-4102-a574-f875bcf45917
---

When you reconcile two copies of a store — a tracked tree against a working checkout, a mirror against its source, a backup against the live directory — **a comparison by file NAME is blind to the divergence you are actually looking for.** Equal counts with nothing one-sided is the reading that feels like agreement and carries none of it.

**Measured 2026-09-12.** I compared a 275-file memory store against its shared working checkout by name and reported 275 against 275 with nothing missing on either side, which I treated as licence to copy one over the other. A sha256 comparison of the same 275 files then found **five whose bytes differed**, one of them the body of the longest entry in the index I was repairing. Re-running the comparison immediately before the copy rather than trusting the earlier list found a **sixth**, which my own intervening edit had created.

**Why:** the one comparison that is cheap to run and easy to narrate is the one that cannot see this class, and it produces a clean-looking table. The failure is silent in both directions — a copy shadows content unique to the destination, and a "verified identical" claim survives review because nothing in it is false, only incomplete.

**How to apply:**
- Hash every member and report the count that differed, not the count that matched. `only in A`, `only in B` and `differing by hash` are three separate numbers and a reconciliation is not finished until all three are zero.
- Re-run the comparison at ACT TIME, immediately before the copy — including after your own edits, which are a writer like any other.
- Divergence usually splits BOTH ways, so do not decide in advance which side wins. Where neither version is a superset, the answer is a two-way FOLD, not a copy.
- **Order the versions by the version-control dates, never by mtime.** On a shared multi-writer store an mtime is somebody else's write: here the committed side was newer for three files and older for two. See [[re-read-cannot-tell-wrong-from-acted-on]] for the general form of that half.
- Before overwriting the longer or unresolved copy of a file, confirm what it holds is recoverable elsewhere and say where — `[[recoverable-is-not-unused]]`.
- The set-membership sibling of this rule is [[replacing-a-list-with-a-glob-changes-the-set]]: that one is about members the comparison never listed, this one about members it listed and did not read.
