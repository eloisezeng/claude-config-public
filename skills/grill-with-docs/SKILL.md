---
name: grill-with-docs
description: A relentless interview to sharpen a plan or design, which also creates docs (ADR's and glossary) as we go.
disable-model-invocation: true
---

Call the Skill tool twice, for "mattpocock-skills:grilling" and
"mattpocock-skills:domain-modeling".

This is a short-name alias so `/grill-with-docs` keeps working. The skills it
calls are Matt Pocock's, installed as the `mattpocock-skills@mattpocock` plugin
(https://github.com/mattpocock/skills, MIT) rather than vendored as copies —
so they update with the plugin instead of freezing at whatever was copied.
The plugin ships its own `grill-with-docs` too, reachable as
`/mattpocock-skills:grill-with-docs`; this file exists only for the short name.
