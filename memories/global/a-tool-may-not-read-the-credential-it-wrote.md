---
name: a-tool-may-not-read-the-credential-it-wrote
description: A tool's own stored credential is not a credential it reads back — flyctl v0.4.99 writes access_token into ~/.fly/config.yml at login and reads none of it, so "the token is there" and "the tool can authenticate" are different facts and re-login rewrites the ignored file; prove a credential by USING it, and separate not-found from rejected with the tool's own no-network "print what you stored" subcommand
metadata:
  type: feedback
scope: global
---

Finding the credential on disk is not evidence the tool uses it.
Measured 2026-10-29: `flyctl` v0.4.99 held a valid 665-character `access_token` in the
`~/.fly/config.yml` it had written itself, and `auth token`, `auth whoami` and `apps list` all
answered `Error: no access token available` against that very file — while the same value handed to
the same binary through `FLY_API_TOKEN` authenticated immediately.

**Separate "not found" from "rejected" before choosing a remedy, and do it without the network.**
Most such tools have a subcommand that merely prints what they stored (`flyctl auth token`,
`gh auth token`, `aws configure get`). It makes no API call, so its answer is about the READ PATH
alone: "none available" means the file is being ignored, and only a 401/`Unauthorized` from a real
call means the value was presented and refused. The two want opposite fixes — supply it, versus
replace it.

**A re-login is not the fix for the ignored case.** It rewrites the same file the tool will not
read, so it looks like a remedy and changes nothing. That the tool keeps *rewriting* that file
(mtime moving on every invocation) is a sign of this class, not a sign of health.

**So prove a credential by using it, in the first second.** A deploy or any other expensive
operation gets an authenticated no-op probe up front, beside its free refusals, and supplies the
stored value the one way the tool accepts. Both, never one: supplying it still fails silently for
every other way a credential can go absent, and probing alone leaves a manual export in the path.

**Exporting a secret for one consumer hands it to every consumer.** `export FLY_API_TOKEN` reached
every process the deploy started — including its eleven-minute browser suite, three browsers running
the app, which has no call on a token that can replace production. Scope it back off whatever does
not need it (`env -u NAME ... "$downstream"`) and assert the absence with a stub that records what
it saw. Related: [[a-fail-fast-check-is-tested-by-where-it-sits]], [[a-blocked-write-may-be-a-no-op]].
