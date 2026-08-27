---
name: openai-structured-output-schema-limits
description: OpenAI structured outputs (--output-schema) reject optional properties, uniqueItems, and cross-field conditionals — express optional as a nullable type and enforce the rest caller-side
metadata:
  node_type: memory
  type: reference
  scope: global
---

`codex exec --output-schema <FILE>` (and `codex exec review --output-schema`) makes the CLI **enforce** a JSON Schema on the model's final response, which is what turns a review gate into a machine-checkable predicate instead of a reading of prose. But the accepted schema subset is narrower than JSON Schema, and every violation is a `400 invalid_json_schema` before any model work happens.

Verified live against Codex CLI 0.146.0 on 2026-08-03:

- **Every property must be listed in `required`.** There is no optional property. `400: 'required' is required to be supplied and to be an array including every key in properties. Missing 'base'.` Express "may be absent" as a nullable type — `"type": ["string", "null"]` — not by omitting the key from `required`.
- **`additionalProperties: false`** is required on each object.
- **`uniqueItems` is rejected**: `400: 'uniqueItems' is not permitted`. `minItems` and `minLength` ARE accepted.
- **No cross-field conditionals** (`if`/`then`/`allOf`), so an invariant like "verdict=approve implies findings is empty" cannot live in the schema. Enforce it in the caller — and note a reviewer really does emit `approve` alongside a critical finding, so trust the findings array over the verdict field.

A schema the model satisfies trivially is worse than none: bound what you can (`minItems`, `minLength`) and check the rest yourself. Anything the schema cannot express — uniqueness, `line_start <= line_end`, whether a file manifest names the *right* files — is a caller-side check or it does not happen.

Pairs with [[codex-model-tiers-and-effort-routing]], [[verify-claims-against-artifacts]].
