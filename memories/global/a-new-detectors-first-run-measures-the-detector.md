---
name: a-new-detectors-first-run-measures-the-detector
description: A new detector's first full run is mostly about the detector, so classify its output by CAUSE with counts and fix the tool before reading one finding as being about the subject
metadata:
  type: feedback
scope: global
---

The first full run of any new detector — an exploratory bug finder, a linter, a scanner, an audit, a review panel — measures the DETECTOR, not the subject.
Treat its output as a measurement of the tool: group every finding by CAUSE, report the count per class, and fix each tool-side class before reading a single finding as being about the product.
A report whose volume is its own false positives is a report nobody will trust a second time, and the classes are invisible one finding at a time: they only appear as counts.

**Why:** measured 2026-10-17 on an exploratory UI bug finder's first full local run — 2204 findings in 170 signatures, of which four of the six largest classes were the finder's own:

- 460 flash findings were RE-RENDERS. An element's identity was a path of tag names and child indexes, so any re-render retired the old key and read exactly like text that disappeared. Any "this vanished" rule over a structural key has a false-positive floor equal to the re-render rate; judge a disappearance against the whole document's FINAL state instead of one element's history.
- 124 form findings were the page's own background requests. The watcher was attached across the page LOAD, so ambient failure was attributed to the submit. When measuring what an action caused, start observing after the system reaches steady state.
- 24 accessibility findings came from inside a third party's iframe. Derive the exclusion from the page (mark cross-origin frames from the document itself) rather than naming hosts, so a new embed is excluded the day it is added and same-origin frames — the product's own pages embedded in itself — are still scanned.
- 2 navigation findings were the test's own degenerate case: a round trip from the home page to the home page lands on the tab's blank starting point.

After the four fixes the same checks gave 26 signatures, and every surviving class was a real candidate.

**How to apply:** before reporting a new detector's findings to anyone, print a signature-or-cause histogram and read it top-down, asking of each class "is this about the subject or about my instrument?".
Fix the instrument classes, re-run, and quote both numbers (170 groups → 26) — the drop is the evidence the report is worth reading.
Two further classes live in the REPORT rather than the checks: a finding that spans many pages must not be headed by the first of them, and a similarity matcher fed a long path list matches almost anything, so match on the message once a glitch spans more than a few pages.
Related: [[counting-a-set-is-not-classifying-it]], [[verify-claims-against-artifacts]], [[a-fixture-helpers-default-pins-the-swept-axis]].
