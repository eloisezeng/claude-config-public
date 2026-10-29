---
name: a-name-resolved-at-runtime-fails-silently
description: A reference resolved by NAME in a namespace no checker owns (CSS custom property, i18n key, flag name, env var) fails to nothing instead of erroring; guard it by enumerating the definitions and asserting every reference resolves
metadata:
  type: feedback
  scope: global
---

A reference resolved by NAME at runtime, in a namespace no type checker owns, does not fail — it
resolves to **nothing**, and the artifact renders with the fallback as if that were the intent.
`var(--size-metaa)` in a CSS module makes the declaration vanish and the text render at the
inherited size. The same shape covers an i18n key, a feature-flag name, an env var name, a CSS
class in a non-module stylesheet, and a `data-*` selector: the compiler cannot see it, the unit
suite cannot see it, and a screenshot only catches it if a human notices that one label is the
wrong size.

**Why:** these namespaces have definitions in one file set and references in another, with no
link step between them, so "spelled wrong" and "deliberately absent" are the same program. The
usual guards are all blind: a type check never enters the string, a render test asserts the TEXT
and not the computed style, and a palette/duplication guard asks whether a value is repeated
rather than whether a name resolves.

**How to apply:** when a change adds a stylesheet, a message catalogue, or any file that
references such names, ship a guard with it in the SAME commit that (1) enumerates the DEFINED
names by scanning the definition files from `git ls-files`, not from a hand-typed list,
(2) extracts every reference from the new file, and (3) asserts the difference is empty in the
reference → definition direction, with a sanity floor on both counts (`defined.size > 50`,
`read.length > 10`) so a scan that silently found nothing fails instead of passing. Add the
companion assertion that the file holds no literal of its own (no hex colour where the project
catch something on its FIRST run: mine did, on a token layer that mints `--track-meta` but no
`--size-meta`, which is exactly the near-miss a human eye reads as correct.

Before writing the guard, find where the project's constants actually live and whether they are
LOADED: a token directory can be tracked, complete and imported by nothing, which looks identical
to a live one from a file listing — `[[measure-what-reaches-context-not-disk]]` is the same
question one layer down. Follow the `@import` chain and the class the values are scoped to.
