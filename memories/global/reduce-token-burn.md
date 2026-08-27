---
name: reduce-token-burn
description: "Token-frugal defaults — extract values via sandboxed execution not full Reads; derive once and persist with pointers; read only the span you'll edit; trust derivation scripts; batch authorized chains"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When reading a structured file (JSON, CSV, HDF5 metadata, log) only to extract specific values, run a sandboxed extraction (context-mode `ctx_execute`/`ctx_execute_file`, or a python/shell one-liner that prints just the values) instead of the Read tool — raw bytes stay out of the conversation.

**Why:** reading a full metrics.json to pull one field burns ~80× the tokens of the answer; one harvest session did this 6+ times per cell.
The subtler cost is **re-derivation**: recomputing the same aggregate across many turns because it was never written down anywhere citable.

**How to apply:**
- Extracting values from data files → sandboxed execution; multiple files → batch it.
- **Derive once, persist with pointers.** When a derived fact will be read again — by you after a compaction, by a delegate, or by a document — write it to disk *with the pointer it came from* rather than recomputing. Better still, make the emitter produce it, so it is traceable rather than asserted.
- **Read only the span you will edit.** For a large file whose bulk is boilerplate (appendices, generated blocks), get the structure with a sandboxed scan and Read only the prose you are changing.
- Reading a file you are about to Edit → still Read that span (Edit needs exact bytes).
- Trust the derivation script over its inputs: if a script already aggregates raw files into a table, run it once and quote its output — don't separately Read the N inputs.
- Don't re-render a table already printed in the conversation; state the new insight or delta.
- `grep -nA N <anchor>` beats a full Read for "show me §X of the runbook".
- Prefer `/clear` or a handoff over `/compact` between fully-done task pivots ([[handoff-at-boundaries-saves-tokens]]).
- Batch authorization-gated steps: if you greenlit "edit → commit → push", do the whole chain in one turn without intermediate "want me to…?" round-trips.
- Check the guard/validator BEFORE authoring against it. Writing first and discovering the linter refuses your central claim costs a full rewrite cycle plus a misdirected debugging round.
