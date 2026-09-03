---
name: an-event-loop-bound-timeout-accuses-the-network
description: A DNS/TLS/socket timeout fires off the event loop, so a blocked loop reports ETIMEOUT on a perfectly healthy network — measure the dependency separately and reproduce under a deliberately blocked loop before believing the accusation
scope: global
metadata:
  type: feedback
---

An `ETIMEOUT` / `ETIMEDOUT` names the thing that did not answer in time, and reads like a verdict about it.
It is not.
Node's c-ares resolver (`new Resolver({ timeout, tries })`) and `socket.setTimeout` — and every `setTimeout`-derived deadline — are armed **on the event loop**.
A loop blocked past the deadline fires them spuriously, so a dependency answering in 33 ms is reported as having timed out.

**Why:** the accusation and the real fault live in different processes, and only one of them is yours.
Believing the message sends you to the network, the DNS provider, or the peer's TLS stack — none of which will show anything wrong, because nothing is.
Anything synchronous and slow in-process is a candidate blocker: a synchronous DB driver (better-sqlite3) against a large file, a big JSON parse, a tight CPU loop, or simply another process winning the CPU on a shared box.

**How to apply:**
- **Measure the dependency on its own**, from the same host, at volume — not once. (Measured: 0 failures in 320 DNS lookups from the box, slowest 33 ms, for the exact name a production gate had just refused as `queryA ETIMEOUT`.)
- **Reproduce with the loop deliberately blocked**, and vary the block: it is the diagnosis, and it doubles as the pinning experiment. (Measured: `tries:1` + a 3000 ms block → all four lookups ERR ETIMEOUT; `tries:3` + the same block → all four ok. TLS `timeout:2000` + a 3000 ms block → ERR; + 0 ms → ok.)
- **Retransmit, don't widen.** More `tries` survives a blocked loop; a longer `timeout` just moves the cliff and slows every genuine failure.
- **Scope the retry to the transient class only.** Retry a handshake *timeout*; never retry an unauthorized chain, an expired certificate, or an identity mismatch — those must still fail on attempt 1, or the retry has weakened the gate instead of steadying it. Give the transient case its own error type so the predicate cannot drift into catching verdicts.
- **Compare the checker against the sweep it re-checks.** A gate built with `tries: 1` while the population sweep used a bare `new Resolver()` (Node's default 4) is strictly stricter than the thing that declared the item ready — that asymmetry alone manufactures failures. Derive both from one constant.
- **Isolate per-check failures.** One `try/catch` around a `Promise.all` of independent probes lets the first thrown one mask the rest, discarding real findings the other legs made and reporting a message that names no subject. Attribute each result to its own check.

Related: [[wall-clock-ceilings-measure-the-machine]] (the test-side form of the same confusion), [[verify-claims-against-artifacts]], [[a-control-must-match-the-probes-shape]].

Measured: 0 failures in 320 lookups, slowest 33 ms, for the very name a `tries:1` gate had just refused. The c-ares form is `new Resolver({timeout, tries})`; the blocking work was a sync DB driver on a big file and a co-located process winning the CPU. A handshake timeout is the only retryable class — an expired cert or an identity mismatch still fails on attempt 1, or the retry has weakened the gate.
