---
name: a-redirect-location-has-two-surfaces
description: A framework may PARSE a redirect's Location rather than forward it — so the value the handler RETURNS and the value on the WIRE differ, and a test asserting one against the other pins a bug
metadata:
  type: reference
  scope: global
---

A redirect's `Location` can exist on **two different surfaces**, and conflating them shipped a
2h22m total outage on your-other-project (2026-08-30, PR #325):

| surface | value | why |
| --- | --- | --- |
| what the handler RETURNS | `https://host/login?next=%2F` — **absolute** | Next parses it with `new URL(value)` and **no base**; a relative value throws `ERR_INVALID_URL` *inside the framework* |
| what goes out on the WIRE | `/login?next=%2F` — **relative** | Next re-serialises a same-origin redirect on the way out |

Both are correct. The bug was a middleware hand-building `new NextResponse(null, {headers:{location:
target}})` with a relative `target`: **every** logged-out request answered 500 while all 17 required
checks were green and the deploy reported success.

**The unit test could not see it, and no care in that file would have helped** — it called
`middleware(req)` and asserted the returned `Response`, which *cannot exhibit the failure* because
only the server ever parses that header. The strongest-looking assertion (a byte-exact snapshot) was
the one pinning the bug.

Three consequences, each of which cost something:

1. **Scope matters, not just the framework.** In Next, a *route handler's* `Response` goes out
   verbatim — only *middleware* responses get the `new URL()` parse. So relative Locations in route
   tests are correct and NOT in the defect class. Enumerate by surface, not by grep.
2. **A guard must drive the real surface.** Pin it with a real server request (`next dev` needs no
   build), not the exported function — [[verify-claims-against-artifacts]].
3. **Verify on the wire.** The incident handoff told the successor to confirm the fix by looking for
   an *absolute* Location live; that criterion would have scored the **working** deploy a failure.

Generalise: whenever a framework interprets a value rather than forwarding it, ask which surface
your test asserts and which one the user meets. Related: [[a-mention-is-not-a-property]],
[[fix-the-class-not-the-reported-instance]].
