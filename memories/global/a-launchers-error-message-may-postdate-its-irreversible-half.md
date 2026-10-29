---
name: a-launchers-error-message-may-postdate-its-irreversible-half
description: A dispatcher that writes its record BEFORE launching means a command-line error tells you nothing about whether the dispatch happened — read the record, and treat your own restart as evidence it landed
metadata:
  type: feedback
  scope: global
---

A launcher whose record is written BEFORE the irreversible step — which `handoff.sh` does deliberately, its own header saying "the record is written BEFORE the launch and updated after it, so neither a kill in the launch window nor a failed verification can leave a running successor that no record remembers" — cannot tell you from its EXIT MESSAGE whether the thing happened.
So never read a launcher's error as "it did not happen": read the RECORD, which is the artifact the design put there for exactly this question (`state=verified`, `session_id`, `retired_predecessor`, an armed `watch_pid`).

Two corollaries that are sharper than the general rule:
- **Your own process restarting mid-dispatch is EVIDENCE THE DISPATCH LANDED, not evidence it failed** — a verified dispatch RETIRES the dispatching seat, so the retire arrives as your session ending. The restart feels like the failure and is the success.
- The duplicate it invites is the expensive kind: you re-derive the plan and start building against a successor already doing it, and neither of you can see the other.

Measured 2026-10-26: I read `handoff: unknown option: --force`, concluded no successor existed, and was one tool call from implementing a build lane in duplicate — while the record showed `state=verified`, successor `085ef8ba` with my full objective verbatim, `retired_predecessor=522b8ff1`, a watcher armed at pid 23250, and the seat itself `"state": "working"` 3,602 tokens in. The context-watchdog hook told me a verified dispatch existed and I was right to distrust it against my own observation — and wrong to settle the contradiction by believing the message instead of opening the record.

This is `[[verify-claims-against-artifacts]]` on the dispatch path, and it is also the inverse of `[[a-handoff-doc-must-not-assert-a-drop-it-has-not-made]]`: that rule stops you CLAIMING a handoff you have not made, and this one stops you DENYING one you have. Both are settled from the record, never from prose or from a message. See also `[[the-injected-lane-marker-can-name-a-sibling-lane]]`, which is the other thing on this path you cannot read off the obvious surface.

Reproduced 2026-10-27 with a second shape, which pins the mechanism rather than the one message:
`handoff.sh`'s dispatch options are parsed AFTER the positionals, so `--force` placed before the
file dies as `unknown option: --force` — and the correct spelling is
`handoff.sh <file> --force -- "<objective>"`. **Whether that death lands before or after the
launch is NOT uniform**: once it died after the launch had already happened, and once
(2026-10-26, a duplicate-check refusal naming the caller's OWN seat, then the same flag
mispositioned) it died in the parser with the record's mtime provably unmoved and exactly one
`session_uuid` in it. So the message is uninformative in BOTH directions, which is the rule
rather than a weakening of it — read the record, and settle a possible launch by the record's
mtime plus its `session_uuid` lines, never by the exit text. The
duplicate-check refusal that sends you to `--force` does not say where to put it. The record read
`state=verified`, a real `session_uuid`, an armed `watch_pid` and `retired_predecessor=<me>`, and
my own process had exited, which IS the retirement. Put the flag after the objective, and read the
record, never the message.
