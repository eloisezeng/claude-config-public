---
name: sftp-put-refuses-an-overwrite-and-exits-zero
description: `fly ssh sftp put` refuses to overwrite an existing remote path AND still exits 0, so the run that follows executes the OLD file — compare the landed byte count, or give every upload a content-hashed remote name; `tee` over `fly ssh console` overwrites cleanly
metadata:
  type: reference
  scope: global
---

Uploading a probe or a repair script to a live box and then running it is a two-step act whose first step can silently do nothing. `fly ssh sftp put <local> <remote>` **refuses to overwrite an existing remote path and exits 0 anyway**, so the second step runs whatever was already there. The failure is invisible in every signal an unattended session normally checks: the exit status is 0, the upload prints no error, and the run produces plausible output — from the previous version of the script.

That is the worst shape a step can have, because the natural iteration loop (edit the probe, re-upload, re-run, read a number) then reports the FIRST version's answer for every subsequent round, and the numbers look stable because they are literally the same run.

Three ways to close it, cheapest first:

- **Compare the landed byte count to the local one.** A probe uploaded at 3,884 bytes local and confirmed 3,884 bytes on the box is the check that matters, and it is one extra command.
- **Give every upload a content-hashed remote name** (`/app/probe-<sha12>.ts`), so an overwrite is never attempted and the name proves which bytes ran.
- **Write the file with `tee` over `fly ssh console` instead**, which overwrites cleanly.

Two further facts about the same surface. Uploads do **not survive a machine replacement**, so anything uploaded before a deploy is gone after it — upload AFTER the deploy you mean to probe. And `fly ssh` picks a machine PER INVOCATION, so an upload and the console call that runs it can land on different machines; pass the same explicit `--machine <id>` to every call in the sequence, and read that id byte-exact rather than off colourised stdout — `[[handoff-session-id-ansi-poisoning]]`.

Note the two spellings are different subcommands: `fly sftp shell` takes its commands on **stdin** and never `-C`, while the flag-taking form is `fly sftp put <local> <remote>`.

Related: `[[verify-claims-against-artifacts]]`, `[[watch-the-run-you-triggered]]`, `[[absence-needs-a-probe-that-could-see-presence]]`, `[[unambiguous-status-and-logs]]`.
