---
name: codex-converge
description: Use when building a feature or fixing/auditing a codebase with the full cross-AI convergence loop where Claude and Codex check each other at every stage. Runs brainstorm → spec → converge → plan → converge → execute → review-till-converge, pairing each Claude artifact with an independent Codex critique and looping until both AIs agree there are no remaining unresolved findings. Invoke when the user says "use the convergence workflow", "have claude and codex work together", "codex-converge", or asks for a thorough Claude↔Codex build/fix/review with Playwright verification.
---

# Codex-converge — the Claude↔Codex convergence build/fix loop

The job: produce high-quality changes by never letting one AI's work go unchecked.
At every stage, Claude writes the artifact and Codex independently critiques it (or vice-versa), and you loop until the two AIs converge.
This is the default pipeline for anything non-trivial: building a feature, fixing bugs, or auditing a codebase.

Use the superpowers skills for the Claude-side discipline (`superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:test-driven-development`, `superpowers:subagent-driven-development` / `superpowers:executing-plans`, `superpowers:requesting-code-review`, `superpowers:verification-before-completion`) and the Codex CLI for the independent second opinion.

## When to use

- Building a feature, fixing a bug, or auditing/cleaning a codebase where correctness and quality matter.
- Any time the user wants Claude and Codex to "work together" or check each other.
- Not for trivial one-line edits — use judgment; the loop has overhead.

## Setup

- Work in an isolated git worktree off the canonical base branch (`superpowers:using-git-worktrees`), so the change is cleanly reviewable.
- **Establish the base branch from the task, not from habit.** It is whatever this work will merge into — the PR target, or the repo's default branch (`git symbolic-ref refs/remotes/origin/HEAD`). Do not assume `origin/main`; a repo whose target is `develop` or a stacked branch will otherwise be reviewed against the wrong range for the entire loop.
- **Pin it once and write it to the progress file:** `BASE=$(git rev-parse <that-branch>)`. Every later review is scoped to this SHA. Re-resolving "the base" at review time is how a review silently covers the wrong range.
- Establish a green baseline first: run the test suite and the type-checker; record the numbers.
- Track phases as a task list so the loop survives a usage-limit reset; keep a short progress file on disk with the locked decisions.

## Preflight (once per machine, and re-check if a 5.6 call 400s)

