---
name: zsh-eats-a-colon-suffix-after-an-unbraced-var
description: In zsh, `$VAR:src/...` silently loses the `:suffix` — a history modifier attaches to the unbraced expansion; quoting does not help, braces do
metadata:
  type: reference
---

**In zsh, `$VAR:something` can silently drop the `:something`.**
zsh (unlike bash) applies history modifiers to a parameter expansion with NO braces — `$PWD:h` is the familiar one.
So a `rev:path` argument built from a variable is parsed as `$VAR` plus a modifier, and the path is eaten before the shell splits anything and before the command parses anything.

Measured 2026-08-28 on `git show "$C:src/core/plugins.ts"`, which returned a COMMIT DIFF instead of the blob and nearly landed a fabricated refutation of a peer's claim — true text with a false subject.
`:s` is the SUBSTITUTE modifier, and `:src/core/plugins.ts` is a valid one: delimiter `r`, pattern `c/co`, replacement `e/plugins.ts`.
The SHA did not contain `c/co`, so it substituted nothing and returned the value pristine — suffix gone, variable intact.
Derived rather than named: a value that DOES contain the pattern comes back substituted (`C=xxc/coyy` → `xxe/plugins.tsyy`).

```
zsh   $C:src/core/plugins.ts     -> 2554ffce                       # eaten
zsh  "$C:src/core/plugins.ts"    -> 2554ffce                       # QUOTING IS NOT A DEFENSE
zsh  ${C}:src/core/plugins.ts    -> 2554ffce:src/core/plugins.ts   # braces are
zsh   $C:docs/specs/x.md         -> 2554ffce:docs/specs/x.md       # 'd' is not a modifier
bash  $C:src/core/plugins.ts     -> 2554ffce:src/core/plugins.ts   # bash never does this
```

**Twelve first letters are eaten unconditionally — `a c e h l q r t u A P Q`** (measured silent under two different tails).
**Six more are TAIL-DEPENDENT — `s f g w F W`** — and this is where both independent enumerations of this entry went wrong, in mirror ways: the first read the modifier list by hand and mis-binned `s` as silent (its probe tail made it a LOUD parse error) while missing `Q` entirely; the second swept `a`–`z A`–`Z` but with ONE tail, which classifies every tail-dependent letter by whichever answer that arbitrary tail happened to give, and so reported `s` as the only one.

**The durable conclusion is that a first-letter table is the WRONG INSTRUMENT.** Whether a path is silently eaten is a function of the WHOLE string, not its first character, so no letter list can decide it. Measured, same first letter and opposite outcomes:

```
$C:fly.toml            -> 2554ffcey.toml     SILENT      $C:fixtures/a.ts     -> intact
$C:gates/g.ts          -> /abs/.../2554ffcetes/g.ts      $C:github/x.yml      -> intact
$C:web/page.tsx        -> b/page.tsx         SILENT      $C:worker/index.ts   -> intact
$C:src/core/plugins.ts -> 2554ffce           SILENT      $C:src/x             -> LOUD (you see it)
```

`fly.toml` is a real file in a repo that deploys from it. **So do not consult a hazard list — brace the expansion.** The list below is kept only to show the failure is deterministic, never as a thing to check against.

**The table is unsound for HAZARDS but sound for SAFETY, and the asymmetry is structural.** Tail-dependence can only arise for a letter that IS a modifier — the tail decides whether the modifier parses. A letter that is not a modifier at all is inert for EVERY tail. So "this path is dangerous" can never be read off the first letter, while "this path is safe" can, if you know the modifier set. **But reading `zshexpn` does not give you that set, and this is the part that bites.** The man page IS readable (`man -w zshexpn` resolves; the `Modifiers` section slices to 668 lines under zsh 5.9 — an earlier "the extraction returned nothing" was a property of the extraction command, not of the box). But **the `Modifiers` section is an explicit UNION across three expansion contexts, and it says so** — "The following `f`, `F`, `w` and `W` modifiers work only with parameter expansion and filename generation\. **They are listed here to provide a single point of reference for all modifiers**." Per-item context membership lives in PROSE, never in the tags, so **any tag/header extraction returns the union and silently presents it as the parameter-expansion set**:

- **over-lists** `p` ("Only works with history expansion") and `x` ("Does not work with parameter expansion") — their own bodies scope them out. Harmless; it only shrinks the safe set.
- **under-lists `g`**, a live prefix that appears only inside the `s/l/r/` prose with no tag of its own. Measured `$C:grc/core/plugins.ts` → `2554ffcec/core/plugins.ts` — `:gr` consumed. Extract the tags, conclude `gates/` is safe, and you are wrong.
- and the tag set is not even stable across instruments: the rendered-text rule gives `& a A c e f F h l p P q Q r s t u w W x`, the troff `.TP` rule drops `a` and `f` (both present in the source). Three rules over one readable file, three answers, none finding `g`.

So the safe half is only PARTLY derivable: **`plugins/` is derived safe** (`p` is documented and scoped out of parameter expansion), while **`docs/` stays empirical** — `d` is absent from the section entirely, and `g` is the standing proof that absence from it is not evidence of inertness. `d m n o v z S b i j k y` were inert on every tail tried. Treat the safe list as a strong empirical result with a gap the documentation cannot close.

**`:s` is silent iff the character following `s` recurs later in the tail** — it is the delimiter and the pattern must close (verified 6/6, predicting LOUD for `src/x` and `scripts/deploy-freeze.sh`, SILENT for `src/core/plugins.ts` and `srv/a/r.ts`). Realistic-tail hazards seen: `src/ test/ tests/ lib/ app/ hooks/ components/ core/ util/ tools/ handoffs/ resources/ fly.toml gates/ web/`; inert: `docs/ plugins/ package.json README.md .github/ scripts/ worker/ workflows/ fixtures/ github/`. **`app/` is the nastiest**: `:a` returns an ABSOLUTE path, so the corrupted argument looks *more* real, not less.

**Fix, in order of strength.**
1. **Brace it: `git cat-file -p "${C}:${F}"`.** One character class, stops it at the source.
2. Leave the shell entirely — Python `subprocess` LIST form passes `f'{rev}:{path}'` as one argv element with nothing to split. Immune by construction, though only to this; a wrong rev still poisons it.
3. Independently of the cause, `git show <rev>` with a missing path **FAILS OPEN** — exit 0, plausible content, no error to catch. Prefer `git cat-file -p` (no rev-only fallback) and assert a per-file blob read's first line is not `^commit [0-9a-f]{40}$`.
4. **A hasher downstream re-silences even the LOUD half.** When the eaten path does not exist, git errors — but `git show "$C:web/..." | shasum` still prints `e3b0c442…`, the hash of the empty string, which is indistinguishable from a real answer and reads as *the content changed*. So a verification that only compares hashes converts a caught failure back into a confident wrong conclusion. Hash-compare only after asserting the byte count is non-zero, and keep `e3b0c44298fc…` (sha256 of nothing) / `da39a3ee5e6b…` (sha1 of nothing) as recognisable-on-sight sentinels.

The general class, which outlives the shell detail: **a command whose output silently changes SUBJECT still answers you.**
Grepping a commit diff for an import attributes another file's line to the path you believed you asked for.
See [[verify-claims-against-artifacts]] and [[absence-needs-a-probe-that-could-see-presence]].
