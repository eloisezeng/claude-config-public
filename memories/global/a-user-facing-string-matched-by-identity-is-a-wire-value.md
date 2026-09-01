---
name: a-user-facing-string-matched-by-identity-is-a-wire-value
description: A human-readable string that crosses server to JSON to a client that identity-matches it is a WIRE VALUE; judge reword findings by reachability, and know no server-side change reaches an already-loaded bundle
metadata:
  type: feedback
  scope: global
---

When a message is thrown server-side, serialized into a response body, and recognized in the browser by exact-value comparison, it stopped being copy — it is a wire value with two readers in **different processes**. Within one build the chain is pinnable end to end (throw site → body byte-equal → client returns it verbatim) and a reword is safe. Across a deploy it is not: a tab loaded before the machine is replaced holds the old set, fails the identity test, and falls back to the generic message until it reloads.

**Why:** a reviewer will file this as a defect, and the mechanism is real — but the two things that decide it are not in the mechanism. **(1) Reachability:** ask whether the *old* spelling was ever deployed. If the whole feature is unmerged, no client holds it and the instance cannot occur — measured once by `git grep` at `origin/HEAD` returning zero references to the constants and the module being absent there. **(2) The remedy space is empty:** an already-loaded bundle is frozen code, so nothing the server does reaches it. A stable error code does not help a client that never reads the field; keeping the old string on the wire pins retired wording into the API forever and needs a growing legacy map per reword. The honest disposition is therefore to decline the code change and accept the **fact** — because such a finding usually also exposes a document claiming the reword is "copy only, no behaviour", and that doc is the side that is wrong.

**How to apply:** before authoring a fix or a test, check which hops are already pinned — a test asserting the response body byte-equals the exported constant covers the hop that actually drifts. Do not write a regression test for the cross-deploy half: it could only assert that an old string is *not* recognized, i.e. assert the defect. Put the caveat where a future re-worder looks (the comparison site), ending in the operative instruction: reword freely, do not add a legacy-spelling map. Related: [[fetch-before-you-diagnose]] · [[codex-parallel-lenses-beat-serial-rounds]] · [[verify-claims-against-artifacts]]