GPT-5.6 requires Codex CLI **≥ 0.144.0** (OpenAI's documented minimum).
Locally verified 2026-08-03: 0.141.0 fails, 0.146.0 works.
An older CLI does not fall back — it returns `400 invalid_request_error: The 'gpt-5.6-sol' model requires a newer version of Codex`.
Check with `codex --version`; upgrade with `codex update`.

Note that `codex --version` reports the binary on PATH, which can lag the Codex desktop app.
The desktop app refreshes the shared `~/.codex/models_cache.json`, so a model can *appear* in the catalog while the CLI on PATH still rejects it.
Trust a live probe, not the catalog listing.

## Model routing — which Codex tier runs which stage

Codex exposes three GPT-5.6 tiers plus an effort ladder.
The tier sets capability; the effort sets how hard it thinks.
Read the live ladder with:

```
python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.codex/models_cache.json')));[print(m['slug'],m.get('default_reasoning_level'),[x['effort'] for x in m.get('supported_reasoning_levels') or []]) for m in d['models']]"
```

Re-verified on **the user's Mac** 2026-08-17 against `~/.codex/models_cache.json` (CLI 0.146.0):

| Tier | slug | Supported efforts | Default |
| --- | --- | --- | --- |
| Sol | `gpt-5.6-sol` | low…xhigh, `max`, `ultra` | **`low`** |
| Terra | `gpt-5.6-terra` | low…xhigh, `max`, `ultra` | `medium` |
| Luna | `gpt-5.6-luna` | low…xhigh, `max` | `medium` |
| (prev) | `gpt-5.5` | low…xhigh | `medium` |
| (prev) | `gpt-5.4` | low…xhigh | `medium` |
| (prev) | `gpt-5.4-mini` | low…xhigh | `medium` |

> **Tier availability and installed profiles are PER-MACHINE. This table is not portable.**
> This repo is shared with a fork whose machine has a different account and a different
> profile set, so never carry a routing flag from one machine's notes to another.
>
> Measured differences seen so far:
> - **the user's Mac** (ChatGPT auth, CLI 0.146.0): all three 5.6 tiers present. `-p sol` runs
>   `gpt-5.6-sol` at `high` — verified live 2026-08-17, not read from the catalog.
> - **deathstrxder's Windows machine** (different ChatGPT account, CLI 0.147.0): `-m gpt-5.6-sol`
>   returns `400 invalid_request_error: The 'gpt-5.6-sol' model is not supported when using
>   Codex with a ChatGPT account`, and the slug is absent from that machine's catalog. Terra is
>   the ceiling there, with `terrax`/`terramax` profiles that do **not** exist on the Mac.
> - **your-university cluster** (CLI 0.146.0): no profile files at all; base config is `gpt-5.6-sol`.
>
> **An unknown `-p <name>` is not an error — it silently falls through to the base config.**
> Measured on the Mac 2026-08-17: `-p terrax` (absent here) ran `gpt-5.6-sol` at reasoning
> effort **`none`**, while the caller believed it had asked for Terra/xhigh. The verdict looks
> identical to a real one.
>
> `run-codex.sh` now **refuses** a `-p` naming a profile with no matching
> `$CODEX_HOME/<name>.config.toml`, and prints the tier the run actually used from codex's own
> banner. Read that banner line, never the flag you passed.

**Context window is 272,000 tokens** (`context_window` in the model catalog), with `effective_context_window_percent: 95` — the same for all three 5.6 tiers and for 5.5.
Secondary write-ups quote a 1.5M window for the GPT-5.6 family; that is not what this CLI exposes, and sizing a prompt to it will overflow.
Read `context_window` from `~/.codex/models_cache.json` rather than trusting a blog.

**ALWAYS set the effort explicitly. Sol defaults to `low`.**
Selecting Sol without an effort runs the flagship at its weakest reasoning and can be *worse* than Terra at `high`, while costing more; Terra and Luna default to `medium`, which quietly runs an escalated stage at everyday depth.
Naming the tier without the effort is the single most expensive mistake in this skill — closely followed by naming a profile that does not exist on *this* machine, which fails *silently* rather than merely weakly.

An effort the chosen model does not support is a hard `400`, not a downgrade.
The error's "supported values" list is **model-scoped**, so a rejection seen on Luna does not mean the level does not exist — `ultra` 400s on Luna and succeeds on Terra.
Check the model's own ladder in the catalog before concluding a level is unavailable.

### Selecting a tier — real syntax

There is **no `--effort` flag on the Codex CLI**; that flag belongs to the `codex:*` plugin's companion script, not to `codex exec`.
Set effort one of these two ways:

```
codex exec -m gpt-5.6-sol -c model_reasoning_effort="xhigh" -s read-only -C <worktree> ...
codex exec -p solx -s read-only -C <worktree> ...
```

`-p <name>` layers `$CODEX_HOME/<name>.config.toml` over the base config, and an explicit `-m` / `-c` on the same command line still wins over the profile.
Profiles installed **on the user's Mac** (`ls ~/.codex/*.config.toml` — always check this rather than trusting the table, because the set differs per machine):

| Profile | model | effort |
| --- | --- | --- |
| `luna` | `gpt-5.6-luna` | `low` |
| `terra` | `gpt-5.6-terra` | `high` |
| `sol` | `gpt-5.6-sol` | `high` |
| `solx` | `gpt-5.6-sol` | `xhigh` |

A profile name with no matching file is not a codex error — it silently falls back to the base config, so `run-codex.sh` refuses it instead (see the preflight above).
Route through `run-codex.sh`; a bare `codex exec -p <name>` has no such guard.

For a route not covered by a profile (Sol at `max`, Terra at `medium` or `ultra`), pass `-m` and `-c` explicitly rather than adding profiles.

### Stage routing

Pick the cheapest tier that can do the job, and escalate only where a miss is expensive:

| Stage | Route | Why |
| --- | --- | --- |
| Textual traceability (does every spec line map to a plan task, and every plan task back to a spec line?) | `-p luna` | Mechanical string-and-structure matching against a document. |
| Discovery sweep / brainstorm angles | `-m gpt-5.6-terra -c model_reasoning_effort="medium"` | Breadth, not depth. |
| Spec and plan convergence rounds; plan-to-diff conformance | `-p terra` | Semantic judgment, everyday depth. |
| **Adversarial review of the diff** (the finding-hunt) | `-p sol` | Review is the stage where a miss ships a bug. |
| Security, migration, money/lifecycle seams, schema rebuilds | `-p solx` | the user's repeat-bug classes live here. |
| One gnarly tightly-coupled bug (a race, an ordering bug) | `-m gpt-5.6-sol -c model_reasoning_effort="max"` | Every clue must stay in ONE reasoning chain — do not split it. No profile covers this route. |
| Whole-codebase audit with independent workstreams | `-m gpt-5.6-terra -c model_reasoning_effort="ultra"` | Spawns internal subagents that decompose and reassemble. Highest spend — see the budget rule. |

Do not put semantic judgment on the Luna route.
"Does the diff match the plan" is a semantic question, and no inspection of a final diff can establish that a test failed first for the right reason — that requires the recorded red-phase command and output.
Keep Luna for traceability, and demand red/green evidence as an artifact rather than asking any model to infer it.

Max vs ultra is about the *shape* of the problem, not its size.
A small concurrency bug wants `max` because splitting it loses the thread; a large migration wants `ultra` because its workstreams are genuinely independent.

Escalate the prompt before escalating the model.
Per OpenAI's own Codex prompting guidance: tighten the task contract and the verification rules first, and only then raise reasoning.
If a round comes back vague, the usual fix is a missing `<structured_output_contract>`, not a bigger tier.

**Budget.** Published API pricing is Sol \$5/\$30, Terra \$2.50/\$15, Luna \$1/\$6 per 1M input/output tokens.
Those are **API-key prices and are not what the user pays** — this machine authenticates Codex with a ChatGPT subscription, so usage draws on plan allowances and credits instead.
Use the dollar figures only as a *relative weight* between tiers, never as a spend estimate.
The rule that does bind: no usage-based overage without explicit per-action permission.
`ultra` is the one setting whose cost is unbounded in principle (main agent + subagents + tool calls + integration), so treat Sol/`xhigh` as the default ceiling and ask before reaching for `ultra` on a large repo.

## The Codex CLI (the independent second opinion)

- Headless run: `codex exec -s read-only -C <dir> - < prompt.txt` (read-only for review/critique; pipe the prompt via stdin). `-s` is short for `--sandbox`.
- When working in a worktree, ALWAYS pass `-C <worktree-path>` so Codex reviews the right checkout, not the main working tree (this is a common silent mistake).
- Capture the final answer with `-o <file>` (short for `--output-last-message`) and redirect full logs to a separate file. Write `-o` to a path **outside the reviewed tree** so review artifacts never pollute the diff being reviewed. (`-o` is written by the host CLI, not by the sandboxed model, so `-s read-only` does not prevent it.)
- **Run every `codex exec` through the watchdogged launcher shipped with this skill**, `~/dotfiles/claude/skills/codex-converge/run-codex.sh`. `codex exec` wedges often enough that an unguarded call will eventually hang a whole round — and nothing in the Codex plugin replaces this: its only timeout is on the status poll, not a kill-and-retry on a wedged run.

```
SKILL=~/dotfiles/claude/skills/codex-converge
ARC="$CLAUDE_JOB_DIR/tmp"   # one directory per arc holds the ledger; TRACK is the lens, ROUND the panel number
"$SKILL/run-codex.sh" --policy-version 2026-09-02-scheduler-v1 --arc "$ARC" --track "$TRACK" --round "$ROUND" "$ARC/$TRACK-r$ROUND.prompt.txt" "$ARC/$TRACK-r$ROUND.verdict.json" "$ARC/$TRACK-r$ROUND.run.log" "$WORKTREE" \
  -p sol --output-schema "$SKILL/review-output.schema.json"
```

Its contract is `run-codex.sh --policy-version 2026-09-02-scheduler-v1 [--write] (--arc DIR --track T --round N [--name NAME] | --one-off) <prompt-file> <out-file> <log-file> <workdir> [codex-args...]`.
Attribution is mandatory: an unattributed launch exits 2 before touching codex, because it would be unscheduled and unprofiled.

**Give every run its own `<out-file>` and `<log-file>`, derived from the arc, track and round — never a fixed `/tmp/cc-verdict.json`.**
The launcher truncates the log at the start of each attempt and renames the verdict into place at the end, so two runs sharing a pair of paths destroy each other's evidence: the second truncates the first's log mid-run, and whichever finishes last overwrites the other's verdict, leaving a caller reading a verdict about a range it never asked about.
Since the parallel-lens panel runs three reviews at once, shared paths are the normal case rather than the exotic one.
This is now enforced — the launcher takes an `mkdir` lock on each path and refuses a second run aimed at either, and refuses outright if the two paths are the same file.
`CC_ARC` / `CC_TRACK` / `CC_ROUND` in the environment also count, and the arc defaults to `$CLAUDE_JOB_DIR/tmp`; `--one-off` is for a single call outside any arc (the `codex-opinion` skill uses it).
An attributed launch re-executes itself under `loop.py run`, which ledgers it in `<arc>/jobs.jsonl`, takes the tree lock, and refuses (rc 6) while the previous round of that track is unclosed or has a TRIGGERED lever nobody has dispositioned — see "Keeping the loop short".
The version handshake is a fail-closed session refresh: when this review policy changes, increment
the version in both files. A session holding old instructions cannot launch another round; the
launcher tells it to re-read this file and acknowledge the current version. It cannot alter a
review process already in flight, so apply the new policy starting with that process's result.
It supplies exactly one `-s` — **never pass your own** — plus `-C <workdir>`, `-o <out-file>` and stdin-piping; everything after `<workdir>` is passed through to `codex exec`, which is where the profile and schema go.
It kills a run whose log has been idle 150s (600s with `--write`; `RUN_CODEX_POLL` and `RUN_CODEX_IDLE_WINDOW` shorten both, which exists so the watchdog can be tested in seconds rather than never), clears the output file before each attempt, and exits non-zero unless a non-empty verdict landed.

Sandbox and retries depend on the mode, and the defaults below apply **only without `--write`**:

| Mode | Sandbox | Attempts |
| --- | --- | --- |
| default (reviews) | `read-only` | up to 3 |
| `--write` (implementation) | `workspace-write` | exactly 1, then quarantine |

Keep `<out-file>` and `<log-file>` outside the reviewed tree.

### Scoping the review to the right code

`codex exec review` takes `--base <BRANCH>`, `--commit <SHA>`, `--uncommitted`, `--output-schema <FILE>` and `--json`.

Always scope the final review with `--base $BASE` using the SHA pinned at setup.
**Never** finish a round on `--uncommitted` after the plan's atomic commits have landed: it reviews only staged, unstaged and untracked changes, so it will come back clean without ever reading the implementation.
Reserve `--uncommitted` for work deliberately left uncommitted.

**Commit or stash everything before the final review, then pin `HEAD` for the round** (`HEAD_SHA=$(git rev-parse HEAD)`).
A dirty tree means the range `$BASE...$HEAD_SHA` is not the change, and no verdict about it is trustworthy.
**Emit the SHAs per round from live `git rev-parse`, never from a reused prompt fragment.**
A stale HEAD baked into a shared facts/ledger block silently voided a whole round — all three reviewers obeyed the stale contract over the fresh task line and reviewed the previous range.
The `reviewed.head` echo check below is the tripwire; treat a mismatch as a failed round, and never skip it on an "obviously fine" round.

### Enforcing the output contract

Pass the vendored schema so the CLI enforces the shape, instead of the prompt merely requesting it:

```
SKILL=~/dotfiles/claude/skills/codex-converge
ARC="$CLAUDE_JOB_DIR/tmp"   # one directory per arc holds the ledger; TRACK is the lens, ROUND the panel number
"$SKILL/run-codex.sh" --policy-version 2026-09-02-scheduler-v1 --arc "$ARC" --track "$TRACK" --round "$ROUND" "$ARC/$TRACK-r$ROUND.prompt.txt" "$ARC/$TRACK-r$ROUND.verdict.json" "$ARC/$TRACK-r$ROUND.run.log" "$WORKTREE" \
  -p sol --output-schema "$SKILL/review-output.schema.json"
```

The schema requires `reviewed` (`base`, `head`, `files[]`), `verdict` (`approve` | `needs-attention`), `summary`, `next_steps`, and `findings[]` where each finding carries `severity` (`critical|high|medium|low`), `title`, `body`, `file`, `line_start`, `line_end`, `confidence` (a **number 0–1**, not an enum) and `recommendation`.

The `reviewed` block exists because a schema-valid clean verdict is otherwise unfalsifiable: `findings: []` proves nothing about what was read.
State `$BASE` and `$HEAD_SHA` in the prompt, require them echoed back, and check the round yourself:

- `reviewed.base` and `reviewed.head` are **non-null** and equal the SHAs you pinned — otherwise the reviewer looked at a different range. They are nullable so the same contract serves document reviews of a spec or plan; at the diff stage a `null` is itself a failed round.
- `reviewed.files` covers `git diff --name-only $BASE...$HEAD_SHA` (plus `git ls-files --others --exclude-standard` if any untracked file is part of the change). Any changed file missing from the manifest fails the round.
- At the spec and plan stages there is no diff to compare against, so name the expected document paths in the prompt and check `reviewed.files` contains them. The schema enforces only that the list is non-empty (`minItems`); **uniqueness and correctness are yours to check** — reject duplicate entries, and confirm it names the *right* files.
- Each finding's `line_start <= line_end`, and both land inside the cited file. The schema bounds them only at `>= 1`, so a reversed or out-of-range span validates while pointing at nothing.
- `verdict` and `findings` agree. The schema cannot express this — OpenAI's structured-output mode has no cross-field conditionals — so a response saying `approve` alongside a `critical` finding is schema-valid and has been produced in practice. **Trust `findings`, not `verdict`**; that combination is a contradiction and fails the round.

**If you edit the schema, obey OpenAI's structured-output rules or every round 400s.**
Each object needs `additionalProperties: false`, and `required` must list **every** key in `properties` — there is no optional property.
Express "may be absent" as a nullable type (`"type": ["string", "null"]`), never by leaving the key out of `required`.
Not every JSON Schema keyword is accepted either.
Verified against this CLI on 2026-08-03: `minItems` and `minLength` are permitted; **`uniqueItems` is rejected** (`400 ... 'uniqueItems' is not permitted`).
There are also no cross-field conditionals (`if`/`then`/`allOf`), which is why the verdict-vs-findings consistency check has to live in the caller.
Any such mistake yields a `400 invalid_json_schema`, which the launcher reports on the first attempt without retrying — read the message rather than assuming the model failed.

This schema is for **this skill's own `codex exec` prompts**.
Do not pass it to `codex exec review` — the built-in reviewer emits its own contract and does not know about `reviewed`.
Run the built-in `codex exec review --base "$BASE" --json` as a *complementary* second opinion under its own shape.

Treat **any** of the following as a failed round, not as a pass: non-zero exit from the launcher, missing or empty output file, JSON that does not parse, JSON that does not validate against the schema, or a `reviewed` block that fails the checks above.
A round that produced no parseable, scope-checked verdict has produced no evidence of anything.

### What to take from the `codex:*` plugin — and what not to

Take the **XML prompt blocks** (`codex:gpt-5-4-prompting`).
Structure each Codex prompt as `<task>`, then the blocks the stage needs: `<structured_output_contract>` always; `<grounding_rules>` for review and research; `<verification_loop>` and `<completeness_contract>` for debugging and implementation; `<action_safety>` for any write-capable run.
Add a `<verified_environment_facts>` block listing what you have already probed, with an instruction not to re-report those as findings — it stops rounds being spent re-litigating settled facts.

Do **NOT** route convergence rounds through the `codex:rescue` subagent.
Its contract is a pure forwarder: exactly one `task` call, stdout returned unchanged, explicitly barred from calling `review` / `adversarial-review` / `status` / `result`, and barred from inspecting the repo.
It cannot take `-C <worktree>`, so it would review the wrong checkout — the exact silent failure this skill warns about — and it defaults to `--write`, which is wrong for a review pass.
`codex:rescue` is for handing Codex one self-contained task, not for running this loop.

## The pipeline (loop each ↔ until convergence)

0. **Cost preflight — before the first paid launch, and round 1 is GATED on it.**
   (Distinct from the per-machine tier check above; this one is per ARC.)
   Price the arc against its RISK in writing, with `python3 "$SKILL/loop.py" preflight --arc "$ARC"`:
   `--critical-path` (what actually has to happen in order), `--parallel` (what does not, and therefore launches together),
   `--batch` (which checks share a run because they need no isolation), `--scope` (which surfaces the change really invalidated
   — a scoped review beats a full panel whenever the rest is unchanged), `--stop` (a BOUNDED condition; the recorder refuses
   "until no findings remain" and accepts "no new production-risk finding" or a named round count), and `--drivers` (the top
   cost drivers) — then cut the largest driver before spending on it.
   Buy ONE cheap Codex critique of the PROCESS itself — unnecessary serialization, duplicated verification, over-broad review
   scope, excessive stopping criteria, cheaper orders that keep the same guarantees — and record it with `--codex <file>`.
   It is a planning consultation, not a second loop. If Codex is down, record `--codex-unavailable "<why>"` and do the same
   analysis yourself; an outage never blocks the arc.
   A `review`, `write` or `mutant` launch at round 1 exits `RC_GATE` until this record exists, because the round-boundary
   profiler below cannot fire until a round has already been paid for — which is precisely the round this preflight prices.
   None of it buys speed with correctness, security, data integrity, deploy safety, or an explicitly required independent
   check: the target is equivalent safety with less serialization, less duplicated work, and less wall-clock.

1. **Brainstorm (Claude + Codex).**
   Run `superpowers:brainstorming` to explore intent and options.
   Ask Codex the same framing question independently (Terra at `medium`); fold its angles in.
   For an audit, the "brainstorm" is the discovery sweep: fan out Claude subagents per subsystem AND a Codex full-codebase pass, then consolidate + dedupe findings.
   When a design/UX decision needs the human, present a Lavish mockup (`visualize-in-browser` / `brainstorm-in-lavish` prefs), let the user pick, and fold the chosen option into the spec — this is the right place for the one human check-in in an otherwise hands-off run.

2. **Claude writes the spec.**
   A written design/spec doc (for a fix-set: the consolidated, deduped, severity-ranked findings + the intended fixes and any design decisions).
   Fold in every mockup/brainstorm critique so nothing is lost.

3. **Codex ↔ Claude converge on the spec.**
   Give Codex the spec (`-p terra`); ask it to find gaps, errors, missing cases, and disagreements, under the enforced schema.
   Claude addresses each point (fix or reasoned reject).
   Repeat until the gate below is satisfied.

4. **Claude writes the implementation plan — but answers the NECESSITY GATE first.**

   Before planning ANY new component, executor, route, worker, agent, table, or parallel path,
   answer these IN THE PLAN, in writing. A plan that introduces one without these answers is not
   ready to review.

   1. **What already does this, or most of it?** Name the existing machinery by file and symbol.
      "Nothing" is an answer only after you have searched for it — say what you searched.
   2. **Why can't this reuse or extend that?** A concrete blocker (different lifecycle, incompatible
      contract, a gate it must not inherit), not "cleaner" or "simpler to start fresh".
   3. **Does it contradict a recorded decision or a "don't do X" constraint?** Grep the spec, the
      brainstorm and the design agreement for the thing you are about to build. A line saying
      "reuse X rather than a parallel Y" is a constraint even when it is phrased as advice.
   4. **Can the constraint be enforced mechanically?** If so, the plan includes a guard task —
      see "Encode constraints as guards" below.

   *Why this gate exists (measured, 2026-08-07→11):* a design agreement said in writing "reuse
   `hand_register` … rather than a parallel money path". A parallel money executor was planned and
   built anyway. Nobody compared the plan task to that line. The result: 18 feature commits and
   **44 review-fix commits** across seven rounds, nearly all of them re-hardening logic the existing
   executors already had. Reused code inherits its tests and its scars; new code on a money path
   buys none of that and pays for every guard again.

   Then run `superpowers:writing-plans` — a TDD, step-by-step plan with atomic commits.

