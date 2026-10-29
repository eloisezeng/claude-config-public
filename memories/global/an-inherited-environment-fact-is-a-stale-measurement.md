---
name: an-inherited-environment-fact-is-a-stale-measurement
description: A handoff's "environment facts (measured <date>)" block — and its "this has not shipped yet" — is the predecessor's reading, so re-run any of it you are about to repeat in a deliverable or build on, otherwise you publish their stale measurement under your name or rebuild shipped work.
metadata:
  type: feedback
  scope: global
---

Every line in a brief's environment block is a MEASUREMENT with an author and a timestamp, never a
constant. Re-run any of it that reaches an outward-facing deliverable, and re-run it before quoting
it back to the user. The cost of not doing so is asymmetric: the claim arrives with your name on it,
and the reader is usually the one person who can disprove it in one click.

**Why:** a handoff's environment facts read as settled ground truth because they are stated as
facts, in the imperative register of the rest of the brief, often with a "measured <date>" stamp
that makes them feel checked. Nothing in them is self-checking, and a successor's reflex is to build
ON them rather than TEST them, so a wrong one propagates into every deliverable the lane produces
(measured 2026-10-17: a brief said "production, staging and the sandbox answer 403 from this
machine"; production actually answered 200, serving a "Coming soon" holding page on every path,
while only staging was refused — the conclusion drawn from it happened to hold, but a published
report told an external stakeholder that a site he could load himself was refusing us).

**How to apply:** before repeating an inherited access, reachability, credential or version fact,
run the one command that settles it, and expect the real picture to be composite rather than
uniform — "all three are refused" collapsed into one refused host, one host serving a placeholder,
and a working VPN. State which reason applies to which host. When the predecessor's claim proves
wrong, correct the deliverable in place and record the measurement in the lane, including the part
of their claim that held.

The most expensive member of this class is the inherited NEGATIVE: "nothing has shipped from this
yet", which buys a whole duplicate arc rather than one wrong sentence. An absence claim needs a
probe that could see presence, and a word-grep over PR titles is not one — so settle it in the
ARTIFACT (does the file exist at `origin/main`? does the merged PR exist?) and read the brief's own
pointer document, which is where the refutation usually already is (measured 2026-10-29: a brief
said "no merged PR title mentions search as of 2026-10-28, but verify in code", and the lane it
pointed at recorded the whole arc SHIPPED six weeks earlier under PR #55, titled "Make *searching*
a department code…"; the right deliverable was not the build but a re-proof that the shipped
feature still worked on today's tree — 136 assertions and five live queries). Related:
[[absence-needs-a-probe-that-could-see-presence]] · [[verify-claims-against-artifacts]] ·
[[fetch-before-you-diagnose]] · [[start-local-runs-from-a-saved-copy-of-live-settings]]
