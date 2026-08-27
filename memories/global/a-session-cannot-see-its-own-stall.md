---
name: a-session-cannot-see-its-own-stall
description: "A rate-limit or transport stall writes NO turn, so it is invisible from inside the conversation — never assert your own continuity; measure wall-clock gaps between transcript timestamps instead"
metadata: 
  node_type: memory
  type: feedback
  scope: global
---

A rate-limit stall (or any pause between turns) records nothing.
The conversation resumes exactly where it left off and reads as continuous, because the missing minutes produced no text to notice the absence of.

**So "I never stopped" is a claim a session is structurally incapable of making.**
Reproduced 2026-08-21: I told a peer flatly that I had not been rate-limited; my own transcript then showed a **38.6-minute** hole (17:56:34Z → 18:35:09Z) ending on the `queue-operation` record of that peer's nudge.
Nothing in my context marked it, and nothing could have.
This is [[absence-needs-a-probe-that-could-see-presence]] turned on yourself: the probe was introspection, and introspection has no discriminating power over an interval in which nothing was written.

**Why:** `detail` in `~/.claude/jobs/<short>/state.json` is stale text and can latch (a session reading `blocked` with `needs: null`, `tempo: active` and a transcript record thirty seconds old is WORKING, so never nudge or kill on that word), and a session's own memory of "what I was doing" carries no clock at all.

**How to apply.** Liveness — yours or anyone's — is a wall-clock question answered from the transcript, never from the flag and never from recollection:

```python
rows = sorted(json.loads(l)['timestamp'] for l in open(path) if '"timestamp"' in l)
# report every adjacent pair more than N minutes apart
```

Expect legitimate multi-minute gaps for long tool calls (a full test suite shows up as 5–8 minutes); a stall is an order of magnitude larger and resumes on an external event.
When a peer reports your stall, reproduce it against your own transcript before agreeing OR disagreeing — and when the artifact refutes you, correct the record wherever the wrong claim was sent, not only where it was written ([[re-read-cannot-tell-wrong-from-acted-on]], [[verification-claims-are-earned-per-item]]).