5. **Codex ↔ Claude converge on the plan.**
   Same loop as step 3, against the plan.
   Add a cheap `-p luna` traceability pass: every spec line maps to at least one plan task, and every plan task traces back to a spec line.

   **Traceability is COVERAGE, not CONSISTENCY — ask for contradiction separately.** A task "build a
   parallel X" traces perfectly to a spec line "do not build a parallel X": both name X, so the
   mapping passes. Add one explicit question to the plan-convergence prompt:

   > List every plan task that CONTRADICTS a spec line, a recorded decision, or a "don't do X"
   > constraint, quoting both sides. Then list every task introducing a new component, and for each
   > state what existing machinery it duplicates and why reuse was rejected. If the plan does not
   > answer that, say so — an unanswered necessity gate is a finding, not a gap to fill in yourself.

6. **Execute the plan — Claude or Codex, by task type (see "Who implements" below).**
   Run the plan with `superpowers:test-driven-development` (red→green→refactor) and `superpowers:subagent-driven-development` / `superpowers:executing-plans`.
   Record the red-phase command and output for each test as you go; that transcript is the only admissible evidence that TDD actually happened.
   Keep tests and the type-checker green; commit atomically.
   Finish the other relevant superpowers skills (e.g. `superpowers:verification-before-completion`).

