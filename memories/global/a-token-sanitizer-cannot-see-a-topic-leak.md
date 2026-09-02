---
name: a-token-sanitizer-cannot-see-a-topic-leak
description: a publication pipeline that default-INCLUDES publishes every new paragraph the moment it is written, and a token sanitizer passes clean on a paragraph that still describes unreleased product work — ask "does this publish?" at WRITE time and withhold the whole file, never half-sanitise it
metadata:
  type: feedback
  scope: global
---

So writing a file, or adding a paragraph to an existing one, publishes it — nobody has to opt it in, and the sync is the only moment anyone looks.

The sanitizer rewrote the repo name to a placeholder and reported **"verify pass: zero forbidden tokens survived."**
The paragraph was still a readable account of private product work.
Caught only by an independent topic grep over the staged tree before the push, not by the pipeline.

**Why:** a token sanitizer is a string substitution. It is blind to what a sentence is ABOUT.
It can only certify that no listed identifier survives — never that the content is publishable.
Every clean verify pass is an argument about tokens that reads like an argument about safety.

**How to apply:**

- Ask "does this publish?" while WRITING, not at sync time. A default-include pipeline has no other gate.
- Withhold the whole file rather than half-sanitising it. A doc whose general half is publishable and whose appendix is not goes on the exclude list entire, with the reason written next to it.
- Before any publish, run an independent grep for TOPICS (customer names, product status, secret key names, open PR numbers) over the staged tree, not just the diff — and classify each hit as pre-existing or newly added by this sync, since only the new ones are yours.
- Never treat the sanitizer's own verify pass as the publication gate — `[[verify-claims-against-artifacts]]`, `[[absence-needs-a-probe-that-could-see-presence]]`.
- The mirror NEVER deletes, so a file that should go is a deliberate hand-made commit — `[[recoverable-is-not-unused]]`.
