---
name: a-wrong-mock-body-must-name-the-receiving-route
description: A "the mock answers the wrong shape" diagnosis is incomplete until it names the handler that RECEIVES the request — a sibling route one path segment away with a disjoint method set makes the fix a silent no-op that reads as progress; fix it once in a typed builder so the compiler refuses the sibling's shape
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When a test fails because a mocked endpoint answered the wrong body, the diagnosis is not finished at **which shape is wrong**.
It is finished at **which handler receives the request**, read off the route files rather than off the nearest line in the component.
Then build that body ONCE, in a helper that the type checker validates against the response contract, so no caller can write the sibling's shape by hand.

**Why:** A handoff handed me a diagnosis settled to the line: the press posts `/api/opened-briefs`, a single mock intercepts that path for every method and answers the LIST shape `{ user, entries }`, an unlock response is `{ userId, entry, allowance }`, so the identity check compares `undefined` against the viewer's id and the press renders a refusal instead of navigating. All of that was true about the shapes. The previous session branched that mock on `route.request().method()` and the test still failed, which it recorded as "necessary but not sufficient". It was neither: the component posts `/api/opened-briefs/<id>`, one segment down, and the two routes have **disjoint methods** — the bare route exports `GET` only and the per-idea route exports `POST` only. No POST had ever arrived at the path that was fixed. The method branch was dead code, the per-idea mock was still answering the list shape, and the failure was unchanged for exactly the original reason. Three specs mocked the per-idea route and two of them had the same wrong body.

**How to apply:**
- **Read the route files, not the fetch call's neighbourhood.** `grep "export const \(GET\|POST\|PUT\|DELETE\)"` over the route directory answers which handler can receive what. A path and its `[param]` child are different modules with different method sets, and a glob like `**/api/thing` does not match `**/api/thing/42`.
- **A fix that changes nothing looks exactly like a fix that was insufficient.** Both leave the same failure. Distinguish them by making the mock COUNT its requests and asserting the count: a handler that was never called is a no-op fix, and a handler called with the right body that still fails is genuine insufficiency.
- **Build the body in one place, typed.** `route.fulfill({ json: {...} satisfies UnlockResponse })` inside a single fixture turns the whole class into a compile error. Hand-written bodies at N call sites fail at run time, minutes later, as a navigation that did not happen — and they get the shape wrong in the same direction every time, because the sibling route's shape is the one the author just read.
- **Derive what the body implies rather than passing it alongside.** The fixture takes `userId: number | null` and derives the viewer kind from it, because a member has an id and a visitor is the absence of one; a second `viewer` parameter would let a caller mock a member's limits onto a visitor's response.
- **Enumerate the other mocks of the same route before declaring it fixed.** One grep for the path found three specs; the one that was already correct folded onto the fixture too, so there is no second author of that shape left.
- **Instrument before hypothesising when one message serves two outcomes.** The identity check threw the same sentence for an aborted request and a wrong-viewer response, so the page snapshot could not say which fired. Splitting the message — an abandoned request is worth retrying, a changed session is not — settled it in one re-run, and the split is worth having on its own terms because a reader can act on one cause and not the other.

Related: [[mocks-blind-to-the-mechanism-they-replace]] · [[unambiguous-status-and-logs]] · [[verify-claims-against-artifacts]] · [[encode-the-invariant-in-the-shape-not-another-guard]] · [[counting-a-set-is-not-classifying-it]]
