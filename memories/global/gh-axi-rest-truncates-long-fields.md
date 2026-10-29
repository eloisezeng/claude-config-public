---
name: gh-axi-rest-truncates-long-fields
description: "gh-axi's REST renderer silently truncates long string fields (~2KB), so any absence-check on a PR/issue body through it is structurally blind — use GraphQL"
metadata: 
  node_type: memory
  scope: global
  type: reference
  originSessionId: 33c28db7-11e2-401e-a805-cdcabc6dac07
  modified: 2026-08-26T19:14:53.911Z
---

`gh-axi api <rest-path>` renders responses as YAML and **silently truncates long string values at
roughly 2 KB**, with no marker, ellipsis, or warning.

Measured 2026-08-26 on `repos/kunchenguid/lavish-axi/pulls/295`: a body of **36,527 B** rendered as
**2,017 B**, and the whole PR object as **3,313 B**. `grep -c 'no-mistakes-pipeline-attestation'` over
that raw response returned **0** on a PR that *did* contain the marker. `gh-axi pr view` truncates too
(926 B for the same PR). The truncation is per-field, so short fields (`state`, `conclusion`, `sha`,
`updated_at`) are trustworthy and long ones (`body`, `description`, log text) are not.

**Use GraphQL for any long field** — it does not truncate:

```
gh-axi api POST graphql --field query='query{repository(owner:"O",name:"N"){pullRequest(number:N){body}}}'
```

`userContentEdits(last:N){editedAt editor{login} diff}` is the same route's bonus: it recovers **prior
versions of a PR/issue body**, which is how a body clobbered by a bot gets restored verbatim.

The trap is that the failure presents as a *confident zero*, and a zero is what an absence-check is
looking for — so it reads as evidence rather than as a broken instrument. It nearly produced a
retraction of a correct peer claim ("the attestation is not there") that was arithmetically argued from
the truncated byte count. Control-test the probe against a known-present case before trusting a zero —
`[[absence-needs-a-probe-that-could-see-presence]]`, `[[re-read-cannot-tell-wrong-from-acted-on]]`.

**Same class, second instrument: `gh-axi`'s OUTPUT SHAPE is not `gh`'s.** It prints YAML-ish
`key: value` / `checks[17]{name,conclusion}` blocks, not `gh`'s tab-separated rows, and it **ignores
both `--json <fields>` and `--jq`** — handing back its own full record instead of erroring. Measured
2026-08-28: a CI poller grepping `^\S+\s+(pass|fail|pending)` matched **nothing** for 90 iterations
and reported `pass=0 fail=0 pending=0` — indistinguishable from "all green". Only an incidental
`TOTAL > 0` guard stopped it declaring success on the first empty read.
So: never scrape `gh-axi` with a regex written for `gh`, and give every poll loop a blind-probe arm
(`if [ -z "$STATUS" ]; then exit 3; fi`) plus an identity arm (the SHA it read must equal the SHA you
expect) — a poller with no blind arm cannot distinguish "done" from "read nothing".

The `--jq` half of that recurred 2026-10-09 in a shape worth naming: a stall watcher counting
`[ "$(gh-axi api .../check-runs/<id> --jq '.status')" = "completed" ]` compared the WHOLE record
against one word, so it answered "not done" on every poll and would have read `0/2` straight through
both jobs finishing. A settle detector built this way fails in the silent direction — it looks
exactly like work still running, forever. The fix is one grep against the real printed shape
(`^status: `), and the test is a POSITIVE control: a check-run known `completed` must read done,
because the in-progress arm alone passes for a predicate that can never say yes —
`[[control-a-settle-detector-on-captured-output]]`, `[[a-guard-must-be-satisfiable-not-just-failable]]`.

**Indent depth depends on the SHAPE of the response, and a grep that assumes one depth silently returns nothing.** Measured 2026-08-30, twice in one session: `gh-axi api repos/.../actions/runs/<id>` prints a single object's fields at **zero** indent (`id:`, `status:`, `head_sha:`), while a LIST response indents item fields (`- id:` on the list-item line, nested objects deeper). So `grep -E '^\s+status:'` matches nothing on a single-run read, and the watcher polls blind forever printing empty values that read as "not started yet" rather than as a parse failure — the second time, it cost a full background watcher that had to be killed and re-armed. Read the raw head of the response once and write the grep against what it actually prints; make an empty extraction FAIL LOUDLY rather than loop.

**`run list --branch <b>` does not order by recency.** Measured 2026-09-04 on
`your-org/your-other-project`: seconds after a merge, `gh-axi run list --branch main --limit 8`
returned runs from **27–29 days ago** as its eight newest rows, with the just-created run absent
entirely. The same moment, `--workflow=<file>.yml` returned the new run as row 1 (`just now`), and
`api "…/actions/runs?head_sha=<sha>"` returned exactly the two runs pinned by that commit. So when
you need the run YOUR push triggered — which is the only run worth watching
(`[[watch-the-run-you-triggered]]`) — select it by `head_sha` or by workflow, never by branch plus
recency. A branch listing that silently omits the run you are looking for is the same confident-zero
failure as the truncation above.

**The truncation also eats JOB LOGS and ARTIFACT DOWNLOADS, and GraphQL is NOT the route for
those — plain `gh` is.** The prescription above sends a reader to GraphQL, which has no endpoint for
either, so following it on a CI diagnosis dead-ends. Measured 2026-10-28 on
`your-org/your-other-project` run `40766022076`: `gh-axi api .../actions/jobs/<id>/logs` returned
**4,131 B** where `/opt/homebrew/bin/gh` returned **71,669 B** — and the 4 KB held only the runner's
boot banner, so the entire cause of the failure (a `next dev` memory-threshold restart, named in the
dev-server output tail) was invisible. `gh-axi run view <id> --log-failed` returned **zero lines
mentioning the failed e2e job at all**, which is the confident-zero shape again: it reads as "that
job printed nothing" rather than as "this client dropped it". The artifact route is worse because it
corrupts rather than shortens: `gh-axi api .../actions/artifacts/<id>/zip` wrote **9,838 B** of a
**1,189,962 B** zip, and `file` called the result `data` rather than reporting a truncated archive.
`gh run download <run> --name <artifact> --dir <d>` fetched all 2.6 MB correctly.

So for anything whose payload is LARGE or BINARY — job logs, artifact zips, trace files — use plain
`gh` (check `gh auth status` and confirm the ACTIVE account can read the repo; a wrong account 404s
identically to "absent"). Keep `gh-axi` for the short structured fields it renders faithfully.
A corollary worth holding onto: a CI red you cannot explain may be a red you cannot READ, and the
instrument is the first thing to rule out — `[[a-tail-window-is-not-a-failure-report]]`.