7. **Codex ↔ Claude review each other's work — till convergence.**
   Claude runs `superpowers:requesting-code-review`; Codex runs an independent review of the diff, scoped `--base $BASE`, at `-p solx` when the diff touches security, money, migrations, or schema.
   If any range on this branch was Codex-authored, the Codex pass does not speak for it — see the independence rule in "Who implements"; those ranges need a Claude review artifact of their own.
   For UI changes, ground the review in Playwright on the live page (drive the real flow as an end user would), per the user's execution-verification preference.
   Each side adversarially verifies the other's claims; apply real findings, reject false ones with reasoning.
   Loop until the gate below is satisfied from both sides.
   Run the loop with the efficiency rules ("Keeping the loop short", below) — generated corpora for enumerable families, delta scoping after a clean sweep, lens panels over serial chains — so convergence takes rounds, not days.

## Who implements — Codex may write, under conditions

Codex is allowed to implement plan tasks. **The one rule that cannot bend: whoever wrote the code does not review it.** Codex-implements means Claude reviews; it never means Codex reviews its own diff, because author/reviewer independence is the only thing this whole loop buys.

**Route to Codex** the mechanical, well-specified, high-volume tasks: applying one pattern across many sites, migrations, sweeps, renames, independent workstreams. Sol at `medium` or `high`; reach for `ultra` only when the workstreams are genuinely independent.

**Keep with Claude** anything touching the seams the project's own instructions call out — payload readers, config defaults and their boot-time backfill, schema rebuilds, money and lifecycle paths. Those bugs come from project-specific knowledge, not general coding skill, and they are exactly where a confident wrong edit is most expensive.

**Preconditions — check these before the first write-capable run:**

- **Codex can see the project's rules.** Codex reads `AGENTS.md`, not `CLAUDE.md`. The user's global config sets `project_doc_fallback_filenames = ["CLAUDE.md"]` so it falls back correctly; verify per repo by asking Codex to quote a rule that exists only in `CLAUDE.md` before trusting it to write. A repo where this fails is a repo where Codex must not implement.
- **Isolated worktree, always.** `-s workspace-write -C <worktree>`, never the main checkout. `workspace-write` still lets Codex run commands; the worktree is what bounds the blast radius.
- **One plan task per run.** Do not hand it the whole plan; a single run that half-lands three tasks is far worse than three runs.

**Run it with the launcher's `--write` mode**, which is the only supported way to get a mutating run:

```
"$SKILL/run-codex.sh" --policy-version 2026-09-02-scheduler-v1 --write --arc "$ARC" --track "$TRACK" --round "$ROUND" /tmp/task.txt /tmp/task-out.json /tmp/task.log "$WORKTREE" \
  -p terra
```

`--write` supplies `-s workspace-write` (never pass your own `-s`), and it refuses to start unless the workdir is a linked worktree, off the default branch, and clean.
It runs **exactly once** — no retries, because a killed attempt may already have written or committed, and a retry would inherit that partial state and silently duplicate work.
On either outcome it pins and prints `START_SHA` plus the resulting commits and changed files.

**Contract for a write-capable run** — add these XML blocks on top of the usual ones:

- `<action_safety>`: stay inside the named files; no unrelated refactors; no dependency changes; do not stage with `git add -A`; commit only the files this task touches.
- `<verification_loop>`: write the test first, run it, and **paste the failing output verbatim**, then implement until it passes and paste the passing output. That transcript is the deliverable, not a claim about it.
- `<completeness_contract>`: the task is done only when the project's own gate commands (e.g. the test suite and the type-checker named in its instructions) are green.

**Then gate the result mechanically, before reading a word of it:**

- **Require the run to finish clean**, then gate the *entire* worktree state against `START_SHA` — committed, staged, unstaged and untracked. `START_SHA..HEAD` plus untracked files silently misses modifications to already-tracked files that were never committed, which is exactly where an out-of-scope edit hides. A write run that leaves a dirty tree is a failed task: quarantine it.
- Check that state against the task's **allowlist of files**. Any path outside it, or any commit beyond the expected count, fails the task — an out-of-scope edit that happens to pass tests is still not what the plan asked for.
  This is a **preliminary** path-and-count gate, not scope enforcement: it cannot see an unrelated hunk bundled into an expected commit inside an allowed file. Read the diff hunk by hunk and require each one to trace to the assigned plan task; reject any hunk that cannot be accounted for.
- **Check for under-delivery, not just over-delivery.** Excess commits fail the task, but so does a run that quietly did less: require the *exact* expected commit count, and walk every acceptance criterion and planned test in the task, confirming each appears in the diff and the transcript. One valid red→green transcript proves one test moved — not that a multi-case task was finished. Green project gates cannot detect a case that was never written.
- Re-run the tests and the type-checker in the worktree yourself. Never accept the run's own report that they passed; a status line is not an artifact.
- Confirm the red-phase transcript is actually present and shows a real failure. Absent evidence, the task is unverified regardless of what the final tree looks like.

**Reviewing Codex-authored code — the independence rule, made operational.**
Record the author and the SHA range of every task as you go (`task → author → START_SHA..END_SHA`).
A range is converged only when reviewed by the party that did **not** write it: Claude reviews Codex-authored ranges, Codex reviews Claude-authored ranges.
So on a mixed branch, step 7's Codex pass **cannot** be the verdict for the whole diff — it covers only the Claude-authored ranges, and a Claude review artifact must cover each Codex-authored range.
Treat a Codex verdict over its own range as no verdict at all; that is the one substitution that turns the entire loop into theatre.

