---
name: codex-opinion
description: Get Codex's independent opinion on what Claude just said — one call, no convergence arc. Use when the user asks "what's codex's opinion", "ask codex", "does codex agree", "second opinion on that", "have codex check this", or otherwise wants Codex to weigh in on a claim, recommendation, diagnosis, or disposition Claude has just given. For a full build/fix/audit with the brainstorm→spec→plan→execute→review loop, use codex-converge instead — this skill is deliberately the small one.
---

# Codex's opinion, in one call

`codex-converge` owns the whole arc and is 500+ lines of protocol.
This skill is for the moment the user reads a Claude answer and wants a second pair of eyes on
**that answer** — nothing more.

## The rule that makes this worth doing

A second opinion is worthless if it ratifies.
Every prompt this skill sends must tell Codex to **disagree if the reasoning is wrong**, must ask
for **the strongest argument against its own recommendation**, and must ask **what has not been
checked that could flip the answer**. That last question is where the value has actually come from
in practice.

## Steps

1. **Write the claim to a file.** The substance of the response under review — verbatim, not a
   paraphrase, and including the reasoning, not just the conclusion. If Claude verified something,
   say what was verified and how; Codex must be able to tell claim from measurement.

2. **Run it:**

   ```bash
   ~/.claude/skills/codex-opinion/ask-codex.sh <claim-file> [--tier luna|sol|terra] [--workdir DIR]
   ```

   Defaults: `luna` at `high` effort, workdir `$PWD`, read-only sandbox, verdict and log under
   `${CLAUDE_JOB_DIR:-/tmp}/tmp/`. The script frames the prompt, so the claim file holds only
   the claim.

3. **Verify the tier from the run-log banner, not the flag you passed.** The script prints it.
   Profile defaults are per-machine and `luna`'s default effort is `low`, which is why the script
   always passes `-c model_reasoning_effort` explicitly.

4. **Reproduce every load-bearing claim Codex makes before relaying it.** Codex citing
   `file.ts:6-9` is a pointer, not a finding. Read those lines. This has caught both real findings
   Claude missed *and* confident claims that did not reproduce.

5. **Adjudicate — do not capitulate and do not defend.** Say plainly, per point, where Codex is
   right, where it is wrong, and where it is right about a fact but wrong about what follows.
   A code-vs-claim mismatch names a fact and never which side is wrong.

## Tiers

| flag | model | effort passed |
|---|---|---|
| `--tier luna` (default) | `gpt-5.6-luna` | `high` |
| `--tier sol` | `gpt-5.6-sol` | `high` |
| `--tier terra` | `gpt-5.6-terra` | `high` |

`solx` / `max` / `ultra` need the user's explicit per-action permission — they spend extra-usage
credits. Do not reach for them to settle a disagreement; reach for a reproduction instead.

## When this is the wrong skill

- Building, fixing, or auditing a codebase → `codex-converge`.
- A review that needs multiple lenses, rounds, and a convergence criterion → `codex-converge`.
- A factual lookup Claude can just run → run it.
