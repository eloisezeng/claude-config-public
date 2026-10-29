---
name: a-gated-helper-is-wrong-on-a-public-route
description: The first PUBLIC write into an app whose other writes are gated inherits every gate-shaped assumption of the helpers it reuses — audit the reused helper against the new caller's AUDIENCE, not against its current behaviour
metadata:
  type: feedback
  scope: global
---

Adding the FIRST unauthenticated write to an application whose other writes sit behind a sign-in gate is not "one more route".
Every helper, grant and idiom it reuses was written for a caller who had to identify themselves first, and each carries that assumption invisibly.
Reusing them is the defect, and the reuse looks like consistency — which is exactly why review praises it.

Measured on one 33-file branch: three separate security findings, raised in two rounds by two reviewers, were ONE root cause wearing three costumes.

- **Disclosure.** The repo's `errorMessage(error, fallback)` discloses the error's message, code and the principal and server a login failure names wherever `SHOW_ERRORS` is on — and it is on unless explicitly `"false"`, `"0"` or `"off"`, production included. Correct behind a member gate, where the caller is a known person. On a public route it hands the database's shape to anyone. The sibling member-gated route I had just written had the same bug, found only because I went looking for the class.
- **Integrity.** The idiomatic upsert (`UPDATE … WHERE <natural key> = @key`, INSERT if no rows) is correct for a member's own row, where the gate proves the key is theirs. On a public write the key is whatever the caller TYPED, so an UPDATE lets anyone rewrite the row belonging to any key they can guess, with no account and no trace. The fix is shape, not validation: INSERT-only, append-only, first submit wins, with the migration REVOKING `UPDATE` and `DELETE` so no privilege exists to misuse.
- **Cost.** `await request.json()` buffers the whole body before any field rule can look at it. Behind a gate the cost is bounded by who got in; on a public route the caller chooses it, and a 50 MB body whose two recognised fields are three characters long passes every rule in the handler. Bound the BYTES READ in chunks, never Content-Length, which the caller writes.

**The question to ask at the moment you write `withAccess("public", …)` or its equivalent:** for every helper, grant and pattern this handler reuses, who was the caller it was written for?
Then re-read each one as if a stranger were calling it. Reach for the app's own precedent FIRST — mine already had the bounded chunked read in a logging route, so the fix was to EXTRACT it and share one implementation, not to write a second copy of the loop (`[[the-product-may-already-own-the-write-path]]`).

Two corollaries learned the same day.

A test asserting `typeof answer.error === "string"` is satisfied by the DISCLOSING version, so it passes for the wrong reason and the weak assertion is what let the finding through for a whole review round.
Assert the fixed sentence and sweep the error's parts (the message, the code, a sentinel secret) — `[[plan-assertions-need-reachable-alternatives]]`.

A guard spelled as "the handler must not MENTION `errorMessage`" FAILS on the correct fix, because the fixed handler's own docblock names the helper to explain why it is not used.
Strip comments first, assert the IMPORT as well as the identifier, and carry a positive control proving the stripper did not empty the file — `[[a-mention-is-not-a-property]]`.