**The ledger must be complete, or it proves nothing.** Before converging, check it against `git rev-list $BASE..$HEAD_SHA`: every commit is claimed by exactly one range — no gaps, no overlaps. Review fixes, cleanup commits, merge and conflict resolutions are commits too and need an author like any other; they are the ones that habitually go unrecorded and then inherit the wrong reviewer by default. A commit that no range claims is unreviewed by construction, whatever the round said. If a single commit genuinely has mixed authorship, split it or re-review the whole of it with the party that wrote neither half.

## Review rounds: parallel lenses, and who writes the fix

Measured over one 9-round build (2026-08-05): serial rounds with one generic prompt plateau, but
**diverse lenses keep finding real defects long after a single reviewer goes quiet**. Run each
review round as 2-4 concurrent lens-scoped prompts, not as repeated identical passes.

- **Run the NECESSITY lens first, and only on the first round of a build.** Before any lens asks
  whether the code is correct, one asks whether it should exist: *which of these components
  duplicates machinery that already exists, and what would reusing it have cost?* Give it the diff
  AND the list of comparable existing components (other executors, routes, agents). This is the only
  question that gets more expensive every round — once the code is hardened, nobody will delete it.
  Measured: seven rounds of correctness/lifecycle/money/test-quality lenses on a money path never
  once asked why it was a fourth money executor, while a design line said to reuse the third.
- Lenses that earned their place: **correctness & reconciliation**, **client state & lifecycle**,
  **test quality**, and for money/security/migrations a dedicated pass at `-p solx`.
- The **test-quality lens is the highest-yield one and the easiest to skip.** Require it to state,
  for every finding, the concrete production mutation that would leave the FULL suite green — and
  to say it ran that mutation. On the measured build it caught: an SSR test that never invoked the
  route, count assertions that passed against `${num}0`, a facet loop that ran zero assertions, a
  fixture asserted instead of the SQL actually prepared, and a disclosure whose copy was never
  rendered in any test.
- **A lens that just approved something is poorly placed to attack it.** When a fix lands for
  finding X, the next round's *other* lenses are what catch the defect the fix introduced — a
  render-phase ref mutation, a poll-starvation guard, a single-flight wedge, each introduced by the
  fix for the finding before it.
- **Do not stop on small numbers.** On the measured build, correctness returned 0 findings twice
  and then a HIGH on the next round. Stop only on a genuinely clean round, then confirm.
- **Two structural columns belong in the scorecard beside severity, and both are one command.**
  (a) *throws-added vs types-added* in the round's fixes — a mostly-throws round deferred the design,
  so spend the next fix on the shape (see "…then encode the guard in the SHAPE").
  (b) *fixes-per-file across the arc* —
  `git log --grep='^fix(<arc>)' --pretty=%H | while read c; do git show --stat --format= --name-only $c; done | grep -v '\.test\.' | sort | uniq -c | sort -rn | head -3`.
  A non-test file taking **>40% of the arc's fixes is a structural finding**, not a hot spot: it has
  fused the decision with the IO, so a scenario is the only way to reach any of its rules and each
  round finds one more combination in it. Extract the pure decision in the same round as that file's
  next fix, and argue it with the count — "15 of 28" is an argument, "this file feels big" is not.
- **Keep a written round scorecard: total findings and HIGHs per round, with the `profile-loop.sh`
  timeline and levers pasted beside it (see "Keeping the loop short").** A round returning only
  LOWs is a stop (use the deferral dispositions), not "one more pass". A FLAT rate over 3+ rounds
  (measured on a 12-round build: 5,6,4,4,4,6 findings / 2,2,1,1,1,2 HIGHs — no trend) means
  grinding has reached equilibrium: your fixes add reviewable surface as fast as the panel consumes
  it. Stop, or replace the patched region with one deliberate rewrite reviewed whole; never predict
  that the next round is clean. And a clean LENS is not convergence — lifecycle returned approve
  four rounds running, then produced a genuine HIGH.
- Carry a SPECIFIC `do NOT re-report` list into each prompt — each entry names the finding AND the
  reason it is settled; vague lists burn rounds re-litigating.

### Who writes the fix

Codex writes the fix for its own finding BY DEFAULT when the finding is mechanical (`run-codex.sh
--write`, linked worktree, one finding per run), and Claude then reviews that diff — the
independence rule holds, inverted. Run the two fix streams in PARALLEL: Codex grinds the mechanical
list while Claude fixes the judgment findings, so the fix stage pipelines instead of serializing.
Two writers cannot share one checkout — give Codex a sibling worktree on a temp branch off the
round's HEAD and have Claude merge it back (the merge commit is Claude-authored in the ledger).
Split by kind:

| Finding | Author | Why |
| --- | --- | --- |
| Mechanical, single-site — substring→exact assertion, an uncovered shape, a missing noun | **Codex** | unambiguous; a human-language round-trip adds latency and interpretation risk |
| Judgment — reject the finding, choose between designs, decide what a sentence may claim | **Claude** | needs repo history and product context, and "reject" is the right answer often enough to matter |

**…but route by the round's shape, not reflexively.** The benefit is OVERLAP; the cost per routed
fix is near-fixed (worktree + `node_modules` symlink, prompt authoring, ~10 min wall-clock, the
START_SHA gate, hunk-by-hunk diff review, mutation-verifying its tests yourself, committing and
merging on its behalf) — roughly 60–70% of writing it yourself PLUS its wall-clock, a win only when
that wall-clock hides behind judgment work you are doing anyway. And the contract is ONE finding
per `--write` run, so N mechanical findings are N SEQUENTIAL runs: on a round that is mostly
mechanical (measured: 4 mechanical + 1 judgment), Codex becomes the critical path and the split
makes the round LONGER than doing it all inline. Do it inline when it is the round's only finding,
when it is trivial (a grammar fix, a constant), or when the mechanical queue would outlast the
judgment stream. The DEFAULT stays "route mechanical to Codex" on mixed-set rounds — this is the
exception, not the reverse.

**Route by sub-task, and write the table first.** The routing UNIT is the sub-task, not the finding: write the routing table BEFORE the first fix lands, and carve each judgment finding's mechanical tail (a golden regeneration, a guard copied from an existing rule, a test scaffold) onto the Codex queue so it runs under the judgment work — the judgment stream is the critical path and it shortens only by moving work OFF it (measured 2026-09-01, your-module r1: 17 accepted, 7 mechanical ones ran on Codex in parallel, then the last three judgment items each carried such a tail and ran it serially on the judgment seat). A "mirror X inline in the UI" finding is an IMPORT of the existing predicate, never a second copy (share one predicate with the backend).

Expect `LAUNCHER_EXIT=4` as normal in shared-`.git` repos: `workspace-write` cannot reach the
repo's `.git/worktrees` dir, so Codex edits but cannot commit. Quarantined ≠ failed — gate the tree
against START_SHA as usual and commit on its behalf.

Two hard rules regardless of author:

1. **Mutation-verify every FIX, not just every test.** A reviewer's *proposed* test is not a
   verified test. On one measured build, Codex proposed a layout-effect harness for a commit-phase
   race; built exactly as described, it passed with the production guard deleted (it was removed
   rather than kept as false assurance, with a comment saying the guard is deliberately untested
   and why). On another, two fixes shipped with NO test and were caught only by mutating the fix
   itself, and two tests PASSED FOR THE WRONG REASON — one because a fixture's parked run made a
   different code path file the asserted artifact, one because the guard sat where the throw does
   not happen. A mutation that does NOT kill the test is a finding about your test, never a pass.
2. **Assert the edit target exists before replacing it.** A silent no-op `replace` reports success
   from the file write, not the match — twice on the measured build a "fix" was never applied and
   the passing suite meant nothing. Fail loudly instead.

### Micro-review the fix diff before the next full panel

A fix creates the surface the next round finds: on one measured branch (2026-08-07), three separate
rounds found defects in the previous round's own fixes — including a HIGH after two consecutive
zero-HIGH rounds. So when a round's fixes land, do not go straight to the next full panel: run one
fast counter-party pass over just the fix commits (`<prev-round-HEAD>..HEAD`; `-p sol`
when the fixes touch money, lifecycle or migrations), fix what it finds, and only then launch the
panel. The panel then confirms instead of discovering, and a fix-induced defect costs a micro-loop,
not a whole round. Scope it to the commits that have not yet had a counter-party review — the
Claude-authored judgment fixes; a Codex-authored fix was reviewed hunk by hunk at merge and needs
no second pass, so a round whose fixes were all mechanical goes straight to the panel. Scope discipline: the micro-pass supplements the full-range rounds — it never
substitutes for the confirming full-range round that closes the gate, and its reviewer must never
be the fix's author.

### Freeze discovery before regression review

The first whole-range implementation audit is **discovery mode**. Save its deduplicated findings,
the user's locked decisions, and the reviewed HEAD in the progress ledger before applying fixes.
Every corrective pass after that is **regression mode** until the fixes are clean:

- Review only `<previous-reviewed-HEAD>..HEAD` plus a named checklist of invariants the fix could
  affect. The prompt identifies the finding IDs being closed and their required regression tests.
- A regression round blocks only when a target finding remains, the fix breaks a named invariant,
  the claimed test does not detect removal of the fix, or the fix introduces a new critical/high
  defect in the same behavior family.
- A pre-existing concern outside that contract is recorded as a candidate for the confirmation
  sweep; it does not recursively widen the current round. Never hide a newly observed critical/high
  risk, but classify whether it was fix-induced before treating it as a regression blocker.
- When findings enumerate spellings, encodings, or other members of one machine-generable family,
  stop the instance loop. Add a generated adversarial corpus/property test and ask the reviewer to
  audit the family boundary once.

After regression mode is clean, run exactly one **confirmation mode** panel over the full pinned
`$BASE...$HEAD`. Confirmation may reopen the branch only for a concrete unresolved defect, not to
re-litigate a recorded product decision or accepted data outcome. A user decision is binding unless
new evidence shows its stated premise was false; reviewers classify it as `product_decision` or
`data_outcome`, not an implementation blocker.

Each review prompt declares `mode: discovery | regression | confirmation`. A regression prompt also
declares `target_findings`, `fix_range`, `affected_invariants`, `settled_decisions`, and
`out_of_scope_disposition: record_for_confirmation`. A prompt missing these fields is a discovery
prompt regardless of what it calls itself.

## Encode constraints as guards, not prose

A constraint written as a sentence can be contradicted silently by the next plan; a constraint
written as a test fails the build. Whenever an architectural decision is mechanically checkable,
the plan gets a guard task and the decision moves into it.

Checkable, in practice, is broader than it first looks:
- **A closed set of privileged call sites** — which modules may reach a money call, a raw credential,
  a destructive statement. Enumerate them in an exported constant, assert the set in a test, and
  require each entry to carry its justification beside it.
- **A boundary that must not be crossed** — a token, an import, a column that certain files may not
  read. A source scan with an allowlist, each entry commented with WHY it is permitted.
- **A default that must stay safe** — assert the seeded value, not just the resolver.
- **A shape that must not grow** — the exact element sequence of a surface, so an unreviewed
  addition fails rather than blends in.

The test's failure message is the design document: it should tell whoever tripped it what the
constraint is and where the decision was recorded, so the next person either complies or changes the
constraint deliberately. **Adding your file to an allowlist must be a conscious edit with a reason —
that friction is the entire mechanism.**

Prefer a guard at a CHOKE POINT over flags each call site must remember: the flag shape is
fail-open, and the next component written the obvious way silently reinherits the bug.

### …then encode the guard in the SHAPE, which is one step further

Prose → guard is where this section used to stop, and stopping there has a measured cost. Over four
weeks of one arc, 28 fix commits titled "harden / enforce / validate … invariants" added **~110
`throw` statements against ~27 type-or-schema constructs**, ending at **316 throws in 8,725 lines —
one every 28 lines**, with 15 of the 28 landing in the same 2,893-line module. Every round was
correct and converged; the invariants still ended up as scattered interior checks.

A finding of the form "X can be invalid *here*" is a **type** bug. The check closes the finding;
only the shape closes the class.

- **Parse at the boundary, don't validate in the interior.** One function turns untrusted input into
  a narrowed type — a discriminated union, a branded id, a non-empty array, a required
  non-optional field — and every downstream signature takes that type. A `throw` at depth 3 says the
  type at depth 0 was too wide.
- **Prefer impossible to loud.** A required parameter fails in CI at every call site at once; a
  runtime assert fails on one production path, later, in front of the user.
- **Two effects that must happen together are one function, one transaction, and the second's data
  is a required never-defaulted parameter of it.** Left to call-site discipline the pair holds until
  the first resume/backfill/retry path, then fails silently and writes no artifact to point at.
  (Measured: 735,506 names committed with no downstream wake, 734,892 archived unscreened.)
- **Anything that REPORTS what a run did queries the rows by run id**, rather than counting what the
  run returned — the return path and the write path diverge the moment anything writes mid-run.
  (Measured: a run that spent \$0.119 and filed an approval card logged itself a no-op.)
- A guard is genuinely right where the constraint is **dynamic** — a live budget, a clock, a vendor
  response. It is wrong wherever the caller could simply have been unable to say the invalid thing.

## Convergence definition — one gate

A stage is converged when **every** finding raised by either side has a recorded disposition.
No finding at any severity expires silently, and "zero high findings" is *not* the gate — a round with an unaddressed medium is not converged.

The permitted dispositions differ by severity, and there is exactly one way to release a blocker:

| Severity | May be resolved by |
| --- | --- |
| `critical`, `high` | **fixed** in the artifact, or **adjudicated as not a defect** with written evidence. Deferral is not available to the agent. The single exception is the user's own explicit, recorded risk acceptance — she can release a blocker; you cannot, and you must ask rather than assume. |
| `medium`, `low` | fixed, adjudicated as not a defect with written evidence, or deferred with a written reason. |

Read the gate off the validated JSON, never off the prose summary.
A summary that says "looks good" above a `high` finding is a real and observed failure mode.

A confirming round after the first clean result is SCOPED to what the last fix actually invalidated, and it is owed only when that fix touched production behaviour — a test-only, golden or documentation fix does not re-earn the full panel.
That scoped round is the LAST one for the region unless it raises a NEW production-risk finding; one more low-value observation is not a reason to buy another.
An unconditional extra round is ceremony, and ceremony is exactly what the round-1 preflight prices: record the stop as a bound (`--stop`), never as "until no findings".
Keep "safe to ship" and "all review work complete" as separate verdicts — the first does not wait on the second, so an otherwise-shippable artifact is never held behind unrelated hardening.

**Reproduce a reviewer's claim before acting on it** — run the scenario yourself; the minute it costs pays either way.
Either the claim is right and you now know the exact shape (verified here: SQL `json_extract` takes the FIRST duplicate key, JS `JSON.parse` the LAST), or it is right about the risk while its recommended fix is wrong — one proposed validator-flag tightening could not be reproduced and would have re-introduced a narrowing bug from two rounds earlier; it was rejected with evidence, the class fixed instead, and the rejection recorded in the spec.
Never tighten a guard to match a validator whose acceptance set you have not measured.

Adjudicate a disputed finding in the contract, never by softening the prompt so the finding stops appearing.
Use evidence appropriate to the claim and the stage: a primary source or an explicit spec line is sufficient during spec and plan convergence, when no implementation exists yet.
Once the behaviour is implemented, a claim about executable behaviour additionally needs a pinning test.
Carry adjudicated disputes into the next round's `<verified_environment_facts>` block (`Do not re-report X — adjudicated against <primary source>`) so a settled question does not consume every subsequent round.

## Keeping the loop short — efficiency rules

The gate above defines *when* you are done; these rules keep the number of rounds it takes small.
They were extracted from a real loop that ran 30+ rounds, roughly half of them grinding a single validator family one finding at a time.

**The first round is priced before it is bought — the profiler is one increment late by construction.**
`loop.py` refuses a round-1 `review`, `write` or `mutant` launch in an arc with no `preflight` record on the ledger, and the record is derived, never a name: an arc whose paid jobs all predate the gate is grandfathered, while a job that was refused the lock spent nothing and grandfathers nothing.
That closes the hole this section otherwise leaves open — everything below measures a loop that is already running, so a loop that should never have been launched in that shape reads perfectly healthy at every boundary.

**Profile the loop at EVERY round boundary — the launcher now refuses to skip it.**
Every review or `--write` launch is attributed (`--arc DIR --track T --round N`) and runs through `loop.py`, which writes an exact per-job ledger (`<arc>/jobs.jsonl`: requested / started / ended, queue wait, CPU class, tree state, exit code) and holds two locks.
The per-tree lock is shared by readers and exclusive for a `--write`, so a write waits for the reviews reading that tree and a review never starts on a tree mid-edit; a read-only job whose tree changes underneath it anyway exits 5 and quarantines its verdict as `<out>.tree-moved` (the fail-open the old SHA assertion gave you, now mechanical).
The machine-wide CPU lock serialises wide vitest / tsc / full-suite runs (exclusive), lets scoped test files share it, and is not taken at all by model reviews or `--write` runs — so reviews overlap implementation for free while the suites that used to fight each other cannot.
**Do not make a review wait for an unrelated write — freeze the SHA and read that.**
`python3 "$SKILL/loop.py" snapshot --arc "$ARC" --track T --round N --repo <any worktree> --sha <SHA>` prints a detached worktree at `<arc>/wt/<sha12>`, created once and reused.
A review pointed at that path holds the lock on a tree nobody writes, so it overlaps implementation on the real worktree instead of queueing behind it — this is the whole of lever L1, and it is why a round's three lenses launch in parallel rather than in sequence.
**L1 reads SOLO wait — one blocking call with an idle machine behind it — not merely "a wait with no non-wait beside it".**
Two lenses overlapping is the state L1 asks for, so a fully parallel panel must read quiet or the lever is telling you to land the fix you just landed.
Measured on this skill's own arc: round 2 ran three lenses concurrently for 19m28s and the earlier predicate still reported TRIGGERED at 100%; under the solo rule the same round reads 7m32s (39%) and goes quiet, and that 7m32s is the real tail — the last lens still running after the other two finished, with nothing left to overlap it with.
It does not weaken the tree-moved check: the snapshot is still snapshotted and compared, so a lens whose frozen tree is disturbed still exits 5 and quarantines its verdict.
The snapshot is taken and compared while the tree lock is HELD, so a writer that merely finished while a reader was queued is the tree the reader reads, not a "move" that quarantines a good verdict.
`--prune` removes them when the arc is done.

Run scoped tests through it too: `python3 "$SKILL/loop.py" run --arc "$ARC" --track T --round N --kind vitest --tree "$WORKTREE" -- npx vitest run <changed test files>`.
It counts the `Test Files` / `Tests` summary lines and fails CLOSED (rc 5) on the zero-file or zero-test run that vitest itself exits 0 on; a wide run (no file arguments, or more than 8 files) is refused (rc 4) unless declared a checkpoint (`--checkpoint "pre-merge"`), and `--affected BASE` derives the file list from `git diff --name-only` and escalates to a checkpoint by itself when a config file moved.
`--no-capture` is REFUSED for `--kind vitest` (rc 2): the zero-test gate is read out of the child's output, so suppressing the capture would turn vitest's exit 0 on a name filter that selected nothing back into a green.
Route mutation testing through `mutate.py --arc "$ARC" --track T --round N` — it shares the ledger and the light CPU lock, turns a `-t` that matched nothing into MISARMED instead of a green, and never arms a mutant in the tracked tree.
It takes the SAME round-locked admission transaction as `loop.py run`, so a battery cannot execute against an already-closed round (rc 6) or land its events after a `close-round` has snapshotted the ledger; round 1 therefore needs the preflight on record like any other paid job.
The attribution tuple is all-or-nothing: `--arc` with no `--round` (or any other partial spelling) is a usage error (rc 4), because the old behaviour was to run the whole battery unledgered and unGATED while LOOKING addressed, with its wall-clock landing in the unexplained-gap bucket.
To mutate a helper that lives in the test file itself (a wait, a deadline, a fixture rule), pass the same file as `--src` and `--test` and give the module it imports with `--also-copy loop.py`; companions are placed unmutated beside the copy each round and hashed as tracked.
The copy dir holds the source under its basename and the test under ITS basename, test written second, so a basename collision between two DIFFERENT files would overwrite the armed source and report every mutant SURVIVED at exit 0 — that shape is refused as usage (rc 4), and the same-file case writes one file once instead.
At the boundary run `profile-loop.sh "$ARC" --round T:N` and paste its `timeline` and `levers` blocks into the scorecard, then `python3 "$SKILL/loop.py" close-round --arc "$ARC" --track T --round N`.
A job that ledgered a `start` but never a `child` recorded no process group, so its liveness cannot be established at all — `--abandon-unfinished` does NOT cover it (that flag abandons jobs measured dead), and the operator must name each one with `--abandon-unverifiable=<names>` after confirming by hand that it is gone; the round-close record keeps those separate from `abandoned`, because one says "we saw it die" and the other says "nobody could see, and a human asserted it".
`close-round` records which levers read TRIGGERED for that track and round, and every launcher for round N+1 of that track exits 6 until each one is dispositioned with `python3 "$SKILL/loop.py" lever --arc "$ARC" --track T --round N --id L3 --state landed|declined --note "…"`.
A lever that reads TRIGGERED is landed before the next panel launches, never listed as an option (memory `optimize-the-loop-unprompted`); a decline carries the reason into the ledger.
Gaps in the arc's wall-clock are classed from evidence only — `declared` (via `loop.py note`), `seat-blocked` / `seat-active` / `seat-silent` from the job heartbeat, else `unknown` — the profiler never names a cause it cannot show.
A wall-clock STEP is separated from real elapsed time by the offset between each job's wall and monotonic clocks, recorded at BOTH ends of every job: a step that lands while a 20-minute lens is running moves only the end offset, so a detector built from start offsets alone would bill it to the seat as work.
Such a step is reported with that job on both sides of the boundary, which is the truthful attribution — it happened while that job was what was running.
A flat artifact directory with no ledger still profiles under the old birth→mtime heuristics, and every such artifact is reported UNATTRIBUTED (lever L7).
The profiler's own fail-opens remain: a span read as "the suite got slower" is usually two runs contending for one machine — L4 names the overlapping jobs, so rerun the slow one ALONE before touching compiler or test config — and the one thing the scheduler cannot lock is a vitest run that codex launches inside a `--write` job.

**Read each round by REMEDY SHAPE, and leave the document stage when the findings turn code-shaped.**
A finding is **code-shaped** when discharging it means writing a function, a case table or a test-matrix row — "this rule has no implementable signature", "this matrix covers one of three kinds", "this named mutant survives".
It is **document-shaped** when discharging it changes what the design DECIDES — a wrong ordering, a missing failure branch, a claim about existing behaviour that is false.
Tally both counts in the dispositions ledger beside the severity scorecard.

Once a round is majority code-shaped, the document has run out of prose-answerable questions: stop the panel and implement.
Code-shaped findings resolve in minutes at the keyboard and are proven by a test going red; in prose they resolve into wording the next lens re-opens, one sibling site at a time.
Measured 2026-09-01 on an alerting spec: five document rounds, zero lines of code, and round 5 returned one signature finding plus two test-matrix findings that the first implementation commit would have settled for free — while round 4's own FIX minted round 5's blocking HIGH.
An extra prose round is not merely slow; past that point it manufactures defects.

**This does not weaken the gate above.** Those HIGHs are not deferred and not adjudicated away — they are re-typed as implementation tasks and discharged in the SAME commit as the code they describe, which is a stronger disposition than a spec edit promising them.
Group them by shape first: "a named matrix covers only one of N kinds" at two sites is ONE class, so fix the class.

**`--write` serializes per TREE, not globally.**
The one-run-at-a-time, nothing-else-dirties-the-tree constraint is a property of the worktree the launcher checks, so independent tracks touching disjoint files have no reason to queue behind each other.
Give each track its own linked worktree and run their implementations concurrently, committing with `-o <paths>` while siblings are live.
Measured on the same lane: three tracks with disjoint file sets ran strictly sequentially for no reason but a shared cleanliness check.
Read-only review lenses never had this constraint — keep running them panel-wide.

**Ship the independent slice rather than the whole document.**
When a spec has two halves joined only by a shared dependency and every blocking finding sits in one half, split at the seam and ship the clean half now.
Measured: a disk-headroom alert (a probe, two thresholds, two templates) sat blocked for rounds behind the agent-health half that owned every HIGH — and it was the half the operator could act on soonest.

**Detect the enumeration treadmill.**
When consecutive rounds concentrate their findings in one family (textual money forms, Unicode digit tricks, encoding variants), the reviewer is winning a game that fixing instances cannot close.
Stop fixing instance-by-instance: give the family a generated corpus (next rule), and raise whether the contract itself should change — an allow-list beats a deny-list wherever a safe fallback makes over-rejection free.
That is a spec question to adjudicate, not another round.
When the treadmill is a guard or assertion rather than a textual family — measured: a scale guard that went regex → column metadata → +text → +comment stripping → TEMP VIEW, and a transaction assertion bypassed 7 distinct ways — the exit is to assert the PROPERTY instead of the SHAPE: read the engine's own statement trace rather than wrapping JS methods; assert the builder observed post-interleaving state rather than that the trace looks right.
Shape assertions invite bypasses forever.
Where no property-level assertion exists, accept the limit, record it in the spec with its reason, and stop paying for it.

**Give machine-checkable families to a generator, not the reviewer.**
Any family whose membership is enumerable by code — currency and sign forms, Unicode digit blocks, spacing/grouping variants, spelled numbers, date formats — gets a programmatic adversarial corpus wired into the test suite as property tests.
The reviewer's job then shrinks to auditing the generator's coverage once, instead of imagining one bypass per round.
A frontier model at `xhigh` is the most expensive fuzzer money can buy; a script fuzzes better and permanently.

**Close a region with a census, then declare the NEXT panel its last.**
When three consecutive rounds land their findings in one region, the rate is falling but it is not converging — measured 2026-09-01 on a shelf-draft validator: rounds 3–6 all hit one Unicode fold pipeline, findings 15→10→14→9→7→6, each round's fix minting the next round's boundary case.
Stop dispositioning that region one finding at a time.
Enumerate its input space by code (every assigned code point, every enum value, every call site), derive the accepted and refused sets FROM THE CODE, pin both directions in the test, record the rule and its boundaries in the spec, and write in the scorecard that the next panel is the last for that region.
After it, a finding inside the region is dispositioned against the census: a member the census admits by rule is DECLINED with the rule cited; a member the census missed is a census bug, so fix the census, not the instance.
`enumerate-recurring-defect-classes` says trigger on the second repeat; the census is what the trigger produces, and the "last panel" line is what stops the region absorbing rounds 7, 8 and 9.

**Overlap the stages that read a frozen sha.**
The micro-review of a fix diff reads a COMMITTED sha, and Phase C mutation runs on a COPY of the tree; neither waits on the other.
Commit the fix, launch the micro-review lens against that sha in a second linked worktree, and run Phase C in the working worktree meanwhile.
The one real serialisation is never editing tracked files while a lens or a mutation run is reading them — the harness's sha256 assert fails the run if you do, which is the guard working.

**Reuse the round mechanics instead of rewriting them each arc.**
`mutate.py` beside this file is the mutation harness: a mutants JSON in (`label`, `old`, `new`, `expect: killed|survived|unobservable`, `test`), one line per mutant out (`KILLED`/`SURVIVED`/`MISARMED` against its expectation), armed only on a copy, with `--census 'REGEX=N'` as the completeness guard for an enumerated class and sha256 asserts on the tracked files.
A mutant is only as good as its ANCHOR, and an anchor rots the moment the code under it is rewritten: 0 matches means the mutant arms nothing, 2+ means it rewrites every site so the kill no longer isolates the line the label names.
`loop.stranded_mutant_anchors` is that rule as a pure function, checked over every battery by `loop_test.py` in milliseconds, so a rewrite that strands a mutant reddens on the next unit run instead of surfacing as MISARMED forty minutes into a battery.
It is a checkout-only check — inside a mutation copy there are no batteries to scan, so it SKIPS visibly rather than passing, and section 12c of `tests/codex-loop.test.sh` pins that an in-repo run really ran it.
Give every `expect: killed` mutant a `test` naming the test that must kill it — it becomes vitest's `-t` filter, turning a 9-mutant round over a 52-test file from 468 test executions into 9, and pinning WHICH test kills the mutant rather than accepting a kill by any neighbour. A filter that selects no test is MISARMED, never SURVIVED (vitest exits 0 on a zero-match `-t`, which would read every `killed` expectation as satisfied).
Give it a copy dir unique to your session, and expect the census to correct you: on its first run it refused a site count of 13 carried from memory — the code had 12.
Write one `make-prompts.py` per arc at round 1, parameterised by round number, HEAD and the previous round's results, and re-run it each round; hand-editing three lens prompts per round costs wall-clock comparable to a lens run.
Surface the human-gated ship steps (an inbox card whose approval releases N of the affected items) at the FIRST green, not in the final report — the human's clock runs in parallel with the loop's only if you start it.

**After a clean full sweep, review deltas.**
Once a full-range round has come back clean, scope the next rounds to the fix commits (`<last-clean-swept-HEAD>..HEAD`) plus a fixed invariant checklist, at full reviewer strength.
Run a full-range sweep every few delta rounds so drift in untouched files is still caught.
The final confirming round that closes the gate always reviews the full pinned range and always includes a WHOLE-DIFF lens — twice on measured builds, three clean narrow lenses were followed by a whole-diff pass finding a real regression.
Delta scoping accelerates the middle of the loop, never the gate itself.

**Prefer a panel over a chain.**
When the range is large or rounds keep producing findings, run several reviewers in one round with distinct lenses — money, lifecycle, concurrency, Unicode/i18n, schema — union and dedupe their findings, fix once, then run one confirming pass.
Lens diversity finds more per round than the same reviewer re-run serially, and it converts many fix→review round-trips into one.
Each lens run still echoes and validates the pinned range like any other round.

**Use the deferral dispositions deliberately.**
The severity table above already permits deferring `medium`/`low` findings with a written reason; use that on purpose instead of spending full rounds polishing them, especially when a human approval gate stands between the artifact and the outside world.
`critical`/`high` still block exactly as the table says — this changes the cost of the tail, not the bar.

**Mechanics that waste wall-clock.**
Launch panels and `--write` runs as tracked BACKGROUND jobs — a foreground shell timeout kills the codex child, and ~20 minutes were once spent polling a run that had been dead the whole time.
Never conclude from a status line: a run-level CI `conclusion: failure` whose job shows `runner_name: ""` means the tests never ran (an Actions outage), not a red build.
And grep verdict files for the assertion text itself, not a generic word like "Tests" — a filtered grep once hid a present transcript and nearly caused the work to be re-run.

## Finishing

- Verify the real artifact, not just the code — for UI, check the running page as an end user would (`~/.claude` global verification prefs).
- Respect the chosen ship target (e.g. stop at a PR vs merge+deploy); don't exceed it.
- On a usage-limit / API error, route around it and resume after reset — never abandon the loop. No paid overage unless told.
